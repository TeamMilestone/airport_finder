# airport_finder

Find the nearest airport from (lat, lng) coordinates.

Embeds a global airport database (~10,000 airports) and country polygon boundaries at compile time. Uses R-tree spatial indexing for fast country detection and Haversine distance for nearest airport search.

## Features

- **Embedded data** — no external files needed at runtime
- **R-tree spatial index** — O(log n) country detection
- **Ray-casting** point-in-polygon for precise country boundaries
- **16-directional radial search** fallback for edge cases (coastlines, small islands)
- **Special island handling** (Dokdo, Kerguelen, Bouvet, etc.)
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

## Output format

- `code`: `country_code.iata_code` (e.g., `kr.gmp`, `us.jfk`, `jp.hnd`)
- `name`: `City, Country` (e.g., `Seoul, Korea`)

## License

MIT
