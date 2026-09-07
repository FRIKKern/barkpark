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
#   content.labels gains two entries, once (POST /v1/tasks/:id/labels):
#       landed-on-main            the class, so a board filter finds the whole
#                                 population in one query
#       landed:pr-<n>@<sha10>     the fact — which PR, which commit
#   content.landed gains the same fact as a SENTENCE (POST /v1/tasks/:id/landed):
#       commits: [<sha>]  prs: ["<n>"]  notes: ["landed on main as <sha> by PR #<n>"]
#   and, ONLY where the server's own merge-shaped permit allows it, exactly one
#   acceptance criterion flips to met=true with that note as its evidence.
#   Nothing else is written by either door. Not lifecycle_status, not the claim,
#   not the assignee, not the criteria array wholesale, never a second criterion.
#
# AND A THIRD DOOR, FOR THE ROWS THIS MERGE DID NOT CREDIT
# ----------------------------------------------------------------------------
# Everything above marks the ONE row the `Task:` trailer names. A merge that
# also discharged a criterion on a SIBLING row left that row nothing, and the
# row went on advertising work origin/main already held (five measured
# instances in one day — task-29781d0921e5a885). A body may now name those rows
# at column 0:
#
#     Discharges: <doc_id> c<N>
#
# and this script POSTs the whole commit message to
# POST /v1/tasks/<the trailer row>/discharges, where the SERVER parses the
# citations (Barkpark.Tasks.Citations) and leaves each cited row a
# `discharge_marks` note carrying the PR, the sha and the primary row. That
# verb has NO criterion field and NO met field on the wire, so this door cannot
# fabricate a done the way a /landed criterion flip could. The grammar is not
# mirrored here: this file probes for the substring to decide whether to spend
# a request, and parses nothing.
#
# THE REQUEST WAS GRANTED — AND BOTH DOORS ARE NOW CALLED, NOT ONE
# ----------------------------------------------------------------------------
# This section used to be a REQUEST: a label carries a fact, it cannot carry a
# SENTENCE and it cannot flip a criterion, so the script raised a ::notice and
# stopped. PR #15090 built the verb that closes the gap:
#
#     POST /v1/tasks/:doc_id/landed
#     body  {"commit": "<sha>", "pr": "<n>", "note": "<sentence>",
#            "criterion": <zero-based index|null>}
#     auth  a token with WRITE on the task dataset. NO claim, NO epoch.
#     does  unions commit/pr/note into content.landed through the SAME
#           Tasks.Internal.merge_landed/2 a close uses, and — when `criterion`
#           is given and that criterion is MERGE-SHAPED and not already met —
#           sets met=true with `note` as its evidence.
#     event `task.landed`, carrying the caller token id.
#
# It shipped, and for four days NOTHING CALLED IT. The producer half of the gap
# task-2279167dd00ec347 measured on the consumer side: a facility that exists
# and is unconsumed. This script now calls it.
#
# WHY BOTH DOORS AND NOT A SWITCH TO THE NEW ONE. The obvious reading of "make
# landed-mark.sh call /landed instead of /labels" is WRONG, and the module doc
# of Barkpark.Tasks.Landed says so itself: "It cannot touch lifecycle_status,
# the claim, disposition, LABELS, or any other criterion." /landed writes
# content.landed. It cannot write a label, by design and on purpose.
#
# That matters because the label is the only QUERYABLE spelling. The reader,
# scripts/landed-open-report.sh, finds landed-but-open rows by walking the
# ledger for the `landed-on-main` class label; there is no server-side filter
# over content.landed. Dropping the /labels POST would have blinded that reader
# on the day it shipped, and turned 400-odd findable rows back into rows only a
# 3,000-PR-body scrape can see. So:
#
#     /labels  FIRST  — the queryable mark. If this fails, nothing else runs.
#     /landed  SECOND — the sentence, and the one criterion the server permits.
#
# The order is the failure mode talking. Labels-then-no-sentence leaves a row
# that is still FINDABLE. Sentence-then-no-labels leaves a row carrying a fact
# nothing queries — invisible, which is the exact defect this file exists to
# remove, reintroduced one layer down.
#
# THE SERVER OWNS THE PERMIT, NOT THIS SCRIPT. `merge_shaped?/1` is mirrored in
# the helper below so a --dry-run can print what will happen, but the mirror is
# not trusted to be exhaustive: it cannot see a future server rule, and here the
# predicate gates a PERMIT rather than a refusal, so erring permissive would be
# a SILENT fabricated done. A 409 (`criterion_not_merge_shaped`,
# `criterion_already_met`) is therefore EXPECTED traffic: the script retries
# without the criterion so the landing sentence still lands, and raises the
# ::notice as the handover to whoever holds the claim.
#
# IDEMPOTENT BY READ, NOT BY LUCK. A re-run on the same sha reads the row first
# and skips BOTH writes when the two labels are already on it AND
# content.landed.commits already carries this sha. Both halves, because a row
# marked before the /landed door existed has the labels and no sentence — a
# guard reading only the labels would call that row finished and leave every
# pre-existing row half-marked forever. A HALF-marked row is exactly what a
# re-run should finish. The labels
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

