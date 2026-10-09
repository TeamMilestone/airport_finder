# Benchmark and dump harness: the Ruby side of examples/compare.rs, doing
# the same calls in the same order and printing the same format.
#
#   bench dump POINTS SUBSET          one line of answers per point
#   bench init                        ns taken by the first lookup
#   bench run NEAR ANYWHERE SUBSET [BUDGET_MS] [MIN_PASSES]

require_relative "airport_finder"

def now_ns
  Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
end

# [lat, lng] of every line, flattened: [lat0, lng0, lat1, lng1, ...].
def read_points(path)
  coords = []
  File.readlines(path).each do |line|
    f = line.split(" ")
    coords << f[0].to_f << f[1].to_f
  end
  coords
end

def lats_of(coords)
  out = []
  i = 0
  while i < coords.size
    out << coords[i]
    i += 2
  end
  out
end

def lngs_of(coords)
  out = []
  i = 1
  while i < coords.size
    out << coords[i]
    i += 2
  end
  out
end

def read_codes(path)
  codes = []
  File.readlines(path).each do |line|
    code = line.strip
    codes << code unless code.empty?
  end
  codes
end

def find_text(lat, lng)
  code, name = AirportFinder.find_nearest_airport(lat, lng)
  "#{code}|#{name}"
rescue AirportFinder::Error => e
  "!#{e.message}"
end

def nearby_text(hits)
  hits.map { |h| "#{h.airport.iata}:#{h.distance_km}" }.join(",")
end

def resolved_text(r)
  return "-" if r.nil?
  "#{r.airport.iata}:#{r.distance_km}:#{r.resolution}:#{r.nearest_code}"
end

def dump(points, subset_path)
  coords = read_points(points)
  lats = lats_of(coords)
  lngs = lngs_of(coords)
  all = AirportFinder::AirportSet.all
  subset = AirportFinder::AirportSet.new(read_codes(subset_path))
  out = []
  lats.each_with_index do |lat, i|
    lng = lngs[i]
    country = AirportFinder.country_at(lat, lng)
    out << [
      find_text(lat, lng),
      country.nil? ? "-" : country,
      nearby_text(all.nearest(lat, lng, limit: 3)),
      nearby_text(all.nearest(lat, lng, limit: 2, max_km: 500.0)),
      resolved_text(subset.resolve(lat, lng, foreign_max_km: 300.0)),
      resolved_text(subset.resolve(lat, lng))
    ].join("\t")
    if out.size == 1000
      puts out.join("\n")
      out = []
    end
  end
  puts out.join("\n") unless out.empty?
end

# Runs the block in passes until budget_ms have passed and at least
# min_passes ran; prints the median ns per op.
def measure(name, ops, budget_ms, min_passes)
  times = []
  check = 0
  start = now_ns
  while times.size < min_passes || now_ns - start < budget_ms * 1_000_000
    t0 = now_ns
    check = yield
    times << now_ns - t0
  end
  times.sort!
  median = times[times.size / 2]
  puts "#{name}\t#{median.to_f / ops}\t#{times.size}\t#{check}"
end

def run(near_path, anywhere_path, subset_path, budget_ms, min_passes)
  near = read_points(near_path)
  near_lat = lats_of(near)
  near_lng = lngs_of(near)
  any = read_points(anywhere_path)
  any_lat = lats_of(any)
  any_lng = lngs_of(any)
  codes = read_codes(subset_path)
  AirportFinder.find_nearest_airport(37.5665, 126.978) # initialize

  measure("find_nearest_airport/near_airports", near_lat.size, budget_ms, min_passes) do
    sum = 0
    near_lat.each_with_index do |lat, i|
      begin
        sum += AirportFinder.find_nearest_airport(lat, near_lng[i])[0].bytesize
      rescue AirportFinder::Error
        sum += 1
      end
    end
    sum
  end
  measure("find_nearest_airport/anywhere", any_lat.size, budget_ms, min_passes) do
    sum = 0
    any_lat.each_with_index do |lat, i|
      begin
        sum += AirportFinder.find_nearest_airport(lat, any_lng[i])[0].bytesize
      rescue AirportFinder::Error
        sum += 1
      end
    end
    sum
  end
  measure("country_at/anywhere", any_lat.size, budget_ms, min_passes) do
    sum = 0
    any_lat.each_with_index do |lat, i|
      c = AirportFinder.country_at(lat, any_lng[i])
      sum += c.nil? ? 1 : c.bytesize
    end
    sum
  end
  all = AirportFinder::AirportSet.all
  measure("AirportSet.all.nearest(limit 5)/anywhere", any_lat.size, budget_ms, min_passes) do
    sum = 0
    any_lat.each_with_index do |lat, i|
      sum += all.nearest(lat, any_lng[i], limit: 5).size
    end
    sum
  end
  subset = AirportFinder::AirportSet.new(codes)
  measure("subset.resolve(300 km)/near_airports", near_lat.size, budget_ms, min_passes) do
    sum = 0
    near_lat.each_with_index do |lat, i|
      r = subset.resolve(lat, near_lng[i], foreign_max_km: 300.0)
      sum += r.nil? ? 1 : r.nearest_code.bytesize
    end
    sum
  end
  measure("AirportSet.all (build)", 1, budget_ms, min_passes) do
    AirportFinder::AirportSet.all.size
  end
end

mode = ARGV[0]
if mode == "dump"
  dump(ARGV[1], ARGV[2])
elsif mode == "init"
  t0 = now_ns
  AirportFinder.find_nearest_airport(37.5665, 126.978)
  puts now_ns - t0
elsif mode == "run"
  run(ARGV[1], ARGV[2], ARGV[3], ARGV.size > 4 ? ARGV[4].to_i : 2000, ARGV.size > 5 ? ARGV[5].to_i : 5)
else
  puts "usage: bench dump POINTS SUBSET | init | run NEAR ANYWHERE SUBSET [BUDGET_MS] [MIN_PASSES]"
  exit 2
end
