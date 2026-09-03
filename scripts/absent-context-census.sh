#!/usr/bin/env bash
# absent-context-census.sh — dates the ABSENCE of a required context, and
# enumerates the queue that produces it. A census, never a merge gate.
#
# THE DEFECT IT EXISTS FOR, measured 2026-08-07 on FRIKKern/barkpark.
# PR #9887 sat unmergeable for more than twelve hours with ZERO red checks. Its
# head aa19dcca3 rendered 27 check runs, every one `success` or `skipped`, and
# the committed required set has four members — one of which, `Console gate`,
# was not among the 27 at all. The producing run (console-harness.yml, id
# 31120806862) was `status: queued`, `run_attempt: 1`, `jobs.total_count: 0`:
# created and never dispatched. Meanwhile a pr-task-gate run had been queued
# since 2026-07-23 at attempt 9 — FIFTEEN DAYS — on a branch that will never
# push again. Nothing in this repository reported any of it.
#
# WHAT THIS IS NOT, so nobody re-implements a neighbour.
# scripts/required-checks-verify.sh already owns the merge-path verdict, and its
# deadlock_check() ALREADY exits 3 printing `missing: Console gate` when pointed
# at that head. This script does not replace it, wrap it, or edit it. Two things
# genuinely did not exist anywhere in the tree, and they are all this adds:
#   1. an absence that carries a DATE and a CLASS, so "how long" and "why" are
#      answerable without a human reading the Actions tab. The classes, and the
#      DIFFERENT remedy each one implies.
#
#      SCREAMING — a standing absence with a remedy, reaches the exit code:
#        ZOMBIED         not completed, jobs.total_count 0, and OLDER than
#                        --stale-queue-hours. GitHub created the run and never
#                        dispatched it. Re-dispatch. The age bound is
#                        load-bearing: without it a sixty-second-old run scored
#                        identically to the fifteen-day specimen this class was
#                        written for, which is precisely what happened.
#        RERUN_DELETED   attempt >= 2, run COMPLETED, no rendered check run.
#                        Re-run. Completion is required — an unfinished re-run
#                        is in flight, not deleted.
#        NAME_NOT_IN_RUN the producing run COMPLETED on its first attempt and
#                        rendered no check run under this name — a head
#                        predating the context, a renamed job, a pruned
#                        aggregator. Rebase, or edit the spec. Never
#                        re-dispatch; there is nothing to dispatch.
#        NO_RUN          no run of the producing workflow on this head at all,
#                        and the pull request is not conflicted.
#        UNCLASSIFIED(…) the census does not know, and says so rather than
#                        picking the nearest label. Fails closed at any age.
#
#      IN FLIGHT — self-resolving, printed and counted, NO exit code:
#        DISPATCHED_PENDING  the producing run is still working and has
#                            dispatched jobs; this job is behind an unmet
#                            `needs:` and does not exist yet.
#        UNDISPATCHED_YOUNG  jobs.total_count 0 but YOUNGER than the threshold —
#                            a run GitHub has not populated yet, not a zombie.
#        PR_CONFLICTED       no run because the merge commit cannot be computed
#                            — a merge conflict, not a missing context.
#   2. a repo-wide queued-run enumeration that is PAGINATED and
#      SERVER-FILTERED, so it can report a queue older than the last page.
#
# THE PENDING CASE IS OUT OF SCOPE — AND THERE ARE THREE OF THEM, NOT TWO.
#
# This header used to say the pending population and the absent population were
# "disjoint by construction". They are not, and the claim cost seventeen days.
# There are THREE populations, and the original reasoning only ever saw two:
#
#   1. RENDERED AND CONCLUDED — the ordinary case.
#   2. RENDERED, NOT CONCLUDED — a check run exists with status queued or
#      in_progress. Live, self-resolving, somebody else's subject. This is the
#      only pending case the first version considered, and it is correctly
#      excluded by testing for the NAME rather than for its status.
#   3. NOT RENDERED BECAUSE THE JOB DOES NOT EXIST YET. GitHub creates a job —
#      and its check run — only once every one of its `needs:` has concluded.
#      Until then the job is absent from `runs/<id>/jobs` entirely, so there is
#      no check run of ANY status to find, and a name-presence test reads it as
#      an absence. Every gate in this repository is a terminal aggregator behind
#      a full `needs:` list, so population 3 is non-empty on every pull request
#      for the whole first phase of its CI.
#
# Population 3 is indistinguishable from a genuinely missing context by the
# check-run feed alone. It is separated HERE by asking the producing run whether
# it is still working: status queued/waiting/pending/requested/in_progress with
# jobs.total_count > 0 means the job is coming. That verdict is reported in the
# in-flight column and carries no exit code.
#
# MEASURED, one run id, twenty minutes apart (run 32766664303, cloud.yml, PR
# #14040, 2026-08-24): at 19:11Z jobs.total_count was 2 and `Cloud gate` was not
# in the job list; at 19:31Z it was 5 and `Cloud gate` was present, queued. No
# intervention — only time. The census called that an ABSENCE 71 times.
#
# THE HARNESS PINS ALL THREE. §3 carries a fixture for population 2 (a rendered
# unconcluded check run reports nothing) and for population 3 (a producing run
# still working, with the gate job not in its job list, reports nothing) — and
# each is paired with the mutation that flips it to a SCREAM, so neither probe
# is a green that can only pass.
#
# THE CONFLICTED HEAD. A pull request GitHub cannot compute a merge commit for
# runs no `pull_request` workflow at all, so all four required contexts go
# missing together. That is a merge conflict — already reported by GitHub's own
# UI and by `mergeable` — and this census exists for things NOTHING ELSE
# reports. It is classified PR_CONFLICTED and carried in the in-flight column.
#
# THE TWO LIMBS ARE REPORTED APART. The absence limb and the repo-wide queue
# limb each state a verdict on their own line, whether or not the other fired,
# because fusing them is how a true positive stayed invisible for seventeen days.
#
# THE QUEUE QUERY IS BUILT TO LOSE.
# The comfortable form — `gh api repos/:o/:r/actions/runs --jq
# 'select(.status=="queued")'` — filters the DEFAULT PAGE, i.e. the 30 newest
# runs, on the client. Anything older has already fallen off the page, so the
# fifteen-day zombie is invisible to it and it answers a small, calm number.
# Four samples taken in one night gave 0-vs-6, 0-vs-6, 1-vs-7 and 0-vs-7 against
# the paginated truth. This script therefore runs BOTH and prints both: the
# server-filtered `?status=queued&per_page=100 --paginate` form is the answer,
# and the client-side form is reported beside it as the loser. A run where the
# two agree is not proof of health — it is a day when nothing old was queued.
#
# EXIT CODES
#   0  every required context is either rendered on every head examined, or its
#      producing run is still working on it, and no queued run is older than the
#      staleness threshold. In-flight rows may be non-zero at exit 0 — that is
#      the point of the column.
#   1  SCREAM — at least one required context is ABSENT from a head, and/or a
#      queued run has been sitting past the threshold
#   2  UNKNOWN — a feed could not be read, or a required context could not be
#      mapped to a producing workflow. Never green: a census that cannot see is
#      not a census that found nothing.
#   3  CONFIGURATION FAULT — the credential cannot read the endpoints at all
#
# USAGE
#   scripts/absent-context-census.sh                       # every open PR head
#   scripts/absent-context-census.sh --sha <sha>           # one head
#   scripts/absent-context-census.sh --fixtures <dir> --now <iso>   # hermetic
#
# HERMETIC MODE reads these files from --fixtures and touches no network:
#   prs.json              gh pr list --json number,headRefOid,updatedAt
#   checkruns-<sha>.json  repos/:o/:r/commits/<sha>/check-runs
#   runs-<sha>.json       repos/:o/:r/actions/runs?head_sha=<sha>
#   jobs-<run id>.json    repos/:o/:r/actions/runs/<id>/jobs
#   queued-paginated.json    the server-filtered, paginated truth
#   queued-unpaginated.json  the default-page answer, kept so the gap is visible

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SPEC="$REPO_ROOT/.github/required-checks.json"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
FIXTURES=""
REPO_OVERRIDE=""
NOW_ISO=""
STALE_QUEUE_HOURS=24
# A queued run on the current head of an open PR is only actionable if someone
# is plausibly coming back to that PR. Older than this with no PR activity, the
# re-run remedy exists in principle and will never be applied in practice
# (#11766: owner-held since Aug 17, 300+ commits behind main). Dispatched runs
# are unaffected — cancel works regardless of whether anyone returns.
DORMANT_PR_DAYS=14
# THE PHANTOM SLICE. A queued run this old is not queue DEPTH: GitHub will not
# dequeue it and will not let anyone cancel it. Measured 2026-09-03 08:03Z
# (task-82059e31bcccdbd7): `gh api actions/runs?status=queued` answered 8 for a
# whole night — seven created 2026-08-07T09:08:43Z (breakglass-watch, cloud,
# console-harness, doc-gates, elixir, release-artifact, required-checks-drift)
# and one 2026-08-19T05:23:37Z (compose-smoke), all push/main, all answering 409
# "Cannot cancel a workflow run that has not been queued yet" to BOTH cancel
# paths. Any queue-depth reading taken since carries a CONSTANT +8, and the
# ratio it corrupts depends on the hour: this same report, run from a worktree
# at 2026-09-03T16:11Z, read 31 queued rows of which 8 were phantoms (26%),
# while `gh run list --status queued` at 08:03Z that morning returned 8 rows of
# which all 8 were. This is a SLICE OF THE ROWS
# BELOW, never a new class: each row is still classified STALE / DISPATCHED /
# ORPHANED by the remedy that exists for it, and no verdict moves because of
# this number. The slice exists so that a DEPTH is quotable at all.
PHANTOM_QUEUE_HOURS=24
SHAS=()

