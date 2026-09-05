#!/usr/bin/env bash
# stale-tree-ci-wiring.test.sh — the CI wiring of the stale-tree regression
# check is a SIX-PLACE change, and five of those places are silent when wrong.
#
# WHAT GOES WRONG WITHOUT THIS. scripts/stale-tree-regression-check.sh landed in
# PR #16001 and ran NOWHERE (task-e75a5acd30825d77, C1). Wiring it as a job is
# the fix, but every part of that wiring fails QUIETLY:
#
#   * a workflow-level `paths:` key emits no check run at all on a non-matching
#     head — the name goes ABSENT, not skipped, and the whole point of this
#     check is heads whose authors touched none of its inputs;
#   * a gate step that loses the breaker-capture exec line still passes and
#     still reds — it just stops writing the signature file, so every verdict
#     silently degrades to SIGNATURE-UNVERIFIED (the exact inert state the
#     breaker shipped in);
#   * a deleted Decide step turns three `continue-on-error: true` gate steps
#     into a job that is GREEN NO MATTER WHAT. That is the dangerous one, and it
#     is the mutation this harness proves it catches;
#   * a STEP_NAMES map that drifts from the step ids/names makes the breaker
#     compare against names main never had, so nothing ever inherits.
#
# It reads the YAML, never a copy of it, and every case takes a FILE argument so
# the mutants below are the same code path as the real check.
#
# Exit: 0 all cases pass · 1 a case failed · 2 the harness could not measure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/required-checks-drift.yml"
JOB_ID="stale-tree"
JOB_NAME="Head does not silently revert main (stale tree)"

command -v python3 >/dev/null || { echo "HARNESS-UNAVAILABLE: python3 missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "HARNESS-UNAVAILABLE: PyYAML missing" >&2; exit 2; }
[ -f "$WF" ] || { echo "HARNESS-UNAVAILABLE: $WF not readable" >&2; exit 2; }

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }

# The checker. Prints one `WIRING-FAIL: <reason>` line per defect and exits
# non-zero if it found any. Takes the workflow file so a mutant is judged by
# exactly this code.
wiring_check() { # <workflow-file>
  python3 - "$1" "$JOB_ID" "$JOB_NAME" <<'PY'
import sys, json, yaml

path, job_id, job_name = sys.argv[1], sys.argv[2], sys.argv[3]
ARM = 'scripts/breaker-capture.sh'
bad = []

try:
    doc = yaml.safe_load(open(path))
except Exception as e:
    print("WIRING-FAIL: unparseable YAML: %s" % e)
    sys.exit(1)

# `on:` parses as the boolean True in YAML 1.1 — never index it by the string.
trig = doc.get(True, doc.get('on'))
if not isinstance(trig, dict) or 'pull_request' not in trig:
    bad.append("the workflow does not trigger on pull_request")
elif isinstance(trig.get('pull_request'), dict) and 'paths' in trig['pull_request']:
    bad.append("workflow-level pull_request.paths: — the check name would be ABSENT, not skipped, on a non-matching head")

conc = doc.get('concurrency')
if not isinstance(conc, dict) or 'group' not in conc:
    bad.append("no workflow-level concurrency group")
else:
    g, c = str(conc['group']), str(conc.get('cancel-in-progress'))
    if 'github.sha' not in g or 'github.ref' not in g:
        bad.append("concurrency group is not the canonical per-sha-on-main/per-ref-on-PR form: %s" % g)
    if c.strip().lower() == 'true':
        bad.append("cancel-in-progress is a literal true — that self-cancels the suite dark on main")

job = (doc.get('jobs') or {}).get(job_id)
if not isinstance(job, dict):
    print("WIRING-FAIL: job `%s` is absent from %s" % (job_id, path))
    for b in bad:
        print("WIRING-FAIL: " + b)
    sys.exit(1)

if job.get('name') != job_name:
    bad.append("job `%s` renders as %r, not %r — the check-run name IS the job name" % (job_id, job.get('name'), job_name))
if 'if' not in job:
    bad.append("job `%s` has no job-level `if:` — it would run on push/schedule where head==base and print a vacuous OK" % job_id)

steps = job.get('steps') or []
gate_ids = []
decide = None
for st in steps:
    if not isinstance(st, dict):
        continue
    body = st.get('run')
    if body is None:
        continue
    if 'main-red-breaker.sh' in body and st.get('if') is not None:
        decide = st
        continue
    if ARM not in body.splitlines()[0]:
        bad.append("step %r does not START with the breaker-capture exec line" % st.get('name'))
    if st.get('continue-on-error') is not True:
        bad.append("step %r is not continue-on-error: true — the Decide step cannot own the verdict" % st.get('name'))
    if st.get('id'):
        gate_ids.append(st['id'])

if decide is None:
    bad.append("no main-red-breaker Decide step — the %d continue-on-error gate step(s) make this job green no matter what" % len(gate_ids))
else:
    env = decide.get('env') or {}
    if str(decide.get('if')).strip() != 'always()':
        bad.append("the Decide step is not `if: always()`")
    if env.get('JOB_NAME') != job_name:
        bad.append("Decide JOB_NAME %r != the job's rendered name %r" % (env.get('JOB_NAME'), job_name))
    try:
        names = json.loads(env.get('STEP_NAMES', ''))
    except Exception:
        names = None
    if not isinstance(names, dict):
        bad.append("Decide STEP_NAMES is not a JSON object")
    else:
        missing = [i for i in gate_ids if i not in names]
        extra = [i for i in names if i not in gate_ids]
        if missing:
            bad.append("Decide STEP_NAMES is missing gate step id(s): %s" % ", ".join(missing))
        if extra:
            bad.append("Decide STEP_NAMES names id(s) no gate step has: %s" % ", ".join(extra))

for b in bad:
    print("WIRING-FAIL: " + b)
sys.exit(1 if bad else 0)
PY
}

