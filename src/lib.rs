//! Airport finder — given (lat, lng), returns the nearest airport code.
//!
//! Rust rewrite of the Go `airport_finder` project.
//! Exposes a C FFI function for Python ctypes integration.
//!
//! Beyond [`find_nearest_airport`], [`AirportSet`] searches a caller-chosen
//! subset of the airports — e.g. only those the caller has data for — and
//! [`airport`] / [`country_at`] expose the lookups the finder is built on.

use std::collections::{HashMap, HashSet};
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

/// An embedded airport.
#[derive(Debug, Deserialize, Clone)]
pub struct Airport {
    /// IATA code, uppercase (`"ICN"`).
    pub iata: String,
    pub name: String,
    pub city: String,
    /// ISO 3166-1 alpha-2 country of the airport itself, uppercase (`"KR"`).
    pub country: String,
    pub lat: f64,
    pub lng: f64,
}

impl Airport {
    /// `"country.iata"` in lowercase, under the airport's own country
    /// (`"es.leu"`) — the code [`find_nearest_airport`] returns.
    pub fn code(&self) -> String {
        format!("{}.{}", self.country.to_ascii_lowercase(), self.iata.to_ascii_lowercase())
    }

    /// `"City, Country"` — the form [`find_nearest_airport`] returns.
    pub fn display_name(&self) -> String {
        display_name(get_state(), self, &self.country)
    }
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
    airports_by_iata: HashMap<String, usize>,         // uppercase IATA -> airport index
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

