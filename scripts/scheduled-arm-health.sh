#!/usr/bin/env bash
# scheduled-arm-health.sh — for every workflow in the tree that declares a cron,
# the verdict of its SCHEDULED runs, SCOPED BY EVENT, and loudest of all: the
# ones that have never succeeded even once.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE DEFECT THIS EXISTS FOR (task-2c762aa7dfca5bd8, measured 2026-09-15)
# ─────────────────────────────────────────────────────────────────────────────
# studio-journey-smoke's daily scheduled run had failed 47 times out of 47 since
# 2026-07-30 — every scheduled run it has ever had — and cost nobody a second.
# The job's own name ends "(report mode, gates nothing)", and "gates nothing"
# had quietly come to mean "nobody ever reads it". A check that reports
# correctly into a void is not a check.
#
# WHY THE OBVIOUS READER MISSES IT, AND THIS IS THE WHOLE POINT OF THIS FILE.
# Over the last 50 runs of that workflow across ALL EVENTS the conclusions read
# success=38. Those greens are a DIFFERENT JOB — the offline self-test arm, which
# runs on push and pull_request and was explicitly skipped on the cron. The green
# runs and the red runs measure different things, so ANY reader that counts runs
# without splitting by `event` will certify this workflow as healthy. Measured on
# main the same day: scripts/main-workflow-rollup.sh reads
# `actions/runs?branch=main&status=completed` and never touches `.event`, so a
# single push-green landing inside a streak of scheduled reds resets its grace
# clock. It is an honest instrument asking a different question — "is main
# healthy?" — and the question here is "does the cron measure anything?".
#
# THEREFORE EVERY COUNT IN THIS SCRIPT IS TAKEN WITH `event=schedule`, and the
# all-events count is fetched too, ONLY so a disagreement between them can be
# named out loud as the LAUNDERED verdict below.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE ROSTER IS THE TREE
# ─────────────────────────────────────────────────────────────────────────────
# Enumerated from .github/workflows/*.yml(+.yaml) on the working tree, filtered
# to files carrying a `- cron:` entry. Never a committed list, never "the
# workflows GitHub happens to have run" — a workflow whose cron fires into
# nothing is exactly the case that leaves no failing run to find, and a roster
# built from run data cannot contain it. The count of files enumerated and the
# count that declare a cron are both printed, so adding one moves a number a
# reader can see.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE FOUR VERDICTS
# ─────────────────────────────────────────────────────────────────────────────
#   NEVER SUCCEEDED  >= --min-runs completed scheduled runs, zero successes.
#                    RED. This is the studio-journey-smoke shape.
#   LAUNDERED        zero scheduled successes AND at least one success on some
#                    other event. RED, and reported as its own line because it
#                    is the state a naive reader calls healthy.
#   STALE            it has succeeded, but not within --stale-days, while
#                    scheduled runs kept happening. RED.
#   NEVER RAN        a cron is declared and the API knows of ZERO completed
#                    scheduled runs. Reported loudly, NOT red by default: a cron
#                    added yesterday is indistinguishable from one GitHub has
#                    disabled, and reading the first as a defect would make this
#                    instrument cry wolf on its own first day. --strict-never-ran
#                    promotes it. Either way the line is printed, never omitted.
#
# AN UNREADABLE WORKFLOW IS NEVER GREEN. A `gh api` that errors or times out
# (main-gate-watch.yml did exactly that during this script's own bring-up) exits
# 2 CANNOT MEASURE for the whole run. A reader that skipped the row would print a
# clean report having not looked, which is the failure mode this file is about.
#
# PAGINATION IS NOT AN ABSENCE CLAIM. `total_count` and the number of runs
# actually received are both printed on every row. Where they differ the row says
# so, and every "zero successes" verdict is explicitly relative to the runs read.
#
# USAGE
#   scripts/scheduled-arm-health.sh                       # whole tree, live API
#   scripts/scheduled-arm-health.sh --workflow studio-journey-smoke.yml
#   scripts/scheduled-arm-health.sh --runs-dir DIR        # offline fixtures
#   --min-runs N (default 5) · --stale-days N (default 21) · --strict-never-ran
#   --repo owner/name (default: read from .github/required-checks.json)
#   --now ISO8601 (default: now — pinned by the self-test so it cannot rot)
#
# OFFLINE FIXTURES. --runs-dir DIR reads DIR/<basename>.schedule.json and
# DIR/<basename>.all.json, each the raw `actions/workflows/<file>/runs` payload.
# That is the route the self-test uses; it never touches the network.
#
# EXIT: 0 no red · 1 at least one red · 2 cannot measure.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${SAH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKFLOWS_DIR="$ROOT/.github/workflows"
MIN_RUNS=5
STALE_DAYS=21
STRICT_NEVER_RAN=0
RUNS_DIR=""
ONLY=""
REPO_OVERRIDE=""
NOW_ISO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --min-runs) MIN_RUNS="${2:-}"; shift 2 ;;
    --stale-days) STALE_DAYS="${2:-}"; shift 2 ;;
    --strict-never-ran) STRICT_NEVER_RAN=1; shift ;;
    --runs-dir) RUNS_DIR="${2:-}"; shift 2 ;;
    --workflow) ONLY="${2:-}"; shift 2 ;;
    --repo) REPO_OVERRIDE="${2:-}"; shift 2 ;;
    --now) NOW_ISO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "scheduled-arm-health: REFUSING — unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -d "$WORKFLOWS_DIR" ] || { echo "scheduled-arm-health: REFUSING — no .github/workflows/ under $ROOT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "scheduled-arm-health: REFUSING — jq is not on PATH" >&2; exit 2; }
