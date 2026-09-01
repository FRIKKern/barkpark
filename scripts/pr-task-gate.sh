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
#     TASK_ID                    required — the task doc id referenced by the PR
#     LEDGER_BASE                optional — ledger base URL (default guerrilla)
#     EXPECTED_WORKER            optional — if set, the actor must equal it
#     PR_OPENED_AT               required to decide a LAPSED claim — the PR's
#                                created_at (ISO-8601). Absent/unparseable is a
#                                refusal on that branch, never a fall-open.
#     PR_TASK_GATE_RETRIES       optional — ledger attempts (default 3)
#     PR_TASK_GATE_RETRY_DELAY   optional — seconds between attempts (default 2)
#   Exit codes:
#     0  pass   — the change is TASK-BACKED: the task exists and either
#                   • lifecycle_status == in_progress with a claim.worker, or
#                   • lifecycle_status == done with a claim.closed_by, or
#                   • lifecycle_status == open with a claim that was still LIVE
#                     when this PR was opened (the TTL sweeper reaped it while
#                     the PR sat in review)
#                 (and the actor matches EXPECTED_WORKER when that is set)
#     1  fail   — a DEFINITIVE violation: no task ref, task not found, task
#                 open and never claimed (or lapsed BEFORE the PR was opened),
#                 in_progress with no worker, done without ever having been
#                 claimed/closed through the engine, cancelled, or wrong worker.
#                 Must not merge.
#     2  UNCHECKED — the ledger could not be reached after PR_TASK_GATE_RETRIES
#                 attempts (network error / 5xx / 429 / 000), OR it answered 2xx
#                 with no task document in the envelope. This is NOT a pass:
#                 the caller (the workflow) turns it into a FAILURE carrying a
#                 self-describing "re-run once the ledger is up" message.
#
# Why 2 is distinct from 1: a hard fail means "the rule was checked and broken";
# 2 means "the rule could not be checked". Both block, but they read differently
# and only one of them is fixed by pressing re-run. Collapsing them would print
# a policy accusation at a reader whose PR is fine.
#
# Why 2 no longer passes (charter D24). The old contract was "neutral =
# pass-with-warning", and the handler that would have emitted that warning was
# unreachable dead code: the workflow step runs under GitHub's `bash -e`, which
# `set -uo pipefail` does not clear, so exit 2 aborted the step before `rc=$?`.
# The behaviour shipped for the whole life of the gate was therefore "5xx =
# red with a misleading label". Making the handler reachable AS WRITTEN would
# have turned every ledger blip into a SILENT GREEN — a blocking check passing
# having verified nothing — because GitHub removed the `neutral` conclusion for
# exit codes in 2019. So: bounded retry (a blip really is transient), then an
# honest red that says what to do about it.
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

