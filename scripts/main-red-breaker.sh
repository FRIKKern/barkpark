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
# DECISION
#   no step failed                         -> exit 0 (nothing to decide)
#   event is not pull_request              -> exit 1 on any failure. On main
#                                             itself the red is MAIN'S STATE and
#                                             must never be waved through.
#   main's newest COMPLETED run of this workflow has a job of the same name
#   whose failed step names are a SUPERSET of ours (non-empty)
#                                          -> exit 0, notice INHERITED-FROM-MAIN
#                                             naming main's run id and steps
#   otherwise (main green, main red on a different step, main unreadable,
#   no such job on main, or we failed on a step main did not)
#                                          -> exit 1 naming OUR failed steps
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
# This script must never be wired into a required context
# (required-checks-floor.sh guards the four names; this script's harness asserts
# it names none of them).
#
# READING MAIN. One REST call for the newest completed push run on main, one for
# its jobs, one for the failing job's plain-text log. Unreadable main == not
# inherited (the job reds on its own failure), so an API outage can only make
# the breaker LESS forgiving; an unreadable main LOG only makes the signature
# unknown, which the notice states.
#
# HARNESS HOOK. MAIN_RED_BREAKER_FIXTURE=<file> supplies main's jobs JSON and
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

if [ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]; then
  say "FAIL — '${JOB_NAME}' failed on: $(printf '%s' "$OURS" | tr '\n' ';'). This is not a pull_request run, so the red is main's state and stands."
  exit 1
fi

# Main's newest completed push run of this workflow, and its jobs.
MAIN_JOBS="$TMPD/main-jobs.json"
if [ -n "${MAIN_RED_BREAKER_FIXTURE:-}" ]; then
  cp -- "$MAIN_RED_BREAKER_FIXTURE" "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
  MAIN_RUN_ID="fixture"
else
  API="https://api.github.com/repos/${GITHUB_REPOSITORY:-}"
  auth=(-H "Authorization: Bearer ${GITHUB_TOKEN:-}" -H "Accept: application/vnd.github+json")
  MAIN_RUN_ID="$(curl -sS --max-time 20 "${auth[@]}" "${API}/actions/workflows/${WORKFLOW_FILE}/runs?branch=main&event=push&status=completed&per_page=1" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("workflow_runs") or []; print(r[0]["id"] if r else "")' 2>/dev/null || true)"
  if [ -z "$MAIN_RUN_ID" ]; then
    say "FAIL — '${JOB_NAME}' failed on: $(printf '%s' "$OURS" | tr '\n' ';'). Could not read main's newest completed run of ${WORKFLOW_FILE}, so nothing is inherited."
    exit 1
  fi
  curl -sS --max-time 20 "${auth[@]}" "${API}/actions/runs/${MAIN_RUN_ID}/jobs?per_page=100" -o "$MAIN_JOBS" 2>/dev/null || : > "$MAIN_JOBS"
fi

# Main's failed step names for the job of the same name, plus that job's id
# (written to mainjob.id) so its plain-text log can be read for the signature.
python3 - "$MAIN_JOBS" "$JOB_NAME" "$TMPD/mainjob.id" > "$TMPD/mains.txt" <<'PY' || : > "$TMPD/mains.txt"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
jid = ""
for j in d.get("jobs") or []:
    if j.get("name") == want and j.get("conclusion") == "failure":
        jid = jid or str(j.get("id") or "")
        for s in j.get("steps") or []:
            if s.get("conclusion") == "failure":
                print(s.get("name"))
open(sys.argv[3], "w").write(jid)
PY
MAINS="$(sort -u "$TMPD/mains.txt")"

if [ -z "$MAINS" ]; then
  say "FAIL — '${JOB_NAME}' failed on: $(printf '%s' "$OURS" | tr '\n' ';'). Main's newest completed run (${MAIN_RUN_ID}) has this job GREEN or absent, so the red is this PR's own."
  exit 1
fi

