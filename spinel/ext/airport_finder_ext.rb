# The entries a host calls into when the port is built as a library
# (spinel --ext-init, see build.sh). Answers are numbers, so nothing is
# formatted per call: an airport is its index in the embedded data (the
# host asks airport_record for its fields once), a country code an id
# (string gives the code). An answer with more than one value leaves them
# for out_index / out_km.
#
# Run as a program (spinel or ruby), the block at the bottom prints a few
# answers; it is also where Spinel learns the entries' argument types.

require_relative "../airport_finder"

module AirportFinderExt
  # AirportSet handles: index into this array, nil once freed.
  @sets = []
  # The last answer's values, read back with out_index / out_km.
  @out = AirportFinder::Hits.new([0.0], [0])
  # Strings handed out by id, and the ids by string.
  @strings = [""]
  @string_ids = { "" => 0 }

  # find_nearest_airport's airport. Raises AirportFinder::Error.
  def self.find(lat, lng)
    AirportFinder.nearest_airport_index(lat, lng)
  end

  # country_at's code as a string id, or -1 for nil.
  def self.country_at(lat, lng)
    code = AirportFinder.country_at(lat, lng)
    code.nil? ? -1 : intern(code.to_s)
  end

  def self.string(id)
    raise AirportFinder::Error, "no such string: #{id}" unless id >= 0 && id < @strings.size
    @strings[id].to_s
  end

  # The airport with this IATA code (any case), or -1.
  def self.airport(iata)
    AirportFinder.airport_index(iata)
  end

  # Airport i's code, iata, name ("City, Country"), airport_name, city and
  # country (lowercase), joined by "\x1f"; out_km(0) and out_km(1) are its
  # lat and lng.
  def self.airport_record(i)
    st = AirportFinder.state
    raise AirportFinder::Error, "no such airport: #{i}" unless i >= 0 && i < st.ap_iata.size
    @out = AirportFinder::Hits.new([st.ap_lat[i], st.ap_lng[i]], [i])
    name = AirportFinder.display_name(st, st.ap_city[i], st.ap_name[i], st.ap_country[i])
    [st.code_of(i), st.ap_iata[i], name, st.ap_name[i], st.ap_city[i], st.ap_country[i].downcase].join("\x1f")
  end

  # A new AirportSet of `count` IATA codes, joined by "\x1f"; its handle.
  def self.set_new(codes, count)
    list = []
    codes.split("\x1f", -1).each { |c| list << c } if count > 0
    @sets << AirportFinder::AirportSet.new(list)
    @sets.size - 1
  end

  def self.set_free(h)
    @sets[h] = nil
    0
  end

  def self.set_size(h)
    set_of(h).size
  end

  def self.set_include(h, iata)
    set_of(h).include?(iata) ? 1 : 0
  end

  # Codes the embedded data does not know, each followed by "\x1f".
  def self.set_missing(h)
    set_of(h).missing.map { |c| c + "\x1f" }.join
  end

  # AirportSet#nearest: how many airports it found. out_index(k) is the
  # k-th, out_km(k) its distance. has_country / has_max say whether country
  # / max_km were given.
  def self.set_nearest(h, lat, lng, country, has_country, max_km, has_max, limit)
    @out = set_of(h).nearest_hits(lat, lng, limit, has_country == 1, country, has_max == 1, max_km)
    @out.size
  end

  # AirportSet#resolve: the airport, or -1 for nil. out_km(0) is its
  # distance, out_index(1) the resolution (0 nearest, 1 same_country,
  # 2 nearby_foreign) and out_index(2) find_nearest_airport's airport.
  def self.set_resolve(h, lat, lng, foreign_max_km, has_max)
    r = set_of(h).resolve_at(lat, lng, has_max == 1, foreign_max_km)
    how = r.resolution == :nearest ? 0 : r.resolution == :same_country ? 1 : 2
    @out = AirportFinder::Hits.new([r.distance_km], [r.index, how, r.nearest])
    r.index
  end

  def self.out_index(k)
    @out.i[k].to_i
  end

  def self.out_km(k)
    @out.d[k].to_f
  end

  def self.set_of(h)
    set = h >= 0 && h < @sets.size ? @sets[h] : nil
    raise AirportFinder::Error, "no such AirportSet: #{h}" if set.nil?
    set
  end

  def self.intern(s)
    id = @string_ids.fetch(s, -1).to_i
    if id < 0
      id = @strings.size
      @strings << s
      @string_ids[s] = id
    end
    id
  end
end

if __FILE__ == $0
  i = AirportFinderExt.find(37.5665, 126.978)
  puts AirportFinderExt.airport_record(i), AirportFinderExt.out_km(0), AirportFinderExt.out_km(1)
  puts AirportFinderExt.string(AirportFinderExt.country_at(42.5, 1.52)), AirportFinderExt.country_at(0.0, -150.0)
  puts AirportFinderExt.airport("djt"), AirportFinderExt.airport("zzz")
  h = AirportFinderExt.set_new("HYD\x1fBOM\x1fSIN\x1fZZZ", 4)
  puts AirportFinderExt.set_size(h), AirportFinderExt.set_include(h, "hyd"), AirportFinderExt.set_missing(h).inspect
  n = AirportFinderExt.set_nearest(h, 19.07, 72.87, "in", 1, 0.0, 0, 2)
  n.times { |k| puts "#{AirportFinderExt.out_index(k)} #{AirportFinderExt.out_km(k)}" }
  puts AirportFinderExt.set_resolve(h, 17.385, 78.486, 300.0, 1), AirportFinderExt.out_km(0), AirportFinderExt.out_index(1), AirportFinderExt.out_index(2)
  puts AirportFinderExt.set_free(h)

  # The port's own API, which no entry calls: typed here, or its untyped
  # parameters would widen the code it shares with the entries.
  p AirportFinder.find_nearest_airport(37.5665, 126.978), AirportFinder.airport("djt").iata
  set = AirportFinder::AirportSet.new(["HYD", "BOM"])
  some = n > 0
  p set.nearest(19.07, 72.87, limit: 2, country: some ? "in" : nil, max_km: some ? nil : 5.0).size
  p set.resolve(17.385, 78.486, foreign_max_km: some ? 300.0 : nil).nearest_code
end