# The header IS the documentation, so --help prints it. The range stops one
# line short of `set -uo pipefail`; a hardcoded end that drifts behind the
# header silently truncates the decision record out of --help.
usage() { sed -n "2,$(($(grep -n '^set -uo pipefail' "$SELF" | head -1 | cut -d: -f1) - 1))p" "$SELF" | sed 's/^# \{0,1\}//'; }

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
import json, re, sys

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

    # MERGE-SHAPED, MIRRORING THE SERVER'S PERMIT EXACTLY.
    # Barkpark.Tasks.Landed.merge_shaped?/1 permits a criterion when it carries
    # `merge_gate: true`, OR when the author declared NO merge_gate flag and the
    # wording matches. An explicit `merge_gate: false` VETOES, and no prose match
    # may override an author who wrote it — because here the predicate gates a
    # PERMIT, not a refusal, so a false positive is a SILENT fabricated done.
    # This mirror exists so a dry run can print what the server will do; the
    # server is still the authority, and its 409s are handled, not prevented.
    hit = -1
    for i, c in enumerate(criteria):
        if not isinstance(c, dict) or c.get("met") is True:
            continue
        flag = c.get("merge_gate")
        if flag is False:
            continue
        if flag is True or (flag is None and MERGE_RE.search(str(c.get("criterion") or ""))):
            hit = i
            break
    unstampable = str(criteria[hit].get("criterion") or "")[:120] if hit >= 0 else ""

    # WHAT `content.landed` ALREADY HOLDS. The landing sentence goes through
    # POST /v1/tasks/:id/landed, whose union is by VALUE, so the idempotency
    # read has to cover it too — otherwise a re-run skips the labels (already
    # there) and still fires a second `task.landed` event.
    landed = content.get("landed")
    landed = landed if isinstance(landed, dict) else {}
    commits = landed.get("commits")
    commits = commits if isinstance(commits, list) else []
    commit_known = sha in commits

    # MUT-IDEMPOTENT: the whole no-second-write guarantee is this one
    # condition. scripts/landed-mark.test.sh replaces it with `if False:` in
    # a scratch copy and requires the selftest's re-run assertions to go RED.
    # BOTH halves must already be on the row: labels present AND this commit
    # already in content.landed.commits. A row carrying only one of them is
    # HALF-marked, and a re-run is exactly what should finish it.
    if all(w in labels for w in wanted) and commit_known:
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
        # THE SECOND DOOR. `pr` is a STRING on this verb (capabilities says so);
        # sending the int would be a 422 on a payload that looks right.
        "landed_skip": commit_known,
        "landed_body": landed_body(sha, pr, sentence, hit),
    }))
    return 0