# ── Trailer extraction ────────────────────────────────────────────────────────
# `pr-task-gate.sh --extract-task-id` reads the PR description from PR_BODY and
# prints the task id it references (nothing when there is no trailer). The
# workflow calls this instead of carrying its own copy of the grammar.
#
# It lives HERE, not inline in .github/workflows/pr-task-gate.yml, because the
# hermetic harness can only reach what the script exposes: while the grammar sat
# in the YAML, no test could run it, and it silently dropped every trailer whose
# id was wrapped in markdown backticks — PR #5290 went RED with a correct task
# reference while #5307 went green with the same task written bare (run
# 29804094521). A gate that reds on correct work spends the only thing it
# produces, a reviewer's trust.
#
# ACCEPTED — case-insensitive, at COLUMN 0, and surrounding backticks are
# stripped from the id:
#     Task: cch-bl-some-slug
#     Task: `cch-bl-some-slug`
#     task:   `cch-bl-some-slug`
#
# DELIBERATELY NOT ACCEPTED — each of these would be its own decision, not a
# wider character class, and each currently yields an empty id, which the gate
# below turns into a definitive FAIL ("no task reference found on the PR"):
#   • a trailer that is not at the start of its line — "see Task: x" mid-sentence
#   • other markdown wrappers — **Task:** x, _x_, [x](url), <x>, "x"
#   • a bare id with no `Task:` label, or a `Task:` label with no id after it
# The id character class itself is unchanged (a-z 0-9 . _ / -), so the set of
# ids this gate can name is exactly what it always was.
#
# ── WHY THIS NO LONGER PICKS, AND NO LONGER ALLOWS INDENTATION ───────────────
# It used to allow arbitrary leading whitespace and then take `head -1`. Both
# halves were wrong, and the second is the one that matters.
#
# INDENTATION: a fenced code block is indented, so an EXAMPLE trailer quoted
# inside one MATCHED. This fleet's briefs, PR bodies and handoff messages quote
# real, currently-claimed ids constantly — that is the house idiom — so the
# realistic vector was never a crafted attack, it was a routine paste. Column 0
# ends it, because a quoted example is not at column 0.
#
# PICKING: `head -1` resolved the ambiguity BY POSITION, and `tail -1` would
# have been exactly as wrong — it does not remove the hijack, it only changes
# WHICH quote wins. A body whose example sits BELOW the real trailer defeats
# `tail -1` precisely as one above it defeated `head -1`.
#
#   A GATE THAT RESOLVES AMBIGUITY BY POSITION IS GUESSING, AND A GUESS IN A
#   MERGE GATE IS A GUESS IN THE PERMISSIVE DIRECTION.
#
# So it no longer chooses: two or more DISTINCT ids is a REFUSAL. The same id
# repeated is not ambiguity — a body may legitimately restate its own trailer —
# so the ids are deduplicated before they are counted.
#
# EXIT CODES: 0 with the id on stdout · 0 with EMPTY stdout when there is no
# trailer at all (the caller turns that into the definitive "no task reference"
# FAIL) · 4 with the offending ids on stderr when the reference is ambiguous.
# Ambiguity gets its own code because it must not be reported as absence: the
# author of an ambiguous body HAS named their task, and telling them to add a
# trailer they already wrote is the kind of wrong instruction that gets a gate
# worked around rather than satisfied.
extract_task_ids() { # every DISTINCT column-0 trailer id, one per line
  printf '%s' "${PR_BODY:-}" \
    | grep -ioE '^task:[[:space:]]*`?[a-z0-9][a-z0-9._/-]*`?' \
    | sed -E 's/^[Tt][Aa][Ss][Kk]:[[:space:]]*//' \
    | tr -d '`' \
    | awk 'NF && !seen[$0]++'
}

extract_task_id() {
  ids="$(extract_task_ids)"
  n="$(printf '%s' "$ids" | grep -c . || true)"
  case "$n" in
    ''|0) return 0 ;;
    1)    printf '%s' "$ids"; return 0 ;;
  esac
  printf 'ambiguous task reference — %s distinct `Task:` ids at column 0: %s. Exactly one is required: keep the real trailer at column 0 and indent, fence or reword every example id.\n' \
    "$n" "$(printf '%s' "$ids" | tr '\n' ' ' | sed 's/ *$//')" >&2
  return 4
}

if [ "${1:-}" = "--extract-task-id" ]; then
  extract_task_id
  exit $?
fi

LEDGER_BASE="${LEDGER_BASE:-https://guerrilla.barkpark.cloud}"
DATASET="${LEDGER_DATASET:-production}"
RETRIES="${PR_TASK_GATE_RETRIES:-3}"
RETRY_DELAY="${PR_TASK_GATE_RETRY_DELAY:-2}"
# A non-numeric or zero retry count would make `[ "$attempt" -ge "$RETRIES" ]`
# error out, which reads as false — an INFINITE retry loop, i.e. a gate that
# hangs instead of deciding. Refuse the input loudly rather than guess.
case "$RETRIES" in ''|*[!0-9]*|0) echo "pr-task-gate: PR_TASK_GATE_RETRIES must be a positive integer, got '${RETRIES}'" >&2; exit 1 ;; esac
case "$RETRY_DELAY" in ''|*[!0-9]*) echo "pr-task-gate: PR_TASK_GATE_RETRY_DELAY must be a non-negative integer, got '${RETRY_DELAY}'" >&2; exit 1 ;; esac