# Report accumulators. ABSENT_ROWS and STALE_ROWS are the two SCREAMING limbs and
# are counted apart on purpose — see THE TWO LIMBS ARE REPORTED APART in the
# header. PENDING_ROWS is informational and never reaches an exit code.
ABSENT_ROWS=0
STALE_ROWS=0
UNKNOWN_ROWS=0
PENDING_ROWS=0
# ORPHANED runs are stale-queued rows that are UNDISPATCHABLE and unattached:
# jobs.total_count 0, and a head that is no longer the current head of any open
# PR or of main. GitHub has no state transition for them — `gh run cancel` says
# "completed", the REST cancel says "has NOT BEEN QUEUED YET" while status reads
# queued (measured on all 8 specimens, 2026-09-01) — so a verdict that screams
# about them screams about something nobody can act on, forever. That is how
# this census spent 93 runs red without one green: a watch that is red every
# time it runs is indistinguishable from a watch that is broken, which is this
# file's own founding principle. Orphans are counted and PRINTED, never exited
# on. The run records stay: deleting them to green a gate would be destroying
# the only evidence the class exists.
ORPHAN_ROWS=0
# Rows in the PHANTOM SLICE above. Reported, never exited on: it is a property
# of the DEPTH NUMBER, not a finding.
PHANTOM_ROWS=0