[ -n "$NOW_ISO" ] || NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ISO8601 (Z) -> epoch seconds, on both GNU and BSD date. Prints nothing when it
# cannot parse, and every caller treats an empty answer as "cannot measure age"
# rather than as age zero — an unparsed date must never read as fresh.
iso_epoch() {
  local iso="$1" e=""
  [ -n "$iso" ] || return 0
  e="$(date -u -d "$iso" +%s 2>/dev/null)" || e=""
  if [ -z "$e" ]; then e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" || e=""; fi
  printf '%s' "$e"
}

NOW_EPOCH="$(iso_epoch "$NOW_ISO")"
[ -n "$NOW_EPOCH" ] || { echo "scheduled-arm-health: REFUSING — cannot parse --now '$NOW_ISO'" >&2; exit 2; }

REPO="$REPO_OVERRIDE"
if [ -z "$REPO" ] && [ -z "$RUNS_DIR" ]; then
  REPO="$(jq -r '.repo // empty' "$ROOT/.github/required-checks.json" 2>/dev/null)"
  [ -n "$REPO" ] || { echo "scheduled-arm-health: REFUSING — no repo in .github/required-checks.json and no --repo" >&2; exit 2; }
fi

# Fetch one workflow's completed runs for one event scope. Echoes the JSON body,
# or the literal UNREADABLE — which the caller turns into exit 2, never a skip.
fetch_runs() {
  local base="$1" scope="$2" body="" q=""
  if [ -n "$RUNS_DIR" ]; then
    local f="$RUNS_DIR/$base.$scope.json"
    [ -f "$f" ] || { echo UNREADABLE; return 0; }
    body="$(cat "$f")"
  else
    q="per_page=100&status=completed"
    [ "$scope" = "schedule" ] && q="$q&event=schedule"
    body="$(gh api "repos/$REPO/actions/workflows/$base/runs?$q" 2>&1)" || { echo UNREADABLE; return 0; }
  fi
  jq -e 'has("workflow_runs")' >/dev/null 2>&1 <<<"$body" || { echo UNREADABLE; return 0; }
  printf '%s' "$body"
}