    // Build airports-by-country and airports-by-IATA indices
    let mut airports_by_country: HashMap<String, Vec<usize>> = HashMap::new();
    let mut airports_by_iata: HashMap<String, usize> = HashMap::new();
    for (i, ap) in airports.iter().enumerate() {
        airports_by_country
            .entry(ap.country.to_ascii_lowercase())
            .or_default()
            .push(i);
        airports_by_iata.insert(ap.iata.to_ascii_uppercase(), i);
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
        airports_by_iata,
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

/// Validate coordinates and wrap the longitude into [-180, 180].
///
/// Rejects non-finite values and |lat| > 90. Wrapping uses `rem_euclid`:
/// repeatedly subtracting 360 never terminates for `inf`, nor for huge
/// finite values like `1e300` where `lng - 360.0 == lng`.
fn checked_coords(lat: f64, lng: f64) -> Result<(f64, f64), String> {
    if !lat.is_finite() || !lng.is_finite() || lat.abs() > 90.0 {
        return Err("invalid coordinates".into());
    }
    Ok((lat, normalize_lng(lng)))
}

fn normalize_lng(lng: f64) -> f64 {
    if (-180.0..=180.0).contains(&lng) {
        lng
    } else {
        (lng + 180.0).rem_euclid(360.0) - 180.0
    }
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
/// and name is `"City, Country"` (e.g. `"Seoul, Korea"`), both under the
/// airport's own country. For coordinates in a country without airports the
/// answer comes from a neighbour — Andorra gives `"es.leu"` — and
/// [`country_at`] tells the country the coordinates are in (`"ad"`).
/// (Before 0.3.0 both used that country: `"ad.leu"`, `"…, Andorra"`.)
/// Errors on non-finite coordinates or |lat| > 90.
pub fn find_nearest_airport(lat: f64, lng: f64) -> Result<(String, String), String> {
    find_nearest_airport_impl(lat, lng)
}

fn find_nearest_airport_impl(lat: f64, lng: f64) -> Result<(String, String), String> {
    let (lat, lng) = checked_coords(lat, lng)?;
    let state = get_state();
    let (_, nearest) = nearest_in_country(state, lat, lng)?;
    let nearest = &state.airports[nearest];
    Ok((nearest.code(), nearest.display_name()))
}

/// The country containing (lat, lng) and the index of its nearest airport —
/// or, for a country without airports, of the nearest one in a nearby country.
/// Expects coordinates already passed through [`checked_coords`].
fn nearest_in_country(state: &FinderState, lat: f64, lng: f64) -> Result<(String, usize), String> {
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
    let mut best: Option<usize> = None;
    for &i in airport_indices {
        let ap = &state.airports[i];
        let d = haversine(lat, lng, ap.lat, ap.lng);
        if d < best_dist {
            best_dist = d;
            best = Some(i);
        }
    }

    let nearest = best.ok_or("could not find nearest airport")?;
    Ok((country_code, nearest))
}

/// `"City, Country"` for *airport*, named after *country_code* (any case).
fn display_name(state: &FinderState, airport: &Airport, country_code: &str) -> String {
    let country_name = get_country_name(state, country_code);
    if !airport.city.is_empty() && airport.city != airport.name {
        format!("{}, {}", airport.city, country_name)
    } else {
        format!("{}, {}", airport.name, country_name)
    }
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
// Lookups
// ---------------------------------------------------------------------------

/// The embedded airport with this IATA code (any case), if any.
pub fn airport(iata: &str) -> Option<&'static Airport> {
    let state = get_state();
    state
        .airports_by_iata
        .get(&iata.trim().to_ascii_uppercase())
        .map(|&i| &state.airports[i])
}

/// Lowercase ISO 3166-1 alpha-2 code of the country containing (lat, lng).
/// Matches the prefix of [`find_nearest_airport`]'s code except in countries
/// without airports (`"ad"` vs `"es.leu"`). `None` for invalid coordinates
/// or open ocean far from any country.
pub fn country_at(lat: f64, lng: f64) -> Option<String> {
    let (lat, lng) = checked_coords(lat, lng).ok()?;
    find_country_code(get_state(), lat, lng)
}

// ---------------------------------------------------------------------------
// Searching a subset of airports
// ---------------------------------------------------------------------------

/// An airport found by [`AirportSet::nearest`] / [`AirportSet::resolve`].
#[derive(Debug, Clone, Copy)]
pub struct Nearby {
    pub airport: &'static Airport,
    pub distance_km: f64,
}

/// How [`AirportSet::resolve`] picked its airport.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolution {
    /// [`find_nearest_airport`]'s own answer is in the set (and domestic).
    Nearest,
    /// The nearest set airport in the country containing the coordinates.
    SameCountry,
    /// That country has no set airport: the nearest one across a border.
    NearbyForeign,
}

impl Resolution {
    pub fn as_str(&self) -> &'static str {
        match self {
            Resolution::Nearest => "nearest",
            Resolution::SameCountry => "same_country",
            Resolution::NearbyForeign => "nearby_foreign",
        }
    }
}

/// The result of [`AirportSet::resolve`].
#[derive(Debug, Clone)]
pub struct Resolved {
    pub airport: &'static Airport,
    pub distance_km: f64,
    pub resolution: Resolution,
    /// [`find_nearest_airport`]'s code for the coordinates (`"in.bpm"`),
    /// whether or not that airport is in the set or domestic.
    pub nearest_code: String,
}

/// A subset of the embedded airports to search within — for instance the
/// airports a caller holds data for. Build it once and reuse it.
#[derive(Debug, Clone)]
pub struct AirportSet {
    members: HashSet<usize>,
    all: Vec<usize>,
    by_country: HashMap<String, Vec<usize>>, // lowercase ISO -> airport indices
    missing: Vec<String>,
}

impl AirportSet {
    /// A set of the airports with these IATA codes (any case). Codes the
    /// embedded data does not know are skipped and listed in [`Self::missing`].
    pub fn new<I, S>(iata_codes: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let state = get_state();
        let mut set = AirportSet {
            members: HashSet::new(),
            all: Vec::new(),
            by_country: HashMap::new(),
            missing: Vec::new(),
        };
        for code in iata_codes {
            let key = code.as_ref().trim().to_ascii_uppercase();
            match state.airports_by_iata.get(&key) {
                Some(&i) => {
                    if set.members.insert(i) {
                        set.all.push(i);
                        set.by_country
                            .entry(state.airports[i].country.to_ascii_lowercase())
                            .or_default()
                            .push(i);
                    }
                }
                None => {
                    if !set.missing.contains(&key) {
                        set.missing.push(key);
                    }
                }
            }
        }
        set
    }