def landed_body(sha, pr, sentence, hit):
    body = {"commit": sha, "note": sentence}
    if pr:
        body["pr"] = str(pr)
    # DELIBERATELY NOT SENT: `criterion`. See task-48ff3f84e68aecbb.
    #
    # The server's permit for a landed criterion flip holds NO claim, NO
    # worker_id and NO epoch, and it permits the flip whenever the criterion
    # merely LOOKS merge-shaped — including on `merge_gate: true`. But
    # `merge_gate: true` is set by LEADS to mean "the LEAD closes this, not the
    # builder", and it is carried by criteria demanding things a merge cannot
    # discharge (a live browser demo, an operator action). ONE BOOLEAN, TWO
    # MEANINGS, and the permit reads the wrong one. Once the last unmet
    # criterion flips this way the criteria gate has nothing left to refuse:
    # a SILENT FABRICATED `done`, with no holder's name on it.
    #
    # This script runs from .github/workflows/landed-mark.yml on push-to-main.
    # Sending `criterion` from here does not merely expose that defect, it ARMS
    # it on EVERY MERGE — turning "somebody must deliberately type the command"
    # into "it happens automatically". So the landing SENTENCE goes through
    # this door and the criterion NEVER does. The row that still looks
    # satisfiable is handed to its claim holder by ::notice instead, which is
    # the honest half of what the flip was for.
    #
    # DO NOT re-add this, not behind a condition and not "just for
    # merge_gate:true rows" — that predicate IS the bug. The fix belongs on the
    # server (task-48ff3f84e68aecbb, which requires a both-directions proof: a
    # permit that refuses everything is not a fix). `hit` is still computed and
    # still drives the ::notice; only the wire field is withheld.
    #
    # selftest section 4 asserts this by BYTE — a landed POST body carrying
    # "criterion" reds the suite. The prohibition is load-bearing, not prose.
    return body


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


# The /landed fixture applier — mirrors Tasks.Internal.merge_landed/2 (union by
# value, per key) and Tasks.Landed's single-criterion flip, so the hermetic
# selftest's SECOND run reads the state its FIRST run wrote. Idempotency proven
# against a row that really changed, not a stub that always says "already done".
def cmd_apply_landed_fixture(argv):
    rowpath, payload = argv[0], json.load(open(argv[1]))
    row = json.load(open(rowpath))
    doc, content = row_content(row)
    landed = content.get("landed")
    landed = dict(landed) if isinstance(landed, dict) else {}
    for src, key in (("commit", "commits"), ("pr", "prs"), ("note", "notes")):
        v = payload.get(src)
        if v:
            landed[key] = union(landed.get(key), [v])
    content["landed"] = landed
    idx = payload.get("criterion")
    crit = content.get("acceptance_criteria")
    if isinstance(idx, int) and isinstance(crit, list) and 0 <= idx < len(crit):
        if isinstance(crit[idx], dict) and crit[idx].get("met") is not True:
            crit[idx]["met"] = True
            crit[idx]["evidence"] = payload.get("note") or ""
    doc["content"] = content
    doc["rev"] = doc.get("rev", "") + "+"
    json.dump(row, open(rowpath, "w"))
    return 0


CMDS = {"plan": cmd_plan, "field": cmd_field, "apply-fixture": cmd_apply_fixture,
        "apply-landed-fixture": cmd_apply_landed_fixture}
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

# THE SECOND DOOR — POST /v1/tasks/:id/landed. Same token, same no-claim,
# no-epoch shape as /labels; a DIFFERENT blast radius (content.landed and at
# most one merge-shaped criterion). Kept as its own function so the fixture
# door records it under its own log and the selftest can assert the two writes
# independently.
ledger_post_landed() { # $1 task id, $2 body file, $3 out file
  local id="$1" body="$2" out="$3"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -n "${LANDED_MARK_FIXTURE_LANDED_CODE:-}" ]; then echo "$LANDED_MARK_FIXTURE_LANDED_CODE"; return 0; fi
    if [ -n "$HTTP_STUB_CODE" ]; then echo "$HTTP_STUB_CODE"; return 0; fi
    cat "$body" >> "$FIXTURE_DIR/landed.log"; printf '\n' >> "$FIXTURE_DIR/landed.log"
    python3 "$PYHELPER" apply-landed-fixture "$FIXTURE_DIR/rows/$id.json" "$body"
    echo '{"ok":true}' > "$out"; echo 200
    return 0
  fi
  curl -sS -m 30 -o "$out" -w '%{http_code}' \
    -X POST "${LEDGER_BASE%/}/v1/tasks/${id}/landed" \
    -H "Authorization: Bearer ${LEDGER_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data-binary "@${body}" 2>/dev/null || echo 000
}

