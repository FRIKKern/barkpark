#!/usr/bin/env bash
# cron-overdue-probe.sh — cron silence is invisible; this makes it a red check.
#
# WHAT WAS MEASURED, 2026-09-03 (task-86340d69fc2f36b8, by main and lead-studio-3)
# GitHub Actions cron on a busy repo is best-effort delivery, and on this repo it
# is delivered every 2-5 h or not at all:
#   task-lease-renew   (*/20)  ran ZERO times in 3 h — the claim sweep was dark
#   main-gate-watch    (*/30)  fired 4 times in 12 h, against 24 expected
#   paper-readers      (05:17) did not run at all on 2026-09-03
#   absent-context-census      last ran 04:32Z
# A watch that does not fire reads exactly like a watch with nothing to report.
# That is the whole failure: green by absence.
#
# THE INVARIANT THIS PROBE ENFORCES
#   A CRITICAL-CADENCE workflow has a run newer than 3x its schedule interval.
# Three times, not one: cron delivery is genuinely jittery and a 1x bound would
# red on healthy jitter, which is how a probe gets muted. 3x of */30 is 90
# minutes — well inside the 2-5 h silences actually measured, so the bound is
# loose enough to be quiet and tight enough to have caught every one of them.
#
# AND SILENCE IS NEVER A PASS. A critical workflow with NO run row at all is the
# WORST case, not the absent one: it reds (arm c5). This file exists because
# "nothing came back" was being read as "nothing to say".
#
# CLASSIFICATION, NOT A GLOBAL RULE. A weekly changelog that slips six hours is
# not a defect, and reddening on it would train the fleet to ignore this probe —
# the same mistake absent-context-census.sh made for 93 consecutive runs. Every
# scheduled workflow in the tree therefore carries a CLASS and a dated line
# below, and only `critical` rows are bounded. A scheduled workflow that is NOT
# in the table is a HARD REFUSAL (exit 2), never a silent skip: an unclassified
# workflow is the one nobody has thought about.
#
# THE QUEUED-RUN TRAP, and it is shared with task-82059e31bcccdbd7. "It has a
# run row" is not "it ran". Eight `status: queued` records from 2026-08-07 and
# 2026-08-19 sit in this repo's run list permanently — GitHub answers 409
# "has not been queued yet" to both cancel paths — so a phantom row is evidence
# of nothing and is not accepted as proof of a firing (arm c6).
#
# A FALLBACK THAT ONLY SHOUTS IS NOT A FALLBACK (2026-09-06, task-f94a1d96238b18e4).
# The 90-minute bound above was written against a DECLARED */30 schedule. What
# GitHub actually delivers for main-gate-watch.yml is every 2.1-4.7 HOURS — 14
# consecutive scheduled runs 2026-09-05T07:48Z..2026-09-06T08:02Z, never once at
# the declared cadence (measured in that workflow's own header, PR #16390). So
# this probe reddened main by CONSTRUCTION between deliveries: push:main run
# 34025016921 printed `newest run is 92m old, bound is 3x = 90m` and exited 1 on
# a repo where nothing was wrong. A probe that is red on a platform cadence
# teaches the fleet to dismiss the one alarm watching a silent watch.
#
# The remedy is not a looser bound — that would make a genuinely dead
# main-gate-watch invisible for up to 15 hours. The remedy is that the probe
# DOES what its own table already claims: for main-gate-watch.yml its line says
# "this probe is its fallback". So when a critical workflow that is CRON-ONLY
# (no push: arm, an honoured push-refused: guard) is past its bound, the probe
# now FIRES it — `gh workflow run <file> --ref main` — prints the dispatched run
# id, and reds only if the dispatch itself fails or the dispatched run never
# appears. Cron silence still cannot hide: the workflow runs either way.
#
# WHY A DISPATCH IS SAFE WHERE A push: ARM IS NOT (D721). The push arm was
# measured harmful because it fired ~15-20 s after a merge, when GitHub had
# created no check-run rows on the new tip at all, and main-gate-watch's MISSING
# logic red by construction on the empty payload (2 of 2 runs red on tip
# 026c5b1d78 while main was green). A dispatch is a different animal on both
# counts: it runs the same code the SCHEDULE runs, against whatever tip is
# current when this probe fires — which is minutes into the run, not seconds —
# and since wave 61 an absent required row while any run on the tip is still in
# flight reports WAITING (exit 2), not MISSING. main-gate-watch.yml's own header
# names the remedy in these words: "read the newest COMPLETED run ... or fire
# workflow_dispatch; do NOT add a push: arm". Its triggers are NOT touched here.
#
# AND IT DOES NOT CANCEL WHAT IT IS PROTECTING. Measured while building the arm:
# five dispatches of main-gate-watch inside three minutes left ONE run and FOUR
# `cancelled` — its concurrency group keeps one pending run and a newer queue
# entry cancels the older. A cancelled watch is a tip with no verdict, the very
# thing it exists to report. So the arm re-reads the live run list immediately
# before firing and skips the dispatch while any non-completed run under 24 h
# old exists (24 h because of the phantom-queued trap above — a permanently
# queued row must not hold that guard open forever).
#
# AND THE DISPATCH ARM NEVER WEAKENS A push-ARMED WORKFLOW. A critical workflow
# that carries `push: branches: [main]` already has a reliable trigger, so being
# past bound means something is genuinely wrong with it: those SCREAM exactly as
# before, and are never dispatched. Nor does the arm touch the no-run-row case
# (c5) — a workflow that has NEVER produced a row is the worst case, and firing
# one by hand would launder it.
#
# USAGE
#   bash scripts/cron-overdue-probe.sh                       # live, this repo
#   bash scripts/cron-overdue-probe.sh --runs-file <ndjson> --now <iso>   # hermetic
#   bash scripts/cron-overdue-probe.sh --table <file>        # override the table
#   bash scripts/cron-overdue-probe.sh --no-dispatch         # report only, never fire
#   bash scripts/cron-overdue-probe.sh --selftest            # no network
#
# THE HERMETIC INPUT IS RAW. --runs-file takes the newest run row per workflow
# exactly as the API emits it — {"path": ".github/workflows/x.yml", "status":
# "...", "created_at": "..."} — never a pre-computed age, because a fixture that
# arrives already judged proves only that the harness can read its own answer.
#
# EXIT CODES
#   0 every critical-cadence workflow fired inside its bound
#   1 OVERDUE — at least one critical workflow is silent past 3x its interval
#   2 the table and the tree disagree, a fallback is missing, or usage
#   3 the run list could not be read — UNKNOWN, never reported as fired
#
# ENV
#   CRON_PROBE_GH          the gh binary (stubbed by the selftest's dispatch arm)
#   CRON_PROBE_REPO_ROOT   override the repo root (the selftest runs a MUTATED
#                          copy of this file from a temp dir and still needs the
#                          real tree for the table/fallback reads)
#   CRON_PROBE_POLL_TRIES  how many times to look for the dispatched run (12)
#   CRON_PROBE_POLL_SLEEP  seconds between those looks (5)

