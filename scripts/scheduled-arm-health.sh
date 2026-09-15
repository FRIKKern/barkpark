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
#   VACUOUS CRON     it succeeds on the cron, but a JOB-LEVEL read of that very
#                    run shows the cron SKIPPED a job and EXECUTED NOTHING THE
#                    PUSH/PR ARM DOES NOT ALREADY EXECUTE. RED. See below — this is the
#                    defect this reader reproduced one level up on its own day
#                    one, and a run-level `.conclusion` read is structurally
#                    blind to it.
#
#   ASSERTED NOTHING it succeeds on the cron with EVERY job in that run skipped.
#                    A run whose entire job graph was skipped concludes
#                    `success`. RED, and the loudest shape of the same disease.
#
# ─────────────────────────────────────────────────────────────────────────────
#  A RUN-LEVEL CONCLUSION IS NOT COVERAGE (task-c1148783a9ee36e7, 2026-09-15)
# ─────────────────────────────────────────────────────────────────────────────
# THIS FILE'S FIRST VERSION WOULD HAVE CERTIFIED ITS OWN SUBJECT AS `ok` WITHIN
# FIVE CRONS. It counted `.conclusion` at RUN level and never once read a job.
# The remedy landed for studio-journey-smoke in #18323 took the live arm off the
# cron (the credential it needs does not exist) and put `harness-self-test` on
# it instead. Measured on run 34910849865 (dbe6ba4d, the merge of #18323), the
# resulting job graph is:
#
#     success  Studio journey — self-test (fixtures, no network)
#     skipped  Studio journey — deployed (report mode, gates nothing)
#
# A RUN WHOSE ONLY EXECUTED JOB SUCCEEDED CONCLUDES `success`. So the very next
# cron would have flipped this workflow from NEVER SUCCEEDED to `ok` while the
# DEPLOYED journey — the only thing the cron was ever for — stayed exactly as
# unmeasured as it was during the 47-of-47 streak. The instrument would have
# printed the healthy word over the unhealthy state: the disease itself.
#
# THE RULE THAT WAS TRIED FIRST AND IS WRONG: "red any scheduled success that
# contains a skipped job". Measured the same day on the intended POSITIVE
# CONTROL, search-starter-smoke.yml run 34845674798 (scheduled, success; its
# scheduled arm genuinely runs — event=schedule total_count 50, received 50,
# success 50):
#
#     success  Journey smoke — live demo (report mode, never gates)
#     skipped  Finder unit specs (dep-free, no browser)
#     skipped  Journey smoke — self-test (fixtures, no network)
#
# TWO SKIPPED JOBS, AND IT IS THE HEALTHY ONE. A skipped-job rule reds both, and
# a guard that reds on everything discriminates nothing.
#
# THE RULE USED HERE — DOES THE CRON EXECUTE ANYTHING THE PR ARM DOES NOT? The
# job names EXECUTED (conclusion neither `skipped` nor `cancelled`) on the
# newest SCHEDULED success are compared against the job names executed on the
# newest NON-SCHEDULE success of the same workflow. If the scheduled set is a
# SUBSET of the non-schedule set, the cron adds no coverage that every push
# already buys, and calling it `ok` is the launder. On the two workflows above:
#
#     studio-journey-smoke   sched {self-test} SUBSET OF push {self-test}  -> VACUOUS CRON
#                            (and the cron SKIPPED "Studio journey — deployed")
#     search-starter-smoke   sched {live demo} NOT subset of push {...}    -> ok
#
# Same reader, opposite verdicts, on real runs. That is the discrimination a
# `.conclusion` count cannot make.
#
# AND THE SUBSET ALONE IS NOT ENOUGH — A RERUN IS NOT A LAUNDER. The red also
# requires that the scheduled run SKIPPED at least one job. A nightly that
# re-runs the whole suite the push arm runs, skipping nothing, is a REPEAT: it
# buys time-coverage rather than new coverage, which is weak but honest. Subset
# alone reds 10 of this tree's 29 cron'd workflows (measured 2026-09-15) and a
# verdict that fires on a third of the roster stops being read at all. Subset
# AND a skipped job reds 4, and every one of the 4 is a job the cron declares
# and then does not run. `ok (rerun)` is the noted, non-red half of that pair.
#
# WHERE A WORKFLOW HAS NO NON-SCHEDULE SUCCESS AT ALL, the cron is its only arm
# and cannot be redundant with an arm that does not exist: `ok`, with the reason
# printed. That is a stated exemption, not a silent one.
#
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
# DIR/<basename>.all.json, each the raw `actions/workflows/<file>/runs` payload,
# and DIR/jobs.<run_id>.json for the job-level read, each the raw
# `actions/runs/<id>/jobs` payload. A referenced jobs fixture that is ABSENT is
# UNREADABLE and exits 2 — never a quiet skip back onto the `ok` path.
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