# THE THIRD DOOR — POST /v1/tasks/:id/discharges. Same token, same no-claim,
# no-epoch shape; a THIRD blast radius, narrower than either of the other two.
# :id here is the PRIMARY row (the one the `Task:` trailer credits) and the body
# carries the whole commit message: the SERVER parses its `Discharges:` lines
# and marks the SIBLING rows the same merge may also have satisfied. Kept as its
# own function so the fixture door records it under its own log.
ledger_post_discharges() { # $1 primary task id, $2 body file, $3 out file
  local id="$1" body="$2" out="$3"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -n "${LANDED_MARK_FIXTURE_DISCHARGES_CODE:-}" ]; then echo "$LANDED_MARK_FIXTURE_DISCHARGES_CODE"; return 0; fi
    if [ -n "$HTTP_STUB_CODE" ]; then echo "$HTTP_STUB_CODE"; return 0; fi
    cat "$body" >> "$FIXTURE_DIR/discharges.log"; printf '\n' >> "$FIXTURE_DIR/discharges.log"
    echo '{"ok":true,"cited":0,"marked":0}' > "$out"; echo 200
    return 0
  fi
  curl -sS -m 30 -o "$out" -w '%{http_code}' \
    -X POST "${LEDGER_BASE%/}/v1/tasks/${id}/discharges" \
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
MARKED=0; NOOP=0; SKIPPED=0; SCANNED=0; PLANNED=0; LANDINGS=0; DISCHARGES=0

# THE SENTENCE HALF — POST /v1/tasks/:id/landed, fired AFTER the labels write.
#
# ORDER IS DELIBERATE AND IT IS NOT ARBITRARY. If the labels land and this
# fails, the row is still FINDABLE: scripts/landed-open-report.sh queries the
# `landed-on-main` label, so a lead still sees the row. If this landed and the
# labels failed, the row would carry a sentence nothing queries — invisible,
# which is the defect landed-mark.sh exists to remove, reintroduced one layer
# down. So the queryable mark goes first and this is the enrichment.
#
# NEVER FATAL. Same rule as the whole file: the code is already on main, a red
# here cannot unland it, and only 401/403 is loud (it means every future run is
# a silent no-op). A 409 is the SERVER EXERCISING ITS PERMIT — `criterion_not_
# merge_shaped` or `criterion_already_met` — and the right response is to retry
# WITHOUT the criterion and keep the sentence, then hand the criterion to a
# human by ::notice. The local mirror of merge_shaped?/1 is deliberately not
# trusted to be exhaustive: it cannot see a future server rule, and guessing
# wrong in the permissive direction would be a silent fabricated done.
post_landing() { # $1 id, $2 plan file, $3 criterion index, $4 criterion text, $5 sha
  local id="$1" planf="$2" idx="$3" ctext="$4" sha="$5"
  local lbody louf skip

  skip="$(python3 -c 'import json,sys; print("1" if json.load(open(sys.argv[1])).get("landed_skip") else "0")' "$planf")"
  if [ "$skip" = "1" ]; then
    note "${id}: content.landed already records ${sha:0:10} — the sentence is not written twice."
    return 0
  fi

  lbody="$(mktemp -t landed-mark-landedbody.XXXXXX)"
  louf="$(mktemp -t landed-mark-landedout.XXXXXX)"
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["landed_body"], open(sys.argv[2],"w"))' "$planf" "$lbody"

  with_retry ledger_post_landed "$id" "$lbody" "$louf"
  case "$RC_CODE" in
    401|403) rm -f "$lbody" "$louf"; die_auth "$RC_CODE" "POST /v1/tasks/${id}/landed" ;;
    2??)
      if [ "$idx" != "-1" ] && [ -n "$ctext" ]; then
        # The sentence landed; the criterion was never offered. See
        # task-48ff3f84e68aecbb and the comment in landed_body().
        note "${id}: landing recorded in content.landed; criterion ${idx} deliberately NOT flipped."
        echo "::notice title=A merge-gated criterion still needs a holder::landed-mark: ${id} criterion ${idx} reads \"${ctext}\" — this landing looks like it satisfies it, and the landing sentence WAS recorded. The criterion was deliberately not flipped: the server's landed permit carries no claim and reads merge_gate:true as \"a merge discharges this\" when leads set it to mean \"the LEAD closes this\" (task-48ff3f84e68aecbb). Flipping it needs the claim holder."
      else
        note "${id}: landing recorded in content.landed."
      fi
      LANDINGS=$((LANDINGS + 1)); rm -f "$lbody" "$louf"; return 0 ;;
    409|422)
      # The permit was refused. Drop the criterion, keep the sentence — the
      # landing is a fact regardless of whether any criterion may be flipped.
      if [ "$idx" != "-1" ]; then
        python3 -c '