set -uo pipefail

REPO_ROOT="${CRON_PROBE_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
REPO="${CRON_PROBE_REPO:-FRIKKern/barkpark}"
TABLE_FILE=""
RUNS_FILE=""
NOW_ISO=""
MODE=report
OVERDUE_FACTOR=3
DISPATCH=1
# READ AT CALL TIME, never bound here. Binding `gh` at startup made the
# selftest's stub unreachable — it exports CRON_PROBE_GH after this file has
# already been sourced — and the first run of the dispatch arm went out over the
# real network and fired three real main-gate-watch runs. A stub that is not
# reached is a test that proves nothing, loudly.
gh_bin()     { printf '%s' "${CRON_PROBE_GH:-gh}"; }
poll_tries() { printf '%s' "${CRON_PROBE_POLL_TRIES:-12}"; }
poll_sleep() { printf '%s' "${CRON_PROBE_POLL_SLEEP:-5}"; }

# ── THE CLASSIFICATION TABLE ────────────────────────────────────────────────
# file|class|interval-minutes|dated note
#
# class:
#   critical  silence is a hole in a safety net. Bounded at OVERDUE_FACTOR x the
#             interval, and required to carry a trigger fallback (see
#             check_fallbacks) so cron is not its only way to fire.
#   periodic  an audit whose whole point is the sweep, not the minute. Lag is
#             accepted; listed so the tree is fully accounted for.
#   report    a digest. A day late is a day late.
#
# Every line was written on 2026-09-03 against the 16 workflows carrying a
# `schedule:` trigger on origin/main that day. The task that ordered this work
# said 14; the tree had 16 (task-lease-renew gained its push arm in #15757 and
# is counted here as critical-with-fallback).
DEFAULT_TABLE='absent-context-census.yml|periodic|360|2026-09-03: 6 h absence audit. Its own harness (absent-context-census.test.sh §7) asserts this workflow is SCHEDULE-ONLY, so a push arm is forbidden here by a committed test; a 6 h sweep tolerates a 6 h lag by construction.
breakglass-watch.yml|critical|30|2026-09-03: watches whether branch protection was broken open. Carries push: branches [main] — cron silence cannot hide an unrestored breakglass across a merge.
chronicle-paper.yml|report|1440|2026-09-03: nightly narrative digest. A late chronicle is a late chronicle.
codebase-intel.yml|report|10080|2026-09-03: weekly intelligence sweep. Weekly cadence, weekly tolerance.
cron-overdue-probe.yml|critical|60|2026-09-03: this probe itself. Hourly, and it carries push: branches [main] — a silence watch delivered only by the mechanism it watches is a smoke detector wired to the fire. It appeared in this table because its own table/tree check REFUSED the first live run that did not classify it.
crown-reconcile.yml|periodic|360|2026-09-03: 6 h reconciliation sweep; carries push: branches [main] already.
deploy-harnesses.yml|periodic|1440|2026-09-06: nightly re-run of the deploy harnesses (cron 03:20Z) so a rot in deploy/ is seen within a day; carries push: branches [main]. Added when cron-overdue-probe c1 reddened main on the three schedules landed after the 2026-09-03 table.
elixir-nightly.yml|report|1440|2026-09-03: the long Elixir suite, nightly. Its reds are found the next morning either way.
grip-suite.yml|periodic|1440|2026-09-06: nightly Grip suite (cron 03:25Z); carries push: branches [main]. Same 2026-09-06 c1 red as deploy-harnesses.
main-gate-watch.yml|critical|30|2026-09-03: the second scream on main tip verdicts. push-refused:scripts/main-gate-watch.test.sh — a push arm was MEASURED harmful (wave 60 D721: 2 of 2 push runs red on tip 026c5b1d78 while main was green, because ~15 s after a merge no check-run row exists yet) and a committed test reds if one comes back. Its fallback is THIS probe: a workflow that may not carry a trigger fallback must at least be watched for silence.
paper-readers.yml|report|1440|2026-09-03: daily paper-reader digest; did not run at all on 09-03, which is the tolerated case for a report.
renew-mail-cert.yml|report|43200|2026-09-03: monthly certificate renewal. 3x a month is a 90-day bound, which is not a useful alarm — the certificate expiry is the alarm, and it is watched where it lands, not here.
required-checks-drift.yml|periodic|1440|2026-09-03: daily drift audit of the required set; carries push: branches [main] already.
scaffy-catalog-drift.yml|report|1440|2026-09-03: daily catalog drift digest; carries push: branches [main].
search-starter-smoke.yml|report|1440|2026-09-03: daily starter smoke; carries push: branches [main].
stale-verdict-watch.yml|critical|30|2026-09-03: watches PRs asserting a green main has moved past. Carries push: branches [main].
studio-journey-smoke.yml|report|1440|2026-09-03: daily Studio journey smoke; carries push: branches [main].
task-lease-renew.yml|critical|20|2026-09-03: the claim sweep. Ran ZERO times in 3 h on 09-03; push: branches [main] was added in #15757 and is present.
twoslash.yml|periodic|1440|2026-09-06: nightly twoslash type-check of the documentation snippets (cron 03:30Z); carries push: branches [main]. Same 2026-09-06 c1 red as deploy-harnesses.
weekly-changelog.yml|report|10080|2026-09-03: weekly changelog digest.'

usage() { sed -n '2,110p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --table)      TABLE_FILE="$2"; shift 2 ;;
    --runs-file)  RUNS_FILE="$2"; shift 2 ;;
    --now)        NOW_ISO="$2"; shift 2 ;;
    --workflows)  WORKFLOWS_DIR="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --factor)     OVERDUE_FACTOR="$2"; shift 2 ;;
    --no-dispatch) DISPATCH=0; shift ;;
    --selftest)   MODE=selftest; shift ;;
    -h|--help)    usage ;;
    *) echo "cron-overdue-probe: unknown argument '$1'" >&2; usage ;;
  esac
done

