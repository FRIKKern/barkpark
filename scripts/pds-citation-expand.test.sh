#!/usr/bin/env bash
# pds-citation-expand.test.sh — the harness for scripts/pds-citation-expand.sh.
#
# WHY THIS FILE EXISTS. A guard nothing runs is inert. The citation guard ships
# with 16 selftest arms and both controls, but nothing in CI invoked it, so a
# compressed citation could re-enter the PDS fence and no red would ever fire.
#
# IT IS WIRED. The `PDS census / parity / scratch-target harnesses` leg of
# .github/workflows/shell-harnesses.yml runs this file — the arm lives in
# .github/shell-harness-legs.json beside its pds-* siblings, and the workflow's
# twin paths lists and its `changes` dispatcher admit both this file and its
# subject through the `scripts/pds-*.sh` glob (explicit rows were tried and
# pushed the `changes` run block over its 20000-byte fail floor, 63 bytes past
# it — scripts/workflow-run-block-length-check.sh), so an edit to either
# triggers the leg that runs it. Be exact about
# what that buys: shell-harnesses.yml is NOT one of main's required contexts
# (those are exactly Elixir gate, PR references an active task, Cloud gate,
# Console gate), so wiring makes this harness RUN, not BLOCK. Running is the
# prerequisite; registering is a separate, evidence-gated decision. Wiring row:
# task-b92409dc562dc20c. Baseline at authoring: 4 passed, 0 failed.
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
