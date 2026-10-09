# The crate's unit tests (src/lib.rs `mod tests`), ported. Runs under
# Spinel and CRuby:
#
#   make test        # spinel
#   ruby test.rb     # CRuby

require_relative "airport_finder"

$failures = 0
$checks = 0

def check(cond, what)
  $checks += 1
  return if cond
  $failures += 1
  puts "FAIL: #{what}"
end

def check_eq(actual, expected, what)
  check(actual == expected, "#{what}: expected #{expected.inspect}, got #{actual.inspect}")
end

def raises?(lat, lng)
  AirportFinder.find_nearest_airport(lat, lng)
  false
rescue AirportFinder::Error => e
  e.message == "invalid coordinates"
end

def code_at(lat, lng)
  AirportFinder.find_nearest_airport(lat, lng)[0]
end

NAN = 0.0 / 0.0
INF = Float::INFINITY

def test_finds_seoul
  code, name = AirportFinder.find_nearest_airport(37.5665, 126.978)
  check(code.start_with?("kr."), "finds_seoul code #{code}")
  check(name.end_with?("Korea"), "finds_seoul name #{name}")
end

def test_rejects_invalid_coordinates
  [[1.0, -INF], [1.0, INF], [INF, 1.0], [NAN, 1.0], [1.0, NAN], [95.0, 10.0]].each do |pt|
    check(raises?(pt[0], pt[1]), "rejects #{pt.inspect}")
    check(AirportFinder.country_at(pt[0], pt[1]).nil?, "country_at rejects #{pt.inspect}")
  end
end

def test_huge_longitude_wraps_instead_of_hanging
  check(!AirportFinder.find_nearest_airport(1.0, 1e300).empty?, "1e300 wraps")
  seoul = AirportFinder.find_nearest_airport(37.5665, 126.978)
  check_eq(AirportFinder.find_nearest_airport(37.5665, 126.978 + 360.0), seoul, "+360")
  check_eq(AirportFinder.find_nearest_airport(37.5665, 126.978 - 720.0), seoul, "-720")
end

def test_longitude_in_range_is_untouched
  check_eq(AirportFinder.normalize_lng(180.0), 180.0, "180")
  check_eq(AirportFinder.normalize_lng(-180.0), -180.0, "-180")
  check_eq(AirportFinder.normalize_lng(190.0), -170.0, "190")
  check_eq(AirportFinder.normalize_lng(-190.0), 170.0, "-190")
end

def test_airport_lookup
  icn = AirportFinder.airport("icn")
  check_eq(icn.country, "KR", "icn country")
  check_eq(icn.code, "kr.icn", "icn code")
  check(AirportFinder.airport("zzz").nil?, "zzz unknown")
end

def test_palm_beach_is_djt
  # IATA recoded PBI -> DJT on 2026-08-18.
  check(AirportFinder.airport("PBI").nil?, "PBI gone")
  check_eq(AirportFinder.airport("DJT").city, "West Palm Beach", "DJT city")
  check_eq(code_at(26.68, -80.09), "us.djt", "palm beach")
end

def test_new_airports_are_known
  %w[WSI LHL LSG DXN HWR AVR CSW TVT LTH].each do |iata|
    check(!AirportFinder.airport(iata).nil?, "known #{iata}")
  end
end

def test_display_name_uses_airport_country
  check_eq(AirportFinder.airport("SJC").display_name, "San Jose, United States", "SJC display_name")
end

def test_country_at_matches_code_prefix_where_there_are_airports
  check_eq(AirportFinder.country_at(37.5665, 126.978), "kr", "country_at seoul")
  check(code_at(37.5665, 126.978).start_with?("kr."), "code prefix seoul")
end

def test_enclaves_are_their_own_country
  # Holes in the country around them, and Vatican City, drawn over Italy
  # without a hole (Natural Earth's polygon sits ~1.7 km west).
  [[-29.31, 27.48, "ls"], [43.94, 12.45, "sm"], [39.85, 70.58, "tj"], [41.9017, 12.4332, "va"]].each do |c|
    check_eq(AirportFinder.country_at(c[0], c[1]), c[2], "enclave (#{c[0]}, #{c[1]})")
  end
  check_eq(code_at(-29.31, 27.48), "ls.msu", "Maseru")
  # Around them, the country around them.
  check_eq(AirportFinder.country_at(-29.0, 25.0), "za", "around Lesotho")
  check_eq(AirportFinder.country_at(43.8, 12.0), "it", "around San Marino")
  check_eq(AirportFinder.country_at(40.5, 72.8), "kg", "around Vorukh")
end

def test_answer_from_a_neighbour_keeps_its_own_country
  # Andorra and South Georgia have no airports; the answer is the
  # neighbour's airport, named for the neighbour (0.2: ad.leu, gs.psy).
  check_eq(AirportFinder.country_at(42.5, 1.52), "ad", "andorra country")
  code, name = AirportFinder.find_nearest_airport(42.5, 1.52)
  check_eq(code, "es.leu", "andorra code")
  check(name.end_with?(", Spain"), "andorra name #{name}")
  check_eq(AirportFinder.country_at(-54.28, -36.5), "gs", "south georgia country")
  check_eq(AirportFinder.find_nearest_airport(-54.28, -36.5), ["fk.psy", "Stanley, Falkland Is."], "south georgia")
