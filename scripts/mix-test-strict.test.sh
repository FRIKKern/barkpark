#!/usr/bin/env bash
#
# mix-test-strict.test.sh — behavioural matrix for scripts/mix-test-strict.sh.
#
# Hermetic: every case runs against a FIXTURE mix project built in mktemp (a
# `mix.exs` stub plus a handful of `.exs` files). No `mix` is invoked — the
# subject's BP_MIX_TEST_STRICT_DRY_RUN seam stops it one line before `exec`, so
# this harness needs neither Elixir nor a database and cannot rot into a skip.
#
# It has four parts:
#   1. REFUSAL cases   — each must exit REFUSE_EXIT (64) AND name the offending
#      argument.
#   2. PASS-THROUGH    — each must exit 0 and print the argv UNCHANGED.
#   3. DISTINCTNESS    — the refusal code must be one `mix test` cannot return:
#      not 0 (pass), not 1 (mix's own failure), and above all NOT 2, which is
#      ExUnit's "tests failed" status. Mutation-proved by reverting the
#      constant to 2. See task-620ea822de73bf5e.
#   4. MUTATION proof  — each guard is neutralised by its `# MUT:` anchor in a
#      scratch copy, and the case that guard owns must STOP refusing. A guard
#      whose removal changes nothing was never the detector.
#
# WHAT THIS HARNESS CANNOT SEE: it never invokes `mix`, so it cannot observe
# that a REAL failing suite exits 2. That half lives in
# scripts/mix-test-strict-live.test.sh, which needs Elixir and a real project
# and refuses (exit 2, CANNOT MEASURE) rather than skipping when it has neither.
#
# EXIT: 0 all cases pass · 1 at least one failed · 2 cannot measure.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/mix-test-strict.sh"
[ -f "$SUBJECT" ] || { echo "mix-test-strict.test: CANNOT READ — no $SUBJECT" >&2; exit 2; }

# Read the refusal status OUT OF THE SUBJECT rather than hard-coding it here:
# a harness that carries its own copy of the number cannot notice the subject
# changing it. The literal 2 below is ExUnit's, and is hard-coded on purpose —
# that is the value the refusal must never collide with.
EXUNIT_FAILED_EXIT=2
REFUSE_EXIT="$(sed -n 's/^REFUSE_EXIT=\([0-9][0-9]*\)$/\1/p' "$SUBJECT" | head -1)"
case "$REFUSE_EXIT" in
  ''|*[!0-9]*) echo "mix-test-strict.test: CANNOT MEASURE — no REFUSE_EXIT=<int> line in $SUBJECT" >&2; exit 2 ;;
esac

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mtstrict.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---- fixture mix project -----------------------------------------------------
PROJ="$TMP/proj"
mkdir -p "$PROJ/test/real" "$PROJ/test/support" "$PROJ/test/empty_dir"
printf 'defmodule Fixture.MixProject do\nend\n' > "$PROJ/mix.exs"
printf 'defmodule RealTest do\nend\n' > "$PROJ/test/real/alpha_test.exs"
printf 'defmodule Real2Test do\nend\n' > "$PROJ/test/real/beta_test.exs"
printf 'defmodule Helper do\nend\n'    > "$PROJ/test/support/helper.exs"

# The fixture must actually be in the state each case needs; a setup that
# silently died turns every refusal case into a vacuous green.
for must in "$PROJ/mix.exs" "$PROJ/test/real/alpha_test.exs" "$PROJ/test/support/helper.exs"; do
  [ -f "$must" ] || { echo "mix-test-strict.test: CANNOT MEASURE — fixture missing $must" >&2; exit 2; }
done
[ -z "$(find "$PROJ/test/support" -name '*_test.exs')" ] || {
  echo "mix-test-strict.test: CANNOT MEASURE — fixture test/support unexpectedly holds a *_test.exs" >&2; exit 2; }
[ ! -e "$PROJ/test/real/gone_test.exs" ] || {
  echo "mix-test-strict.test: CANNOT MEASURE — fixture 'missing' path exists" >&2; exit 2; }

# run <script> <args...> -> sets RC and OUT (stdout+stderr, read to EOF).
run() {
  local script="$1"; shift
  OUT="$(cd "$PROJ" && BP_MIX_TEST_STRICT_DRY_RUN=1 bash "$script" "$@" 2>&1)"
  RC=$?
}

expect_refusal() { # label, expected-substring, args...
  local label="$1" needle="$2"; shift 2
  run "$SUBJECT" "$@"
  if [ "$RC" -ne "$REFUSE_EXIT" ]; then bad "$label — expected exit $REFUSE_EXIT, got $RC"; return; fi
  case "$OUT" in
    *"$needle"*) ok "$label (exit $REFUSE_EXIT, names '$needle')" ;;
    *) bad "$label — exit $REFUSE_EXIT but output never named '$needle'"; printf '%s\n' "$OUT" ;;
  esac
}