# Informational rows are buffered, not printed inline, so the queue limb's
# verdict is never pushed off the top of a log by in-flight noise.
PENDING_REPORT=""

say()  { echo "$*"; }
warn() { echo "$*" >&2; }

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --spec)              SPEC="$2"; shift 2 ;;
    --workflows)         WORKFLOWS_DIR="$2"; shift 2 ;;
    --fixtures)          FIXTURES="$2"; shift 2 ;;
    --repo)              REPO_OVERRIDE="$2"; shift 2 ;;
    --now)               NOW_ISO="$2"; shift 2 ;;
    --stale-queue-hours) STALE_QUEUE_HOURS="$2"; shift 2 ;;
    --phantom-queue-hours) PHANTOM_QUEUE_HOURS="$2"; shift 2 ;;
    --dormant-pr-days) DORMANT_PR_DAYS="$2"; shift 2 ;;
    --sha)               SHAS+=("$2"); shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { warn "jq is required"; exit 2; }

[ -f "$SPEC" ] || { warn "cannot read the committed spec at $SPEC — refusing to report an empty required set as 'nothing absent'"; exit 2; }
[ -d "$WORKFLOWS_DIR" ] || { warn "cannot read $WORKFLOWS_DIR — a context cannot be mapped to a producing workflow"; exit 2; }

REPO="${REPO_OVERRIDE:-$(jq -r '.repo // empty' "$SPEC")}"
[ -n "$REPO" ] || { warn "no repo: pass --repo, or commit one in $SPEC"; exit 2; }

# ── time ─────────────────────────────────────────────────────────────────────
# Portable across GNU date (CI) and BSD date (stock macOS). A parse failure is
# reported as UNKNOWN rather than silently becoming epoch 0, which would date
# every absence to 1970 and make the age column meaningless.
iso_to_epoch() { # <iso8601-Z>
  local iso="$1" e
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { echo "$e"; return 0; }
  e="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)" && { echo "$e"; return 0; }
  return 1
}

if [ -n "$NOW_ISO" ]; then
  NOW_EPOCH="$(iso_to_epoch "$NOW_ISO")" || { warn "--now is not an ISO-8601 Z timestamp: $NOW_ISO"; exit 2; }
else
  NOW_EPOCH="$(date -u +%s)"
fi

age_hours() { # <iso8601-Z> -> hours to 1dp, or the literal "?"
  local then h
  then="$(iso_to_epoch "$1")" || { echo "?"; return 0; }
  h=$(( NOW_EPOCH - then ))
  [ "$h" -lt 0 ] && h=0
  awk -v s="$h" 'BEGIN { printf "%.1f", s / 3600 }'
}

# True when <iso> is strictly older than <hours>.
#
# COMPARES SECONDS, NEVER age_hours' STRING. age_hours formats to one decimal
# for the report, and reusing that here silently floors every age under six
# minutes to "0.0" — so a threshold of 0 could never be exceeded and a newborn
# run stayed calm no matter how the bar was set. Caught by §1.7, which is
# exactly the probe that lowers the threshold to 0 to prove the guard is the
# threshold and not the date literal.
#
# AN UNREADABLE TIMESTAMP IS TRUE, not false: the one caller is the ZOMBIED age
# guard, and a date nobody could parse must not quietly demote a real zombie
# into the calm column. A newborn run always has a parseable created_at.
age_exceeds() { # <iso8601-Z> <hours> -> 0 when older
  local then secs
  then="$(iso_to_epoch "$1")" || return 0
  secs=$(( NOW_EPOCH - then ))
  [ "$secs" -lt 0 ] && secs=0
  awk -v s="$secs" -v t="$2" 'BEGIN { exit !(s > t * 3600) }'
}

# ── the fetch layer ──────────────────────────────────────────────────────────
# Every reader emits NDJSON of the objects the census cares about, so a fixture
# is a REAL captured API payload and not a bespoke shape the live path never
# sees. A live read that fails is distinguished from one that returns nothing:
# CONFIG_FAULT is set on a credential refusal and the whole run exits 3.
CONFIG_FAULT=0

is_config_fault() { # <body>
  # Rate limiting also answers 403 and DOES clear on its own; it is not a
  # credential fault and must not be reported as one.
  grep -qiE 'rate limit|abuse detection' <<<"$1" && return 1
  grep -qE 'HTTP 401|HTTP 403|Bad credentials|Resource not accessible by integration|Requires authentication|requires authentication' <<<"$1"
}

gh_api() { # <url> [jq-filter]
  local url="$1" filter="${2:-.}" out rc
  out="$(gh api "$url" --paginate --jq "$filter" 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    is_config_fault "$out" && CONFIG_FAULT=1
    warn "  read failed: $url"
    warn "$(printf '%s\n' "$out" | sed 's/^/    /' | head -5)"
    return 1
  fi
  printf '%s\n' "$out"
}

fixture() { # <name> — path, or empty if absent
  [ -n "$FIXTURES" ] || return 1
  [ -f "$FIXTURES/$1" ] || return 1
  echo "$FIXTURES/$1"
}

