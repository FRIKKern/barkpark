#!/usr/bin/env bash
#
# landed-mark.sh — when a PR lands on main, the task row it names learns its
# merge sha. Nothing in the merge path wrote to the ledger before this.
#
# THE DEFECT, measured by lead-reconcile 2026-09-01 across the P1 ready backlog
# ----------------------------------------------------------------------------
# A PR lands on origin/main carrying `Task: <id>` in its squash body. The PR
# task gate read that trailer on the way IN, as a presence check, and nothing
# reads it on the way OUT: `gh pr merge --squash` and scripts/bp-merge.sh push
# the button and stop. The builder was told to report, not close, so the claim
# is released or lapses. The row is left lifecycle-open, assignee = a worker
# name nobody is, claim = none. Of the first 18 rows with a Task-trailer PR on
# main, 14 sat in exactly that state; 27 were sealed by hand in one session and
# 9 more part-stamped. The seal is owed to a lead who never arrives, so the next
# lane spends a worker re-triaging a row whose work shipped days ago.
#
# THE DECISION THIS SCRIPT IS (recorded here because a decision that lives only
# in a PR body is not recorded — task-2e16f1390ffc064f criterion 2)
# ----------------------------------------------------------------------------
# Two sides could own the seal after merge, and only one of them survives
# contact with how this fleet actually works:
#
#   REJECTED — THE LEAD BRIEF OWNS IT. Make "seal on merge" a required brief
#   step with `--list-open` (below) as its checklist. This is cheaper to write
#   and it is what the 27 hand-seals already were. It was not chosen because the
#   defect IS this remedy failing: the brief already said a lead seals, the
#   instruction was in force for every one of the 14 rows, and the measurement
#   is what a step that depends on a human arriving looks like at scale. Adding
#   the step a second time, more loudly, changes nothing a machine can check. It
#   survives here as the DEGRADED mode, not the mechanism: `--list-open` is
#   shipped so a lead can still find what the automation missed.
#
#   CHOSEN — THE MERGE PATH OWNS IT. The push to main is the only event that is
#   guaranteed to happen exactly once per landing, is observable without anyone
#   being awake, and already knows both halves of the fact (the sha, and the
#   trailer naming the row). .github/workflows/landed-mark.yml fires on it and
#   calls this script. The cost is real and is accepted: CI holds a write token
#   and never a claim, so the mark it leaves is weaker than a close (see the
#   next section) and the seal is still a lead's to finish. The mark is what
#   turns "re-triage this row from scratch" into "read one line".
#
# WHAT CI IS ALLOWED TO WRITE — THREE DOORS TRIED, ONE THAT WORKS
# ----------------------------------------------------------------------------
# CI holds a WRITE TOKEN and never a CLAIM. That one fact eliminates most of the
# task API, and it eliminated the obvious answer first.
#
#   REFUSED — POST /v1/tasks/:id/stamp. The verb the brief reaches for, and it
#   cannot be used from CI at all. It runs check_holder then check_fencing
#   before it touches anything: the caller must BE the claim holder AND present
#   the live epoch, so every stamp CI attempts is a 409 not_holder. Nothing
#   rescues it — `holder_override` exists only on the close path, and the epoch
#   fence there is independent of it, so a caller that does not know the epoch
#   is refused even with an override reason. close / release / pulse are gated
#   the same way, and none of them is wanted here regardless: THIS SCRIPT NEVER
#   CLOSES A ROW AND NEVER CLAIMS ONE. A merge is evidence about a row, not a
#   verdict on it.
#
#   REFUSED — POST /v1/data/mutate/<dataset> with a `patch`. This is the door
#   pr-task-gate.yml's hotfix lane already opens with the same secret, it takes
#   a plain write scope with no claim and no epoch, and every guard on it is one
#   this script would not trip. It was built against, tried live, and REJECTED
#   ON EVIDENCE: a task patch resolves its base through the DRAFT spelling, so
#   the write lands on `drafts.<id>` and the task API never reads it. Measured
#   on task-71762fd1bf152e49: the row's own GET reports rev 9cebfb2b…, the
#   mutate door reports actual b7e6bb19… and 412s any ifRevisionID taken from
#   the first; forcing the door's own rev returned 200 with
#   `results[0].id = "drafts.task-71762fd1bf152e49"`, and a fresh GET showed the
#   published row unchanged, byte for byte. A mark nobody can read is worse than
#   no mark: it looks like the mechanism is working. Publishing the draft
#   afterwards would promote every unrelated in-flight draft edit along with it,
#   which is not a thing an unattended job may do.
#
#   REFUSED — POST /v1/tasks/:id/stage with a note. Non-holder and free-text,
#   but it writes `content.disposition_reason`, a SINGLE-VALUED triage field
#   (Map.put, not a union). A landing would erase whatever a human wrote there.
#
#   CHOSEN — POST /v1/tasks/:id/labels. Task-native, so it reads the PUBLISHED
#   row directly (Repo.get under a per-task advisory lock, CAS on the row's own
#   rev), takes no worker and no epoch, and its add-list is union-merged and
#   de-duplicated server-side. It emits `task.relabeled`, so the mark is on the
#   event feed as well as the row. It cannot remove a label: this script sends
#   `add` and never `remove`.
#
# WHAT THE MARK IS
#   content.labels gains two entries, once:
#       landed-on-main            the class, so a board filter finds the whole
#                                 population in one query
#       landed:pr-<n>@<sha10>     the fact — which PR, which commit
#   Nothing else is written. Not lifecycle_status, not the claim, not the
#   assignee, not the criteria array.
#
# WHAT IS STILL MISSING, AS A REQUEST (task-2e16f1390ffc064f, for lead-cli)
# ----------------------------------------------------------------------------
# A label carries a fact; it cannot carry a SENTENCE, and it cannot flip a
# criterion. So when a row has an acceptance criterion whose own text is about
# the PR merging, this script raises a ::notice naming the criterion and saying
# why it did not stamp it — and stops. Closing that gap needs ONE server-side
# verb, and it should be filed as a request rather than guessed at:
#
#     POST /v1/tasks/:doc_id/landed
#     body  {"commit": "<sha>", "pr": <n>, "note": "<sentence>",
#            "criterion": <index|null>}
#     auth  a token with WRITE on the task dataset. NO claim, NO epoch — the
#           whole point is that the caller is CI, which can never be the holder.
#     does  unions `commit`/`pr`/`note` into content.landed the way
#           Tasks.Close.merge_landed/2 already unions prs/files/capability_slugs,
#           and — when `criterion` is given AND that criterion's own text is
#           merge-shaped AND it is not already met — sets met=true with `note`
#           as evidence. Refuses on any other criterion index, so the verb can
#           never become a general non-holder stamp.
#     event `task.landed`, carrying the caller token id.
#
# Until that exists, the label IS the mark and the ::notice is the handover.
#
# IDEMPOTENT BY READ, NOT BY LUCK. A re-run on the same sha reads the row first
# and skips the write entirely when both labels are already on it. The labels
# verb is union-add, so a duplicate call would be harmless to the ROW — but it
# would still emit a second `task.relabeled` event, and an event feed that
# reports a landing three times is a feed a reader stops trusting. So the skip
# is on the read, and it is the arm scripts/landed-mark.test.sh disarms.
#
# THERE IS NO DATASET IN THE URL, deliberately. /v1/tasks/:id/labels is scoped
# by the token, unlike /v1/data/mutate/<dataset> — so there is no LEDGER_DATASET
# knob here to set wrong.
#
# LOUD IN EXACTLY ONE DIRECTION. A mark is a courtesy, not a merge gate --
# the code is ALREADY ON MAIN by the time this runs, so failing the job cannot
# unland it and a red on main is a permanent red nobody can fix by pushing.
# So: a ledger outage (5xx, timeout, 412 after retries) is a ::warning and
# exit 0. A commit with no trailer is silence and exit 0 -- most commits have
# none. But 401/403 is exit 1, loudly naming BARKPARK_TASK_TOKEN, because a
# broken secret makes every future run a silent no-op, and a mechanism that
# fails quiet is the defect this script exists to remove, reintroduced.
#
# USAGE
#   bash scripts/landed-mark.sh                     # push mode (reads GITHUB_*)
#   bash scripts/landed-mark.sh --sha X --pr N      # one landing, by hand
#   bash scripts/landed-mark.sh --dry-run ...       # print the plan, write none
#   bash scripts/landed-mark.sh --list-open         # the instrument (below)
#   bash scripts/landed-mark.sh --selftest          # hermetic, no network
#
# THE INSTRUMENT (--list-open)
#   Lists task rows that are STILL OPEN although their id appears in a `Task:`
#   trailer of a commit on origin/main -- the population the measurement above
#   counted, re-derivable on demand. It is the degraded-mode checklist for a
#   lead, and it is how anyone checks whether this workflow is actually working:
#   the list should trend to zero, and any row on it either predates the
#   workflow or is one the workflow could not mark.
#
#     bash scripts/landed-mark.sh --list-open --range origin/main~40..origin/main
#     bash scripts/landed-mark.sh --list-open --fixture scripts/fixtures/landed-mark/2026-09-01T2000Z
#
#   The fixture directory is the documented equivalent of a ledger state: the
#   three rows lead-reconcile named were closed BY HAND hours after the
#   measurement, so the live ledger can no longer reproduce them. See that
#   directory's PROVENANCE.txt.
#
# EXIT CODES
#   0  marked, or nothing to mark, or a ledger outage (::warning)
#   1  the ledger REFUSED the credential (401/403) -- names the secret
#   2  CANNOT MEASURE: a bad flag, no python3, or a scan that read zero commits.
#      Never a vacuous green.
#
# NO `printf ... | grep -q` ANYWHERE IN THIS FILE. Under `pipefail` grep -q
# exits at the first match and the writer takes SIGPIPE, so the pipeline
# reports 141 -- a false NO that only appears under load. Here-strings and
# case statements throughout.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${BASH_SOURCE[0]}"
# The repo the commit walk reads. Overridable so the selftest can drive real
# `git rev-list` over mktemp repos instead of stubbing git — a stubbed walk
# proves nothing about the walk.
GITROOT="${LANDED_MARK_GIT_ROOT:-$ROOT}"

