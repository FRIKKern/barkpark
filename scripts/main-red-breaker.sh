#!/usr/bin/env bash
# main-red-breaker.sh — the DECIDE step for a non-required CI job: a red that
# main already carries on the same step is INHERITED, not the author's.
#
# THE NUMBER THIS EXISTS FOR (task-e638b950726fea51). 631 of 1,207 PR reds in
# 14 days (52 percent) were main's own defect showing up on every PR: doc-gates
# citation guard (186), doc-gates EXIT-trap selftest (171), required-checks-
# drift (148), Sobelow stale pin (32), compose env census (32), gofmt drift
# (25). Each cost an author a read and often a rerun for a defect that was not
# theirs, while the main watcher already owned it.
#
# THE DAMAGE IS NOT THE WASTED TIME — IT IS THE HABIT. A breaker that
# CONFIDENTLY MISLABELS is worse than no breaker, because people act on it: a
# required gate's red starts reading as noise. So this script has THREE
# verdicts, not two, and "I cannot tell" is never folded into "yours":
#
#   INHERITED-FROM-MAIN      exit 0, ::notice   main already fails this, same signature
#   FAIL (this PR's own)     exit 1, ::error    main PROVABLY ran the step and passed it
#   OWNERSHIP-UNDETERMINED   exit 1, ::warning  main's state is unreadable, absent,
#                                               cancelled, or never reached the step
#   RUNNER-LOCAL             exit 0, ::warning  the HOST caused it — a known signature
#                                               in this red's OWN body (see M6)
#
# UNDETERMINED still exits 1 — these are non-required jobs, so the red blocks
# nothing, and failing closed can never wave a real PR defect through. What
# changes is the CLAIM: it says out loud that it is not accusing the author.
#
# HOW A JOB USES IT. Every gate step in the job carries `id: sN` and
# `continue-on-error: true`, so the job runs to the end and the outcome of
# each step is known. The LAST step runs this script with:
#
#   STEP_OUTCOMES   ${{ toJSON(steps) }}          — id -> {outcome, ...}
#   STEP_NAMES      JSON {"sN": "<step name>", …} — generated next to the ids
#   JOB_NAME        the job's display name (matched against main's run)
#   WORKFLOW_FILE   e.g. doc-gates.yml
#   GITHUB_EVENT_NAME, GITHUB_REPOSITORY, GITHUB_TOKEN (actions: read)
#
# ── THE THREE MISLABELS THIS VERSION CLOSES (all observed 2026-09-05/06) ─────
#
# M1. IT MATCHED MAIN'S JOB BY EXACT NAME, AND A MATRIX JOB IS NOT NAMED THAT.
#     MEASURED: main run 33968984175 (security.yml, 2026-09-05T13:28Z) reads
#     `"conclusion": "success"` at the RUN level while its job
#     'Sobelow static analysis (regression gate, baseline .sobelow-skips)
#      (27.0, 1.18.1)' reads `"conclusion": "failure"`. security.yml passes
#     JOB_NAME without the ` (27.0, 1.18.1)` matrix tuple GitHub appends, so
#     `j["name"] == JOB_NAME` matched NOTHING and the breaker printed
#     "has this job GREEN or absent, so the red is this PR's own" on #16189 and
#     #16136 — for a `DOS.StringToAtom` finding in api/lib/barkpark/validation.ex,
#     a file neither PR touched. Main's job had failed. FIX: match the exact name OR
#     `JOB_NAME + " ("` (the matrix leg), union every leg, and never key the
#     lookup on the RUN's conclusion — a continue-on-error job leaves the run
#     green over a failed job.
#
# M2. IT COMPARED AGAINST A RUN THAT NEVER REACHED THE STEP.
#     MEASURED: PR #15517, `Smoke arms` — a `sys_sigaltstack(): Internal error
#     … Aborted (core dumped)` in a diff containing zero API code. Main's own
#     run had reddened on an EARLIER step, and steps in these jobs are
#     sequential, so main stamped every later step `skipped` and NEVER EXECUTED
#     the arm being compared. The breaker asked "is this failing on main?", got
#     "no", and read that as "then it is yours" — when the truth was
#     **"main never ran it."** Absence of a failure is not evidence of a pass
#     when the step never executed. FIX: classify each of our failed steps
#     against main as FAILED / PASSED / NOT-REACHED / UNKNOWN, and only a
#     PASSED — main demonstrably ran the step and it succeeded — can carry the
#     verdict "this is yours". NOT-REACHED and UNKNOWN are UNDETERMINED.
#
# M3. IT READ A STALE, OR AN UNINFORMATIVE, MAIN RUN — AND CALLED IT GREEN.
#     MEASURED: PR #16233's Decide step printed "Main's newest completed run
#     has this job GREEN or absent, so the red is this PR's own" naming a run
#     that had concluded FAILURE 36 minutes earlier. That one sentence
#     conflated four different states: main is green / main's run has no job of
#     this name / main's jobs JSON did not parse / the API returned an error
#     body. Only the first is evidence about the author. FIX: they are now four
#     distinct verdicts, three of them UNDETERMINED; the run is chosen from the
#     newest INFORMATIVE completed runs (a `cancelled` or `startup_failure` run
#     carries no information about main's health — this fleet cancels
#     superseded runs constantly); and every verdict line states the run's id,
#     head sha, conclusion and AGE IN MINUTES so a stale comparison is visible
#     rather than implied.
#
# M4. ITS OWN OUTPUT WAS NOT A ROUND-TRIPPABLE FORMAT. Found 2026-09-06 by
#     replaying main run 33968984175 through v1 and v2 instead of through a
#     fixture — no arm in the harness had it. Main's verdict sentence joins its
#     failed step names with ';', and security.yml's gate step is named
#     "Sobelow (--skip reads api/.sobelow-skips baseline; --exit Low reds …)".
#     Split back on ';' that yields two names matching nothing, so a PR failing
#     the EXACT step main fails read as "a step main does not": a FOURTH route
#     to the same wrong sentence, from the breaker parsing its own prose. FIX:
#     main also prints one unambiguous MAIN-FAILED-STEP line per step, the
#     parser prefers those, and a legacy ';'-joined recovery that contained a
#     ';' is marked AMBIGUOUS — it can still inherit, but it can never blame.
#
# M5. IT COMPARED AGAINST A RUN THAT NEVER RAN THE JOB, AND AGAINST A SIGNATURE
#     THAT COULD NOT SEE THE FINDING. Both closed here; see the M5 block at the
#     run selection and the SOBELOW block in the normaliser.
#
# M6. IT ACCUSED FOUR PRs OF A CRASH THE RUNNER CAUSED (task-572a62485cb1f8da).
#     MEASURED 2026-09-06 (task-f21e6a627ca13ef8): compose-smoke's green and
#     refusal arms die intermittently with
#       sys/unix/sys_signal_stack.c:101:sys_sigaltstack(): Internal error:
#       Failed to set alternate signal stack   ->   Aborted (core dumped)
#       ->   FAIL green arm: api container is not cleanly running
#     The BEAM aborts at boot inside the musl runtime image, before any repo
#     code runs. It is a HOST property: every crash since the hardware census
#     step landed ran on INTEL(R) XEON(R) PLATINUM 8573C (runs 34020171927,
#     34020897938, 34020905909) and 0 of 7 clean census runs did; over 85
#     executed runs, 9 of 16 in Azure westus3+centralus crashed and 0 of 69
#     elsewhere (p~1e-8), runner/image/agent/OS identical across all 85.
#
#     Every verdict this script had was a claim about the TREE — main's or the
#     author's — so a host-caused red could only be sorted into one of them,
#     and it was sorted into the worst one. Runs 33981944988, 33985199172,
#     33988481430, 34018218144, 34018443211 and 34019839592 were told the red
#     was the PR's own. TWO OF THE THREE ACCUSED ARMS TOOK THE **PASSED** PATH:
#     main had run the same step and passed it, so the script said "yours"
#     WITHOUT EVER COMPARING SIGNATURES. A third (34019839592) took the
#     signature path and read OWN because the crash log lines vary between
#     runs. And 34019702764 read INHERITED only by luck — main happened to
#     crash on the same host minutes earlier.
#
#     FIX, and the ORDER IS THE FIX: a RUNNER-LOCAL check on the PR's OWN
#     failure body, running BEFORE main is read at all — therefore before both
#     the PASSED path and the signature path, the only two routes to an
#     accusation. It needs nothing from main, because "the host did this" is
#     not a comparative claim. Its verdict is a FOURTH one: neither inherited
#     nor own. It does not red the check (exit 0), and it is not silently green
#     either — it prints a ::warning naming the signature, the host measurement
#     that justified the entry, and the row that filed it.
#
#     THE SIGNATURE LIST IS DATA, NOT A REGEX IN THIS FILE:
#     scripts/main-red-breaker.runner-local.json, one entry per signature, each
#     carrying the DATE and the MEASUREMENT that established the host-property
#     claim. An allowlist that grows stops discriminating, so the loader
#     REFUSES an entry missing either field, says so in the log, and attributes
#     the red exactly as if the entry were absent. A future entry therefore
#     costs its author a measurement, which is the price of the exemption.
#
#     WHY ONLY ON A PULL REQUEST. The not-a-pull_request clause below still
#     exits first, so a push to main never prints RUNNER-LOCAL. That is
#     deliberate twice over: main's red is MAIN'S STATE (a host that keeps
#     crashing main is a thing to see, not to excuse), and the log-recovery
#     parser reads exactly one wording out of main's log.
#
# ── WHY A FAILED SOBELOW JOB DOES NOT RED THE SECURITY GATE ─────────────────
# Recorded, NOT changed (task-e65c78b1cd214237 criterion c3). The `Security
# gate` aggregator in .github/workflows/security.yml lists, in its `needs`,
# [changes, gate-shape, sobelow-inline-overlap, sobelow-baseline-fingerprint,
# mix-audit] — and NOT `sobelow`. That omission is BY DESIGN, not a fail-open
# hole: security.yml's header declares Sobelow ADVISORY because its fingerprints
# are derived from compiled AST and are not stable across Elixir toolchains, so
# a blocking gate would red the fleet on baseline drift rather than on real
# regressions; and scripts/security-gate-shape.test.sh (the 'Security gate shape
# ratchet' job) ENFORCES that every continue-on-error job stays OUT of the
# aggregator's needs. So a FAILED Sobelow job sitting inside a GREEN required
# `Security gate` context is the documented posture, and main accepted it again
# on 2026-09-05 14:15Z. Whether that posture should change is a RULING FOR MAIN,
# never a silent edit from a breaker PR: this script only decides WHOSE red it
# is, never whether a red blocks.
#
# DECISION (in order)
#   no step failed                          -> exit 0 (nothing to decide)
#   event is not pull_request               -> exit 1 on any failure. On main
#                                              itself the red is MAIN'S STATE and
#                                              must never be waved through. This
#                                              is also why main's log only ever
#                                              carries the FAIL wording, never
#                                              UNDETERMINED — see LOG RECOVERY.
#   our own failure body matches a known
#     runner-local signature                 -> exit 0, RUNNER-LOCAL (M6). FIRST,
#                                              before main is read: it is not a
#                                              claim about either tree.
#   main unreadable / no informative run     -> UNDETERMINED
#   main's jobs JSON unparsable              -> UNDETERMINED
#   no job of this name in main's run        -> UNDETERMINED (M1's shape)
#   any of our steps PROVABLY PASSED on main -> exit 1, that step is ours (and
#                                              any step it could not settle is
#                                              named as UNDETERMINED in the same
#                                              line, never folded into the blame)
#   any of our steps NOT-REACHED on main     -> UNDETERMINED (M2's shape)
#   main's step list came back ';'-shredded  -> UNDETERMINED (M4's shape)
#   all our steps FAILED on main, signature matches or is unverifiable
#                                            -> exit 0, INHERITED-FROM-MAIN
#   same steps, DIFFERENT failure signature  -> exit 1, the red is this PR's own
#
# The comparison is by STEP NAME within the SAME JOB NAME **and by a normalised
# FAILURE SIGNATURE**. Step name alone is too coarse, and it cost us a merge:
#
#   MEASURED 2026-09-03 (task-cf774c315a1deca0). PR #15784 added prose to
#   .github/workflows/architecture.yml that tripped required-checks-verify.sh's
#   advisory-prose clause. The 'Required-check spec gate' job was ALREADY red on
#   main at the SAME step from a DIFFERENT file (#15650's sidecar sentence), so
#   the PR's brand-new hit read as inherited and merged; main then carried two
#   hits instead of one. Same step, same script, same `FAIL:` header line — only
#   the file:line differed. A fresh defect hid inside an already-red step.
#
# SIGNATURE. Every error line of a red is normalised (leading runner timestamp,
# ANSI colour, `##[error]`/`##[warning]` annotation prefix stripped; 7-40 char
# hex runs -> <sha>; every remaining digit run -> #; whitespace collapsed) so
# that the SAME defect reported at a shifted line, in a rerun, or under a new
# run id still matches, while a DIFFERENT file or a different message does not.
# Digits are erased on purpose: line drift must not manufacture a fresh red.
# The comparison is a SUBSET test, exactly like the step-name test: inherit only
# when every one of our normalised error lines also appears in main's.
#
# WHERE OUR SIGNATURE COMES FROM — and what is NOT available. The breaker runs
# as the LAST step of the very job it judges, so the job's own log is NOT
# readable: `gh api /actions/jobs/{id}/logs` 404s until the job is complete, and
# a check-run's annotations are not final either. The one source that exists at
# that moment is a CAPTURE FILE a gate step wrote while it was failing:
#
#   BREAKER_ERROR_LOG   default ${RUNNER_TEMP}/main-red-breaker-errors.txt
#                       plain raw log lines, appended by any gate step that
#                       wants its red discriminated. Raw is the contract: this
#                       script does the normalising, callers do not.
#
# When that file is absent or empty our signature is UNKNOWN. An unknown
# signature falls back to the v1 step-name-only verdict and SAYS SO in the
# notice (`SIGNATURE-UNVERIFIED`) — because failing closed there would turn all
# 631 known-inherited reds back on in one commit, and failing silently is what
# this change exists to stop. Main's side has no such problem: main's run is
# complete, so its job log is always readable.
#
# LOG RECOVERY — WHY THE JOBS API IS NOT ENOUGH. MEASURED 2026-09-03
# (task-2dbe8808f2a6f7b5). Every gate step carries `continue-on-error: true`,
# and the runner reports such a step as `"conclusion": "success"` even when it
# failed (only its `outcome` is `failure`, and `outcome` is not in the jobs
# API). Run 33788784458 job 100759983487 ('Doc budgets + anchors'): 33 gate
# steps, all `conclusion: success`, one `failure`, the Decide step. So a
# conclusion-keyed reader can only ever see the Decide step on main. The
# recovery needs no new API: main's Decide step PRINTED its gate-step names,
# and it prints them in exactly one wording because on a push run this script
# exits at the not-a-pull_request clause. A name recovered that way inherits
# ONLY on a VERIFIED signature.
#
# Because a gate step's `success` is ambiguous under continue-on-error, "main
# PASSED this step" is only ever asserted from one of three PROOFS:
#   (a) main's job concluded success        — nothing in it failed, full stop;
#   (b) main's Decide line was parsed       — we know main's complete failed set;
#   (c) main's jobs JSON marks some GATE step `conclusion: failure` — the job is
#       not continue-on-error-masked, so its step conclusions are truthful.
# Without one of those, a `success` step conclusion is UNKNOWN, not a pass.
#
# This script must never be wired into a required context
# (required-checks-floor.sh guards the four names; this script's harness asserts
# it names none of them).
#
# READING MAIN. One REST call for the newest completed push runs on main, one
# for the chosen run's jobs, one for the failing job's plain-text log.
# Unreadable main == UNDETERMINED (the job still reds), so an API outage can
# only make the breaker LESS forgiving and never more accusing; an unreadable
# main LOG only makes the signature unknown, which the notice states.
#
# HARNESS HOOKS. MAIN_RED_BREAKER_RUNNER_LOCAL_DATA=<file> overrides the
# runner-local signature data file, MAIN_RED_BREAKER_RUNS_FIXTURE=<file> supplies the runs listing,
# MAIN_RED_BREAKER_FIXTURE=<file> main's jobs JSON and
# MAIN_RED_BREAKER_LOG_FIXTURE=<file> main's raw job log, instead of the API
# (the harness also stubs curl); nothing else differs.
set -uo pipefail