import json,sys
b=json.load(open(sys.argv[1])); b.pop("criterion", None)
json.dump(b, open(sys.argv[1],"w"))' "$lbody"
        with_retry ledger_post_landed "$id" "$lbody" "$louf"
        case "$RC_CODE" in
          2??) LANDINGS=$((LANDINGS + 1))
               note "${id}: landing recorded without the criterion flip." ;;
          *)   warn "recording the landing for ${id} returned HTTP ${RC_CODE} — skipped, not failed." ;;
        esac
        # NOT a failure and NOT silence. The row HAS a criterion this landing
        # looks like it satisfies, the server declined to flip it, and the
        # handover to whoever holds the claim is this line.
        echo "::notice title=A merge-gated criterion still needs a holder::landed-mark: ${id} criterion ${idx} reads \"${ctext}\" — this landing looks like it satisfies it, but POST /v1/tasks/${id}/landed refused the flip (HTTP ${RC_CODE}: the criterion is not merge-shaped by the server rule, or somebody already met it). The landing sentence was recorded; flipping the criterion needs the claim holder."
      else
        warn "recording the landing for ${id} returned HTTP ${RC_CODE} — skipped, not failed."
      fi
      rm -f "$lbody" "$louf"; return 0 ;;
    *)
      warn "recording the landing for ${id} returned HTTP ${RC_CODE} — the LABEL is on the row, so the landing is still findable. Skipped, not failed."
      rm -f "$lbody" "$louf"; return 0 ;;
  esac
}

# THE SIBLING HALF — POST /v1/tasks/<primary>/discharges (task-29781d0921e5a885).
#
# WHAT IT IS FOR. The two doors above mark the ONE row the `Task:` trailer
# credits. A merge that also discharged a criterion on a SIBLING row left that
# row nothing at all: it kept advertising work origin/main already held, and a
# lead paid a full re-derivation to refute it (five measured instances, one day).
# A `Discharges: <doc_id> c<N>` line in the body names those rows.
#
# THIS SCRIPT OWNS NO SECOND GRAMMAR, HERE EITHER. The `case` below is a
# PRESENCE probe, not a parser: it decides only whether to spend an HTTP call,
# and it extracts nothing and resolves no row. The citation grammar lives in
# Barkpark.Tasks.Citations and runs on the SERVER, which is handed the commit
# message verbatim — the same rule the `Task:` extractor follows for the same
# reason (#5290: a second copy of a grammar reddens correct work). A false
# positive here costs one request that marks nothing; a false negative is
# impossible, because a citation the server would parse contains the probed
# substring by construction.
#
# NEVER FATAL, and it can never flip anything. The verb has no `criterion`
# field and no `met` field to send — the server writes a `discharge_marks` note
# and nothing else — so unlike /landed there is no permit to be careful about.
# Only 401/403 is loud (every future run would be a silent no-op). A 404 is the
# ledger not having this door yet, which is a ::warning and exit 0: an old
# server must not red a merge that already happened.
post_discharges() { # $1 primary id, $2 sha, $3 pr, $4 the commit message
  local id="$1" sha="$2" pr="$3" msg="$4"
  case "$msg" in
    *[Dd]ischarges:*) : ;;
    *) return 0 ;;
  esac

  local msgf dbody douf
  msgf="$(mktemp -t landed-mark-msg.XXXXXX)"
  dbody="$(mktemp -t landed-mark-dbody.XXXXXX)"
  douf="$(mktemp -t landed-mark-dout.XXXXXX)"
  printf '%s' "$msg" > "$msgf"
  # Built by python3 from a FILE, never by string-pasting the message into
  # JSON: a commit body carries quotes, backslashes and newlines, and a
  # hand-built payload would be a 400 on the bodies that need this most.
  python3 -c '
