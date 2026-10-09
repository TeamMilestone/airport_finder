# Airport finder — given (lat, lng), returns the nearest airport code.
#
# A Ruby port of the Rust crate (src/lib.rs, 0.3.1) written for Spinel, the
# Ruby AOT compiler; it runs unchanged under CRuby. Same data, same
# algorithms, same answers: the embedded JSON is parsed on first use the way
# serde_json parses it, polygon rings are banded by latitude for the ray
# cast, and nearest airports come from an R-tree of unit vectors.
#
# Hot data lives in flat typed arrays (struct of arrays) rather than in an
# object per ring or airport: Spinel stores an Array of objects boxed, and
# every access through it takes the slow, dynamically typed path.
#
# The C FFI (airport_finder_find / _free) is not ported: Spinel builds
# executables, and this file is meant to be compiled into one.

require_relative "embedded_data"

module AirportFinder
  class Error < StandardError; end

  INF = Float::INFINITY
  DEG = Math::PI / 180.0 # f64::to_radians multiplies by exactly this
  HALF_PI = Math::PI / 2.0
  EARTH_RADIUS_KM = 6371.0

  # -------------------------------------------------------------------------
  # Data structures
  # -------------------------------------------------------------------------

  # An embedded airport.
  class Airport
    # iata: IATA code, uppercase ("ICN").
    # country: ISO 3166-1 alpha-2 country of the airport itself ("KR").
    attr_reader :iata, :name, :city, :country, :lat, :lng

    def initialize(iata, name, city, country, lat, lng)
      @iata = iata
      @name = name
      @city = city
      @country = country
      @lat = lat
      @lng = lng
    end

    # "country.iata" in lowercase, under the airport's own country ("es.leu").
    def code
      "#{@country.downcase}.#{@iata.downcase}"
    end

    # "City, Country" — the form find_nearest_airport returns.
    def display_name
      AirportFinder.display_name(AirportFinder.state, @city, @name, @country)
    end
  end

  # Airports found by AirportIndex#nearest: distance d[k] to airport i[k],
  # closest first.
  class Hits
    attr_reader :d, :i

    def initialize(d, i)
      @d = d
      @i = i
    end

    def size
      @i.size
    end
  end

  # -------------------------------------------------------------------------
  # JSON
  # -------------------------------------------------------------------------

  # A cursor over the embedded JSON, read straight into typed values the way
  # serde's derived Deserialize reads it: unknown keys are skipped.
  class JsonReader
    attr_reader :src, :pos

    def initialize(src, pos)
      @src = src
      @pos = pos
      @n = src.bytesize
    end

    # Raises; callers that must return a value follow it with one, so
    # Spinel types the method by that value rather than by the raise.
    def bad(what)
      raise Error, "json: #{what} at byte #{@pos}"
    end

    def skip_ws
      while @pos < @n
        c = @src.getbyte(@pos)
        break unless c == 32 || c == 10 || c == 13 || c == 9
        @pos += 1
      end
      @pos
    end

    # The next significant byte, or -1 at the end.
    def peek
      skip_ws
      @pos < @n ? @src.getbyte(@pos) : -1
    end

    def expect(c)
      bad("expected '#{c.chr}'") unless peek == c
      @pos += 1
    end

    # Call before each element of an array or member of an object whose
    # opening bracket was read: false, past `close`, when there are no more.
    def next?(close, first)
      c = peek
      if c == close
        @pos += 1
        return false
      end
      unless first
        bad("expected ',' or '#{close.chr}'") unless c == 44
        @pos += 1
      end
      true
    end

    def read_string
      expect(34)
      start = @pos
      while @pos < @n
        c = @src.getbyte(@pos)
        if c == 34
          s = @src.byteslice(start, @pos - start)
          @pos += 1
          return s
        end
        return read_escaped(start) if c == 92
        @pos += 1
      end
      bad("unterminated string")
      ""
    end

    # The rest of a string holding an escape, from its first byte at `start`.
    def read_escaped(start)
      buf = @src.byteslice(start, @pos - start)
      while @pos < @n
        c = @src.getbyte(@pos)
        if c == 34
          @pos += 1
          return buf
        elsif c == 92
          e = @pos + 1 < @n ? @src.getbyte(@pos + 1) : -1
          @pos += 2
          if e == 34 then buf << "\""
          elsif e == 92 then buf << "\\"
          elsif e == 47 then buf << "/"
          elsif e == 98 then buf << "\b"
          elsif e == 102 then buf << "\f"
          elsif e == 110 then buf << "\n"
          elsif e == 114 then buf << "\r"
          elsif e == 116 then buf << "\t"
          else
            # \uXXXX never occurs in the embedded data.
            @pos -= 2
            bad("unsupported string escape")
          end
        else
          run = @pos
          @pos += 1 while @pos < @n && @src.getbyte(@pos) != 34 && @src.getbyte(@pos) != 92
          buf << @src.byteslice(run, @pos - run)
        end
      end
      bad("unterminated string")
      buf
    end

    # A string, or nil for null.
    def read_opt_string
      if peek == 110
        skip_literal("null")
        return nil
      end
      read_string
    end

    # A number as serde_json reads one without its float_roundtrip feature:
    # the digits as an integer, converted to f64, then scaled by one power of
    # ten. With 17 significant digits that is not always the double closest
    # to the decimal — String#to_f's — but it is the one the crate gets.
    def read_number
      skip_ws
      neg = false
      if @pos < @n && @src.getbyte(@pos) == 45
        neg = true
        @pos += 1
      end
      sig = 0
      exp = 0
      c = @pos < @n ? @src.getbyte(@pos) : -1
      bad("invalid number") unless c >= 48 && c <= 57
      if c == 48
        @pos += 1
      else
        while @pos < @n && (c = @src.getbyte(@pos)) >= 48 && c <= 57
          bad("number too long") if sig >= SIG_LIMIT
          sig = sig * 10 + (c - 48)
          @pos += 1
        end
      end
      if @pos < @n && @src.getbyte(@pos) == 46
        @pos += 1
        digits = 0
        while @pos < @n && (c = @src.getbyte(@pos)) >= 48 && c <= 57
          bad("number too long") if sig >= SIG_LIMIT
          sig = sig * 10 + (c - 48)
          exp -= 1
          digits += 1
          @pos += 1
        end
        bad("invalid number") if digits == 0
      end
      if @pos < @n && ((c = @src.getbyte(@pos)) == 101 || c == 69)
        @pos += 1
        eneg = false
        if @pos < @n && ((c = @src.getbyte(@pos)) == 43 || c == 45)
          eneg = c == 45
          @pos += 1
        end
        e = 0
        digits = 0
        while @pos < @n && (c = @src.getbyte(@pos)) >= 48 && c <= 57
          e = e * 10 + (c - 48) if e < 100_000
          digits += 1
          @pos += 1
        end
        bad("invalid number") if digits == 0
        exp = eneg ? exp - e : exp + e
      end
      bad("number exponent out of range") if exp < -22 || exp > 22
      f = sig.to_f
      f = exp >= 0 ? f * POW10[exp] : f / POW10[-exp]
      neg ? -f : f
    end

    # Beyond this the next digit could overflow a 64-bit integer.
    SIG_LIMIT = 922_337_203_685_477_580

    # 1e0 .. 1e22, all exact.
    POW10 = [1.0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
             1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22].freeze

    def skip_literal(word)
      skip_ws
      bad("invalid literal") unless @src.byteslice(@pos, word.bytesize) == word
      @pos += word.bytesize
    end

    def skip_value
      c = peek
      if c == 34
        read_string
      elsif c == 123
        @pos += 1
        first = true
        while next?(125, first)
          first = false
          read_string
          expect(58)
          skip_value
        end
      elsif c == 91
        @pos += 1
        first = true
        while next?(93, first)
          first = false
          skip_value
        end
      elsif c == 116
        skip_literal("true")
      elsif c == 102
        skip_literal("false")
      elsif c == 110
        skip_literal("null")
      else
        read_number
      end
      nil
    end
  end

  # -------------------------------------------------------------------------
  # Polygon rings
  # -------------------------------------------------------------------------

  # Every polygon ring, parsed once at init, with its bounding box, and its
  # edges bucketed by latitude band so a ray cast only visits the edges near
  # its latitude.
  #
  # Ring r's points are xs/ys[first[r], n[r]] (lng, lat). Edge i runs from
  # point i - 1 (cyclically) to point i; band b's edges are
  # edges[bstart[band0[r] + b] ... bstart[band0[r] + b + 1]], in edge order.
  class Rings
    # Ring edges per latitude band, on average and roughly.
    EDGES_PER_BAND = 8
    MARGIN = 1e-9

    attr_reader :xs, :ys, :first, :n, :min_lng, :min_lat, :max_lng, :max_lat

    def initialize
      @xs = []
      @ys = []
      @first = []
      @n = []
      @min_lng = []
      @min_lat = []
      @max_lng = []
      @max_lat = []
      @band_height = []
      @bands = []
      @band0 = []
      @bstart = []
      @edges = []
    end

    def size
      @n.size
    end

    # Adds a ring of points and returns its number.
    def add(xs, ys)
      r = @n.size
      n = xs.size
      min_lng = INF
      min_lat = INF
      max_lng = -INF
      max_lat = -INF
      @first << @xs.size
      i = 0
      while i < n
        x = xs[i]
        y = ys[i]
        @xs << x
        @ys << y
        min_lng = x if x < min_lng
        min_lat = y if y < min_lat
        max_lng = x if x > max_lng
        max_lat = y if y > max_lat
        i += 1
      end

      # Each edge goes in every band its latitude span touches.
      bands = n / EDGES_PER_BAND
      bands = 1 if bands < 1
      band_height = (max_lat - min_lat) / bands
      lo_band = []
      hi_band = []
      count = Array.new(bands, 0)
      i = 0
      while i < n
        yi = ys[i]
        yj = ys[i == 0 ? n - 1 : i - 1]
        lo = AirportFinder.band_of(yi < yj ? yi : yj, min_lat, band_height, bands)
        hi = AirportFinder.band_of(yi < yj ? yj : yi, min_lat, band_height, bands)
        lo_band << lo
        hi_band << hi
        b = lo
        while b <= hi
          count[b] += 1
          b += 1
        end
        i += 1
      end
      start = []
      at = @edges.size
      b = 0
      while b < bands
        start << at
        @bstart << at
        at += count[b]
        b += 1
      end
      @bstart << at
      @edges << 0 while @edges.size < at
      i = 0
      while i < n
        b = lo_band[i]
        while b <= hi_band[i]
          @edges[start[b]] = i
          start[b] += 1
          b += 1
        end
        i += 1
      end

      @n << n
      @min_lng << min_lng
      @min_lat << min_lat
      @max_lng << max_lng
      @max_lat << max_lat
      @band_height << band_height
      @bands << bands
      @band0 << @bstart.size - bands - 1
      r
    end

    # Same answer as a ray cast over the whole ring. Outside the bounding box
    # the ray crosses the ring an even number of times (or never), so it is
    # skipped. Latitude is compared exactly as the ray cast does; longitude
    # gets a margin far above the rounding of its intersections. Within it,
    # only the edges in `lat`'s band can cross the ray, and the parity of the
    # crossings does not depend on the order they are seen.
    def contains(r, lng, lat)
      min_lat = @min_lat[r]
      if lat < min_lat || lat >= @max_lat[r] || lng < @min_lng[r] - MARGIN || lng > @max_lng[r] + MARGIN
        return false
      end
      n = @n[r]
      base = @first[r]
      b = @band0[r] + AirportFinder.band_of(lat, min_lat, @band_height[r], @bands[r])
      k = @bstart[b]
      stop = @bstart[b + 1]
      inside = false
      while k < stop
        i = @edges[k]
        j = base + (i == 0 ? n - 1 : i - 1)
        i += base
        yi = @ys[i]
        yj = @ys[j]
        if (yi > lat) != (yj > lat)
          xi = @xs[i]
          inside = !inside if lng < (@xs[j] - xi) * (lat - yi) / (yj - yi) + xi
        end
        k += 1
      end
      inside
    end
  end

  # The latitude band holding `lat`, saturating as Rust's `as usize` does
  # (NaN and negatives to 0). Monotonic in `lat`, so an edge whose span
  # holds `lat` is always listed in this band.
  def self.band_of(lat, min_lat, band_height, bands)
    v = (lat - min_lat) / band_height
    return 0 unless v >= 1.0
    return bands - 1 if v >= bands.to_f
    v.to_i
  end

  # -------------------------------------------------------------------------
  # R-tree
  # -------------------------------------------------------------------------

  # A static R-tree over boxes lo/hi[i * dims + k] (a point has lo == hi),
  # bulk loaded by sort-tile-recursive packing into nodes of up to
  # NODE_SIZE children — rstar's default maximum.
  #
  # Node n's children are kids[first[n], count[n]]: item numbers if leaf[n]
  # is 1, else node numbers. Its box is nlo/nhi[n * dims + k].
  class RTree
    NODE_SIZE = 6

    attr_reader :root, :first, :count, :leaf, :kids, :nlo, :nhi, :lo, :hi

    def initialize(dims, lo, hi)
      @dims = dims
      @lo = lo
      @hi = hi
      @first = []
      @count = []
      @leaf = []
      @kids = []
      @nlo = []
      @nhi = []
      @root = -1
      n = lo.size / dims
      if n > 0
        level = pack((0...n).to_a, lo, hi, 1)
        level = pack(level, @nlo, @nhi, 0) while level.size > 1
        @root = level[0]
      end
    end

    # Parent nodes over `ids`, whose boxes are in blo/bhi.
    def pack(ids, blo, bhi, leaf)
      d = @dims
      n = ids.size
      centers = Array.new(n * d, 0.0)
      p = 0
      while p < n
        id = ids[p]
        k = 0
        while k < d
          centers[p * d + k] = (blo[id * d + k] + bhi[id * d + k]) * 0.5
          k += 1
        end
        p += 1
      end
      order = str_order((0...n).to_a, 0, centers)
      parents = []
      start = 0
      while start < n
        node = @first.size
        cnt = n - start < NODE_SIZE ? n - start : NODE_SIZE
        @first << @kids.size
        @count << cnt
        @leaf << leaf
        k = 0
        while k < d
          @nlo << INF
          @nhi << -INF
          k += 1
        end
        c = 0
        while c < cnt
          id = ids[order[start + c]]
          @kids << id
          k = 0
          while k < d
            v = blo[id * d + k]
            @nlo[node * d + k] = v if v < @nlo[node * d + k]
            v = bhi[id * d + k]
            @nhi[node * d + k] = v if v > @nhi[node * d + k]
            k += 1
          end
          c += 1
        end
        parents << node
        start += NODE_SIZE
      end
      parents
    end

    # Positions in sort-tile-recursive order of their centers: sorted on the
    # first axis, cut into slabs of whole nodes, each slab ordered on the
    # next axis. Ties go by position, so the tree does not depend on the sort.
    def str_order(pos, dim, centers)
      d = @dims
      sorted = pos.sort do |a, b|
        c = centers[a * d + dim] <=> centers[b * d + dim]
        c == 0 ? a <=> b : c
      end
      return sorted if dim == d - 1
      n = sorted.size
      leaves = (n + NODE_SIZE - 1) / NODE_SIZE
      slabs = (leaves**(1.0 / (d - dim))).ceil
      per = NODE_SIZE * ((leaves + slabs - 1) / slabs)
      out = []
      k = 0
      while k < n
        str_order(sorted[k, per], dim + 1, centers).each { |q| out << q }
        k += per
      end
      out
    end

    # Squared distance from (x, y, z) to node's box in a 3-d tree.
    def mindist3(node, x, y, z)
      b = node * 3
      lo = @nlo[b]
      hi = @nhi[b]
      dx = x < lo ? lo - x : (x > hi ? x - hi : 0.0)
      lo = @nlo[b + 1]
      hi = @nhi[b + 1]
      dy = y < lo ? lo - y : (y > hi ? y - hi : 0.0)
      lo = @nlo[b + 2]
      hi = @nhi[b + 2]
      dz = z < lo ? lo - z : (z > hi ? z - hi : 0.0)
      dx * dx + dy * dy + dz * dz
    end

    # Squared distance from (x, y, z) to point item of a 3-d tree.
    def dist3(item, x, y, z)
      b = item * 3
      dx = @lo[b] - x
      dy = @lo[b + 1] - y
      dz = @lo[b + 2] - z
      dx * dx + dy * dy + dz * dz
    end

    # Whether a point item of a 3-d tree is within squared distance r2.
    def any_within3?(x, y, z, r2)
      @root >= 0 && within3?(@root, x, y, z, r2)
    end

    def within3?(node, x, y, z, r2)
      return false if mindist3(node, x, y, z) > r2
      s = @first[node]
      e = s + @count[node]
      while s < e
        if @leaf[node] == 1
          return true if dist3(@kids[s], x, y, z) <= r2
        elsif within3?(@kids[s], x, y, z, r2)
          return true
        end
        s += 1
      end
      false
    end
  end

  # A binary min-heap of (distance, reference) pairs.
  class MinHeap
    def initialize
      @d = []
      @r = []
    end

    def size
      @d.size
    end

    def top_d
      @d[0]
    end

    def top_r
      @r[0]
    end

    def push(d, r)
      @d << d
      @r << r
      i = @d.size - 1
      while i > 0
        p = (i - 1) / 2
        break if @d[p] <= d
        @d[i] = @d[p]
        @r[i] = @r[p]
        i = p
      end
      @d[i] = d
      @r[i] = r
    end

    def pop
      d = @d.pop
      r = @r.pop
      n = @d.size
      return if n == 0
      i = 0
      while true
        c = 2 * i + 1
        break if c >= n
        c += 1 if c + 1 < n && @d[c + 1] < @d[c]
        break if d <= @d[c]
        @d[i] = @d[c]
        @r[i] = @r[c]
        i = c
      end
      @d[i] = d
      @r[i] = r
    end
  end

  # Items grouped by a key, groups in order of first appearance: group g is
  # keys[g] and holds items[start[g] ... start[g + 1]], in the order given.
  # (A Hash of Arrays would do, but Spinel leaves one untyped.)
  class Groups
    attr_reader :keys

    # item_keys[k] is the key of items[k].
    def initialize(item_keys, items)
      group_of = {}
      @keys = []
      groups = []
      k = 0
      while k < items.size
        key = item_keys[k]
        g = group_of[key]
        if g.nil?
          g = @keys.size
          group_of[key] = g
          @keys << key
        end
        groups << g
        k += 1
      end
      @start = Array.new(@keys.size + 1, 0)
      groups.each { |g| @start[g + 1] += 1 }
      fill = [0]
      g = 0
      while g < @keys.size
        @start[g + 1] += @start[g]
        fill << @start[g + 1]
        g += 1
      end
      @items = Array.new(items.size, 0)
      k = 0
      while k < items.size
        g = groups[k]
        @items[fill[g]] = items[k]
        fill[g] += 1
        k += 1
      end
    end

    def members(g)
      out = []
      k = @start[g]
      while k < @start[g + 1]
        out << @items[k]
        k += 1
      end
      out
    end
  end

  # -------------------------------------------------------------------------
  # Global state (initialized once on first call)
  # -------------------------------------------------------------------------

  class State
    attr_reader :airports, :ap_iata, :ap_name, :ap_city, :ap_country, :ap_lat, :ap_lng,
                :all_airports, :rings, :feature_ring0, :feature_rings, :country_names,
                :airports_by_country, :airports_by_iata, :country_tree, :env_code, :env_feature

    def initialize(airports_json, countries_json)
      @airports = []
      @ap_iata = []
      @ap_name = []
      @ap_city = []
      @ap_country = []
      @ap_lat = []
      @ap_lng = []
      parse_airports(JsonReader.new(airports_json, 0))

      # Airports by country (lowercase) and by IATA code (uppercase)
      countries = []
      @airports_by_iata = {}
      i = 0
      while i < @ap_iata.size
        countries << @ap_country[i].downcase
        @airports_by_iata[@ap_iata[i].upcase] = i
        i += 1
      end
      by_country = Groups.new(countries, (0...@ap_iata.size).to_a)

      # Every polygon ring once, and the countries' bounding boxes
      @rings = Rings.new
      @feature_ring0 = []
      @feature_rings = []
      @country_names = {}
      @env_code = []
      @env_feature = []
      @env_lo = []
      @env_hi = []
      parse_countries(JsonReader.new(countries_json, 0))
      @country_tree = RTree.new(2, @env_lo, @env_hi)

      @all_airports = AirportIndex.new(@ap_lat, @ap_lng, (0...@ap_iata.size).to_a)
      @airports_by_country = {}
      g = 0
      while g < by_country.keys.size
        @airports_by_country[by_country.keys[g]] = AirportIndex.new(@ap_lat, @ap_lng, by_country.members(g))
        g += 1
      end
    end

    def parse_airports(r)
      r.expect(91)
      first = true
      while r.next?(93, first)
        first = false
        iata = ""
        name = ""
        city = ""
        country = ""
        lat = 0.0
        lng = 0.0
        seen = 0
        r.expect(123)
        f = true
        while r.next?(125, f)
          f = false
          key = r.read_string
          r.expect(58)
          if key == "iata" then iata = r.read_string; seen |= 1
          elsif key == "name" then name = r.read_string; seen |= 2
          elsif key == "city" then city = r.read_string; seen |= 4
          elsif key == "country" then country = r.read_string; seen |= 8
          elsif key == "lat" then lat = r.read_number; seen |= 16
          elsif key == "lng" then lng = r.read_number; seen |= 32
          else r.skip_value
          end
        end
        raise Error, "airports parse: missing field in airport #{@ap_iata.size}" unless seen == 63
        @airports << Airport.new(iata, name, city, country, lat, lng)
        @ap_iata << iata
        @ap_name << name
        @ap_city << city
        @ap_country << country
        @ap_lat << lat
        @ap_lng << lng
      end
    end

    def parse_countries(r)
      found = false
      r.expect(123)
      first = true
      while r.next?(125, first)
        first = false
        key = r.read_string
        r.expect(58)
        if key == "features"
          found = true
          r.expect(91)
          f = true
          while r.next?(93, f)
            f = false
            parse_feature(r)
          end
        else
          r.skip_value
        end
      end
      raise Error, "countries parse: missing field `features`" unless found
    end

    def parse_feature(r)
      iso = nil
      name = nil
      ring0 = @rings.size
      r.expect(123)
      first = true
      while r.next?(125, first)
        first = false
        key = r.read_string
        r.expect(58)
        if key == "properties"
          r.expect(123)
          f = true
          while r.next?(125, f)
            f = false
            k = r.read_string
            r.expect(58)
            if k == "iso_a2" then iso = r.read_opt_string
            elsif k == "name" || k == "NAME" then name = r.read_opt_string
            else r.skip_value
            end
          end
        elsif key == "geometry"
          parse_geometry(r)
        else
          r.skip_value
        end
      end

      index = @feature_ring0.size
      @feature_ring0 << ring0
      @feature_rings << @rings.size - ring0
      if !iso.nil? && !name.nil?
        upper = iso.upcase
        @country_names[upper] = name.to_s unless @country_names.key?(upper)
      end
      if !iso.nil? && !iso.empty? && iso != "-99"
        add_envelope(index, iso.downcase)
      end
    end

    # Adds every ring of a Polygon / MultiPolygon, in GeoJSON order; none for
    # other geometry types.
    def parse_geometry(r)
      gtype = ""
      type_seen = false
      coords_at = -1
      r.expect(123)
      first = true
      while r.next?(125, first)
        first = false
        key = r.read_string
        r.expect(58)
        if key == "type"
          gtype = r.read_string
          type_seen = true
        elsif key == "coordinates"
          if type_seen
            parse_coordinates(r, gtype)
          else
            # Read once the type is known.
            r.skip_ws
            coords_at = r.pos
            r.skip_value
          end
        else
          r.skip_value
        end
      end
      parse_coordinates(JsonReader.new(r.src, coords_at), gtype) if coords_at >= 0
    end

    def parse_coordinates(r, gtype)
      if gtype == "Polygon"
        parse_polygon(r)
      elsif gtype == "MultiPolygon"
        r.expect(91)
        first = true
        while r.next?(93, first)
          first = false
          parse_polygon(r)
        end
      else
        r.skip_value
      end
    end

    def parse_polygon(r)
      r.expect(91)
      first = true
      while r.next?(93, first)
        first = false
        parse_ring(r)
      end
    end

    # A ring of [lng, lat, ...] points; shorter points are dropped.
    def parse_ring(r)
      xs = []
      ys = []
      r.expect(91)
      first = true
      while r.next?(93, first)
        first = false
        r.expect(91)
        k = 0
        x = 0.0
        y = 0.0
        f = true
        while r.next?(93, f)
          f = false
          v = r.read_number
          x = v if k == 0
          y = v if k == 1
          k += 1
        end
        if k >= 2
          xs << x
          ys << y
        end
      end
      @rings.add(xs, ys)
    end

    # The bounding box of every ring of the feature, unless they hold no point.
    def add_envelope(feature, code)
      min_lat = 90.0
      max_lat = -90.0
      min_lng = 180.0
      max_lng = -180.0
      xs = @rings.xs
      ys = @rings.ys
      r = @feature_ring0[feature]
      stop = r + @feature_rings[feature]
      while r < stop
        i = @rings.first[r]
        e = i + @rings.n[r]
        while i < e
          lng = xs[i]
          lat = ys[i]
          min_lat = lat if lat < min_lat
          max_lat = lat if lat > max_lat
          min_lng = lng if lng < min_lng
          max_lng = lng if lng > max_lng
          i += 1
        end
        r += 1
      end
      return nil if min_lat >= 90.0 || max_lat <= -90.0
      @env_lo << min_lng << min_lat
      @env_hi << max_lng << max_lat
      @env_code << code
      @env_feature << feature
      nil
    end

    # The code of the country holding (lat, lng); nil if none. Where two do —
    # an enclave drawn over the country around it without a hole (Vatican
    # City in Italy), or borders that overlap by a sliver — the one whose
    # ring around the point is smaller wins, then the lower feature index:
    # never the order the R-tree happens to list them in.
    def country_exact(lat, lng)
      t = @country_tree
      return nil if t.root < 0
      env = exact_in(t, t.root, lng, lat, -1)
      env < 0 ? nil : @env_code[env]
    end

    # The better of `best` (an envelope, or -1) and the envelopes under node
    # whose country holds (x, y).
    def exact_in(t, node, x, y, best)
      nlo = t.nlo
      nhi = t.nhi
      b = node * 2
      return best if x < nlo[b] || x > nhi[b] || y < nlo[b + 1] || y > nhi[b + 1]
      kids = t.kids
      s = t.first[node]
      e = s + t.count[node]
      if t.leaf[node] == 1
        lo = t.lo
        hi = t.hi
        while s < e
          env = kids[s]
          b = env * 2
          if x >= lo[b] && x <= hi[b] && y >= lo[b + 1] && y <= hi[b + 1]
            size = innermost_ring(@env_feature[env], x, y)
            best = env if size >= 0.0 && (best < 0 || better?(size, env, best, x, y))
          end
          s += 1
        end
      else
        while s < e
          best = exact_in(t, kids[s], x, y, best)
          s += 1
        end
      end
      best
    end

    # Whether envelope env, whose ring around (x, y) has area `size`, beats
    # envelope best, which holds the point too.
    def better?(size, env, best, x, y)
      best_size = innermost_ring(@env_feature[best], x, y)
      return size < best_size if size != best_size
      @env_feature[env] < @env_feature[best]
    end

    # If a country's rings hold the point, the bounding-box area of the
    # smallest of them around it; else -1. Held means by the even-odd rule
    # over all the rings: a hole is a ring too, so a point in an enclave cut
    # out of the country (Lesotho in South Africa) is held twice, and is not
    # the country's.
    def innermost_ring(feature, lng, lat)
      r = @feature_ring0[feature]
      stop = r + @feature_rings[feature]
      inside = false
      smallest = INF
      while r < stop
        if @rings.contains(r, lng, lat)
          inside = !inside
          size = (@rings.max_lng[r] - @rings.min_lng[r]) * (@rings.max_lat[r] - @rings.min_lat[r])
          smallest = size if size < smallest
        end
        r += 1
      end
      inside ? smallest : -1.0
    end

    # "country.iata" of airport i, lowercase.
    def code_of(i)
      "#{@ap_country[i].downcase}.#{@ap_iata[i].downcase}"
    end
  end

    def self.state
    @state ||= State.new(AIRPORTS_JSON, COUNTRIES_JSON)
  end

  # -------------------------------------------------------------------------
  # Geometric algorithms
  # -------------------------------------------------------------------------

  # Rejects non-finite values and |lat| > 90.
  def self.valid_coords?(lat, lng)
    lat.finite? && lng.finite? && lat.abs <= 90.0
  end

  # Wrap a finite longitude into [-180, 180]. Float#% is fmod plus the
  # divisor when negative: Rust's rem_euclid for a positive divisor.
  def self.normalize_lng(lng)
    return lng if lng >= -180.0 && lng <= 180.0
    (lng + 180.0) % 360.0 - 180.0
  end

  # Haversine distance in km.
  def self.haversine(lat1, lng1, lat2, lng2)
    d_lat = (lat2 - lat1) * DEG
    d_lng = (lng2 - lng1) * DEG
    lat1r = lat1 * DEG
    lat2r = lat2 * DEG
    s1 = Math.sin(d_lat / 2.0)
    s2 = Math.sin(d_lng / 2.0)
    a = s1 * s1 + Math.cos(lat1r) * Math.cos(lat2r) * (s2 * s2)
    c = 2.0 * Math.atan2(sqrt_or_nan(a), sqrt_or_nan(1.0 - a))
    EARTH_RADIUS_KM * c
  end

  # f64::sqrt: NaN below zero, where Math.sqrt raises. At an antipode `a`
  # rounds a hair above 1, and the distance comes out NaN as in the crate.
  def self.sqrt_or_nan(x)
    x < 0.0 ? Float::NAN : Math.sqrt(x)
  end

  # Squared chord of an arc of `km`, plus a margin far above the rounding of
  # either distance: an airport farther than this along the chord is farther
  # than `km` by haversine. Unbounded from half the globe on (and for NaN).
  def self.chord2_bound(km)
    half_angle = km / (2.0 * EARTH_RADIUS_KM)
    if half_angle < HALF_PI
      s = Math.sin(half_angle)
      4.0 * (s * s) + 1e-9
    else
      INF
    end
  end

  # Distance da to airport ia against db to ib: f64::total_cmp on the
  # distances (a NaN is the positive one arm64 makes), then the lower index.
  def self.cmp_dist(da, ia, db, ib)
    if da.nan? || db.nan?
      return 1 unless db.nan?
      return -1 unless da.nan?
      return ia <=> ib
    end
    return -1 if da < db
    return 1 if da > db
    ia <=> ib
  end

  # -------------------------------------------------------------------------
  # Nearest airports
  # -------------------------------------------------------------------------

  # Airports as points on the unit sphere, where the straight-line (chord)
  # distance orders them the same as the great-circle distance does.
  class AirportIndex
    attr_reader :ids

    # lats/lngs: every airport's; indices: the ones to index.
    def initialize(lats, lngs, indices)
      @lats = lats
      @lngs = lngs
      @ids = indices
      pts = []
      indices.each do |i|
        la = lats[i] * DEG
        ln = lngs[i] * DEG
        pts << Math.cos(la) * Math.cos(ln) << Math.cos(la) * Math.sin(ln) << Math.sin(la)
      end
      @tree = RTree.new(3, pts, pts)
    end

    # Up to `limit` airports nearest to (lat, lng) by haversine, closest
    # first and ties to the lower index; with has_max, farther than max_km
    # and NaN distances are dropped. Exactly what computing every distance
    # and sorting gives, but it stops once no farther airport can make the cut.
    def nearest(lat, lng, has_max, max_km, limit)
      hd = []
      hi = []
      t = @tree
      if limit > 0 && t.root >= 0
        la = lat * DEG
        ln = lng * DEG
        qx = Math.cos(la) * Math.cos(ln)
        qy = Math.cos(la) * Math.sin(ln)
        qz = Math.sin(la)
        cutoff = has_max ? AirportFinder.chord2_bound(max_km) : INF
        # Haversine can come out NaN at the antipode, and total_cmp may sort
        # that first; without max_km to drop it, look at every airport.
        exhaustive = !has_max && t.any_within3?(-qx, -qy, -qz, 1e-9)

        # Best first: nodes by the distance to their box, airports (encoded
        # -1 - item) by their own, so airports come out closest first.
        first = t.first
        count = t.count
        leaf = t.leaf
        kids = t.kids
        heap = MinHeap.new
        heap.push(t.mindist3(t.root, qx, qy, qz), t.root)
        while heap.size > 0
          d2 = heap.top_d
          ref = heap.top_r
          heap.pop
          break if d2 > cutoff
          if ref < 0
            i = @ids[-1 - ref]
            d = AirportFinder.haversine(lat, lng, @lats[i], @lngs[i])
            if !has_max || d <= max_km
              hd << d
              hi << i
              if hd.size == limit && !exhaustive
                # Only airports as close as the farthest of these can still make the cut.
                b = AirportFinder.chord2_bound(AirportIndex.worst(hd))
                cutoff = b if b < cutoff
              end
            end
          else
            s = first[ref]
            e = s + count[ref]
            if leaf[ref] == 1
              while s < e
                item = kids[s]
                heap.push(t.dist3(item, qx, qy, qz), -1 - item)
                s += 1
              end
            else
              while s < e
                node = kids[s]
                heap.push(t.mindist3(node, qx, qy, qz), node)
                s += 1
              end
            end
          end
        end
      end
      return Hits.new(hd, hi) if hd.size < 2

      order = (0...hd.size).to_a
      order.sort! { |a, b| AirportFinder.cmp_dist(hd[a], hi[a], hd[b], hi[b]) }
      sd = []
      si = []
      k = 0
      while k < order.size && k < limit
        sd << hd[order[k]]
        si << hi[order[k]]
        k += 1
      end
      Hits.new(sd, si)
    end

    # The largest distance, by total_cmp.
    def self.worst(ds)
      w = ds[0]
      ds.each { |d| w = d if d.nan? || (!w.nan? && d > w) }
      w
    end

    # The index of the nearest airport within max_km, or -1.
    def nearest_one(lat, lng, max_km)
      hits = nearest(lat, lng, true, max_km, 1)
      hits.size == 0 ? -1 : hits.i[0]
    end
  end

  # -------------------------------------------------------------------------
  # Country detection
  # -------------------------------------------------------------------------

  RADII = [0.05, 0.1, 0.2, 0.5, 1.0, 2.0].freeze
  # (dlat, dlng) pairs
  DIRECTIONS = [
    1.0, 0.0, 0.92, 0.38, 0.71, 0.71, 0.38, 0.92,
    0.0, 1.0, -0.38, 0.92, -0.71, 0.71, -0.92, 0.38,
    -1.0, 0.0, -0.92, -0.38, -0.71, -0.71, -0.38, -0.92,
    0.0, -1.0, 0.38, -0.92, 0.71, -0.71, 0.92, -0.38
  ].freeze

  # Special cases: remote islands missing from GeoJSON
  def self.special_country(lat, lng)
    return "kr" if lat >= 37.23 && lat <= 37.25 && lng >= 131.85 && lng <= 131.87 # 독도
    return "sh" if lat >= -37.2 && lat <= -37.0 && lng >= -12.5 && lng <= -12.1 # Tristan da Cunha
    return "tf" if lat >= -49.7 && lat <= -48.9 && lng >= 68.5 && lng <= 70.6 # Kerguelen
    return "gs" if lat >= -54.9 && lat <= -53.9 && lng >= -38.0 && lng <= -35.5 # South Georgia
    return "bv" if lat >= -54.5 && lat <= -54.3 && lng >= 3.2 && lng <= 3.5 # Bouvet Island
    return "cp" if lat >= 10.2 && lat <= 10.4 && lng >= -109.3 && lng <= -109.1 # Clipperton
    nil
  end

  def self.find_country_code(st, lat, lng)
    code = special_country(lat, lng)
    return code unless code.nil?

    # 1st: Exact R-tree + polygon test
    code = st.country_exact(lat, lng)
    return code unless code.nil?

    # 2nd: Radial search with 16-directional sampling
    RADII.each do |r|
      k = 0
      while k < DIRECTIONS.size
        code = st.country_exact(lat + DIRECTIONS[k] * r, lng + DIRECTIONS[k + 1] * r)
        return code unless code.nil?
        k += 2
      end
    end

    # 3rd: Nearby airports fallback (1000 km)
    find_country_from_nearby_airports(st, lat, lng, 1000.0)
  end

  def self.find_country_from_nearby_airports(st, lat, lng, max_km)
    i = st.all_airports.nearest_one(lat, lng, max_km)
    i < 0 ? nil : st.ap_country[i].downcase
  end

  # -------------------------------------------------------------------------
  # Main finder
  # -------------------------------------------------------------------------

  # Find the nearest airport for the given coordinates.
  #
  # Returns [code, name] where code is "country.iata" (e.g. "kr.gmp") and
  # name is "City, Country" (e.g. "Seoul, Korea"), both under the airport's
  # own country. For coordinates in a country without airports the answer
  # comes from a neighbour — Andorra gives "es.leu" — and country_at tells
  # the country the coordinates are in ("ad").
  # Raises Error on non-finite coordinates or |lat| > 90, and when no
  # airport is found.
  def self.find_nearest_airport(lat, lng)
    raise Error, "invalid coordinates" unless valid_coords?(lat, lng)
    lng = normalize_lng(lng)
    st = state
    loc = nearest_in_country(st, lat, lng)
    raise Error, loc.error if loc.index < 0
    i = loc.index
    [st.code_of(i), display_name(st, st.ap_city[i], st.ap_name[i], st.ap_country[i])]
  end

  # The country containing a point and the index of its nearest airport (or,
  # for a country without airports, of the nearest one in a nearby country)
  # — or index -1 and why not.
  class Located
    attr_reader :country, :index, :error

    def initialize(country, index, error)
      @country = country
      @index = index
      @error = error
    end
  end

  NEARBY_RADII = [2000.0, 3000.0, 4000.0].freeze

  # Expects coordinates already validated and wrapped.
  def self.nearest_in_country(st, lat, lng)
    # 1. Find country
    found = find_country_code(st, lat, lng)
    return Located.new("", -1, "no country found for coordinates") if found.nil?
    country = found.to_s

    # 2. Get airports in that country; if it has none, search nearby countries
    pool = st.airports_by_country[country]
    if pool.nil?
      k = 0
      while k < NEARBY_RADII.size
        nearby = find_country_from_nearby_airports(st, lat, lng, NEARBY_RADII[k])
        if !nearby.nil? && nearby != country
          pool = st.airports_by_country[nearby]
          break unless pool.nil?
        end
        k += 1
      end
    end
    return Located.new(country, -1, "no airports found in country #{country} or nearby") if pool.nil?

    # 3. Find nearest airport by Haversine distance
    i = pool.nearest_one(lat, lng, INF).to_i
    return Located.new(country, -1, "could not find nearest airport") if i < 0
    Located.new(country, i, "")
  end

  # "City, Country" for an airport, named after country_code (any case).
  def self.display_name(st, city, name, country_code)
    country_name = get_country_name(st, country_code)
    if !city.empty? && city != name
      "#{city}, #{country_name}"
    else
      "#{name}, #{country_name}"
    end
  end

  def self.get_country_name(st, code)
    upper = code.upcase
    st.country_names.fetch(upper, upper).to_s
  end

  # -------------------------------------------------------------------------
  # Lookups
  # -------------------------------------------------------------------------

  # The embedded airport with this IATA code (any case), if any.
  def self.airport(iata)
    st = state
    i = st.airports_by_iata.fetch(iata.to_s.strip.upcase, -1).to_i
    i < 0 ? nil : st.airports[i]
  end

  # Lowercase ISO 3166-1 alpha-2 code of the country containing (lat, lng).
  # Matches the prefix of find_nearest_airport's code except in countries
  # without airports ("ad" vs "es.leu"). nil for invalid coordinates or open
  # ocean far from any country.
  def self.country_at(lat, lng)
    return nil unless valid_coords?(lat, lng)
    find_country_code(state, lat, normalize_lng(lng))
  end

  # -------------------------------------------------------------------------
  # Searching a subset of airports
  # -------------------------------------------------------------------------

  # An airport found by AirportSet#nearest / #resolve.
  class Nearby
    attr_reader :airport, :distance_km

    def initialize(airport, distance_km)
      @airport = airport
      @distance_km = distance_km
    end
  end

  # The result of AirportSet#resolve. resolution is how it picked its airport:
  #   :nearest        find_nearest_airport's own answer is in the set (and domestic)
  #   :same_country   the nearest set airport in the country containing the coordinates
  #   :nearby_foreign that country has no set airport: the nearest one across a border
  # nearest_code is find_nearest_airport's code for the coordinates ("in.bpm"),
  # whether or not that airport is in the set or domestic.
  class Resolved
    attr_reader :airport, :distance_km, :resolution, :nearest_code

    def initialize(airport, distance_km, resolution, nearest_code)
      @airport = airport
      @distance_km = distance_km
      @resolution = resolution
      @nearest_code = nearest_code
    end
  end

  # A subset of the embedded airports to search within — for instance the
  # airports a caller holds data for. Build it once and reuse it.
  class AirportSet
    # A set of the airports with these IATA codes (any case). Codes the
    # embedded data does not know are skipped and listed in #missing.
    def initialize(iata_codes)
      st = AirportFinder.state
      @members = {}
      all = []
      countries = []
      @missing = []
      iata_codes.each do |code|
        key = code.to_s.strip.upcase
        i = st.airports_by_iata.fetch(key, -1).to_i
        if i < 0
          @missing << key unless @missing.include?(key)
        elsif !@members.key?(i)
          @members[i] = 1
          all << i
          countries << st.ap_country[i].downcase
        end
      end
      @all = AirportIndex.new(st.ap_lat, st.ap_lng, all)
      @by_country = {}
      by_country = Groups.new(countries, all)
      g = 0
      while g < by_country.keys.size
        @by_country[by_country.keys[g]] = AirportIndex.new(st.ap_lat, st.ap_lng, by_country.members(g))
        g += 1
      end
    end

    # Every embedded airport.
    def self.all
      AirportSet.new(AirportFinder.state.ap_iata)
    end

    def size
      @members.size
    end

    def empty?
      @members.empty?
    end

    def include?(iata)
      @members.key?(AirportFinder.state.airports_by_iata.fetch(iata.to_s.strip.upcase, -1))
    end

    # Codes passed to new that the embedded data does not know (uppercase,
    # in the order given).
    def missing
      @missing
    end

    # Up to `limit` airports of the set nearest to (lat, lng), closest first.
    # `country` (ISO alpha-2, any case) keeps only that country's airports;
    # `max_km` drops any farther away.
    def nearest(lat, lng, limit: 1, country: nil, max_km: nil)
      raise Error, "invalid coordinates" unless AirportFinder.valid_coords?(lat, lng)
      lng = AirportFinder.normalize_lng(lng)
      hits = pool_hits(lat, lng, limit, !country.nil?, country.nil? ? "" : country.downcase, !max_km.nil?, max_km.nil? ? 0.0 : max_km)
      airports = AirportFinder.state.airports
      out = []
      k = 0
      while k < hits.size
        out << Nearby.new(airports[hits.i[k]], hits.d[k])
        k += 1
      end
      out
    end

    # Hits among the set's airports in `country` (lowercase) if
    # has_country, else among all of them.
    def pool_hits(lat, lng, limit, has_country, country, has_max, max_km)
      pool = has_country ? @by_country[country] : @all
      if pool.nil?
        # No hits, but built by #nearest, so that Spinel types their arrays.
        pool = @all
        limit = 0
      end
      pool.nearest(lat, lng, has_max, max_km, limit)
    end

    # Pick the set's airport for someone at (lat, lng):
    #
    # 1. :nearest — find_nearest_airport's answer, if it is in the set and in
    #    the country containing the coordinates.
    # 2. :same_country — else the nearest set airport in the country
    #    containing the coordinates, however far.
    # 3. :nearby_foreign — else (that country has none) the nearest set
    #    airport anywhere, within foreign_max_km if given.
    #
    # nil when none applies, including open ocean with no country.
    # Raises Error only on invalid coordinates.
    def resolve(lat, lng, foreign_max_km: nil)
      raise Error, "invalid coordinates" unless AirportFinder.valid_coords?(lat, lng)
      lng = AirportFinder.normalize_lng(lng)
      st = AirportFinder.state
      loc = AirportFinder.nearest_in_country(st, lat, lng)
      return nil if loc.index < 0
      nearest = loc.index
      nearest_code = st.code_of(nearest)

      # A country without airports gets find_nearest_airport's answer from a
      # neighbour up to 4000 km away — that counts as foreign, so it is only
      # taken within foreign_max_km below.
      domestic = st.ap_country[nearest].downcase == loc.country
      if domestic && @members.key?(nearest)
        d = AirportFinder.haversine(lat, lng, st.ap_lat[nearest], st.ap_lng[nearest])
        return Resolved.new(st.airports[nearest], d, :nearest, nearest_code)
      end
      hits = pool_hits(lat, lng, 1, true, loc.country, false, 0.0)
      resolution = :same_country
      if hits.size == 0
        hits = pool_hits(lat, lng, 1, false, "", !foreign_max_km.nil?, foreign_max_km.nil? ? 0.0 : foreign_max_km)
        resolution = :nearby_foreign
      end
      return nil if hits.size == 0
      Resolved.new(st.airports[hits.i[0]], hits.d[0], resolution, nearest_code)
    end
  end
end
