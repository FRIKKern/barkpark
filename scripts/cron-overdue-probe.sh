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
# ── 2026-09-20: WHAT "WATCHING MAIN" GUARANTEES, AND WHO DELIVERS IT ────────
# (task-edebe459992b3574, by deploy-w3. The row was filed 2026-09-07 against a
# 2026-08-09..2026-09-07 population; everything below is a RE-MEASUREMENT taken
# 2026-09-20T19:40Z from the paginated REST API, `event=` filtered, never
# `gh run list --limit N` — a row cap is not a time window.)
#
# THE GUARANTEE, stated so it can be checked rather than assumed:
#   EVERY TIP OF main GETS A COMPLETED main-gate-watch VERDICT WITHIN 3x THE
#   DECLARED INTERVAL, BY A DECLARED MECHANISM. Two mechanisms are declared and
#   only two: GitHub's `schedule:` trigger, and THIS PROBE's workflow_dispatch
#   rescue. A push: arm is a third mechanism and it is FORBIDDEN here (below).
#   The guarantee is about the VERDICT arriving, not about which of the two
#   delivered it — but WHICH ONE DELIVERED IT IS NOW REPORTED, because a green
#   that silently means "the rescue carried it" is a different claim from the
#   one its reader makes.
#
# THE MEASUREMENT. Gaps between consecutive event=schedule runs, minutes:
#
#   main-gate-watch.yml  (*/30, bound 90m)   647 schedule runs, 87 dispatches
#     FULL  08-09..09-20   646 gaps  min 19 p50 57  p90 250 max 680  >90m 28%  delivered 647/2055 = 31%
#     QUIET 08-12..08-19   198 gaps  min 20 p50 47  p90  85 max 137  >90m  6%  delivered 199/336  = 59%
#     SPIKE 09-05..09-07    20 gaps  min 119 p50 192 p90 304 max 358 >90m 100% delivered 21/144   = 15%
#     LAST7 09-13..09-20    48 gaps  min 107 p50 217 p90 329 max 415 >90m 100% delivered 49/375   = 13%
#
#   stale-verdict-watch.yml (*/30, bound 90m) 601 schedule runs, 2 dispatches
#     FULL  600 gaps p50 60  >90m 31%  | QUIET 182 gaps p50 53 >90m 10% (54%)
#     SPIKE  20 gaps p50 194 >90m 100% | LAST7  47 gaps p50 246 >90m 100% (13%)
#
#   task-lease-renew.yml   (*/20, bound 60m)  121 schedule runs, 1 dispatch
#     FULL  120 gaps min 99 p50 192 max 415 — 100% exceed its own 60m bound
#     LAST7  49 gaps min 106 p50 230 max 415 — 100% exceed it
#
#   EVENT SPLIT, last 24 h to 2026-09-20T19:40Z: main-gate-watch 7 schedule +
#   2 dispatch; stale-verdict-watch 7 + 0; task-lease-renew 7 + 0. THREE
#   WORKFLOWS AT TWO DECLARED CADENCES ALL RECEIVED EXACTLY SEVEN SCHEDULED
#   RUNS. The declared interval is not what GitHub delivers on this repo; ~7
#   beats a day is, whatever you write in the cron expression.
#
# THREE THINGS THE FILING GOT WRONG, all in the direction of understatement:
#   (1) "the bound was never achievable" — in the QUIET window 94% of gaps were
#       inside the 90m bound. The bound was achievable in August. The platform
#       degraded; the bound did not become wrong.
#   (2) "TODAY IS AN OUTLIER, NOT THE NORM" — thirteen days later the outlier IS
#       the norm: LAST7 p50 is 217m and 100% of gaps exceed 90m, worse than the
#       09-05..09-07 spike it was contrasted against. The filing's own warning
#       against over-fitting to a spike now cuts the other way.
#   (3) the population got worse, not merely longer: 17% of gaps over 90m at
#       filing, 28% over the same start date measured today.
#
# THE DECISION, and it is deliberately NOT a wider bound.
#   * THE 90m BOUND AND THE 3x FACTOR ARE UNCHANGED. Widening one is how a true
#     alarm gets silenced (this row's own words), and the QUIET numbers say the
#     bound describes a cadence this repo really delivered five weeks ago.
#   * THE DISPATCH RESCUE IS PROMOTED FROM AN EXCEPTION PATH TO A DECLARED
#     CO-PRIMARY DELIVERY MECHANISM, in writing, here. It is not new code and
#     nothing about it is loosened; what changes is that it is no longer an
#     emergent property nobody chose. At 13% schedule delivery it is carrying a
#     large and growing share of the beats and will keep doing so.
#   * AND THE PROBE NOW SAYS SO OUT LOUD. See THE CADENCE MEASURE below.
#   * WHAT IS *NOT* DONE: no push: arm (forbidden, measured harmful — 2 of 2
#     push runs red on tip 026c5b1d78 while main was in fact green, because
#     ~15s after a merge GitHub has created no check-run rows on the new tip at
#     all; scripts/main-gate-watch.test.sh reds if one returns). No re-anchored
#     interval either: rewriting */30 to */200 to match ~7 beats a day would
#     make the DECLARED cadence a description of a platform outage, and would
#     take the bound from 90m to 600m — ten hours of real silence invisible.
#
# ── THE CADENCE MEASURE (a second question, asked separately) ───────────────
# THE AGE CHECK ANSWERS "IS IT LATE RIGHT NOW". IT CANNOT ANSWER "IS THIS
# CADENCE BEING DELIVERED", and task-lease-renew.yml is the specimen: it
# violates its own 60m bound on 100% of 120 measured gaps while the probe
# truthfully reports it INSIDE BOUND every time it happens to have just fired.
# Both answers are true; they are answers to different questions, and only one
# of them was ever printed.
#
# So for every critical row the probe now ALSO computes, over a trailing window
# (default 24 h) of that workflow's own run rows:
#   expected  = span / declared interval
#   delivered = run rows with event=schedule in that span
#   rescued   = run rows with event=workflow_dispatch in that span
# and prints delivered/expected as a percentage, plus the rescue share, plus —
# when rescues outnumber schedule runs — the sentence THIS PROBE IS THE PRIMARY
# DELIVERY MECHANISM. That line is the whole point: a reader seeing
# `Cron overdue probe: success` may now find out which mechanism earned it.
#
# WHY THE FLOOR IS 50% AND WHY IT IS A WARNING, NOT A RED. 50% is read off the
# QUIET window (59% and 54% delivery) and the degraded ones (31%/29% full,
# 13%/13% last-7d): it separates the August platform from today's, which is the
# only discrimination a floor can honestly make. It is a WARNING because at 13%
# delivery, across three workflows with different declared intervals, the
# condition is a property of GitHub's scheduler on this repo that NO pull
# request can clear — a red here would be red every day, and a true alarm
# nobody can act on trains the fleet to ignore the one alarm watching a silent
# watch, which is this row's own stated failure mode reached from a new side.
# The escalation lever exists and is named: `--cadence-strict` exits 4, a code
# DISTINCT from 1 (late right now, or a rescue that failed) and from the
# no-run-row scream. Nothing in CI passes it today; when GitHub's delivery
# recovers, turning it on is a one-flag change with a fixture already proving
# it fires.
#
# THE SPAN IS WHAT THE FETCHED PAGE COVERS, not a fixed 24 h, and the rate is
# computed against THAT span — so a push-armed workflow whose 60 rows only reach
# back 9 h is scored over 9 h, never over a window it has no rows for. The
# window flag is a CEILING on the span, never a claim about it. And the line
# names all three sources (schedule:, this probe's rescue, any other trigger),
# because "breakglass-watch fired 60 times" and "the scheduler delivered 2 of
# its 18 promised beats" are both true and only the second is this measure.
#
# THE MEASURE IS SILENT RATHER THAN WRONG when it has too little history: fewer
# than 3 rows in the window, or a span under 4x the interval, prints "not
# measured" and scores nothing. A cadence verdict computed from two samples is
# the row-cap trap in miniature.
#
# USAGE
#   bash scripts/cron-overdue-probe.sh                       # live, this repo
#   bash scripts/cron-overdue-probe.sh --runs-file <ndjson> --now <iso>   # hermetic
#   bash scripts/cron-overdue-probe.sh --table <file>        # override the table
#   bash scripts/cron-overdue-probe.sh --no-dispatch         # report only, never fire
#   bash scripts/cron-overdue-probe.sh --config-only         # table-vs-tree only
#   bash scripts/cron-overdue-probe.sh --selftest            # no network
#   bash scripts/cron-overdue-probe.sh --cadence-strict      # delivery shortfall reds (exit 4)
#   bash scripts/cron-overdue-probe.sh --cadence-window <min> --cadence-floor <pct>
#
# THE CONFIG QUESTION AND THE LIVE QUESTION ARE ASKED SEPARATELY (2026-09-07,
# task-16df558f0d748713). "Is every scheduled workflow classified?" is a fact
# about the REPO. "Has a critical-cadence workflow gone silent?" is a fact about
# GITHUB RIGHT NOW. They used to be welded together twice over — the selftest's
# c1 asserted the repo's classification, and the report path did `check_table ||
# exit 2` before it ever reached the overdue read — so ONE unclassified
# `schedule:` disarmed the live safety net. Measured: 42 consecutive failing
# runs and the overdue check dark for ~15h50m (2026-09-07T01:09:42Z..~16:59Z),
# during which main-gate-watch.yml sat 238m past a 90m bound and nothing said
# so. Now: the drift still REFUSES and still exits non-zero, but it no longer
# answers a question it was not asked. --config-only is that question alone.
#
# THE HERMETIC INPUT IS RAW. --runs-file takes the newest run row per workflow
# exactly as the API emits it — {"path": ".github/workflows/x.yml", "status":
# "...", "created_at": "..."} — never a pre-computed age, because a fixture that
# arrives already judged proves only that the harness can read its own answer.
#
# EXIT CODES
#   0 every critical-cadence workflow fired inside its bound
#   1 OVERDUE — at least one critical workflow is silent past 3x its interval
#   2 the table and the tree disagree, a fallback is missing, or usage. In
#     report mode this is now reached only when the CRON read itself came back
#     clean: a drift never masks 1 or 3, and never suppresses the cron verdict.
#   3 the run list could not be read — UNKNOWN, never reported as fired
#   4 CADENCE SHORTFALL under --cadence-strict only — a declared schedule is
#     being delivered below the floor. DISTINCT from 1 on purpose: 1 means a
#     workflow is late or dark RIGHT NOW; 4 means the beats are arriving but
#     not at the declared rate. Never returned without the flag.
#
# ENV
#   CRON_PROBE_GH          the gh binary (stubbed by the selftest's dispatch arm)
#   CRON_PROBE_REPO_ROOT   override the repo root (the selftest runs a MUTATED
#                          copy of this file from a temp dir and still needs the
#                          real tree for the table/fallback reads)
#   CRON_PROBE_POLL_TRIES  how many times to look for the dispatched run (12)
#   CRON_PROBE_POLL_SLEEP  seconds between those looks (5)
#   CRON_PROBE_RUNS_PER_PAGE  how many run rows per workflow the live read
#                          fetches (60). The age check needs one; the cadence
#                          measure needs a history, and this is that history.