# The refusal has to survive the trip to the check-run UI. A plain stderr line
# does not: a red `PR references an active task` exposed output.title=null,
# output.summary=null and a single annotation reading `Process completed with
# exit code 1.` — while all 17 fail() sites below already carry the exact
# remediation command. GitHub's log parser only lifts WORKFLOW COMMANDS out of a
# step's output, so the fix is the `::error title=…::` envelope, not the stream:
# proven 2026-07-28 on a live throwaway run, this exact form written to stderr
# from inside a called script, invoked exactly as .github/workflows/
# pr-task-gate.yml invokes it, landed as `[failure] title=… | pr-task-gate:
# FAIL: …`. Only `fail()` wears this title — `unchecked()` is an outage, not a
# finding about the PR, and the workflow raises its own ::error for it.
# CONSUMERS: the authored annotation is NOT annotations[0]. The runner's own
# `Process completed with exit code 1.` and actions/checkout's Node-20 warning
# both precede it, so select on a non-empty `.title`, never on index.
fail()      { echo "::error title=PR is not task-backed::pr-task-gate: FAIL: $*" >&2; exit 1; }
unchecked() { echo "pr-task-gate: UNCHECKED: $*" >&2; exit 2; }
pass()      { echo "pr-task-gate: PASS: $*";        exit 0; }

[ -n "${TASK_ID:-}" ] || fail "no task reference found on the PR (add a 'Task: <doc_id>' line to the PR description)"

# ── The CURE clause: what a reader must DO, not just what they broke ──────────
# Wave 24 shipped six PRs that were green on every code gate and then sat red
# for hours on this one required context. The red was not silent — it named the
# violation and handed over `bp task claim` — but it stopped one step short of
# landing anything, twice over:
#
#   1. RE-CLAIMING DOES NOT RE-FIRE THE GATE. This check runs on pull_request
#      events (opened/synchronize/reopened/edited/labeled/unlabeled); a write to
#      the LEDGER is not one of them. So a reader who does exactly what the red
#      told them watches the same red sit there, concludes the instruction did
#      not work, and either pushes an empty commit or gives up. The verdict is
#      sticky until something re-fires it, and the cheapest something is a
#      re-run of the failed job.
#   2. RELEASING AFTERWARDS IS UNRECOVERABLE BY RE-FIRE. `bp task release` does
#      not clear the claim — apply_release_update/2 in the tasks release path
#      MERGES released_by/released_at into the SURVIVING claim map and never
#      touches expired_at. A task that was reaped, re-claimed, then released
#      therefore carries released_at >= expired_at forever, which is precisely
#      the ordering clause below. No number of re-runs moves it; only a fresh
#      claim does. A reader tidying up after themselves ("I am done, let me
#      release it") converts a fixable red into a permanent one, and nothing in
#      the old message warned them.
#
# HOW TO FIND THE RUN ID BY HAND, and the trap in doing so (recorded here
# because this is the read site a reader lands on when the interpolated id is
# absent): `gh api repos/<owner>/<repo>/commits/<sha>/check-runs` PAGINATES at
# per_page=30. A sha carrying 36 check runs answered with this gate's run
# NOWHERE in the response — not an error, just a truncated page that reads as
# "the check never ran". Use `--paginate`, or `--jq` over a `per_page=100` page,
# and PIN THE RESULT BY (sha, check-run NAME) — never by check-run id: the cure
# below mints a NEW check-run id for the same (sha, name) pair, so an id
# captured before the re-fire points at the dead red forever.
#
# GITHUB_RUN_ID is a DEFAULT Actions environment variable (present in every
# step, no `env:` plumbing in .github/workflows/pr-task-gate.yml required), and
# it is the workflow RUN id — exactly what `gh run rerun` takes. Outside Actions
# it is unset, and the clause degrades to a readable literal rather than
# printing `gh run rerun  --failed`, which reads as a broken command.
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  RERUN_CMD="gh run rerun ${GITHUB_RUN_ID} --failed"
else
  RERUN_CMD="gh run rerun <this run id> --failed"
fi

# The ordering clause's own line number, quoted in the refusals below so the
# reader can jump straight to the rule they are one keystroke from tripping.
#
# DERIVED AT RUN TIME, NOT PINNED. It was a literal, and the literal was wrong
# within one edit of this file: adding the trailer-ambiguity refusal above moved
# the clause from :462 to :504 and the harness caught a citation that would have
# sent a blocked author 42 lines wrong. The harness catching it is the system
# working — but a pin that only survives because a test re-pins it by hand is a
# chore, and a chore is a thing that gets skipped. Computing it from the clause
# itself removes the class: the number cannot drift from the line it names.
#
# THE PATTERN IS ANCHORED ON THE CLAUSE'S SHAPE, NOT ON THE SYMBOL, because the
# first draft searched for the symbol alone — and THIS LINE contains the symbol,
# so `head -1` matched the assignment itself and the gate cited its own line
# number. The harness passed it, because its assertion only asked whether the
# cited line mentions `released_ge_expired`, which a line searching for that
# string does. A self-referential search needs a pattern its own source cannot
# satisfy: the clause opens `[ "$released_ge_expired"`, and this line cannot.
#
# If it ever matches nothing the reference degrades to a bare filename, which
# fails the harness's `[0-9]+` assertion loudly rather than misdirecting quietly.
ORDERING_CLAUSE_REF="pr-task-gate.sh:$(grep -nE '^[[:space:]]*\[ "\$released_ge_expired" = "no" \]' "$0" | head -1 | cut -d: -f1)"

