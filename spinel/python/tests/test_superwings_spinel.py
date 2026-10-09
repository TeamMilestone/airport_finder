"""superwings' own tests (superwings_airport/tests), run against the
Spinel build, plus what the enclave fix changed."""

import math
import threading

import pytest

from superwings_spinel import AirportSet, airport, country_at, find_nearest_airport


def test_find_nearest_airport():
    result = find_nearest_airport(37.5665, 126.978)
    assert result["code"].startswith("kr.")
    assert result["name"].endswith("Korea")


@pytest.mark.parametrize("lat,lng", [
    (1.0, -math.inf), (1.0, math.inf), (math.nan, 1.0), (95.0, 10.0),
])
def test_invalid_coordinates(lat, lng):
    assert find_nearest_airport(lat, lng) == {"error": "invalid coordinates"}
    assert country_at(lat, lng) is None


def test_huge_longitude_does_not_hang():
    assert "code" in find_nearest_airport(1.0, 1e300)


def test_airport_lookup():
    djt = airport("djt")
    assert djt["code"] == "us.djt"
    assert djt["name"] == "West Palm Beach, United States"
    assert airport("PBI") is None
    assert airport("zzz") is None


def test_country_at():
    assert country_at(37.5665, 126.978) == "kr"
    assert country_at(42.5, 1.52) == "ad"


def test_answer_from_a_neighbour_keeps_its_own_country():
    assert find_nearest_airport(-54.28, -36.5) == {
        "code": "fk.psy", "name": "Stanley, Falkland Is."}
    assert country_at(-54.28, -36.5) == "gs"
    assert find_nearest_airport(42.5, 1.52)["code"] == "es.leu"


def test_enclaves_are_their_own_country():
    assert country_at(-29.31, 27.48) == "ls"  # Maseru; superwings 0.3.0: "za"
    assert find_nearest_airport(-29.31, 27.48)["code"] == "ls.msu"
    assert country_at(43.94, 12.45) == "sm"
    assert country_at(41.9017, 12.4332) == "va"
    assert country_at(-29.0, 25.0) == "za"


def test_set_basics():
    s = AirportSet(["icn", "GMP", "gmp", "ZZZ"])
    assert len(s) == 2
    assert "ICN" in s and "gmp" in s and "PUS" not in s
    assert s.missing == ["ZZZ"]
    assert len(AirportSet({"ICN", "GMP"})) == 2
    assert len(AirportSet([" icn\n"])) == 1
    assert len(AirportSet([])) == 0
    with pytest.raises(TypeError):
        AirportSet("ICN")
    with pytest.raises(TypeError):
        AirportSet([1])


def test_nearest():
    s = AirportSet(["HYD", "BOM", "BCN"])
    hits = s.nearest(19.07, 72.87, country="IN", limit=2)
    assert [h["iata"] for h in hits] == ["BOM", "HYD"]
    assert hits[0]["distance_km"] < hits[1]["distance_km"]
    assert s.nearest(19.07, 72.87, max_km=1.0) == []
    assert s.nearest(19.07, 72.87, country="zz") == []
    with pytest.raises(ValueError):
        s.nearest(math.nan, 0.0)


def test_resolve():
    s = AirportSet(["HYD", "BOM", "LEU"])
    hit = s.resolve(17.385, 78.486, foreign_max_km=300)
    assert (hit["iata"], hit["resolution"], hit["nearest_code"]) == ("HYD", "same_country", "in.bpm")
    hit = s.resolve(19.09, 72.87)
    assert (hit["iata"], hit["resolution"]) == ("BOM", "nearest")
    hit = s.resolve(42.5, 1.52, foreign_max_km=300)
    assert (hit["code"], hit["resolution"], hit["nearest_code"]) == ("es.leu", "nearby_foreign", "es.leu")
    assert AirportSet(["PSY"]).resolve(-54.28, -36.5, foreign_max_km=300) is None
    with pytest.raises(ValueError):
        s.resolve(math.inf, 0.0)


def test_sets_are_freed():
    for _ in range(200):
        assert len(AirportSet(["ICN"])) == 1


def test_threads():
    s = AirportSet(["ICN", "GMP", "HYD"])
    errors = []

    def work():
        try:
            for _ in range(200):
                assert find_nearest_airport(37.5665, 126.978)["code"] == "kr.gmp"
                assert s.resolve(17.385, 78.486)["iata"] == "HYD"
        except Exception as e:  # noqa: BLE001
            errors.append(e)

    threads = [threading.Thread(target=work) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
