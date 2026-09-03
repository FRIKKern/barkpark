#!/usr/bin/env bash
#
# task-lease-renew.sh — buy a claimed ledger row grace while an OPEN pull
# request names it in a `Task:` trailer, and hand the grace back when that PR
# closes. The CI half of task-16e56d05b809dd39; the API half is
# `POST /v1/tasks/:doc_id/renew` (Barkpark.Tasks.Renew).
#
# ── THE DEFECT THIS CLOSES ───────────────────────────────────────────────────
# MEASURED 2026-09-02: the ledger's claim lease is 2700s (45 min) and the CI
# queue ran 60-90 min (390 queued runs at 04:15Z). The required
# `PR references an active task` context reads the claim WHEN IT RUNS, so a PR
# that waited out the queue met a row whose lease the TTL sweeper had already
# reaped — "still open and carries no claim". Ten PRs failed that way in one
# night; one lane re-claimed the same rows three times. RULED by the
# orchestrator: fix on the LEDGER side, and that context stays strict and
# byte-unchanged. Nothing in this file touches it.
#
# ── WHAT THIS IS NOT ─────────────────────────────────────────────────────────
# NOT a merge gate, and it never becomes one. `.github/required-checks.json`
# does not list this workflow and must not: a red here would block a PR for a
# LEDGER state, which is precisely the confusion the row was filed against.
# Every ledger answer this script can get — the row is gone, the row is not
# claimed, the extension cap is spent, the ledger is down — is a ::notice or a
# ::warning and exit 0. Exactly ONE arm is non-zero, and it is not about the PR
# at all: 401/403, a refused credential, because a broken secret makes every
# future run a silent no-op and reintroduces the defect with a green tick on
# top. That asymmetry is copied deliberately from scripts/landed-mark.sh, which
# learned it the same way.
#
# ── THE API CONTRACT THIS IS WRITTEN AGAINST ─────────────────────────────────
# Quoted from branch cli/lease-pr-extension (api/lib/barkpark/plugins/tasks.ex,
# api/lib/barkpark_web/controllers/tasks_controller.ex, docs/openapi.json):
#
#   route  {:post, "/tasks/:doc_id/renew", TasksController, :renew,
#           auth: :token_root}          — auth_tier "write", x-barkpark-scope write
#   body   {"pr": <positive int>, "state": "open"|"closed"|"merged",
#           "reason": "<free text>"}
#          `pr` is REQUIRED (400 otherwise): "an extension with no named reason
#          is a blank cheque". `state` absent means "open".
#   CLEAR  is NOT a second verb and NOT a DELETE — it is the SAME endpoint with
#          state=closed / state=merged, and it is PR-MATCHED: a close of PR #2
#          cannot cancel the window PR #1 bought.
#   200    {"ok": true, "doc": {... "content": {"claim": {"lease_extension":
#            {"until": <iso8601>, "pr": n, "reason": s,
#             "first_granted_at": iso, "last_renewed_at": iso,
#             "renewals": n}}}}}
#          A CLEAR also answers 200, with lease_extension absent.
#   409    {"ok": false, "reason": "not_claimed" | "extension_cap_reached"
#            | "stale_claim"}          — a ledger state, never this PR's fault
#   404    the row is not on the ledger
#   400    malformed pr / state (this script cannot produce one; it is still
#          classified, because an unclassified code is a silent no-op)
#   401/403  the credential was refused
#
# THE WINDOW IS THE SERVER'S TO COMPUTE. One renewal buys one lease-length
# (2700s) and total extension is capped at 21600s from the FIRST grant. This
# script sends no duration and does no arithmetic on time: a repeated
# `synchronize` renews the same bounded window, so the run is idempotent by
# construction rather than by a guard here.
#
# ── ONE TRAILER GRAMMAR, AND IT IS NOT THIS FILE'S ───────────────────────────
# scripts/pr-task-gate.sh owns the `Task:` grammar and exposes it as
# `--extract-task-id` (column 0, case-insensitive, backticks stripped, two
# DISTINCT ids is a refusal with rc 4). This script SHELLS OUT to it. A second
# regex here would be a third copy of the grammar in the repo — scripts/
# landed-mark.sh already delegates for the same reason, and PR #5290 went red
# on a correct trailer the last time a copy drifted.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   PR_BODY=... PR_NUMBER=15234 PR_ACTION=opened bash scripts/task-lease-renew.sh
#   PR_ACTION=closed PR_MERGED=true ... bash scripts/task-lease-renew.sh
#   bash scripts/task-lease-renew.sh --dry-run     # print the plan, write none
#
#   env:
#     PR_BODY      the PR description (the trailer source). Absent/empty is
#                  "no row named" — silence, not an error.
#     PR_NUMBER    required, positive integer.
#     PR_ACTION    the pull_request event action. `closed` clears; anything
#                  else renews.
#     PR_MERGED    "true" on a merged close -> state=merged, else state=closed.
#                  Both clear; the distinction is only what the record says.
#     LEDGER_BASE  default https://guerrilla.barkpark.cloud
#     LEDGER_TOKEN write-tier token (the workflow passes BARKPARK_TASK_TOKEN).
#                  ABSENT is a ::warning and exit 0, never a red: a fork PR
#                  receives no secrets, and this must not accuse a fork.
#     TASK_LEASE_RENEW_RETRIES        default 3
#     TASK_LEASE_RENEW_RETRY_DELAY    default 2 (seconds, doubling)
#     TASK_LEASE_RENEW_EXTRACTOR      override the trailer grammar's path
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  renewed / cleared / no trailer / row gone / row not claimed / cap spent /
#      ledger unreachable / no token. A ledger state is never this PR's fault.
#   1  the ledger REFUSED the credential (401/403) — names BARKPARK_TASK_TOKEN.
#   2  CANNOT MEASURE: a bad flag, a bad PR number, no python3, or a missing
#      trailer extractor. Never a vacuous green.
#
# NO `printf ... | grep -q` ANYWHERE IN THIS FILE. Under `pipefail` grep -q
# exits at the first match and the writer takes SIGPIPE, so the pipeline reports
# 141 — a false NO that only shows up under load. Case statements throughout.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${BASH_SOURCE[0]}"