# The whole cure, in the order it must be performed. Every refusal that a
# re-claim actually fixes carries this, verbatim.
CURE="Re-claim it: bp task claim ${TASK_ID} <worker>. THEN RE-FIRE THIS CHECK — a ledger write is not a pull_request event, so the red stays sticky until the job re-runs: ${RERUN_CMD}. And do NOT release the claim afterwards: release merges released_at into the SURVIVING claim and never touches expired_at (apply_release_update/2), so released_at >= expired_at trips the ordering clause at ${ORDERING_CLAUSE_REF} — a refusal that NO re-fire can clear, only a fresh claim."

url="${LEDGER_BASE%/}/v1/data/doc/${DATASET}/task/${TASK_ID}"

# -sS: quiet but show errors. -m 20: hard per-request cap. Capture body and the
# HTTP status separately so a 5xx is distinguishable from a 404 body.
tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.err"' EXIT

# Bounded retry, then decide (D24). Only INDECISIVE answers are retried: a
# transport failure or a status that is neither 404 nor 2xx. A 404 and a 2xx are
# both answers, and retrying an answer would only make the gate slower and its
# verdict a function of the wall clock — the exact contamination this epic
# exists to remove. `last_reason` carries the final attempt's reason so the
# UNCHECKED message names what actually happened, not a generic outage.
# Authenticated read (wave-3 token plumbing). The ledger serves task documents
# unauthenticated TODAY, but the day tasks flip to private every unauthenticated
# read of a REAL task answers 404, and the 404 branch below would then red every
# PR with "task does not exist" — a private-flip would make main unmergeable with
# no code change. Sending a Bearer keeps authenticated reads seeing the task.
# The header is added ONLY when LEDGER_TOKEN is non-empty: an EMPTY `Authorization:
# Bearer ` is a malformed-but-present credential, worse than sending none. The
# secret is UNPROVISIONED today and fork PRs never receive secrets, so the
# empty-token path is the common runtime case, not an error — the 404 branch
# below treats a token-absent 404 as an outage (exit 2), not a PR accusation.
# `${auth_args[@]+...}` guards the expansion for empty arrays under `set -u` on
# bash 3.2 (macOS), where a bare `"${auth_args[@]}"` on an empty array aborts.
auth_args=()
if [ -n "${LEDGER_TOKEN:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${LEDGER_TOKEN}")
fi

last_reason=""
fetch_doc() {
  local attempt=1
  while : ; do
    if http_code="$(curl -sS -m 20 ${auth_args[@]+"${auth_args[@]}"} -o "$tmp" -w '%{http_code}' "$url" 2>"$tmp.err")"; then
      case "$http_code" in
        404|2??) return 0 ;;
      esac
      last_reason="ledger returned HTTP ${http_code} for ${TASK_ID}"
    else
      http_code="000"
      last_reason="could not reach the ledger at ${LEDGER_BASE} ($(head -1 "$tmp.err" 2>/dev/null))"
    fi
    [ "$attempt" -ge "$RETRIES" ] && return 1
    echo "pr-task-gate: attempt ${attempt}/${RETRIES} was indecisive (${last_reason}); retrying in ${RETRY_DELAY}s" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

fetch_doc || unchecked "${last_reason} after ${RETRIES} attempts — the task backing of this PR could not be checked at all. This is not a finding about your PR: re-run this check once the ledger is up (ledger: ${LEDGER_BASE})"