    /// Every embedded airport.
    pub fn all() -> Self {
        Self::new(get_state().airports.iter().map(|ap| ap.iata.as_str()))
    }

    pub fn len(&self) -> usize {
        self.all.len()
    }

    pub fn is_empty(&self) -> bool {
        self.all.is_empty()
    }

    pub fn contains(&self, iata: &str) -> bool {
        let state = get_state();
        state
            .airports_by_iata
            .get(&iata.trim().to_ascii_uppercase())
            .is_some_and(|i| self.members.contains(i))
    }

    /// Codes passed to [`Self::new`] that the embedded data does not know
    /// (uppercase, in the order given).
    pub fn missing(&self) -> &[String] {
        &self.missing
    }

    /// Up to `limit` airports of the set nearest to (lat, lng), closest
    /// first. `country` (ISO alpha-2, any case) keeps only that country's
    /// airports; `max_km` drops any farther away.
    pub fn nearest(
        &self,
        lat: f64,
        lng: f64,
        country: Option<&str>,
        max_km: Option<f64>,
        limit: usize,
    ) -> Result<Vec<Nearby>, String> {
        let (lat, lng) = checked_coords(lat, lng)?;
        let pool = match country {
            Some(c) => self.by_country.get(&c.to_ascii_lowercase()).map_or(&[][..], |v| v.as_slice()),
            None => &self.all,
        };
        Ok(scan(lat, lng, pool, max_km, limit))
    }

