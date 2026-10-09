# airport_finder

Find the nearest airport from (lat, lng) coordinates.

Embeds a global airport database (~10,000 airports) and country polygon boundaries at compile time. Uses R-tree spatial indexing for fast country detection and Haversine distance for nearest airport search.

## Features

- **Embedded data** — no external files needed at runtime
- **R-tree spatial index** — O(log n) country detection
- **Ray-casting** point-in-polygon for precise country boundaries
- **16-directional radial search** fallback for edge cases (coastlines, small islands)
- **Special island handling** (Dokdo, Kerguelen, Bouvet, etc.)
- **Subset search** — `AirportSet` finds the nearest airport among the ones you choose
- **Input validation** — non-finite coordinates and |lat| > 90 are rejected; any finite longitude is wrapped
- **C FFI** — usable from Python (ctypes), Elixir (NIF), or any FFI-capable language

## C FFI

Build as a shared library:

```bash
cargo build --release
# produces: target/release/libairport_finder.{dylib,so}
```

```c
// Returns JSON: {"code":"kr.gmp","name":"Seoul, Korea"}
extern char* airport_finder_find(double lat, double lng);
extern void  airport_finder_free(char* ptr);
```

## Python usage

```python
import ctypes, json

lib = ctypes.CDLL("target/release/libairport_finder.dylib")
lib.airport_finder_find.restype = ctypes.c_char_p
lib.airport_finder_find.argtypes = [ctypes.c_double, ctypes.c_double]

result = json.loads(lib.airport_finder_find(37.5665, 126.978))
# {"code": "kr.gmp", "name": "Seoul, Korea"}
```

## Rust usage

```rust
use airport_finder::find_nearest_airport;

let (code, name) = find_nearest_airport(37.5665, 126.978).unwrap();
assert!(code.starts_with("kr."));
```

### Searching a subset

```rust
use airport_finder::{airport, country_at, AirportSet, Resolution};

// Only the airports you have data for. Unknown codes land in `missing()`.
let set = AirportSet::new(["HYD", "BOM", "BCN"]);

// Nearest set airport, preferring the country the user is in:
// Nearest -> SameCountry -> NearbyForeign (within the given km).
let r = set.resolve(17.385, 78.486, Some(300.0)).unwrap().unwrap();
assert_eq!(r.nearest_code, "in.bpm");          // find_nearest_airport's answer
assert_eq!(r.airport.iata, "HYD");             // nearest one in the set
assert_eq!(r.resolution, Resolution::SameCountry);

// k nearest, optionally within one country and/or a radius.
let hits = set.nearest(19.07, 72.87, Some("in"), None, 2).unwrap();

assert_eq!(airport("djt").unwrap().city, "West Palm Beach");
assert_eq!(country_at(42.5, 1.52).as_deref(), Some("ad"));
```

## Output format

- `code`: `country_code.iata_code` (e.g., `kr.gmp`, `us.jfk`, `jp.hnd`)
- `name`: `City, Country` (e.g., `Seoul, Korea`)

Both use the airport's own country. In a country without airports (Andorra,
San Marino, South Georgia, ...) the nearest airport is a neighbour's, so the
code and name are the neighbour's: South Georgia gives `fk.psy`,
`Stanley, Falkland Is.`. Use `country_at(lat, lng)` for the country the
coordinates are in (`gs`).

**Changed in 0.3.0:** earlier versions prefixed the country of the
coordinates instead (`gs.psy`, `Stanley, S. Geo. and S. Sandw. Is.`).
Results only differ in those countries without airports.

## License

MIT
