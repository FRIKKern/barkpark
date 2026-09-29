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
#   STALE            it has succeeded, but not within its ALLOWED SILENCE (derived
#                    from its own cron, floor --stale-days — see below), while
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
#   --min-runs N (default 5) · --stale-days N (default 21, the FLOOR of the
#   cron-derived allowed silence) · --slack-hours N (default 48) · --strict-never-ran
#   --repo owner/name (default: read from .github/required-checks.json)
#   --now ISO8601 (default: now — pinned by the self-test so it cannot rot)
#
# OFFLINE FIXTURES. --runs-dir DIR reads DIR/<basename>.schedule.json and
# DIR/<basename>.all.json, each the raw `actions/workflows/<file>/runs` payload
# (DIR/<basename>.all.page<N>.json for the deeper unfiltered pages; one that the
# walk needs — total_count says it exists — and that is absent is UNREADABLE),
# and DIR/jobs.<run_id>.json for the job-level read, each the raw
# `actions/runs/<id>/jobs` payload. A referenced jobs fixture that is ABSENT is
# UNREADABLE and exits 2 — never a quiet skip back onto the `ok` path.
# That is the route the self-test uses; it never touches the network.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THIS READER DOES NOT READ ITSELF (task-c3b8d7a5e1745a17, measured 2026-09-25)
# ─────────────────────────────────────────────────────────────────────────────
# scheduled-arm-health.yml is itself a cron'd workflow, and until this change it
# was on its own roster. Its run exits 1 whenever ANY row is red, so its own
# scheduled history is red on every day some other workflow is — and the next
# run then reads that history as NEVER SUCCEEDED and reds on it. That is a
# LATCH: fix every other row and this one still reds, forever, because its only
# evidence is its own past verdicts. Measured: 8 of 8 scheduled runs
# 2026-09-17..24 failed, and on run 36001198282 its own row was one of the 10
# reds. Its silence is watched elsewhere (cron-overdue-probe.sh's table carries
# a row for it), and its verdict IS the run it is printing, so the self row is
# excluded by name and the exclusion is PRINTED, never silent. SAH_SELF names
# the file (default scheduled-arm-health.yml) so the hermetic test can pin it.
#
# ─────────────────────────────────────────────────────────────────────────────
#  A SKIP THE CRON NEVER DECLARED IS NOT A LAUNDER (same task, same day)
# ─────────────────────────────────────────────────────────────────────────────
# VACUOUS CRON reds a scheduled run that SKIPPED a job while executing nothing
# the push arm does not. On run 36001198282 four of its five VACUOUS rows were
# skips the cron never declared:
#   cron-overdue-probe / crown-reconcile / main-gate-watch — the skipped job is
#     the `… harness`, gated `if: github.event_name == 'pull_request'`: it tests
#     a PR's diff, and a cron has no diff.
#   main-gate-watch / twoslash — the skipped jobs are `Report … to a human`,
#     gated on `failure()`: a reporter is skipped on EVERY green run, of any
#     event, by design.
# Those are the "rerun" shape (the cron re-executes the watcher on a clock),
# not the studio-journey-smoke shape (a job the scheduled arm could run and
# does not). So a skipped job whose `if:` is a failure()/cancelled() reporter,
# or is confined to pull_request (contains `github.event_name ==
# 'pull_request'` and no `||`), is EXCUSED and named as such; every other skip
# still counts. studio-journey-smoke's `deployed` job is gated to
# workflow_dispatch, so it still counts and that row stays VACUOUS. The `if:`
# is read from the workflow file with python3+PyYAML (preinstalled on
# ubuntu-latest); when that read is unavailable NOTHING is excused and the
# line says so — the old, stricter verdict, never a quieter one.
#
# ─────────────────────────────────────────────────────────────────────────────
#  A FILTERED LISTING CAN LAG; A FLAT THRESHOLD CANNOT READ A MONTHLY CRON
#  (task-1662605eac0c70ee, measured 2026-09-25)
# ─────────────────────────────────────────────────────────────────────────────
# Two false STALE rows on run 36001198282 (2026-09-24):
#
#   breakglass-watch.yml (cron */30, also push/PR). This file ALREADY asked the
#   server for `event=schedule&status=completed`. That listing answered
#   total_count=207 with its newest success on 2026-08-23 — while scheduled
#   successes existed every few hours (e.g. run 36122169740, 2026-09-25T10:06Z).
#   The same query answered total_count=723 a day later, and on 2026-09-25T14:46Z
#   `…&status=completed&event=schedule` answered total 703 / newest 20:44Z
#   (09-24) while `…&event=schedule` answered 723 / newest 10:06Z (09-25) in the
#   same minute. The FILTERED listing is served from an index that can lag the
#   runs themselves by weeks. It is not "the newest N runs, then filtered":
#   that reader never existed here.
#   So: (1) status is filtered CLIENT-side, one fewer server filter; (2) the
#   schedule rows of the unfiltered listing are UNIONED in, by id; (3) when the
#   row would still be STALE, the unfiltered listing is walked further back
#   (up to $WALK_PAGES pages) before the red is printed, because a push-heavy
#   workflow's first unfiltered page can hold no scheduled run at all. Every
#   row rescued this way is COUNTED on the line ("+N from the unfiltered
#   listing"), so a lagging index is visible, never absorbed silently.
#
#   renew-mail-cert.yml (cron "17 4 1 * *"). Last scheduled success 09-01, next
#   fire 10-01. A flat 21-day threshold reds it on day 22 of every month for
#   doing exactly what it was told. The allowed silence is now DERIVED from the
#   workflow's own cron(s): the longest interval between consecutive fires of
#   the union of its schedules (several crons = the tightest schedule that still
#   bounds the gap), plus --slack-hours for GitHub's late and dropped crons,
#   and never less than --stale-days — that floor is a tolerance for a failure
#   streak on a frequent cron, which the cron text cannot supply. Monthly:
#   31d + 48h = 33d. Every row prints the cron(s), the gap and the threshold.
#   The gap is computed by python3 (stdlib only). Where it cannot be computed
#   the row uses the --stale-days floor and SAYS so — the old, stricter verdict,
#   never a quieter one.
#
# EXIT: 0 no red · 1 at least one red · 2 cannot measure.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${SAH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKFLOWS_DIR="$ROOT/.github/workflows"
MIN_RUNS=5
STALE_DAYS=21
SLACK_HOURS=48
WALK_PAGES=5
STRICT_NEVER_RAN=0
RUNS_DIR=""
ONLY=""
REPO_OVERRIDE=""
NOW_ISO=""
SELF="${SAH_SELF:-scheduled-arm-health.yml}"