expect_pass() { # label, expected-forwarded-argv, args...
  local label="$1" forwarded="$2"; shift 2
  run "$SUBJECT" "$@"
  if [ "$RC" -ne 0 ]; then bad "$label — expected exit 0, got $RC"; printf '%s\n' "$OUT"; return; fi
  case "$OUT" in
    *"would exec: mix test $forwarded"*) ok "$label (exit 0, forwards \`mix test $forwarded\`)" ;;
    *) bad "$label — argv was not forwarded unchanged; wanted 'mix test $forwarded'"; printf '%s\n' "$OUT" ;;
  esac
}

echo "REFUSALS"
# THE REPRODUCTION, in miniature: one real path is enough for `mix test` to drop
# the other silently and still exit 0. This is the case the task exists for.
expect_refusal "a nonexistent path RIDING ALONGSIDE a real one" \
  "names no file: test/real/gone_test.exs" \
  test/real/alpha_test.exs test/real/gone_test.exs
expect_refusal "a nonexistent path alone" \
  "names no file: test/real/gone_test.exs" \
  test/real/gone_test.exs
expect_refusal "a nonexistent path with a :LINE suffix" \
  "names no file: test/real/gone_test.exs:14" \
  test/real/gone_test.exs:14
expect_refusal "a directory that exists but holds no *_test.exs" \
  "matches no test (directory holds no *_test.exs): test/support" \
  test/support
expect_refusal "an empty directory" \
  "matches no test" \
  test/empty_dir
expect_refusal "a file that exists but is not a *_test.exs" \
  "matches no test (not a *_test.exs file): test/support/helper.exs" \
  test/support/helper.exs
expect_refusal "every offender is named, not just the first" \
  "names no file: test/real/gone_test.exs" \
  test/real/gone_test.exs test/support
run "$SUBJECT" test/real/gone_test.exs test/support
case "$OUT" in
  *"matches no test (directory holds no *_test.exs): test/support"*) ok "…and the second offender too" ;;
  *) bad "second offender was not reported alongside the first" ;;
esac

echo "PASS-THROUGH (argv forwarded unchanged)"
expect_pass "a single real test file" "test/real/alpha_test.exs" test/real/alpha_test.exs
expect_pass "two real test files" "test/real/alpha_test.exs test/real/beta_test.exs" \
  test/real/alpha_test.exs test/real/beta_test.exs
expect_pass "a directory that does hold tests" "test/real" test/real
expect_pass "a :LINE-addressed real file" "test/real/alpha_test.exs:7" test/real/alpha_test.exs:7
expect_pass "a value-taking flag's value is not existence-checked" \
  "--only boot test/real/alpha_test.exs" --only boot test/real/alpha_test.exs
expect_pass "--flag=value form" "--seed=0 test/real/alpha_test.exs" --seed=0 test/real/alpha_test.exs
expect_pass "a boolean flag after the paths" \
  "test/real/alpha_test.exs --trace" test/real/alpha_test.exs --trace
expect_pass "--max-failures 1 swallows its value" \
  "--max-failures 1 test/real/alpha_test.exs" --max-failures 1 test/real/alpha_test.exs
expect_pass "no arguments at all (a whole-suite run stays legal)" ""

echo "CANNOT-MEASURE"
OUT="$(cd "$TMP" && BP_MIX_TEST_STRICT_DRY_RUN=1 bash "$SUBJECT" 2>&1)"; RC=$?
if [ "$RC" -eq "$REFUSE_EXIT" ] && case "$OUT" in *"CANNOT READ"*"no mix.exs"*) true ;; *) false ;; esac; then
  ok "outside a mix project: exit $REFUSE_EXIT and a distinct CANNOT READ line"
else
  bad "outside a mix project: expected exit $REFUSE_EXIT + CANNOT READ, got $RC / $OUT"
fi

echo "EXIT-CODE DISTINCTNESS (a refusal must not wear ExUnit's failure code)"
# THE REGRESSION THIS SECTION EXISTS FOR (task-620ea822de73bf5e): both refusal
# arms used to exit 2, the same code `mix test` returns when the suite RAN and
# tests FAILED, so `… || echo REFUSED` called a red suite a refusal.
if [ "$REFUSE_EXIT" -ne "$EXUNIT_FAILED_EXIT" ]; then
  ok "refusal status $REFUSE_EXIT is not ExUnit's tests-failed status $EXUNIT_FAILED_EXIT"
else
  bad "refusal status is $REFUSE_EXIT — the SAME code a failed-but-completed run returns"
fi
case "$REFUSE_EXIT" in
  0|1) bad "refusal status $REFUSE_EXIT collides with mix's own (0 pass / 1 mix failure)" ;;
  *)   ok "refusal status $REFUSE_EXIT collides with neither 0 (pass) nor 1 (mix's own failure)" ;;