LEDGER_BASE="${LEDGER_BASE:-https://guerrilla.barkpark.cloud}"
RETRIES="${TASK_LEASE_RENEW_RETRIES:-3}"
RETRY_DELAY="${TASK_LEASE_RENEW_RETRY_DELAY:-2}"
DRY_RUN=0

note() { echo "task-lease-renew: $*"; }
# A ledger STATE gets a ::notice — it is information about the row, not a
# finding about the pull request.
notice() { echo "::notice title=Task lease renew::task-lease-renew: $*"; }
warn()   { echo "::warning title=Task lease UNCHECKED::task-lease-renew: $*" >&2; }
die2()   { echo "task-lease-renew: CANNOT MEASURE — $*" >&2; exit 2; }
# The ONE loud arm. `::error` so it lifts into the check-run UI rather than
# dying in a log nobody opens, and it names the secret because a re-run cannot
# clear a refused credential.
die_auth() {
  echo "::error title=Task lease renew cannot write — BARKPARK_TASK_TOKEN was REFUSED::task-lease-renew: the ledger answered HTTP $1 for POST /v1/tasks/$2/renew. This is NOT an outage and re-running will not clear it. BARKPARK_TASK_TOKEN must be a least-privilege app token scoped read,write. Until it is fixed, every claim whose PR sits in the CI queue lapses again — the exact state this mechanism exists to remove." >&2
  exit 1
}

usage() { sed -n "2,$(($(grep -n '^set -uo pipefail' "$SELF" | head -1 | cut -d: -f1) - 1))p" "$SELF" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    # An unknown flag NEVER passes. A typo'd flag that exits 0 is a mechanism
    # that silently stopped renewing, which is indistinguishable from the defect.
    *) die2 "unknown option '$1'" ;;
  esac
done

case "$RETRIES" in ''|*[!0-9]*|0) die2 "TASK_LEASE_RENEW_RETRIES must be a positive integer, got '${RETRIES}'" ;; esac
case "$RETRY_DELAY" in ''|*[!0-9]*) die2 "TASK_LEASE_RENEW_RETRY_DELAY must be a non-negative integer, got '${RETRY_DELAY}'" ;; esac

command -v python3 >/dev/null 2>&1 || die2 "python3 is not on PATH — the response reader is python3."

# ── The response reader ──────────────────────────────────────────────────────
# Written to a temp FILE rather than inlined in a `$(python3 - <<PY)` command
# substitution: bash 3.2 (what macOS ships) scans for the closing paren THROUGH
# a quoted heredoc inside a substitution, so a single apostrophe in a Python
# comment would fail to parse this whole file — green on a runner, red on every
# developer machine.
PYHELPER="$(mktemp -t task-lease-renew-py.XXXXXX)"
BODYF="$(mktemp -t task-lease-renew-body.XXXXXX)"
REQF="$(mktemp -t task-lease-renew-req.XXXXXX)"
trap 'rm -f "$PYHELPER" "$BODYF" "$REQF"' EXIT