table() {
  if [ -n "$TABLE_FILE" ]; then cat "$TABLE_FILE"; else printf '%s\n' "$DEFAULT_TABLE"; fi
}

# Portable across GNU date (CI) and BSD date (stock macOS), same two-form probe
# scripts/absent-context-census.sh uses.
iso_to_epoch() { # <iso8601-Z>
  local iso="$1" e
  # SHAPE FIRST, and it is load-bearing rather than tidy. The two date
  # implementations DISAGREE about junk, and the disagreement is not symmetric:
  #
  #   GNU coreutils 9.4  `date -u -d "" +%s`   -> rc 0, 1788652800 (today 00:00Z)
  #   BSD (stock macOS)  `date -u -j -f … "" ` -> rc 1, "illegal time format"
  #
  # So a run row with a missing or malformed timestamp was silently stamped with
  # a time NEAR NOW on Linux and refused on macOS. That is not a cosmetic split:
  # in_flight() below would read such a row as "a run is in flight right now" and
  # suppress the dispatch forever, and try_dispatch() would read it as "the
  # dispatched run appeared" — both are the laundered green this whole file
  # exists to refuse, handed out by whichever libc the runner happens to have.
  # It shipped: every push:main run of #16411 red on selftest c8b3, which passed
  # 26/26 on macOS (measured under `docker run ubuntu:24.04`, 2026-09-06).
  #
  # The guard makes the two agree BY CONSTRUCTION, at the stricter of the two —
  # the exact `%Y-%m-%dT%H:%M:%SZ` the BSD branch already demanded and the exact
  # shape the Actions API emits — so nothing that worked on macOS is lost and
  # Linux stops being the lax one. A glob `case`, not a regex: no bashisms, and
  # nothing to get wrong about anchoring.
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { echo "$e"; return 0; }
  e="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)" && { echo "$e"; return 0; }
  return 1
}

now_epoch() {
  if [ -n "$NOW_ISO" ]; then iso_to_epoch "$NOW_ISO"; else date -u +%s; fi
}

# Workflow files in the tree that carry a `schedule:` trigger, one basename per
# line. Comments are stripped first: a file that ARGUES about schedules in prose
# (main-gate-watch.yml argues about push:) must not be matched on its prose.
scheduled_files() {
  local f
  for f in "$WORKFLOWS_DIR"/*.yml; do
    [ -f "$f" ] || continue
    # ONE grep over the FILE, never `sed … | grep -q`: grep -q exits on its first
    # match, sed then takes SIGPIPE writing the rest of a long workflow, and under
    # `set -o pipefail` the pipeline reads as "no match" — so a long file whose
    # schedule: sits near the top (required-checks-drift.yml) dropped out of the
    # tree on some runs and c1 reported it as "classified but carries no schedule"
    # (main run 34015146623: `sed: couldn't write 108 items to stdout: Broken
    # pipe`, 19 files found, then 20 on the next). The trailing group is the
    # comment sed used to strip.
    if grep -qE '^[[:space:]]{2}schedule:[[:space:]]*(#.*)?$' "$f"; then
      basename "$f"
    fi
  done | sort
}

# ── 1. the table and the tree must agree ────────────────────────────────────
# A scheduled workflow nobody classified is the one nobody thought about, and
# defaulting it either way is a decision made by silence. Refuse instead.
check_table() {
  local rc=0 tree tbl only_tree only_tbl
  tree="$(scheduled_files)"
  tbl="$(table | cut -d'|' -f1 | sort)"
  only_tree="$(comm -23 <(printf '%s\n' "$tree") <(printf '%s\n' "$tbl"))"
  only_tbl="$(comm -13 <(printf '%s\n' "$tree") <(printf '%s\n' "$tbl"))"
  if [ -n "$only_tree" ]; then
    echo "REFUSED: scheduled workflow(s) carry no classification line:" >&2
    printf '  %s\n' $only_tree >&2
    echo "  Add a line to the table in $(basename "$0") — class, interval, and a DATED note." >&2
    rc=2
  fi
  if [ -n "$only_tbl" ]; then
    echo "REFUSED: the table classifies workflow(s) that carry no schedule: trigger:" >&2
    printf '  %s\n' $only_tbl >&2
    rc=2
  fi
  return $rc
}

# ── 2. every critical cadence carries a trigger fallback ────────────────────
# push: branches [main] is the fallback: a merge fires the workflow whatever cron
# is doing. The ONE escape hatch is a workflow whose push arm was measured
# HARMFUL — and it is not a note in this file, it is a COMMITTED TEST that reds
# when a push: trigger comes back. `push-refused:<path>` is honoured only when
# that file exists and actually carries the refusal, so the hatch cannot be
# pasted onto a workflow that has not earned it.
check_fallbacks() {
  local rc=0 line file class note wf guard
  while IFS='|' read -r file class _interval note; do
    [ -n "$file" ] || continue
    [ "$class" = "critical" ] || continue
    wf="$WORKFLOWS_DIR/$file"
    if [ ! -f "$wf" ]; then echo "REFUSED: $file is classified critical and does not exist" >&2; rc=2; continue; fi
    # Same shape as scheduled_files: one grep over the file, no sed|grep -q pipe
    # (the SIGPIPE flip made c7 report every critical workflow as push-less on
    # a shell with pipefail — measured on this repo's own tree, 4 false REFUSEDs).
    if grep -qE '^[[:space:]]{2}push:[[:space:]]*(#.*)?$' "$wf"; then
      echo "  ok   $file (critical, every ${_interval}m) carries a push: trigger — cron is not its only way to fire"
      continue
    fi
    guard="$(printf '%s' "$note" | sed -n 's/.*push-refused:\([^ ]*\).*/\1/p')"
    if [ -n "$guard" ] && [ -f "$REPO_ROOT/$guard" ] && grep -q 'THERE MUST BE NO push:' "$REPO_ROOT/$guard"; then
      echo "  ok   $file (critical, every ${_interval}m) has NO push arm and may not have one — $guard reds if it comes back; this probe is its fallback"
      continue
    fi
    echo "REFUSED: $file is classified critical, carries no push: trigger, and names no committed guard that forbids one." >&2
    echo "         Add \`push: branches: [main]\`, or name a guard file with \`push-refused:<path>\` that carries the literal refusal." >&2
    rc=2
  done <<EOF
$(table)
EOF
  return $rc
}