# Open PR heads: NDJSON of {number, sha, updated_at, mergeable}.
#
# `mergeable` is read because a CONFLICTING pull request runs no `pull_request`
# workflow at all — GitHub cannot compute the merge commit — and so shows every
# required context missing at once. A fixture captured before this field existed
# yields "UNKNOWN", which classifies as NO_RUN exactly as it did before: the
# absence of the field can only make the census LOUDER, never quieter.
read_open_prs() {
  local f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture prs.json)" || { warn "fixtures mode: missing prs.json"; return 1; }
    jq -c '.[] | {number, sha: .headRefOid, updated_at: .updatedAt, mergeable: (.mergeable // "UNKNOWN")}' "$f"
  else
    gh pr list --repo "$REPO" --state open --limit 100 \
      --json number,headRefOid,updatedAt,mergeable 2>/dev/null \
      | jq -c '.[] | {number, sha: .headRefOid, updated_at: .updatedAt, mergeable: (.mergeable // "UNKNOWN")}'
  fi
}

# Rendered check runs on a head: NDJSON of {name, status, conclusion}.
read_check_runs() { # <sha>
  local sha="$1" f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture "checkruns-$sha.json")" || { warn "fixtures mode: missing checkruns-$sha.json"; return 1; }
    jq -c '.check_runs[] | {name, status, conclusion}' "$f"
  else
    gh_api "repos/$REPO/commits/$sha/check-runs?per_page=100" \
      '.check_runs[] | {name, status, conclusion}'
  fi
}

# Workflow runs on a head: NDJSON of {id, path, status, run_attempt, created_at}.
read_head_runs() { # <sha>
  local sha="$1" f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture "runs-$sha.json")" || { warn "fixtures mode: missing runs-$sha.json"; return 1; }
    jq -c '.workflow_runs[] | {id, path, status, run_attempt, created_at}' "$f"
  else
    gh_api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
      '.workflow_runs[] | {id, path, status, run_attempt, created_at}'
  fi
}

# The current head of main, or empty when it cannot be read. Liveness of a
# queued run's head is judged against open-PR heads PLUS this; an unreadable
# answer disables the orphan downgrade entirely (fail closed — a run nobody can
# prove dead keeps screaming).
read_main_head() {
  local f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture main-head.json)" || return 1
    jq -r '.sha // empty' "$f"
  else
    gh api "repos/$REPO/commits/main" --jq '.sha' 2>/dev/null
  fi
}

# jobs.total_count for a run, or -1 when it cannot be read. -1 is a real value
# here: it downgrades the class to UNCLASSIFIED instead of asserting ZOMBIED off
# a number nobody managed to fetch.
read_jobs_count() { # <run id>
  local id="$1" f out
  if [ -n "$FIXTURES" ]; then
    f="$(fixture "jobs-$id.json")" || { echo "-1"; return 0; }
    jq -r '.total_count // -1' "$f"
  else
    out="$(gh api "repos/$REPO/actions/runs/$id/jobs" --jq '.total_count' 2>&1)" || out=""
    # A NON-NUMERIC answer is unreadable, not zero and not "some". `--jq
    # .total_count` on a payload without the key prints `null`, and letting
    # `null` fall through would classify a run whose job count nobody read as
    # DISPATCHED_PENDING — the calm end of the scale, off a value that does not
    # exist. -1 sends it to UNCLASSIFIED(jobs-unreadable) instead.
    case "$out" in
      ''|*[!0-9]*) echo "-1" ;;
      *) printf '%s\n' "$out" ;;
    esac
  fi
}

# THE PAGINATED, SERVER-FILTERED TRUTH.
read_queued_paginated() {
  local f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture queued-paginated.json)" || { warn "fixtures mode: missing queued-paginated.json"; return 1; }
    jq -c '.workflow_runs[] | {id, path, status, run_attempt, created_at, updated_at, head_sha}' "$f"
  else
    gh_api "repos/$REPO/actions/runs?status=queued&per_page=100" \
      '.workflow_runs[] | {id, path, status, run_attempt, created_at, updated_at, head_sha}'
  fi
}

# THE COMFORTABLE FORM, kept so the gap between them is reportable. It filters
# the default page client-side and structurally cannot see past it.
read_queued_default_page() {
  local f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture queued-unpaginated.json)" || { warn "fixtures mode: missing queued-unpaginated.json"; return 1; }
    jq -c '.workflow_runs[] | select(.status == "queued") | {id, path, created_at}' "$f"
  else
    gh api "repos/$REPO/actions/runs" \
      --jq '.workflow_runs[] | select(.status == "queued") | {id, path, created_at}' 2>/dev/null
  fi
}

# ── context → producing workflow ─────────────────────────────────────────────
# A required context is a JOB NAME. The mapping is read out of the workflow
# tree rather than hard-coded, so a job that moves file takes its mapping with
# it. Zero matches or more than one are both UNKNOWN — a guess here would put a
# confident CLASS on the wrong run.
producing_workflow() { # <context> -> repo-relative workflow path, or empty
  local ctx="$1" hits
  hits="$(grep -rlE "^[[:space:]]+name:[[:space:]]+['\"]?$(sed 's/[][\.*^$/]/\\&/g' <<<"$ctx")['\"]?[[:space:]]*$" \
            "$WORKFLOWS_DIR" 2>/dev/null | sort)"
  [ "$(grep -c . <<<"$hits")" = "1" ] || return 1
  echo ".github/workflows/$(basename "$hits")"
}