# INTERPRETER GUARD — MEASURED 2026-09-09 by RUNNING it, not by grepping
# (task-b896488e115d1eed). `sh scripts/cron-overdue-probe.sh` on this Mac's bash 3.2.57 in
# POSIX mode (which is what /bin/sh is here) exited 0.
#
# WHY THAT 0 IS A LIE HERE: the process substitution(s) at line(s) 307, 308 sit
# inside a command substitution, so bash parses them only when the $( ) is
# expanded. Under POSIX mode that expansion printed
#   scripts/cron-overdue-probe.sh: command substitution: syntax error near unexpected token `('
# to stderr, the captured variable came back EMPTY, and an empty diff/comm reads
# as "no drift" — after which this script printed its own OK/PASS/VERDICT line.
# The verdict was rendered; the comparison behind it never ran. That was observed
# in the 2026-09-09 census, on a clean tree, in this script's own output.
#
# CI IS NOT EXPOSED: every workflow invokes this with `bash`. This is an agent-
# and operator-facing trap — someone typing `sh scripts/cron-overdue-probe.sh` out of habit —
# and it is recorded here as one, not overstated as a CI hole.
#
# The guard below is copied verbatim (modulo the script name) from
# scripts/required-checks.test.sh:119-129. It must stay POSIX-parseable and must
# stay ABOVE the first process substitution: bash reads incrementally, so
# anything the guard sits after is code a POSIX-mode shell has already run.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "cron-overdue-probe.sh: needs bash (this script uses process substitution); run: bash scripts/cron-overdue-probe.sh${1:+ $1}" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "cron-overdue-probe.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this script's process substitution; run: bash scripts/cron-overdue-probe.sh${1:+ $1}" >&2
    exit 2
    ;;
