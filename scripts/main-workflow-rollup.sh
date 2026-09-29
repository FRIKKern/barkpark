#!/usr/bin/env bash
# main-workflow-rollup.sh — every workflow IN THE TREE, its newest completed
# verdict on main, and whether that verdict can block a merge.
#
# THE DEFECT THIS EXISTS FOR IS THE DENOMINATOR, NOT THE VERDICT
#
# main-gate-watch.sh and stale-verdict-watch.sh are both honest instruments and
# both read a WATCHED SET: main-gate-watch derives its roster from branch
# protection's required contexts, stale-verdict-watch from the open-PR
# population. Neither can report a workflow that is not in the set it was told
# to look at. So a workflow that has drifted out of branch protection, or that
# has never had a single run on main at all, is not reported as unhealthy — it
# is not reported AT ALL, and in a report an absence reads exactly like a green.
# A roll-up that counts only what it was told to look for cannot discover the
# thing nobody told it about.
#
# THEREFORE THE ROSTER IS THE TREE, AND THE DENOMINATOR IS PRINTED
#
# The enumeration is `.github/workflows/*.yml`(+`.yaml`) read off the working
# tree, never a committed list and never the set of names GitHub happens to have
# run. The count of files enumerated is printed on its own line, so adding a
# workflow file raises a number a reader can see; if the count does not move
# when the tree gains a workflow, this instrument is reading a watched set and
# is broken. A workflow with ZERO completed runs on main is printed with that
# fact in words — it is the loudest row here, not an omitted one, because
# "never ran" is the one state that leaves no failing run behind to find.
#
# REQUIRED vs ADVISORY IS DERIVED, NEVER LISTED HERE
#
# main today carries ADVISORY reds (Crown reconcile is a production fact routed
# elsewhere; Stale verdict watch's rc 6 is GitHub transport silence). An
# operator reading a flat list of failing runs cannot tell either from a
# merge-blocking red, and a script carrying its own hardcoded list of the
# required four goes stale against .github/required-checks.json in silence.
# So the needles come from the spec at run time:
# `.protection.required_status_checks.checks[].context`. A workflow is REQUIRED
# when one of those context strings is a job `name:` value in that file — that
# is the actual mechanism by which a workflow renders a required check run
# (verified on main: Cloud gate/cloud.yml, Console gate/console-harness.yml,
# Elixir gate/elixir.yml, PR references an active task/pr-task-gate.yml, four
# for four). Move a name between `checks` and `exclusions` in the spec and the
# label for its workflow flips, because nothing here repeats the name.
#
# THE GRACE WINDOW, AND WHY A RED ALONE IS NOT A FAILURE
#
# A workflow that went red twenty minutes ago is a workflow somebody is very
# probably already fixing, and an instrument that fails on it fails on every
# transient and gets muted. The failing condition is a red that PERSISTS: the
# newest completed run is a failure, and the OLDEST run of the current
# unbroken failure streak started more than the grace window ago (default 24h,
# --grace-hours). One green anywhere in the streak resets the clock, so a
# flapping workflow never accumulates age it did not actually spend red.
#
# THE READ WINDOW IS PRINTED, BECAUSE "ZERO RUNS" IS A CLAIM ABOUT A WINDOW
#
# GitHub's `actions/runs` listing is finite (the API stops around 1000 results
# even under --paginate, and a recorded fixture is whatever was recorded), so
# "this workflow has no completed run on main" is honestly "none among the N
# completed runs this read could see". N is printed on the zero-run line and in
# the summary. That is still the loudest row in the report — a workflow with no
# run in a window covering every other workflow's last N runs is not being
# exercised — but it is not dressed up as a claim about all of history.
#
# HERMETIC BY CONSTRUCTION
#
# Every input is injectable: --workflows-dir (the tree), --runs-file (a recorded
# `gh api .../actions/runs` payload), --spec (required-checks.json), --now (the
# clock). With all four supplied this script makes no network call at all, which
# is what lets its harness prove both directions on fixtures.
#
# EXIT CODES  0 = no workflow has been red on main past the grace window
#             1 = at least one has — named, with how long it has been red
#             3 = CONFIGURATION FAULT: the tree, the spec, or the run data
#                 could not be read. A roll-up that cannot see must never
#                 report an empty green.
#
# USAGE
#   scripts/main-workflow-rollup.sh
#   scripts/main-workflow-rollup.sh --grace-hours 48
#   # hermetic (the harness; no network at all):
#   scripts/main-workflow-rollup.sh --workflows-dir <d> --runs-file <f> \
#       --spec <f> --now 2026-09-11T00:00:00Z

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
SPEC="$REPO_ROOT/.github/required-checks.json"
RUNS_FILE=""
NOW_ISO=""
GRACE_HOURS=24
BRANCH="main"
REPO_OVERRIDE=""