    /// Pick the set's airport for someone at (lat, lng):
    ///
    /// 1. [`Resolution::Nearest`] — [`find_nearest_airport`]'s answer, if it
    ///    is in the set and in the country containing the coordinates.
    /// 2. [`Resolution::SameCountry`] — else the nearest set airport in the
    ///    country containing the coordinates, however far.
    /// 3. [`Resolution::NearbyForeign`] — else (that country has none) the
    ///    nearest set airport anywhere, within `foreign_max_km` if given.
    ///
    /// `Ok(None)` when none applies, including open ocean with no country.
    /// Errors only on invalid coordinates.
    pub fn resolve(
        &self,
        lat: f64,
        lng: f64,
        foreign_max_km: Option<f64>,
    ) -> Result<Option<Resolved>, String> {
        let (lat, lng) = checked_coords(lat, lng)?;
        let state = get_state();
        let Ok((country, nearest)) = nearest_in_country(state, lat, lng) else {
            return Ok(None);
        };
        let nearest_code = state.airports[nearest].code();

        // A country without airports gets find_nearest_airport's answer from
        // a neighbour up to 4000 km away — that counts as foreign, so it is
        // only taken within `foreign_max_km` below.
        let ap = &state.airports[nearest];
        let domestic = ap.country.eq_ignore_ascii_case(&country);
        let (hit, resolution) = if domestic && self.members.contains(&nearest) {
            let hit = Nearby { airport: ap, distance_km: haversine(lat, lng, ap.lat, ap.lng) };
            (Some(hit), Resolution::Nearest)
        } else if let Some(&hit) = self
            .nearest(lat, lng, Some(&country), None, 1)?
            .first()
        {
            (Some(hit), Resolution::SameCountry)
        } else {
            let hit = self.nearest(lat, lng, None, foreign_max_km, 1)?.first().copied();
            (hit, Resolution::NearbyForeign)
        };
        Ok(hit.map(|h| Resolved {
            airport: h.airport,
            distance_km: h.distance_km,
            resolution,
            nearest_code,
        }))
    }
}

/// The `limit` airports of `pool` nearest to (lat, lng), closest first.
fn scan(lat: f64, lng: f64, pool: &[usize], max_km: Option<f64>, limit: usize) -> Vec<Nearby> {
    let state = get_state();
    let mut hits: Vec<(f64, usize)> = pool
        .iter()
        .map(|&i| (haversine(lat, lng, state.airports[i].lat, state.airports[i].lng), i))
        .filter(|&(d, _)| max_km.is_none_or(|m| d <= m))
        .collect();
    let by_distance = |a: &(f64, usize), b: &(f64, usize)| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1));
    if limit == 0 {
        return Vec::new();
    }
    if hits.len() > limit {
        hits.select_nth_unstable_by(limit - 1, by_distance);
        hits.truncate(limit);
    }
    hits.sort_unstable_by(by_distance);
    hits.into_iter()
        .map(|(d, i)| Nearby { airport: &state.airports[i], distance_km: d })
        .collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_seoul() {
        let (code, name) = find_nearest_airport(37.5665, 126.978).unwrap();
        assert!(code.starts_with("kr."), "{code}");
        assert!(name.ends_with("Korea"), "{name}");
    }

    #[test]
    fn rejects_invalid_coordinates() {
        for (lat, lng) in [
            (1.0, f64::NEG_INFINITY),
            (1.0, f64::INFINITY),
            (f64::INFINITY, 1.0),
            (f64::NAN, 1.0),
            (1.0, f64::NAN),
            (95.0, 10.0),
        ] {
            assert_eq!(find_nearest_airport(lat, lng), Err("invalid coordinates".into()));
            assert_eq!(country_at(lat, lng), None);
        }
    }

    #[test]
    fn huge_longitude_wraps_instead_of_hanging() {
        // `lng -= 360.0` never changes 1e300: the old loop spun forever.
        assert!(find_nearest_airport(1.0, 1e300).is_ok());
        assert_eq!(
            find_nearest_airport(37.5665, 126.978 + 360.0),
            find_nearest_airport(37.5665, 126.978),
        );
        assert_eq!(
            find_nearest_airport(37.5665, 126.978 - 720.0),
            find_nearest_airport(37.5665, 126.978),
        );
    }

    #[test]
    fn longitude_in_range_is_untouched() {
        assert_eq!(normalize_lng(180.0), 180.0);
        assert_eq!(normalize_lng(-180.0), -180.0);
        assert_eq!(normalize_lng(190.0), -170.0);
        assert_eq!(normalize_lng(-190.0), 170.0);
    }

    #[test]
    fn airport_lookup() {
        let icn = airport("icn").unwrap();
        assert_eq!(icn.country, "KR");
        assert_eq!(icn.code(), "kr.icn");
        assert!(airport("zzz").is_none());
    }

    #[test]
    fn palm_beach_is_djt() {
        // IATA recoded PBI -> DJT on 2026-08-18.
        assert!(airport("PBI").is_none());
        assert_eq!(airport("DJT").unwrap().city, "West Palm Beach");
        assert_eq!(find_nearest_airport(26.68, -80.09).unwrap().0, "us.djt");
    }

    #[test]
    fn new_airports_are_known() {
        for iata in ["WSI", "LHL", "LSG", "DXN", "HWR", "AVR", "CSW", "TVT", "LTH"] {
            assert!(airport(iata).is_some(), "{iata}");
        }
    }

    #[test]
    fn display_name_uses_airport_country() {
        assert_eq!(airport("SJC").unwrap().display_name(), "San Jose, United States");
    }

    #[test]
    fn country_at_matches_code_prefix_where_there_are_airports() {
        assert_eq!(country_at(37.5665, 126.978).as_deref(), Some("kr"));
        assert!(find_nearest_airport(37.5665, 126.978).unwrap().0.starts_with("kr."));
    }

    #[test]
    fn answer_from_a_neighbour_keeps_its_own_country() {
        // Andorra and South Georgia have no airports; the answer is the
        // neighbour's airport, named for the neighbour (0.2: ad.leu, gs.psy).
        assert_eq!(country_at(42.5, 1.52).as_deref(), Some("ad"));
        let (code, name) = find_nearest_airport(42.5, 1.52).unwrap();
        assert_eq!(code, "es.leu");
        assert!(name.ends_with(", Spain"), "{name}");
        assert_eq!(country_at(-54.28, -36.5).as_deref(), Some("gs"));
        assert_eq!(
            find_nearest_airport(-54.28, -36.5).unwrap(),
            ("fk.psy".to_string(), "Stanley, Falkland Is.".to_string()),
        );
    }

    #[test]
    fn set_tracks_missing_codes() {
        let set = AirportSet::new(["icn", "GMP", "gmp", "ZZZ"]);
        assert_eq!(set.len(), 2);
        assert!(set.contains("ICN") && set.contains("gmp"));
        assert!(!set.contains("PUS"));
        assert_eq!(set.missing(), ["ZZZ"]);
    }

    #[test]
    fn nearest_orders_and_filters() {
        let set = AirportSet::all();
        let hits = set.nearest(37.5665, 126.978, Some("KR"), None, 3).unwrap();
        assert_eq!(hits.len(), 3);
        assert!(hits.windows(2).all(|w| w[0].distance_km <= w[1].distance_km));
        assert!(hits.iter().all(|h| h.airport.country == "KR"));
        assert!(set.nearest(37.5665, 126.978, None, Some(1.0), 5).unwrap().is_empty());
        assert!(set.nearest(37.5665, 126.978, Some("zz"), None, 5).unwrap().is_empty());
        assert!(set.nearest(37.5665, 126.978, None, None, 0).unwrap().is_empty());
        assert!(set.nearest(f64::NAN, 0.0, None, None, 1).is_err());
    }

    #[test]
    fn resolve_direct_hit() {
        let r = AirportSet::all().resolve(37.5665, 126.978, None).unwrap().unwrap();
        assert_eq!(r.resolution, Resolution::Nearest);
        assert_eq!(r.nearest_code, r.airport.code());
    }

    #[test]
    fn resolve_same_country() {
        // Hyderabad: nearest is Begumpet (BPM), which the set leaves out.
        let set = AirportSet::new(["HYD", "BOM", "SIN"]);
        let r = set.resolve(17.385, 78.486, None).unwrap().unwrap();
        assert_eq!(r.nearest_code, "in.bpm");
        assert_eq!(r.airport.iata, "HYD");
        assert_eq!(r.resolution, Resolution::SameCountry);
        assert!(r.distance_km < 50.0);
    }

    #[test]
    fn resolve_nearby_foreign_within_limit() {
        // Andorra has no set airport; Barcelona is ~150 km away.
        let set = AirportSet::new(["BCN", "ICN"]);
        let r = set.resolve(42.5, 1.52, Some(300.0)).unwrap().unwrap();
        assert_eq!(r.airport.iata, "BCN");
        assert_eq!(r.resolution, Resolution::NearbyForeign);
        assert!(set.resolve(42.5, 1.52, Some(50.0)).unwrap().is_none());
    }

    #[test]
    fn resolve_treats_cross_border_answer_as_foreign() {
        // Andorra has no airports: find_nearest_airport answers with Spain's
        // LEU. Even with LEU in the set it is a foreign pick.
        let set = AirportSet::new(["LEU"]);
        let r = set.resolve(42.5, 1.52, Some(300.0)).unwrap().unwrap();
        assert_eq!(r.nearest_code, "es.leu");
        assert_eq!(r.resolution, Resolution::NearbyForeign);
        // South Georgia: the answer is the Falklands' PSY, ~1450 km away —
        // past the limit, so nothing.
        let set = AirportSet::new(["PSY"]);
        assert_eq!(find_nearest_airport(-54.28, -36.5).unwrap().0, "fk.psy");
        assert!(set.resolve(-54.28, -36.5, Some(300.0)).unwrap().is_none());
    }

    #[test]
    fn resolve_rejects_invalid_coordinates() {
        assert!(AirportSet::all().resolve(f64::INFINITY, 0.0, None).is_err());
    }
}