# ── the census, one head at a time ───────────────────────────────────────────
census_head() { # <sha> <label> <pr-updated-at> <mergeable>
  local sha="$1" label="$2" mergeable="${4:-UNKNOWN}"
  local checks runs names oldest_queued anchor anchor_label

  if ! checks="$(read_check_runs "$sha")"; then
    warn "UNKNOWN  $label $sha — the check-run feed could not be read; this head is NOT certified clean"
    UNKNOWN_ROWS=$((UNKNOWN_ROWS + 1))
    return 0
  fi
  if ! runs="$(read_head_runs "$sha")"; then
    warn "UNKNOWN  $label $sha — the workflow-run feed could not be read; this head is NOT certified clean"
    UNKNOWN_ROWS=$((UNKNOWN_ROWS + 1))
    return 0
  fi

  # EVERY rendered name counts as present, whatever its status. A rendered but
  # unconcluded check run is a live state with an owner elsewhere; this
  # instrument's population is names that render nowhere.
  names="$(printf '%s\n' "$checks" | jq -r 'select(. != null) | .name' 2>/dev/null)"

  # The age anchor, in falling order of directness: the oldest queued run on
  # this head, else the oldest run of any status, else the PR's own timestamp.
  oldest_queued="$(printf '%s\n' "$runs" | jq -r 'select(. != null) | select(.status == "queued") | .created_at' 2>/dev/null | sort | head -1)"
  if [ -n "$oldest_queued" ]; then
    anchor="$oldest_queued"; anchor_label="oldest-queued-run"
  else
    anchor="$(printf '%s\n' "$runs" | jq -r 'select(. != null) | .created_at' 2>/dev/null | sort | head -1)"
    anchor_label="oldest-run"
    if [ -z "$anchor" ]; then
      anchor="$3"; anchor_label="pr-updated-at"
    fi
  fi

  local ctx wf wfruns newest attempt status jobs class rid
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    # Here-string, not a pipe: under pipefail a matching `grep -q` exits at once
    # and the upstream takes SIGPIPE, so a PRESENT context would intermittently
    # read as absent and this census would cry wolf at a healthy head.
    grep -qxF "$ctx" <<<"$names" && continue

    if ! wf="$(producing_workflow "$ctx")"; then
      warn "UNKNOWN  $label $sha — required context \"$ctx\" is ABSENT and maps to no single workflow job name under $WORKFLOWS_DIR; it cannot be classified"
      UNKNOWN_ROWS=$((UNKNOWN_ROWS + 1))
      continue
    fi

    wfruns="$(printf '%s\n' "$runs" | jq -c --arg p "$wf" 'select(. != null) | select(.path == $p)' 2>/dev/null)"
    # NEWEST attempt wins: a re-run creates a fresh row for the same workflow,
    # and classifying off the first one would date the absence to a run GitHub
    # has already superseded.
    newest="$(printf '%s\n' "$wfruns" | grep . | jq -sc 'sort_by(.created_at, .id) | last // empty' 2>/dev/null)"

    if [ -z "$newest" ] || [ "$newest" = "null" ]; then
      # A pull request whose merge commit GitHub cannot compute runs NO
      # `pull_request` workflow at all, so every required context is missing from
      # it at once. That is a merge conflict — reported by GitHub's own UI on the
      # pull request, and by `mergeable` on the API — wearing an absent-context
      # label. It is not this instrument's subject; see THE CONFLICTED HEAD.
      if [ "$mergeable" = "CONFLICTING" ]; then
        class="PR_CONFLICTED"; rid="-"
      else
        class="NO_RUN"; rid="-"
      fi
    else
      rid="$(jq -r '.id' <<<"$newest")"
      attempt="$(jq -r '.run_attempt // 1' <<<"$newest")"
      status="$(jq -r '.status // ""' <<<"$newest")"
      # STATUS IS READ BEFORE ATTEMPT, and that order is itself a fix. A re-run
      # that has not finished is in flight exactly like a first attempt that has
      # not finished; branching on `run_attempt` first labelled it RERUN_DELETED
      # while its jobs were still being created. RERUN_DELETED means a re-run
      # that COMPLETED and rendered nothing, so it now lives in the `completed`
      # arm, which is the only place that is knowable.
      case "$status" in
        queued|waiting|pending|requested|in_progress)
          # THE POPULATION THIS ARM EXISTS FOR — and the reason this census was
          # red on all 71 runs it had between 2026-08-07 and 2026-08-24,
          # without ever once being green. GitHub does not CREATE a
          # `needs:`-gated job,
          # and renders no check run for it, until every one of its `needs:`
          # has concluded. All three gates here are terminal aggregators
          # (`Cloud gate` needs [changes, compile, test, path-escape]; Console
          # and Elixir the same shape), so for the whole first phase of every
          # pull request's CI those names render NOWHERE while their producing
          # run is perfectly healthy.
          #
          # Measured on run 32766664303 (cloud.yml, PR #14040) 2026-08-24:
          #   19:11Z  jobs.total_count=2  `Cloud gate` NOT in the job list
          #   19:31Z  jobs.total_count=5  `Cloud gate` present, queued/null
          # Same run id, twenty minutes, no intervention. Counting that as an
          # ABSENCE is counting the passage of time.
          #
          # `in_progress` is named in this arm deliberately. It used to fall
          # through to UNCLASSIFIED(status=in_progress) — the census saying it
          # did not know, about a state it knows exactly.
          jobs="$(read_jobs_count "$rid")"
          if [ "$jobs" = "-1" ]; then
            # Fail closed, at ANY age. A job count nobody managed to read is
            # not evidence of health, and this is the one arm here that still
            # screams.
            class="UNCLASSIFIED(jobs-unreadable)"
          elif [ "$jobs" = "0" ]; then
            # Nothing dispatched. AGE is the entire discriminator, and dropping
            # it is what let a sixty-second-old run score identically to the
            # fifteen-day specimen this class was written for.
            if age_exceeds "$(jq -r '.created_at // empty' <<<"$newest")" "$STALE_QUEUE_HOURS"; then
              class="ZOMBIED"
            else
              class="UNDISPATCHED_YOUNG"
            fi
          else
            class="DISPATCHED_PENDING"
          fi
          ;;
        # The producing run RAN TO COMPLETION on this head and still rendered
        # no check run under this name. Review fix: this used to read
        # UNCLASSIFIED(status=completed), which is the class the census emits
        # when it does not know — and it does know. It is the dominant live
        # class (3 of the 10 rows the first real run found), so leaving it
        # unnamed made the census's own headline illegible, which is the
        # disease and not the cure. It means the job did not exist under this
        # name in that run: a head that predates a required context, a renamed
        # job, or an aggregator pruned out of the graph. Every one of those is
        # a real deadlock whose remedy is a rebase or a spec edit, never a
        # re-dispatch — which is exactly why it must not wear ZOMBIED's name.
        completed)
          # A re-run that finished and still rendered nothing is a DELETED
          # check run; a first attempt that did the same never had one. The
          # remedies differ, so the names must.
          if [ "$attempt" -ge 2 ] 2>/dev/null; then
            class="RERUN_DELETED"
          else
            class="NAME_NOT_IN_RUN"
          fi
          ;;
        *) class="UNCLASSIFIED(status=$status)" ;;
      esac
    fi

    # ── the split ────────────────────────────────────────────────────────────
    # A class is either SELF-RESOLVING — the producing run is still working and
    # the job simply does not exist yet — or it is a standing absence with a
    # remedy. Only the second kind reaches an exit code. The first is printed,
    # counted and visible, but it is weather, and a watch that screams at weather
    # is a watch nobody reads. This is the whole of the over-report fix: nothing
    # here is suppressed, it is REROUTED to a column that carries no verdict.
    case "$class" in
      DISPATCHED_PENDING|UNDISPATCHED_YOUNG|PR_CONFLICTED)
        PENDING_REPORT="$PENDING_REPORT
  pending  $label  head $sha
           context \"$ctx\" has not been created yet on this head
           class   $class
           run     $rid  producer $wf"
        PENDING_ROWS=$((PENDING_ROWS + 1))
        ;;
      *)
        say "ABSENT   $label  head $sha"
        say "         context \"$ctx\" renders nowhere on this head"
        say "         class   $class"
        say "         age     $(age_hours "$anchor")h  (anchor: $anchor_label $anchor)"
        say "         run     $rid  producer $wf"
        ABSENT_ROWS=$((ABSENT_ROWS + 1))
        ;;
    esac
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF
}