import json,sys
body = {"pr": str(sys.argv[2]), "commit": sys.argv[3], "body": open(sys.argv[1]).read()}
if not body["pr"]:
    body.pop("pr")
json.dump(body, open(sys.argv[4], "w"))' "$msgf" "$pr" "$sha" "$dbody"

  with_retry ledger_post_discharges "$id" "$dbody" "$douf"
  case "$RC_CODE" in
    401|403) rm -f "$msgf" "$dbody" "$douf"; die_auth "$RC_CODE" "POST /v1/tasks/${id}/discharges" ;;
    2??)
      local cited marked
      cited="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cited", 0))' "$douf" 2>/dev/null || echo 0)"
      marked="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("marked", 0))' "$douf" 2>/dev/null || echo 0)"
      note "${id}: ${sha:0:10} cites ${cited} sibling row(s); ${marked} back-link mark(s) written."
      DISCHARGES=$((DISCHARGES + 1)) ;;
    404)
      warn "the ledger has no /v1/tasks/${id}/discharges door (HTTP 404) — the sibling rows named by this body go unmarked. Skipped, not failed." ;;
    *)
      warn "recording the sibling back-links for ${id} returned HTTP ${RC_CODE} — skipped, not failed." ;;
  esac
  rm -f "$msgf" "$dbody" "$douf"
  return 0
}

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
      note "${id}: criterion ${idx} is merge-shaped — the /landed call below will ask the server to flip it."
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
        MARKED=$((MARKED + 1))
        post_landing "$id" "$planf" "$idx" "$unstampable" "$sha"
        rm -f "$rowf" "$planf" "$bodyf" "$outf"; return 0 ;;
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
    # AFTER the row's own marks, and never on a dry run. The sibling rows are
    # the enrichment: if this fails the credited row is still marked and still
    # findable, which is the same ordering argument /landed rides behind
    # /labels.
    [ "$DRY_RUN" = "1" ] || post_discharges "$id" "$sha" "$pr" "$msg"
  done <<<"$shas"

  if [ "$DRY_RUN" = "1" ]; then
    note "DRY RUN — scanned ${SCANNED} commit(s): ${PLANNED} would be marked, ${NOOP} already marked, ${SKIPPED} skipped. Nothing was written."
  else
    note "scanned ${SCANNED} commit(s): ${MARKED} marked, ${LANDINGS} landing(s) recorded, ${NOOP} already marked, ${SKIPPED} skipped, ${DISCHARGES} sibling citation(s) posted."
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
  mkdir -p "$1/rows"; : > "$1/writes.log"; : > "$1/landed.log"; : > "$1/discharges.log"
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
has "$OUT" "0 marked, 0 landing(s) recorded, 2 already marked" "the re-run tally is 0 marked"
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
has "$OUT" "criterion 1 deliberately NOT flipped" "a merge-shaped criterion is NOT flipped through /landed (task-48ff3f84e68aecbb)"
has "$OUT" "still needs a holder" "…and it is handed to the claim holder by ::notice instead"
has "$OUT" "marked task-ccc1" "the label mark lands alongside the landing sentence"
has "$OUT" "::notice" "the holder handover IS raised even on a 2xx — the sentence lands, the criterion is withheld"
# THE ARM THAT MATTERS: the criterion is still UNMET in the ledger after a
# landing that "looks like" it satisfies it. This is the fabricated-done that
# task-48ff3f84e68aecbb describes, asserted absent at the row rather than at
# the wire — if a future change re-adds the field, THIS reds even if the body
# check above is somehow satisfied.
check "the criterion is STILL UNMET on the row — no fabricated done (task-48ff3f84e68aecbb)" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["doc"]["content"]["acceptance_criteria"][1].get("met"))' "$L4/rows/task-ccc1.json")" "False"
# positive control: the row was really read back, so "False" is a value and not a failed read
check "positive control: the fixture row was read back and has its criteria" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["doc"]["content"]["acceptance_criteria"]))' "$L4/rows/task-ccc1.json")" "2"
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