LEDGER_BASE="${LEDGER_BASE:-https://guerrilla.barkpark.cloud}"
RETRIES="${LANDED_MARK_RETRIES:-3}"
RETRY_DELAY="${LANDED_MARK_RETRY_DELAY:-2}"
MAX_COMMITS="${LANDED_MARK_MAX_COMMITS:-100}"

MODE="mark"
DRY_RUN=0
ARG_SHA=""
ARG_BEFORE=""
ARG_PR=""
ARG_RANGE=""
FIXTURE_DIR="${LANDED_MARK_FIXTURE_DIR:-}"

note()  { echo "landed-mark: $*"; }
warn()  { echo "::warning title=Landed mark skipped::landed-mark: $*" >&2; }
die2()  { echo "landed-mark: CANNOT MEASURE — $*" >&2; exit 2; }
# The credential refusal is the one loud arm. `::error` so it lifts into the
# check-run UI instead of dying in a log nobody opens.
die_auth() {
  echo "::error title=Landed mark cannot write — bad or missing BARKPARK_TASK_TOKEN::landed-mark: the ledger answered HTTP $1 for $2. The mark needs a token with WRITE scope on the task dataset; the workflow passes secrets.BARKPARK_TASK_TOKEN. Until it is fixed EVERY landing goes unmarked and the rows go back to being sealed by hand." >&2
  exit 1
}

