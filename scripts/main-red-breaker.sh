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
# The comparison is by STEP NAME within the SAME JOB NAME. A PR that fails the
# same step for a different reason is still waved through — that is the
# accepted cost for NON-required jobs, whose red the main watcher owns. This
# script must never be wired into a required context (required-checks-floor.sh
# guards the four names; this script's harness asserts it names none of them).
#
# READING MAIN. One REST call for the newest completed push run on main, one
# for its jobs. Unreadable main == not inherited (the job reds on its own
# failure), so an API outage can only make the breaker LESS forgiving.
#
# HARNESS HOOK. MAIN_RED_BREAKER_FIXTURE=<file> supplies main's jobs JSON
# instead of the API (the harness also stubs curl); nothing else differs.
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

# Main's failed step names for the job of the same name.
python3 - "$MAIN_JOBS" "$JOB_NAME" > "$TMPD/mains.txt" <<'PY' || : > "$TMPD/mains.txt"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
for j in d.get("jobs") or []:
    if j.get("name") == want and j.get("conclusion") == "failure":
        for s in j.get("steps") or []:
            if s.get("conclusion") == "failure":
                print(s.get("name"))
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

MSG="INHERITED-FROM-MAIN — '${JOB_NAME}' failed only on step(s) main's newest completed run (${MAIN_RUN_ID}) already fails: $(printf '%s' "$OURS" | tr '\n' ';'). This is main's defect, not this PR's; the main watcher owns it. This job reports neutral (exit 0)."
echo "::notice title=Inherited from main::${MSG}"
say "$MSG"
{ echo "### Inherited from main"; echo; echo "$MSG"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0
