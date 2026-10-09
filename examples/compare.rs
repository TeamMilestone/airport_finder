//! Benchmark and dump harness for comparing the crate with its Spinel port
//! (spinel/bench.rb does the same calls in the same order, printing the
//! same format).
//!
//! ```text
//! cargo run --release --example compare -- dump POINTS SUBSET
//! cargo run --release --example compare -- init
//! cargo run --release --example compare -- run NEAR ANYWHERE SUBSET [BUDGET_MS] [MIN_PASSES]
//! ```

use std::hint::black_box;
use std::io::{BufWriter, Write};
use std::time::Instant;

use airport_finder::{country_at, find_nearest_airport, AirportSet, Nearby, Resolved};

fn read_points(path: &str) -> (Vec<f64>, Vec<f64>) {
    let text = std::fs::read_to_string(path).expect("points file");
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let mut f = l.split_whitespace().map(|v| v.parse::<f64>().expect("number"));
            (f.next().unwrap(), f.next().unwrap())
        })
        .unzip()
}

fn read_codes(path: &str) -> Vec<String> {
    let text = std::fs::read_to_string(path).expect("subset file");
    text.lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect()
}

fn find_text(lat: f64, lng: f64) -> String {
    match find_nearest_airport(lat, lng) {
        Ok((code, name)) => format!("{code}|{name}"),
        Err(e) => format!("!{e}"),
    }
}

fn nearby_text(hits: &[Nearby]) -> String {
    hits.iter()
        .map(|h| format!("{}:{}", h.airport.iata, h.distance_km))
        .collect::<Vec<_>>()
        .join(",")
}

fn resolved_text(r: Option<Resolved>) -> String {
    match r {
        None => "-".into(),
        Some(r) => format!("{}:{}:{}:{}", r.airport.iata, r.distance_km, r.resolution.as_str(), r.nearest_code),
    }
}

fn dump(points: &str, subset: &str) {
    let (lats, lngs) = read_points(points);
    let all = AirportSet::all();
    let subset = AirportSet::new(read_codes(subset));
    let mut out = BufWriter::new(std::io::stdout().lock());
    for (&lat, &lng) in lats.iter().zip(&lngs) {
        writeln!(
            out,
            "{}\t{}\t{}\t{}\t{}\t{}",
            find_text(lat, lng),
            country_at(lat, lng).unwrap_or_else(|| "-".into()),
            nearby_text(&all.nearest(lat, lng, None, None, 3).unwrap()),
            nearby_text(&all.nearest(lat, lng, None, Some(500.0), 2).unwrap()),
            resolved_text(subset.resolve(lat, lng, Some(300.0)).unwrap()),
            resolved_text(subset.resolve(lat, lng, None).unwrap()),
        )
        .unwrap();
    }
}

/// Runs `f` in passes until `budget_ms` have passed and at least
/// `min_passes` ran; prints the median ns per op.
fn measure(name: &str, ops: usize, budget_ms: u64, min_passes: usize, mut f: impl FnMut() -> usize) {
    let mut times = Vec::new();
    let mut check = 0;
    let start = Instant::now();
    while times.len() < min_passes || start.elapsed().as_millis() < budget_ms as u128 {
        let t0 = Instant::now();
        check = black_box(f());
        times.push(t0.elapsed().as_nanos());
    }
    times.sort_unstable();
    let median = times[times.len() / 2];
    println!("{name}\t{}\t{}\t{check}", median as f64 / ops as f64, times.len());
}

fn run(near: &str, anywhere: &str, subset: &str, budget_ms: u64, min_passes: usize) {
    let (near_lat, near_lng) = read_points(near);
    let (any_lat, any_lng) = read_points(anywhere);
    let codes = read_codes(subset);
    find_nearest_airport(37.5665, 126.978).unwrap(); // initialize

    let find = |lats: &[f64], lngs: &[f64]| {
        let mut sum = 0;
        for (&lat, &lng) in lats.iter().zip(lngs) {
            sum += match find_nearest_airport(black_box(lat), black_box(lng)) {
                Ok((code, _)) => code.len(),
                Err(_) => 1,
            };
        }
        sum
    };
    measure("find_nearest_airport/near_airports", near_lat.len(), budget_ms, min_passes, || find(&near_lat, &near_lng));
    measure("find_nearest_airport/anywhere", any_lat.len(), budget_ms, min_passes, || find(&any_lat, &any_lng));
    measure("country_at/anywhere", any_lat.len(), budget_ms, min_passes, || {
        let mut sum = 0;
        for (&lat, &lng) in any_lat.iter().zip(&any_lng) {
            sum += country_at(black_box(lat), black_box(lng)).map_or(1, |c| c.len());
        }
        sum
    });
    let all = AirportSet::all();
    measure("AirportSet.all.nearest(limit 5)/anywhere", any_lat.len(), budget_ms, min_passes, || {
        let mut sum = 0;
        for (&lat, &lng) in any_lat.iter().zip(&any_lng) {
            sum += all.nearest(black_box(lat), black_box(lng), None, None, 5).unwrap().len();
        }
        sum
    });
    let set = AirportSet::new(&codes);
    measure("subset.resolve(300 km)/near_airports", near_lat.len(), budget_ms, min_passes, || {
        let mut sum = 0;
        for (&lat, &lng) in near_lat.iter().zip(&near_lng) {
            sum += set
                .resolve(black_box(lat), black_box(lng), Some(300.0))
                .unwrap()
                .map_or(1, |r| r.nearest_code.len());
        }
        sum
    });
    measure("AirportSet.all (build)", 1, budget_ms, min_passes, || AirportSet::all().len());
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("dump") => dump(&args[1], &args[2]),
        Some("init") => {
            let t0 = Instant::now();
            black_box(find_nearest_airport(37.5665, 126.978).unwrap());
            println!("{}", t0.elapsed().as_nanos());
        }
        Some("run") => run(
            &args[1],
            &args[2],
            &args[3],
            args.get(4).map_or(2000, |v| v.parse().unwrap()),
            args.get(5).map_or(5, |v| v.parse().unwrap()),
        ),
        _ => {
            eprintln!("usage: compare dump POINTS SUBSET | init | run NEAR ANYWHERE SUBSET [BUDGET_MS] [MIN_PASSES]");
            std::process::exit(2);
        }
    }
}