say() { echo "main-red-breaker: $*"; }
[ -n "${STEP_OUTCOMES:-}" ] || { say "CANNOT DECIDE — STEP_OUTCOMES is empty; the Decide step must pass toJSON(steps)" >&2; exit 2; }
[ -n "${STEP_NAMES:-}" ]    || { say "CANNOT DECIDE — STEP_NAMES is empty; the step-id -> name map was not generated" >&2; exit 2; }
[ -n "${JOB_NAME:-}" ]      || { say "CANNOT DECIDE — JOB_NAME is empty" >&2; exit 2; }
[ -n "${WORKFLOW_FILE:-}" ] || { say "CANNOT DECIDE — WORKFLOW_FILE is empty" >&2; exit 2; }

TMPD="$(mktemp -d -t main-red-breaker.XXXXXX)"; trap 'rm -rf "$TMPD"' EXIT
printf '%s' "$STEP_OUTCOMES" > "$TMPD/outcomes.json"
printf '%s' "$STEP_NAMES"    > "$TMPD/names.json"

# Our failed step names, one per line, from the two JSON inputs.
python3 - "$TMPD/outcomes.json" "$TMPD/names.json" > "$TMPD/ours.txt" <<'PY' || { say "CANNOT DECIDE — STEP_OUTCOMES / STEP_NAMES did not parse as JSON" >&2; exit 2; }
import json, sys
outcomes = json.load(open(sys.argv[1])); names = json.load(open(sys.argv[2]))
for sid, meta in outcomes.items():
    # Only steps named in STEP_NAMES are GATE steps; a step that was already
    # advisory (continue-on-error before the breaker) is deliberately absent.
    if sid in names and isinstance(meta, dict) and meta.get("outcome") == "failure":
        print(names[sid])