# Status handling, decided by code not body. A 404 is an ANSWER, never retried
# (fetch_doc returns it at once), but what it MEANS depends on whether we could
# read the ledger authenticated:
#   404 + token PRESENT → we asked as ourselves and the task is not there →
#                         DEFINITIVE fail (exit 1). The accusation is TRUE.
#   404 + token ABSENT  → an unauthenticated read cannot tell a missing task from
#                         a PRIVATE one it is not allowed to see, so this is an
#                         OUTAGE about the gate's credentials, not a finding about
#                         the PR → UNCHECKED (exit 2), naming BARKPARK_TASK_TOKEN.
#                         This is the private-flip safety valve: fork PRs and the
#                         (currently unprovisioned) secret both land here, and
#                         neither deserves a false "your task does not exist" red.
#   2xx                 → parse the body (below).
# Everything else is already handled by fetch_doc (retry, then UNCHECKED).
case "$http_code" in
  404)
    if [ -n "${LEDGER_TOKEN:-}" ]; then
      fail "task '${TASK_ID}' does not exist on the ledger (${LEDGER_BASE}) — reference a real task (HTTP 404)"
    else
      unchecked "the ledger answered 404 for '${TASK_ID}' and no LEDGER_TOKEN was supplied, so an unauthenticated read cannot tell a missing task from a private one it may not see — the task backing of this PR could not be checked. This is not a finding about your PR: provision BARKPARK_TASK_TOKEN (see .github/workflows/pr-task-gate.yml and docs/ops/merge-gates.md) and re-run, or — on a fork PR, which never receives secrets — merge from a branch in this repo (ledger: ${LEDGER_BASE})"
    fi
    ;;
  2??)     : ;;  # parse below
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
#
# The last five fields serve the lapsed-claim branch (D23/D58) and are computed
# here because the arithmetic is timestamp parsing, which shell cannot do
# portably: `prev_worker` is stamped by the TTL sweeper's reap, `lapse_age` is
# the whole seconds since claim.expired_at ("." when it is missing or does not
# parse — never 0, which would silently read as "just lapsed"),
# `released_ge_expired` answers the one question that separates a reap from a
# voluntary release, `pr_open_state` says whether PR_OPENED_AT could be read at
# all ("ok" / "absent" / "unparseable" — the gate refuses on the last two rather
# than comparing against a guess), and `open_lead` is claim.expired_at minus the
# PR's created_at in whole seconds: >= 0 means the claim was still LIVE when the
# PR was opened, < 0 means it had already lapsed by then (see the `open` branch).
IFS=$'\t' read -r found lifecycle worker closed_by claimed prev_worker lapse_age released_ge_expired pr_open_state open_lead < <(python3 - "$tmp" <<'PY'
import json, os, sys
from datetime import datetime, timezone


def emit(*fields):
    # Tabs and newlines are stripped from values so a ledger string can never
    # forge a field separator or a second record.
    print("\t".join(str(f).replace("\t", " ").replace("\n", " ") for f in fields))


def ts(value):
    """Parse a ledger ISO-8601 stamp to an aware datetime, or None.

    Returns None for anything unparseable rather than a sentinel time: the
    caller must be able to tell "no timestamp" from "an old one", because those
    two decide opposite ways.
    """
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


# PR_OPENED_AT is read HERE and reported as a state rather than defaulted: an
# absent or unparseable value must reach the shell as itself, because the only
# honest answer to "was the claim live when the PR opened?" without it is "the
# gate cannot tell", and the rule for that is refuse, never pass.
#
# NOTE for anyone editing these comments: this block is a heredoc inside a
# process substitution, so bash scans it for the closing paren while tracking
# quotes. A lone apostrophe here (a possessive, a contraction) is an unbalanced
# single quote and breaks the whole script with "bad substitution". Spell around
# it — every comment below is apostrophe-free on purpose.
raw_pr_open = os.environ.get("PR_OPENED_AT", "")
pr_opened_at = None
if not raw_pr_open.strip():
    pr_open_state = "absent"
else:
    pr_opened_at = ts(raw_pr_open)
    pr_open_state = "ok" if pr_opened_at is not None else "unparseable"

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    emit("error", ".", ".", ".", "no", ".", ".", "unknown", pr_open_state, ".")
    sys.exit(0)
doc = d.get("result")
if isinstance(doc, list):
    doc = doc[0] if doc else None
if not isinstance(doc, dict) or not doc.get("_id"):
    emit("missing", ".", ".", ".", "no", ".", ".", "unknown", pr_open_state, ".")
    sys.exit(0)
raw = doc.get("claim")
claim = raw if isinstance(raw, dict) else {}

expired_at = ts(claim.get("expired_at"))
released_at = ts(claim.get("released_at"))
lapse_age = "."
if expired_at is not None:
    lapse_age = int((datetime.now(timezone.utc) - expired_at).total_seconds())
# Unknown when there is no expired_at to compare against: the shell branch
# accepts ONLY the explicit "no", so an unknown can never be read as a reap.
released_ge_expired = "unknown"
if expired_at is not None:
    released_ge_expired = "yes" if (released_at is not None and released_at >= expired_at) else "no"

# "." whenever either side is unreadable — the shell branch accepts only an
# integer, so an unknown can never be read as "the claim was live".
open_lead = "."
if expired_at is not None and pr_opened_at is not None:
    open_lead = int((expired_at - pr_opened_at).total_seconds())

emit("found",
     doc.get("lifecycle_status") or ".",
     claim.get("worker") or ".",
     claim.get("closed_by") or ".",
     "yes" if claim else "no",
     claim.get("previous_worker") or ".",
     lapse_age,
     released_ge_expired,
     pr_open_state,
     open_lead)
PY
)

