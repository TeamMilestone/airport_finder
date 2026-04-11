//! Airport finder — given (lat, lng), returns the nearest airport code.
//!
//! Rust rewrite of the Go `airport_finder` project.
//! Exposes a C FFI function for Python ctypes integration.

use std::collections::HashMap;
use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::OnceLock;

use rstar::{RTree, RTreeObject, AABB};
use serde::Deserialize;

// ---------------------------------------------------------------------------
// Embedded data (compiled into the binary)
// ---------------------------------------------------------------------------

const AIRPORTS_JSON: &str = include_str!("../data/airports.json");
const COUNTRIES_JSON: &str = include_str!("../data/countries.geojson");

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Clone)]
struct Airport {
    iata: String,
    name: String,
    city: String,
    country: String,
    lat: f64,
    lng: f64,
}

#[derive(Debug, Deserialize)]
struct GeoJSON {
    features: Vec<Feature>,
}

#[derive(Debug, Deserialize)]
struct Feature {
    properties: Properties,
    geometry: Geometry,
}

#[derive(Debug, Deserialize)]
struct Properties {
    iso_a2: Option<String>,
    #[serde(alias = "NAME")]
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Geometry {
    #[serde(rename = "type")]
    geom_type: String,
    coordinates: serde_json::Value,
}

// ---------------------------------------------------------------------------
// R-tree spatial index for country bounding boxes
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct CountryEnvelope {
    min_lng: f64,
    min_lat: f64,
    max_lng: f64,
    max_lat: f64,
    country_code: String,
    feature_index: usize,
}

impl RTreeObject for CountryEnvelope {
    type Envelope = AABB<[f64; 2]>;

    fn envelope(&self) -> Self::Envelope {
        AABB::from_corners([self.min_lng, self.min_lat], [self.max_lng, self.max_lat])
    }
}

// ---------------------------------------------------------------------------
// Global state (initialized once on first call)
// ---------------------------------------------------------------------------

struct FinderState {
    airports: Vec<Airport>,
    geojson: GeoJSON,
    airports_by_country: HashMap<String, Vec<usize>>, // country_code -> airport indices
    country_rtree: RTree<CountryEnvelope>,
}

static STATE: OnceLock<FinderState> = OnceLock::new();

fn get_state() -> &'static FinderState {
    STATE.get_or_init(|| init_state().expect("failed to initialize airport finder"))
}

fn init_state() -> Result<FinderState, String> {
    let airports: Vec<Airport> =
        serde_json::from_str(AIRPORTS_JSON).map_err(|e| format!("airports parse: {e}"))?;
    let geojson: GeoJSON =
        serde_json::from_str(COUNTRIES_JSON).map_err(|e| format!("countries parse: {e}"))?;

    // Build airports-by-country index
    let mut airports_by_country: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, ap) in airports.iter().enumerate() {
        airports_by_country
            .entry(ap.country.to_ascii_lowercase())
            .or_default()
            .push(i);
    }

    // Build R-tree on country bounding boxes
    let mut envelopes = Vec::new();
    for (i, feature) in geojson.features.iter().enumerate() {
        let iso = match &feature.properties.iso_a2 {
            Some(s) if !s.is_empty() && s != "-99" => s.to_ascii_lowercase(),
            _ => continue,
        };
        if let Some(env) = calculate_bounds(&feature.geometry, &iso, i) {
            envelopes.push(env);
        }
    }
    let country_rtree = RTree::bulk_load(envelopes);

    Ok(FinderState {
        airports,
        geojson,
        airports_by_country,
        country_rtree,
    })
}

// ---------------------------------------------------------------------------
// Bounding box calculation
// ---------------------------------------------------------------------------

fn calculate_bounds(geom: &Geometry, code: &str, idx: usize) -> Option<CountryEnvelope> {
    let mut min_lat: f64 = 90.0;
    let mut max_lat: f64 = -90.0;
    let mut min_lng: f64 = 180.0;
    let mut max_lng: f64 = -180.0;

    let mut update = |lng: f64, lat: f64| {
        if lat < min_lat { min_lat = lat; }
        if lat > max_lat { max_lat = lat; }
        if lng < min_lng { min_lng = lng; }
        if lng > max_lng { max_lng = lng; }
    };

    match geom.geom_type.as_str() {
        "Polygon" => {
            let coords: Vec<Vec<Vec<f64>>> =
                serde_json::from_value(geom.coordinates.clone()).ok()?;
            for ring in &coords {
                for pt in ring {
                    if pt.len() >= 2 { update(pt[0], pt[1]); }
                }
            }
        }
        "MultiPolygon" => {
            let coords: Vec<Vec<Vec<Vec<f64>>>> =
                serde_json::from_value(geom.coordinates.clone()).ok()?;
            for poly in &coords {
                for ring in poly {
                    for pt in ring {
                        if pt.len() >= 2 { update(pt[0], pt[1]); }
                    }
                }
            }
        }
        _ => return None,
    }

    if min_lat >= 90.0 || max_lat <= -90.0 {
        return None;
    }

    Some(CountryEnvelope {
        min_lng, min_lat, max_lng, max_lat,
        country_code: code.to_string(),
        feature_index: idx,
    })
}

