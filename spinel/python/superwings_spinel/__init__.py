"""The superwings API, backed by the Spinel build of airport_finder.

A drop-in for the ``superwings`` package (the crate's PyO3 binding): the
same functions, the same dicts, the same answers, computed by the Ruby port
in ``spinel/`` compiled to a shared library (``spinel/ext/build.sh``).

    from superwings_spinel import AirportSet, find_nearest_airport

The library answers with numbers: an airport is its index in the embedded
data, whose dict is made here the first time it comes up, and a country
code an id. Nothing is formatted or parsed per call.

The library is ``libairport_finder_spinel.so`` next to this file, or the
path in ``$SUPERWINGS_SPINEL_LIB``.
"""

from __future__ import annotations

import ctypes
import os
import threading
from collections.abc import Iterable
from pathlib import Path
from typing import Any

__all__ = ["AirportSet", "airport", "country_at", "find_nearest_airport"]

_lib = ctypes.CDLL(os.environ.get("SUPERWINGS_SPINEL_LIB")
                   or str(Path(__file__).with_name("libairport_finder_spinel.so")))

_i64 = ctypes.c_longlong
_f64 = ctypes.c_double
_str = ctypes.c_char_p
_text = ctypes.c_void_p  # a malloc'd string answer, freed with af_free
for _name, _args, _ret in [
    ("af_find", [_f64, _f64], _i64),
    ("af_country_at", [_f64, _f64], _i64),
    ("af_string", [_i64], _text),
    ("af_airport", [_str], _i64),
    ("af_airport_record", [_i64], _text),
    ("af_set_new", [_str, _i64], _i64),
    ("af_set_free", [_i64], _i64),
    ("af_set_size", [_i64], _i64),
    ("af_set_include", [_i64, _str], _i64),
    ("af_set_missing", [_i64], _text),
    ("af_set_nearest", [_i64, _f64, _f64, _str, _i64, _f64, _i64, _i64], _i64),
    ("af_set_resolve", [_i64, _f64, _f64, _f64, _i64], _i64),
    ("af_buffers", [ctypes.POINTER(_i64), ctypes.POINTER(_f64), _i64], None),
    ("af_free", [_text], None),
    ("af_error", [], ctypes.c_char_p),
]:
    getattr(_lib, _name).argtypes = _args
    getattr(_lib, _name).restype = _ret
_find, _country_at = _lib.af_find, _lib.af_country_at
_set_nearest, _set_resolve = _lib.af_set_nearest, _lib.af_set_resolve

_RAISED = -2  # a number answer after a Ruby raise; af_error() has the message
_RESOLUTIONS = ("nearest", "same_country", "nearby_foreign")

# The Spinel runtime takes one call at a time, and the buffers hold the last
# call's extra values: both only under this lock. Reentrant, so that an
# AirportSet freed by the garbage collector inside it can still get in.
_lock = threading.RLock()
_cap = 0
_index: Any = None
_km: Any = None


def _reserve(n: int) -> None:
    """Buffers for n values of each kind. Under _lock."""
    global _cap, _index, _km
    if n > _cap:
        _cap = max(n, 2 * _cap, 16)
        _index = (_i64 * _cap)()
        _km = (_f64 * _cap)()
        _lib.af_buffers(_index, _km, _cap)


with _lock:
    _reserve(16)


def _error() -> ValueError:
    """The last raise's message. Under _lock."""
    return ValueError(_lib.af_error().decode())


def _take(ptr: int | None) -> str:
    """A string answer. Under _lock."""
    if not ptr:
        raise _error()
    try:
        return ctypes.string_at(ptr).decode()
    finally:
        _lib.af_free(ptr)


# Airport dicts by index and country codes by id, as they come up. Airport
# dicts are copied before they reach a caller.
_airports: dict[int, dict[str, Any]] = {}
_strings: dict[int, str] = {}


def _airport(i: int) -> dict[str, Any]:
    d = _airports.get(i)
    if d is None:
        with _lock:
            fields = _take(_lib.af_airport_record(i)).split("\x1f")
            lat, lng = _km[0], _km[1]
        code, iata, name, airport_name, city, country = fields
        d = _airports[i] = {"code": code, "iata": iata, "name": name, "airport_name": airport_name,
                            "city": city, "country": country, "lat": lat, "lng": lng}
    return d


def _string(i: int) -> str:
    s = _strings.get(i)
    if s is None:
        with _lock:
            s = _strings[i] = _take(_lib.af_string(i))
    return s


def _bytes(s: str) -> bytes:
    if not isinstance(s, str):
        raise TypeError(f"expected str, not {type(s).__name__}")
    return s.encode()