usage() { sed -n '2,140p' "$SELF" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --selftest)   MODE="selftest"; shift ;;
    --list-open)  MODE="list-open"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --sha)        [ "$#" -ge 2 ] || die2 "--sha needs a value"; ARG_SHA="$2"; shift 2 ;;
    --sha=*)      ARG_SHA="${1#--sha=}"; shift ;;
    --before)     [ "$#" -ge 2 ] || die2 "--before needs a value"; ARG_BEFORE="$2"; shift 2 ;;
    --before=*)   ARG_BEFORE="${1#--before=}"; shift ;;
    --pr)         [ "$#" -ge 2 ] || die2 "--pr needs a value"; ARG_PR="$2"; shift 2 ;;
    --pr=*)       ARG_PR="${1#--pr=}"; shift ;;
    --range)      [ "$#" -ge 2 ] || die2 "--range needs a value"; ARG_RANGE="$2"; shift 2 ;;
    --range=*)    ARG_RANGE="${1#--range=}"; shift ;;
    --fixture)    [ "$#" -ge 2 ] || die2 "--fixture needs a path"; FIXTURE_DIR="$2"; shift 2 ;;
    --fixture=*)  FIXTURE_DIR="${1#--fixture=}"; shift ;;
    -h|--help)    usage; exit 0 ;;
    # An unknown flag NEVER passes. A typo'd flag that exits 0 is a mechanism
    # that silently stopped marking, which is indistinguishable from the defect.
    *)            die2 "unknown option '$1'" ;;
  esac
done

case "$RETRIES" in ''|*[!0-9]*|0) die2 "LANDED_MARK_RETRIES must be a positive integer, got '${RETRIES}'" ;; esac
case "$RETRY_DELAY" in ''|*[!0-9]*) die2 "LANDED_MARK_RETRY_DELAY must be a non-negative integer, got '${RETRY_DELAY}'" ;; esac

command -v python3 >/dev/null 2>&1 || die2 "python3 is not on PATH — the row reader and the patch builder are python3."

# ── The JSON half ────────────────────────────────────────────────────────────
# Written to a temp file rather than inlined in a `$(python3 - <<PY)` command
# substitution: bash 3.2 (what macOS ships) scans for the closing paren THROUGH
# a quoted heredoc inside a substitution, so one apostrophe in a Python comment
# would fail to parse this whole file — green on a runner, red on every
# developer machine. A heredoc into a file is not a substitution and is safe.
PYHELPER="$(mktemp -t landed-mark-py.XXXXXX)"
trap 'rm -f "$PYHELPER"' EXIT
cat > "$PYHELPER" <<'PYEOF'
import json, os, re, sys

# A criterion is merge-shaped when its own text says so. Deliberately narrow:
# three spellings, case-insensitive, and nothing else is ever flipped by CI.
MERGE_RE = re.compile(r"pr\s+merged|merged\s+to\s+main|merged\s+into\s+main", re.I)


def row_content(row):
    doc = row.get("doc", row) or {}
    return doc, (doc.get("content") or {})


def union(existing, incoming):
    out = list(existing or [])
    for item in incoming:
        if item not in out:
            out.append(item)
    return out


def cmd_plan(argv):
    row = json.load(open(argv[0]))
    sha, pr = argv[1], argv[2]
    doc, content = row_content(row)
    short = sha[:10]
    sentence = "landed on main as %s by PR #%s" % (sha, pr) if pr else "landed on main as %s" % sha

    labels = content.get("labels")
    labels = list(labels) if isinstance(labels, list) else []
    fact = ("landed:pr-%s@%s" % (pr, short)) if pr else ("landed:main@%s" % short)
    wanted = ["landed-on-main", fact]

    criteria = content.get("acceptance_criteria")
    criteria = list(criteria) if isinstance(criteria, list) else []
    hit = -1
    for i, c in enumerate(criteria):
        if isinstance(c, dict) and MERGE_RE.search(str(c.get("criterion") or "")):
            hit = i
            break
    # A merge-shaped criterion is REPORTED, never written: POST /v1/tasks/:id/
    # stamp is holder+epoch fenced and CI holds no claim, so the flip is a 409
    # by construction. See the header's REQUEST section.
    unstampable = ""
    if hit >= 0 and not criteria[hit].get("met"):
        unstampable = str(criteria[hit].get("criterion") or "")[:120]

    # MUT-IDEMPOTENT: the whole no-second-write guarantee is this one
    # condition. scripts/landed-mark.test.sh replaces it with `if False:` in
    # a scratch copy and requires the selftest's re-run assertions to go RED.
    if all(w in labels for w in wanted):
        print(json.dumps({"action": "noop", "reason": "already marked with %s" % short,
                          "unstampable": unstampable, "criterion_index": hit}))
        return 0

    print(json.dumps({
        "action": "criterion" if unstampable else "note",
        "criterion_index": hit, "evidence": sentence,
        "lifecycle": doc.get("lifecycle_status"),
        "unstampable": unstampable,
        "add": [w for w in wanted if w not in labels],
        "body": {"add": wanted},
    }))
    return 0


def cmd_field(argv):
    row = json.load(open(argv[0]))
    doc, content = row_content(row)
    claim = content.get("claim") or {}
    fields = {
        "lifecycle": doc.get("lifecycle_status") or content.get("lifecycle_status") or "?",
        "assignee": content.get("assignee") or "-",
        "claim": ("%s@%s" % (claim.get("worker"), claim.get("epoch"))) if claim.get("worker") else "none",
        "title": (doc.get("title") or content.get("title") or "")[:70],
    }
    print(json.dumps(fields))
    return 0