# ── run ──────────────────────────────────────────────────────────────────────
say "absent-context-census — repo $REPO  spec $(basename "$SPEC")"
say ""

REQ_COUNT="$(jq -r '[.protection.required_status_checks.checks[].context] | length' "$SPEC" 2>/dev/null || echo 0)"
if [ "$REQ_COUNT" -lt 1 ] 2>/dev/null; then
  warn "the committed spec lists ZERO required contexts — there is nothing this census could ever find absent, which is a broken input, not a clean bill of health"
  exit 2
fi
say "required contexts: $REQ_COUNT"

# Live heads, for the queue limb's orphan discriminator. Knowable only when the
# open-PR list was actually walked AND main's head was readable; under --sha the
# PR list is never read, so liveness stays UNKNOWN and every stale row keeps the
# screaming path it has today (fail closed, never downgrade on missing data).
LIVE_HEADS=""
# Heads of open PRs with NO activity in DORMANT_PR_DAYS. Still live — the
# absence limb still walks them — but for the queue limb their re-run remedy is
# notional. An unreadable updated_at keeps the head ACTIVE (fail closed: a PR
# nobody can prove dormant keeps its scream).
DORMANT_HEADS=""
LIVE_OK=0

HEADS_SEEN=0
if [ "${#SHAS[@]}" -gt 0 ]; then
  for s in "${SHAS[@]}"; do
    HEADS_SEEN=$((HEADS_SEEN + 1))
    census_head "$s" "sha" ""
  done
else
  if ! PRS="$(read_open_prs)"; then
    warn "the open-PR list could not be read — no head was examined"
    [ "$CONFIG_FAULT" = "1" ] && exit 3
    exit 2
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    HEADS_SEEN=$((HEADS_SEEN + 1))
    pr_upd="$(jq -r '.updated_at // empty' <<<"$row")"
    pr_upd_hrs="$(age_hours "$pr_upd")"
    if [ "$pr_upd_hrs" != "?" ] \
       && awk -v a="$pr_upd_hrs" -v d="$DORMANT_PR_DAYS" 'BEGIN { exit !(a > d * 24) }'; then
      DORMANT_HEADS="$DORMANT_HEADS $(jq -r '.sha' <<<"$row")"
    else
      LIVE_HEADS="$LIVE_HEADS $(jq -r '.sha' <<<"$row")"
    fi
    census_head \
      "$(jq -r '.sha' <<<"$row")" \
      "PR #$(jq -r '.number' <<<"$row")" \
      "$(jq -r '.updated_at' <<<"$row")" \
      "$(jq -r '.mergeable // "UNKNOWN"' <<<"$row")"
  done <<<"$PRS"
  MAIN_HEAD="$(read_main_head)" || MAIN_HEAD=""
  if [ -n "$MAIN_HEAD" ]; then
    LIVE_HEADS="$LIVE_HEADS $MAIN_HEAD"
    LIVE_OK=1
  fi