NOT_ON_MAIN="$(comm -23 <(printf '%s\n' "$OURS") <(printf '%s\n' "$MAINS"))"
if [ -n "$NOT_ON_MAIN" ]; then
  say "FAIL — '${JOB_NAME}' failed on a step main does not: $(printf '%s' "$NOT_ON_MAIN" | tr '\n' ';'). (Main run ${MAIN_RUN_ID} is red on: $(printf '%s' "$MAINS" | tr '\n' ';'); those are inherited, the rest is yours.)"
  exit 1
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
def norm(t):
    t = DIG.sub('#', SHA.sub('<sha>', ANN.sub('', t)))
    return ' '.join(t.split())
out, inblock = set(), False
for raw in open(sys.argv[1], errors='replace'):
    body = ANSI.sub('', TS.sub('', raw.rstrip('\r\n')))
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

OUR_LOG="${BREAKER_ERROR_LOG:-${RUNNER_TEMP:-/nonexistent}/main-red-breaker-errors.txt}"
: > "$TMPD/our-sigs.txt"
[ -s "$OUR_LOG" ] && sigfile "$OUR_LOG" > "$TMPD/our-sigs.txt"

MAIN_LOG="$TMPD/main-job.log"; : > "$MAIN_LOG"
if [ -n "${MAIN_RED_BREAKER_LOG_FIXTURE:-}" ]; then
  cp -- "$MAIN_RED_BREAKER_LOG_FIXTURE" "$MAIN_LOG" 2>/dev/null || : > "$MAIN_LOG"
elif [ -z "${MAIN_RED_BREAKER_FIXTURE:-}" ] && [ -s "$TMPD/mainjob.id" ]; then
  curl -sSL --max-time 20 "${auth[@]}" "${API}/actions/jobs/$(cat "$TMPD/mainjob.id")/logs" -o "$MAIN_LOG" 2>/dev/null || : > "$MAIN_LOG"
fi
: > "$TMPD/main-sigs.txt"
[ -s "$MAIN_LOG" ] && sigfile "$MAIN_LOG" > "$TMPD/main-sigs.txt"

if [ ! -s "$TMPD/our-sigs.txt" ]; then
  SIG_NOTE=" SIGNATURE-UNVERIFIED: no gate step wrote ${OUR_LOG}, so this red was matched on STEP NAME ALONE — a different defect inside the same red step is indistinguishable from here."
elif [ ! -s "$TMPD/main-sigs.txt" ]; then
  SIG_NOTE=" SIGNATURE-UNVERIFIED: main's job log was empty or unreadable, so this red was matched on STEP NAME ALONE."
else
  NEW_SIG="$(comm -23 "$TMPD/our-sigs.txt" "$TMPD/main-sigs.txt")"
  if [ -n "$NEW_SIG" ]; then
    say "FAIL — '${JOB_NAME}' failed on the same step(s) main does ($(printf '%s' "$OURS" | tr '\n' ';')) but NOT with the same failure signature, so the red is this PR's OWN." >&2
    say "  THIS PR's signature line(s) that main does not have:" >&2; printf '    %s\n' "$NEW_SIG" >&2
    say "  MAIN's signature line(s) (run ${MAIN_RUN_ID}):" >&2; sed 's/^/    /' "$TMPD/main-sigs.txt" >&2
    exit 1
  fi
  SIG_NOTE=" Signature matched too: all $(wc -l < "$TMPD/our-sigs.txt" | tr -d ' ') normalised error line(s) of this red also appear in main's."
fi

MSG="INHERITED-FROM-MAIN — '${JOB_NAME}' failed only on step(s) main's newest completed run (${MAIN_RUN_ID}) already fails: $(printf '%s' "$OURS" | tr '\n' ';').${SIG_NOTE} This is main's defect, not this PR's; the main watcher owns it. This job reports neutral (exit 0)."
echo "::notice title=Inherited from main::${MSG}"
say "$MSG"
{ echo "### Inherited from main"; echo; echo "$MSG"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0
