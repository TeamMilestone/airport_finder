# Summarizes run_bench.sh output: the median over rounds of each
# benchmark's per-round median, per implementation, as a Markdown table.
#
#   ruby summarize.rb out/bench-*.tsv

IMPLS = %w[rust spinel cruby-yjit cruby].freeze

def median(xs)
  s = xs.sort
  s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
end

def show(name, ns)
  return "%.1f MB" % (ns / 1_048_576.0) if name.start_with?("max RSS")
  return "%.1f ms" % (ns / 1e6) if ns >= 1e6
  return "%.2f µs" % (ns / 1e3) if ns >= 1e3
  "%.0f ns" % ns
end

rows = Hash.new { |h, k| h[k] = Hash.new { |g, i| g[i] = [] } }
checks = Hash.new { |h, k| h[k] = {} }
ARGV.each do |path|
  File.foreach(path) do |line|
    impl, _round, name, ns, _passes, check = line.chomp.split("\t")
    rows[name][impl] << ns.to_f
    checks[name][impl] = check
  end
end

puts "| | " + IMPLS.join(" | ") + " | spinel / rust | cruby-yjit / spinel |"
puts "|---" * (IMPLS.size + 3) + "|"
rows.each do |name, by_impl|
  med = IMPLS.to_h { |i| [i, by_impl[i].empty? ? nil : median(by_impl[i])] }
  cells = IMPLS.map { |i| med[i] ? show(name, med[i]) : "-" }
  ratio = ->(a, b) { med[a] && med[b] ? "%.2f×" % (med[a] / med[b]) : "-" }
  puts "| #{name} | #{cells.join(" | ")} | #{ratio.("spinel", "rust")} | #{ratio.("cruby-yjit", "spinel")} |"
end

bad = checks.select { |name, c| !name.start_with?("init", "max RSS") && c.values.uniq.size > 1 }
puts
puts bad.empty? ? "Checksums agree across implementations." : "CHECKSUMS DIFFER: #{bad}"