# Applies a mutate payload to a fixture row on disk, so the hermetic selftest's
# SECOND run reads the state the FIRST run wrote. Idempotency proven against a
# row that really changed, not against a stub that always says "already done".
def cmd_apply_fixture(argv):
    rowpath, payload = argv[0], json.load(open(argv[1]))
    row = json.load(open(rowpath))
    doc, content = row_content(row)
    content["labels"] = union(content.get("labels"), payload.get("add") or [])
    doc["content"] = content
    doc["rev"] = doc.get("rev", "") + "+"
    json.dump(row, open(rowpath, "w"))
    return 0


CMDS = {"plan": cmd_plan, "field": cmd_field, "apply-fixture": cmd_apply_fixture}
sys.exit(CMDS[sys.argv[1]](sys.argv[2:]))
PYEOF

# ── HTTP, with the fixture door ──────────────────────────────────────────────
# FIXTURE_DIR replaces the network entirely: rows/<id>.json is the GET, and a
# POST is appended to writes.log and applied to the row. Nothing in the selftest
# reaches guerrilla, so the harness cannot rot into a skip.
HTTP_STUB_CODE="${LANDED_MARK_FIXTURE_HTTP_CODE:-}"

ledger_get() { # $1 task id, $2 out file -> echoes an HTTP-ish code
  local id="$1" out="$2"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -n "$HTTP_STUB_CODE" ]; then echo "$HTTP_STUB_CODE"; return 0; fi
    if [ -f "$FIXTURE_DIR/rows/$id.json" ]; then
      cat "$FIXTURE_DIR/rows/$id.json" > "$out"; echo 200
    else
      echo 404
    fi
    return 0
  fi
  local auth=()
  [ -n "${LEDGER_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${LEDGER_TOKEN}")
  curl -sS -m 20 -o "$out" -w '%{http_code}' "${auth[@]}" \
    "${LEDGER_BASE%/}/v1/tasks/${id}" 2>/dev/null || echo 000
}

ledger_post() { # $1 task id, $2 body file, $3 out file -> echoes an HTTP-ish code
  local id="$1" body="$2" out="$3"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -n "$HTTP_STUB_CODE" ]; then echo "$HTTP_STUB_CODE"; return 0; fi
    cat "$body" >> "$FIXTURE_DIR/writes.log"; printf '\n' >> "$FIXTURE_DIR/writes.log"
    python3 "$PYHELPER" apply-fixture "$FIXTURE_DIR/rows/$id.json" "$body"
    echo '{"ok":true}' > "$out"; echo 200
    return 0
  fi
  curl -sS -m 30 -o "$out" -w '%{http_code}' \
    -X POST "${LEDGER_BASE%/}/v1/tasks/${id}/labels" \
    -H "Authorization: Bearer ${LEDGER_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data-binary "@${body}" 2>/dev/null || echo 000
}

# Bounded retry with backoff. 5xx/000 is transient; 401/403 is terminal and
# never retried (retrying a refused credential just multiplies the log).
with_retry() { # $1 fn, $2.. args -> sets RC_CODE
  local fn="$1"; shift
  local attempt=1 code delay="$RETRY_DELAY"
  while :; do
    code="$("$fn" "$@")"
    case "$code" in
      2??) RC_CODE="$code"; return 0 ;;
      401|403|404|409|412|422) RC_CODE="$code"; return 0 ;;
    esac
    if [ "$attempt" -ge "$RETRIES" ]; then RC_CODE="$code"; return 0; fi
    note "ledger answered ${code} — retry ${attempt}/${RETRIES} in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# ── Trailer extraction — ONE grammar, and it is not this file's ──────────────
# pr-task-gate.sh owns the `Task:` grammar (column 0, case-insensitive, backticks
# stripped, two DISTINCT ids is a refusal). It reads PR_BODY, and a squash body
# IS the PR body, so the commit message goes in unmodified. A second regex here
# would be a second grammar, which is how #5290 went red on a correct trailer.
# Overridable so a harness can run a SCRATCH COPY of this script from a temp
# directory without the copy losing the extractor and reddening every arm at
# once — a mutation that breaks everything locates nothing.
EXTRACTOR="${LANDED_MARK_EXTRACTOR:-$ROOT/scripts/pr-task-gate.sh}"
[ -f "$EXTRACTOR" ] || die2 "the Task: trailer grammar lives in ${EXTRACTOR} and it is not there. This script deliberately owns no second copy of that regex."

trailer_ids_for() { # $1 commit message -> id on stdout; rc 4 = ambiguous
  PR_BODY="$1" bash "$EXTRACTOR" --extract-task-id 2>/dev/null
}

pr_number_from_subject() { # squash convention: "subject (#1234)"
  local subject="$1" n
  n="$(sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p' <<<"$subject")"
  printf '%s' "$n"
}

# ── mark ─────────────────────────────────────────────────────────────────────
MARKED=0; NOOP=0; SKIPPED=0; SCANNED=0; PLANNED=0