# 6b. THE SECOND DOOR IS ACTUALLY CALLED, and it carries what /landed accepts.
#     Before this, scripts/landed-mark.sh POSTed only /labels and the verb built
#     for it in PR #15090 had no caller at all.
has "$(cat "$L4/landed.log")" '"commit"' "the /landed body carries the commit"
has "$(cat "$L4/landed.log")" '"pr": "21"' "the /landed body sends pr as a STRING — the int is a 422 on a payload that looks right"
has "$(cat "$L4/landed.log")" '"note"' "the /landed body carries the sentence — the thing a label cannot hold"
hasnt "$(cat "$L4/landed.log")" '"criterion"' "THE ARM: no landed POST body carries a criterion field, on ANY row (task-48ff3f84e68aecbb)"
check "positive control: the landed POST body was actually written and read" \
  "$(grep -c '"commit"' "$L4/landed.log")" "2"
hasnt "$(cat "$L4/landed.log")" '"lifecycle_status"' "the /landed body NEVER touches lifecycle_status"
hasnt "$(cat "$L4/landed.log")" '"labels"' "the /landed body NEVER touches labels — that is the other door's job"
check "the row with NO merge-shaped criterion still got a landing sentence" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["doc"]["content"]["landed"]["commits"]))' "$L4/rows/task-ccc2.json")" "1"
check "and NO criterion index was sent for it either — ZERO across BOTH rows" \
  "$(grep -c '"criterion"' "$L4/landed.log")" "0"

# 6c. IDEMPOTENT ACROSS BOTH DOORS. A re-run of the same sha writes NEITHER.
#     The old guard read the labels only, so a row already labelled would still
#     have fired a second task.landed event on every re-run.
BEFORE_L="$(wc -c < "$L4/landed.log")"
OUT="$(run "$R4" "$L4" --sha "$S4a")"
has "$OUT" "already marked with" "a re-run of the same sha is a noop"
check "the re-run wrote nothing to /landed either" "$(wc -c < "$L4/landed.log")" "$BEFORE_L"

# 6d. THE HALF-MARKED ROW. Labels present, content.landed empty — the exact
#     state every row marked before the /landed door existed is in. A re-run
#     must FINISH it, not read the labels and call it done.
python3 - "$L4/rows/task-ccc2.json" <<'PYX'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["doc"]["content"].pop("landed", None)
json.dump(d, open(p, "w"))
PYX
BEFORE_L="$(wc -c < "$L4/landed.log")"
OUT="$(run "$R4" "$L4" --sha "$S4b")"
hasnt "$OUT" "already marked with" "a row with the labels but no content.landed is NOT treated as marked"
if [ "$(wc -c < "$L4/landed.log")" -gt "$BEFORE_L" ]; then
  ok "a half-marked row gets its landing sentence backfilled"
else
  bad "a half-marked row got no /landed write — every pre-#15090 row stays half-marked forever"
fi

# 6e. THE SERVER REFUSES THE FLIP. The local mirror of merge_shaped?/1 cannot
#     see a future server rule, so a 409 must degrade to "sentence, no flip,
#     handover by notice" — never to a lost landing and never to a red.
R4b="$TMPROOT/r4b"; L4b="$TMPROOT/l4b"; mkrepo "$R4b"; mkledger "$L4b"
mkrow "$L4b" task-ccc3 in_progress builder-q "The PR merged to main and CI is green."
S4c="$(mkcommit "$R4b" "$(printf 'fix(c): refused (#23)\n\nTask: task-ccc3\n')")"
OUT="$(LANDED_MARK_FIXTURE_LANDED_CODE=409 run "$R4b" "$L4b" --sha "$S4c")"; RC=$?
check "a 409 from /landed still exits 0 — a merge is never undone by a refusal" "$RC" "0"
has "$OUT" "::notice" "a refused flip raises the holder handover"
has "$OUT" "needs the claim holder" "the handover says who can finish it"
has "$OUT" "marked task-ccc3" "the LABEL still landed, so the row is still findable by the reader"