cat > "$PYHELPER" <<'PYEOF'
import json, sys

# The renew answer nests the record where the ledger keeps it:
# doc.content.claim.lease_extension. A CLEAR answers 200 with the key gone, so
# absence is a legitimate reading and never an error.
mode, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        payload = json.load(fh)
except Exception:
    payload = None

if not isinstance(payload, dict):
    print("")
    sys.exit(0)

if mode == "reason":
    print(str(payload.get("reason") or ""))
    sys.exit(0)

doc = payload.get("doc") or {}
content = doc.get("content") or {}
# The live server renders the claim at doc.claim (Params.render_doc lifts it);
# older fixtures and any pre-lift server put it under doc.content.claim. Read
# both, top level first — measured 2026-09-03: 20 real renews were written and
# answered 200 while this reader looked only under content and reported
# "carried no claim.lease_extension.until".
claim = doc.get("claim") or content.get("claim") or {}
ext = claim.get("lease_extension") or {}
if mode == "until":
    print(str(ext.get("until") or ""))
elif mode == "renewals":
    print(str(ext.get("renewals") or ""))
elif mode == "pr":
    print(str(ext.get("pr") or ""))
PYEOF

read_field() { python3 "$PYHELPER" "$1" "$BODYF" 2>/dev/null; }

# ── Trailer extraction — ONE grammar, and it is not this file's ──────────────
# Overridable so a harness can drive a SCRATCH COPY of this script from a temp
# directory without the copy losing the extractor and reddening every arm at
# once: a mutation that breaks everything locates nothing.
EXTRACTOR="${TASK_LEASE_RENEW_EXTRACTOR:-$ROOT/scripts/pr-task-gate.sh}"
[ -f "$EXTRACTOR" ] || die2 "the Task: trailer grammar lives in ${EXTRACTOR} and it is not there. This script deliberately owns no second copy of that regex."

TASK_ID=""
EXTRACT_RC=0
TASK_ID="$(PR_BODY="${PR_BODY:-}" bash "$EXTRACTOR" --extract-task-id 2>/dev/null)" || EXTRACT_RC=$?

if [ "$EXTRACT_RC" = "4" ]; then
  # AMBIGUOUS. pr-task-gate already reds the PR for this, with the sentence that
  # fixes it. Saying it twice, from a workflow with no authority to say it,
  # would only add noise to a page the author is already reading.
  notice "the PR body names two or more DISTINCT Task: ids at column 0, so there is no single row to renew. The required task context reports this; nothing here is renewed."
  exit 0
fi
if [ "$EXTRACT_RC" != "0" ]; then
  die2 "the trailer extractor exited ${EXTRACT_RC}"
fi
if [ -z "$TASK_ID" ]; then
  notice "this PR names no task row (no column-0 Task: trailer), so there is no claim to keep alive. Nothing to do."
  exit 0
fi

# ── The PR facts ─────────────────────────────────────────────────────────────
PR_NUMBER="${PR_NUMBER:-}"
case "$PR_NUMBER" in
  ''|*[!0-9]*|0) die2 "PR_NUMBER must be a positive integer, got '${PR_NUMBER}'. The API refuses a renew with no named PR (400) — an extension with no named reason is a blank cheque — so this script will not send one." ;;
esac

PR_ACTION="${PR_ACTION:-opened}"
PR_MERGED="${PR_MERGED:-false}"

# THE STATE MAP. `closed` is the clear, and BOTH kinds of close clear: a merged
# PR's row should be reapable at once, and an ABANDONED PR must not hold a row
# for the rest of its window. The API distinguishes them only in the record.
case "$PR_ACTION" in
  closed)
    case "$PR_MERGED" in
      true|True|TRUE) STATE="merged" ;;
      *)              STATE="closed" ;;
    esac
    VERB="clear" ;;
  *)
    STATE="open"
    VERB="renew" ;;
esac

printf '{"pr":%s,"state":"%s","reason":"open_pr"}' "$PR_NUMBER" "$STATE" > "$REQF"

if [ "$DRY_RUN" = "1" ]; then
  note "DRY RUN — would POST ${LEDGER_BASE%/}/v1/tasks/${TASK_ID}/renew with $(cat "$REQF")"
  exit 0
fi