# total_count <TAB> received <TAB> success <TAB> failure <TAB> newest-success-iso
summarise() {
  jq -r '
    (.workflow_runs // []) as $r
    | [ (.total_count // ($r|length)),
        ($r|length),
        ([$r[]|select(.conclusion=="success")]|length),
        ([$r[]|select(.conclusion=="failure")]|length),
        ([$r[]|select(.conclusion=="success")|(.run_started_at // .created_at)]|sort|last // "")
      ] | @tsv'
}

say() { printf '%s\n' "$*"; }

say "scheduled-arm-health — roster = the tree at ${ROOT}, as of $NOW_ISO"
say "  min-runs=$MIN_RUNS  stale-days=$STALE_DAYS  strict-never-ran=$STRICT_NEVER_RAN  source=${RUNS_DIR:-live API ($REPO)}"
say ""

FILES=""
DENOM=0
for f in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  DENOM=$((DENOM + 1))
  grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$f" || continue
  b="$(basename "$f")"
  if [ -n "$ONLY" ] && [ "$b" != "$ONLY" ]; then continue; fi
  FILES="$FILES$b
"
done

CRONNED=0
while IFS= read -r b; do [ -n "$b" ] || continue; CRONNED=$((CRONNED + 1)); done <<EOF
$FILES
EOF

say "enumerated $DENOM workflow files; $CRONNED declare a cron${ONLY:+ (scoped to --workflow $ONLY)}"
if [ "$CRONNED" -eq 0 ]; then
  say "REFUSING — nothing to measure. A report over an empty roster is not a clean report."
  exit 2
fi
say ""

REDS=0
NEVER_RAN_N=0
OK_N=0

while IFS= read -r base; do
  [ -n "$base" ] || continue

  sched="$(fetch_runs "$base" schedule)"
  allev="$(fetch_runs "$base" all)"
  if [ "$sched" = "UNREADABLE" ] || [ "$allev" = "UNREADABLE" ]; then
    say "CANNOT MEASURE  $base — the runs listing could not be read."
    say "                A report that skips an unreadable row prints a clean verdict it did not earn."
    exit 2
  fi

  IFS="$(printf '\t')" read -r s_tc s_got s_ok s_fail s_last <<EOF
$(printf '%s' "$sched" | summarise)
EOF
  IFS="$(printf '\t')" read -r a_tc a_got a_ok a_fail a_last <<EOF
$(printf '%s' "$allev" | summarise)
EOF

  window="scheduled total_count=$s_tc received=$s_got · success=$s_ok failure=$s_fail"
  [ "$s_tc" = "$s_got" ] || window="$window (TRUNCATED READ: $s_got of $s_tc — every verdict below is relative to the $s_got read)"

  if [ "${s_got:-0}" -eq 0 ]; then
    NEVER_RAN_N=$((NEVER_RAN_N + 1))
    say "NEVER RAN       $base — declares a cron and has ZERO completed scheduled runs."
    say "                all events: success=$a_ok failure=$a_fail of $a_got read."
    say "                A cron added recently looks identical to one GitHub has disabled; decide which."
    [ "$STRICT_NEVER_RAN" -eq 1 ] && REDS=$((REDS + 1))
    continue
  fi

  if [ "${s_ok:-0}" -eq 0 ]; then
    if [ "${s_got:-0}" -ge "$MIN_RUNS" ]; then
      REDS=$((REDS + 1))
      say "NEVER SUCCEEDED $base — $window"
      say "                NOT ONE of the $s_got completed scheduled runs read here succeeded."
      if [ "${a_ok:-0}" -gt 0 ]; then
        say "                LAUNDERED: across ALL events this workflow reads success=$a_ok of $a_got —"
        say "                those greens are a DIFFERENT ARM on a different event. A reader that does not"
        say "                split by event will call this workflow healthy. That is the whole defect."
      fi
      say "                A scheduled arm that has never once succeeded is not a flake; it has never worked."
    else
      say "young           $base — $window; $s_got runs is under --min-runs=$MIN_RUNS, no verdict yet."
    fi
    continue
  fi

  last_epoch="$(iso_epoch "$s_last")"
  if [ -z "$last_epoch" ]; then
    say "CANNOT MEASURE  $base — newest scheduled success timestamp '$s_last' did not parse."
    exit 2
  fi
  age_days=$(( (NOW_EPOCH - last_epoch) / 86400 ))
  if [ "$age_days" -gt "$STALE_DAYS" ]; then
    REDS=$((REDS + 1))
    say "STALE           $base — $window; newest scheduled success $s_last is ${age_days}d old (> $STALE_DAYS)."
  else
    OK_N=$((OK_N + 1))
    say "ok              $base — $window; newest scheduled success $s_last (${age_days}d)."
  fi
done <<EOF
$FILES
EOF

say ""
say "SUMMARY: $CRONNED cron'd workflow(s) measured · $OK_N ok · $NEVER_RAN_N never ran · $REDS red"
if [ "$REDS" -gt 0 ]; then
  say ""
  say "A scheduled job that gates nothing still has to be READ. These are the rows where the"
  say "cron has been firing into a void — the state that let a daily red sit unnoticed for six"
  say "weeks. Fix the arm, supply what it needs, or take it off the cron WITH ITS REASON WRITTEN"
  say "IN THE WORKFLOW. Deleting a schedule quietly is the one remedy that is worse than the bug."
  exit 1
fi
exit 0