esac

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
# THE CADENCE MEASURE'S TWO KNOBS AND ITS SWITCH. See the 2026-09-20 header
# section: the floor is read off the QUIET window (59%/54% delivery) against
# the degraded ones (13%), and the default is a WARNING because no PR can
# clear a platform-wide delivery shortfall.
CADENCE_WINDOW_MIN=1440
CADENCE_FLOOR_PCT=50
CADENCE_STRICT=0
# Set by check_overdue when a critical workflow's schedule delivery is under
# the floor. It is a SECOND verdict and never touches the overdue return code.
CADENCE_SHORTFALL=0
CADENCE_MEASURED=0
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
#
# 2026-09-13 (task-3d58169ded21964a): five rows added, taking the table to 28
# against the 28 workflows carrying a `schedule:` on origin/main e02933779 —
# cli-release-cadence, pds-scratch-round-trip, posix-vacuous-green-census,
# release-curator-draft, seal-reading. They were NOT a hidden drift: main's own
# push arm reported them on every merge (run 34759749673, 2026-09-13T13:27Z,
# "REFUSED: scheduled workflow(s) carry no classification line" naming all five,
# and the same red on every completed push:main run that day). Nobody had
# classified them, so every workflow-touching PR inherited main's red through
# the harness job's pull_request arm — the cost of leaving a true refusal
# standing, not a defect in where it is asked. NONE of the five is critical:
# each is an audit, a measurement or a digest whose lag costs a sample, and
# three of them deliberately carry no push: arm (pds-scratch-round-trip and
# release-curator-draft have none at all), which is exactly the case
# check_fallbacks would wrongly demand a trigger for if they were critical.
DEFAULT_TABLE='absent-context-census.yml|periodic|360|2026-09-03: 6 h absence audit; 2026-09-23 (task-a0abaae6f64c0a9c): the cron is now its FLOOR, beside a workflow_run leg on the four required-context producers and a self re-arm, so a fresh run usually exists long before 6 h. Its harness (absent-context-census.test.sh §7) still forbids a pull_request arm, and it has no push arm, so a 6 h tolerance on the floor stays correct.
breakglass-watch.yml|critical|30|2026-09-03: watches whether branch protection was broken open. Carries push: branches [main] — cron silence cannot hide an unrestored breakglass across a merge.
chronicle-paper.yml|report|1440|2026-09-03: nightly narrative digest. A late chronicle is a late chronicle.
cli-release-cadence.yml|periodic|10080|2026-09-13: weekly (cron 14 9 * * 4) check that the shipped `bp` has not moved past the newest installable `cli-v*` release; carries push: branches [main] AND an unfiltered pull_request arm, so a week of cron silence still leaves it running on every merge and every PR. PERIODIC, not critical: its red is cleared by an ACT OF RELEASE (`git tag cli-v<semver>`), never by a change to any PR, and its own header says so and refuses promotion to the required set. Same shape as the pipefail-sigpipe-scan/posix-vacuous-green-census rows.
codebase-intel.yml|report|10080|2026-09-03: weekly intelligence sweep. Weekly cadence, weekly tolerance.
cron-overdue-probe.yml|critical|60|2026-09-03: this probe itself. Hourly, and it carries push: branches [main] — a silence watch delivered only by the mechanism it watches is a smoke detector wired to the fire. It appeared in this table because its own table/tree check REFUSED the first live run that did not classify it.
crown-reconcile.yml|periodic|360|2026-09-03: 6 h reconciliation sweep; carries push: branches [main] already.
deploy-harnesses.yml|periodic|1440|2026-09-06: nightly re-run of the deploy harnesses (cron 03:20Z) so a rot in deploy/ is seen within a day; carries push: branches [main]. Added when cron-overdue-probe c1 reddened main on the three schedules landed after the 2026-09-03 table.
deploy-prod-microblock-staleness.yml|periodic|360|2026-09-20 (task-dd27173ac5b52b0c): 6-hourly (cron 40 2,8,14,20 * * *) read of the prod micro-block 89.167.28.206 status.json commit against origin/main — the reader that is not a person. PERIODIC, not critical: its subject is a SERVER a human deploys by `git pull` on the box, so a lag costs one sample of a gap that has already stood for days, and its scheduled red is the finding, not a hole in a safety net. Carries an unfiltered pull_request arm (the harness job) so cron is not its only way to fire.
elixir-nightly.yml|report|1440|2026-09-03: the long Elixir suite, nightly. Its reds are found the next morning either way.
grip-suite.yml|periodic|1440|2026-09-06: nightly Grip suite (cron 03:25Z); carries push: branches [main]. Same 2026-09-06 c1 red as deploy-harnesses.
landed-open-report.yml|report|1440|2026-09-07: daily ledger digest (cron 06:27Z), wired in #16640. Classified report, not critical: its own header states a red here means THE READ FAILED, findings exit 0 to the step summary, and it deliberately carries no push: arm so it renders no check run anywhere. A day late is a day late — and report class is what leaves check_fallbacks satisfied without inventing a trigger this workflow was designed not to have.
main-gate-watch.yml|critical|30|2026-09-03: the second scream on main tip verdicts. push-refused:scripts/main-gate-watch.test.sh — a push arm was MEASURED harmful (wave 60 D721: 2 of 2 push runs red on tip 026c5b1d78 while main was green, because ~15 s after a merge no check-run row exists yet) and a committed test reds if one comes back. Its fallback is THIS probe: a workflow that may not carry a trigger fallback must at least be watched for silence.
main-red-owner.yml|critical|60|2026-09-16 (task-6005859f86872319): hourly. Converts the verdict of scripts/main-red-predicate.sh into ONE deduped GitHub issue, so an ADVISORY workflow red on the tip of main has an owner instead of standing 11 h across 8 consecutive runs with nobody on it, which is exactly what posix-vacuous-green-census did. CRITICAL because its silence IS the defect it exists to abolish: nothing else in this tree notices a red that cannot block a merge. Carries push: branches [main] as its trigger fallback, so cron silence cannot hide a red introduced by a merge.
paper-readers.yml|report|1440|2026-09-03: daily paper-reader digest; did not run at all on 09-03, which is the tolerated case for a report.
pds-scratch-round-trip.yml|periodic|1440|2026-09-13: daily (cron 47 4 * * *) boot/verify/teardown of the PDS scratch target. SCHEDULE + workflow_dispatch ONLY and it may stay that way: its own header measures the run at >10 minutes (two full compiles) and calls a per-PR venue a WRONG build, so push/pull_request arms are deliberately absent. PERIODIC, not critical, precisely so check_fallbacks does not demand a trigger this workflow was designed not to have — the same argument landed-open-report.yml carries. A day-late drift report on crown infrastructure costs a day.
pipefail-sigpipe-scan.yml|periodic|10080|2026-09-09: weekly repo-state scan for pipelines that can return 141 instead of a verdict (cron 41 5 * * 1, wired in #17081). PERIODIC because the whole point is the sweep, not the minute: the class it hunts is latent and static, a week late costs nothing, and it carries push: branches [main] plus a pull_request arm, so a week of cron silence still leaves it running on every merge. Same shape as the twoslash/grip-suite/deploy-harnesses rows.
posix-vacuous-green-census.yml|periodic|10080|2026-09-13: weekly (cron 23 17 * * 2) census of scripts/*.sh using process substitution without an interpreter guard. PERIODIC for the same reason pipefail-sigpipe-scan.yml is, and it is the file that row already names as its own shape: the class is latent and static, a week late costs nothing, and it carries push: branches [main] plus an unfiltered pull_request arm, so cron is far from its only way to fire.
pr-meta.yml|periodic|1440|2026-09-09: the nightly venue of the filebase aesthetics critic (cron 17 5 * * *), moved off the PR path in #17079 because it was 573 s of a 615 s run for an advisory that cannot block a merge. PERIODIC, not critical: the critic is an advisory score sweep with its own watcher, it is ADDITIONALLY armed by push: branches [main] (scoped to changes under tooling/aesthetics/ or this workflow), and a skipped night costs a score sample, not a safety net.
release-curator-draft.yml|report|1440|2026-09-13: daily (cron 10 7 * * *) scan of main that opens or refreshes ONE draft GitHub Release for a human to bless. REPORT, not critical: schedule + workflow_dispatch are the ONLY triggers by design (its header rules out a push arm as noise that would make the draft chase main), and report class is what leaves check_fallbacks satisfied without inventing that trigger — the landed-open-report.yml argument again. A day late is a day late: the draft is a standing invitation, not a safety net.
renew-mail-cert.yml|report|43200|2026-09-03: monthly certificate renewal. 3x a month is a 90-day bound, which is not a useful alarm — the certificate expiry is the alarm, and it is watched where it lands, not here.
required-checks-drift.yml|periodic|1440|2026-09-03: daily drift audit of the required set; carries push: branches [main] already.
scaffy-catalog-drift.yml|report|1440|2026-09-03: daily catalog drift digest; carries push: branches [main].
seal-reading.yml|periodic|1440|2026-09-13: the one MACHINE-TAKEN seal reading (cron 20 6 * * *), plus push: branches [main] — a reading per merged state, and a daily tick because the rungs of the register can rot without a commit. PERIODIC: it is a MEASUREMENT whose CONTENT never reds it (charter D335 — only a refusal or an infra fault does), it gates no merge, and it deliberately has no pull_request arm because seal-run.sh refuses a reading taken off a tree that is not the tip of origin/main.
scheduled-arm-health.yml|report|1440|2026-09-15: daily (cron 20 7 * * *) read of every cron-declaring workflow in the tree against its real scheduled-run history (task-c1148783a9ee36e7). REPORT, not critical: schedule + workflow_dispatch are the ONLY triggers BY DESIGN - its subject is the GitHub run history, which no diff changes, so a push or pull_request arm would be ~90 gh api calls of pure noise on every PR. Report class is what leaves check_fallbacks satisfied without inventing a trigger this workflow was designed not to have - the landed-open-report.yml and release-curator-draft.yml argument again. A day late costs a day of a finding that has already sat six weeks; the reading is a standing alarm, not a safety net.
search-starter-smoke.yml|report|1440|2026-09-03: daily starter smoke; carries push: branches [main].
stale-verdict-watch.yml|critical|30|2026-09-03: watches PRs asserting a green main has moved past. Carries push: branches [main].
studio-journey-smoke.yml|report|1440|2026-09-03: daily Studio journey smoke; carries push: branches [main].
task-lease-renew.yml|critical|20|2026-09-03: the claim sweep. Ran ZERO times in 3 h on 09-03; push: branches [main] was added in #15757 and is present.
twoslash.yml|periodic|1440|2026-09-06: nightly twoslash type-check of the documentation snippets (cron 03:30Z); carries push: branches [main]. Same 2026-09-06 c1 red as deploy-harnesses.
weekly-changelog.yml|report|10080|2026-09-03: weekly changelog digest.'

usage() { sed -n '2,239p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --table)      TABLE_FILE="$2"; shift 2 ;;
    --runs-file)  RUNS_FILE="$2"; shift 2 ;;
    --now)        NOW_ISO="$2"; shift 2 ;;
    --workflows)  WORKFLOWS_DIR="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --factor)     OVERDUE_FACTOR="$2"; shift 2 ;;
    --no-dispatch) DISPATCH=0; shift ;;
    --cadence-window) CADENCE_WINDOW_MIN="$2"; shift 2 ;;
    --cadence-floor)  CADENCE_FLOOR_PCT="$2"; shift 2 ;;
    # THE ESCALATION LEVER, off by default and not passed anywhere in CI.
    # It makes a delivery shortfall exit 4 — a code DISTINCT from 1 (late or
    # dark right now) so the two findings can never be read as each other.
    --cadence-strict) CADENCE_STRICT=1; shift ;;
    # The CONFIGURATION question on its own: is every scheduled workflow in the
    # tree classified, and does every critical cadence carry a fallback? It
    # touches no network and reads no run list, which is exactly why it can be
    # asked in a place that does not gate the live read.
    --config-only) MODE=config; shift ;;
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
    # per_page 60, and `event` is carried. 5 rows answered the AGE question and
    # nothing else; the cadence measure needs a HISTORY, and the event field is
    # what tells a delivered beat (`schedule`) from a rescue this probe itself
    # fired (`workflow_dispatch`). Same endpoint, same paginated REST shape, one
    # call per workflow exactly as before — the page is wider, not extra.
    out="$("$(gh_bin)" api "repos/$REPO/actions/workflows/$file/runs?per_page=${CRON_PROBE_RUNS_PER_PAGE:-60}" \
             --jq ".workflow_runs[] | {path: \"$file\", status: .status, created_at: .created_at, event: .event}" 2>&1)"; grc=$?
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

# ── 3c. THE CADENCE MEASURE (task-edebe459992b3574) ─────────────────────────
# A SECOND QUESTION, AND IT IS NOT THE AGE QUESTION. check_overdue below asks
# "how old is the newest run", which answers IS IT LATE RIGHT NOW and nothing
# else. The specimen that proves those are different questions is
# task-lease-renew.yml: 120 of 120 measured gaps exceed its own 60m bound, and
# the probe reports it INSIDE BOUND — truthfully — every time it looks a minute
# after a firing. WHEN IS THE NEXT BEAT DUE beats HOW OLD IS THE LAST BEAT.
#
# So this reads the SAME rows check_overdue reads (no extra network call) and
# counts, over a trailing window, how many of the beats the declared interval
# promises actually arrived by `schedule:` — and how many firings in that window
# were this probe's own workflow_dispatch rescues. The rescue count is the half
# that makes the green legible: since 2026-09-06 a cron-only critical workflow
# past bound is DISPATCHED and the probe reports ok, so "success" can mean
# "the scheduler delivered" or "this probe carried it" and nothing said which.
#
# IT IS SILENT RATHER THAN WRONG. Fewer than 3 rows in the window, or a span
# shorter than 4x the interval, and it prints NOT MEASURED and scores nothing.
# A cadence computed from two samples is the row-cap trap in miniature — and it
# is also what keeps every pre-existing single-row hermetic fixture untouched:
# one run row per workflow cannot and must not produce a cadence verdict.
cadence_verdict() { # <file> <interval> <rows> <now-epoch>
  local file="$1" interval="$2" rows="$3" now="$4"
  local m status span nrows expected sched disp other pct firings primary min_span
  m="$(printf '%s\n' "$rows" | grep -F "\"$file\"" | python3 -c '
import json, sys, datetime
now = float(sys.argv[1]); interval = float(sys.argv[2]); win = float(sys.argv[3])
rows = []
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
    # THE PHANTOM-QUEUED TRAP, applied here too (c6): a permanently-queued row
    # is evidence of nothing, and counting it as a delivered beat would inflate
    # the very number this measure exists to deflate.
    if o.get("status") == "queued" and (now - e) > 1440 * 60: continue
    if e > now or e < now - win * 60: continue
    rows.append((e, o.get("event") or ""))
if len(rows) < 3:
    print("INSUFFICIENT|0|%d|0|0|0|0" % len(rows)); raise SystemExit
span = (now - min(e for e, _ in rows)) / 60.0
if span < 4 * interval:
    print("INSUFFICIENT|%d|%d|0|0|0|0" % (round(span), len(rows))); raise SystemExit
expected = span / interval
sched = sum(1 for _, ev in rows if ev == "schedule")
disp  = sum(1 for _, ev in rows if ev == "workflow_dispatch")
print("MEASURED|%d|%d|%d|%d|%d|%d|%d" % (
    round(span), len(rows), round(expected), sched, disp,
    len(rows) - sched - disp, round(100.0 * sched / expected) if expected > 0 else 0))
' "$now" "$interval" "$CADENCE_WINDOW_MIN" 2>/dev/null)" || true
  IFS='|' read -r status span nrows expected sched disp other pct <<EOF
$m
EOF
  min_span=$(( interval * 4 ))
  if [ "${status:-}" != "MEASURED" ]; then
    echo "  --   $file (cadence): NOT MEASURED — ${nrows:-0} run row(s) spanning ${span:-0}m, under the 3-row / ${min_span}m minimum. Too little history to score a delivery rate; that is silence about this question, not a pass on it."
    return 0
  fi
  CADENCE_MEASURED=$(( CADENCE_MEASURED + 1 ))
  firings=$(( sched + disp + other ))
  primary=""
  [ "$disp" -gt "$sched" ] && primary=" — SO THIS PROBE, NOT THE SCHEDULER, IS THE PRIMARY DELIVERY MECHANISM for it"
  if [ "$pct" -lt "$CADENCE_FLOOR_PCT" ]; then
    CADENCE_SHORTFALL=$(( CADENCE_SHORTFALL + 1 ))
    echo "CADENCE  $file (critical, every ${interval}m): the SCHEDULER delivered $sched of ~$expected expected beats over the last ${span}m — ${pct}% of its declared cadence, under the ${CADENCE_FLOOR_PCT}% floor. It fired $firings times in that window: $sched by schedule:, $disp by THIS PROBE's workflow_dispatch rescue, $other by another trigger (push/pull_request)${primary}. THIS IS A DELIVERY FINDING, NOT 'late right now' — the age line below answers that question on its own, and it may well say inside-bound." >&2
  else
    echo "  ok   $file (cadence): $sched of ~$expected expected beats delivered by schedule: over the last ${span}m (${pct}% of the declared ${interval}m cadence, floor ${CADENCE_FLOOR_PCT}%); of $firings firings, $disp were probe dispatches and $other came from another trigger"
  fi
}

check_overdue() {
  local now rows rc=0 file class interval note newest age bound runid=""
  now="$(now_epoch)" || { echo "cron-overdue-probe: --now is not an ISO-8601 Z timestamp" >&2; return 2; }
  rows="$(read_runs)" || { echo "UNKNOWN: the run list could not be read — that is not 'it fired'." >&2; return 3; }
  while IFS='|' read -r file class interval note; do
    [ -n "$file" ] || continue
    [ "$class" = "critical" ] || continue
    # THE CADENCE QUESTION FIRST, AND ANSWERED ON ITS OWN LINE. It never touches
    # $rc: a delivery shortfall is a second verdict, not a scream, and it must
    # not be able to mask or be masked by the age answer that follows it.
    cadence_verdict "$file" "$interval" "$rows" "$now"
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

  # c1 — THE COMPARISON CAN WIN, and that is ALL this arm asks now.
  #
  # It used to ask "does THIS repo's table match THIS repo's tree", which is a
  # CONFIGURATION fact, not a fact about whether the probe still works — and the
  # workflow runs this selftest as the tripwire BEFORE the live overdue read, so
  # bundling the two meant one unclassified `schedule:` skipped the live check
  # entirely. It did: 42 consecutive failing runs, the overdue check dark for
  # ~15h50m on 2026-09-07, and main-gate-watch.yml 238m past a 90m bound behind
  # it (task-16df558f0d748713). The configuration question is still asked and
  # still REFUSES — `--config-only`, in its own workflow step and in the PR
  # harness — it is simply not asked here, where a wrong answer disarms a probe.
  #
  # So c1 feeds check_table a table GENERATED FROM the tree and requires
  # acceptance. Non-vacuous the same way it always was: a set comparison against
  # an empty tree passes trivially, so the tree must hold at least 10 files.
  # A WORKFLOWS DIR THE TABLE AGREES WITH BY CONSTRUCTION. The whole-program
  # arms far below (c8d/c8d2) run the REPORT path, and the report path now
  # reports a config drift instead of returning early — so one unclassified
  # workflow in the real tree would turn c8d2's POSITIVE CONTROL red for a
  # reason that has nothing to do with the dispatch arm it is controlling. That
  # is this very defect one level down: measured on a planted unclassified
  # workflow, 2026-09-07, c8d2 was the last arm still coupled to repo config.
  # Point those arms at a directory holding exactly the table's own files.
  local _tf
  mkdir -p "$tmp/wf"
  while IFS='|' read -r _tf _ _ _; do
    [ -n "$_tf" ] || continue
    [ -f "$WORKFLOWS_DIR/$_tf" ] && cp "$WORKFLOWS_DIR/$_tf" "$tmp/wf/$_tf"
  done <<EOF
$(table)
EOF

  local n_tree
  n_tree="$(scheduled_files | awk 'END{print NR}')"
  scheduled_files | awk '{print $0 "|periodic|1440|synthetic row, generated from the tree by selftest c1"}' > "$tmp/tree-table"
  if TABLE_FILE="$tmp/tree-table" check_table >/dev/null 2>&1 && [ "$n_tree" -ge 10 ]; then
    pass=$((pass+1)); echo "  ok   c1 a table generated from the $n_tree scheduled workflow(s) in the tree is ACCEPTED — the comparison can WIN, and this arm no longer depends on how the repo happens to be classified today"
  else
    fail=$((fail+1)); echo "  FAIL c1 a table generated from the tree itself was refused ($n_tree scheduled files found)"; TABLE_FILE="$tmp/tree-table" check_table
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
{"path": "main-red-owner.yml", "status": "completed", "created_at": "2026-09-03T11:43:00Z"}
{"path": "task-lease-renew.yml", "status": "in_progress", "created_at": "2026-09-03T11:50:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX
  out="$(RUNS_FILE="$tmp/fresh.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c2 every critical workflow with a run in the last 20m passes — the probe is quiet when cron is healthy"
  else
    fail=$((fail+1)); echo "  FAIL c2 a healthy fixture reddened (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # ── A CONFIG DRIFT MUST NOT DISARM THE LIVE READ (task-16df558f0d748713) ──
  # These four arms are the regression test for the whole point of this change.
  # Run as WHOLE PROGRAMS, so what is asserted is the process exit code and the
  # printed verdicts a human actually reads — not an internal return value.
  #
  # c1c — drift present, cron healthy: BOTH verdicts are printed, and the cron
  # read genuinely ran. Before this change the script returned at `check_table
  # || exit 2` and there was no cron verdict at all.
  cat > "$tmp/drift-lag.ndjson" <<'FIX'
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z"}
{"path": "main-red-owner.yml", "status": "completed", "created_at": "2026-09-03T11:43:00Z"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T09:00:00Z"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z"}
FIX
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$WORKFLOWS_DIR" \
           --table "$tmp/short-table" --runs-file "$tmp/fresh.ndjson" --now "$NOW" --no-dispatch 2>&1)"; rc=$?
  if [ "$rc" = "2" ] \
     && grep -q 'REFUSED: scheduled workflow(s) carry no classification line' <<<"$out" \
     && grep -q 'VERDICT  config: DRIFT' <<<"$out" \
     && grep -q 'VERDICT  cron: every critical-cadence workflow fired' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c1c an UNCLASSIFIED scheduled workflow REFUSES loudly (exit 2) and the cron verdict is still produced — the drift no longer takes the live read with it"
  else
    fail=$((fail+1)); echo "  FAIL c1c the drift suppressed the cron verdict or stopped refusing (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c1d — drift present AND a critical workflow overdue: the SCREAM owns the
  # exit code (1, never laundered into a 2 that reads like a config chore) and
  # the drift line is still printed. Neither verdict masks the other.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$WORKFLOWS_DIR" \
           --table "$tmp/short-table" --runs-file "$tmp/drift-lag.ndjson" --now "$NOW" --no-dispatch 2>&1)"; rc=$?
  if [ "$rc" = "1" ] \
     && grep -q 'OVERDUE  task-lease-renew.yml' <<<"$out" \
     && grep -q 'VERDICT  cron: SCREAM' <<<"$out" \
     && grep -q 'VERDICT  config: DRIFT' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c1d with a drift AND an overdue critical workflow, the exit code is the SCREAM (1) and both verdicts print — a drift cannot launder a silent safety net into a config chore"
  else
    fail=$((fail+1)); echo "  FAIL c1d the drift and the scream interfered (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c1e — --config-only asks the drift question ALONE, and refuses.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$WORKFLOWS_DIR" \
           --table "$tmp/short-table" --config-only 2>&1)"; rc=$?
  if [ "$rc" = "2" ] && grep -q 'VERDICT  config: DRIFT' <<<"$out" \
     && grep -q 'main-gate-watch.yml' <<<"$out" \
     && ! grep -q 'VERDICT  cron:' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c1e --config-only REFUSES the same drift (exit 2), names the workflow, and reads no run list at all — the drift has a home that is not the tripwire"
  else
    fail=$((fail+1)); echo "  FAIL c1e --config-only did not refuse the drift cleanly (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c1e2 — and --config-only can PASS: the tree-generated table is accepted, so
  # c1e is a question that can go either way rather than a mode that always reds.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$WORKFLOWS_DIR" \
           --table "$tmp/tree-table" --config-only 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && grep -q 'VERDICT  config: every scheduled workflow' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c1e2 …and --config-only ACCEPTS a table that matches the tree — c1e is a question that can win"
  else
    fail=$((fail+1)); echo "  FAIL c1e2 --config-only refused a table generated from the tree (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
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
{"path": "main-red-owner.yml", "status": "completed", "created_at": "2026-09-03T11:43:00Z"}
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
{"path": "main-red-owner.yml", "status": "completed", "created_at": "2026-09-03T11:43:00Z"}
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
{"path": "main-red-owner.yml", "status": "completed", "created_at": "2026-09-03T11:43:00Z"}
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
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$tmp/nodispatch.sh" --workflows "$tmp/wf" \
           --runs-file "$tmp/lag92.ndjson" --now "$NOW" 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  main-gate-watch.yml' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c8d …and with the dispatch arm removed the SAME 92m fixture reds again — c8a is the arm doing the work, not the fixture"
  else
    fail=$((fail+1)); echo "  FAIL c8d the mutant still passed (rc=$rc) — c8a proves nothing"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
  # …and the positive control: the UNMUTATED script, same invocation, exits 0.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$tmp/wf" \
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
  # ══ c9 — THE CADENCE MEASURE (task-edebe459992b3574) ══════════════════════
  # THE SPECIMEN IS THE ROW'S OWN: task-lease-renew.yml (*/20, bound 60m), which
  # violated its 60m bound on 120 of 120 gaps measured 2026-09-20 and which the
  # probe reported INSIDE BOUND — truthfully — whenever it looked just after a
  # firing. This fixture is exactly that shape: newest run 2 MINUTES old, and
  # every trailing gap far past the bound. The age answer and the cadence answer
  # must both be printed, must disagree, and must be labelled so a reader cannot
  # mistake one for the other.
  cat > "$tmp/chronic-late.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:40:00Z", "event": "schedule"}
{"path": "breakglass-watch.yml", "status": "completed", "created_at": "2026-09-03T11:41:00Z", "event": "schedule"}
{"path": "stale-verdict-watch.yml", "status": "completed", "created_at": "2026-09-03T11:42:00Z", "event": "schedule"}
{"path": "main-red-owner.yml", "status": "completed", "created_at": "2026-09-03T11:43:00Z", "event": "schedule"}
{"path": "cron-overdue-probe.yml", "status": "completed", "created_at": "2026-09-03T11:45:00Z", "event": "schedule"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T11:58:00Z", "event": "schedule"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T09:30:00Z", "event": "schedule"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T06:45:00Z", "event": "schedule"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-03T03:10:00Z", "event": "schedule"}
{"path": "task-lease-renew.yml", "status": "completed", "created_at": "2026-09-02T23:40:00Z", "event": "schedule"}
FIX
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$tmp/wf" \
           --runs-file "$tmp/chronic-late.ndjson" --now "$NOW" --no-dispatch 2>&1)"; rc=$?
  if [ "$rc" = "0" ] \
     && grep -q 'CADENCE  task-lease-renew.yml' <<<"$out" \
     && grep -q 'newest run 2m old, inside the 60m bound' <<<"$out" \
     && grep -q 'VERDICT  cadence: DEGRADED' <<<"$out" \
     && grep -q 'VERDICT  cron: every critical-cadence workflow fired' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9a the CHRONICALLY-LATE specimen is caught by the CADENCE measure while the AGE measure says inside-bound, and the two answers are printed separately: $(grep -o 'CADENCE  task-lease-renew.yml.*floor\.' <<<"$out")"
  else
    fail=$((fail+1)); echo "  FAIL c9a the chronic-lateness specimen was not split into two answers (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c9a2 — and the AGE measure really did say inside-bound on that same fixture,
  # asserted as an ABSENCE of the scream as well as a presence of the ok line.
  # Without this, c9a would pass on a fixture that reddened for the ordinary
  # reason and printed a cadence line as a bonus.
  if ! grep -q 'OVERDUE  task-lease-renew.yml' <<<"$out" \
     && ! grep -q 'VERDICT  cron: SCREAM' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9a2 …and NOTHING about that fixture is overdue — the cadence finding is the ONLY finding, which is the whole point of asking the second question"
  else
    fail=$((fail+1)); echo "  FAIL c9a2 the specimen was overdue too, so c9a did not isolate the cadence measure"
  fi

  # c9b — THE DISTINCT EXIT. A delivery shortfall is a WARNING by default (see
  # the 2026-09-20 header: no PR can clear a platform-wide shortfall, and a red
  # nobody can act on is how an alarm gets ignored). --cadence-strict turns the
  # same finding into exit 4 — never 1, so it can never be read as "late or dark
  # right now", and never 2, so it can never be read as a config chore.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$tmp/wf" \
           --runs-file "$tmp/chronic-late.ndjson" --now "$NOW" --no-dispatch --cadence-strict 2>&1)"; rc=$?
  if [ "$rc" = "4" ] && grep -q 'VERDICT  cadence: DEGRADED' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9b …and --cadence-strict reds the SAME fixture at exit 4 — a code distinct from 1 (late/dark now), 2 (config drift) and 3 (unreadable)"
  else
    fail=$((fail+1)); echo "  FAIL c9b --cadence-strict did not produce the distinct code (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c9c — AND IT CAN LOSE. The same workflow delivering its declared */20 for
  # five hours is green on BOTH measures. A cadence check that reds on every
  # history is a cadence check nobody reads.
  grep -v 'task-lease-renew' "$tmp/chronic-late.ndjson" > "$tmp/healthy-cadence.ndjson"
  for t in 07:00 07:20 07:40 08:00 08:20 08:40 09:00 09:20 09:40 10:00 10:20 10:40 11:00 11:20 11:40 11:55; do
    echo "{\"path\": \"task-lease-renew.yml\", \"status\": \"completed\", \"created_at\": \"2026-09-03T$t:00Z\", \"event\": \"schedule\"}" \
      >> "$tmp/healthy-cadence.ndjson"
  done
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$tmp/wf" \
           --runs-file "$tmp/healthy-cadence.ndjson" --now "$NOW" --no-dispatch --cadence-strict 2>&1)"; rc=$?
  if [ "$rc" = "0" ] \
     && grep -q 'ok   task-lease-renew.yml (cadence)' <<<"$out" \
     && ! grep -q 'CADENCE  ' <<<"$out" \
     && grep -q 'VERDICT  cadence: every measured critical workflow' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9c a workflow actually delivering its */20 is GREEN on both measures even under --cadence-strict: $(grep -o 'ok   task-lease-renew.yml (cadence).*' <<<"$out")"
  else
    fail=$((fail+1)); echo "  FAIL c9c a healthy cadence was flagged (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c9d — THE LEGIBILITY HALF, which is the reason the row calls the dispatch
  # arm's success a problem: 5 of 7 firings in the window are this probe's own
  # rescues, the scheduler delivered 2, and the verdict must SAY SO. Before this
  # change the identical history printed `cron: every critical-cadence workflow
  # fired inside 3x its interval` and nothing else.
  grep -v 'main-gate-watch' "$tmp/chronic-late.ndjson" > "$tmp/probe-primary.ndjson"
  cat >> "$tmp/probe-primary.ndjson" <<'FIX'
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-02T13:00:00Z", "event": "schedule"}
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T02:00:00Z", "event": "schedule"}
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T04:00:00Z", "event": "workflow_dispatch"}
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T06:00:00Z", "event": "workflow_dispatch"}
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T08:00:00Z", "event": "workflow_dispatch"}
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T10:00:00Z", "event": "workflow_dispatch"}
{"path": "main-gate-watch.yml", "status": "completed", "created_at": "2026-09-03T11:50:00Z", "event": "workflow_dispatch"}
FIX
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$0" --workflows "$tmp/wf" \
           --runs-file "$tmp/probe-primary.ndjson" --now "$NOW" --no-dispatch 2>&1)"; rc=$?
  if [ "$rc" = "0" ] \
     && grep -q 'THIS PROBE, NOT THE SCHEDULER, IS THE PRIMARY DELIVERY MECHANISM' <<<"$out" \
     && grep -q 'It fired 7 times in that window: 2 by schedule:, 5 by THIS PROBE' <<<"$out" \
     && grep -q 'newest run 10m old, inside the 90m bound' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9d a green built out of 5 probe dispatches and 2 scheduled runs SAYS SO: $(grep -o 'CADENCE  main-gate-watch.yml.*MECHANISM for it' <<<"$out")"
  else
    fail=$((fail+1)); echo "  FAIL c9d the probe-as-primary-delivery case was not made legible (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c9e — RED-BEFORE, by a SURGICAL CUT of the cadence DECISION. Not the
  # counting, not the printing: only the comparison against the floor. If c9a
  # passes on the mutant, the measure is decorative.
  sed 's|^  if \[ "$pct" -lt "$CADENCE_FLOOR_PCT" \]; then$|  if false; then|' "$0" > "$tmp/nocadence.sh"
  if [ "$(grep -c '^  if false; then$' "$tmp/nocadence.sh")" = "1" ] \
     && ! diff -q "$0" "$tmp/nocadence.sh" >/dev/null; then
    pass=$((pass+1)); echo "  ok   c9e-mut the cut-the-cadence-decision MUTATION applied — exactly one comparison disabled"
  else
    fail=$((fail+1)); echo "  FAIL c9e-mut the mutation did not apply — c9e below would prove nothing"
  fi
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$tmp/nocadence.sh" --workflows "$tmp/wf" \
           --runs-file "$tmp/chronic-late.ndjson" --now "$NOW" --no-dispatch --cadence-strict 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && ! grep -q 'CADENCE  task-lease-renew.yml' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9e …and with that ONE comparison cut, the chronic-lateness specimen goes silent and exits 0 — c9a/c9b are the decision doing the work, not the fixture"
  else
    fail=$((fail+1)); echo "  FAIL c9e the mutant still flagged the specimen (rc=$rc) — c9a proves nothing"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
  # c9e2 — AND THE MUTANT MUST NOT MOVE THE OTHER TWO ARMS. A cut that also
  # broke the dead-workflow scream or the healthy fixture would make c9e a
  # measurement of something else entirely.
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$tmp/nocadence.sh" --workflows "$tmp/wf" \
           --runs-file "$tmp/gap6h.ndjson" --now "$NOW" --no-dispatch 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'OVERDUE  main-gate-watch.yml' <<<"$out" && grep -q '360m old' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9e2 …and the SAME mutant still reds the 6 h dead-workflow fixture (c3's) at exit 1 — the cut touched the cadence decision and nothing else"
  else
    fail=$((fail+1)); echo "  FAIL c9e2 the cadence mutation also broke the dead-workflow scream (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
  out="$(CRON_PROBE_REPO_ROOT="$REPO_ROOT" bash "$tmp/nocadence.sh" --workflows "$tmp/wf" \
           --runs-file "$tmp/healthy-cadence.ndjson" --now "$NOW" --no-dispatch --cadence-strict 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    pass=$((pass+1)); echo "  ok   c9e3 …and it still passes the healthy-cadence fixture — the mutant differs from this script on exactly the one fixture c9a is about"
  else
    fail=$((fail+1)); echo "  FAIL c9e3 the cadence mutation reddened the healthy fixture (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  # c9f — THE HISTORY-SHAPED INPUT DID NOT BREAK THE ONE-ROW FIXTURES. Every
  # arm above c9 feeds --runs-file the newest row per workflow and no event
  # field at all; those must keep meaning exactly what they meant, which is why
  # the measure refuses to score under 3 rows / 4x the interval rather than
  # inventing a rate from one sample.
  out="$(RUNS_FILE="$tmp/fresh.ndjson" NOW_ISO="$NOW" check_overdue 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && [ "$(grep -c '(cadence): NOT MEASURED' <<<"$out")" = "6" ] \
     && ! grep -q 'CADENCE  ' <<<"$out"; then
    pass=$((pass+1)); echo "  ok   c9f the pre-existing one-row-per-workflow fixtures score NO cadence at all — all 6 critical rows print NOT MEASURED, and a rate is never invented from one sample"
  else
    fail=$((fail+1)); echo "  FAIL c9f a single run row produced a cadence verdict (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/       /'
  fi

  unset CRON_PROBE_GH CRON_PROBE_POLL_TRIES CRON_PROBE_POLL_SLEEP

  echo
  echo "SELFTEST: $pass passed, $fail failed."
  [ "$fail" -eq 0 ]
}

