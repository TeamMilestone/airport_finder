# superwings-spinel

Find the nearest airport from (lat, lng) coordinates — the
[superwings](https://pypi.org/project/superwings/) API, computed by a Ruby
port of the [airport_finder](https://github.com/TeamMilestone/airport_finder)
crate compiled to native code by [Spinel](https://github.com/matz/spinel),
Matz's Ruby AOT compiler.

```python
from superwings_spinel import AirportSet, airport, country_at, find_nearest_airport

find_nearest_airport(37.5665, 126.978)
# {'code': 'kr.gmp', 'name': 'Seoul, Korea'}

country_at(-29.31, 27.48)
# 'ls'

hubs = AirportSet(["HYD", "BOM", "BCN"])
hubs.resolve(17.385, 78.486, foreign_max_km=300)
# {'code': 'in.hyd', 'iata': 'HYD', 'name': 'Hyderabad, India', ...,
#  'distance_km': 18.09828547178263, 'resolution': 'same_country', 'nearest_code': 'in.bpm'}
hubs.nearest(19.07, 72.87, country="IN", limit=2)
```

Functions, dicts and errors are superwings 0.3.0's: `import superwings_spinel
as superwings` is enough to switch. The answers are the crate's, bit for bit
on 150,403 test points, with one difference from superwings 0.3.0, which
bundles the crate's 0.3.1: an enclave is its own country. Maseru is Lesotho
(`ls`), not South Africa; 0.3.1 answered `za` across all of Lesotho.

## Speed

The Rust wheel is faster, by about as much as the compiled code is. From
Python on an Apple M1 (superwings in parentheses): `find_nearest_airport`
takes 6 µs near airports (3.6 µs) and 25 µs anywhere (14 µs);
`AirportSet.nearest(limit=5)` 8.6 µs (6.6 µs), `resolve` 9 µs (4.6 µs),
`airport` 1 µs (0.8 µs). Loading the data on the first call takes about
33 ms (26 ms).

The library answers with numbers: airports by index, with distances. The
module makes an airport's dict the first time that airport comes up and
hands out copies, so a call formats and parses nothing (0.1.0 passed JSON:
2–4× superwings). The dicts kept come to about 8 MB if every airport has
come up.

## Notes

- The library takes one call at a time; the module serializes calls from
  threads with a lock.
- Wheels carry no Python extension (the library is loaded with ctypes), so
  one wheel per platform serves every Python 3.9+. Elsewhere the sdist
  builds with a C compiler alone.
- `$SUPERWINGS_SPINEL_LIB` points the module at another build of the library.

## License

MIT. The library includes Spinel's runtime (MIT); see THIRD_PARTY_NOTICES.