while [ $# -gt 0 ]; do
  case "$1" in
    --min-runs) MIN_RUNS="${2:-}"; shift 2 ;;
    --stale-days) STALE_DAYS="${2:-}"; shift 2 ;;
    --slack-hours) SLACK_HOURS="${2:-}"; shift 2 ;;
    --strict-never-ran) STRICT_NEVER_RAN=1; shift ;;
    --runs-dir) RUNS_DIR="${2:-}"; shift 2 ;;
    --workflow) ONLY="${2:-}"; shift 2 ;;
    --repo) REPO_OVERRIDE="${2:-}"; shift 2 ;;
    --now) NOW_ISO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "scheduled-arm-health: REFUSING — unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$STALE_DAYS$SLACK_HOURS$MIN_RUNS" in *[!0-9]*|'') echo "scheduled-arm-health: REFUSING — --stale-days/--slack-hours/--min-runs take whole numbers" >&2; exit 2 ;; esac
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

# Fetch one workflow's runs for one event scope (and, for `all`, one page).
# Echoes the JSON body, or the literal UNREADABLE — which the caller turns into
# exit 2, never a skip. NO server-side status filter: see "A FILTERED LISTING
# CAN LAG" above; `completed` is selected client-side in summarise().
fetch_runs() {
  local base="$1" scope="$2" page="${3:-1}" body="" q=""
  if [ -n "$RUNS_DIR" ]; then
    local f="$RUNS_DIR/$base.$scope.json"
    [ "$page" -eq 1 ] || f="$RUNS_DIR/$base.$scope.page$page.json"
    [ -f "$f" ] || { echo UNREADABLE; return 0; }
    body="$(cat "$f")"
  else
    q="per_page=100&page=$page"
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

# total_count <TAB> received <TAB> completed <TAB> success <TAB> failure <TAB> newest-success-iso
# A row with no `status` (an older fixture) counts as completed.
summarise() {
  jq -r '
    (.workflow_runs // []) as $all
    | [ $all[] | select((.status // "completed") == "completed") ] as $r
    | [ (.total_count // ($all|length)),
        ($all|length),
        ($r|length),
        ([$r[]|select(.conclusion=="success")]|length),
        ([$r[]|select(.conclusion=="failure")]|length),
        ([$r[]|select(.conclusion=="success")|(.run_started_at // .created_at)]|sort|last // "")
      ] | @tsv'
}

# job_gates <workflow-file> — one `name<TAB>if` line per job, `name` being the
# job's `name:` (or its key when it has none), which is what the jobs API
# reports for a non-matrix job. Prints the literal UNAVAILABLE when the file
# cannot be parsed here; the caller then excuses nothing.
job_gates() {
  python3 - "$1" 2>/dev/null <<'PY' || echo UNAVAILABLE
import sys, yaml
d = yaml.load(open(sys.argv[1]), Loader=yaml.BaseLoader) or {}
jobs = d.get("jobs") or {}
if not isinstance(jobs, dict):
    raise SystemExit(1)
for key, job in jobs.items():
    if not isinstance(job, dict):
        continue
    name = str(job.get("name", key)).replace("\t", " ").replace("\n", " ")
    cond = str(job.get("if", "")).replace("\t", " ").replace("\n", " ")
    print(name + "\t" + cond)
PY
}

# excused_skip <if-expression> — true when a skip under this `if:` is one the
# cron never declared: a failure()/cancelled() reporter, or a job confined to
# pull_request. See the header block "A SKIP THE CRON NEVER DECLARED".
excused_skip() {
  local cond="$1"
  case "$cond" in *'failure()'*|*'cancelled()'*) return 0 ;; esac
  case "$cond" in *'||'*) return 1 ;; esac
  case "$cond" in
    *"github.event_name == 'pull_request'"*|*'github.event_name == "pull_request"'*) return 0 ;;
  esac
  return 1
}

# union_schedule <filtered-listing-json> <unfiltered-page-json> — the filtered
# listing plus every `event == schedule` row of the unfiltered page whose id it
# does not already carry. Keeps the filtered listing's total_count and records
# how many rows were added as .rescued, so the caller can print it.
# Both documents go in on stdin (jq -s): a 100-run page as --argjson overflows
# ARG_MAX, measured on the live read of absent-context-census.yml.
union_schedule() {
  jq -c -s '
    .[1] as $extra
    | .[0]
    | (.workflow_runs // []) as $mine
    | ([ $mine[] | .id | select(. != null) ]) as $ids
    | [ ($extra.workflow_runs // [])[]
        | select((.event // "") == "schedule" and .id != null)
        | select(.id as $i | ($ids | index($i)) == null) ] as $add
    | .workflow_runs = ($mine + $add)
    | .rescued = ((.rescued // 0) + ($add | length))' <<<"$1
$2"
}

# oldest_iso <runs-json> — the oldest start time on one page, empty when none.
oldest_iso() { jq -r '[(.workflow_runs // [])[] | (.run_started_at // .created_at // empty)] | sort | first // ""'; }

# cron_exprs <workflow-file> — each `- cron:` value, one per line, unquoted.
cron_exprs() {
  sed -n -E 's/^[[:space:]]*-[[:space:]]*cron:[[:space:]]*//p' "$1" \
    | sed -E 's/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//; s/[[:space:]]+$//'
}

# cron_max_gap <expr>... — the longest interval, in seconds, between consecutive
# fires of the UNION of the given crons (UTC, the way GitHub reads them). Prints
# nothing when python3 is missing or an expression does not parse; the caller
# then falls back to the --stale-days floor and says so.
cron_max_gap() {
  python3 - "$@" 2>/dev/null <<'PY'
import sys, datetime
NAMES = {"jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,"jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12,
         "sun":0,"mon":1,"tue":2,"wed":3,"thu":4,"fri":5,"sat":6}
def field(s, lo, hi):
    out = set()
    for part in s.lower().split(","):
        step = 1
        if "/" in part:
            part, st = part.split("/", 1); step = int(st)
            if step < 1: raise ValueError(s)
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            x, y = part.split("-", 1); a, b = int(NAMES.get(x, x)), int(NAMES.get(y, y))
        else:
            a = int(NAMES.get(part, part)); b = hi if step > 1 else a
        if a < lo or b > hi or a > b: raise ValueError(s)
        out.update(range(a, b + 1, step))
    return out
def fires(expr, start, days):
    f = expr.split()
    if len(f) != 5: raise ValueError(expr)
    mi, hr = field(f[0], 0, 59), field(f[1], 0, 23)
    dom, mon = field(f[2], 1, 31), field(f[3], 1, 12)
    dow = {d % 7 for d in field(f[4], 0, 7)}
    dom_star, dow_star = f[2].startswith("*"), f[4].startswith("*")
    for n in range(days):
        d = start + datetime.timedelta(days=n)
        if d.month not in mon: continue
        in_dom, in_dow = d.day in dom, (d.isoweekday() % 7) in dow
        # Vixie cron: when BOTH day fields are restricted, either one matches.
        ok = (in_dom and in_dow) if (dom_star or dow_star) else (in_dom or in_dow)
        if not ok: continue
        base = datetime.datetime(d.year, d.month, d.day)
        for h in sorted(hr):
            for m in sorted(mi):
                yield base + datetime.timedelta(hours=h, minutes=m)
# Nine years from a fixed start covers every month length and two leap days,
# so even "0 0 29 2 *" has a gap to measure.
start, days = datetime.date(2025, 1, 1), 9 * 366
times = set()
for e in sys.argv[1:]:
    times.update(fires(e, start, days))
t = sorted(times)
if len(t) < 2: raise SystemExit(1)
print(int(max((b - a).total_seconds() for a, b in zip(t, t[1:]))))
PY
}

# human duration for seconds: 1800 -> 30m, 90000 -> 1d1h
dur() {
  local s="$1" d h m
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%sd%s' "$d" "$([ "$h" -gt 0 ] && printf '%sh' "$h")"
  elif [ "$h" -gt 0 ]; then printf '%sh%s' "$h" "$([ "$m" -gt 0 ] && printf '%sm' "$m")"
  else printf '%sm' "$m"; fi
}

say() { printf '%s\n' "$*"; }

say "scheduled-arm-health — roster = the tree at ${ROOT}, as of $NOW_ISO"
say "  min-runs=$MIN_RUNS  stale-days(floor)=$STALE_DAYS  slack-hours=$SLACK_HOURS  strict-never-ran=$STRICT_NEVER_RAN  source=${RUNS_DIR:-live API ($REPO)}"
say ""

FILES=""
DENOM=0
SELF_SEEN=0
for f in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  DENOM=$((DENOM + 1))
  grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$f" || continue
  b="$(basename "$f")"
  if [ -n "$ONLY" ] && [ "$b" != "$ONLY" ]; then continue; fi
  if [ "$b" = "$SELF" ]; then SELF_SEEN=1; continue; fi
  FILES="$FILES$b
"
done

CRONNED=0
while IFS= read -r b; do [ -n "$b" ] || continue; CRONNED=$((CRONNED + 1)); done <<EOF
$FILES
EOF

say "enumerated $DENOM workflow files; $CRONNED declare a cron${ONLY:+ (scoped to --workflow $ONLY)}"
if [ "$SELF_SEEN" -eq 1 ]; then
  say "self            $SELF — NOT READ: this reader's own history is its past verdicts, so reading it"
  say "                latches (one red makes every later run NEVER SUCCEEDED). Its silence is"
  say "                cron-overdue-probe.sh's row; its verdict is this run."
fi
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

  # ── ALLOWED SILENCE, FROM THIS WORKFLOW'S OWN CRON(S) ─────────────────────
  crons="$(cron_exprs "$WORKFLOWS_DIR/$base")"
  cron_list="$(printf '%s' "$crons" | tr '\n' '|' | sed 's/|$//; s/|/", "/g')"
  gap=""
  cron_args=()
  while IFS= read -r c; do [ -n "$c" ] && cron_args+=("$c"); done <<EOF
$crons
EOF
  [ "${#cron_args[@]}" -eq 0 ] || gap="$(cron_max_gap "${cron_args[@]}")"
  floor_s=$((STALE_DAYS * 86400))
  if [ -n "$gap" ]; then
    allowed_s=$((gap + SLACK_HOURS * 3600))
    allowed_how="cron \"$cron_list\" max gap $(dur "$gap") + ${SLACK_HOURS}h slack"
    if [ "$allowed_s" -lt "$floor_s" ]; then
      allowed_s=$floor_s
      allowed_how="$allowed_how, raised to the --stale-days floor ${STALE_DAYS}d"
    fi
  else
    allowed_s=$floor_s
    allowed_how="cron \"$cron_list\" gap NOT COMPUTED (python3 missing or cron unparsed) — --stale-days floor ${STALE_DAYS}d"
  fi

  # ── THE FILTERED LISTING CAN LAG: UNION THE UNFILTERED ROWS ─────────────────
  sched="$(union_schedule "$sched" "$allev")" || {
    say "CANNOT MEASURE  $base — the schedule and all-events listings could not be merged."
    exit 2
  }
  walked=1
  while :; do
    IFS="$(printf '\t')" read -r s_tc s_got s_done s_ok s_fail s_last <<EOF
$(printf '%s' "$sched" | summarise)
EOF
    last_epoch="$(iso_epoch "$s_last")"
    # Walk deeper only while the row would be STALE (or has no success yet)
    # and the unfiltered listing still has older runs to show.
    if [ -n "$last_epoch" ] && [ $((NOW_EPOCH - last_epoch)) -le "$allowed_s" ]; then break; fi
    [ "$walked" -lt "$WALK_PAGES" ] || break
    a_total="$(jq -r '.total_count // 0' <<<"$allev")"
    [ "$((walked * 100))" -lt "${a_total:-0}" ] || break
    walked=$((walked + 1))
    deeper="$(fetch_runs "$base" all "$walked")"
    if [ "$deeper" = UNREADABLE ]; then
      say "CANNOT MEASURE  $base — page $walked of the unfiltered runs listing could not be read."
      say "                The filtered listing alone said this row is stale, and it can lag; not looking is not a verdict."
      exit 2
    fi
    sched="$(union_schedule "$sched" "$deeper")" || {
      say "CANNOT MEASURE  $base — page $walked of the unfiltered listing could not be merged."
      exit 2
    }
    d_oldest="$(printf '%s' "$deeper" | oldest_iso)"
    # A page that already reaches back past the newest known success cannot be
    # followed by a newer one: stop.
    if [ -n "$last_epoch" ] && [ -n "$d_oldest" ]; then
      d_epoch="$(iso_epoch "$d_oldest")"
      [ -z "$d_epoch" ] || [ "$d_epoch" -gt "$last_epoch" ] || { IFS="$(printf '\t')" read -r s_tc s_got s_done s_ok s_fail s_last <<EOF
$(printf '%s' "$sched" | summarise)
EOF
        break; }
    fi
  done
  rescued="$(jq -r '.rescued // 0' <<<"$sched")"
  IFS="$(printf '\t')" read -r _ a_got a_done a_ok a_fail _ <<EOF
$(printf '%s' "$allev" | summarise)
EOF

  window="scheduled total_count=$s_tc received=$s_got completed=$s_done · success=$s_ok failure=$s_fail"
  [ "${rescued:-0}" -eq 0 ] || window="$window (+$rescued scheduled row(s) the filtered listing did NOT return, found in $walked page(s) of the unfiltered listing — the filtered index LAGGED)"
  [ "$s_got" -lt "$s_tc" ] && window="$window (TRUNCATED READ: $s_got of $s_tc — every verdict below is relative to the $s_got read)"
  a_got="$a_done"

  if [ "${s_done:-0}" -eq 0 ]; then
    NEVER_RAN_N=$((NEVER_RAN_N + 1))
    say "NEVER RAN       $base — declares a cron and has ZERO completed scheduled runs."
    say "                all events: success=$a_ok failure=$a_fail of $a_got read."
    say "                A cron added recently looks identical to one GitHub has disabled; decide which."
    [ "$STRICT_NEVER_RAN" -eq 1 ] && REDS=$((REDS + 1))
    continue
  fi

  if [ "${s_ok:-0}" -eq 0 ]; then
    if [ "${s_done:-0}" -ge "$MIN_RUNS" ]; then
      REDS=$((REDS + 1))
      say "NEVER SUCCEEDED $base — $window"
      say "                NOT ONE of the $s_done completed scheduled runs read here succeeded."
      if [ "${a_ok:-0}" -gt 0 ]; then
        say "                LAUNDERED: across ALL events this workflow reads success=$a_ok of $a_got —"
        say "                those greens are a DIFFERENT ARM on a different event. A reader that does not"
        say "                split by event will call this workflow healthy. That is the whole defect."
      fi
      say "                A scheduled arm that has never once succeeded is not a flake; it has never worked."
    else
      say "young           $base — $window; $s_done runs is under --min-runs=$MIN_RUNS, no verdict yet."
    fi
    continue
  fi

  last_epoch="$(iso_epoch "$s_last")"
  if [ -z "$last_epoch" ]; then
    say "CANNOT MEASURE  $base — newest scheduled success timestamp '$s_last' did not parse."
    exit 2
  fi
  age_s=$((NOW_EPOCH - last_epoch))
  age_days=$((age_s / 86400))
  if [ "$age_s" -gt "$allowed_s" ]; then
    REDS=$((REDS + 1))
    say "STALE           $base — $window; newest scheduled success $s_last is $(dur "$age_s") old (> allowed $(dur "$allowed_s"))."
    say "                allowed silence: $allowed_how."
    [ "$walked" -le 1 ] || say "                confirmed against $walked page(s) of the unfiltered listing: no newer scheduled success."
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
      say "ok              $base — $window; newest scheduled success $s_last (${age_days}d; allowed $(dur "$allowed_s"): $allowed_how)."
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
      grep -Fxq -- "$j" <<<"$o_exec" || UNIQUE_TO_CRON="$UNIQUE_TO_CRON$j
"
    done <<EOF
$s_exec
EOF

    s_skipped_all="$(printf '%s' "$s_jobs" | jq -r '[(.jobs // [])[] | select(.conclusion == "skipped") | .name] | sort | unique | .[]')"
    s_skipped=""
    s_excused=""
    gates=""
    gate_note=""
    if [ -n "$s_skipped_all" ]; then
      gates="$(job_gates "$WORKFLOWS_DIR/$base")"
      if [ "$gates" = UNAVAILABLE ]; then
        gates=""
        gate_note="(job if: read unavailable — every skip counted)"
      fi
    fi
    while IFS= read -r j; do
      [ -n "$j" ] || continue
      cond="$(printf '%s\n' "$gates" | awk -F'\t' -v n="$j" '$1 == n { sub(/^[^\t]*\t/, ""); print; exit }')"
      if [ -n "$gates" ] && [ -n "$cond" ] && excused_skip "$cond"; then
        s_excused="$s_excused$j
"
      else
        s_skipped="$s_skipped$j
"
      fi
    done <<EOF
$s_skipped_all
EOF
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
      say "ok (rerun)      $base — $window; newest scheduled success $s_last (${age_days}d; allowed $(dur "$allowed_s"): $allowed_how)."
      say "                job read: scheduled run $s_win_id executed the SAME job(s) the push arm executes and"
      say "                skipped none. A repeat of a full run, not a launder — it buys time-coverage only."
      [ -z "$s_excused" ] || say "                excused skips (reporter or pull_request-only, never the cron's job): $(printf '%s' "$s_excused" | tr '\n' '|' | sed 's/|$//')"
      [ -z "$gate_note" ] || say "                $gate_note"
      continue
    fi

    if [ -z "$UNIQUE_TO_CRON" ]; then
      REDS=$((REDS + 1))
      say "VACUOUS CRON    $base — $window"
      say "                SKIPPED on the cron: $(printf '%s' "$s_skipped" | tr '\n' '|' | sed 's/|$//')"
      [ -z "$s_excused" ] || say "                excused skips (reporter or pull_request-only): $(printf '%s' "$s_excused" | tr '\n' '|' | sed 's/|$//')"
      [ -z "$gate_note" ] || say "                $gate_note"
      say "                It SUCCEEDS on the cron, and that success asserts nothing a push does not."
      say "                scheduled run $s_win_id executed: $(printf '%s' "$s_exec" | tr '\n' '|' | sed 's/|$//')"
      say "                non-schedule run $o_win_id executed: $(printf '%s' "$o_exec" | tr '\n' '|' | sed 's/|$//')"
      say "                Every job the cron ran, the push arm already runs. The cron buys NO coverage,"
      say "                and a run-level conclusion count would have printed 'ok' over exactly this."
      continue
    fi

    OK_N=$((OK_N + 1))
    say "ok              $base — $window; newest scheduled success $s_last (${age_days}d; allowed $(dur "$allowed_s"): $allowed_how)."
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