if [ -z "${LEDGER_TOKEN:-}" ]; then
  # NOT an ::error. A pull_request run from a FORK receives no secrets, and this
  # workflow must never accuse a contributor of a repo-configuration fact. The
  # row simply lapses on the normal lease, which is today's behaviour.
  warn "no ledger token on this run (BARKPARK_TASK_TOKEN is unset — expected on a fork PR), so the claim on ${TASK_ID} was not extended and lapses on the normal lease."
  exit 0
fi

# ── HTTP ─────────────────────────────────────────────────────────────────────
# `curl` is invoked by NAME so scripts/task-lease-renew.test.sh can put a stub
# ahead of it on PATH and drive every response class through the REAL argument
# list this script builds. Nothing in the harness reaches guerrilla.
# The token is passed as a header value and is never echoed, never in a URL.
post_renew() { # -> echoes an HTTP-ish code, body lands in $BODYF
  : > "$BODYF"
  curl -sS --max-time 20 -o "$BODYF" -w '%{http_code}' \
    -X POST "${LEDGER_BASE%/}/v1/tasks/${TASK_ID}/renew" \
    -H "Authorization: Bearer ${LEDGER_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${REQF}" 2>/dev/null || echo 000
}

# Bounded retry with backoff. 5xx and 000 (timeout / connection failure) are
# transient; every decided answer — including 401/403 — is terminal, because
# retrying a refused credential only multiplies the log.
CODE=""
attempt=1
delay="$RETRY_DELAY"
while :; do
  CODE="$(post_renew)"
  case "$CODE" in
    2??|400|401|403|404|409|412|422) break ;;
  esac
  if [ "$attempt" -ge "$RETRIES" ]; then break; fi
  note "ledger answered ${CODE} — retry ${attempt}/${RETRIES} in ${delay}s"
  sleep "$delay"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
done

# ── Classification. EVERY arm below is exit 0 except the credential one. ─────
case "$CODE" in
  2??)
    if [ "$VERB" = "clear" ]; then
      notice "PR #${PR_NUMBER} is ${STATE}; the lease extension it bought on ${TASK_ID} is cleared, so the row is reapable on the next sweep."
    else
      UNTIL="$(read_field until)"
      RENEWALS="$(read_field renewals)"
      if [ -n "$UNTIL" ]; then
        notice "PR #${PR_NUMBER} keeps ${TASK_ID} claimed until ${UNTIL} (renewal ${RENEWALS:-1}). The claim holder and epoch are untouched."
      else
        # 200 with no window is not a failure to report as one: a clear answers
        # exactly this shape, and so does a body this reader cannot parse. Say
        # which fact is missing rather than inventing a time.
        notice "the ledger accepted the renew for ${TASK_ID} (HTTP ${CODE}) but its answer carried no claim.lease_extension.until, so the new boundary is unknown from here."
      fi
    fi
    exit 0 ;;
  404)
    notice "task ${TASK_ID}, named by PR #${PR_NUMBER}, is not on the ledger (HTTP 404) — there is no claim to extend. The required task context is what decides whether that matters."
    exit 0 ;;
  409)
    REASON="$(read_field reason)"
    case "$REASON" in
      not_claimed)
        notice "task ${TASK_ID} carries no live claim (HTTP 409 not_claimed). A renew may EXTEND a lease; it may never resurrect one a reap, a release or a close already ended. Re-claim the row if the work is still yours." ;;
      extension_cap_reached)
        notice "task ${TASK_ID} has spent its extension cap (HTTP 409 extension_cap_reached) — the total grace one claim can buy is bounded from the first grant, so a long-lived PR buys hours, not days. The claim will now lapse on the normal lease." ;;
      *)
        notice "the ledger declined to extend ${TASK_ID} (HTTP 409${REASON:+ ${REASON}}). That is a ledger state, not a finding about this PR." ;;
    esac
    exit 0 ;;
  401|403)
    die_auth "$CODE" "$TASK_ID" ;;
  400|412|422)
    warn "the ledger refused the renew body for ${TASK_ID} with HTTP ${CODE}$( [ -n "$(read_field reason)" ] && printf ' (%s)' "$(read_field reason)" ). The lease was NOT extended. This is a contract mismatch between this script and /v1/tasks/:doc_id/renew, not a finding about the PR."
    exit 0 ;;
  *)
    warn "the ledger did not answer after ${RETRIES} attempts (last: HTTP ${CODE}), so the claim on ${TASK_ID} was not extended and lapses on the normal lease. This is not a finding about this PR."
    exit 0 ;;
esac
