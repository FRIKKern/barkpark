#!/usr/bin/env bash
#
# node-test-floor.test.sh — the harness for scripts/node-test-floor.mjs, the
# runner that four CI gates use instead of a bare `node --test '<glob>'`.
#
# Honest-gates D26: a harness nobody runs is not a ratchet. This one is executed
# by shell-harnesses.yml, and its subject set includes the call sites, so the PR
# that changes one of them runs this.
#
# WHY THE ORDERING CASE EXISTS (case 7), which is the one that is easy to lose.
# The runner spawns one process PER FILE — that is what makes the zero-test
# floor per-file at all — and pools those spawns across availableParallelism().
# Downstream gates PARSE that output: apps/hundesteder's Test step sums every
# `# pass N` line against a MIN_TESTS floor. If the pool ever streams child
# stdout instead of buffering each file and printing it whole in file order,
# TAP blocks interleave, per-file tallies get shredded across lines, and the sum
# still looks PLAUSIBLE. A wrong number that looks right is worse than a crash,
# and no existing gate would notice. That property was defended by a comment
# until this harness; a property defended only by a comment is not defended.
#
# The cases that matter are the ones that prove the runner can FAIL:
#   * a pattern matching nothing must red                     (case 2)
#   * a file registering zero tests must red                  (case 3) — node
#     reports such a file as `# tests 1` / `ok 1 - <path>`, the FILE counted as
#     its own passing test, so a naive `tests > 0` floor PASSES this. It did.
#   * a missing explicit path must red even beside a real one (case 4) — bare
#     `node --test real.mjs missing.mjs` exits 0 and never names the missing one
#   * a real failing assertion must red                       (case 5)
#   * a forwarded --test-reporter must be refused BY NAME     (case 6)
#   * per-file TAP blocks must stay whole and ordered         (case 7)
# A harness with only green cases is the defect, not the proof.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/node-test-floor.mjs"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   — $1"; }
no() { fail=$((fail + 1)); echo "  FAIL — $1" >&2; }

# Never `A | grep -q` on a status we read (honest-gates D37: the writer takes
# SIGPIPE and pipefail promotes it). Match against a variable, no pipeline.
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Emit a test file with N passing tests.
# `local` is load-bearing: shell functions share the caller's scope, and an
# earlier version of this helper looped on `i` — the same name the case-7
# fixture loop used — which silently renamed every fixture file and made the
# ordering assertion fail against a scrambled expectation. THE HARNESS WAS
# WRONG, NOT THE RUNNER, and it accused the runner deterministically, which is
# the most convincing way to be wrong. Case 7 now derives its expectation from
# the files on disk rather than from bookkeeping a helper can corrupt.
mk_tests() { # <path> <n>
  local _k
  { echo 'import { test } from "node:test";'
    for _k in $(seq 1 "$2"); do echo "test(\"$(basename "$1" .test.mjs) case $_k\", () => {});"; done
  } >"$1"
}

echo "== node-test-floor.mjs =="

# ── case 1 — the control. A real suite passes and reports its counts. ────────
FX1="$TMPROOT/c1"; mkdir -p "$FX1"
mk_tests "$FX1/a.test.mjs" 3
mk_tests "$FX1/b.test.mjs" 2
out="$(cd "$FX1" && node "$RUNNER" '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0 on a real suite"; else no "control red (rc=$rc): $out"; fi
if has "ran 5 tests from 2 files" "$out"; then
  ok "reports the derived counts (5 tests / 2 files)"
else
  no "the summary line is missing or wrong: $out"
fi

# ── case 2 — a pattern matching NOTHING. The whole reason this exists. ──────
FX2="$TMPROOT/c2"; mkdir -p "$FX2"
out="$(cd "$FX2" && node "$RUNNER" '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on a zero-match pattern"; else no "ZERO-MATCH PASSED — the defect this runner exists to stop: $out"; fi
if has "matched NO files" "$out"; then ok "names the pattern that matched nothing"; else no "the refusal does not name the pattern: $out"; fi

# ── case 3 — a file that registers ZERO tests. node calls it `# tests 1`. ────
FX3="$TMPROOT/c3"; mkdir -p "$FX3"
mk_tests "$FX3/a.test.mjs" 3
echo 'export const nothing = 1;' >"$FX3/empty.test.mjs"
out="$(cd "$FX3" && node "$RUNNER" '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on a file registering zero tests"; else no "A ZERO-TEST FILE PASSED — a naive tests>0 floor does exactly this: $out"; fi
if has "empty.test.mjs" "$out"; then ok "names the empty file"; else no "the refusal does not name the empty file: $out"; fi
if has "counts the FILE, not a test" "$out"; then ok "explains why the count looked healthy"; else no "the refusal does not explain the # tests 1 trap: $out"; fi

# ── case 4 — an explicit path that does not exist, BESIDE a real one. ────────
# Bare `node --test real.test.mjs missing.test.mjs` exits 0 and never mentions
# the missing file. Only when EVERY path is missing does node itself red.
FX4="$TMPROOT/c4"; mkdir -p "$FX4"
mk_tests "$FX4/a.test.mjs" 2
out="$(cd "$FX4" && node --test a.test.mjs missing.test.mjs 2>&1)" && bare_rc=0 || bare_rc=$?
if [ "$bare_rc" -eq 0 ]; then
  ok "baseline confirmed — bare node --test exits 0 with a missing sibling (this is the bug)"
else
  no "node no longer drops a missing sibling (rc=$bare_rc) — this harness's premise moved; re-derive it"
