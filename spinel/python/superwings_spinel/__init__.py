"""The superwings API, backed by the Spinel build of airport_finder.

A drop-in for the ``superwings`` package (the crate's PyO3 binding): the
same functions, the same dicts, the same answers, computed by the Ruby port
in ``spinel/`` compiled to a shared library (``spinel/ext/build.sh``).

    from superwings_spinel import AirportSet, find_nearest_airport

The library is ``libairport_finder_spinel.so`` next to this file, or the
path in ``$SUPERWINGS_SPINEL_LIB``.
"""

from __future__ import annotations

import ctypes
import json
import os
import threading
from collections.abc import Iterable
from pathlib import Path
from typing import Any

__all__ = ["AirportSet", "airport", "country_at", "find_nearest_airport"]

_lib = ctypes.CDLL(os.environ.get("SUPERWINGS_SPINEL_LIB")
                   or str(Path(__file__).with_name("libairport_finder_spinel.so")))

_str = ctypes.c_char_p
_i64 = ctypes.c_longlong
_f64 = ctypes.c_double
_ENTRIES = {
    "af_find": [_f64, _f64],
    "af_country_at": [_f64, _f64],
    "af_airport": [_str],
    "af_set_new": [_str, _i64],
    "af_set_free": [_i64],
    "af_set_size": [_i64],
    "af_set_include": [_i64, _str],
    "af_set_missing": [_i64],
    "af_set_nearest": [_i64, _f64, _f64, _str, _i64, _f64, _i64, _i64],
    "af_set_resolve": [_i64, _f64, _f64, _f64, _i64],
}
for _name, _args in _ENTRIES.items():
    getattr(_lib, _name).argtypes = _args
    getattr(_lib, _name).restype = ctypes.c_void_p  # freed with af_free
_lib.af_free.argtypes = [ctypes.c_void_p]
_lib.af_free.restype = None
_lib.af_error.argtypes = []
_lib.af_error.restype = ctypes.c_char_p

# The Spinel runtime takes one call at a time.
_lock = threading.Lock()


def _call(name: str, *args: Any) -> Any:
    """The entry's JSON answer, decoded; ValueError for a Ruby raise."""
    with _lock:
        ptr = getattr(_lib, name)(*args)
        if not ptr:
            raise ValueError(_lib.af_error().decode())
        try:
            text = ctypes.string_at(ptr).decode()
        finally:
            _lib.af_free(ptr)
    return json.loads(text)


def _bytes(s: str) -> bytes:
    if not isinstance(s, str):
        raise TypeError(f"expected str, not {type(s).__name__}")
    return s.encode()


def find_nearest_airport(lat: float, lng: float) -> dict[str, str]:
    """``{"code": "kr.gmp", "name": "Seoul, Korea"}``, or ``{"error": ...}``."""
    return _call("af_find", float(lat), float(lng))


def country_at(lat: float, lng: float) -> str | None:
    """Lowercase ISO 3166-1 alpha-2 code of the country containing (lat, lng),
    or None for invalid coordinates / open ocean."""
    return _call("af_country_at", float(lat), float(lng))


def airport(iata: str) -> dict[str, Any] | None:
    """The airport with this IATA code (any case) as a dict, or None."""
    return _call("af_airport", _bytes(iata))


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
        self._handle = int(_call("af_set_new", "\x1f".join(codes).encode(), len(codes)))

    def __del__(self) -> None:
        handle = getattr(self, "_handle", None)
        if handle is not None:
            try:
                _call("af_set_free", handle)
            except Exception:  # interpreter shutdown
                pass

    @property
    def missing(self) -> list[str]:
        """IATA codes (uppercase) the embedded data does not know."""
        return _call("af_set_missing", self._handle)

    def __len__(self) -> int:
        return int(_call("af_set_size", self._handle))

    def __contains__(self, iata: str) -> bool:
        return _call("af_set_include", self._handle, _bytes(iata))

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
        return _call("af_set_nearest", self._handle, float(lat), float(lng),
                     b"" if country is None else _bytes(country), int(country is not None),
                     0.0 if max_km is None else float(max_km), int(max_km is not None), limit)

    def resolve(self, lat: float, lng: float, *,
                foreign_max_km: float | None = None) -> dict[str, Any] | None:
        """The set's airport for someone at (lat, lng): "nearest", else
        "same_country", else "nearby_foreign" within ``foreign_max_km``.

        Returns an airport dict plus ``distance_km``, ``resolution`` and
        ``nearest_code``, or None. Raises ValueError for invalid coordinates."""
        return _call("af_set_resolve", self._handle, float(lat), float(lng),
                     0.0 if foreign_max_km is None else float(foreign_max_km),
                     int(foreign_max_km is not None))