mark_one() { # $1 task id, $2 sha, $3 pr
  local id="$1" sha="$2" pr="$3"
  local rowf planf bodyf outf attempt=1
  rowf="$(mktemp -t landed-mark-row.XXXXXX)"
  planf="$(mktemp -t landed-mark-plan.XXXXXX)"
  bodyf="$(mktemp -t landed-mark-body.XXXXXX)"
  outf="$(mktemp -t landed-mark-out.XXXXXX)"

  while :; do
    with_retry ledger_get "$id" "$rowf"
    case "$RC_CODE" in
      401|403) rm -f "$rowf" "$planf" "$bodyf" "$outf"; die_auth "$RC_CODE" "GET /v1/tasks/${id}" ;;
      2??) : ;;
      404) warn "task ${id} named by ${sha:0:10} is not on the ledger (HTTP 404) — nothing marked."
           SKIPPED=$((SKIPPED + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0 ;;
      *)   warn "reading task ${id} returned HTTP ${RC_CODE} — the mark for ${sha:0:10} is skipped, not failed. A mark is a courtesy; the code is already on main."
           SKIPPED=$((SKIPPED + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0 ;;
    esac

    if ! python3 "$PYHELPER" plan "$rowf" "$sha" "$pr" > "$planf" 2>/dev/null; then
      warn "could not read task ${id}'s row shape — the mark for ${sha:0:10} is skipped."
      SKIPPED=$((SKIPPED + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0
    fi

    local action evidence lifecycle idx
    action="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["action"])' "$planf")"
    if [ "$action" = "noop" ]; then
      note "${id}: already marked with ${sha:0:10} — no write."
      NOOP=$((NOOP + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0
    fi
    evidence="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["evidence"])' "$planf")"
    lifecycle="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lifecycle"])' "$planf")"
    idx="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["criterion_index"])' "$planf")"

    local adds unstampable
    adds="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["add"]))' "$planf")"
    unstampable="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["unstampable"])' "$planf")"
    # "would mark" on a dry run, "plan" on a real one. A real run that announces
    # "would mark" and then marks reads like it changed its mind.
    local verb="plan"; [ "$DRY_RUN" = "1" ] && verb="would mark"
    note "${verb} ${id} (${lifecycle}): note — \"${evidence}\" as label(s) ${adds}"
    if [ -n "$unstampable" ]; then
      # NOT a failure and NOT silence. The row HAS a criterion this landing
      # satisfies and CI is structurally barred from stamping it, so the notice
      # is the handover to whoever holds the claim.
      echo "::notice title=A merge-gated criterion still needs a holder::landed-mark: ${id} criterion ${idx} reads \"${unstampable}\" — this landing satisfies it, but POST /v1/tasks/${id}/stamp is holder+epoch fenced and CI holds no claim, so only the label was written. Stamping it needs the claim holder, or the non-holder landed verb requested in scripts/landed-mark.sh."
    fi

    if [ "$DRY_RUN" = "1" ]; then
      # Counted separately. A dry run that reports "0 marked" beside a printed
      # plan reads as a plan that was rejected, which is the opposite of true.
      PLANNED=$((PLANNED + 1))
      rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0
    fi

    python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["body"], open(sys.argv[2],"w"))' "$planf" "$bodyf"
    with_retry ledger_post "$id" "$bodyf" "$outf"
    case "$RC_CODE" in
      401|403) rm -f "$rowf" "$planf" "$bodyf" "$outf"; die_auth "$RC_CODE" "POST /v1/tasks/${id}/labels" ;;
      2??)
        note "marked ${id}: ${evidence}"
        MARKED=$((MARKED + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0 ;;
      412|409)
        # A holder wrote the row between our read and our write. The rev CAS did
        # its job — re-read and re-plan rather than clobber their stamp.
        if [ "$attempt" -ge "$RETRIES" ]; then
          warn "task ${id} changed under us ${attempt} times (HTTP ${RC_CODE}) — the mark for ${sha:0:10} is skipped, not forced."
          SKIPPED=$((SKIPPED + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0
        fi
        note "${id}: rev moved (HTTP ${RC_CODE}) — re-reading (attempt ${attempt}/${RETRIES})"
        attempt=$((attempt + 1)); continue ;;
      *)
        warn "writing the mark for ${id} returned HTTP ${RC_CODE} — skipped, not failed."
        SKIPPED=$((SKIPPED + 1)); rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0 ;;
    esac
  done
}

commit_list() {
  local sha="${ARG_SHA:-${GITHUB_SHA:-}}"
  local before="${ARG_BEFORE:-${GITHUB_EVENT_BEFORE:-}}"
  [ -n "$sha" ] || die2 "no sha to read — pass --sha or run under GITHUB_SHA."
  case "$before" in
    ''|0000000000000000000000000000000000000000) printf '%s\n' "$sha"; return 0 ;;
  esac
  if ! git -C "$GITROOT" cat-file -e "${before}^{commit}" 2>/dev/null; then
    # A force-push, a first push, or a shallow checkout that cannot see `before`.
    # Marking only the tip is the honest degradation; inventing a range is not.
    warn "github.event.before (${before:0:10}) is not in this checkout — marking only the tip commit."
    printf '%s\n' "$sha"; return 0
  fi
  git -C "$GITROOT" rev-list --reverse "${before}..${sha}" 2>/dev/null | head -n "$MAX_COMMITS"
}

run_mark() {
  local shas msg subject id rc pr
  shas="$(commit_list)"
  if [ -z "$shas" ]; then
    note "no commits in this push — nothing to mark."
    return 0
  fi
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    SCANNED=$((SCANNED + 1))
    msg="$(git -C "$GITROOT" log -1 --format='%B' "$sha" 2>/dev/null)"
    subject="$(git -C "$GITROOT" log -1 --format='%s' "$sha" 2>/dev/null)"
    id="$(trailer_ids_for "$msg")"; rc=$?
    if [ "$rc" = "4" ]; then
      warn "${sha:0:10} names two or more DISTINCT tasks at column 0 — pr-task-gate's grammar refuses to choose, and so does this. Nothing marked for that commit."
      SKIPPED=$((SKIPPED + 1)); continue
    fi
    [ -n "$id" ] || continue
    pr="${ARG_PR:-$(pr_number_from_subject "$subject")}"
    mark_one "$id" "$sha" "$pr"
  done <<<"$shas"

  if [ "$DRY_RUN" = "1" ]; then
    note "DRY RUN — scanned ${SCANNED} commit(s): ${PLANNED} would be marked, ${NOOP} already marked, ${SKIPPED} skipped. Nothing was written."
  else
    note "scanned ${SCANNED} commit(s): ${MARKED} marked, ${NOOP} already marked, ${SKIPPED} skipped."
  fi
}

# ── the instrument ───────────────────────────────────────────────────────────
run_list_open() {
  local msgs="" sha msg subject id rc found=0 seen=0
  if [ -n "$FIXTURE_DIR" ]; then
    [ -d "$FIXTURE_DIR/commits" ] || die2 "fixture ${FIXTURE_DIR} has no commits/ directory."
    msgs="$(ls -1 "$FIXTURE_DIR/commits" 2>/dev/null)"
  else
    local range="${ARG_RANGE:-origin/main~40..origin/main}"
    msgs="$(git -C "$GITROOT" rev-list "$range" 2>/dev/null | head -n "$MAX_COMMITS")"
    [ -n "$msgs" ] || die2 "git rev-list ${range} read zero commits — an empty scan is not a clean report."
  fi
  [ -n "$msgs" ] || die2 "read zero commits — an empty scan is not a clean report."

  printf '%-38s %-12s %-26s %-22s %-11s %s\n' TASK LIFECYCLE ASSIGNEE CLAIM COMMIT SUBJECT
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ -n "$FIXTURE_DIR" ]; then
      msg="$(cat "$FIXTURE_DIR/commits/$item")"
      sha="${item%.msg}"
      subject="$(head -n 1 <<<"$msg")"
    else
      sha="$item"
      msg="$(git -C "$GITROOT" log -1 --format='%B' "$sha" 2>/dev/null)"
      subject="$(git -C "$GITROOT" log -1 --format='%s' "$sha" 2>/dev/null)"
    fi
    seen=$((seen + 1))
    id="$(trailer_ids_for "$msg")"; rc=$?
    [ "$rc" = "4" ] && continue
    [ -n "$id" ] || continue

    local rowf code lifecycle
    rowf="$(mktemp -t landed-mark-row.XXXXXX)"
    with_retry ledger_get "$id" "$rowf"; code="$RC_CODE"
    case "$code" in
      401|403) rm -f "$rowf"; die_auth "$code" "GET /v1/tasks/${id}" ;;
      2??) : ;;
      *) printf '%-38s %-12s %-26s %-22s %-11s %s\n' "$id" "READ-${code}" "-" "-" "${sha:0:10}" "${subject:0:60}"
         rm -f "$rowf"; continue ;;
    esac
    local fields
    fields="$(python3 "$PYHELPER" field "$rowf")"
    lifecycle="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["lifecycle"])' "$fields")"
    case "$lifecycle" in
      done|cancelled) rm -f "$rowf"; continue ;;
    esac
    found=$((found + 1))
    printf '%-38s %-12s %-26s %-22s %-11s %s\n' \
      "$id" "$lifecycle" \
      "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["assignee"])' "$fields")" \
      "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["claim"])' "$fields")" \
      "${sha:0:10}" "${subject:0:60}"
    rm -f "$rowf"
  done <<<"$msgs"

  [ "$seen" -gt 0 ] || die2 "scanned zero commits — an empty scan is not a clean report."
  note "--list-open: scanned ${seen} commit(s); ${found} row(s) named by a landed Task: trailer are STILL OPEN."
}

