#!/usr/bin/env bash
# Hermetic harness for scripts/elixir-test-partition.sh (task-bc3ef53758b916a8).
#
# The Elixir Test cells pick their files with that script, so a defect in it is
# a silently SMALLER required suite. Every arm below is a way that could happen
# (a file in no cell, a file in two, cells that disagree because input order
# differed, a new file the weights never saw) or a refusal that must stay loud.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/elixir-test-partition.sh"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   — $1"; }
no() { fail=$((fail + 1)); echo "  FAIL — $1"; }

# Fixture: 12 files, two heavy, plus one the weights never saw.
cat >"$TMP/w.tsv" <<'EOF'
test/a_test.exs	120.00
test/b_test.exs	45.50
test/c_test.exs	30.00
test/d_test.exs	10.00
test/e_test.exs	9.00
test/f_test.exs	8.00
test/g_test.exs	1.00
test/h_test.exs	1.00
test/i_test.exs	0.50
test/j_test.exs	0.20
test/gone_test.exs	99.00
EOF
printf '%s\n' test/a_test.exs test/b_test.exs test/c_test.exs test/d_test.exs test/e_test.exs \
  test/f_test.exs test/g_test.exs test/h_test.exs test/i_test.exs test/j_test.exs test/new_test.exs \
  >"$TMP/cands.txt"

cells_of() { # $1 = n, $2 = candidates file, $3 = weights -> cell files in $TMP/cell.<k>
  local k
  for k in $(seq 1 "$1"); do
    bash "$SCRIPT" --cell "$k" "$1" "$3" <"$2" >"$TMP/cell.$k"
  done
}

echo "case 1: every candidate lands in exactly one cell, for 1..4 cells"
for n in 1 2 3 4; do
  cells_of "$n" "$TMP/cands.txt" "$TMP/w.tsv"
  got="$(cat "$TMP"/cell.[1-$n] | LC_ALL=C sort)"
  want="$(LC_ALL=C sort "$TMP/cands.txt")"
  dups="$(cat "$TMP"/cell.[1-$n] | LC_ALL=C sort | uniq -d)"
  if [ "$got" = "$want" ] && [ -z "$dups" ]; then
    ok "n=$n: union == candidates, no file twice"
  else
    no "n=$n: union/disjointness broken (dups: ${dups:-none})"
  fi
  rm -f "$TMP"/cell.*
done

echo "case 2: the assignment is a function of the SET, not of input order"
cells_of 3 "$TMP/cands.txt" "$TMP/w.tsv"
awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' "$TMP/cands.txt" >"$TMP/rev.txt"
printf 'test/c_test.exs\n' >>"$TMP/rev.txt" # a duplicate line changes nothing either
same=1
for k in 1 2 3; do
  bash "$SCRIPT" --cell "$k" 3 "$TMP/w.tsv" <"$TMP/rev.txt" | diff -q - "$TMP/cell.$k" >/dev/null || same=0
done
if [ "$same" = 1 ]; then ok "reversed + duplicated input -> identical cells"; else no "input order changed a cell"; fi

echo "case 3: weights steer — the two heaviest files never share a cell"
a_cell="$(grep -lx 'test/a_test.exs' "$TMP"/cell.* | head -1)"
b_cell="$(grep -lx 'test/b_test.exs' "$TMP"/cell.* | head -1)"
if [ -n "$a_cell" ] && [ "$a_cell" != "$b_cell" ]; then ok "a (120 s) and b (45.5 s) are in different cells"; else no "a and b share $a_cell"; fi

echo "case 4: a file the weights never saw is placed, and a gone file costs nothing"
if cat "$TMP"/cell.* | grep -qx 'test/new_test.exs'; then ok "new_test.exs is in a cell"; else no "new_test.exs was dropped"; fi
if cat "$TMP"/cell.* | grep -qx 'test/gone_test.exs'; then no "a weights-only path was run"; else ok "gone_test.exs (weights only) is not run"; fi
plan="$(ELIXIR_PARTITION_P1_EXTRA=0 bash "$SCRIPT" --plan 3 "$TMP/w.tsv" <"$TMP/cands.txt")"
total="$(printf '%s\n' "$plan" | awk -F'\t' '{ s += $2 } END { printf "%.1f", s }')"
# known 225.2 s + new file at the median known weight (8.00 or 9.00 → 9.00 for 10 values: the 5th of sorted)
if [ "$total" = "233.2" ] || [ "$total" = "234.2" ]; then ok "plan total $total = known weights + one median"; else no "plan total $total"; fi