// ---------------------------------------------------------------------------
// Geometric algorithms
// ---------------------------------------------------------------------------

fn normalize_lng(mut lng: f64) -> f64 {
    while lng > 180.0 { lng -= 360.0; }
    while lng < -180.0 { lng += 360.0; }
    lng
}

/// Haversine distance in km.
fn haversine(lat1: f64, lng1: f64, lat2: f64, lng2: f64) -> f64 {
    const R: f64 = 6371.0;
    let d_lat = (lat2 - lat1).to_radians();
    let d_lng = (lng2 - lng1).to_radians();
    let lat1r = lat1.to_radians();
    let lat2r = lat2.to_radians();
    let a = (d_lat / 2.0).sin().powi(2)
        + lat1r.cos() * lat2r.cos() * (d_lng / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
    R * c
}

/// Ray-casting point-in-polygon (GeoJSON coordinate order: [lng, lat]).
fn point_in_polygon(lng: f64, lat: f64, ring: &[Vec<f64>]) -> bool {
    let mut inside = false;
    let n = ring.len();
    if n == 0 { return false; }
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = (ring[i][0], ring[i][1]);
        let (xj, yj) = (ring[j][0], ring[j][1]);
        if ((yi > lat) != (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}

// ---------------------------------------------------------------------------
// Country detection
// ---------------------------------------------------------------------------

fn find_country_code(state: &FinderState, lat: f64, lng: f64) -> Option<String> {
    // Special cases: remote islands missing from GeoJSON
    if lat >= 37.23 && lat <= 37.25 && lng >= 131.85 && lng <= 131.87 { return Some("kr".into()); } // 독도
    if lat >= -37.2 && lat <= -37.0 && lng >= -12.5 && lng <= -12.1 { return Some("sh".into()); } // Tristan da Cunha
    if lat >= -49.7 && lat <= -48.9 && lng >= 68.5 && lng <= 70.6 { return Some("tf".into()); } // Kerguelen
    if lat >= -54.9 && lat <= -53.9 && lng >= -38.0 && lng <= -35.5 { return Some("gs".into()); } // South Georgia
    if lat >= -54.5 && lat <= -54.3 && lng >= 3.2 && lng <= 3.5 { return Some("bv".into()); } // Bouvet Island
    if lat >= 10.2 && lat <= 10.4 && lng >= -109.3 && lng <= -109.1 { return Some("cp".into()); } // Clipperton

    // 1st: Exact R-tree + polygon test
    if let Some(code) = find_country_exact(state, lat, lng) {
        return Some(code);
    }

    // 2nd: Radial search with 16-directional sampling
    let radii = [0.05, 0.1, 0.2, 0.5, 1.0, 2.0];
    let directions: [(f64, f64); 16] = [
        (1.0, 0.0), (0.92, 0.38), (0.71, 0.71), (0.38, 0.92),
        (0.0, 1.0), (-0.38, 0.92), (-0.71, 0.71), (-0.92, 0.38),
        (-1.0, 0.0), (-0.92, -0.38), (-0.71, -0.71), (-0.38, -0.92),
        (0.0, -1.0), (0.38, -0.92), (0.71, -0.71), (0.92, -0.38),
    ];
    for &r in &radii {
        for &(dlat, dlng) in &directions {
            if let Some(code) = find_country_exact(state, lat + dlat * r, lng + dlng * r) {
                return Some(code);
            }
        }
    }

    // 3rd: Nearby airports fallback (1000 km)
    find_country_from_nearby_airports(state, lat, lng, 1000.0)
}

fn find_country_exact(state: &FinderState, lat: f64, lng: f64) -> Option<String> {
    let point = AABB::from_point([lng, lat]);
    for env in state.country_rtree.locate_in_envelope_intersecting(&point) {
        let feature = &state.geojson.features[env.feature_index];
        match feature.geometry.geom_type.as_str() {
            "Polygon" => {
                if let Ok(coords) = serde_json::from_value::<Vec<Vec<Vec<f64>>>>(
                    feature.geometry.coordinates.clone(),
                ) {
                    for ring in &coords {
                        if point_in_polygon(lng, lat, ring) {
                            return Some(env.country_code.clone());
                        }
                    }
                }
            }
            "MultiPolygon" => {
                if let Ok(coords) = serde_json::from_value::<Vec<Vec<Vec<Vec<f64>>>>>(
                    feature.geometry.coordinates.clone(),
                ) {
                    for poly in &coords {
                        for ring in poly {
                            if point_in_polygon(lng, lat, ring) {
                                return Some(env.country_code.clone());
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    None
}

fn find_country_from_nearby_airports(
    state: &FinderState, lat: f64, lng: f64, max_km: f64,
) -> Option<String> {
    let mut best_dist = f64::MAX;
    let mut best_code = None;
    for ap in &state.airports {
        let d = haversine(lat, lng, ap.lat, ap.lng);
        if d <= max_km && d < best_dist {
            best_dist = d;
            best_code = Some(ap.country.to_ascii_lowercase());
        }
    }
    best_code
}

// ---------------------------------------------------------------------------
// Main finder
// ---------------------------------------------------------------------------

/// Find the nearest airport for the given coordinates.
///
/// Returns `(code, name)` where code is `"country.iata"` (e.g. `"kr.gmp"`)
/// and name is `"City, Country"` (e.g. `"Seoul, Korea"`).
pub fn find_nearest_airport(lat: f64, lng: f64) -> Result<(String, String), String> {
    find_nearest_airport_impl(lat, lng)
}

fn find_nearest_airport_impl(lat: f64, lng: f64) -> Result<(String, String), String> {
    let lng = normalize_lng(lng);
    let state = get_state();

    // 1. Find country
    let country_code = find_country_code(state, lat, lng)
        .ok_or("no country found for coordinates")?;

    // 2. Get airports in that country
    let mut airport_indices: &[usize] = state
        .airports_by_country
        .get(&country_code)
        .map(|v| v.as_slice())
        .unwrap_or(&[]);

    // If country has no airports, search nearby countries
    let mut fallback_indices = Vec::new();
    if airport_indices.is_empty() {
        for &radius in &[2000.0, 3000.0, 4000.0] {
            if let Some(nearby_code) = find_country_from_nearby_airports(state, lat, lng, radius) {
                if nearby_code != country_code {
                    if let Some(idx) = state.airports_by_country.get(&nearby_code) {
                        fallback_indices = idx.clone();
                        break;
                    }
                }
            }
        }
        if fallback_indices.is_empty() {
            return Err(format!("no airports found in country {country_code} or nearby"));
        }
        airport_indices = &fallback_indices;
    }

    // 3. Find nearest airport by Haversine distance
    let mut best_dist = f64::MAX;
    let mut best: Option<&Airport> = None;
    for &i in airport_indices {
        let ap = &state.airports[i];
        let d = haversine(lat, lng, ap.lat, ap.lng);
        if d < best_dist {
            best_dist = d;
            best = Some(ap);
        }
    }

    let nearest = best.ok_or("could not find nearest airport")?;

    // 4. Format result
    let code = format!("{}.{}", country_code, nearest.iata.to_ascii_lowercase());

    let country_name = get_country_name(state, &country_code);
    let name = if !nearest.city.is_empty() && nearest.city != nearest.name {
        format!("{}, {}", nearest.city, country_name)
    } else {
        format!("{}, {}", nearest.name, country_name)
    };

    Ok((code, name))
}

fn get_country_name(state: &FinderState, code: &str) -> String {
    let upper = code.to_ascii_uppercase();
    for f in &state.geojson.features {
        if let Some(ref iso) = f.properties.iso_a2 {
            if iso.to_ascii_uppercase() == upper {
                if let Some(ref name) = f.properties.name {
                    return name.clone();
                }
            }
        }
    }
    upper
}

// ---------------------------------------------------------------------------
// C FFI
// ---------------------------------------------------------------------------

/// Find the nearest airport for the given coordinates.
///
/// Returns a JSON C string: `{"code":"kr.icn","name":"Seoul, South Korea"}`
/// or `{"error":"..."}` on failure.
///
/// The caller must free the returned string with `airport_finder_free`.
#[no_mangle]
pub extern "C" fn airport_finder_find(lat: f64, lng: f64) -> *mut c_char {
    let json = match find_nearest_airport_impl(lat, lng) {
        Ok((code, name)) => {
            format!(
                r#"{{"code":"{}","name":"{}"}}"#,
                code,
                name.replace('\\', "\\\\").replace('"', "\\\""),
            )
        }
        Err(e) => {
            format!(r#"{{"error":"{}"}}"#, e.replace('"', "\\\""))
        }
    };
    CString::new(json).unwrap_or_default().into_raw()
}

/// Free a string previously returned by `airport_finder_find`.
#[no_mangle]
pub extern "C" fn airport_finder_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}
