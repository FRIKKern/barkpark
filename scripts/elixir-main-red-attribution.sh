#!/usr/bin/env bash
# elixir-main-red-attribution.sh — when main reds on an ExUnit failure, did the
# PR that landed it actually RUN that test?
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────
#
# scripts/elixir-impacted-tests.sh narrows the ExUnit set a pull request runs.
# Every argument for that narrowing rests on one claim: anything the selection
# misses is caught on main, at its own sha, before it can compound. That claim
# is only worth something if somebody MEASURES the misses. Otherwise the first
# time anyone learns the selector has a blind spot is a week of confusing reds.
#
# So: on a red `elixir` run on main, this reconstructs the pull request's file
# set from the merge commit, re-runs the selector over it, and asks whether the
# tests that actually failed were in the answer. A `no` is a measured selector
# miss, and it gets filed with the merge sha attached.
#
# ── WHAT IT CAN AND CANNOT SAY, STATED UP FRONT ───────────────────────────
#
# The recomputation happens with BP_IMPACTED_NO_XREF=1: this runs on a watcher
# with no compiled build, so the compile closure is unavailable and the selector
# falls back to the convention + by-name mappers alone. That answer is a SUBSET
# of what CI computed. The direction is therefore known and safe:
#
#   * a test reported COVERED here was certainly selected on the PR — the real
#     selection is a superset. No false "all clear".
#   * a test reported SKIPPED here MAY still have been selected, by an xref edge
#     this reconstruction could not see. So SKIPPED is "worth a human look",
#     not "proven miss", and the filed row says exactly that.
#
# Over-reporting is the correct bias for an instrument whose whole job is to
# stop a narrowing going quietly blind.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#
#   elixir-main-red-attribution.sh --log <exunit log> --diff <changed paths>
#   elixir-main-red-attribution.sh --selftest
#
# Exit: 0 covered / the selection was ALL / the red was not a test failure
#       3 SKIPPED — at least one failing test file is outside the selection
#       1 unusable input (an empty log, a missing file)
#
# It prints `verdict=<TOKEN>` on its own line; the workflow reads that.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="${BP_ATTRIBUTION_SELECTOR:-$HERE/elixir-impacted-tests.sh}"

LOG=""
DIFF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:?--log needs a file}"; shift 2 ;;
    --diff) DIFF="${2:?--diff needs a file}"; shift 2 ;;
    --selftest) exec bash "$HERE/elixir-main-red-attribution.test.sh" ;;
    *)
      echo "elixir-main-red-attribution: unknown argument '$1'" >&2
      echo "usage: $0 --log <exunit log> --diff <changed paths file> | --selftest" >&2
      exit 2
      ;;
  esac
done

verdict() { echo "verdict=$1"; }

[ -n "$LOG" ] && [ -f "$LOG" ] || { echo "::error::attribution: --log is missing or not a file" >&2; verdict UNUSABLE; exit 1; }
[ -n "$DIFF" ] && [ -f "$DIFF" ] || { echo "::error::attribution: --diff is missing or not a file" >&2; verdict UNUSABLE; exit 1; }
[ -s "$LOG" ] || { echo "::error::attribution: the log is EMPTY — nothing to attribute, and a silent pass here would look identical to a clean run" >&2; verdict UNUSABLE; exit 1; }

# ── the failing test files ────────────────────────────────────────────────
# ExUnit prints each failure as a numbered header followed by an indented
# `test/<path>_test.exs:<line>` locator. That locator is the only place the
# FILE appears; the header line carries the test name and the module, not the
# path. Anchored on `test/` so a stack-trace frame into lib/ or deps/ cannot be
# mistaken for a failing test file.
failing="$(sed -nE 's|^[[:space:]]*(\(.*\) )?(test/[A-Za-z0-9_./-]*_test\.exs):[0-9]+.*|\2|p' "$LOG" | LC_ALL=C sort -u)"

if [ -z "$failing" ]; then
  # A red run with no ExUnit locator in it: a compile error, a drift gate, the
  # boot bar's own step, an infrastructure failure. Not a selection question.
  echo "no ExUnit failure locators in the log — this red is not a test failure, so the selector cannot be responsible for it."
  verdict NOT_A_TEST_FAILURE
  exit 0
fi

echo "failing test files:"
printf '  %s\n' $failing

# ── what would the PR have selected? ──────────────────────────────────────
export BP_IMPACTED_NO_XREF=1
sel=""
rc=0
sel="$(bash "$SELECTOR" --select <"$DIFF" 2>/dev/null)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "::error::attribution: the selector exited rc=${rc} on this diff — the reconstruction failed, not the selection." >&2
  verdict UNUSABLE
  exit 1
fi

if grep -qxF 'ALL' <<<"$sel"; then
  echo "the reconstructed selection is ALL — this pull request ran the whole suite, so the red is not attributable to narrowing."
  verdict SELECTION_ALL
  exit 0
fi

echo "reconstructed selection: $(grep -c . <<<"$sel") test files (mapper-only — a SUBSET of what CI computed)"

missed=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # D37: a here-string, never `printf … | grep -q`.
  grep -qxF -- "$f" <<<"$sel" || missed="${missed}${f}
"
done <<EOF
$failing
EOF

missed="$(sed '/^$/d' <<<"$missed")"
if [ -z "$missed" ]; then
  echo "every failing test file is inside the reconstructed selection — the pull request ran them and they passed there, or the failure is order/environment dependent."
  verdict COVERED
  exit 0
fi

echo
echo "SELECTOR MISS CANDIDATES — failing on main, absent from the reconstructed selection:"
printf '  %s\n' $missed
echo
echo "This is a candidate, not a proof: the reconstruction runs without a compiled build, so it omits the compile-closure half and under-reports what the pull request actually ran. What it does establish is that neither the convention map, the by-name net, nor the ALWAYS set reached these files — so if the closure did not either, the narrowing was blind here."
verdict SKIPPED
exit 3