say() { echo "$*"; }
red() { echo "$*" >&2; }

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --workflows-dir) WORKFLOWS_DIR="${2:-}"; shift 2 ;;
    --runs-file)     RUNS_FILE="${2:-}"; shift 2 ;;
    --spec)          SPEC="${2:-}"; shift 2 ;;
    --now)           NOW_ISO="${2:-}"; shift 2 ;;
    --grace-hours)   GRACE_HOURS="${2:-}"; shift 2 ;;
    --branch)        BRANCH="${2:-}"; shift 2 ;;
    --repo)          REPO_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) red "unknown argument: $1"; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { red "CONFIGURATION FAULT — jq is not installed; this roll-up cannot read anything."; exit 3; }

# ── epoch seconds from an ISO8601 Z timestamp, portably ──────────────────────
# GNU date and BSD date disagree on every flag that matters, so neither is
# asked: jq's own strptime is the same on both and is already a dependency.
iso_to_epoch() {
  local iso="$1"
  [ -n "$iso" ] || { echo ""; return 0; }
  jq -rn --arg t "$iso" '
    ($t | sub("\\.[0-9]+Z$"; "Z") | sub("Z$"; "Z"))
    | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch empty
  ' 2>/dev/null
}

# ── the clock ────────────────────────────────────────────────────────────────
if [ -n "$NOW_ISO" ]; then
  NOW_EPOCH="$(iso_to_epoch "$NOW_ISO")"
  if [ -z "$NOW_EPOCH" ]; then
    red "CONFIGURATION FAULT — --now '$NOW_ISO' is not an ISO8601 Z timestamp."
    exit 3
  fi
else
  NOW_EPOCH="$(date -u +%s)"
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

case "$GRACE_HOURS" in
  ''|*[!0-9]*) red "CONFIGURATION FAULT — --grace-hours must be a whole number of hours, got '$GRACE_HOURS'."; exit 3 ;;
esac
GRACE_SECONDS=$((GRACE_HOURS * 3600))

# ── authority 1: THE TREE (the denominator) ──────────────────────────────────
if [ ! -d "$WORKFLOWS_DIR" ]; then
  red "CONFIGURATION FAULT — workflows directory not found: $WORKFLOWS_DIR"
  red "The roster of this roll-up IS the tree. With no tree there is no denominator,"
  red "and a roll-up with no denominator reporting green is the defect it exists to abolish."
  exit 3
fi

WF_FILES="$(find "$WORKFLOWS_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)"
DENOMINATOR=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  DENOMINATOR=$((DENOMINATOR + 1))
done <<EOF
$WF_FILES
EOF

if [ "$DENOMINATOR" -eq 0 ]; then
  red "CONFIGURATION FAULT — $WORKFLOWS_DIR contains no *.yml/*.yaml file."
  red "Zero enumerated workflows is not a clean bill of health; it is a read that found nothing."
  exit 3
fi