if [ "$MODE" = selftest ]; then selftest; exit $?; fi

# ── --config-only: the CONFIGURATION question, alone ────────────────────────
# No network, no run list, no verdict about cron. This exists so the drift can
# be asked somewhere that does not gate the live read — and so it can be asked
# at PR time, before the drift is ever on main to disarm anything.
if [ "$MODE" = config ]; then
  echo "cron-overdue-probe — CONFIGURATION only: is every scheduled workflow classified, and does every critical cadence carry a fallback?"
  echo
  CRC=0
  check_table     || CRC=2
  check_fallbacks || CRC=2
  echo
  if [ "$CRC" -eq 0 ]; then
    echo "VERDICT  config: every scheduled workflow in .github/workflows carries a classification line, and every critical cadence carries a trigger fallback"
  else
    echo "VERDICT  config: DRIFT — the classification table and the tree disagree (named above). This is a REFUSAL, not a warning."
  fi
  exit "$CRC"
fi

echo "cron-overdue-probe — repo $REPO, bound ${OVERDUE_FACTOR}x the schedule interval"
echo
# THESE TWO NO LONGER `exit 2` ON THE SPOT (2026-09-07, task-16df558f0d748713).
# They used to, which meant a CONFIGURATION drift — somebody adds a `schedule:`
# and does not classify it — returned before the LIVE overdue read had run at
# all. That is not the question the drift answers, and the cost of letting it
# answer was measured: the overdue check dark ~15h50m while main-gate-watch.yml,
# whose ONLY fallback is this probe (a push arm is forbidden there by
# scripts/main-gate-watch.test.sh), sat 238m past its 90m bound. The drift is
# still a refusal — it is carried in DRIFT, printed as its own VERDICT line
# below, and exits non-zero — it just no longer takes the safety net with it.
DRIFT=0
check_table     || DRIFT=2
check_fallbacks || DRIFT=2
echo
check_overdue
RC=$?
echo
case "$RC" in
  0) echo "VERDICT  cron: every critical-cadence workflow fired inside ${OVERDUE_FACTOR}x its interval" ;;
  1) echo "VERDICT  cron: SCREAM — a critical-cadence workflow is silent past ${OVERDUE_FACTOR}x its interval AND could not be fired (named above). GitHub cron is best-effort, so lag alone is no longer a scream: a cron-only critical workflow past bound is DISPATCHED by this probe, and only a failed dispatch, a dispatched run that never appeared, a push-armed workflow gone quiet, or a workflow with no run row at all reaches this verdict. A re-run of this probe is not the remedy." ;;
  3) echo "VERDICT  cron: UNKNOWN — the run list could not be read. Not a pass." ;;