# Fetch one RUN's jobs. Echoes the JSON body, or the literal UNREADABLE — which
# the caller turns into exit 2, never a skip. THE WHOLE POINT OF THIS FUNCTION:
# a run-level `.conclusion` is the conclusion of the jobs that ACTUALLY RAN, so
# a run whose substantive job was skipped concludes `success`. Only this read
# can tell those apart.
fetch_jobs() {
  local run_id="$1" body=""
  [ -n "$run_id" ] || { echo UNREADABLE; return 0; }
  if [ -n "$RUNS_DIR" ]; then
    local f="$RUNS_DIR/jobs.$run_id.json"
    [ -f "$f" ] || { echo UNREADABLE; return 0; }
    body="$(cat "$f")"
  else
    body="$(gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" 2>&1)" || { echo UNREADABLE; return 0; }
  fi
  jq -e 'has("jobs")' >/dev/null 2>&1 <<<"$body" || { echo UNREADABLE; return 0; }
  printf '%s' "$body"
}

# Job names a run EXECUTED, one per line. `skipped` and `cancelled` are the two
# conclusions that mean "this job did not assert anything"; every other
# conclusion (success, failure, neutral, timed_out) means it ran and produced a
# result, and only `executed` is what the subset rule below compares.
executed_job_names() { jq -r '[(.jobs // [])[] | select(.conclusion != "skipped" and .conclusion != "cancelled") | .name] | sort | unique | .[]'; }