# 6f. THE SIBLING CITATIONS (task-29781d0921e5a885). A body carrying
#     `Discharges:` lines POSTs the message to /discharges; a body without them
#     spends no request at all. The script parses NOTHING here — these arms are
#     about what is SENT, because what is parsed is the server's business.
R4c="$TMPROOT/r4c"; L4c="$TMPROOT/l4c"; mkrepo "$R4c"; mkledger "$L4c"
mkrow "$L4c" task-hhh1 in_progress builder-p ""
S4d="$(mkcommit "$R4c" "$(printf 'fix(h): two siblings (#71)\n\nDischarges: task-sib-one c2\nDischarges: `task-sib-two`\n\nTask: task-hhh1\n')")"
OUT="$(run "$R4c" "$L4c" --sha "$S4d")"; RC=$?
check "a body with Discharges: lines still exits 0" "$RC" "0"
has "$(cat "$L4c/discharges.log")" 'task-sib-one' "the /discharges body carries the FIRST cited row"
has "$(cat "$L4c/discharges.log")" 'task-sib-two' "the /discharges body carries the SECOND cited row — a PR citing two rows sends BOTH"
has "$(cat "$L4c/discharges.log")" '"pr": "71"' "the /discharges body sends pr as a STRING, like /landed"
has "$(cat "$L4c/discharges.log")" "$S4d" "the /discharges body carries the merge sha"
# THE ARM THAT MATTERS. This verb has no criterion field and no met field on the
# wire, so a back-link cannot become a fabricated done the way a /landed
# criterion flip could (task-48ff3f84e68aecbb). Asserted by BYTE.
hasnt "$(cat "$L4c/discharges.log")" '"criterion"' "no /discharges body carries a criterion field"
hasnt "$(cat "$L4c/discharges.log")" '"met"' "no /discharges body carries a met field"
hasnt "$(cat "$L4c/discharges.log")" '"lifecycle_status"' "the /discharges body NEVER touches lifecycle_status"
hasnt "$(cat "$L4c/discharges.log")" '"labels"' "the /discharges body NEVER touches labels"
check "positive control: exactly ONE /discharges body was written" \
  "$(grep -c '"commit"' "$L4c/discharges.log")" "1"
has "$OUT" "1 sibling citation(s) posted" "the tally counts the sibling POST"

# A body with NO citations spends no request — the common PR.
S4e="$(mkcommit "$R4c" "$(printf 'fix(h): no siblings (#72)\n\nTask: task-hhh1\n')")"
BEFORE_D="$(wc -c < "$L4c/discharges.log")"
OUT="$(run "$R4c" "$L4c" --sha "$S4e")"
check "a body with no Discharges: line writes NOTHING to /discharges" \
  "$(wc -c < "$L4c/discharges.log")" "$BEFORE_D"
has "$OUT" "0 sibling citation(s) posted" "…and the tally says so"

# A DRY RUN never posts a citation either.
R4d="$TMPROOT/r4d"; L4d="$TMPROOT/l4d"; mkrepo "$R4d"; mkledger "$L4d"
mkrow "$L4d" task-hhh2 open builder-p ""
S4f="$(mkcommit "$R4d" "$(printf 'fix(h): dry (#73)\n\nDischarges: task-sib-three c0\n\nTask: task-hhh2\n')")"
OUT="$(run "$R4d" "$L4d" --sha "$S4f" --dry-run)"
check "a --dry-run posts no sibling citation" "$(wc -c < "$L4d/discharges.log" | tr -d ' ')" "0"

# AN OLD SERVER (404 on the door) IS NOT A RED. The merge already happened.
R4e="$TMPROOT/r4e"; L4e="$TMPROOT/l4e"; mkrepo "$R4e"; mkledger "$L4e"
mkrow "$L4e" task-hhh3 open builder-p ""
S4g="$(mkcommit "$R4e" "$(printf 'fix(h): old server (#74)\n\nDischarges: task-sib-four\n\nTask: task-hhh3\n')")"
OUT="$(LANDED_MARK_FIXTURE_DISCHARGES_CODE=404 run "$R4e" "$L4e" --sha "$S4g")"; RC=$?
check "a 404 from /discharges exits 0" "$RC" "0"
has "$OUT" "no /v1/tasks/task-hhh3/discharges door" "a ledger without the door says so, as a warning"
has "$OUT" "marked task-hhh3" "the credited row is still marked when the sibling door is missing"

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