esac

# Both refusal ARMS, not just the validate_args one, must carry it.
run "$SUBJECT" test/real/alpha_test.exs test/real/gone_test.exs
argv_rc=$RC
OUT="$(cd "$TMP" && BP_MIX_TEST_STRICT_DRY_RUN=1 bash "$SUBJECT" 2>&1)"; guard_rc=$?
if [ "$argv_rc" -eq "$REFUSE_EXIT" ] && [ "$guard_rc" -eq "$REFUSE_EXIT" ]; then
  ok "both arms refuse with $REFUSE_EXIT (validate_args=$argv_rc, project-guard=$guard_rc)"
else
  bad "arms disagree: validate_args=$argv_rc, project-guard=$guard_rc, wanted $REFUSE_EXIT both"
fi

# RED-WITHOUT: put the old value back and the distinctness case must fail. A
# check that passes with the defect restored was never checking anything.
revert="$TMP/mutant-refuse-exit.sh"
sed "s/^REFUSE_EXIT=$REFUSE_EXIT\$/REFUSE_EXIT=$EXUNIT_FAILED_EXIT/" "$SUBJECT" > "$revert"
if ! grep -q "^REFUSE_EXIT=$EXUNIT_FAILED_EXIT\$" "$revert"; then
  bad "CANNOT MEASURE — reverting REFUSE_EXIT did not change the file"
elif ! bash -n "$revert"; then
  bad "CANNOT MEASURE — reverted copy does not parse"
else
  run "$revert" test/real/alpha_test.exs test/real/gone_test.exs
  if [ "$RC" -eq "$EXUNIT_FAILED_EXIT" ]; then
    ok "REFUSE_EXIT reverted to $EXUNIT_FAILED_EXIT -> the refusal is indistinguishable again (exit $RC): the constant IS the detector"
  else
    bad "REFUSE_EXIT reverted but the refusal still exited $RC — something else sets the status"
  fi
fi

echo "MUTATION PROOF (neutralise a guard; the case it owns must stop refusing)"
mutate() { # anchor -> scratch copy with that guard's test inverted to always-false
  # NOT one `local` statement: bash expands every word of `local` BEFORE
  # assigning any of them, so `out="$TMP/mutant-$anchor.sh"` would read an unset
  # $anchor and (under set -u) abort the harness inside its own helper.
  local anchor="$1"
  local out="$TMP/mutant-$anchor.sh"
  case "$anchor" in
    exists-guard)  sed 's|if \[ ! -e "$path" \]; then|if false; then|' "$SUBJECT" > "$out" ;;
    matches-guard) sed 's|if \[ -d "$path" \]; then|if false; then|; s|\*_test.exs) : ;;|*) : ;;|' "$SUBJECT" > "$out" ;;
    project-guard) sed 's|if \[ ! -f "mix.exs" \]; then|if false; then|' "$SUBJECT" > "$out" ;;
  esac
  bash -n "$out" || return 1
  printf '%s' "$out"
}

mutant="$(mutate exists-guard)" || { echo "CANNOT MEASURE — exists-guard mutant does not parse" >&2; exit 2; }
if ! grep -q 'if \[ ! -e "\$path" \]' "$mutant"; then
  run "$mutant" test/real/alpha_test.exs test/real/gone_test.exs
  if [ "$RC" -eq 0 ]; then ok "exists-guard neutralised -> the reproduction GREENS again (exit 0): it is the detector"
  else bad "exists-guard neutralised but the case still refused (exit $RC) — something else is refusing"; fi
else
  bad "CANNOT MEASURE — exists-guard mutation did not change the file"
fi

mutant="$(mutate matches-guard)" || { echo "CANNOT MEASURE — matches-guard mutant does not parse" >&2; exit 2; }
run "$mutant" test/support
if [ "$RC" -eq 0 ]; then ok "matches-guard neutralised -> a test-less directory greens again: it is the detector"
else bad "matches-guard neutralised but test/support still refused (exit $RC)"; fi
run "$mutant" test/support/helper.exs
if [ "$RC" -eq 0 ]; then ok "matches-guard neutralised -> a non-test .exs greens again"
else bad "matches-guard neutralised but helper.exs still refused (exit $RC)"; fi

mutant="$(mutate project-guard)" || { echo "CANNOT MEASURE — project-guard mutant does not parse" >&2; exit 2; }
OUT="$(cd "$TMP" && BP_MIX_TEST_STRICT_DRY_RUN=1 bash "$mutant" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "project-guard neutralised -> a non-project directory stops refusing"
else bad "project-guard neutralised but the non-project case still exited $RC"; fi

echo ""
echo "mix-test-strict.test: $pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
exit 0