# Newest success run id in a runs payload, optionally EXCLUDING one event.
# Prints nothing when there is none, and every caller distinguishes "none"
# from "could not read" rather than collapsing them.
newest_success_id() {
  local exclude_event="${1:-}"
  jq -r --arg ex "$exclude_event" '
    [ (.workflow_runs // [])[]
      | select(.conclusion == "success")
      | select($ex == "" or ((.event // "") != $ex)) ]
    | sort_by(.run_started_at // .created_at) | last | (.id // "") | tostring' \
    | sed 's/^null$//'
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
    # ── THE JOB-LEVEL READ ───────────────────────────────────────────────────
    # Everything above this point is a RUN-LEVEL `.conclusion` count, and a
    # run-level count cannot see a scheduled arm whose substantive job is
    # skipped: the run concludes `success` off whatever DID run. This is the
    # last gate before the word `ok` is printed, and it is the only gate that
    # looks at what the cron actually executed.
    s_win_id="$(printf '%s' "$sched" | newest_success_id)"
    if [ -z "$s_win_id" ]; then
      say "CANNOT MEASURE  $base — a scheduled success was counted but carries no run id to read jobs from."
      exit 2
    fi
    s_jobs="$(fetch_jobs "$s_win_id")"
    if [ "$s_jobs" = UNREADABLE ]; then
      say "CANNOT MEASURE  $base — jobs of scheduled run $s_win_id could not be read."
      say "                Printing ok here would be a verdict taken without looking."
      exit 2
    fi
    s_exec="$(printf '%s' "$s_jobs" | executed_job_names)"
    s_exec_n=0
    while IFS= read -r j; do [ -n "$j" ] || continue; s_exec_n=$((s_exec_n + 1)); done <<EOF
$s_exec
EOF

    if [ "$s_exec_n" -eq 0 ]; then
      REDS=$((REDS + 1))
      say "ASSERTED NOTHING $base — $window"
      say "                 newest scheduled success is run $s_win_id, and EVERY job in it was skipped."
      say "                 A run whose whole job graph skipped still concludes \`success\`. It measured nothing."
      continue
    fi

    o_win_id="$(printf '%s' "$allev" | newest_success_id schedule)"
    if [ -z "$o_win_id" ]; then
      OK_N=$((OK_N + 1))
      say "ok              $base — $window; newest scheduled success $s_last (${age_days}d)."
      say "                job read: run $s_win_id executed $s_exec_n job(s); no non-schedule success exists to"
      say "                compare against, so the cron is this workflow's only arm and cannot be redundant."
      continue
    fi
    o_jobs="$(fetch_jobs "$o_win_id")"
    if [ "$o_jobs" = UNREADABLE ]; then
      say "CANNOT MEASURE  $base — jobs of non-schedule run $o_win_id could not be read."
      exit 2
    fi
    o_exec="$(printf '%s' "$o_jobs" | executed_job_names)"

    UNIQUE_TO_CRON=""
    while IFS= read -r j; do
      [ -n "$j" ] || continue
      printf '%s\n' "$o_exec" | grep -Fxq -- "$j" || UNIQUE_TO_CRON="$UNIQUE_TO_CRON$j
"
    done <<EOF
$s_exec
EOF

    s_skipped="$(printf '%s' "$s_jobs" | jq -r '[(.jobs // [])[] | select(.conclusion == "skipped") | .name] | sort | unique | .[]')"
    s_skipped_n=0
    while IFS= read -r j; do [ -n "$j" ] || continue; s_skipped_n=$((s_skipped_n + 1)); done <<EOF
$s_skipped
EOF

    # A CRON THAT RERUNS THE SAME JOB IS NOT THE DISEASE. When the scheduled run
    # executed everything the workflow has (nothing skipped) and those jobs also
    # run on push, the cron is a REPEAT — it catches rot that arrives with time
    # rather than with a diff, which is a real, if weak, reason to exist. Noted,
    # never red. Measured 2026-09-15 this separates 4 genuine launders from 6
    # plain nightly reruns among this tree's 29 cron'd workflows; without the
    # split the reader reds 10 of 29 and its verdict stops meaning anything.
    if [ -z "$UNIQUE_TO_CRON" ] && [ "$s_skipped_n" -eq 0 ]; then
      OK_N=$((OK_N + 1))
      say "ok (rerun)      $base — $window; newest scheduled success $s_last (${age_days}d)."
      say "                job read: scheduled run $s_win_id executed the SAME job(s) the push arm executes and"
      say "                skipped none. A repeat of a full run, not a launder — it buys time-coverage only."
      continue
    fi

    if [ -z "$UNIQUE_TO_CRON" ]; then
      REDS=$((REDS + 1))
      say "VACUOUS CRON    $base — $window"
      say "                SKIPPED on the cron: $(printf '%s' "$s_skipped" | tr '\n' '|' | sed 's/|$//')"
      say "                It SUCCEEDS on the cron, and that success asserts nothing a push does not."
      say "                scheduled run $s_win_id executed: $(printf '%s' "$s_exec" | tr '\n' '|' | sed 's/|$//')"
      say "                non-schedule run $o_win_id executed: $(printf '%s' "$o_exec" | tr '\n' '|' | sed 's/|$//')"
      say "                Every job the cron ran, the push arm already runs. The cron buys NO coverage,"
      say "                and a run-level conclusion count would have printed 'ok' over exactly this."
      continue
    fi

    OK_N=$((OK_N + 1))
    say "ok              $base — $window; newest scheduled success $s_last (${age_days}d)."
    say "                job read: scheduled run $s_win_id executed $(printf '%s' "$UNIQUE_TO_CRON" | tr '\n' '|' | sed 's/|$//') which the"
    say "                non-schedule arm (run $o_win_id) does not. The cron buys coverage nothing else buys."
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