end

def test_set_tracks_missing_codes
  set = AirportFinder::AirportSet.new(%w[icn GMP gmp ZZZ])
  check_eq(set.size, 2, "set size")
  check(set.include?("ICN") && set.include?("gmp"), "set members")
  check(!set.include?("PUS"), "set non-member")
  check_eq(set.missing, ["ZZZ"], "set missing")
end

def test_nearest_orders_and_filters
  set = AirportFinder::AirportSet.all
  hits = set.nearest(37.5665, 126.978, limit: 3, country: "KR")
  check_eq(hits.size, 3, "3 hits")
  check(hits[0].distance_km <= hits[1].distance_km && hits[1].distance_km <= hits[2].distance_km, "ordered")
  check(hits.all? { |h| h.airport.country == "KR" }, "all KR")
  check(set.nearest(37.5665, 126.978, limit: 5, max_km: 1.0).empty?, "max_km 1")
  check(set.nearest(37.5665, 126.978, limit: 5, country: "zz").empty?, "country zz")
  check(set.nearest(37.5665, 126.978, limit: 0).empty?, "limit 0")
  rejected = false
  begin
    set.nearest(NAN, 0.0)
  rescue AirportFinder::Error
    rejected = true
  end
  check(rejected, "nearest rejects NaN")
end

def test_resolve_direct_hit
  r = AirportFinder::AirportSet.all.resolve(37.5665, 126.978)
  check_eq(r.resolution, :nearest, "direct resolution")
  check_eq(r.nearest_code, r.airport.code, "direct code")
end

def test_resolve_same_country
  # Hyderabad: nearest is Begumpet (BPM), which the set leaves out.
  set = AirportFinder::AirportSet.new(%w[HYD BOM SIN])
  r = set.resolve(17.385, 78.486)
  check_eq(r.nearest_code, "in.bpm", "hyderabad nearest_code")
  check_eq(r.airport.iata, "HYD", "hyderabad airport")
  check_eq(r.resolution, :same_country, "hyderabad resolution")
  check(r.distance_km < 50.0, "hyderabad distance")
end

def test_resolve_nearby_foreign_within_limit
  # Andorra has no set airport; Barcelona is ~150 km away.
  set = AirportFinder::AirportSet.new(%w[BCN ICN])
  r = set.resolve(42.5, 1.52, foreign_max_km: 300.0)
  check_eq(r.airport.iata, "BCN", "andorra BCN")
  check_eq(r.resolution, :nearby_foreign, "andorra resolution")
  check(set.resolve(42.5, 1.52, foreign_max_km: 50.0).nil?, "andorra 50 km")
end

def test_resolve_treats_cross_border_answer_as_foreign
  # Andorra has no airports: find_nearest_airport answers with Spain's
  # LEU. Even with LEU in the set it is a foreign pick.
  set = AirportFinder::AirportSet.new(%w[LEU])
  r = set.resolve(42.5, 1.52, foreign_max_km: 300.0)
  check_eq(r.nearest_code, "es.leu", "LEU nearest_code")
  check_eq(r.resolution, :nearby_foreign, "LEU resolution")
  # South Georgia: the answer is the Falklands' PSY, ~1450 km away —
  # past the limit, so nothing.
  set = AirportFinder::AirportSet.new(%w[PSY])
  check_eq(code_at(-54.28, -36.5), "fk.psy", "south georgia code")
  check(set.resolve(-54.28, -36.5, foreign_max_km: 300.0).nil?, "PSY beyond limit")
end

def test_resolve_rejects_invalid_coordinates
  rejected = false
  begin
    AirportFinder::AirportSet.all.resolve(INF, 0.0)
  rescue AirportFinder::Error
    rejected = true
  end
  check(rejected, "resolve rejects inf")
end

# Deterministic numbers in [lo, hi): xorshift32, which needs no 64-bit wrap.
class Rand
  def initialize(seed)
    @s = seed
  end

  def next(lo, hi)
    s = @s
    s = (s ^ (s << 13)) & 0xFFFF_FFFF
    s ^= s >> 17
    s = (s ^ (s << 5)) & 0xFFFF_FFFF
    @s = s
    lo + (hi - lo) * s.to_f / 4_294_967_296.0
  end
end

# Ray-casting point-in-polygon over the whole of ring r: the reference
# Rings#contains is checked against.
def point_in_polygon(lng, lat, rings, r)
  xs = rings.xs
  ys = rings.ys
  base = rings.first[r]
  n = rings.n[r]
  inside = false
  return false if n == 0
  j = n - 1
  i = 0
  while i < n
    yi = ys[base + i]
    yj = ys[base + j]
    if (yi > lat) != (yj > lat) && lng < (xs[base + j] - xs[base + i]) * (lat - yi) / (yj - yi) + xs[base + i]
      inside = !inside
    end
    j = i
    i += 1
  end
  inside