# ── authority 2: the spec (REQUIRED vs ADVISORY) ─────────────────────────────
# One required context per line. Never a list in this file.
if [ ! -f "$SPEC" ]; then
  red "CONFIGURATION FAULT — required-checks spec not found: $SPEC"
  red "Without it every row would have to be labelled by guess, and a guessed REQUIRED"
  red "is worse than no label at all."
  exit 3
fi
REQUIRED_CONTEXTS="$(jq -r '.protection.required_status_checks.checks[]?.context // empty' "$SPEC" 2>/dev/null)"
if [ -z "$REQUIRED_CONTEXTS" ]; then
  red "CONFIGURATION FAULT — $SPEC carries no .protection.required_status_checks.checks[].context."
  red "An empty required set would label every workflow ADVISORY, which reads as 'nothing can block a merge'."
  exit 3
fi

# ── authority 3: the completed runs on the branch ────────────────────────────
# TSV: workflow path <TAB> conclusion <TAB> run_started_at, newest first. The
# join key is `.path` (".github/workflows/elixir.yml"), not the display name: a
# renamed workflow keeps its file and a display name is not unique.
read_runs_tsv() {
  local body
  if [ -n "$RUNS_FILE" ]; then
    [ -f "$RUNS_FILE" ] || { echo "UNREADABLE"; return 0; }
    body="$(cat "$RUNS_FILE")"
  else
    local repo
    repo="${REPO_OVERRIDE:-$(jq -r '.repo // empty' "$SPEC" 2>/dev/null)}"
    if [ -z "$repo" ]; then echo "UNREADABLE"; return 0; fi
    body="$(gh api --paginate -X GET -f branch="$BRANCH" -f status=completed -f per_page=100 \
              "repos/$repo/actions/runs" 2>&1)" || { echo "UNREADABLE"; return 0; }
  fi
  jq -e . >/dev/null 2>&1 <<<"$body" || { echo "UNREADABLE"; return 0; }
  # `gh api --paginate` on an OBJECT endpoint emits one document PER PAGE, so
  # the whole stream is slurped before it is sorted: a newer run on page 2 must
  # be able to outrank an older one on page 1.
  jq -r -s '
    map(if type == "array" then . else (.workflow_runs // []) end)
    | (add // [])
    | map(select((.status // "") == "completed"))
    | map({path: (.path // ""),
           conclusion: (.conclusion // ""),
           started: (.run_started_at // .created_at // "")})
    | map(select(.path != ""))
    | sort_by(.started)
    | reverse
    | .[]
    | [.path, .conclusion, .started]
    | @tsv
  ' <<<"$body" 2>/dev/null || { echo "UNREADABLE"; return 0; }
}

RUNS_TSV="$(read_runs_tsv)"
case "$RUNS_TSV" in
  UNREADABLE)
    red "CONFIGURATION FAULT — the completed workflow runs on '$BRANCH' could not be read."
    red "A roll-up blind to the run data must not print a roster of green rows it did not measure."
    exit 3 ;;
esac

# ── the roll-up ──────────────────────────────────────────────────────────────
say "main-workflow-rollup — branch $BRANCH, as of $NOW_ISO, grace ${GRACE_HOURS}h"
RUNS_READ=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  RUNS_READ=$((RUNS_READ + 1))
done <<EOF
$RUNS_TSV
EOF

say "enumerated $DENOMINATOR workflow files in ${WORKFLOWS_DIR#"$REPO_ROOT"/}"
say "read $RUNS_READ completed runs on $BRANCH (the window every 'no completed run' verdict below is relative to)"
say ""

STALE=""
NEVER_RAN=0
REQUIRED_COUNT=0
RED_NOW=0

while IFS= read -r file; do
  [ -n "$file" ] || continue
  base="$(basename "$file")"
  relpath=".github/workflows/$base"

  # display name, for the operator; the JOIN never uses it
  wfname="$(awk '/^name:[[:space:]]*/ {sub(/^name:[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; exit}' "$file")"
  [ -n "$wfname" ] || wfname="(unnamed)"

  # REQUIRED derivation: does this file render a required context as a job name?
  label="ADVISORY"
  matched_ctx=""
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    if grep -qF -- "name: $ctx" "$file" 2>/dev/null; then
      label="REQUIRED"
      matched_ctx="$ctx"
      break
    fi
  done <<EOF
$REQUIRED_CONTEXTS
EOF
  [ "$label" = "REQUIRED" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))

  # this workflow's completed runs, newest first
  mine="$(awk -F'\t' -v p="$relpath" '$1 == p {print $2 "\t" $3}' <<EOF
$RUNS_TSV
EOF
)"

  runcount=0
  newest_conclusion=""
  newest_started=""
  streak_started=""
  while IFS="$(printf '\t')" read -r concl started; do
    [ -n "$concl$started" ] || continue
    runcount=$((runcount + 1))
    if [ -z "$newest_conclusion" ]; then
      newest_conclusion="$concl"
      newest_started="$started"
    fi
    if [ "$newest_conclusion" = "failure" ]; then
      if [ "$concl" = "failure" ] && [ -z "${streak_broken:-}" ]; then
        streak_started="$started"
      else
        streak_broken=1
      fi
    fi
  done <<EOF
$mine
EOF
  unset streak_broken

  if [ "$runcount" -eq 0 ]; then
    NEVER_RAN=$((NEVER_RAN + 1))
    say "  $label  $base  [$wfname]  NO COMPLETED RUN ON $BRANCH among the $RUNS_READ read — zero runs, so no failing run exists to find (runs=0)"
    continue
  fi

  detail="newest=$newest_conclusion at $newest_started (runs=$runcount)"
  [ -n "$matched_ctx" ] && detail="$detail required-context=\"$matched_ctx\""

  if [ "$newest_conclusion" != "failure" ]; then
    say "  $label  $base  [$wfname]  $detail"
    continue
  fi

  RED_NOW=$((RED_NOW + 1))
  streak_epoch="$(iso_to_epoch "$streak_started")"
  if [ -z "$streak_epoch" ]; then
    say "  $label  $base  [$wfname]  RED  $detail  (streak start unparseable: '$streak_started')"
    continue
  fi
  age=$((NOW_EPOCH - streak_epoch))
  age_h=$((age / 3600))
  # THE STALENESS COMPARISON. Mutating this to be always-false is what the
  # harness uses to prove the red fixture goes green.
  if [ "$age" -gt "$GRACE_SECONDS" ]; then     # MUT: staleness comparison
    say "  $label  $base  [$wfname]  RED PAST GRACE — red for ${age_h}h (since $streak_started)  $detail"
    STALE="$STALE$label $base [$wfname] red for ${age_h}h since $streak_started
"
  else
    say "  $label  $base  [$wfname]  RED (within ${GRACE_HOURS}h grace, ${age_h}h old)  $detail"
  fi
done <<EOF
$WF_FILES
EOF

say ""
say "enumerated $DENOMINATOR · required $REQUIRED_COUNT · advisory $((DENOMINATOR - REQUIRED_COUNT)) · zero-run $NEVER_RAN · newest-run-red $RED_NOW · completed runs read $RUNS_READ"

if [ -n "$STALE" ]; then
  red ""
  red "RED ON $BRANCH PAST THE ${GRACE_HOURS}h GRACE WINDOW:"
  printf '%s' "$STALE" | while IFS= read -r line; do [ -n "$line" ] && red "  $line"; done
  red ""
  red "A REQUIRED row here blocks merges. An ADVISORY row does not — and is still a workflow"
  red "nobody is fixing: the umbrella promise is that each one is fixed, moved, or deleted."
  exit 1
fi

say "ok — no workflow has been red on $BRANCH past the ${GRACE_HOURS}h grace window"
exit 0
