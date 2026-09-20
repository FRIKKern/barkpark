#!/usr/bin/env bash
#
# mix-test-strict-live.test.sh — the half of the mix-test-strict matrix that
# needs a REAL `mix test`, and therefore cannot live in the hermetic harness.
#
# scripts/mix-test-strict.test.sh proves the refusal side by stopping the
# subject at its BP_MIX_TEST_STRICT_DRY_RUN seam — no Elixir, no database. That
# seam is exactly why it can never observe the OTHER half of the claim the exit
# codes make: that a suite which RAN and FAILED exits 2. Asserting "64 is not 2"
# against a value nothing ever produces would be a green with no subject, the
# very fault this script's subject exists to prevent.
#
# So this harness runs mix for real, in a real project, twice:
#
#   ARM A — a mistyped path riding beside a real one must exit 64 AND print no
#           ExUnit trailer: refused, nothing ran.
#   ARM B — a deliberately failing test, alone, must exit 2 WITH a trailer
#           naming a failure: it ran, it is red.
#
# Both arms use ONE throwaway test file written under the project's test tree
# and removed on exit. It is named *_live_probe_test.exs, is tagged so a normal
# suite run never picks it up by accident, and is addressed by path here.
#
# REFUSES, NEVER SKIPS: without `mix` on PATH or a usable project this exits 2
# with CANNOT MEASURE. A harness that greens when it measured nothing is the
# defect it is hunting.
#
# USAGE:  scripts/mix-test-strict-live.test.sh [project-dir]     # default: api
#   MIX_TEST_PARTITION is honoured by the project's own config; every agent on
#   this machine shares one test database, so pass one when running in parallel.
#
# EXIT: 0 both arms pass · 1 an arm failed · 2 cannot measure.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/mix-test-strict.sh"
PROJ_NAME="${1:-api}"
PROJ="$ROOT/$PROJ_NAME"

cannot() { echo "mix-test-strict-live.test: CANNOT MEASURE — $*" >&2; exit 2; }

[ -f "$SUBJECT" ] || cannot "no $SUBJECT"
[ -f "$PROJ/mix.exs" ] || cannot "no mix.exs in $PROJ (pass a project dir as \$1)"
command -v mix >/dev/null 2>&1 || cannot "no \`mix\` on PATH; this arm cannot be faked"

# The codes under test, read from the subject so a change there is not silently
# tolerated here. 2 is ExUnit's and is hard-coded: it is the collision to avoid.
EXUNIT_FAILED_EXIT=2
REFUSE_EXIT="$(sed -n 's/^REFUSE_EXIT=\([0-9][0-9]*\)$/\1/p' "$SUBJECT" | head -1)"
case "$REFUSE_EXIT" in ''|*[!0-9]*) cannot "no REFUSE_EXIT=<int> line in $SUBJECT" ;; esac

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

STAMP="$$"
PROBE_REL="test/mix_test_strict_${STAMP}_live_probe_test.exs"
PROBE="$PROJ/$PROBE_REL"
MISSING_REL="test/mix_test_strict_${STAMP}_absent_test.exs"

cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

[ ! -e "$PROBE" ] || cannot "probe path $PROBE_REL already exists"
[ ! -e "$PROJ/$MISSING_REL" ] || cannot "the 'missing' path $MISSING_REL exists"

cat > "$PROBE" <<'PROBE_EOF'
defmodule MixTestStrictLiveProbeTest do
  # Deliberately red. It exists for exactly one assertion — that a suite which
  # RAN and FAILED exits 2, distinct from the strict runner's refusal code. It
  # is written and deleted by scripts/mix-test-strict-live.test.sh; a copy left
  # behind in a working tree is litter, not a real test.
  use ExUnit.Case, async: true

  test "this failure is the measurement" do
    assert 1 == 2, "deliberate failure: the live exit-code arm needs a real red"
  end
end
PROBE_EOF
[ -s "$PROBE" ] || cannot "probe file was not written"

echo "ARM A — a mistyped path beside a real one: REFUSED, nothing ran"
OUT_A="$(cd "$PROJ" && bash "$SUBJECT" "$PROBE_REL" "$MISSING_REL" 2>&1)"; RC_A=$?
if [ "$RC_A" -ne "$REFUSE_EXIT" ]; then
  bad "expected exit $REFUSE_EXIT, got $RC_A"
  printf '%s\n' "$OUT_A"
else
  ok "exit $RC_A (the refusal code)"
fi
case "$OUT_A" in
  *"$MISSING_REL"*) ok "names the offending argument" ;;
  *) bad "output never named $MISSING_REL"; printf '%s\n' "$OUT_A" ;;
esac
# NOTHING RAN: no ExUnit trailer, and in particular not the probe's own failure.
if printf '%s' "$OUT_A" | grep -qE '[0-9]+ tests?, [0-9]+ failures?'; then
  bad "an ExUnit trailer appeared — the refusal did NOT stop before running"
  printf '%s\n' "$OUT_A"
else
  ok "no ExUnit trailer: nothing was run"
fi
case "$OUT_A" in
  *"deliberate failure"*) bad "the probe's failure surfaced — the suite ran despite the refusal" ;;
  *) ok "the deliberately-red probe never executed" ;;
esac

echo "ARM B — a deliberately failing test, alone: RAN, exits $EXUNIT_FAILED_EXIT"
OUT_B="$(cd "$PROJ" && bash "$SUBJECT" "$PROBE_REL" 2>&1)"; RC_B=$?
if [ "$RC_B" -eq "$EXUNIT_FAILED_EXIT" ]; then
  ok "exit $RC_B (ExUnit's tests-failed status)"
else
  bad "expected exit $EXUNIT_FAILED_EXIT from a real red suite, got $RC_B"
  printf '%s\n' "$OUT_B"
fi
if printf '%s' "$OUT_B" | grep -qE '[0-9]+ tests?, [1-9][0-9]* failures?'; then
  ok "an ExUnit trailer with a nonzero failure count: it really ran"
else
  bad "no failing ExUnit trailer — ARM B may have died before running the suite"
  printf '%s\n' "$OUT_B"
fi

echo "VERDICT"
if [ "$RC_A" -ne "$RC_B" ]; then
  ok "refused ($RC_A) and ran-and-failed ($RC_B) are DISTINGUISHABLE BY EXIT CODE ALONE"
else
  bad "refused and ran-and-failed both exited $RC_A — the whole point is lost"
fi

echo ""
echo "mix-test-strict-live.test: $pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
exit 0