# ── 3. the overdue read ─────────────────────────────────────────────────────
# Newest run per workflow. A queued run older than 24 h is NOT evidence of a
# firing — see THE QUEUED-RUN TRAP above.
read_runs() {
  if [ -n "$RUNS_FILE" ]; then cat "$RUNS_FILE"; return $?; fi
  local file out grc rc=0
  while IFS='|' read -r file _class _interval _note; do
    [ -n "$file" ] || continue
    out="$("$(gh_bin)" api "repos/$REPO/actions/workflows/$file/runs?per_page=5" \
             --jq ".workflow_runs[] | {path: \"$file\", status: .status, created_at: .created_at}" 2>&1)"; grc=$?
    if [ "$grc" -ne 0 ]; then
      # A 404 IS AN ANSWER, and the opposite of a read fault: GitHub has no such
      # workflow, so it has certainly not fired. Passing that through as zero
      # rows lets a critical workflow reach the "NO run row" scream instead of
      # hiding behind a repo-wide UNKNOWN. Anything else — 403, a rate limit, a
      # transport error — is genuinely unreadable and must not be scored.
      if grep -qE 'HTTP 404|Not Found' <<<"$out"; then continue; fi
      echo "  read failed for $file: $(printf '%s' "$out" | head -1)" >&2
      rc=3
      continue
    fi
    printf '%s\n' "$out"
  done <<EOF
$(table)
EOF
  return $rc
}

# ── 3b. the dispatch fallback ───────────────────────────────────────────────
# Which arms a workflow actually carries. Same one-grep-over-the-file shape as
# scheduled_files/check_fallbacks and for the same reason: `sed … | grep -q`
# takes SIGPIPE under pipefail and reads as "no match", which here would silently
# turn a push-armed workflow into a dispatch candidate.
has_push_arm() { # <basename>
  grep -qE '^[[:space:]]{2}push:[[:space:]]*(#.*)?$' "$WORKFLOWS_DIR/$1"
}
has_dispatch_arm() { # <basename>
  grep -qE '^[[:space:]]{2}workflow_dispatch:[[:space:]]*(#.*)?$' "$WORKFLOWS_DIR/$1"
}

# IS A RUN ALREADY UNDER WAY? Measured while building this arm, 2026-09-06: five
# dispatches of main-gate-watch.yml fired within three minutes produced ONE
# surviving run and FOUR `cancelled` (34026329460, 34026330836, 34026376524,
# 34026420030 on tip 8e533ac402). Its concurrency group is per-ref with
# `cancel-in-progress: false`, and GitHub keeps only one PENDING run per group:
# a newer queued run cancels the older queued one. A cancelled main-gate-watch
# is a tip left with NO VERDICT, which is the exact failure that workflow exists
# to report — so a probe that dispatched blindly could cancel the watch it is
# protecting. Two probe runs can overlap (its own group is per-sha), and the run
# snapshot this probe scored is minutes old by dispatch time, so this is a LIVE
# re-read taken immediately before firing.
#
# THE PHANTOM-QUEUED TRAP APPLIES HERE TOO (c6): eight permanently-`queued` rows
# sit in this repo's list forever. A non-completed row older than 24 h is not
# "in flight", it is dead — counting it would suppress the dispatch for good and
# hand back a laundered green, which is the whole failure this file exists for.
in_flight() { # <basename> <now-epoch> -> prints the run id, 0 if one is running
  local file="$1" now="$2" out rid rst rts re
  out="$("$(gh_bin)" api "repos/$REPO/actions/workflows/$file/runs?per_page=10" \
           --jq '.workflow_runs[] | "\(.id) \(.status) \(.created_at)"' 2>/dev/null)"
  while read -r rid rst rts; do
    [ -n "$rid" ] || continue
    [ "$rst" = "completed" ] && continue
    re="$(iso_to_epoch "$rts")" || continue
    [ "$(( now - re ))" -gt $(( 1440 * 60 )) ] && continue
    printf '%s\n' "$rid"; return 0
  done <<EOF
$out
EOF
  return 1
}

# Fire a cron-only critical workflow and PROVE a run appeared. Prints the run id
# on success; on failure prints the reason (the caller quotes it in the scream).
# The run must be NEWER than the probe's own `now` — an old workflow_dispatch row
# from last week is not evidence that THIS dispatch landed, which is the same
# mistake the queued-row trap above exists to refuse. 120 s of slack absorbs the
# clock skew between the runner and GitHub, nothing more.
try_dispatch() { # <basename> <now-epoch>
  local file="$1" now="$2" out grc t=0 rid rts re gh tries sleep_s
  gh="$(gh_bin)"; tries="$(poll_tries)"; sleep_s="$(poll_sleep)"
  out="$("$gh" workflow run "$file" --repo "$REPO" --ref main 2>&1)"; grc=$?
  if [ "$grc" -ne 0 ]; then
    printf 'the dispatch call itself failed (%s)\n' "$(printf '%s' "$out" | head -1)"
    return 1
  fi
  while [ "$t" -lt "$tries" ]; do
    out="$("$gh" api "repos/$REPO/actions/workflows/$file/runs?event=workflow_dispatch&per_page=5" \
             --jq '.workflow_runs[] | "\(.id) \(.created_at)"' 2>/dev/null)"
    while read -r rid rts; do
      [ -n "$rid" ] || continue
      re="$(iso_to_epoch "$rts")" || continue
      if [ "$re" -ge $(( now - 120 )) ]; then printf '%s\n' "$rid"; return 0; fi
    done <<EOF
$out
EOF
    t=$(( t + 1 ))
    [ "$t" -lt "$tries" ] && sleep "$sleep_s"
  done
  printf 'the dispatch was accepted but NO workflow_dispatch run appeared within %ss\n' \
    "$(( tries * sleep_s ))"
  return 1
}