# `missing` is UNCHECKED, not a violation (charter D59). It is reachable ONLY
# via a 200 whose envelope carries no task document: both genuine "no such task"
# cases (a nonexistent id; a real id of another type) answer HTTP 404 and are
# decided by the 404 branch above, verified live. So the accusation this branch
# used to print — "task does not exist" — could only ever be false, while the
# thing that actually happened is that the ledger answered without answering.
# The branch is NOT deleted: the emitter still emits `missing`, and removing the
# arm would drop it through to the lifecycle catch-all, which prints a second,
# worse false accusation ("task '' is '.'"). Honest limit: exit 2 is still turned
# into a workflow FAILURE by design (D24) — this removes the false ACCUSATION,
# not the block.
case "$found" in
  error)   unchecked "ledger response for ${TASK_ID} was not valid JSON — the task backing of this PR could not be checked. Re-run this check once the ledger is serving well-formed documents" ;;
  missing) unchecked "the ledger answered 2xx for '${TASK_ID}' but the response carried no task document in its 'result' envelope, so the task backing of this PR could not be checked at all. This is not a finding about your PR (a task that genuinely does not exist answers 404, which reds definitively): re-run this check once the ledger is serving documents (ledger: ${LEDGER_BASE})" ;;
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
    [ "$worker" != "." ] || fail "task '${TASK_ID}' is in_progress but carries no claim.worker — that state comes from editing lifecycle_status directly (bp doc patch) instead of going through the claim/close engine. ${CURE}"
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
    # A claim that was LIVE WHEN THIS PR OPENED backs the change (D23, D58).
    # The claim lease is ~45min and PR dwell routinely exceeds it, so the TTL
    # sweeper reaps a claim out from under a PR that was green when it opened:
    # 11 of the gate's last 15 reds were this, not a missing task. The reap
    # (ttl_sweeper.ex apply_reap) writes worker→nil AND lifecycle→"open" AND
    # stamps claim.previous_worker + claim.expired_at on the same document this
    # script already reads unauthenticated — so the gate can tell "reaped while
    # in review" from "never claimed" without a token, an events walk, or CI
    # writing to the ledger (a CI-side renewal bumps claim.epoch and would fence
    # the holder out of their own close).
    #
    # Every clause below is load-bearing; each one is a fixture in
    # scripts/pr-task-gate.test.sh.
    [ "$claimed" = "yes" ] || fail "task '${TASK_ID}' is still 'open' and carries no claim at all — it was never claimed, so this PR was not opened under a live claim. ${CURE}"
    [ "$worker" = "." ] || fail "task '${TASK_ID}' is 'open' but its claim still names worker '${worker}' — that mixed state does not come from the claim/close engine (a reap nulls the worker). ${CURE}"
    [ "$prev_worker" != "." ] || fail "task '${TASK_ID}' is still 'open' — its claim carries no previous_worker, so it was never claimed and reaped. ${CURE}"
    [ "$lapse_age" != "." ] || fail "task '${TASK_ID}' is 'open' with a previous_worker but no readable claim.expired_at, so how long ago the claim lapsed cannot be established. ${CURE}"
    # THE ORDERING CLAUSE. Release MERGES into the surviving claim — it stamps
    # released_by/released_at and never previous_worker — so a task that was
    # reaped, re-claimed, then voluntarily RELEASED still carries the old
    # expired_at and would read as "just lapsed" without this. A release is a
    # worker walking away, which is exactly the state the gate exists to red.
    # Only an explicit "no" (released_at is absent or predates the reap) passes.
    [ "$released_ge_expired" = "no" ] || fail "task '${TASK_ID}' is 'open' because its claim was RELEASED (released_at is at or after expired_at), not because a lease lapsed under a live PR — a released task is unowned. ${CURE}"
    # THE FUTURE-CLOCK FLOOR. A reap can never stamp an expiry ahead of the
    # clock — the sweeper only reaps a claim whose expiry has already passed —
    # so a negative age is not "very recently lapsed"; it is a clock or a
    # document the gate cannot trust, and the epic's rule for that is red, never
    # pass. Kept under P4 because P4 is PR-relative and would otherwise accept
    # any expiry stamped far enough forward: a one-field document edit would buy
    # an indefinite waiver. -300s of slack absorbs honest runner/ledger skew.
    [ "$lapse_age" -ge -300 ] || fail "task '${TASK_ID}' is 'open' and its claim.expired_at is ${lapse_age#-}s in the FUTURE — a reap cannot stamp a future expiry, so this document (or one of the two clocks) cannot be trusted to say when the claim lapsed. ${CURE}"
    # THE LEASE PREDICATE, P4 (charter D58): the claim was LIVE when this PR was
    # OPENED — claim.expired_at >= pull_request.created_at. It replaces the old
    # wall-clock grace, which made the verdict a function of how long a PR sat in
    # review: the same PR went green in the morning and red in the afternoon
    # having changed nothing, and 8 of 15 open PRs were red for that reason
    # alone. P4 has no tunable number in it, so there is no number to be wrong
    # about, and its answer for a given PR never changes.
    #
    # THE COST, stated rather than smuggled: P4 certifies "this PR was opened
    # under a live claim", NOT "the task is still being worked". A PR opened
    # under a live claim therefore passes forever, however long it then sits.
    # That is a real narrowing of what the gate asserts, accepted with eyes open
    # — the alternative on offer was a predicate whose verdict decays with the
    # wall clock, which is the contamination this epic exists to remove.
    #
    # Refuse, never fall open, when the PR's open time is unreadable: without it
    # the only honest answer is "the gate cannot tell", and a gate that cannot
    # tell must not certify. This is scoped to THIS branch because it is the only
    # one whose decision needs the comparison — in_progress and done are decided
    # from the document alone and refusing them would red PRs the gate can read.
    case "$pr_open_state" in
      absent)      fail "task '${TASK_ID}' is 'open' with a lapsed claim, but PR_OPENED_AT was not supplied, so the gate cannot tell whether that claim was still live when this PR was opened — it refuses to certify what it cannot read. The workflow passes it as PR_OPENED_AT: \${{ github.event.pull_request.created_at }} (.github/workflows/pr-task-gate.yml)" ;;
      unparseable) fail "task '${TASK_ID}' is 'open' with a lapsed claim, but PR_OPENED_AT ('${PR_OPENED_AT:-}') is not a readable ISO-8601 timestamp, so the gate cannot tell whether that claim was still live when this PR was opened — it refuses to certify what it cannot read" ;;
    esac
    [ "$open_lead" != "." ] || fail "task '${TASK_ID}' is 'open' and the gate could not compare claim.expired_at with this PR's open time, so whether the claim was live when the PR opened cannot be established. ${CURE}"
    [ "$open_lead" -ge 0 ] || fail "task '${TASK_ID}' is 'open': the claim by '${prev_worker}' had ALREADY lapsed ${open_lead#-}s before this PR was opened, so this PR was not opened under a live claim. ${CURE}"
    actor="$prev_worker"
    verdict="open, but the claim by '${prev_worker}' was still live when this PR was opened (it lapsed ${open_lead}s after, and was reaped ${lapse_age}s ago)"
    ;;
  *)
    fail "task '${TASK_ID}' is '${lifecycle}' — only 'in_progress' (claimed) or 'done' (closed through the engine) back a change"
    ;;
esac

if [ -n "${EXPECTED_WORKER:-}" ] && [ "$EXPECTED_WORKER" != "$actor" ]; then
  fail "task '${TASK_ID}' names worker '${actor}', not the PR author's mapped worker '${EXPECTED_WORKER}'"
fi

pass "task '${TASK_ID}' is task-backed — ${verdict}"