echo "== stale-tree CI wiring =="

out="$(wiring_check "$WF" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "1) the shipped wiring passes every clause (job + if: + concurrency + breaker arm + Decide)"
else
  no "1) the shipped wiring is NOT clean:"
  printf '%s\n' "$out"
fi

# The job must not be a required context. required-checks.json's `protection`
# carries the enforced roster; a name in it is a merge gate, and this check's
# arm (a) is a question, not a verdict (see its own header).
if python3 - "$ROOT/.github/required-checks.json" "$JOB_NAME" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
name = sys.argv[2]
blob = json.dumps(spec.get('protection')) + json.dumps(spec.get('required'))
sys.exit(1 if name in blob else 0)
PY
then
  ok "2) '$JOB_NAME' is NOT in the required set — a non-required rendered name, like its sibling shape job"
else
  no "2) '$JOB_NAME' appears in the required set of .github/required-checks.json"
fi

# ── mutants: the harness has to be shown losing ──────────────────────────────
TMP="$(mktemp -d -t stale-tree-wiring.XXXXXX)" || { echo "HARNESS-UNAVAILABLE: mktemp" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

mutate() { # <name> <python-mutation> <expected substring>
  local label="$1" mut="$2" want="$3"
  local copy="$TMP/mutant.yml"
  cp "$WF" "$copy"
  python3 - "$copy" <<PY
import re, sys
p = sys.argv[1]
s = open(p).read()
$mut
open(p, 'w').write(s)
PY
  if ! diff -q "$WF" "$copy" >/dev/null; then
    local mout
    mout="$(wiring_check "$copy" 2>&1)"
    if [ $? -ne 0 ] && printf '%s' "$mout" | grep -qF "$want"; then
      ok "$label — mutant reds, naming: $(printf '%s' "$mout" | grep -F "$want" | head -1)"
    else
      no "$label — mutant did NOT red on '$want'; got: $mout"
    fi
  else
    no "$label — the mutation applied no change (the anchor drifted); the case proves nothing"
  fi
}

# THE ONE THAT MATTERS: delete the Decide step. Three continue-on-error gate
# steps with no Decide step is a job that cannot fail.
mutate "3) Decide step deleted" \
  "i = s.index('  stale-tree:')
j = s.index('  # ── the advisory half')
blk = s[i:j]
k = blk.index('      - name: Decide (main-red breaker')
assert blk.count('- name: Decide (main-red breaker') == 1, 'anchor is not unique in the job'
s = s[:i] + blk[:k] + s[j:]" \
  "no main-red-breaker Decide step"

mutate "4) breaker-capture exec line dropped from a gate step" \
  "old = s
s = s.replace('          if [ -z \"\${BREAKER_CAPTURE_ARMED:-}\" ] && [ -f \"\$GITHUB_WORKSPACE/scripts/breaker-capture.sh\" ]; then exec bash \"\$GITHUB_WORKSPACE/scripts/breaker-capture.sh\" \"\$0\"; fi  # main-red breaker: capture this step\\'s error block\n          bash scripts/stale-tree-regression-check.test.sh', '          bash scripts/stale-tree-regression-check.test.sh')
assert s != old, 'anchor drifted'" \
  "does not START with the breaker-capture exec line"

mutate "5) job-level if: deleted" \
  "old = s
s = s.replace(\"    if: github.event_name == 'pull_request'\n\", '', 1)
assert s != old, 'anchor drifted'" \
  "has no job-level \`if:\`"

mutate "6) a workflow-level pull_request paths: filter added" \
  "old = s
s = s.replace('on:\n  pull_request:\n', 'on:\n  pull_request:\n    paths:\n      - \"scripts/**\"\n', 1)
assert s != old, 'anchor drifted'" \
  "workflow-level pull_request.paths:"

echo
echo "stale-tree CI wiring: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
