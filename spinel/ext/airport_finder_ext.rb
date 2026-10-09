# The entries a host calls into when the port is built as a library
# (spinel --ext-init, see build.sh): scalars and strings in, JSON out, in
# the shapes the superwings Python package returns.
#
# Run as a program (spinel or ruby), the block at the bottom prints a few
# answers; it is also where Spinel learns the entries' argument types.

require_relative "../airport_finder"

module AirportFinderExt
  # AirportSet handles: index into this array, nil once freed.
  @sets = []

  # {"code": ..., "name": ...}, or {"error": ...}.
  def self.find(lat, lng)
    code, name = AirportFinder.find_nearest_airport(lat, lng)
    "{\"code\":#{json_str(code)},\"name\":#{json_str(name)}}"
  rescue AirportFinder::Error => e
    "{\"error\":#{json_str(e.message)}}"
  end

  # The country code, or null.
  def self.country_at(lat, lng)
    code = AirportFinder.country_at(lat, lng)
    code.nil? ? "null" : json_str(code)
  end

  # The airport dict, or null.
  def self.airport(iata)
    ap = AirportFinder.airport(iata)
    ap.nil? ? "null" : "{#{airport_fields(ap)}}"
  end

  # A new AirportSet of `count` IATA codes, joined by "\x1f"; its handle.
  def self.set_new(codes, count)
    list = []
    codes.split("\x1f", -1).each { |c| list << c } if count > 0
    @sets << AirportFinder::AirportSet.new(list)
    (@sets.size - 1).to_s
  end

  def self.set_free(h)
    @sets[h] = nil
    "null"
  end

  def self.set_size(h)
    set_of(h).size.to_s
  end

  def self.set_include(h, iata)
    set_of(h).include?(iata) ? "true" : "false"
  end

  # Codes the embedded data does not know, as a JSON array.
  def self.set_missing(h)
    "[" + set_of(h).missing.map { |c| json_str(c) }.join(",") + "]"
  end

  # AirportSet#nearest as a JSON array of airport dicts with distance_km.
  # has_country / has_max say whether country / max_km were given.
  def self.set_nearest(h, lat, lng, country, has_country, max_km, has_max, limit)
    hits = set_of(h).nearest(lat, lng, limit: limit,
                                       country: has_country == 1 ? country : nil,
                                       max_km: has_max == 1 ? max_km : nil)
    "[" + hits.map { |n| "{#{airport_fields(n.airport)},\"distance_km\":#{json_float(n.distance_km)}}" }.join(",") + "]"
  end

  # AirportSet#resolve as an airport dict with distance_km, resolution and
  # nearest_code, or null.
  def self.set_resolve(h, lat, lng, foreign_max_km, has_max)
    r = set_of(h).resolve(lat, lng, foreign_max_km: has_max == 1 ? foreign_max_km : nil)
    return "null" if r.nil?
    "{#{airport_fields(r.airport)},\"distance_km\":#{json_float(r.distance_km)}," \
      "\"resolution\":#{json_str(r.resolution.to_s)},\"nearest_code\":#{json_str(r.nearest_code)}}"
  end

  def self.set_of(h)
    set = h >= 0 && h < @sets.size ? @sets[h] : nil
    raise AirportFinder::Error, "no such AirportSet: #{h}" if set.nil?
    set
  end

  # superwings' airport dict: code, iata, name ("City, Country"),
  # airport_name, city, country (lowercase), lat, lng.
  def self.airport_fields(ap)
    "\"code\":#{json_str(ap.code)},\"iata\":#{json_str(ap.iata)}," \
      "\"name\":#{json_str(ap.display_name)},\"airport_name\":#{json_str(ap.name)}," \
      "\"city\":#{json_str(ap.city)},\"country\":#{json_str(ap.country.downcase)}," \
      "\"lat\":#{json_float(ap.lat)},\"lng\":#{json_float(ap.lng)}"
  end

  # Float#to_s is the shortest round-trip form, so the host reads back the
  # same double. Python's json reads NaN and Infinity too.
  def self.json_float(f)
    f.to_s
  end

  def self.json_str(s)
    out = +"\""
    run = 0
    i = 0
    n = s.bytesize
    while i < n
      c = s.getbyte(i)
      if c == 34 || c == 92 || c < 32
        out << s.byteslice(run, i - run)
        out << (c == 34 ? "\\\"" : c == 92 ? "\\\\" : format("\\u%04x", c))
        run = i + 1
      end
      i += 1
    end
    out << s.byteslice(run, n - run)
    out << "\""
    out
  end
end

if __FILE__ == $0
  puts AirportFinderExt.find(37.5665, 126.978)
  puts AirportFinderExt.country_at(42.5, 1.52)
  puts AirportFinderExt.airport("djt")
  h = AirportFinderExt.set_new("HYD\x1fBOM\x1fSIN\x1fZZZ", 4).to_i
  puts AirportFinderExt.set_size(h), AirportFinderExt.set_include(h, "hyd"), AirportFinderExt.set_missing(h)
  puts AirportFinderExt.set_nearest(h, 19.07, 72.87, "in", 1, 0.0, 0, 2)
  puts AirportFinderExt.set_resolve(h, 17.385, 78.486, 300.0, 1)
  puts AirportFinderExt.set_free(h)
end