check_overdue() {
  local now rows rc=0 file class interval note newest age bound runid=""
  now="$(now_epoch)" || { echo "cron-overdue-probe: --now is not an ISO-8601 Z timestamp" >&2; return 2; }
  rows="$(read_runs)" || { echo "UNKNOWN: the run list could not be read — that is not 'it fired'." >&2; return 3; }
  while IFS='|' read -r file class interval note; do
    [ -n "$file" ] || continue
    [ "$class" = "critical" ] || continue
    # The newest run that is EVIDENCE of a firing: any status except a queued
    # row older than 24 h (1440 minutes).
    newest="$(printf '%s\n' "$rows" | grep -F "\"$file\"" | python3 -c '
import json, sys, datetime
now = float(sys.argv[1])
best = None
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except json.JSONDecodeError: continue
    ts = o.get("created_at")
    try:
        e = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        continue
    if o.get("status") == "queued" and (now - e) > 1440 * 60:
        continue
    if best is None or e > best: best = e
print(int(best) if best is not None else "")
' "$now" 2>/dev/null)"
    bound=$(( interval * OVERDUE_FACTOR ))
    if [ -z "$newest" ]; then
      # THE ONE EXEMPTION, and it is not a judgement call: the workflow that is
      # EXECUTING RIGHT NOW has fired by definition. GitHub indexes a run into
      # the list endpoint a moment after it starts, so on the very first push
      # that creates this file the probe can read zero rows for itself and
      # scream about a workflow that is, at that instant, running the scream.
      # GITHUB_WORKFLOW_REF is set only by Actions and names the executing file
      # (owner/repo/.github/workflows/<file>@ref), so this cannot be claimed by
      # any other row.
      if [ -n "${GITHUB_WORKFLOW_REF:-}" ] \
         && [ "$(basename "${GITHUB_WORKFLOW_REF%%@*}")" = "$file" ]; then
        echo "  ok   $file (critical, every ${interval}m): no row in the list yet — THIS run is the firing (GITHUB_WORKFLOW_REF)"
        continue
      fi
      echo "OVERDUE  $file (critical, every ${interval}m): NO run row is evidence of a firing at all. Silence is not a pass." >&2
      rc=1
      continue
    fi
    age=$(( (now - newest) / 60 ))
    [ "$age" -lt 0 ] && age=0
    if [ "$age" -gt "$bound" ]; then
      # THE DISPATCH ARM. Only for a CRON-ONLY critical workflow: one with no
      # push: arm (so cron really is its only automatic trigger) that does carry
      # workflow_dispatch:. A push-armed workflow past bound is genuinely broken
      # and still screams, untouched.
      if [ "$DISPATCH" = 1 ] && [ -f "$WORKFLOWS_DIR/$file" ] \
         && ! has_push_arm "$file" && has_dispatch_arm "$file"; then
        if runid="$(in_flight "$file" "$now")"; then
          echo "  ok   $file (critical, every ${interval}m): newest scored run ${age}m old, past the ${bound}m bound — but run $runid is in flight RIGHT NOW, so this probe did not dispatch (a second queued run would cancel the first)"
          continue
        fi
        if runid="$(try_dispatch "$file" "$now")"; then
          echo "  ok   $file (critical, every ${interval}m): newest run ${age}m old, past the ${bound}m bound — it is cron-only, so this probe DISPATCHED it: run $runid"
          continue
        fi
        echo "OVERDUE  $file (critical, every ${interval}m): newest run is ${age}m old, bound is ${OVERDUE_FACTOR}x = ${bound}m, and this probe's workflow_dispatch fallback FAILED — $runid" >&2
        rc=1
        continue
      fi
      echo "OVERDUE  $file (critical, every ${interval}m): newest run is ${age}m old, bound is ${OVERDUE_FACTOR}x = ${bound}m." >&2
      rc=1
    else
      echo "  ok   $file (critical, every ${interval}m): newest run ${age}m old, inside the ${bound}m bound"
    fi
  done <<EOF
$(table)
EOF
  return $rc
}

selftest() {
  local tmp pass=0 fail=0 out rc
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local NOW=2026-09-03T12:00:00Z

  # THE STUB GOES FIRST, and this is not tidiness. Once the overdue read can
  # DISPATCH, every past-bound fixture below reaches `gh` — the 6 h-gap fixture
  # (c3) fired three real main-gate-watch runs the first time this arm ran. The
  # stub records what it was asked to do and answers the run-list poll, so the
  # selftest stays what its header promises: no network.
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh — records the dispatch, then answers the run-list poll.
case "$1" in
  workflow)
    if [ "${STUB_DISPATCH_FAILS:-0}" = 1 ]; then
      echo "HTTP 403: Resource not accessible by integration" >&2; exit 1
    fi
    printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"; exit 0 ;;
  api)
    case "$2" in
      *event=workflow_dispatch*)
        [ "${STUB_RUN_APPEARS:-1}" = 1 ] && echo "99887766 2026-09-03T12:00:05Z" ;;
      *) [ -n "${STUB_IN_FLIGHT:-}" ] && printf '%s\n' "$STUB_IN_FLIGHT" ;;
    esac
    exit 0 ;;