PY

if [ ! -s "$TMPD/ours.txt" ]; then
  say "no gate step failed in '${JOB_NAME}' — nothing to decide"
  exit 0
fi
OURS="$(sort -u "$TMPD/ours.txt")"
OURS_1L="$(printf '%s' "$OURS" | tr '\n' ';')"

if [ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]; then
  # THE ONE WORDING MAIN EVER PRINTS. The log-recovery parser below reads this
  # exact sentence out of main's job log; do not reshape it. It is also why
  # UNDETERMINED can never appear in a main log: main never reaches that code.
  say "FAIL — '${JOB_NAME}' failed on: ${OURS_1L}. This is not a pull_request run, so the red is main's state and stands."
  # M4, MEASURED 2026-09-06 by replaying main run 33968984175 through both
  # versions: the sentence above joins step names with ';' and security.yml's
  # Sobelow gate step is literally named
  #   "Sobelow (--skip reads api/.sobelow-skips baseline; --exit Low reds ...)".
  # Splitting that back on ';' yields two names that match nothing, so a PR
  # failing the very step main fails read as "a step main does not" — a fourth
  # route to the same wrong sentence, and one no fixture in the harness had.
  # These marker lines carry ONE NAME EACH and no delimiter at all. The
  # sentence stays for the logs already written; the parser prefers these.
  while IFS= read -r _s; do
    [ -n "$_s" ] && say "MAIN-FAILED-STEP in '${JOB_NAME}': ${_s}"
  done <<< "$OURS"
  exit 1
fi