fi
say "heads examined: $HEADS_SEEN"
say ""

# ── the queue census ─────────────────────────────────────────────────────────
say "queued runs, repo-wide"
QP_OK=1; QD_OK=1
QUEUED_PAGINATED="$(read_queued_paginated)" || QP_OK=0
QUEUED_DEFAULT="$(read_queued_default_page)" || QD_OK=0

if [ "$QP_OK" = "0" ]; then
  warn "  the paginated queued-run feed could not be read — the queue is UNKNOWN, not empty"
  UNKNOWN_ROWS=$((UNKNOWN_ROWS + 1))
else
  QP_N="$(printf '%s\n' "$QUEUED_PAGINATED" | grep -c . || true)"
  if [ "$QD_OK" = "1" ]; then
    QD_N="$(printf '%s\n' "$QUEUED_DEFAULT" | grep -c . || true)"
  else
    QD_N="?"
  fi
  # THE SLICE. Counted here, before any row is classified, because the DEPTH is
  # the number other measurements copy out of this report.
  #
  # AN UNREADABLE created_at IS NOT A PHANTOM, and the direction is deliberate:
  # `age_exceeds` answers TRUE on a date it cannot parse (correct for its one
  # other caller, the ZOMBIED guard, where an unparseable date must not demote a
  # real zombie). Here TRUE would REMOVE the row from the depth and make the
  # number quieter, so the parse is required first and an unreadable row stays
  # counted as depth. Probe 5d.4 fails if that ever flips.
  while IFS= read -r prow; do
    [ -n "$prow" ] || continue
    pcreated="$(jq -r '.created_at // empty' <<<"$prow")"
    [ -n "$pcreated" ] || continue
    iso_to_epoch "$pcreated" >/dev/null 2>&1 || continue
    age_exceeds "$pcreated" "$PHANTOM_QUEUE_HOURS" && PHANTOM_ROWS=$((PHANTOM_ROWS + 1))
  done <<<"$QUEUED_PAGINATED"
  QP_DEPTH=$(( QP_N - PHANTOM_ROWS ))
  say "  paginated + server-filtered (?status=queued&per_page=100 --paginate): $QP_N"
  say "  default page, filtered client-side (the form that loses):             $QD_N"
  say "  of which PHANTOM (queued, created > ${PHANTOM_QUEUE_HOURS}h ago):     $PHANTOM_ROWS"
  say "  queue DEPTH, phantoms excluded — the only depth to quote:             $QP_DEPTH"
  if [ "$QD_N" != "?" ] && [ "$QP_N" -gt "$QD_N" ]; then
    say "  the default-page form is UNDERCOUNTING by $((QP_N - QD_N)) run(s) right now — every one of them older than its last page"
  fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    created="$(jq -r '.created_at' <<<"$row")"
    hrs="$(age_hours "$created")"
    qhead="$(jq -r '.head_sha // "-"' <<<"$row")"
    qid="$(jq -r '.id' <<<"$row")"
    line="  queued $(jq -r '.path' <<<"$row")  run $qid  attempt $(jq -r '.run_attempt // 1' <<<"$row")  age ${hrs}h  head $(printf '%s' "$qhead" | cut -c1-9)"
    if [ "$hrs" != "?" ] && awk -v a="$hrs" -v t="$STALE_QUEUE_HOURS" 'BEGIN { exit !(a > t) }'; then
      # A stale-queued run is a FINDING only when a remedy exists. Split on the
      # two questions that decide that, in remedy order, and fail closed on
      # every unreadable answer:
      #   live head?          -> re-run the workflow on that head. SCREAM.
      #   dead head, jobs>0?  -> dispatched and stuck; cancel works. SCREAM.
      #   dead head, jobs==0? -> ORPHANED. GitHub refuses both cancel paths
      #                          (measured on all 8: run cancel says
      #                          "completed", REST says "NOT BEEN QUEUED YET").
      #                          No remedy exists, so no verdict — a NOTICE.
      qjobs="$(read_jobs_count "$qid")"
      if [ "$LIVE_OK" != "1" ] || [ "$qjobs" = "-1" ]; then
        # Liveness or the job count could not be read. A run nobody can prove
        # orphaned keeps the verdict it has today.
        say "$line  STALE (> ${STALE_QUEUE_HOURS}h)"
        STALE_ROWS=$((STALE_ROWS + 1))
      elif [ -n "$qhead" ] && [ "$qhead" != "-" ] && case " $LIVE_HEADS " in *" $qhead "*) true ;; *) false ;; esac; then
        say "$line  STALE (> ${STALE_QUEUE_HOURS}h)  LIVE HEAD — remedy: re-run this workflow on the head"
        STALE_ROWS=$((STALE_ROWS + 1))
      elif [ "$qjobs" != "0" ]; then
        # Dispatched outranks dormancy: cancel works on ANY head, live, dormant
        # or dead, and a dispatched queued run is holding a runner slot.
        say "$line  STALE (> ${STALE_QUEUE_HOURS}h)  DISPATCHED — remedy: gh run cancel $qid"
        STALE_ROWS=$((STALE_ROWS + 1))
      elif [ -n "$qhead" ] && [ "$qhead" != "-" ] && case " $DORMANT_HEADS " in *" $qhead "*) true ;; *) false ;; esac; then
        # The boundary case, decided rather than left to reopen the design: the
        # head IS current on an open PR, so re-run exists in principle — but the
        # PR has had no activity in DORMANT_PR_DAYS, so nobody is coming to
        # apply it. A remedy nobody will apply is not a remedy.
        say "$line  DORMANT PR HEAD (open PR, no activity in ${DORMANT_PR_DAYS}d — the re-run remedy is notional)"
        ORPHAN_ROWS=$((ORPHAN_ROWS + 1))
      else
        # created_at == updated_at is evidence about HOW it died — never
        # dispatched at all versus dispatched and lost — not the verdict key.
        updated="$(jq -r '.updated_at // empty' <<<"$row")"
        if [ -n "$updated" ] && [ "$updated" = "$created" ]; then
          say "$line  ORPHANED (never dispatched; undispatchable, head not on any open PR or main)"
        else
          say "$line  ORPHANED (undispatchable; head not on any open PR or main)"
        fi
        ORPHAN_ROWS=$((ORPHAN_ROWS + 1))
      fi
    else
      say "$line"
    fi
  done <<<"$QUEUED_PAGINATED"
  [ "$QP_N" = "0" ] && say "  (none)"