def find_nearest_airport(lat: float, lng: float) -> dict[str, str]:
    """``{"code": "kr.gmp", "name": "Seoul, Korea"}``, or ``{"error": ...}``."""
    with _lock:
        i = _find(float(lat), float(lng))
        if i < 0:
            return {"error": _lib.af_error().decode()}
    d = _airport(i)
    return {"code": d["code"], "name": d["name"]}


def country_at(lat: float, lng: float) -> str | None:
    """Lowercase ISO 3166-1 alpha-2 code of the country containing (lat, lng),
    or None for invalid coordinates / open ocean."""
    with _lock:
        i = _country_at(float(lat), float(lng))
        if i == _RAISED:
            raise _error()
    return None if i < 0 else _string(i)


def airport(iata: str) -> dict[str, Any] | None:
    """The airport with this IATA code (any case) as a dict, or None."""
    code = _bytes(iata)
    with _lock:
        i = _lib.af_airport(code)
        if i == _RAISED:
            raise _error()
    return None if i < 0 else dict(_airport(i))


class AirportSet:
    """A subset of the airports to search within, built from IATA codes.

    Codes the embedded data does not know are skipped and listed in
    ``missing``. Build once and reuse.
    """

    def __init__(self, iata_codes: Iterable[str]) -> None:
        if isinstance(iata_codes, str):
            raise TypeError("expected an iterable of IATA codes, not a str")
        codes = list(iata_codes)
        for c in codes:
            _bytes(c)
            if "\x1f" in c or "\x00" in c:
                raise ValueError(f"not an IATA code: {c!r}")
        with _lock:
            handle = _lib.af_set_new("\x1f".join(codes).encode(), len(codes))
            if handle == _RAISED:
                raise _error()
            self._handle = handle
            self._size = _lib.af_set_size(handle)

    def __del__(self) -> None:
        handle = getattr(self, "_handle", None)
        if handle is not None:
            try:
                with _lock:
                    _lib.af_set_free(handle)
            except Exception:  # interpreter shutdown
                pass

    @property
    def missing(self) -> list[str]:
        """IATA codes (uppercase) the embedded data does not know."""
        with _lock:
            text = _take(_lib.af_set_missing(self._handle))
        return text.split("\x1f")[:-1]

    def __len__(self) -> int:
        return self._size

    def __contains__(self, iata: str) -> bool:
        code = _bytes(iata)
        with _lock:
            found = _lib.af_set_include(self._handle, code)
            if found == _RAISED:
                raise _error()
        return found == 1

    def __repr__(self) -> str:
        return f"AirportSet({len(self)} airports, {len(self.missing)} missing)"

    def nearest(self, lat: float, lng: float, *, country: str | None = None,
                max_km: float | None = None, limit: int = 1) -> list[dict[str, Any]]:
        """Up to ``limit`` set airports nearest to (lat, lng), closest first, as
        airport dicts plus ``distance_km``. ``country`` (ISO alpha-2, any
        case) keeps one country's airports; ``max_km`` drops farther ones.
        Raises ValueError for invalid coordinates."""
        if limit < 0:
            raise OverflowError("can't convert negative int to unsigned")
        code = b"" if country is None else _bytes(country)
        with _lock:
            if limit > _cap and self._size > _cap:
                _reserve(min(limit, self._size))
            n = _set_nearest(self._handle, float(lat), float(lng), code, country is not None,
                             0.0 if max_km is None else float(max_km), max_km is not None, limit)
            if n == _RAISED:
                raise _error()
            found, km = _index[:n], _km[:n]
        return [{**_airport(i), "distance_km": d} for i, d in zip(found, km)]

    def resolve(self, lat: float, lng: float, *,
                foreign_max_km: float | None = None) -> dict[str, Any] | None:
        """The set's airport for someone at (lat, lng): "nearest", else
        "same_country", else "nearby_foreign" within ``foreign_max_km``.

        Returns an airport dict plus ``distance_km``, ``resolution`` and
        ``nearest_code``, or None. Raises ValueError for invalid coordinates."""
        with _lock:
            i = _set_resolve(self._handle, float(lat), float(lng),
                             0.0 if foreign_max_km is None else float(foreign_max_km),
                             foreign_max_km is not None)
            if i == _RAISED:
                raise _error()
            if i < 0:
                return None
            km, how, nearest = _km[0], _index[1], _index[2]
        return {**_airport(i), "distance_km": km, "resolution": _RESOLUTIONS[how],
                "nearest_code": _airport(nearest)["code"]}
