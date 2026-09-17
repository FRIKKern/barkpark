#!/usr/bin/env bash
# pds-citation-expand.test.sh — the harness for scripts/pds-citation-expand.sh.
#
# WHY THIS FILE EXISTS. A guard nothing runs is inert. The citation guard ships
# with 16 selftest arms and both controls, but nothing in CI invoked it, so a
# compressed citation could re-enter the PDS fence and no red would ever fire.
# This is the runnable tenant a workflow can adopt in one line.
#
# NOT YET WIRED, AND SAYING SO. .github/workflows/shell-harnesses.yml selects
# its tenants by an explicit `paths:` list and an explicit step per harness —
# that file belongs to the gates lane, not this one. Until a gates-lane change
# adds this script beside the other `*.test.sh` tenants, this harness runs only
# when somebody runs it. That is a known gap, stated here rather than left for
# a reader to discover from a guard that never fired.
#
# usage: bash scripts/pds-citation-expand.test.sh

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "pds-citation-expand.test.sh: needs bash" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*) echo "pds-citation-expand.test.sh: refuses to run in POSIX mode" >&2; exit 2;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/pds-citation-expand.sh"
pass=0; fail=0

arm() { # arm <label> <expected-rc> <cmd...>
  local label="$1" want="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); echo "  ok   $label"
  else fail=$((fail+1)); echo "  FAIL $label (expected rc=$want, got rc=$rc)"; fi
}

echo "pds-citation-expand harness"

# 1. The subject's own 16 arms, both controls included.
arm "the subject's --selftest passes (16 arms)" 0 bash "$SUBJECT" --selftest

# 2. THE LIVE GUARD. The PDS fence must carry no compressed citation. This is
#    the arm that reds if one re-enters, which is the whole point of the sweep.
arm "the live PDS fence is free of compressed citations" 0 bash "$SUBJECT" --check

# 3. The interpreter refusal, measured rather than assumed — a POSIX-mode run
#    must REFUSE (rc=2), never exit 0 having compared nothing.
arm "the subject refuses to run under bash --posix" 2 bash --posix "$SUBJECT" --check

# 4. --count answers over the whole tree without error, so the denominator the
#    lane reports is always derivable and never a remembered number.
arm "--count runs clean over the whole tree" 0 bash "$SUBJECT" --count

echo
echo "pds-citation-expand.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