# ── M6: IS THIS RED THE HOST'S? (task-572a62485cb1f8da) ─────────────────────
# FIRST, and on THIS PR's failure body alone. Both routes to an accusation read
# main: the PASSED path ("main ran this step and passed it") and the signature
# path ("same step, different error text"). Two of the three accused compose-
# smoke runs took the PASSED path, which never looks at an error message at all
# — so a check placed inside the signature comparison would have caught one of
# three. A host-caused crash is not a claim about either tree, so it is settled
# before either tree is read, and it needs no API call to settle.
OUR_LOG="${BREAKER_ERROR_LOG:-${RUNNER_TEMP:-/nonexistent}/main-red-breaker-errors.txt}"
RUNNER_LOCAL_DATA="${MAIN_RED_BREAKER_RUNNER_LOCAL_DATA:-$(cd "$(dirname "$0")" && pwd)/main-red-breaker.runner-local.json}"
python3 - "$RUNNER_LOCAL_DATA" "$OUR_LOG" > "$TMPD/runner-local.txt" 2>/dev/null <<'PY' || : > "$TMPD/runner-local.txt"
import json, re, sys
data_path, log_path = sys.argv[1:3]
try:
    d = json.load(open(data_path))
except FileNotFoundError:
    print("NODATA\t%s\t\t" % data_path); raise SystemExit
except Exception as err:
    print("BADFILE\t%s\t%s\t" % (data_path, err)); raise SystemExit
sigs = d.get("signatures")
if not isinstance(sigs, list):
    print("BADFILE\t%s\tno 'signatures' list\t" % data_path); raise SystemExit

# THE TRIPWIRE THAT KEEPS THE ALLOWLIST HONEST. An entry here suppresses an
# accusation, so it must carry the two things that make the suppression
# checkable by a reader: WHEN the host-property claim was established, and HOW.
# A missing one is not a warning to fix later — the entry is REFUSED and the red
# is attributed exactly as it would have been with no file at all.
DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
TS   = re.compile(r'^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s')
ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
MIN_MEASUREMENT = 40   # a sentence, not a shrug
good = []
for i, e in enumerate(sigs):
    if not isinstance(e, dict):
        print("REJECT\tentry #%d\tnot an object\t" % i); continue
    sid  = str(e.get("id") or "").strip()
    pat  = str(e.get("pattern") or "")
    date = str(e.get("date") or "").strip()
    meas = str(e.get("measurement") or "").strip()
    label = sid or ("entry #%d" % i)
    why = []
    if not sid:                    why.append("no id")
    if not pat:                    why.append("no pattern")
    if not DATE.match(date):       why.append("no ISO date (YYYY-MM-DD) saying when this was measured")
    if len(meas) < MIN_MEASUREMENT:why.append("no measurement saying how the host-property claim was established")
    if why:
        print("REJECT\t%s\t%s\t" % (label, "; ".join(why))); continue
    try:
        rx = re.compile(pat)
    except re.error as err:
        print("REJECT\t%s\tpattern is not a valid regular expression: %s\t" % (label, err)); continue
    good.append((sid, date, meas, rx))
print("LOADED\t%d\t%d\t" % (len(good), len(sigs)))
try:
    fh = open(log_path, errors="replace")
except Exception:
    raise SystemExit
for raw in fh:
    body = ANSI.sub('', TS.sub('', raw.rstrip('\r\n'))).strip()
    for sid, date, meas, rx in good:
        if rx.search(body):
            # One field per line, NEVER an empty one: tab is IFS whitespace,
            # so bash's `read` collapses a run of tabs into a single delimiter
            # and an empty middle field would shift every field after it.
            print("MATCH\t%s\t%s\t%s" % (sid, date, ' '.join(body.split())[:300]))
            print("MEASUREMENT\t%s" % ' '.join(meas.split()))
            raise SystemExit
PY

RL_ID=""; RL_DATE=""; RL_LINE=""; RL_MEAS=""
while IFS="$(printf '\t')" read -r _k _f2 _f3 _f4; do
  case "$_k" in
    REJECT)
      say "RUNNER-LOCAL DATA: REFUSED entry '${_f2}' in ${RUNNER_LOCAL_DATA} — ${_f3}. An allowlist entry that cannot say WHEN and HOW the host-property claim was measured may not suppress an accusation, so this red is attributed exactly as if the entry were absent." >&2
      echo "::warning title=Main-red breaker: runner-local entry REFUSED::'${_f2}' in ${RUNNER_LOCAL_DATA}: ${_f3}. It suppresses nothing."
      ;;
    NODATA)  say "RUNNER-LOCAL DATA: no signature file at ${_f2} — every red is attributed on the tree alone." ;;
    BADFILE) say "RUNNER-LOCAL DATA: ${_f2} did not load (${_f3}); no signature suppresses anything." >&2 ;;
    MATCH)       RL_ID="$_f2"; RL_DATE="$_f3"; RL_LINE="$_f4" ;;
    MEASUREMENT) RL_MEAS="$_f2" ;;
  esac
done < "$TMPD/runner-local.txt"

