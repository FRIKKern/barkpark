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
#     0  pass   — the change is TASK-BACKED: the task exists and either
#                   • lifecycle_status == in_progress with a claim.worker, or
#                   • lifecycle_status == done with a claim.closed_by
#                 (and the actor matches EXPECTED_WORKER when that is set)
#     1  fail   — a DEFINITIVE violation: no task ref, task not found, task
#                 still open, in_progress with no worker, done without ever
#                 having been claimed/closed through the engine, cancelled, or
#                 wrong worker. The PR must not merge.
#     2  neutral — the ledger could not be reached (network error / 5xx). The
#                 caller treats this as pass-with-warning: a ledger outage must
#                 never freeze merges (an infra blip is not a policy violation).
#
# Why 2 is distinct from 1: a hard fail means "the rule was checked and broken";
# neutral means "the rule could not be checked". Collapsing them would either
# turn a guerrilla outage into a merge freeze (if 2→1) or let a genuinely
# unbacked PR through whenever the ledger hiccups (if 1→2). Keep them separate.
#
# Why `done` can pass. The invariant is "this change is task-backed", NOT
# "someone is actively typing right now". A task closed on met acceptance
# criteria is the SUCCESS case, and the deadlock it used to create was
# unrecoverable: a done task cannot be re-claimed to satisfy an in_progress-only
# rule, because the claimable allowlist is ~w(open blocked) (claim.ex:26,
# queue.ex:35). Observed 3x on 2026-07-20 and hand-waived each time — a gate
# that reds correct work teaches its readers to dismiss it.
#
# Why `claim.closed_by` and not `landed.prs`. content.landed.{prs,...} is the
# DESIGNED positive PR link (close.ex:290), but it is dead data: 0 of 400 done
# tasks sampled from the live ledger carry it, and the Go CLI structurally
# cannot send it — client_close_payload_test.go:103 pins the close body to
# exactly worker_id/observed_epoch/lifecycle_status. Gating on it today yields a
# gate that can never be green. `closed_by` is populated on 375/400 and proves
# the task went through the claim/close ENGINE rather than being hand-flipped
# via `bp doc patch`. Populating landed.prs is filed as wave-2 work.
#
# Why not blanket `done` == pass: that is the gate lying in the other direction.
# A `done` doc with no claim at all was never worked through the engine, so it
# is no evidence of task backing. Time proximity (closed_at recency) is
# deliberately NOT used: nearness in time is not causation.

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
# Fields are emitted TAB-separated with "." as the absent sentinel, and read
# with IFS=$'\t' — a worker or closed_by string containing a space would
# otherwise shift every later field one position and the gate would silently
# read the wrong value out of a well-formed ledger response. Every field carries
# a sentinel, so no field is ever empty and the positional read is total.
# `claimed` distinguishes "claim object exists" from "claim is null", so a done
# task that was never worked reads differently from one closed through the
# engine. Any literal tab inside a value is squashed to a space by the emitter
# below, so the separator can never be forged from the data side.
IFS=$'\t' read -r found lifecycle worker closed_by claimed < <(python3 - "$tmp" <<'PY'
import json, sys


def emit(*fields):
    # Tabs and newlines are stripped from values so a ledger string can never
    # forge a field separator or a second record.
    print("\t".join(str(f).replace("\t", " ").replace("\n", " ") for f in fields))


try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    emit("error", ".", ".", ".", "no")
    sys.exit(0)
doc = d.get("result")
if isinstance(doc, list):
    doc = doc[0] if doc else None
if not isinstance(doc, dict) or not doc.get("_id"):
    emit("missing", ".", ".", ".", "no")
    sys.exit(0)
raw = doc.get("claim")
claim = raw if isinstance(raw, dict) else {}
emit("found",
     doc.get("lifecycle_status") or ".",
     claim.get("worker") or ".",
     claim.get("closed_by") or ".",
     "yes" if claim else "no")
PY
)

case "$found" in
  error)   neutral "ledger response for ${TASK_ID} was not valid JSON; not blocking on a transport error" ;;
  missing) fail "task '${TASK_ID}' does not exist on the ledger (${LEDGER_BASE}) — reference a real task" ;;
esac

# The task-backed predicate. Exactly two lifecycles can back a change, and each
# needs its own proof that the claim/close ENGINE — not a hand-flip — produced
# the state. `actor` is whoever that proof names; EXPECTED_WORKER is checked
# against it below.
case "$lifecycle" in
  in_progress)
    # A hand-flip through `bp doc patch` can set lifecycle_status without ever
    # going through claim, leaving in_progress with no worker. (This is NOT the
    # TTL sweeper: apply_reap/1 writes worker->nil AND lifecycle->"open" in one
    # Repo.update_all, ttl_sweeper.ex:256/:269/:284, asserted at
    # ttl_sweeper_test.exs:126-128. schema.ex:147-161 warns about the hand-flip
    # in its own comment.)
    [ "$worker" != "." ] || fail "task '${TASK_ID}' is in_progress but carries no claim.worker — that state comes from editing lifecycle_status directly (bp doc patch) instead of going through the claim/close engine. Re-claim it: bp task claim ${TASK_ID} <worker>"
    actor="$worker"
    verdict="in_progress, claimed by '${worker}'"
    ;;
  done)
    # done is the SUCCESS case, but only when the close went through the engine.
    if [ "$claimed" = "no" ]; then
      fail "task '${TASK_ID}' is done but carries no claim at all — it was never worked through the claim/close engine, so it is no evidence this change is task-backed"
    fi
    [ "$closed_by" != "." ] || fail "task '${TASK_ID}' is done but its claim carries no closed_by — the lifecycle was flipped by hand rather than closed through the engine (bp task close ${TASK_ID} <worker> <epoch>)"
    actor="$closed_by"
    verdict="done, closed by '${closed_by}'"
    ;;
  open)
    fail "task '${TASK_ID}' is still 'open' — claim it before opening the PR (bp task claim ${TASK_ID} <worker>)"
    ;;
  *)
    fail "task '${TASK_ID}' is '${lifecycle}' — only 'in_progress' (claimed) or 'done' (closed through the engine) back a change"
    ;;
esac

if [ -n "${EXPECTED_WORKER:-}" ] && [ "$EXPECTED_WORKER" != "$actor" ]; then
  fail "task '${TASK_ID}' names worker '${actor}', not the PR author's mapped worker '${EXPECTED_WORKER}'"
fi

pass "task '${TASK_ID}' is task-backed — ${verdict}"