esac
exit 1
STUB
  chmod +x "$tmp/bin/gh"
  export CRON_PROBE_GH="$tmp/bin/gh" CRON_PROBE_POLL_TRIES=1 CRON_PROBE_POLL_SLEEP=0

  # c0 — and the stub is REACHED. A stub nobody calls is a test that proves
  # nothing while printing ok, which is exactly how this arm failed first time:
  # gh was bound once at startup, so exporting CRON_PROBE_GH here changed nothing.
  if [ "$(gh_bin)" = "$tmp/bin/gh" ] && [ "$(poll_tries)" = "1" ]; then
    pass=$((pass+1)); echo "  ok   c0 the selftest resolves gh to its stub at CALL time — no arm below can reach the network"
  else
    fail=$((fail+1)); echo "  FAIL c0 gh resolves to '$(gh_bin)', not the stub — every dispatch assertion below is live traffic"
  fi

  # c1 — the table describes THIS tree. Non-vacuous: a table matching an empty
  # tree would pass a set comparison trivially.
  local n_tree
  n_tree="$(scheduled_files | grep -c . || true)"
  if check_table >/dev/null 2>&1 && [ "$n_tree" -ge 10 ]; then
    pass=$((pass+1)); echo "  ok   c1 all $n_tree scheduled workflow(s) in .github/workflows carry a classification line, and none is classified that has no schedule"
  else
    fail=$((fail+1)); echo "  FAIL c1 the table and the tree disagree ($n_tree scheduled files found)"; check_table
  fi

  # c1b — and that comparison can LOSE: a table missing one row must refuse.
  table | grep -v '^main-gate-watch.yml' > "$tmp/short-table"
  if ! TABLE_FILE="$tmp/short-table" check_table >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok   c1b a table with main-gate-watch.yml deleted REFUSES — c1 is a question that can fail"
  else
    fail=$((fail+1)); echo "  FAIL c1b a table missing a scheduled workflow was accepted"
  fi

  # c2 — a critical workflow that fired 20 minutes ago is fine. RAW rows.
  cat > "$tmp/fresh.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "in_progress", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/fresh.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c2 every critical workflow with a run in the last 20m passes — the probe is quiet when cron is healthy"
  else
    fail=$((fail+1)); echo "  FAIL c2 a healthy fixture reddened (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c3 — THE MUTATION THIS PROBE EXISTS FOR: fake a 6 h gap on main-gate-watch
  # (*/30, bound 90m) and nothing else. One field moves; the verdict must move
  # with it, and it must NAME the workflow.
  sed 's|"main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z"|"main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T06:00:00Z"|' \
    "$tmp/fresh.ndjson" > "$tmp/gap6h.ndjson"
  if [ "$(grep -c '2026-09-03T06:00:00Z' "$tmp/gap6h.ndjson")" = "1" ] \
     && ! diff -q "$tmp/fresh.ndjson" "$tmp/gap6h.ndjson" >/dev/null; then
    pass=$((pass+1)); echo "  ok   c3a the 6 h gap MUTATION applied — exactly one row moved from 11:40Z to 06:00Z"
  else
    fail=$((fail+1)); echo "  FAIL c3a the mutation did not apply — c3b below would be proving nothing"
  fi
  # DISPATCH=0: this arm is about the OVERDUE READ, not the fallback. Since the
  # dispatch arm landed, a cron-only workflow past bound is FIRED rather than
  # screamed at (c8a is that proof), so asserting the scream here would be
  # asserting the absence of the fix.
  out="$(DISPATCH=0 RUNS_FILE="$tmp/gap6h.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  main-gate-watch.yml' <<<"$out" && grep -q '360m old' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c3b a 6 h gap on a */30 workflow is DETECTED and reds report-only at exit 1, naming it: $(grep -o 'OVERDUE  main-gate-watch.yml.*' <<<"$out")"
  else
    fail=$((fail+1)); echo "  FAIL c3b a 6 h gap did not red (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c3c — and the FACTOR is doing the work, not the timestamp. The identical
  # 6 h-gap fixture under a factor wide enough to cover it must pass.
  out="$(DISPATCH=0 RUNS_FILE="$tmp/gap6h.ndjson" NOW_ISO="$NOW" OVERDUE_FACTOR=100 check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c3c …and the SAME 6 h gap passes at factor 100 — the 3x bound is the discriminator, not a pinned date"
  else
    fail=$((fail+1)); echo "  FAIL c3c the 6 h gap still red at factor 100 (rc=$rc) — something other than the bound is deciding"
  fi

  # c4 — CLASS discriminates. A 30-day gap on a report-class workflow is not a
  # finding: a probe that reds on everything is a probe nobody reads.
  cat > "$tmp/report-gap.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
{"path": "weekly-changelog.yml", "status": "completed", "created_at": "2026-08-04T11:40:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/report-gap.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c4 a 30-day gap on a REPORT-class workflow is not a finding — the class does the discriminating"
  else
    fail=$((fail+1)); echo "  FAIL c4 a report-class gap reddened the probe (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c5 — SILENCE IS THE WORST CASE. No row at all for a critical workflow reds.
  grep -v 'task-lease-renew' "$tmp/fresh.ndjson" > "$tmp/missing.ndjson"
  out="$(RUNS_FILE="$tmp/missing.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'NO run row' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c5 a critical workflow with NO run row at all reds — absence is never read as health"
  else
    fail=$((fail+1)); echo "  FAIL c5 a missing workflow was treated as fired (rc=$rc)"
  fi

  # c5b — THE EXEMPTION, both directions. The executing workflow has fired by
  # definition; nothing else may claim that. c5 above is the same fixture with
  # the env unset, so the pair proves the env is doing the work.
  out="$(GITHUB_WORKFLOW_REF="FRIKKern/barkpark/.github/workflows/task-lease-renew.yml@refs/heads/main" \
         RUNS_FILE="$tmp/missing.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && grep -q 'THIS run is the firing' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c5b …and the workflow that is EXECUTING is exempt from its own missing row — the same fixture c5 reds on"
  else
    fail=$((fail+1)); echo "  FAIL c5b the executing workflow was still called overdue (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
  out="$(GITHUB_WORKFLOW_REF="FRIKKern/barkpark/.github/workflows/some-other.yml@refs/heads/main" \
         RUNS_FILE="$tmp/missing.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ]; then
    pass=$((pass+1)); echo "  ok   c5c …and a DIFFERENT executing workflow cannot claim the exemption — it names one file, not any file"
  else
    fail=$((fail+1)); echo "  FAIL c5c the exemption was claimed by an unrelated workflow (rc=$rc)"
  fi

  # c6 — A PHANTOM QUEUED ROW IS NOT A FIRING (task-82059e31bcccdbd7). The row
  # exists, is 27 days old, and status queued: GitHub will not dequeue it and
  # refuses both cancel paths. Accepting it as evidence would make this probe
  # permanently green on exactly the workflow that stopped running.
  cat > "$tmp/phantom.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "queued", "created_at": "2026-08-07T09:08:43Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/phantom.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'main-gate-watch.yml' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c6 a 27-day-old QUEUED row is not accepted as a firing — the run list has a row and the workflow is still dark"
  else
    fail=$((fail+1)); echo "  FAIL c6 a phantom queued row was read as a firing (rc=$rc) — the probe would be green on a dead workflow"
  fi

  # c7 — every critical cadence carries a fallback, checked against the REAL tree.
  out="$(check_fallbacks 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c7 every critical-cadence workflow carries push: branches [main], or a committed guard that forbids one"
  else
    fail=$((fail+1)); echo "  FAIL c7 a critical workflow has no fallback:"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c7b — the escape hatch cannot be pasted. A critical row naming a guard file
  # that does not carry the refusal must be REFUSED.
  table | sed 's|^main-gate-watch.yml|main-gate-watch.yml|; s|push-refused:scripts/main-gate-watch.test.sh|push-refused:scripts/ci-measure.sh|' > "$tmp/bad-guard"
  if ! TABLE_FILE="$tmp/bad-guard" check_fallbacks >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok   c7b naming a guard file that does not carry the refusal is REFUSED — the exemption cannot be copy-pasted onto another workflow"
  else
    fail=$((fail+1)); echo "  FAIL c7b a bogus push-refused: guard was accepted"
  fi

  # ── c8 — THE DISPATCH ARM (task-f94a1d96238b18e4) ─────────────────────────
  # The exact shape that reddened main: main-gate-watch (*/30, bound 90m) with
  # its newest run 92 minutes old, which is ORDINARY delivery for a schedule
  # GitHub hands over every 2.1-4.7 h. `gh` is stubbed, so no network and no
  # real dispatch; the stub RECORDS what it was asked to do, because "the probe
  # exited 0" would also be true of a probe that quietly stopped checking.
  # 10:28Z under a 12:00Z now is 92m — the census figure, not a round number.
  cat > "$tmp/lag92.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T10:28:00Z"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX

  : > "$tmp/dispatch.log"
  out="$(STUB_LOG="$tmp/dispatch.log" RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] \
     && grep -q 'DISPATCHED it: run 99887766' <<<"$out" \
     && grep -q '92m old' <<<"$out" \
     && grep -q 'workflow run main-gate-watch.yml' "$tmp/dispatch.log"; then
    pass=$((pass+1)); echo "  ok   c8a a 92m-old main-gate-watch is DISPATCHED, not screamed at — and the stub recorded the call: $(head -1 "$tmp/dispatch.log")"
  else
    fail=$((fail+1)); echo "  FAIL c8a the 92m fixture did not dispatch cleanly (rc=$rc, log=$(cat "$tmp/dispatch.log")):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8b — a dispatch that is REFUSED still screams, and says so.
  out="$(STUB_DISPATCH_FAILS=1 RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  main-gate-watch.yml' <<<"$out" \
     && grep -q 'the dispatch call itself failed' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c8b a REFUSED dispatch (403) still reds at exit 1, naming the failure: $(grep -o 'fallback FAILED.*' <<<"$out" | head -1)"
  else
    fail=$((fail+1)); echo "  FAIL c8b a failed dispatch did not red (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8b2 — accepted, but no run ever shows up. A dispatch nobody can find is not
  # a firing; this is the c6 argument applied to the new arm.
  out="$(STUB_RUN_APPEARS=0 RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'NO workflow_dispatch run appeared' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c8b2 …and an ACCEPTED dispatch whose run never appears reds too — 'gh said ok' is not evidence of a firing"
  else
    fail=$((fail+1)); echo "  FAIL c8b2 a vanished dispatch was read as a firing (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8b3 — and a STALE workflow_dispatch row cannot be mistaken for this one.
  # This stub answers the two api reads SEPARATELY. It did not: written before
  # in_flight() existed, it returned its two-field dispatch row to every api
  # call, so in_flight() read the id and the timestamp into the wrong fields and
  # got an EMPTY timestamp — which is the junk the parser above now refuses.
  cat > "$tmp/bin/gh-old" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  workflow) exit 0 ;;
  api)
    case "$2" in
      *event=workflow_dispatch*) echo "11112222 2026-08-30T09:00:00Z" ;;
      *) : ;;  # nothing in flight
    esac
    exit 0 ;;
