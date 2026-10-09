# Compares two dumps (bench dump / compare dump) line by line. Distances are
# printed by Ruby's Float#to_s and Rust's Display, both shortest round-trip,
# so they are compared as the doubles they parse to: equal means bit-equal.
#
#   ruby compare.rb A.tsv B.tsv

FIELDS = %w[find_nearest_airport country_at nearest(3) nearest(2,500km) resolve(300km) resolve].freeze

def same_field?(a, b)
  return true if a == b
  ta = a.split(/[,:]/, -1)
  tb = b.split(/[,:]/, -1)
  return false unless ta.size == tb.size
  ta.zip(tb).all? do |x, y|
    next true if x == y
    fx = Float(x, exception: false)
    fy = Float(y, exception: false)
    !fx.nil? && !fy.nil? && fx == fy
  end
end

a = File.readlines(ARGV[0], chomp: true)
b = File.readlines(ARGV[1], chomp: true)
abort "line counts differ: #{a.size} vs #{b.size}" unless a.size == b.size
bad = Hash.new(0)
shown = 0
a.each_with_index do |la, i|
  fa = la.split("\t", -1)
  fb = b[i].split("\t", -1)
  FIELDS.each_with_index do |name, k|
    next if same_field?(fa[k].to_s, fb[k].to_s)
    bad[name] += 1
    if shown < 10
      shown += 1
      puts "line #{i + 1} #{name}:\n  #{fa[k]}\n  #{fb[k]}"
    end
  end
end
if bad.empty?
  puts "identical: #{a.size} points x #{FIELDS.size} answers"
else
  puts "DIFFERENT: #{bad}"
  exit 1
end