esac

# THE DRIFT IS A SECOND, INDEPENDENT VERDICT — printed whatever the cron read
# said, so it can never be masked by a scream and can never mask one.
if [ "$DRIFT" -ne 0 ]; then
  echo "VERDICT  config: DRIFT — the classification table and the tree disagree (REFUSED, named above). This is a SEPARATE refusal from the cron verdict above, and it does not change it: classify the workflow in $(basename "$0")."
fi

# THE CADENCE VERDICT — A THIRD, INDEPENDENT ANSWER (task-edebe459992b3574).
# It says which mechanism is delivering the beats, which the cron verdict above
# deliberately does not: since the dispatch arm landed, `cron: every critical-
# cadence workflow fired inside 3x its interval` is true both when the scheduler
# delivered and when THIS PROBE carried it, and those are different states.
if [ "$CADENCE_MEASURED" -eq 0 ]; then
  echo "VERDICT  cadence: NOT MEASURED — no critical workflow had enough run history in the last ${CADENCE_WINDOW_MIN}m window to score a delivery rate (see the per-workflow lines above)."
elif [ "$CADENCE_SHORTFALL" -ne 0 ]; then
  echo "VERDICT  cadence: DEGRADED — $CADENCE_SHORTFALL of $CADENCE_MEASURED measured critical workflow(s) are receiving less than ${CADENCE_FLOOR_PCT}% of their declared schedule: beats (named above). This is a WARNING BY DESIGN and it is not the cron verdict: GitHub's scheduler on this repo delivered ~7 runs a day to each of main-gate-watch, stale-verdict-watch and task-lease-renew in the 24 h to 2026-09-20T19:40Z, whatever their cron expressions say, so no pull request can clear it and a red here would be red every day. Pass --cadence-strict to make it exit 4."
else
  echo "VERDICT  cadence: every measured critical workflow received at least ${CADENCE_FLOOR_PCT}% of its declared schedule: beats over the last ${CADENCE_WINDOW_MIN}m"
fi

# THE CODE IS THE WORST LIVE VERDICT, and the drift only owns it when the cron
# read came back clean. A drift must never launder a 1 (a silent safety net) or
# a 3 (an unreadable run list) into a 2 that reads like a config chore. The
# cadence shortfall sits BELOW both for the same reason in reverse: a delivery
# warning must never be able to mask a scream or a refusal.
[ "$RC" -ne 0 ] && exit "$RC"
[ "$DRIFT" -ne 0 ] && exit "$DRIFT"
[ "$CADENCE_STRICT" = 1 ] && [ "$CADENCE_SHORTFALL" -ne 0 ] && exit 4
exit 0
