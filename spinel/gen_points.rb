# Writes the query points both harnesses read (one "lat lng" per line, in
# Float#to_s's shortest round-trip form) and the airport subset they search.
#
#   ruby gen_points.rb
#
# points/near_airports.txt  within ±0.25° of a random airport: populated places
# points/anywhere.txt       uniform over the sphere, ~70% ocean
# points/verify.txt         both kinds, more of them, plus edge cases
# points/subset.txt         every 10th embedded airport's IATA code

require "json"

root = File.expand_path("..", __dir__)
airports = JSON.parse(File.read(File.join(root, "data", "airports.json")))
dir = File.join(__dir__, "points")
Dir.mkdir(dir) unless Dir.exist?(dir)

def near_airports(airports, rng, n)
  Array.new(n) do
    ap = airports[rng.rand(airports.size)]
    lat = (ap["lat"] + rng.rand(-0.25..0.25)).clamp(-90.0, 90.0)
    [lat, ap["lng"] + rng.rand(-0.25..0.25)]
  end
end

def anywhere(rng, n)
  Array.new(n) do
    [Math.asin(rng.rand(-1.0..1.0)) * 180.0 / Math::PI, rng.rand(-180.0...180.0)]
  end
end

def edge_cases(airports)
  pts = []
  # Poles, the antimeridian and longitudes that need wrapping
  [-90.0, -89.9, 0.0, 89.9, 90.0].each { |lat| [-180.0, -179.99, 0.0, 179.99, 180.0].each { |lng| pts << [lat, lng] } }
  [[37.5665, 126.978 + 360.0], [37.5665, 126.978 - 720.0], [1.0, 1e300], [-33.9, -1e15], [51.5, 539.9]].each { |p| pts << p }
  # The special-cased islands, Andorra, South Georgia, and Hyderabad
  [[37.24, 131.86], [-37.1, -12.3], [-49.3, 69.5], [-54.28, -36.5], [-54.4, 3.35], [10.3, -109.2],
   [42.5, 1.52], [17.385, 78.486], [26.68, -80.09]].each { |p| pts << p }
  # Exactly on an airport, and at its antipode
  airports.each_with_index do |ap, i|
    next unless i % 50 == 0
    pts << [ap["lat"], ap["lng"]]
    lng = ap["lng"] + 180.0
    pts << [-ap["lat"], lng > 180.0 ? lng - 360.0 : lng]
  end
  pts
end

def write(path, pts)
  File.write(path, pts.map { |lat, lng| "#{lat} #{lng}\n" }.join)
  puts "#{path}: #{pts.size} points"
end

write(File.join(dir, "near_airports.txt"), near_airports(airports, Random.new(1), 10_000))
write(File.join(dir, "anywhere.txt"), anywhere(Random.new(2), 10_000))
write(File.join(dir, "verify.txt"),
      anywhere(Random.new(3), 100_000) + near_airports(airports, Random.new(4), 50_000) + edge_cases(airports))
subset = airports.each_with_index.select { |_, i| i % 10 == 0 }.map { |ap, _| ap["iata"] }
File.write(File.join(dir, "subset.txt"), subset.join("\n") + "\n")
puts "#{File.join(dir, "subset.txt")}: #{subset.size} airports"
