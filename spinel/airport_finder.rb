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
  # Ring r's points are pts[2 * first[r] ...] as lng, lat pairs, n[r] of
  # them. box[5 * r ...] is its min_lng, min_lat, max_lng, max_lat and band
  # height; band[2 * r] its first band's number in bstart, band[2 * r + 1]
  # its band count. Band b's edges are the entries bstart[b] ...
  # bstart[b + 1] of edges, in edge order, each two numbers: the offsets in
  # pts of the edge's end (point i) and start (point i - 1, cyclically).
  #
  # One array per kind of number rather than one per field: Spinel tests
  # every read of an array, so a ring's fields come from one array, and a
  # point's two coordinates sit together.
  class Rings
    # Ring edges per latitude band, on average and roughly.
    EDGES_PER_BAND = 8
    MARGIN = 1e-9

    attr_reader :pts, :first, :n, :box, :hits

    def initialize
      # boxed's answer, kept between calls.
      @hits = Array.new(64, 0)
      @pts = []
      @first = []
      @n = []
      @box = []
      @band = []
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
      base = @pts.size / 2
      @first << base
      i = 0
      while i < n
        x = xs[i]
        y = ys[i]
        @pts << x << y
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
      at = @edges.size / 2
      b = 0
      while b < bands
        start << at
        @bstart << at
        at += count[b]
        b += 1
      end
      @bstart << at
      @edges << 0 while @edges.size < 2 * at
      i = 0
      while i < n
        b = lo_band[i]
        while b <= hi_band[i]
          @edges[2 * start[b]] = 2 * (base + i)
          @edges[2 * start[b] + 1] = 2 * (base + (i == 0 ? n - 1 : i - 1))
          start[b] += 1
          b += 1
        end
        i += 1
      end

      @n << n
      @box << min_lng << min_lat << max_lng << max_lat << band_height
      @band << @bstart.size - bands - 1 << bands
      r
    end

    # The rings r ... stop whose bounding box can hold (lng, lat), into
    # hits[0 ...]; how many. Latitude is compared exactly as the ray cast
    # does; longitude gets a margin far above the rounding of its
    # intersections. Outside the box the ray crosses the ring an even
    # number of times (or never), so contains skips those rings.
    #
    # The hot methods read their arrays through instance variables: an
    # array in a local is a GC root, which keeps the local in memory.
    def boxed(r, stop, lng, lat)
      k = 0
      while r < stop
        b = r * 5
        unless lat < @box[b + 1] || lat >= @box[b + 3] || lng < @box[b] - MARGIN || lng > @box[b + 2] + MARGIN
          @hits[k] = r
          k += 1
        end
        r += 1
      end
      k
    end

    # Whether ring r, whose box can hold (lng, lat) (boxed), does: the ray
    # cast over only the edges in `lat`'s band, as the parity of the
    # crossings does not depend on the order they are seen.
    def cast(r, lng, lat)
      b = @band[2 * r] + AirportFinder.band_of(lat, @box[r * 5 + 1], @box[r * 5 + 4], @band[2 * r + 1])
      k = 2 * @bstart[b]
      stop = 2 * @bstart[b + 1]
      inside = false
      while k < stop
        i = @edges[k]
        j = @edges[k + 1]
        yi = @pts[i + 1]
        yj = @pts[j + 1]
        if (yi > lat) != (yj > lat)
          xi = @pts[i]
          inside = !inside if lng < (@pts[j] - xi) * (lat - yi) / (yj - yi) + xi
        end
        k += 2
      end
      inside
    end

    # Same answer as a ray cast over the whole of ring r: what
    # innermost_ring does for one ring.
    def contains(r, lng, lat)
      boxed(r, r + 1, lng, lat) == 1 && cast(r, lng, lat)
    end

    # The area of ring r's bounding box.
    def area(r)
      b = r * 5
      (@box[b + 2] - @box[b]) * (@box[b + 3] - @box[b + 1])
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

  # A static R-tree over boxes, bulk loaded by sort-tile-recursive packing
  # into nodes of up to NODE_SIZE children — rstar's default maximum. Item
  # i's box is box[2 * dims * i ...]: its low corner, then its high corner
  # (a point has both the same).
  #
  # Node n's children are kids[first[n], count[n]]: item numbers if leaf[n]
  # is 1, else node numbers. Its box is nbox[2 * dims * n ...], laid out as
  # an item's.
  #
  # The searches keep their nodes to visit on a stack rather than recurse,
  # and test a node's box before they push it: their loops over children
  # then do nothing but read and compare, which Spinel compiles with the
  # arrays' headers held in C locals.
  class RTree
    NODE_SIZE = 6

    attr_reader :root, :first, :count, :leaf, :kids, :nbox, :box, :hits

    def initialize(dims, box)
      @dims = dims
      @box = box
      @first = []
      @count = []
      @leaf = []
      @kids = []
      @nbox = []
      @root = -1
      # The nodes a search has still to visit, and containing2's answer,
      # kept between searches.
      @stack = Array.new(64, 0)
      @hits = Array.new(16, 0)
      n = box.size / (2 * dims)
      if n > 0
        level = pack((0...n).to_a, box, 1)
        level = pack(level, @nbox, 0) while level.size > 1
        @root = level[0]
      end
    end

    # Parent nodes over `ids`, whose boxes are in `boxes`.
    def pack(ids, boxes, leaf)
      d = @dims
      w = 2 * d
      n = ids.size
      centers = Array.new(n * d, 0.0)
      p = 0
      while p < n
        id = ids[p]
        k = 0
        while k < d
          centers[p * d + k] = (boxes[id * w + k] + boxes[id * w + d + k]) * 0.5
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
          @nbox << INF
          k += 1
        end
        k = 0
        while k < d
          @nbox << -INF
          k += 1
        end
        c = 0
        while c < cnt
          id = ids[order[start + c]]
          @kids << id
          k = 0
          while k < d
            v = boxes[id * w + k]
            @nbox[node * w + k] = v if v < @nbox[node * w + k]
            v = boxes[id * w + d + k]
            @nbox[node * w + d + k] = v if v > @nbox[node * w + d + k]
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

    # The items of a 2-d tree whose box holds (x, y), into hits[0 ...]; how
    # many, in no particular order.
    def containing2(x, y)
      root = @root
      return 0 if root < 0
      b = root * 4
      return 0 if x < @nbox[b] || x > @nbox[b + 2] || y < @nbox[b + 1] || y > @nbox[b + 3]
      @stack[0] = root
      sp = 1
      n = 0
      while sp > 0
        sp -= 1
        node = @stack[sp]
        s = @first[node]
        e = s + @count[node]
        if @leaf[node] == 1
          while s < e
            b = @kids[s] * 4
            if x >= @box[b] && x <= @box[b + 2] && y >= @box[b + 1] && y <= @box[b + 3]
              @hits[n] = @kids[s]
              n += 1
            end
            s += 1
          end
        else
          while s < e
            b = @kids[s] * 4
            unless x < @nbox[b] || x > @nbox[b + 2] || y < @nbox[b + 1] || y > @nbox[b + 3]
              @stack[sp] = @kids[s]
              sp += 1
            end
            s += 1
          end
        end
      end
      n
    end

    # Squared distance from (x, y, z) to node's box in a 3-d tree.
    def mindist3(node, x, y, z)
      b = node * 6
      lo = @nbox[b]
      hi = @nbox[b + 3]
      dx = x < lo ? lo - x : (x > hi ? x - hi : 0.0)
      lo = @nbox[b + 1]
      hi = @nbox[b + 4]
      dy = y < lo ? lo - y : (y > hi ? y - hi : 0.0)
      lo = @nbox[b + 2]
      hi = @nbox[b + 5]
      dz = z < lo ? lo - z : (z > hi ? z - hi : 0.0)
      dx * dx + dy * dy + dz * dz
    end

    # Whether a point item of a 3-d tree is within squared distance r2.
    def any_within3?(x, y, z, r2)
      root = @root
      return false if root < 0 || mindist3(root, x, y, z) > r2
      @stack[0] = root
      sp = 1
      found = false
      while sp > 0 && !found
        sp -= 1
        node = @stack[sp]
        s = @first[node]
        e = s + @count[node]
        if @leaf[node] == 1
          while s < e
            b = @kids[s] * 6
            dx = @box[b] - x
            dy = @box[b + 1] - y
            dz = @box[b + 2] - z
            if dx * dx + dy * dy + dz * dz <= r2
              found = true
              break
            end
            s += 1
          end
        else
          while s < e
            b = @kids[s] * 6
            lo = @nbox[b]
            hi = @nbox[b + 3]
            dx = x < lo ? lo - x : (x > hi ? x - hi : 0.0)
            lo = @nbox[b + 1]
            hi = @nbox[b + 4]
            dy = y < lo ? lo - y : (y > hi ? y - hi : 0.0)
            lo = @nbox[b + 2]
            hi = @nbox[b + 5]
            dz = z < lo ? lo - z : (z > hi ? z - hi : 0.0)
            unless dx * dx + dy * dy + dz * dz > r2
              @stack[sp] = @kids[s]
              sp += 1
            end
            s += 1
          end
        end
      end
      found
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
      @env_box = []
      parse_countries(JsonReader.new(countries_json, 0))
      @country_tree = RTree.new(2, @env_box)

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
      pts = @rings.pts
      r = @feature_ring0[feature]
      stop = r + @feature_rings[feature]
      while r < stop
        i = 2 * @rings.first[r]
        e = i + 2 * @rings.n[r]
        while i < e
          lng = pts[i]
          lat = pts[i + 1]
          min_lat = lat if lat < min_lat
          max_lat = lat if lat > max_lat
          min_lng = lng if lng < min_lng
          max_lng = lng if lng > max_lng
          i += 2
        end
        r += 1
      end
      return nil if min_lat >= 90.0 || max_lat <= -90.0
      @env_box << min_lng << min_lat << max_lng << max_lat
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
      n = @country_tree.containing2(lng, lat)
      best = -1
      best_size = 0.0
      best_feature = 0
      k = 0
      while k < n
        env = @country_tree.hits[k]
        feature = @env_feature[env]
        size = innermost_ring(feature, lng, lat)
        if size >= 0.0 && (best < 0 || size < best_size || (size == best_size && feature < best_feature))
          best = env
          best_size = size
          best_feature = feature
        end
        k += 1
      end
      best < 0 ? nil : @env_code[best]
    end

    # If a country's rings hold the point, the bounding-box area of the
    # smallest of them around it; else -1. Held means by the even-odd rule
    # over all the rings: a hole is a ring too, so a point in an enclave cut
    # out of the country (Lesotho in South Africa) is held twice, and is not
    # the country's.
    def innermost_ring(feature, lng, lat)
      r = @feature_ring0[feature]
      n = @rings.boxed(r, r + @feature_rings[feature], lng, lat)
      inside = false
      smallest = INF
      k = 0
      while k < n
        r = @rings.hits[k]
        if @rings.cast(r, lng, lat)
          inside = !inside
          size = @rings.area(r)
          smallest = size if size < smallest
        end
        k += 1
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
      box = []
      indices.each do |i|
        la = lats[i] * DEG
        ln = lngs[i] * DEG
        x = Math.cos(la) * Math.cos(ln)
        y = Math.cos(la) * Math.sin(ln)
        z = Math.sin(la)
        box << x << y << z << x << y << z
      end
      @tree = RTree.new(3, box)
      # The tree's arrays, for nearest to read through instance variables.
      @first = @tree.first
      @count = @tree.count
      @leaf = @tree.leaf
      @kids = @tree.kids
      @nbox = @tree.nbox
      @box = @tree.box
      # nearest's binary min-heap of (distance, reference) pairs, the first
      # @heap_n of these, kept between searches; and the children of the
      # node it expands.
      @heap_d = Array.new(64, 0.0)
      @heap_r = Array.new(64, 0)
      @heap_n = 0
      @kid_d = Array.new(RTree::NODE_SIZE, 0.0)
      @kid_r = Array.new(RTree::NODE_SIZE, 0)
    end

    # Up to `limit` airports nearest to (lat, lng) by haversine, closest
    # first and ties to the lower index; with has_max, farther than max_km
    # and NaN distances are dropped. Exactly what computing every distance
    # and sorting gives, but it stops once no farther airport can make the cut.
    def nearest(lat, lng, has_max, max_km, limit)
      hd = []
      hi = []
      if limit > 0 && @tree.root >= 0
        la = lat * DEG
        ln = lng * DEG
        qx = Math.cos(la) * Math.cos(ln)
        qy = Math.cos(la) * Math.sin(ln)
        qz = Math.sin(la)
        cutoff = has_max ? AirportFinder.chord2_bound(max_km) : INF
        # Haversine can come out NaN at the antipode, and total_cmp may sort
        # that first; without max_km to drop it, look at every airport.
        exhaustive = !has_max && @tree.any_within3?(-qx, -qy, -qz, 1e-9)

        # Best first: nodes by the distance to their box, airports (encoded
        # -1 - item) by their own, so airports come out closest first.
        @heap_n = 0
        heap_push(@tree.mindist3(@tree.root, qx, qy, qz), @tree.root)
        while @heap_n > 0
          d2 = @heap_d[0]
          ref = @heap_r[0]
          heap_pop
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
            # The children's distances first, in a loop of reads and
            # arithmetic alone; then onto the heap, in the same order.
            s = @first[ref]
            e = s + @count[ref]
            m = 0
            if @leaf[ref] == 1
              while s < e
                o = @kids[s] * 6
                dx = @box[o] - qx
                dy = @box[o + 1] - qy
                dz = @box[o + 2] - qz
                @kid_d[m] = dx * dx + dy * dy + dz * dz
                @kid_r[m] = -1 - @kids[s]
                m += 1
                s += 1
              end
            else
              while s < e
                o = @kids[s] * 6
                lo = @nbox[o]
                hi3 = @nbox[o + 3]
                dx = qx < lo ? lo - qx : (qx > hi3 ? qx - hi3 : 0.0)
                lo = @nbox[o + 1]
                hi3 = @nbox[o + 4]
                dy = qy < lo ? lo - qy : (qy > hi3 ? qy - hi3 : 0.0)
                lo = @nbox[o + 2]
                hi3 = @nbox[o + 5]
                dz = qz < lo ? lo - qz : (qz > hi3 ? qz - hi3 : 0.0)
                @kid_d[m] = dx * dx + dy * dy + dz * dz
                @kid_r[m] = @kids[s]
                m += 1
                s += 1
              end
            end
            k = 0
            while k < m
              heap_push(@kid_d[k], @kid_r[k])
              k += 1
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

    def heap_push(d, r)
      i = @heap_n
      @heap_n = i + 1
      if i == @heap_d.size
        @heap_d << d
        @heap_r << r
      end
      while i > 0
        p = (i - 1) / 2
        break if @heap_d[p] <= d
        @heap_d[i] = @heap_d[p]
        @heap_r[i] = @heap_r[p]
        i = p
      end
      @heap_d[i] = d
      @heap_r[i] = r
    end

    def heap_pop
      n = @heap_n - 1
      @heap_n = n
      return if n == 0
      d = @heap_d[n]
      r = @heap_r[n]
      i = 0
      while true
        c = 2 * i + 1
        break if c >= n
        c += 1 if c + 1 < n && @heap_d[c + 1] < @heap_d[c]
        break if d <= @heap_d[c]
        @heap_d[i] = @heap_d[c]
        @heap_r[i] = @heap_r[c]
        i = c
      end
      @heap_d[i] = d
      @heap_r[i] = r
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
    i = nearest_airport_index(lat, lng)
    st = state
    [st.code_of(i), display_name(st, st.ap_city[i], st.ap_name[i], st.ap_country[i])]
  end

  # find_nearest_airport's airport, as its index in the embedded data.
  def self.nearest_airport_index(lat, lng)
    raise Error, "invalid coordinates" unless valid_coords?(lat, lng)
    loc = nearest_in_country(state, lat, normalize_lng(lng))
    raise Error, loc.error if loc.index < 0
    loc.index
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
    i = airport_index(iata)
    i < 0 ? nil : state.airports[i]
  end

  # The index in the embedded data of the airport with this IATA code, or -1.
  def self.airport_index(iata)
    state.airports_by_iata.fetch(iata.to_s.strip.upcase, -1).to_i
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

  # Resolved with indices into the embedded data: the airport (-1 for none)
  # and find_nearest_airport's for the coordinates.
  class ResolvedAt
    attr_reader :index, :distance_km, :resolution, :nearest

    def initialize(index, distance_km, resolution, nearest)
      @index = index
      @distance_km = distance_km
      @resolution = resolution
      @nearest = nearest
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
      hits = nearest_hits(lat, lng, limit, !country.nil?, country.nil? ? "" : country, !max_km.nil?, max_km.nil? ? 0.0 : max_km)
      airports = AirportFinder.state.airports
      out = []
      k = 0
      while k < hits.size
        out << Nearby.new(airports[hits.i[k]], hits.d[k])
        k += 1
      end
      out
    end

    # #nearest's airports as Hits: indices into the embedded data. country
    # (any case) counts if has_country, max_km if has_max.
    def nearest_hits(lat, lng, limit, has_country, country, has_max, max_km)
      raise Error, "invalid coordinates" unless AirportFinder.valid_coords?(lat, lng)
      pool_hits(lat, AirportFinder.normalize_lng(lng), limit, has_country, country.downcase, has_max, max_km)
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
      r = resolve_at(lat, lng, !foreign_max_km.nil?, foreign_max_km.nil? ? 0.0 : foreign_max_km)
      return nil if r.index < 0
      st = AirportFinder.state
      Resolved.new(st.airports[r.index], r.distance_km, r.resolution, st.code_of(r.nearest))
    end

    # #resolve with airports as indices into the embedded data: index -1
    # for nil. foreign_max_km counts if has_max.
    def resolve_at(lat, lng, has_max, foreign_max_km)
      raise Error, "invalid coordinates" unless AirportFinder.valid_coords?(lat, lng)
      lng = AirportFinder.normalize_lng(lng)
      st = AirportFinder.state
      loc = AirportFinder.nearest_in_country(st, lat, lng)
      return ResolvedAt.new(-1, 0.0, :nearest, -1) if loc.index < 0
      nearest = loc.index

      # A country without airports gets find_nearest_airport's answer from a
      # neighbour up to 4000 km away — that counts as foreign, so it is only
      # taken within foreign_max_km below.
      domestic = st.ap_country[nearest].downcase == loc.country
      if domestic && @members.key?(nearest)
        d = AirportFinder.haversine(lat, lng, st.ap_lat[nearest], st.ap_lng[nearest])
        return ResolvedAt.new(nearest, d, :nearest, nearest)
      end
      hits = pool_hits(lat, lng, 1, true, loc.country, false, 0.0)
      resolution = :same_country
      if hits.size == 0
        hits = pool_hits(lat, lng, 1, false, "", has_max, foreign_max_km)
        resolution = :nearby_foreign
      end
      return ResolvedAt.new(-1, 0.0, :nearest, nearest) if hits.size == 0
      ResolvedAt.new(hits.i[0], hits.d[0], resolution, nearest)
    end
  end
end
