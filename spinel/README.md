# airport_finder on Spinel

A Ruby port of the crate (`src/lib.rs`) for [Spinel](https://github.com/matz/spinel),
Matz's Ruby AOT compiler, benchmarked against the crate. The same Ruby also runs
on CRuby.

Same embedded data, same algorithms (latitude-banded ray cast, R-tree of
bounding boxes, best-first nearest neighbour over unit vectors), same
answers: on 150,403 points the crate and the port agree bit for bit on all
six queries (`find_nearest_airport`, `country_at`, two `AirportSet#nearest`,
two `AirportSet#resolve`). Where two countries hold a point, both pick the
one whose ring around it is smaller, so the answer never rests on how either
R-tree happens to be packed.

Not ported: the C FFI (`airport_finder_find` / `_free`). Spinel builds
executables.

## Files

| | |
|---|---|
| `airport_finder.rb` | the port |
| `test.rb` | the crate's 21 unit tests, ported |
| `bench.rb` | benchmark / dump harness (Ruby side) |
| `../examples/compare.rs` | the same harness for the crate |
| `gen_data.rb` | writes `embedded_data.rb`: `data/*.json` as string constants, as `include_str!` embeds them |
| `gen_points.rb` | writes the query points (`points/`) |
| `compare.rb` | compares two dumps |
| `run_bench.sh`, `summarize.rb` | interleaved benchmark rounds and their summary |
| `ext/` | the port as a C library: `airport_finder_ext.rb` (the entries), `shim.c`, `build.sh` |
| `python/` | the `superwings-spinel` PyPI package: the `superwings` API over that library (ctypes) |

## Running

```sh
ruby gen_data.rb && ruby gen_points.rb
SPINEL=~/projects/spinel/spinel     # a build of github.com/matz/spinel

$SPINEL test.rb -o build/test --jobs=1 && build/test    # or: ruby test.rb
$SPINEL bench.rb -o build/bench --jobs=1

# Same answers as the crate?
cargo run --release --example compare -- dump points/verify.txt points/subset.txt > out/verify.rust.tsv
build/bench dump points/verify.txt points/subset.txt > out/verify.spinel.tsv
ruby compare.rb out/verify.rust.tsv out/verify.spinel.tsv

# Benchmarks
SPINEL=$SPINEL ROUNDS=5 ./run_bench.sh
```

From Python, as a drop-in for `superwings` (the `superwings-spinel` package):

```sh
SPINEL=$SPINEL ext/build.sh    # python/csrc/ (generated C + Spinel's runtime) and the library in place
PYTHONPATH=python python3 -c 'from superwings_spinel import find_nearest_airport; print(find_nearest_airport(37.5665, 126.978))'
python/build_dists.sh          # python/dist/: sdist, macOS universal2 and manylinux2014 wheels (Docker)
uv publish python/dist/*
```

The sdist carries the generated C and Spinel's runtime, so it builds with a
C compiler alone; the wheels are `py3-none-<platform>`, as the library is
loaded with ctypes rather than as an extension module.

It passes superwings' own tests and tsip's `tests/test_airport_finder.py`
when imported as `superwings`, and gives superwings 0.3.0's answers to
tsip's calls on all 150,403 points except the 84 the enclave fix changes
(0.3.0 bundles the crate's 0.3.1). Built from this tree, calls cost
1.1–1.4× superwings' from Python (5 µs near airports, 18 µs anywhere);
0.1.1 on PyPI predates the second pass below and costs 1.2–1.8×. That is
about the compiled code's own ratio: the library answers with airport
indices and distances
(`ext/airport_finder_ext.rb`, `ext/shim.c`), and the wrapper makes each
airport's dict once. Passing JSON, as 0.1.0 did, cost 2–4×. The library
takes one call at a time; the wrapper holds a lock.

`--jobs=1` compiles the generated C as one unit. Spinel's default splits a
unit of 4 MB or more, which the embedded data makes this one.

## Results

Apple M1 (Mac mini, 16 GB), macOS 26, 2026-10-13. Rust 1.93.1 (release,
LTO); Spinel at master 18d7cfb6d (`spinel --version`: 2026.09.12+8985)
with Apple clang 21, `-O2`;
CRuby 4.0.7. The crate is 0.3.1 with the enclave fix. Each cell is the
median over 5 interleaved rounds of each round's median per call; 10,000
points per set. The machine was lightly loaded; rounds of the compiled
code varied by 3% at most.

| | Rust | Spinel | CRuby + YJIT | CRuby | Spinel / Rust | YJIT / Spinel |
|---|---|---|---|---|---|---|
| find_nearest_airport, near airports | 3.26 µs | 3.65 µs | 39.3 µs | 109 µs | 1.12× | 10.79× |
| find_nearest_airport, anywhere | 12.4 µs | 14.3 µs | 152 µs | 532 µs | 1.15× | 10.61× |
| country_at, anywhere | 11.7 µs | 13.2 µs | 146 µs | 520 µs | 1.13× | 11.06× |
| AirportSet.all.nearest(limit 5), anywhere | 2.85 µs | 3.76 µs | 32.2 µs | 79.1 µs | 1.32× | 8.55× |
| subset.resolve(300 km), near airports | 3.59 µs | 4.12 µs | 38.0 µs | 117 µs | 1.15× | 9.23× |
| AirportSet.all (build) | 4.0 ms | 7.0 ms | 41.0 ms | 72.6 ms | 1.77× | 5.86× |
| first call (parse data, build indices) | 24.5 ms | 33.4 ms | 244 ms | 824 ms | 1.36× | 7.31× |
| max RSS after first call | 33.7 MB | 27.8 MB | 46.4 MB | 44.5 MB | 0.83× | |

"Near airports" is within ±0.25° of a random airport; "anywhere" is uniform
over the sphere, about 70% ocean, where the radial search and the nearby
airport fallback run. Binaries, data embedded: 6.1 MB each. Build: 5.4 s
for the crate and harness after a touch (LTO), 3.0 s for Spinel.

On x86-64 the gap is narrower for the country lookups and wider for
`nearest`: AMD Ryzen 5 6600H, Linux, gcc 14.2, the same Spinel master,
pinned to one core, medians of 21 interleaved rounds (Rust and Spinel
only):

| | Rust | Spinel | Spinel / Rust |
|---|---|---|---|
| find_nearest_airport, near airports | 3.19 µs | 3.81 µs | 1.19× |
| find_nearest_airport, anywhere | 11.8 µs | 12.9 µs | 1.09× |
| country_at, anywhere | 11.0 µs | 11.3 µs | 1.03× |
| AirportSet.all.nearest(limit 5), anywhere | 3.00 µs | 4.40 µs | 1.46× |
| subset.resolve(300 km), near airports | 3.66 µs | 4.54 µs | 1.24× |
| AirportSet.all (build) | 4.2 ms | 7.0 ms | 1.69× |

Against 6b6f4602c, the master of the previous numbers here, timed in the
same rounds: `AirportSet.all` takes 8.0 → 7.0 ms, as the IATA Hash is now a
`String → Integer` Hash with no annotation (matz/spinel#8783), and the
lookups take 1–5% less, as an index sum `x + c` in a cached loop is now
checked for overflow only off the in-range path (matz/spinel#8828).

Before the crate's cec4cfd its answers differed on x86-64 at ten airports'
antipodes: haversine is NaN there, x86-64's default NaN has its sign
bit set, and `total_cmp` listed that airport first. Both now list it last.

## Writing Ruby for Spinel

The first port kept a Ruby object per ring and per airport and ran 1.6–6×
slower than the crate. The Spinel of then stored an Array (or Hash) of
objects boxed, so every access through one took the dynamically typed path.
Moving the hot data into flat typed arrays (`Array[Float]`, `Array[Integer]`)
made every lookup that finds a country 2.5–3.2× faster, with no change to
the algorithms. `spinel --warn-widen` names each slot that falls back to
the boxed path, and why.

What it took, rechecked on Spinel master 4a9e1029e (2026-10-12) with small
programs and their generated C, and with the first port built again:

- No Array or Hash of objects on a hot path; still worth it. Rings, airport
  coordinates and search hits are parallel arrays indexed by number. An
  Array of objects is now a typed array of pointers, read without a box,
  but a Hash of objects is still boxed, and the loop cache below holds
  Integer, Float and String arrays only. Built on 4a9e1029e, the first port
  is still 2.2–3.1× slower than this one on the lookups that find a
  country, and 1.3× on `nearest(5)`. It also lacks the second pass below.
- No Hash of Arrays (`(h[k] ||= []) << i`); still a boxed Hash of boxed
  Arrays. Grouping here is a `String → Integer` Hash plus offsets into one
  Integer array.
- No longer needed: filling an array in the method that creates it. An
  empty `[]` passed to another method to fill stayed untyped; it is now
  typed by what that method pushes, in a local or an ivar.
- A method that returns an Integer and ends in a `raise` with no value
  after it returns `Integer?`: an Integer with a nil flag beside it, not a
  box. A value after the raise makes it a plain Integer.
- `Hash#[]` returns `Integer?`, likewise an Integer with a nil flag;
  `fetch(key, -1).to_i` makes it a plain Integer.

A second pass, again with the same algorithms, took another 7–26% off
(`find_nearest_airport` 5.52 → 4.52 µs, `country_at` 22.64 → 16.82 µs,
`nearest(5)` 4.63 → 4.29 µs, Spinel da5972974). Spinel keeps an Integer,
Float or String array's data and length in hand across a loop only when the
loop calls none of the program's own methods; then an element read in range
is a compare and a load. Operators, indexing, `size`, attribute reads and
`Math` keep it. Otherwise every read goes through the array again. On
da5972974 a `return` in the loop dropped it too (fixed in 16663cf16, from
#8310). Since c8392966d a `while` inside the loop reads through the outer
loop's cache, and `times`, `upto` / `downto`, `step` and an Integer Range's
`each` keep one as a `while` does. What it took, on da5972974 (not
rechecked):

- Search a tree with an explicit stack, not by recursion, and test a node's
  children in a call-free loop before pushing them.
- Collect candidates first (the rings whose box holds the point), then test
  them, so the collecting loop is call-free.
- Keep scratch arrays (the search stack, the heap, the hit list) in the
  object and reuse them, rather than making them per query.
- Read hot arrays through instance variables, not locals: a local that
  holds an array is a GC root, which keeps it in memory, not in a register.
- Keep the numbers read together in one array: a point's longitude and
  latitude side by side, a ring's box and band in one record.