esac
exit 1
STUB
  chmod +x "$tmp/bin/gh-old"
  out="$(CRON_PROBE_GH="$tmp/bin/gh-old" RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'NO workflow_dispatch run appeared' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c8b3 …and a four-day-old workflow_dispatch row is not accepted as THIS dispatch landing"
  else
    fail=$((fail+1)); echo "  FAIL c8b3 a stale dispatch row was accepted (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8g — THE PLATFORM SEAM ITSELF (#16411 was red on main for this). The shared
  # timestamp parser must refuse junk on BOTH date implementations, because GNU
  # answers `date -d ""` with today-00:00Z at exit 0 and BSD refuses it.
  if ! iso_to_epoch "" >/dev/null 2>&1 \
     && ! iso_to_epoch "not-a-date" >/dev/null 2>&1 \
     && ! iso_to_epoch "2026-09-03 12:00:00" >/dev/null 2>&1 \
     && ! iso_to_epoch "2026-09-03T12:00:00+00:00" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok   c8g the timestamp parser REFUSES an empty/loose stamp — the GNU-vs-BSD split that reddened main cannot come back"
  else
    fail=$((fail+1)); echo "  FAIL c8g the parser accepted junk: empty -> '$(iso_to_epoch "" 2>/dev/null)', loose -> '$(iso_to_epoch "2026-09-03 12:00:00" 2>/dev/null)'"
  fi
  # …and it can LOSE: a real stamp still parses, and two an hour apart are an
  # hour apart. No pinned epoch number, so this holds under either date.
  if [ -n "$(iso_to_epoch 2026-09-03T12:00:00Z)" ] \
     && [ "$(( $(iso_to_epoch 2026-09-03T13:00:00Z) - $(iso_to_epoch 2026-09-03T12:00:00Z) ))" = "3600" ]; then
    pass=$((pass+1)); echo "  ok   c8g2 …and it still parses a real stamp — two an hour apart differ by exactly 3600s, so c8g is not a parser that refuses everything"
  else
    fail=$((fail+1)); echo "  FAIL c8g2 the guard broke the parser for VALID stamps — c8g would be passing vacuously"
  fi
  # c8g3 — the exact production shape the seam produced: an in-flight row whose
  # timestamp field is missing. It must NOT suppress the dispatch. Before the
  # guard this printed "run 11112222 is in flight RIGHT NOW" on Linux and
  # dispatched on macOS; now both dispatch.
  : > "$tmp/dispatch.log"
  out="$(STUB_IN_FLIGHT="11112222 2026-08-30T09:00:00Z" STUB_LOG="$tmp/dispatch.log" \
         RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && grep -q 'DISPATCHED it: run 99887766' <<<"$out" \
     && ! grep -q 'in flight RIGHT NOW' <<<"$out" \
     && grep -q 'workflow run main-gate-watch.yml' "$tmp/dispatch.log"; then
    pass=$((pass+1)); echo "  ok   c8g3 …and a MALFORMED in-flight row (no timestamp field) does not masquerade as a live run — the dispatch still went out"
  else
    fail=$((fail+1)); echo "  FAIL c8g3 a malformed in-flight row suppressed the dispatch (rc=$rc, log=$(cat "$tmp/dispatch.log")):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8c — THE ARM DOES NOT WEAKEN A push-ARMED WORKFLOW. task-lease-renew is
  # critical (*/20, bound 60m) and carries push: branches [main], so 92 minutes
  # of silence means something is actually wrong with it: it must SCREAM, and it
  # must never be dispatched.
  sed 's|"task-lease-renew.yml", "status": "in_progress", "created_at": "2026-09-03T11:50:00Z"|"task-lease-renew.yml", "status": "in_progress", "created_at": "2026-09-03T10:28:00Z"|' \
    "$tmp/fresh.ndjson" > "$tmp/push-armed-lag.ndjson"
  if [ "$(grep -c '"task-lease-renew.yml".*10:28:00Z' "$tmp/push-armed-lag.ndjson")" = "1" ] \
     && ! diff -q "$tmp/fresh.ndjson" "$tmp/push-armed-lag.ndjson" >/dev/null; then
    pass=$((pass+1)); echo "  ok   c8c-mut the push-armed lag MUTATION applied — exactly one row moved to 10:28Z"
  else
    fail=$((fail+1)); echo "  FAIL c8c-mut the mutation did not apply — c8c below would prove nothing"
  fi
  : > "$tmp/dispatch.log"
  out="$(STUB_LOG="$tmp/dispatch.log" RUNS_FILE="$tmp/push-armed-lag.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  task-lease-renew.yml' <<<"$out" \
     && ! grep -q 'task-lease-renew' "$tmp/dispatch.log"; then
    pass=$((pass+1)); echo "  ok   c8c a push-ARMED critical workflow past its bound SCREAMS exactly as before and is never dispatched: $(grep -o 'OVERDUE  task-lease-renew.*' <<<"$out")"
  else
    fail=$((fail+1)); echo "  FAIL c8c the dispatch arm weakened a push-armed workflow (rc=$rc, log=$(cat "$tmp/dispatch.log")):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8f — THE PROBE MUST NOT CANCEL THE WATCH IT PROTECTS. A run already in
  # flight means the workflow IS firing; a second dispatch would only cancel the
  # queued one (four real cancellations, quoted above in_flight()).
  : > "$tmp/dispatch.log"
  out="$(STUB_IN_FLIGHT="55554444 in_progress 2026-09-03T11:58:00Z" STUB_LOG="$tmp/dispatch.log" \
         RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && grep -q 'run 55554444 is in flight RIGHT NOW' <<<"$out" \
     && [ ! -s "$tmp/dispatch.log" ]; then
    pass=$((pass+1)); echo "  ok   c8f a run already in flight suppresses the dispatch entirely — the log is empty, so nothing was queued behind it"
  else
    fail=$((fail+1)); echo "  FAIL c8f the in-flight guard did not hold (rc=$rc, log=$(cat "$tmp/dispatch.log")):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8f2 — and the guard cannot be held open forever by a PHANTOM queued row.
  # Same fixture, same row, aged past 24 h: the dispatch must go out.
  : > "$tmp/dispatch.log"
  out="$(STUB_IN_FLIGHT="55554444 queued 2026-08-07T09:08:43Z" STUB_LOG="$tmp/dispatch.log" \
         RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && grep -q 'DISPATCHED it: run 99887766' <<<"$out" \
     && grep -q 'workflow run main-gate-watch.yml' "$tmp/dispatch.log"; then
    pass=$((pass+1)); echo "  ok   c8f2 …and a 27-day-old QUEUED row does NOT hold that guard open — the dispatch still went out (the c6 trap, applied to the new arm)"
  else
    fail=$((fail+1)); echo "  FAIL c8f2 a phantom queued row suppressed the dispatch permanently (rc=$rc, log=$(cat "$tmp/dispatch.log")):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8d — THE MUTATION THAT MATTERS: cut the dispatch call out of a COPY of this
  # script and the 92m fixture must go back to red. Run as a whole program, so
  # the mutant's verdict is the process exit code, not an internal one.
  sed 's|^        if runid="$(try_dispatch|        if false \&\& runid="$(try_dispatch|' "$0" > "$tmp/nodispatch.sh"
  if [ "$(grep -c '^        if false && runid="$(try_dispatch' "$tmp/nodispatch.sh")" = "1" ] \
     && ! diff -q "$0" "$tmp/nodispatch.sh" >/dev/null; then
    pass=$((pass+1)); echo "  ok   c8d-mut the remove-the-dispatch-arm MUTATION applied — exactly one call site disabled"
  else
    fail=$((fail+1)); echo "  FAIL c8d-mut the mutation did not apply — c8d below would prove nothing"
  fi
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$tmp/nodispatch.sh" --workflows "$WORKFLOWS_DIR" \
           --runs-file "$tmp/lag92.ndjson" --now "$NOW" 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  main-gate-watch.yml' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c8d …and with the dispatch arm removed the SAME 92m fixture reds again — c8a is the arm doing the work, not the fixture"
  else
    fail=$((fail+1)); echo "  FAIL c8d the mutant still passed (rc=$rc) — c8a proves nothing"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
  # …and the positive control: the UNMUTATED script, same invocation, exits 0.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$WORKFLOWS_DIR" \
           --runs-file "$tmp/lag92.ndjson" --now "$NOW" 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c8d2 …and the unmutated script on that identical invocation exits 0 — the pair differs only by the mutation"
  else
    fail=$((fail+1)); echo "  FAIL c8d2 the unmutated script did not pass its own fixture (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c8e — --no-dispatch is a REPORT mode, and it is honest about it: the same
  # fixture reds, so nobody can quietly mute the probe by leaving the flag on.
  out="$(DISPATCH=0 RUNS_FILE="$tmp/lag92.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "1" ]; then
    pass=$((pass+1)); echo "  ok   c8e --no-dispatch reports only — the same fixture reds, so the flag cannot be used to make the probe quiet"
  else
    fail=$((fail+1)); echo "  FAIL c8e --no-dispatch went green without firing anything (rc=$rc)"
  fi
  unset CRON_PROBE_GH CRON_PROBE_POLL_TRIES CRON_PROBE_POLL_SLEEP

  echo
  echo "SELFTEST: $pass passed, $fail failed."
  [ "$fail" -eq 0 ]
}

if [ "$MODE" = selftest ]; then selftest; exit $?; fi

echo "cron-overdue-probe — repo $REPO, bound ${OVERDUE_FACTOR}x the schedule interval"
echo
check_table || exit 2
check_fallbacks || exit 2
echo
check_overdue
RC=$?
echo
case "$RC" in
  0) echo "VERDICT  cron: every critical-cadence workflow fired inside ${OVERDUE_FACTOR}x its interval" ;;
  1) echo "VERDICT  cron: SCREAM — a critical-cadence workflow is silent past ${OVERDUE_FACTOR}x its interval AND could not be fired (named above). GitHub cron is best-effort, so lag alone is no longer a scream: a cron-only critical workflow past bound is DISPATCHED by this probe, and only a failed dispatch, a dispatched run that never appeared, a push-armed workflow gone quiet, or a workflow with no run row at all reaches this verdict. A re-run of this probe is not the remedy." ;;
  3) echo "VERDICT  cron: UNKNOWN — the run list could not be read. Not a pass." ;;
esac
exit $RC