case "$MODE" in
  selftest)  : ;;  # falls through to the selftest block below
  list-open) run_list_open; exit 0 ;;
  mark)      run_mark; exit 0 ;;
esac

# ── selftest ─────────────────────────────────────────────────────────────────
# Hermetic: mktemp git repos and mktemp fixture ledgers, no network, no token,
# no bp. It cannot rot into a skip, and it can LOSE — scripts/landed-mark.test.sh
# disarms the idempotency read in a scratch copy and watches these reds appear.
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing '$2')"; fi; }
hasnt(){ if grep -qF -- "$2" <<<"$1"; then bad "$3 (found '$2')"; else ok "$3"; fi; }

TMPROOT="$(mktemp -d -t landed-mark-selftest.XXXXXX)"
trap 'rm -f "$PYHELPER"; rm -rf "$TMPROOT"' EXIT

mkrepo() { # $1 dir; commits are added by mkcommit
  git init -q "$1" 2>/dev/null
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "root" 2>/dev/null
}
mkcommit() { # $1 dir, $2 message
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2" 2>/dev/null
  git -C "$1" rev-parse HEAD
}
mkledger() { # $1 dir
  mkdir -p "$1/rows"; : > "$1/writes.log"
}
mkrow() { # $1 ledgerdir, $2 id, $3 lifecycle, $4 assignee, $5 criterion-text ("" = none)
  python3 - "$1/rows/$2.json" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, tid, life, assignee, crit = sys.argv[1:6]
content = {"assignee": assignee, "lifecycle_status": life}
if crit:
    content["acceptance_criteria"] = [
        {"criterion": "an unrelated first criterion", "met": False, "evidence": ""},
        {"criterion": crit, "met": False, "evidence": ""},
    ]
json.dump({"ok": True, "doc": {"doc_id": tid, "rev": "rev0", "title": "fixture row " + tid,
                               "lifecycle_status": life, "content": content}}, open(path, "w"))
PY
}
# `grep -c` PRINTS a count AND exits 1 when the count is zero, so the house
# `|| echo 0` idiom fires BOTH sides and yields the two-line string "0\n0" —
# which then fails an `=` compare against "0" and reads as a broken assertion
# rather than a clean zero. Take grep's own output; it is already correct.
writes_in() { local n; n="$(grep -c '"add"' "$1/writes.log" 2>/dev/null)"; [ -n "$n" ] || n=0; printf '%s' "$n"; }
run() { LANDED_MARK_GIT_ROOT="$1" LANDED_MARK_FIXTURE_DIR="$2" LANDED_MARK_RETRY_DELAY=0 \
          bash "$SELF" "${@:3}" 2>&1; }