fi

say ""

# ── the in-flight column ─────────────────────────────────────────────────────
# Printed, never screamed. A reader who wants to know why a context is not on a
# head yet gets the whole list; a reader who wants to know whether anything is
# WRONG reads the two verdict lines below and never has to scroll through this.
if [ "$PENDING_ROWS" -gt 0 ]; then
  say "in flight — NOT a finding, listed so the absence column stays honest"
  printf '%s\n' "$PENDING_REPORT" | sed '/^$/d'
  say ""
fi

# ── THE TWO LIMBS ARE REPORTED APART ─────────────────────────────────────────
# They were fused into one exit code and one sentence, and the consequence was
# measured: between 2026-08-07 and 2026-08-24 this census failed 71 of 71 runs.
# The absence limb over-reported on every single one of them, and it drowned the
# queue limb — which was RIGHT, and which had been naming seven undispatched runs
# on a real main commit since the census's first day. Nobody acted on them for
# seventeen days, because a watch that is red every time it runs is
# indistinguishable from a watch that is broken.
#
# So each limb now states its own verdict on its own line, in full, whether or
# not the other one fired. A reader grepping `VERDICT  queue limb` gets an
# answer that the absence limb cannot suppress, dilute or push off the top of
# the log — and that holds even if only half of this file ever lands.
if [ "$ABSENT_ROWS" -gt 0 ]; then
  say "VERDICT  absence limb : SCREAM — $ABSENT_ROWS required context(s) render nowhere on an open head and are not self-resolving"
else
  say "VERDICT  absence limb : clean — every required context is rendered, or its producing run is still working on it"
fi
if [ "$STALE_ROWS" -gt 0 ]; then
  say "VERDICT  queue limb   : SCREAM — $STALE_ROWS queued run(s) older than ${STALE_QUEUE_HOURS}h with a live remedy (re-run or cancel)"
else
  say "VERDICT  queue limb   : clean — no actionable queued run is older than ${STALE_QUEUE_HOURS}h"
fi
if [ "$ORPHAN_ROWS" -gt 0 ]; then
  say "NOTICE   queue limb   : $ORPHAN_ROWS orphaned run record(s) — undispatchable, on heads no open PR or main carries. No remedy exists; kept as the audit trail of the class."
fi
say ""
say "SUMMARY  absent=$ABSENT_ROWS  stale-queued=$STALE_ROWS  unknown=$UNKNOWN_ROWS  in-flight=$PENDING_ROWS  orphaned=$ORPHAN_ROWS  phantom-queued=$PHANTOM_ROWS"

[ "$CONFIG_FAULT" = "1" ] && {
  warn "CONFIGURATION FAULT — this run's credential cannot read the Actions and check-run endpoints. A census with no authority is not a clean census."
  exit 3
}
if [ "$ABSENT_ROWS" -gt 0 ] || [ "$STALE_ROWS" -gt 0 ]; then
  # Only the limbs that actually fired. A verdict that recites "and 0 queued
  # run(s)" beside a real finding reads like a template, and a template is what
  # a human learns to stop reading.
  FOUND=""
  [ "$ABSENT_ROWS" -gt 0 ] && FOUND="$ABSENT_ROWS required context(s) render nowhere on an open head"
  [ "$STALE_ROWS" -gt 0 ] && FOUND="${FOUND:+$FOUND, and }$STALE_ROWS queued run(s) older than ${STALE_QUEUE_HOURS}h"
  warn "SCREAM: $FOUND. None of it shows up as a red check anywhere, which is why this exits non-zero."
  exit 1
fi
if [ "$UNKNOWN_ROWS" -gt 0 ]; then
  warn "UNKNOWN: $UNKNOWN_ROWS head(s) or feed(s) could not be read. Reporting that as 'nothing found' is the failure this census exists to abolish."
  exit 2
fi
exit 0