if [ -n "$RL_ID" ]; then
  MSG="RUNNER-LOCAL — '${JOB_NAME}' failed on: ${OURS_1L}, and this red's OWN failure body carries the known runner-local signature '${RL_ID}' (recorded ${RL_DATE} in ${RUNNER_LOCAL_DATA}, filed as task-572a62485cb1f8da): \"${RL_LINE}\". That is a property of the HOST this job landed on, not of this branch. ${RL_MEAS} So this red is NOT attributed to this PR, and it is not inherited from main either — it is neither, and no comparison against main was made. ACTION: rerun this job; it will usually land on a different host. If it reproduces across several reruns, the entry above is wrong for your case — remove or narrow it with a new measurement, never widen it."
  say "$MSG"
  echo "::warning title=Main-red breaker: RUNNER-LOCAL, not this PR::${MSG}"
  { echo "### Runner-local failure — not attributed to this PR"; echo; echo "$MSG"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

# ── the three verdicts ──────────────────────────────────────────────────────
# UNDETERMINED is the whole point of this version: a breaker that confidently
# mislabels trains the fleet to read reds as noise. It exits 1 (the red stands,
# nothing is waved through) but makes NO claim about the author.
undetermined() {
  say "OWNERSHIP-UNDETERMINED — '${JOB_NAME}' failed on: ${OURS_1L}. $1 This is NOT a claim that the red is yours: the breaker could not establish that main passes these step(s), and it will not guess. ${MAIN_RUN_DESC:-}" >&2
  echo "::warning title=Main-red breaker: ownership undetermined::'${JOB_NAME}' failed on ${OURS_1L}. $1 Not attributed to this PR. ${MAIN_RUN_DESC:-}"
  { echo "### Ownership undetermined"; echo; echo "'${JOB_NAME}' failed on ${OURS_1L}."; echo; echo "$1"; echo; echo "${MAIN_RUN_DESC:-}"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
}

# Main's newest INFORMATIVE completed push run of this workflow, and its jobs.
# "Informative" excludes cancelled / skipped / startup_failure: this fleet
# cancels superseded main runs constantly (21 of 60 doc-gates runs, measured
# 2026-09-01), and a cancelled run has no job conclusions to compare against —
# taking it and finding nothing is exactly how M3 read a red main as green.
MAIN_JOBS="$TMPD/main-jobs.json"
MAIN_RUN_DESC=""
# M5's predicate: did a job of this name actually EXECUTE in this run's jobs
# listing? `skipped` and `cancelled` are NOT executions — they are the two ways
# a job can be present and carry no evidence. Absent is not an execution either.
# The matrix-leg match is the same one the classifier uses (M1).
job_executed() { # $1 = jobs JSON, $2 = JOB_NAME -> rc 0 if some leg ran to a verdict
  python3 - "$1" "$2" <<'PY'
import json, sys
want = sys.argv[2]
try:
    d = json.load(open(sys.argv[1]))
    jobs = d.get("jobs") or []
except Exception:
    raise SystemExit(1)
for j in jobs:
    n = j.get("name")
    if n == want or (isinstance(n, str) and n.startswith(want + " (")):
        if j.get("conclusion") in ("success", "failure"):
            raise SystemExit(0)
raise SystemExit(1)
PY
}
if [ -n "${MAIN_RED_BREAKER_FIXTURE:-}" ]; then
  cp -- "$MAIN_RED_BREAKER_FIXTURE" "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
  MAIN_RUN_ID="fixture"
  MAIN_RUN_DESC="(main run fixture)"
else
  API="https://api.github.com/repos/${GITHUB_REPOSITORY:-}"
  auth=(-H "Authorization: Bearer ${GITHUB_TOKEN:-}" -H "Accept: application/vnd.github+json")
  RUNS="$TMPD/main-runs.json"
  if [ -n "${MAIN_RED_BREAKER_RUNS_FIXTURE:-}" ]; then
    cp -- "$MAIN_RED_BREAKER_RUNS_FIXTURE" "$RUNS" 2>/dev/null || : > "$RUNS"
  else
    curl -sS --max-time 20 "${auth[@]}" "${API}/actions/workflows/${WORKFLOW_FILE}/runs?branch=main&event=push&status=completed&per_page=10" -o "$RUNS" 2>/dev/null || : > "$RUNS"
  fi
  # id, head sha, conclusion, and how many minutes ago it finished — the age is
  # printed in every verdict so a stale comparison is visible, not implied.
  python3 - "$RUNS" > "$TMPD/runsel.txt" 2>/dev/null <<'PY' || : > "$TMPD/runsel.txt"
import calendar, json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("  "); raise SystemExit
runs = d.get("workflow_runs") or []
UNINFORMATIVE = {"cancelled", "skipped", "startup_failure", "stale", None, ""}
skipped = 0
# M5: emit up to LIMIT candidates, newest first, instead of stopping at the
# first one. The bash side walks them until it finds a run that actually RAN
# the job of interest; without candidates there is nothing to walk.
LIMIT = 5
out = []
for r in runs:
    c = r.get("conclusion")
    if c in UNINFORMATIVE:
        skipped += 1
        continue
    age = "?"
    try:
        t = calendar.timegm(time.strptime(r.get("updated_at") or "", "%Y-%m-%dT%H:%M:%SZ"))
        age = str(max(0, int((time.time() - t) // 60)))
    except Exception:
        pass
    out.append(r)
    print("%s %s %s %s %d" % (r.get("id"), (r.get("head_sha") or "?")[:8], c, age, skipped))
    if len(out) >= LIMIT:
        break
print("")
PY
  MAIN_RUN_ID=""; MAIN_RUN_SHA=""; MAIN_RUN_CONCL=""; MAIN_RUN_AGE=""; MAIN_SKIPPED=""
  read -r MAIN_RUN_ID MAIN_RUN_SHA MAIN_RUN_CONCL MAIN_RUN_AGE MAIN_SKIPPED < "$TMPD/runsel.txt" || true
  if [ -z "${MAIN_RUN_ID:-}" ]; then
    undetermined "Could not read main: no informative completed run of ${WORKFLOW_FILE} on main was returned by the API (every one of the newest 10 was cancelled/skipped, or the request failed). Main's state is unknown from here."
  fi

  # ── M5: THE NEWEST RUN NEED NOT HAVE RUN THIS JOB (task-e65c78b1cd214237) ──
  # A run being informative says nothing about the JOB inside it. security.yml's
  # sobelow job carries `if: needs.changes.outputs.api == 'true'` (security.yml:274),
  # and the workflow's own header records that a job skipped by a job-level `if:`
  # PUBLISHES a check run with conclusion `skipped`. So after any main merge that
  # touches no api/ path, main's newest completed run holds this job as
  # `skipped` — a state carrying zero evidence about main's health at that step,
  # which the classifier can only render as NOT-REACHED (undetermined) while the
  # run one merge older was failing the very step this PR fails.
  #
  # A skipped job is NOT a green job and it is NOT an absent job: it is a run
  # that has nothing to say. So the selection WALKS BACK, newest first, over at
  # most MAIN_RUN_WALKBACK informative runs, and stops at the first one where a
  # job of this name actually EXECUTED — conclusion `success` or `failure`.
  # Bounded on purpose: an unbounded walk turns one API read into a paging loop
  # and, worse, would silently compare against a tree that is hours old. If no
  # candidate ran the job, the newest informative run is kept (the pre-M5
  # behaviour) and the existing NOJOB / NOT-REACHED clauses answer UNDETERMINED.
  #
  # MEASURED 2026-09-06: 160 of 160 newest completed security.yml push runs on
  # main ran the sobelow job (7 jobs each), so this shape is LATENT here today
  # rather than the mechanism behind the six mislabels of 2026-09-05 (those were
  # M1, the matrix-leg name). It is one non-api merge away from being live, and
  # every dispatcher-gated job in every breaker workflow shares it.
  MAIN_RUN_WALKBACK="${MAIN_RUN_WALKBACK:-5}"
  _cand_id=""; _cand_sha=""; _cand_concl=""; _cand_age=""; _cand_skipped=""; _walked=0; _chosen=0
  while read -r _cand_id _cand_sha _cand_concl _cand_age _cand_skipped; do
    [ -n "${_cand_id:-}" ] || continue
    [ "$_walked" -lt "$MAIN_RUN_WALKBACK" ] || break
    if [ -n "${MAIN_RED_BREAKER_JOBS_DIR:-}" ]; then
      cp -- "${MAIN_RED_BREAKER_JOBS_DIR}/${_cand_id}.json" "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
    else
      curl -sS --max-time 20 "${auth[@]}" "${API}/actions/runs/${_cand_id}/jobs?per_page=100" -o "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
    fi
    _walked=$((_walked + 1))
    if job_executed "$MAIN_JOBS" "$JOB_NAME"; then
      MAIN_RUN_ID="$_cand_id"; MAIN_RUN_SHA="$_cand_sha"; MAIN_RUN_CONCL="$_cand_concl"
      MAIN_RUN_AGE="$_cand_age"; MAIN_SKIPPED="$_cand_skipped"; _chosen=1
      break
    fi
  done < "$TMPD/runsel.txt"
  if [ "$_chosen" = 0 ]; then
    # Nothing in the window executed the job. Keep the newest informative run so
    # the verdict still names a real run, and say the walk found nothing.
    if [ -n "${MAIN_RED_BREAKER_JOBS_DIR:-}" ]; then
      cp -- "${MAIN_RED_BREAKER_JOBS_DIR}/${MAIN_RUN_ID}.json" "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
    else
      curl -sS --max-time 20 "${auth[@]}" "${API}/actions/runs/${MAIN_RUN_ID}/jobs?per_page=100" -o "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
    fi
  fi
  MAIN_RUN_DESC="(Main run ${MAIN_RUN_ID}, head ${MAIN_RUN_SHA}, concluded ${MAIN_RUN_CONCL} ${MAIN_RUN_AGE} min ago${MAIN_SKIPPED:+, after skipping ${MAIN_SKIPPED} uninformative cancelled/skipped run(s)}.)"
  if [ "$_chosen" = 1 ] && [ "$_walked" -gt 1 ]; then
    MAIN_RUN_DESC="${MAIN_RUN_DESC} (Walked back past $((_walked - 1)) newer main run(s) in which '${JOB_NAME}' did not EXECUTE — a job skipped by its dispatcher is not a green job.)"
  elif [ "$_chosen" = 0 ] && [ "$_walked" -gt 0 ]; then
    MAIN_RUN_DESC="${MAIN_RUN_DESC} (No job named '${JOB_NAME}' EXECUTED in any of the newest ${_walked} informative main run(s).)"
  fi
fi

# Main's job log. Fetched BEFORE the classification, because it carries main's
# failed GATE step names (the API cannot: continue-on-error) as well as its
# signature. The job id comes from the classifier's first pass, so this is a
# two-pass read of the same JSON — cheap, and it keeps the id logic in one file.
python3 - "$MAIN_JOBS" "$JOB_NAME" > "$TMPD/mainjob.id" 2>/dev/null <<'PY' || : > "$TMPD/mainjob.id"
import json, sys
want = sys.argv[2]
def matches(n):
    # M1: a matrix leg is published as "<name> (27.0, 1.18.1)". Exact name OR
    # the matrix-suffixed form; never the run's conclusion.
    return n == want or (isinstance(n, str) and n.startswith(want + " ("))
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
best = ""
for j in d.get("jobs") or []:
    if not matches(j.get("name")):
        continue
    if j.get("conclusion") == "failure":
        print(j.get("id") or ""); raise SystemExit
    best = best or str(j.get("id") or "")
print(best)
PY
MAIN_JOB_ID="$(head -1 "$TMPD/mainjob.id" 2>/dev/null | tr -d "[:space:]")"
MAIN_LOG="$TMPD/main-job.log"; : > "$MAIN_LOG"
if [ -n "${MAIN_RED_BREAKER_LOG_FIXTURE:-}" ]; then
  cp -- "$MAIN_RED_BREAKER_LOG_FIXTURE" "$MAIN_LOG" 2>/dev/null || : > "$MAIN_LOG"
elif [ -z "${MAIN_RED_BREAKER_FIXTURE:-}" ] && [ -n "$MAIN_JOB_ID" ]; then
  curl -sSL --max-time 20 "${auth[@]}" "${API}/actions/jobs/${MAIN_JOB_ID}/logs" -o "$MAIN_LOG" 2>/dev/null || : > "$MAIN_LOG"
fi

# ── CLASSIFY each of our failed steps against main ──────────────────────────
# FAILED      main fails it too            -> inheritable
# PASSED      main PROVABLY ran and passed -> this PR's own (the only accusing evidence)
# NOTREACHED  main skipped/cancelled it    -> UNDETERMINED (M2)
# UNKNOWN     main's success is masked by continue-on-error, or the job/JSON is
#             missing                      -> UNDETERMINED
python3 - "$MAIN_JOBS" "$JOB_NAME" "$TMPD/ours.txt" "$TMPD/names.json" "$MAIN_LOG" > "$TMPD/report.txt" 2>/dev/null <<'PY'
import json, re, sys

jobs_path, want, ours_path, names_path, log_path = sys.argv[1:6]
ours = [l.rstrip("\n") for l in open(ours_path) if l.strip()]
try:
    gate_names = set(json.load(open(names_path)).values())
except Exception:
    gate_names = set()

def matches(n):
    return n == want or (isinstance(n, str) and n.startswith(want + " ("))

status = "OK"
try:
    d = json.load(open(jobs_path))
    if not isinstance(d, dict) or "jobs" not in d:
        raise ValueError("no jobs key")
    alljobs = d.get("jobs") or []
except Exception:
    status = "NOJSON"
    alljobs = []

legs = [j for j in alljobs if matches(j.get("name"))]
if status == "OK" and not legs:
    status = "NOJOB"

# ── main's failed GATE steps, recovered from its own Decide line ────────────
# The jobs API reports every continue-on-error gate step as "success"; main's
# Decide step printed the truth. LOG_GREEN is the other half of the recovery:
# main saying "nothing to decide" is POSITIVE evidence that every gate step ran
# and passed — without it the common case would be UNKNOWN forever.
log_failed, log_parsed, log_green = set(), False, False
log_marked = False      # main used the unambiguous one-name-per-line markers
log_ambiguous = False   # only the legacy ';'-joined sentence was available AND it
                        # held a ';' — so the split may have shredded a step name
                        # that legitimately contains one (M4).
head = "main-red-breaker: FAIL — '%s' failed on" % want
mark = "main-red-breaker: MAIN-FAILED-STEP in '%s': " % want
green = "main-red-breaker: no gate step failed in '%s'" % want
legacy = set()
try:
    for raw in open(log_path, errors="replace"):
        line = raw.rstrip("\r\n")
        if green in line:
            log_green = True; log_parsed = True
        k = line.find(mark)
        if k >= 0:
            name = line[k + len(mark):].strip()
            if name:
                log_failed.add(name); log_marked = True; log_parsed = True
            continue
        i = line.find(head)
        if i < 0:
            continue
        m = re.search(r":\s*(.*?)\.\s+(?:This is not a pull_request run|\(Main run |Main's newest)", line[i + len(head):])
        if not m:
            continue
        log_parsed = True
        blob = m.group(1)
        if ";" in blob:
            log_ambiguous = True
        # the whole blob is a candidate too: a SINGLE step whose name contains a
        # ';' round-trips only this way.
        for name in [q.strip() for q in blob.split(";")] + [blob.strip()]:
            if name:
                legacy.add(name)
except Exception:
    pass
if not log_marked:
    log_failed |= legacy

api_failed, api_state, job_concls = set(), {}, []
for j in legs:
    job_concls.append(j.get("conclusion"))
    for s in j.get("steps") or []:
        n, c = s.get("name"), s.get("conclusion")
        if c == "failure":
            api_failed.add(n)
        prev = api_state.get(n)
        # union across matrix legs: a real failure anywhere wins, then a pass,
        # then a skip. Never let one leg's skip erase another leg's evidence.
        rank = {"failure": 3, "success": 2}.get(c, 1)
        if prev is None or rank > prev[0]:
            api_state[n] = (rank, c)

# (c) of the three PASS proofs: if the API marks a GATE step failed, this job's
# step conclusions are NOT continue-on-error-masked, so `success` means passed.
api_trusted = bool(api_failed & gate_names) if gate_names else bool(api_failed)
job_all_success = bool(legs) and all(c == "success" for c in job_concls)
job_cancelled = any(c in ("cancelled", None, "") for c in job_concls)

print("STATUS=%s" % status)
print("LEGS=%d" % len(legs))
print("JOBCONCL=%s" % ",".join(str(c) for c in job_concls))
print("LOGPARSED=%d" % int(log_parsed))
print("LOGGREEN=%d" % int(log_green))
print("LOGAMBIGUOUS=%d" % int(log_ambiguous))
print("MAINFAILED=%s" % ";".join(sorted(api_failed | log_failed)))
# LOG_DERIVED: at least one of OUR steps matched only through main's log line.
print("LOGDERIVED=%d" % int(bool([s for s in ours if s in log_failed and s not in api_failed])))

for s in ours:
    if s in api_failed or s in log_failed:
        cls = "FAILED"
    else:
        st = (api_state.get(s) or (None, None))[1]
        if st in ("skipped", "cancelled"):
            cls = "NOTREACHED"            # M2: main never executed it
        elif s not in api_state and status == "OK":
            # present on our side, absent from main's step list entirely: main's
            # job died before the runner ever recorded it.
            cls = "NOTREACHED"
        elif job_cancelled:
            cls = "NOTREACHED"
        elif st == "success" and log_ambiguous and not api_trusted and not job_all_success:
            # M4: main's failed-step list came back ';'-joined and a name may
            # have been shredded by the split, so "absent from main's set" is
            # not trustworthy. Undetermined — never blame.
            cls = "UNKNOWN"
        elif st == "success" and (job_all_success or log_parsed or api_trusted):
            cls = "PASSED"                 # the ONLY accusing evidence
        else:
            cls = "UNKNOWN"
    print("STEP\t%s\t%s" % (cls, s))
PY
if [ ! -s "$TMPD/report.txt" ]; then
  undetermined "Main's jobs listing could not be classified at all (the classifier produced no output)."
fi

get() { sed -n "s/^$1=//p" "$TMPD/report.txt" | head -1; }
STATUS="$(get STATUS)"; LEGS="$(get LEGS)"; LOG_DERIVED="$(get LOGDERIVED)"
# How many of main's jobs carried this name. >1 means matrix legs were unioned —
# printed because "main fails it" reading across legs is a different claim from
# one job failing, and a reader should not have to guess which they were told.
[ "${LEGS:-0}" -gt 1 ] 2>/dev/null && MAIN_RUN_DESC="${MAIN_RUN_DESC} (${LEGS} matrix legs of this job were unioned.)"
MAINS_1L="$(get MAINFAILED)"
cls_of() { awk -F'\t' -v c="$1" '$1=="STEP" && $2==c {print $3}' "$TMPD/report.txt"; }
NOTREACHED="$(cls_of NOTREACHED)"; PASSED="$(cls_of PASSED)"; UNKNOWN="$(cls_of UNKNOWN)"; FAILEDONMAIN="$(cls_of FAILED)"

# M3: four states that used to share one confident "GREEN or absent" sentence.
if [ "$STATUS" = "NOJSON" ]; then
  undetermined "Main's jobs listing for that run did not parse as JSON — the API returned an error body or nothing at all, which is not the same thing as main being green."
fi
if [ "$STATUS" = "NOJOB" ]; then
  undetermined "Main's run has NO job named '${JOB_NAME}' (nor any matrix leg '${JOB_NAME} (…)'). Either the job did not run on main, or its display name has drifted from the JOB_NAME this Decide step was given — a name mismatch is indistinguishable from a green job and must not be reported as one."
fi
# PROVABLY PASSED OUTRANKS UNDETERMINED, and the order is load-bearing. If we
# failed A and B, main provably ran and passed A, and main never reached B, then
# the A-red IS the author's and hiding it behind "undetermined" would be this
# same defect wearing the opposite mask — a breaker that never accuses is as
# useless as one that always does. So a PASSED step is reported, and the steps
# that could not be settled are named in the SAME line rather than dropped.
if [ -n "$PASSED" ]; then
  UNSETTLED="$(printf '%s\n%s' "$NOTREACHED" "$UNKNOWN" | sed '/^$/d' | tr '\n' ';')"
  say "FAIL — '${JOB_NAME}' failed on a step main does not: $(printf '%s' "$PASSED" | tr '\n' ';'). Main RAN that step and it PASSED, so the red is this PR's own.${MAINS_1L:+ (Main is red on: ${MAINS_1L}; those are inherited, the rest is yours.)}${UNSETTLED:+ Ownership of these other failed step(s) is UNDETERMINED, not attributed to you: ${UNSETTLED}} ${MAIN_RUN_DESC}"
  echo "::error title=Main-red breaker: this PR's own red::'${JOB_NAME}' failed on a step main runs and passes: $(printf '%s' "$PASSED" | tr '\n' ';')."
  exit 1
fi
# M2: main never executed the step, so "not failing on main" is vacuously true.
if [ -n "$NOTREACHED" ]; then
  undetermined "Main's job did NOT REACH these step(s): $(printf '%s' "$NOTREACHED" | tr '\n' ';') — they are skipped/cancelled or absent from main's step list, because one red step skips every later step in the same job. Main not failing a step it never ran is not evidence that it passes."
fi
if [ -n "$UNKNOWN" ]; then
  undetermined "Main's state for these step(s) is UNKNOWN: $(printf '%s' "$UNKNOWN" | tr '\n' ';'). Main's jobs API reports them 'success', but every gate step runs with continue-on-error — which reports 'success' for a FAILED step — and main's own Decide line could not be read to settle it."
fi
if [ -z "$FAILEDONMAIN" ]; then
  undetermined "No step could be classified against main at all."
fi

# ── the FAILURE SIGNATURE clause ────────────────────────────────────────────
# The step names agree. That is exactly where v1 stopped, and exactly where a
# fresh defect got in on 2026-09-03 (see the header). Now compare what the red
# actually SAID.
sigfile() { # $1 = file of RAW log lines -> stdout: normalised error lines, sorted -u
  python3 - "$1" <<'PY'
import re, sys
TS    = re.compile(r'^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s')
ANSI  = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
ANN   = re.compile(r'^##\[(?:error|warning|notice)\]')
SHA   = re.compile(r'\b[0-9a-f]{7,40}\b')
DIG   = re.compile(r'\d+')
# An error line OPENS a block; indented non-empty lines CONTINUE it. The
# continuation is not decoration: in the 2026-09-03 case the `FAIL:` header was
# byte-identical on both sides and the only thing that differed was the indented
# file:line detail underneath it. A first-line-only signature would have
# inherited that red too.
START = re.compile(r'##\[error\]|(?:^|[^A-Za-z])(?:FAIL|FAILED|ERROR)\b|\berror:|^\s*✗')
# THE SOBELOW FINDING SHAPE (task-e65c78b1cd214237, criterion c2). Sobelow does
# not print FAIL, ERROR, or an ##[error] annotation for a finding: it prints
#
#     DOS.StringToAtom: Unsafe `String.to_atom` - Low Confidence
#     File: lib/barkpark/content/validation.ex
#     Line: 188
#     Function: get_in_field:187
#     Variable: key
#
# — a header matching none of START's alternatives, and four UNINDENTED
# continuation lines that the indentation rule below therefore also drops. So
# for the whole security.yml sobelow job the signature set collapsed to the one
# line the runner appends, `Process completed with exit code 1`, which is
# byte-identical on every red anywhere. That is not a weak signature; it is a
# VACUOUS one, and it fails in the DANGEROUS direction: `comm -23` finds nothing
# our side has that main's lacks, so a PR carrying a BRAND-NEW Sobelow finding
# inherits main's unrelated red — the exact 2026-09-03 miss (#15784) the
# signature clause was built to stop, reopened for this one job.
# MEASURED 2026-09-05: main run 33968984175 job 101314071568 and PR job
# 101316469061 both report DOS.StringToAtom at
# lib/barkpark/content/validation.ex (Sobelow's own reported line, which the
# normaliser erases as a digit run anyway) — the harness feeds those two logs
# verbatim and asserts INHERITED, and asserts a DIFFERENT file still reads OWN.
SOBELOW = re.compile(r'^[A-Z][A-Za-z0-9]*\.[A-Za-z0-9_]+:\s.+\s-\s(?:High|Medium|Low) Confidence\s*$')
SOBELOW_FIELD = re.compile(r'^(?:File|Line|Col|Function|Variable|Template|Parameter):\s*\S')
def norm(t):
    t = DIG.sub('#', SHA.sub('<sha>', ANN.sub('', t)))
    return ' '.join(t.split())
out, inblock, insob = set(), False, False
for raw in open(sys.argv[1], errors='replace'):
    body = ANSI.sub('', TS.sub('', raw.rstrip('\r\n')))
    if SOBELOW.search(body):
        insob, inblock = True, False        # a finding block OPENS
    elif insob and SOBELOW_FIELD.match(body):
        pass                                 # its unindented File:/Line:/... rows
    else:
        insob = False
        if START.search(body):
            inblock = True
        elif not (inblock and body.strip() and body[:1].isspace()):
            inblock = False
            continue
    n = norm(body)
    if n:
        out.add(n)
for n in sorted(out):
    print(n)
PY
}

: > "$TMPD/our-sigs.txt"
[ -s "$OUR_LOG" ] && sigfile "$OUR_LOG" > "$TMPD/our-sigs.txt"

: > "$TMPD/main-sigs.txt"
[ -s "$MAIN_LOG" ] && sigfile "$MAIN_LOG" > "$TMPD/main-sigs.txt"

if [ ! -s "$TMPD/our-sigs.txt" ] || [ ! -s "$TMPD/main-sigs.txt" ]; then
  if [ ! -s "$TMPD/our-sigs.txt" ]; then
    SIG_NOTE=" SIGNATURE-UNVERIFIED: no gate step wrote ${OUR_LOG}, so this red was matched on STEP NAME ALONE — a different defect inside the same red step is indistinguishable from here."
  else
    SIG_NOTE=" SIGNATURE-UNVERIFIED: main's job log was empty or unreadable, so this red was matched on STEP NAME ALONE."
  fi
  if [ "$LOG_DERIVED" = 1 ]; then
    undetermined "Main's run fails there too, but ONLY per its own Decide line — the jobs API reports every continue-on-error gate step as 'success', so the step names came from main's log. That match alone is not enough to wave a red through:${SIG_NOTE}"
  fi
else
  # LC_ALL=C: sigfile sorts in Python codepoint order, and `comm` compares under
  # LC_COLLATE. Under a UTF-8 locale the runner actually uses, a line opening
  # with a non-ASCII glyph — `  ✗ NOVEL …`, which is exactly how the doc-gates
  # citation guard reports a novel lineref — collates BEFORE an ASCII line that
  # codepoint order puts first, so comm reads both files as unsorted and reports
  # a difference that is not there. Byte order on both sides or not at all.
  NEW_SIG="$(LC_ALL=C comm -23 "$TMPD/our-sigs.txt" "$TMPD/main-sigs.txt")"
  if [ -n "$NEW_SIG" ]; then
    say "FAIL — '${JOB_NAME}' failed on the same step(s) main does (${OURS_1L}) but NOT with the same failure signature, so the red is this PR's OWN. ${MAIN_RUN_DESC}" >&2
    say "  THIS PR's signature line(s) that main does not have:" >&2; printf '    %s\n' "$NEW_SIG" >&2
    say "  MAIN's signature line(s) (run ${MAIN_RUN_ID}):" >&2; sed 's/^/    /' "$TMPD/main-sigs.txt" >&2
    echo "::error title=Main-red breaker: this PR's own red::'${JOB_NAME}' failed on main's step(s) but with a DIFFERENT failure signature."
    exit 1
  fi
  SIG_NOTE=" Signature matched too: all $(wc -l < "$TMPD/our-sigs.txt" | tr -d ' ') normalised error line(s) of this red also appear in main's."
fi

MSG="INHERITED-FROM-MAIN — '${JOB_NAME}' failed only on step(s) main's newest completed run (${MAIN_RUN_ID}) already fails: ${OURS_1L}.${SIG_NOTE} This is main's defect, not this PR's; the main watcher owns it. This job reports neutral (exit 0). ${MAIN_RUN_DESC}"
echo "::notice title=Inherited from main::${MSG}"
say "$MSG"
{ echo "### Inherited from main"; echo; echo "$MSG"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0