echo "landed-mark --selftest"

# 1. A backtick-wrapped trailer is the house idiom and MUST parse. #5290 went red
#    on exactly this shape while the bare spelling went green.
R1="$TMPROOT/r1"; L1="$TMPROOT/l1"; mkrepo "$R1"; mkledger "$L1"
mkrow "$L1" task-aaa1 in_progress builder-x ""
S1="$(mkcommit "$R1" "$(printf 'fix(x): a thing (#4242)\n\nbody prose\n\nTask: `task-aaa1`\n')")"
OUT="$(run "$R1" "$L1" --sha "$S1" --dry-run)"
has "$OUT" "task-aaa1" "a backtick-wrapped Task: trailer is read (the #5290 shape)"
has "$OUT" "landed on main as ${S1} by PR #4242" "the PR number comes off the squash subject"
check "a --dry-run writes NOTHING" "$(writes_in "$L1")" "0"
has "$OUT" "DRY RUN — scanned 1 commit(s): 1 would be marked" "a dry run says one WOULD be marked, never \"0 marked\""

# 2. Two commits in one push are both walked — a push is a RANGE, not a sha.
R2="$TMPROOT/r2"; L2="$TMPROOT/l2"; mkrepo "$R2"; mkledger "$L2"
mkrow "$L2" task-bbb1 open builder-y ""
mkrow "$L2" task-bbb2 open builder-z ""
BASE2="$(git -C "$R2" rev-parse HEAD)"
mkcommit "$R2" "$(printf 'fix(a): one (#11)\n\nTask: task-bbb1\n')" >/dev/null
S2="$(mkcommit "$R2" "$(printf 'fix(b): two (#12)\n\nTask: task-bbb2\n')")"
OUT="$(run "$R2" "$L2" --sha "$S2" --before "$BASE2")"
has "$OUT" "marked task-bbb1" "commit 1 of a two-commit push is marked"
has "$OUT" "marked task-bbb2" "commit 2 of a two-commit push is marked"
has "$OUT" "scanned 2 commit(s): 2 marked" "the tally counts the whole range"
check "two commits produced two writes" "$(writes_in "$L2")" "2"

# 3. IDEMPOTENCY. The second run re-reads the row the first run wrote and finds
#    the sha already there. This is the arm landed-mark.test.sh disarms.
OUT="$(run "$R2" "$L2" --sha "$S2" --before "$BASE2")"
# The PER-ROW line, never the tally: the tally says "0 marked, 2 already
# marked" on EVERY run, so an assertion on the phrase alone stays green with
# the idempotency read disarmed — measured, this exact assertion survived the
# mutant until it was tightened.
has "$OUT" "task-bbb1: already marked with" "a re-run over the same shas reports already-marked"
has "$OUT" "0 marked, 2 already marked" "the re-run tally is 0 marked"
check "a re-run wrote NOTHING NEW (still 2)" "$(writes_in "$L2")" "2"

