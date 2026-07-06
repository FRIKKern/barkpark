#!/usr/bin/env bash
# PR↔task gate — verifies a pull request is backed by an active task on the
# ledger-of-record (guerrilla, per task-obsession decision D4).
#
# This is the mechanical core of the "task-obsession" epic's first layer: no
# change lands without a task that someone is actively working. The workflow
# (.github/workflows/pr-task-gate.yml) extracts the task id from the PR and
# calls this script; the script does the ledger read and decides.
#
# Contract (checked hermetically by scripts/pr-task-gate.test.sh):
#   Inputs  (env):
#     TASK_ID          required — the task doc id referenced by the PR
#     LEDGER_BASE      optional — ledger base URL (default guerrilla)
#     EXPECTED_WORKER  optional — if set, the task's claim.worker must equal it
#   Exit codes:
#     0  pass   — task exists, lifecycle_status == in_progress, claim present
#                 (and matches EXPECTED_WORKER when that is set)
#     1  fail   — a DEFINITIVE violation: no task ref, task not found, task not
#                 in_progress, unclaimed, or wrong worker. The PR must not merge.
#     2  neutral — the ledger could not be reached (network error / 5xx). The
#                 caller treats this as pass-with-warning: a ledger outage must
#                 never freeze merges (an infra blip is not a policy violation).
#
# Why 2 is distinct from 1: a hard fail means "the rule was checked and broken";
# neutral means "the rule could not be checked". Collapsing them would either
# turn a guerrilla outage into a merge freeze (if 2→1) or let a genuinely
# unbacked PR through whenever the ledger hiccups (if 1→2). Keep them separate.

set -uo pipefail

LEDGER_BASE="${LEDGER_BASE:-https://guerrilla.barkpark.cloud}"
DATASET="${LEDGER_DATASET:-production}"

fail()    { echo "pr-task-gate: FAIL: $*" >&2; exit 1; }
neutral() { echo "pr-task-gate: NEUTRAL: $*" >&2; exit 2; }
pass()    { echo "pr-task-gate: PASS: $*";        exit 0; }

[ -n "${TASK_ID:-}" ] || fail "no task reference found on the PR (add a 'Task: <doc_id>' line to the PR description)"

url="${LEDGER_BASE%/}/v1/data/doc/${DATASET}/task/${TASK_ID}"

# -sS: quiet but show errors. -m 20: hard per-request cap. Capture body and the
# HTTP status separately so a 5xx is distinguishable from a 404 body.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
http_code="$(curl -sS -m 20 -o "$tmp" -w '%{http_code}' "$url" 2>"$tmp.err")" || {
  neutral "could not reach the ledger at ${LEDGER_BASE} ($(cat "$tmp.err" 2>/dev/null | head -1)); not blocking the merge on an infra error"
}

# Status handling, decided by code not body:
#   404              → the task genuinely does not exist → DEFINITIVE fail.
#   2xx              → parse the body (below).
#   anything else    → ledger-side / infra problem (5xx, 000 no-response, 429
#                      rate limit, 401/403 misconfig) → neutral, never block a
#                      merge on our own infra. A definitive policy violation is
#                      only ever "no ref / not found / not in_progress".
case "$http_code" in
  404)     fail "task '${TASK_ID}' does not exist on the ledger (${LEDGER_BASE}) — reference a real task (HTTP 404)" ;;
  2??)     : ;;  # parse below
  *)       neutral "ledger returned HTTP ${http_code} for ${TASK_ID}; not blocking the merge on a ledger error" ;;
esac

# Parse the flattened doc. doc.get wraps the document under `.result`; a
# published task carries lifecycle_status and claim at the top level. A 2xx with
# no result (defensive — Sanity-style null-doc) is still a definitive "missing".
read -r found lifecycle worker < <(python3 - "$tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    print("error . .")
    sys.exit(0)
doc = d.get("result")
if isinstance(doc, list):
    doc = doc[0] if doc else None
if not isinstance(doc, dict) or not doc.get("_id"):
    print("missing . .")
    sys.exit(0)
claim = doc.get("claim") or {}
worker = claim.get("worker") or "."
print("found", doc.get("lifecycle_status") or ".", worker)
PY
)

case "$found" in
  error)   neutral "ledger response for ${TASK_ID} was not valid JSON; not blocking on a transport error" ;;
  missing) fail "task '${TASK_ID}' does not exist on the ledger (${LEDGER_BASE}) — reference a real task" ;;
esac

[ "$lifecycle" = "in_progress" ] || fail "task '${TASK_ID}' is '${lifecycle}', not 'in_progress' — claim it before opening the PR (bp task claim ${TASK_ID} <worker>)"
[ "$worker" != "." ] || fail "task '${TASK_ID}' is in_progress but carries no claim.worker — re-claim it"

if [ -n "${EXPECTED_WORKER:-}" ] && [ "$EXPECTED_WORKER" != "$worker" ]; then
  fail "task '${TASK_ID}' is claimed by '${worker}', not the PR author's mapped worker '${EXPECTED_WORKER}'"
fi

pass "task '${TASK_ID}' is in_progress, claimed by '${worker}'"