end

def test_ring_contains_matches_ray_cast
  rand = Rand.new(7)
  bad = 0
  rings = AirportFinder.state.rings
  r = 0
  while r < rings.size
    min_lng = rings.min_lng[r]
    min_lat = rings.min_lat[r]
    max_lng = rings.max_lng[r]
    max_lat = rings.max_lat[r]
    w = max_lng - min_lng
    h = max_lat - min_lat
    lngs = []
    lats = []
    50.times do
      lngs << rand.next(min_lng - w * 0.1, max_lng + w * 0.1)
      lats << rand.next(min_lat - h * 0.1, max_lat + h * 0.1)
    end
    # Vertex latitudes sit on band boundaries and edge ends.
    n = rings.n[r]
    step = n / 20 + 1
    k = 0
    while k < n
      x = rings.xs[rings.first[r] + k]
      y = rings.ys[rings.first[r] + k]
      lngs << x << x - 1e-7 << x + 1e-7 << rand.next(min_lng, max_lng)
      lats << y << y << y << y
      k += step
    end
    lngs.each_with_index do |lng, p|
      lat = lats[p]
      bad += 1 if rings.contains(r, lng, lat) != point_in_polygon(lng, lat, rings, r)
    end
    r += 1
  end
  check(rings.size > 1000, "rings checked: #{rings.size}")
  check_eq(bad, 0, "ring contains vs ray cast mismatches")
end

def check_airport_index(alat, alng, label)
  all = (0...alat.size).to_a
  index = AirportFinder::AirportIndex.new(alat, alng, all)
  rand = Rand.new(11)
  lats = []
  lngs = []
  100.times do
    lats << rand.next(-90.0, 90.0)
    lngs << rand.next(-180.0, 180.0)
  end
  # On an airport, and at an airport's antipode.
  step = alat.size / 20
  k = 0
  while k < alat.size
    lats << alat[k] << -alat[k]
    lngs << alng[k] << AirportFinder.normalize_lng(alng[k] + 180.0)
    k += step
  end
  cases = [[false, 0.0, 1], [false, 0.0, 7], [true, 500.0, 3], [true, INF, 1], [true, 30000.0, 2]]
  bad = 0
  lats.each_with_index do |lat, q|
    lng = lngs[q]
    # Every distance, sorted as the full scan sorted them.
    dist = all.map { |i| AirportFinder.haversine(lat, lng, alat[i], alng[i]) }
    scan = all.sort { |a, b| AirportFinder.cmp_dist(dist[a], a, dist[b], b) }
    cases.each do |c|
      has_max = c[0]
      max_km = c[1]
      limit = c[2]
      expected = scan.select { |i| !has_max || dist[i] <= max_km }.first(limit)
      got = index.nearest(lat, lng, has_max, max_km, limit)
      same = got.size == expected.size
      expected.each_with_index do |i, p|
        next unless same
        d = got.d[p]
        same = false unless got.i[p] == i && (d == dist[i] || (d.nan? && dist[i].nan?))
      end
      unless same
        bad += 1
        puts "  #{label}: (#{lat}, #{lng}) #{c.inspect}" if bad <= 5
      end
    end
  end
  check_eq(bad, 0, "#{label} mismatches")
end

def test_airport_index_matches_full_scan
  st = AirportFinder.state
  check_airport_index(st.ap_lat, st.ap_lng, "airport_index_matches_full_scan")
end

def test_airport_index_breaks_ties_by_index
  # Airports sharing a position tie exactly; the lower index wins.
  st = AirportFinder.state
  lats = []
  lngs = []
  2.times do
    k = 0
    while k < st.ap_lat.size
      lats << st.ap_lat[k]
      lngs << st.ap_lng[k]
      k += 40
    end
  end
  check_airport_index(lats, lngs, "airport_index_breaks_ties_by_index")
end

test_finds_seoul
test_rejects_invalid_coordinates
test_huge_longitude_wraps_instead_of_hanging
test_longitude_in_range_is_untouched
test_airport_lookup
test_palm_beach_is_djt
test_new_airports_are_known
test_display_name_uses_airport_country
test_country_at_matches_code_prefix_where_there_are_airports
test_enclaves_are_their_own_country
test_answer_from_a_neighbour_keeps_its_own_country
test_set_tracks_missing_codes
test_nearest_orders_and_filters
test_resolve_direct_hit
test_resolve_same_country
test_resolve_nearby_foreign_within_limit
test_resolve_treats_cross_border_answer_as_foreign
test_resolve_rejects_invalid_coordinates
test_ring_contains_matches_ray_cast
test_airport_index_matches_full_scan
test_airport_index_breaks_ties_by_index

if $failures == 0
  puts "ok: 21 tests, #{$checks} checks"
else
  puts "FAILED: #{$failures} of #{$checks} checks"
  exit 1
end