fi
out="$(cd "$FX4" && node "$RUNNER" 'a.test.mjs' 'missing.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc when one of two patterns matches nothing"; else no "a missing path was silently dropped: $out"; fi
if has "missing.test.mjs" "$out"; then ok "names the missing path"; else no "the refusal does not name the missing path: $out"; fi

# ── case 5 — an ordinary failing assertion still reds. ──────────────────────
FX5="$TMPROOT/c5"; mkdir -p "$FX5"
mk_tests "$FX5/a.test.mjs" 2
cat >"$FX5/bad.test.mjs" <<'JS'
import { test } from "node:test";
import assert from "node:assert/strict";
test("deliberately failing", () => { assert.equal(1, 2); });
JS
out="$(cd "$FX5" && node "$RUNNER" '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on a real failing assertion"; else no "a failing test passed: $out"; fi

# ── case 6 — a forwarded --test-reporter is refused BY NAME. ────────────────
# The runner owns the TAP reporter because it parses the count. Forwarding one
# leaves the count unreadable; that fails CLOSED, but the message must say the
# caller's flag caused it or the next person debugs their test suite instead.
FX6="$TMPROOT/c6"; mkdir -p "$FX6"
mk_tests "$FX6/a.test.mjs" 2
out="$(cd "$FX6" && node "$RUNNER" --test-reporter=spec -- '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on a forwarded --test-reporter"; else no "a forwarded reporter was accepted; the count would be unreadable: $out"; fi
if has "--test-reporter=spec cannot be forwarded" "$out"; then ok "refuses by name, not by symptom"; else no "the refusal does not name the offending flag: $out"; fi

# ── case 7 — PER-FILE TAP BLOCKS STAY WHOLE AND ORDERED UNDER THE POOL. ─────
# Enough files, with uneven test counts, to saturate the pool so workers finish
# out of order. Three assertions: the sum a downstream parser reads is right,
# every file contributes exactly one intact tally, and the tallies appear in
# FILE order (sorted glob order), not completion order.
FX7="$TMPROOT/c7"; mkdir -p "$FX7"
fx7_n=1
for fx7_count in 7 1 5 2 9 3 8 4 6 11 10 12; do
  mk_tests "$FX7/f$(printf '%02d' "$fx7_n").test.mjs" "$fx7_count"
  fx7_n=$((fx7_n + 1))
done

# DERIVED, not declared: read the expectation back off the files themselves, in
# the same sorted order the runner globs them in. A hand-maintained list is one
# more thing that can be wrong, and when it is wrong it accuses the subject.
expected_order="$(cd "$FX7" && ls f*.test.mjs | sort | while read -r f; do grep -c '^test(' "$f"; done)"
expected_sum="$(printf '%s\n' "$expected_order" | awk '{ s += $1 } END { print s + 0 }')"
expected_files="$(printf '%s\n' "$expected_order" | grep -c .)"

out="$(cd "$FX7" && node "$RUNNER" '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0 across $expected_files concurrent files"; else no "the $expected_files-file control red (rc=$rc): $out"; fi

summed="$(printf '%s' "$out" | awk 'NF == 3 && $2 == "pass" && $3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }')"
if [ "$summed" -eq "$expected_sum" ]; then
  ok "a downstream summing parser reads $expected_sum across $expected_files pooled files"
else
  no "SHREDDED TALLIES — a summing parser reads $summed, not $expected_sum; the pool is interleaving stdout"
fi

tally_lines="$(printf '%s' "$out" | grep -c '^# pass ' || true)"
if [ "$tally_lines" -eq "$expected_files" ]; then
  ok "exactly one intact '# pass' tally per file ($expected_files)"
else
  no "expected $expected_files per-file tallies, found $tally_lines — blocks are being split or merged"
fi

got_order="$(printf '%s' "$out" | awk 'NF == 3 && $2 == "pass" && $3 ~ /^[0-9]+$/ { print $3 }')"
if [ "$got_order" = "$expected_order" ]; then
  ok "tallies appear in FILE order, not completion order"
else
  no "OUT OF ORDER — a consumer keying tallies to files by position is now wrong. got: $(printf '%s' "$got_order" | tr '\n' ' ')/ want: $(printf '%s' "$expected_order" | tr '\n' ' ')"
fi

# ── case 8 — the summary follows the tree DOWN, and the documented limit. ───
survivor="$(cd "$FX7" && ls f*.test.mjs | sort | head -1)"
survivor_n="$(cd "$FX7" && grep -c '^test(' "$survivor")"
(cd "$FX7" && ls f*.test.mjs | sort | tail -n +2 | while read -r f; do rm "$f"; done)
out="$(cd "$FX7" && node "$RUNNER" '*.test.mjs' 2>&1)" && rc=0 || rc=$?
if has "ran $survivor_n tests from 1 files" "$out"; then
  ok "the count follows the tree down (1 file, $survivor_n tests) rather than reporting a stale total"
else
  no "the summary did not track the gutted tree: $out"
fi
# ...AND it exits 0, which is the runner's honest LIMIT: every pattern matched
# and the survivor registers tests. Catching "shrank but non-empty" needs a
# committed baseline or a judgement literal (apps/hundesteder's MIN_TESTS),
# because anything computed from the current tree agrees with a gutted tree by
# construction. Asserted so nobody deletes that second floor as redundant.
if [ "$rc" -eq 0 ]; then
  ok "exit 0 on a gutted-but-non-empty suite — the DOCUMENTED limit; a count floor is what catches this"
else
  no "the runner now reds on a shrink (rc=$rc); if that is deliberate, update apps/hundesteder's MIN_TESTS rationale"
fi

echo
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
