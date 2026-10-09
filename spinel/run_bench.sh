#!/usr/bin/env bash
# Builds the crate's harness (examples/compare.rs) and the Spinel port, then
# benchmarks them -- and the same Ruby under CRuby -- in interleaved rounds,
# so that background load falls on every implementation alike.
#
#   SPINEL=~/projects/spinel/spinel ROUNDS=5 ./run_bench.sh
#
# Writes out/bench-*.tsv and prints the summary (summarize.rb).
set -euo pipefail
cd "$(dirname "$0")"

SPINEL=${SPINEL:-spinel}
RUBY=${RUBY:-ruby}
ROUNDS=${ROUNDS:-5}
BUDGET_MS=${BUDGET_MS:-1500}  # per benchmark per round (compiled)
INIT_RUNS=${INIT_RUNS:-10}
P=points
POINTS="$P/near_airports.txt $P/anywhere.txt $P/subset.txt"

[ -f embedded_data.rb ] || "$RUBY" gen_data.rb
[ -f $P/subset.txt ] || "$RUBY" gen_points.rb
mkdir -p build out
(cd .. && cargo build --release --example compare 2>&1 | tail -1)
"$SPINEL" bench.rb -o build/bench --jobs=1
RUST=../target/release/examples/compare

out=out/bench-$(date +%Y%m%d-%H%M%S).tsv
: > "$out"
record() { # impl round < "name<TAB>ns_per_op<TAB>passes<TAB>check"
  while IFS=$'\t' read -r name ns passes check; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$name" "$ns" "$passes" "$check" >> "$out"
  done
}

for round in $(seq 1 "$ROUNDS"); do
  echo "round $round/$ROUNDS" >&2
  $RUST run $POINTS "$BUDGET_MS" 3 | record rust "$round"
  ./build/bench run $POINTS "$BUDGET_MS" 3 | record spinel "$round"
  "$RUBY" --yjit bench.rb run $POINTS 0 2 | record cruby-yjit "$round"
  "$RUBY" bench.rb run $POINTS 0 1 | record cruby "$round"
done

for run in $(seq 1 "$INIT_RUNS"); do
  printf 'init (first call)\t%s\t1\t0\n' "$($RUST init)" | record rust "$run"
  printf 'init (first call)\t%s\t1\t0\n' "$(./build/bench init)" | record spinel "$run"
  if [ "$run" -le 3 ]; then
    printf 'init (first call)\t%s\t1\t0\n' "$("$RUBY" --yjit bench.rb init)" | record cruby-yjit "$run"
    printf 'init (first call)\t%s\t1\t0\n' "$("$RUBY" bench.rb init)" | record cruby "$run"
  fi
done

rss() { /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident set size/ { print $1 }'; }
printf 'max RSS after init (bytes)\t%s\t1\t0\n' "$(rss $RUST init)" | record rust 1
printf 'max RSS after init (bytes)\t%s\t1\t0\n' "$(rss ./build/bench init)" | record spinel 1
printf 'max RSS after init (bytes)\t%s\t1\t0\n' "$(rss "$RUBY" --yjit bench.rb init)" | record cruby-yjit 1
printf 'max RSS after init (bytes)\t%s\t1\t0\n' "$(rss "$RUBY" bench.rb init)" | record cruby 1

echo "wrote $out" >&2
"$RUBY" summarize.rb "$out"