# 4. No trailer at all is the COMMON case and must be silent, exit 0.
R3="$TMPROOT/r3"; L3="$TMPROOT/l3"; mkrepo "$R3"; mkledger "$L3"
S3="$(mkcommit "$R3" "chore: no trailer here (#99)")"
OUT="$(run "$R3" "$L3" --sha "$S3")"; RC=$?
check "a push with no trailer exits 0" "$RC" "0"
has "$OUT" "scanned 1 commit(s): 0 marked" "a push with no trailer marks nothing"
check "a push with no trailer writes nothing" "$(writes_in "$L3")" "0"

# 5. A criterion whose TEXT is about the merge gets met + evidence; one that is
#    not is left alone and the fact lands as a note instead.
R4="$TMPROOT/r4"; L4="$TMPROOT/l4"; mkrepo "$R4"; mkledger "$L4"
mkrow "$L4" task-ccc1 in_progress builder-q "The PR merged to main and CI is green."
mkrow "$L4" task-ccc2 in_progress builder-q "Some other checkable condition entirely."
S4a="$(mkcommit "$R4" "$(printf 'fix(c): crit (#21)\n\nTask: task-ccc1\n')")"
OUT="$(run "$R4" "$L4" --sha "$S4a")"
has "$OUT" "::notice" "a criterion whose text says 'merged to main' raises the holder notice"
has "$OUT" "holder+epoch fenced" "the notice says WHY CI cannot stamp it, not just that it did not"
has "$OUT" "marked task-ccc1" "the label mark still lands on a row CI cannot stamp"
S4b="$(mkcommit "$R4" "$(printf 'fix(c): note (#22)\n\nTask: task-ccc2\n')")"
OUT="$(run "$R4" "$L4" --sha "$S4b")"
has "$OUT" "note —" "a row with no merge-shaped criterion gets the label and nothing else"
hasnt "$OUT" "::notice" "no criterion notice is raised on a row that has no merge-shaped one"

# 6. THE WRITE IS A LABEL ADD AND NOTHING ELSE. The payload is the proof: this
#    is the arm that guarantees a merge never closes or claims a row.
has "$(cat "$L4/writes.log")" 'landed-on-main' "the write carries the landed-on-main class label"
has "$(cat "$L4/writes.log")" 'landed:pr-21@' "the write carries the PR and sha as a fact label"
hasnt "$(cat "$L4/writes.log")" '"lifecycle_status"' "the write NEVER touches lifecycle_status"
hasnt "$(cat "$L4/writes.log")" '"claim"' "the write NEVER touches the claim"
hasnt "$(cat "$L4/writes.log")" '"acceptance_criteria"' "the write NEVER rewrites the criteria array"
hasnt "$(cat "$L4/writes.log")" 'remove' "the write only ADDS labels — it can never strip one"

# 7. THE 401 ARM. A broken secret must be loud and non-zero — a mechanism that
#    fails quiet is the defect this script removes, reintroduced.
R5="$TMPROOT/r5"; L5="$TMPROOT/l5"; mkrepo "$R5"; mkledger "$L5"
mkrow "$L5" task-ddd1 open builder-w ""
S5="$(mkcommit "$R5" "$(printf 'fix(d): auth (#31)\n\nTask: task-ddd1\n')")"
OUT="$(LANDED_MARK_FIXTURE_HTTP_CODE=401 run "$R5" "$L5" --sha "$S5")"; RC=$?
check "a 401 from the ledger exits 1" "$RC" "1"
has "$OUT" "BARKPARK_TASK_TOKEN" "the 401 refusal names the secret by name"
has "$OUT" "::error" "the 401 refusal is an ::error, so it lifts into the check-run UI"
OUT="$(LANDED_MARK_FIXTURE_HTTP_CODE=403 run "$R5" "$L5" --sha "$S5")"; RC=$?
check "a 403 from the ledger exits 1 too" "$RC" "1"

# 8. A LEDGER OUTAGE IS NOT A RED. The code is already on main; a failing job
#    cannot unland it, and a red on main is a red nobody can push a fix through.
OUT="$(LANDED_MARK_FIXTURE_HTTP_CODE=503 LANDED_MARK_RETRIES=2 run "$R5" "$L5" --sha "$S5")"; RC=$?
check "a 503 from the ledger exits 0" "$RC" "0"
has "$OUT" "::warning" "a 503 is a ::warning, not a failure"
has "$OUT" "1 skipped" "a 503 is counted as skipped, never as marked"

# 9. AMBIGUITY IS REFUSED, not resolved by position. pr-task-gate owns that rule
#    and this script inherits it rather than guessing which id was meant.
R6="$TMPROOT/r6"; L6="$TMPROOT/l6"; mkrepo "$R6"; mkledger "$L6"
mkrow "$L6" task-eee1 open builder-v ""
S6="$(mkcommit "$R6" "$(printf 'fix(e): two ids (#41)\n\nTask: task-eee1\nTask: task-eee2\n')")"
OUT="$(run "$R6" "$L6" --sha "$S6")"; RC=$?
check "two DISTINCT trailer ids exits 0 (a merge is not undone by a bad body)" "$RC" "0"
has "$OUT" "DISTINCT" "two distinct ids are refused, not picked"
check "an ambiguous body writes nothing" "$(writes_in "$L6")" "0"

# 10. A criterion someone already met is a HOLDER's stamp. CI does not overwrite it.
R7="$TMPROOT/r7"; L7="$TMPROOT/l7"; mkrepo "$R7"; mkledger "$L7"
mkrow "$L7" task-fff1 in_progress builder-u "PR merged and the gate is green."
python3 - "$L7/rows/task-fff1.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["doc"]["content"]["acceptance_criteria"][1].update({"met": True, "evidence": "stamped by the holder"})
json.dump(d, open(p, "w"))
PY
S7="$(mkcommit "$R7" "$(printf 'fix(f): held (#51)\n\nTask: task-fff1\n')")"
OUT="$(run "$R7" "$L7" --sha "$S7")"
has "$OUT" "marked task-fff1" "the label still lands on a row whose criterion is already met"
hasnt "$OUT" "::notice" "an already-met criterion raises no holder notice — there is nothing left to ask for"
hasnt "$(cat "$L7/writes.log")" "criterion" "the holder's own stamp is never touched by the write"

# 11. THE INSTRUMENT. An OPEN row named by a landed trailer is listed; a DONE one
#     is not. Without both directions the list is not a measurement.
L8="$TMPROOT/l8"; mkledger "$L8"; mkdir -p "$L8/commits"
mkrow "$L8" task-ggg1 open stranded-builder ""
mkrow "$L8" task-ggg2 "done" lead-reconcile ""
printf 'fix(g): still open (#61)\n\nTask: task-ggg1\n' > "$L8/commits/aaaaaaaaaa.msg"
printf 'fix(g): sealed (#62)\n\nTask: task-ggg2\n'      > "$L8/commits/bbbbbbbbbb.msg"
printf 'chore(g): no trailer (#63)\n'                   > "$L8/commits/cccccccccc.msg"
OUT="$(bash "$SELF" --list-open --fixture "$L8" 2>&1)"; RC=$?
check "--list-open exits 0" "$RC" "0"
has "$OUT" "task-ggg1" "an OPEN row named by a landed trailer is listed"
has "$OUT" "stranded-builder" "the listing names the stranded assignee"
hasnt "$OUT" "task-ggg2" "a row already sealed is NOT listed"
has "$OUT" "scanned 3 commit(s); 1 row(s)" "the listing counts what it scanned"

# 12. AN EMPTY SCAN IS NOT A CLEAN REPORT. A zero-commit run must refuse.
L9="$TMPROOT/l9"; mkledger "$L9"; mkdir -p "$L9/commits"
OUT="$(bash "$SELF" --list-open --fixture "$L9" 2>&1)"; RC=$?
check "--list-open over zero commits is CANNOT MEASURE (rc 2)" "$RC" "2"
has "$OUT" "CANNOT MEASURE" "a zero-commit scan says so instead of reporting OK"

# 13. A typo'd flag NEVER passes: an exit 0 there is a mechanism that silently
#     stopped marking, which looks exactly like the defect.
OUT="$(bash "$SELF" --lst-open 2>&1)"; RC=$?
check "an unknown option refuses at exit 2" "$RC" "2"
has "$OUT" "unknown option" "the unknown-option refusal names the flag"

echo "landed-mark --selftest: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