echo "case 5: refusals are loud (exit 2), never an empty or partial answer"
refuse() { # $1 label, rest = args; stdin from $IN
  local rc=0
  bash "$SCRIPT" "${@:2}" <"$IN" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then ok "$1 -> exit 2"; else no "$1 -> exit $rc"; fi
}
IN="$TMP/cands.txt" refuse "cell 4 of 3" --cell 4 3 "$TMP/w.tsv"
IN="$TMP/cands.txt" refuse "cell 0 of 3" --cell 0 3 "$TMP/w.tsv"
IN="$TMP/cands.txt" refuse "n not a number" --cell 1 x "$TMP/w.tsv"
IN="$TMP/cands.txt" refuse "unreadable weights" --cell 1 3 "$TMP/nope.tsv"
IN=/dev/null refuse "no candidates" --cell 1 3 "$TMP/w.tsv"
IN=/dev/null refuse "unknown mode" --bogus

echo "case 6: a narrowed selection may leave a cell EMPTY — empty output, exit 0"
printf 'test/a_test.exs\n' >"$TMP/one.txt"
empties=0
for k in 1 2 3; do
  out="$(bash "$SCRIPT" --cell "$k" 3 "$TMP/w.tsv" <"$TMP/one.txt")"
  [ -n "$out" ] || empties=$((empties + 1))
done
if [ "$empties" = 2 ]; then ok "one file, three cells: exactly two cells are empty"; else no "$empties empty cells"; fi

echo "case 7: --weights-from-logs reads module gaps out of a --trace log"
cat >"$TMP/p1.log" <<'EOF'
2026-10-01T22:00:00.0000000Z Barkpark.ATest [test/a_test.exs]
2026-10-01T22:00:00.5000000Z   * test x (1.0ms) [L#3]
2026-10-01T22:00:02.0000000Z Barkpark.BTest [test/b_test.exs]
2026-10-01T22:00:05.2500000Z Finished in 5.3 seconds (1.0s async, 4.3s sync)
EOF
cat >"$TMP/p2.log" <<'EOF'
2026-09-30T23:59:59.0000000Z Barkpark.CTest [test/c_test.exs]
2026-10-01T00:00:01.0000000Z Finished in 2.0 seconds (0.0s async, 2.0s sync)
EOF
wl="$(bash "$SCRIPT" --weights-from-logs "$TMP/p1.log" "$TMP/p2.log")"
want="$(printf 'test/a_test.exs\t2.00\ntest/b_test.exs\t3.25\ntest/c_test.exs\t2.00')"
if [ "$wl" = "$want" ]; then ok "a=2.00 b=3.25 c=2.00 (across a month-end midnight)"; else no "got: $(printf '%s' "$wl" | tr '\n' ' ')"; fi

echo "case 8: the REAL tree and the CHECKED-IN weights — full cover, and balanced"
if [ -d "$REAL_ROOT/api/test" ] && [ -r "$HERE/elixir-test-weights.tsv" ]; then
  (cd "$REAL_ROOT/api" && find test -name '*_test.exs' -not -path '*/.*') | LC_ALL=C sort >"$TMP/real.txt"
  for k in 1 2 3; do
    bash "$SCRIPT" --cell "$k" 3 <"$TMP/real.txt" >"$TMP/real.$k"
  done
  if [ "$(cat "$TMP"/real.[123] | LC_ALL=C sort)" = "$(cat "$TMP/real.txt")" ]; then
    ok "$(wc -l <"$TMP/real.txt" | tr -d ' ') real test files, each in exactly one of 3 cells"
  else
    no "the real tree is not covered exactly once"
  fi
  spread="$(bash "$SCRIPT" --plan 3 <"$TMP/real.txt" | awk -F'\t' 'NR == 1 { mn = mx = $2 } { if ($2 < mn) mn = $2; if ($2 > mx) mx = $2 } END { printf "%d", (mx - mn) * 100 / mx }')"
  if [ "$spread" -le 5 ]; then ok "planned cells within ${spread}% of each other"; else no "planned cells ${spread}% apart"; fi
else
  no "no api/test tree or no scripts/elixir-test-weights.tsv to check"
fi

echo
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
