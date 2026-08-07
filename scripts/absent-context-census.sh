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
#      DIFFERENT remedy each one implies:
#        ZOMBIED         queued, attempt 1, jobs.total_count 0 — GitHub created
#                        the run and never dispatched it. Re-dispatch.
#        RERUN_DELETED   attempt >= 2 with no rendered check run. Re-run.
#        NAME_NOT_IN_RUN the producing run COMPLETED and rendered no check run
#                        under this name — a head predating the context, a
#                        renamed job, a pruned aggregator. Rebase, or edit the
#                        spec. Never re-dispatch; there is nothing to dispatch.
#        NO_RUN          no run of the producing workflow on this head at all.
#        UNCLASSIFIED(…) the census does not know, and says so rather than
#                        picking the nearest label;
#   2. a repo-wide queued-run enumeration that is PAGINATED and
#      SERVER-FILTERED, so it can report a queue older than the last page.
#
# THE PENDING CASE IS DELIBERATELY OUT OF SCOPE, and the omission is a ruling
# rather than an oversight. A check run that IS rendered but has not concluded
# is a live, self-resolving state and it is somebody else's subject. This
# instrument's subject is a name that RENDERS NOWHERE — jobs.total_count is 0,
# so there is no check run of any status to classify. The two populations are
# disjoint by construction, and the harness pins that with a fixture whose only
# anomaly is a rendered, unconcluded check run: it reports nothing.
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
#   0  every required context rendered on every head examined, and no queued run
#      is older than the staleness threshold
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
SHAS=()

# Report accumulators.
ABSENT_ROWS=0
STALE_ROWS=0
UNKNOWN_ROWS=0

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

# Open PR heads: NDJSON of {number, sha, updated_at}.
read_open_prs() {
  local f
  if [ -n "$FIXTURES" ]; then
    f="$(fixture prs.json)" || { warn "fixtures mode: missing prs.json"; return 1; }
    jq -c '.[] | {number, sha: .headRefOid, updated_at: .updatedAt}' "$f"
  else
    gh pr list --repo "$REPO" --state open --limit 100 \
      --json number,headRefOid,updatedAt 2>/dev/null \
      | jq -c '.[] | {number, sha: .headRefOid, updated_at: .updatedAt}'
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
    jq -c '.workflow_runs[] | {id, path, status, run_attempt, created_at, head_sha}' "$f"
  else
    gh_api "repos/$REPO/actions/runs?status=queued&per_page=100" \
      '.workflow_runs[] | {id, path, status, run_attempt, created_at, head_sha}'
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
census_head() { # <sha> <label>
  local sha="$1" label="$2" checks runs names oldest_queued anchor anchor_label

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
      class="NO_RUN"; rid="-"
    else
      rid="$(jq -r '.id' <<<"$newest")"
      attempt="$(jq -r '.run_attempt // 1' <<<"$newest")"
      status="$(jq -r '.status // ""' <<<"$newest")"
      if [ "$attempt" -ge 2 ] 2>/dev/null; then
        class="RERUN_DELETED"
      else
        case "$status" in
          queued|waiting|pending|requested)
            jobs="$(read_jobs_count "$rid")"
            if [ "$jobs" = "0" ]; then
              class="ZOMBIED"
            elif [ "$jobs" = "-1" ]; then
              class="UNCLASSIFIED(jobs-unreadable)"
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
          completed) class="NAME_NOT_IN_RUN" ;;
          *) class="UNCLASSIFIED(status=$status)" ;;
        esac
      fi
    fi

    say "ABSENT   $label  head $sha"
    say "         context \"$ctx\" renders nowhere on this head"
    say "         class   $class"
    say "         age     $(age_hours "$anchor")h  (anchor: $anchor_label $anchor)"
    say "         run     $rid  producer $wf"
    ABSENT_ROWS=$((ABSENT_ROWS + 1))
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
    census_head \
      "$(jq -r '.sha' <<<"$row")" \
      "PR #$(jq -r '.number' <<<"$row")" \
      "$(jq -r '.updated_at' <<<"$row")"
  done <<<"$PRS"
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
  say "  paginated + server-filtered (?status=queued&per_page=100 --paginate): $QP_N"
  say "  default page, filtered client-side (the form that loses):             $QD_N"
  if [ "$QD_N" != "?" ] && [ "$QP_N" -gt "$QD_N" ]; then
    say "  the default-page form is UNDERCOUNTING by $((QP_N - QD_N)) run(s) right now — every one of them older than its last page"
  fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    created="$(jq -r '.created_at' <<<"$row")"
    hrs="$(age_hours "$created")"
    line="  queued $(jq -r '.path' <<<"$row")  run $(jq -r '.id' <<<"$row")  attempt $(jq -r '.run_attempt // 1' <<<"$row")  age ${hrs}h  head $(jq -r '.head_sha // "-"' <<<"$row" | cut -c1-9)"
    if [ "$hrs" != "?" ] && awk -v a="$hrs" -v t="$STALE_QUEUE_HOURS" 'BEGIN { exit !(a > t) }'; then
      say "$line  STALE (> ${STALE_QUEUE_HOURS}h)"
      STALE_ROWS=$((STALE_ROWS + 1))
    else
      say "$line"
    fi
  done <<<"$QUEUED_PAGINATED"
  [ "$QP_N" = "0" ] && say "  (none)"
fi

say ""
say "SUMMARY  absent=$ABSENT_ROWS  stale-queued=$STALE_ROWS  unknown=$UNKNOWN_ROWS"

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
