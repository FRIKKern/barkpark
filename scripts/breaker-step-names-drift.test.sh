#!/usr/bin/env bash
# breaker-step-names-drift.test.sh — every main-red-breaker Decide step's
# STEP_NAMES map, in EVERY breaker-wired workflow, still matches the gate steps
# it claims to name.
#
# WHAT GOES WRONG WITHOUT THIS. The breaker (scripts/main-red-breaker.sh) reads
# STEP_OUTCOMES by step id and translates each id into the rendered step NAME
# through the Decide step's STEP_NAMES JSON map. That is how it asks main's
# newest completed run whether the SAME step is already red. When a step is
# added without a map entry, or an id is deleted from the map, or a step is
# renamed and the map is not, the breaker compares against a name main never
# had: the red is reported under the wrong name or swallowed as unknown. Nothing
# in CI reds on that — every one of those edits leaves a green workflow.
#
# scripts/stale-tree-ci-wiring.test.sh already asserts this, but it is hard
# pinned to ONE job in ONE file (its line 29: WF=.../required-checks-drift.yml).
# doc-gates.yml carries the largest map in the repo and was unguarded
# (task-d0b42df11fae0bf6).
#
# The workflow set is DERIVED, never a hand list: `git grep -l STEP_NAMES --
# .github/workflows`. Case 0 is the positive control — an empty derived set is a
# refusal, not a pass.
#
# NOT a numeric sequence check. doc-gates.yml's map has gaps (no s15/s16/s23):
# those ids were retired with their steps. Map keys are compared against the ids
# that EXIST in the file, both directions.
#
# Exit: 0 all cases pass · 1 a case failed · 2 the harness could not measure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v python3 >/dev/null || { echo "HARNESS-UNAVAILABLE: python3 missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "HARNESS-UNAVAILABLE: PyYAML missing" >&2; exit 2; }
command -v git >/dev/null || { echo "HARNESS-UNAVAILABLE: git missing" >&2; exit 2; }

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }

echo "== breaker STEP_NAMES drift =="

# ── case 0: the derived set (positive control) ───────────────────────────────
# git grep, not a literal list: a sixth workflow that wires a breaker is covered
# the day it lands. -z + NUL read so an odd path can never split a filename.
WFS=()
while IFS= read -r -d '' rel; do
  WFS+=("$rel")
done < <(git -C "$ROOT" grep -lz STEP_NAMES -- .github/workflows 2>/dev/null)

if [ "${#WFS[@]}" -eq 0 ]; then
  echo "HARNESS-UNAVAILABLE: the derived workflow set is EMPTY —" \
       "\`git grep -l STEP_NAMES -- .github/workflows\` matched nothing." \
       "A silent green here would assert coverage of zero workflows; refusing." >&2
  exit 2
fi
ok "0) derived ${#WFS[@]} breaker-wired workflow(s) from git grep: ${WFS[*]}"

# The checker. Prints one `DRIFT-FAIL: <reason>` line per defect, one
# `covered <file> job <id>: <n> gate step(s)` line per breaker job, and exits
# non-zero if it found any defect. Takes the files so a mutant copy is judged by
# exactly this code path.
drift_check() { # <workflow-file>...
  python3 - "$@" <<'PY'
import sys, json, yaml

ARM = 'main-red-breaker.sh'
bad = []
notes = []
covered = 0
checked_files = 0


def is_decide(st):
    """The Decide step, not merely a step that MENTIONS the breaker.

    shell-harnesses.yml runs `bash -n scripts/main-red-breaker.sh` as a syntax
    check and lists the path in a dispatch table; a substring match called both
    of those Decide steps. The real one is a ONE-LINE run body that execs the
    breaker AND carries STEP_OUTCOMES in its env — the map it feeds."""
    if not isinstance(st, dict):
        return False
    body = str(st.get('run') or '')
    lines = [l for l in body.strip().splitlines() if l.strip()]
    if len(lines) != 1 or not lines[0].strip().rstrip('"').endswith(ARM):
        return False
    return 'STEP_OUTCOMES' in (st.get('env') or {})


def has_step_names_env(jobs):
    for job in jobs.values():
        if not isinstance(job, dict):
            continue
        for st in (job.get('steps') or []):
            if isinstance(st, dict) and 'STEP_NAMES' in (st.get('env') or {}):
                return True
    return False

for path in sys.argv[1:]:
    try:
        doc = yaml.safe_load(open(path))
    except Exception as e:
        bad.append("%s: unparseable YAML: %s" % (path, e))
        continue

    jobs = (doc or {}).get('jobs') or {}
    if not isinstance(jobs, dict):
        bad.append("%s: no jobs: mapping" % path)
        continue

    breaker_jobs = 0
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []

        # The Decide step is the one that EXECUTES the breaker. Find it by
        # position: everything before it is a gate step, so a step appended
        # after Decide (which the breaker can never see) is not miscounted.
        decide_i = None
        for i, st in enumerate(steps):
            if is_decide(st):
                decide_i = i
                break
        if decide_i is None:
            continue
        breaker_jobs += 1
        decide = steps[decide_i]

        # A gate step = a `run:` step BEFORE Decide that carries an id. `uses:`
        # steps (checkout, setup-beam, upload-artifact) have no run body and are
        # never in STEP_OUTCOMES' gate role. An id-less run step is a DELIBERATE
        # shape in this repo (security.yml's `# ADVISORY — and NO id:` block,
        # compose-smoke.yml's hardware census): the breaker addresses steps by
        # id, so an id-less step is outside the map by construction. Those are
        # NOTED, never silently dropped, and never failed on — the subject of
        # this guard is the ids that DO exist.
        gate_ids = []
        id_name = {}
        idless = []
        for st in steps[:decide_i]:
            if not isinstance(st, dict) or st.get('run') is None:
                continue
            sid = st.get('id')
            if not sid:
                idless.append(str(st.get('name')))
                continue
            gate_ids.append(sid)
            id_name[sid] = st.get('name')
        if idless:
            notes.append("%s job `%s`: %d run step(s) before Decide carry no `id:` "
                         "and are therefore outside STEP_NAMES by construction: %s"
                         % (path, job_id, len(idless), "; ".join(idless)))

        env = decide.get('env') or {}
        raw = env.get('STEP_NAMES')
        if raw is None:
            bad.append("%s job `%s`: the Decide step has no STEP_NAMES env — "
                       "%d gate step(s) would be reported by id, never by name"
                       % (path, job_id, len(gate_ids)))
            continue
        try:
            names = json.loads(raw)
        except Exception as e:
            names = None
            bad.append("%s job `%s`: STEP_NAMES is not parseable JSON: %s" % (path, job_id, e))
        if names is not None and not isinstance(names, dict):
            bad.append("%s job `%s`: STEP_NAMES is not a JSON object" % (path, job_id))
            names = None
        if names is None:
            continue

        missing = [i for i in gate_ids if i not in names]
        extra = [i for i in names if i not in gate_ids]
        if missing:
            bad.append("%s job `%s`: STEP_NAMES is missing gate step id(s): %s"
                       % (path, job_id, ", ".join(missing)))
        if extra:
            bad.append("%s job `%s`: STEP_NAMES names id(s) no gate step has: %s"
                       % (path, job_id, ", ".join(extra)))
        for sid in gate_ids:
            if sid in names and names[sid] != id_name[sid]:
                bad.append("%s job `%s`: STEP_NAMES[%s] is %r but the step's "
                           "`- name:` is %r — the breaker would ask main about a "
                           "name it never had" % (path, job_id, sid, names[sid], id_name[sid]))
        covered += len(gate_ids)

    if breaker_jobs == 0:
        # A candidate that only MENTIONS the token in prose (a comment, a step
        # name, a dispatch path table) is not a breaker-wired workflow and is
        # dropped from the set, loudly. A candidate that carries a real
        # STEP_NAMES env key but no Decide step is drift: that map feeds nothing.
        if has_step_names_env(jobs):
            bad.append("%s: carries a STEP_NAMES env key but has NO Decide step "
                       "that execs %s — that map feeds nothing" % (path, ARM))
        else:
            notes.append("%s: matched the derivation on a PROSE mention only "
                         "(no STEP_NAMES env key anywhere) — excluded from the "
                         "checked set" % path)
    else:
        checked_files += 1

for n in notes:
    print("NOTE: " + n)
for b in bad:
    print("DRIFT-FAIL: " + b)
if checked_files == 0:
    print("DRIFT-FAIL: no candidate file carried a breaker Decide step — the "
          "checked set is EMPTY and this run asserts nothing")
    bad.append("empty checked set")
print("checked %d gate step id(s) across %d breaker-wired workflow file(s) "
      "(%d candidate(s) from the derivation)" % (covered, checked_files, len(sys.argv) - 1))
sys.exit(1 if bad else 0)
PY
}

# ── case 1: the shipped tree ─────────────────────────────────────────────────
abs=()
for rel in "${WFS[@]}"; do abs+=("$ROOT/$rel"); done
out="$(drift_check "${abs[@]}" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "1) every shipped STEP_NAMES map matches its job's gate steps — $(tail -1 <<<"$out")"
  # NOTEs are the non-failing half of the verdict (id-less advisory steps,
  # prose-only candidates). Printed on green too: nothing is skipped silently.
  grep -F 'NOTE: ' <<<"$out"
else
  no "1) the shipped tree DRIFTS:"
  printf '%s\n' "$out"
fi

# ── mutants: the harness has to be shown losing ──────────────────────────────
# doc-gates.yml is the subject: the largest map in the repo (the one this
# harness exists for), and the only one whose id set has retired gaps.
SUBJ="$ROOT/.github/workflows/doc-gates.yml"
[ -f "$SUBJ" ] || { echo "HARNESS-UNAVAILABLE: $SUBJ not readable" >&2; exit 2; }

TMP="$(mktemp -d -t breaker-step-names.XXXXXX)" || { echo "HARNESS-UNAVAILABLE: mktemp" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

mutate() { # <label> <python-mutation> <expected substring>
  local label="$1" mut="$2" want="$3"
  local copy="$TMP/mutant.yml"
  cp "$SUBJ" "$copy"
  python3 - "$copy" <<PY
import re, sys
p = sys.argv[1]
s = open(p).read()
$mut
open(p, 'w').write(s)
PY
  if diff -q "$SUBJ" "$copy" >/dev/null; then
    no "$label — the mutation applied no change (the anchor drifted); the case proves nothing"
    return
  fi
  local mout mrc
  mout="$(drift_check "$copy" 2>&1)"
  mrc=$?
  # herestrings, never `printf | grep -q`: with pipefail a reader that closes
  # early SIGPIPEs the writer and the pipeline returns 141, so the assertion
  # would flip to FAIL under a long mutant output.
  if [ "$mrc" -ne 0 ] && grep -qF -- "$want" <<<"$mout"; then
    ok "$label — mutant reds, naming: $(grep -m1 -F -- "$want" <<<"$mout")"
  else
    no "$label — mutant did NOT red on '$want' (rc=$mrc); got: $mout"
  fi
}

# M1: an id deleted from the map. This is the exact edit that shipped unguarded
# — s37 was removed from a scratch copy and every existing harness stayed green.
mutate "2) an id removed from doc-gates.yml's STEP_NAMES" \
  "old = s
s = s.replace('\\\\\"s37\\\\\": \\\\\"Paper dialect ratchet (fails this job)\\\\\", ', '', 1)
s = s.replace(', \\\\\"s37\\\\\": \\\\\"Paper dialect ratchet (fails this job)\\\\\"', '', 1)
assert s != old, 'anchor drifted: s37 is not in the map in the expected form'" \
  "STEP_NAMES is missing gate step id(s): s37"

# M2: a gate step added (id + breaker-capture preamble + continue-on-error) with
# no map entry — the shape of every "just add one more gate" PR.
mutate "3) a gate step added to doc-gates.yml with no STEP_NAMES entry" \
  "anchor = '      - name: Decide (main-red breaker'
i = s.index(anchor)
new = (
  '      - name: Scratch mutant gate (not a real gate)\n'
  '        id: s99\n'
  '        continue-on-error: true  # main-red breaker: the Decide step below owns the verdict\n'
  '        if: always()\n'
  '        run: |\n'
  '          if [ -z \"\${BREAKER_CAPTURE_ARMED:-}\" ] && [ -f \"\$GITHUB_WORKSPACE/scripts/breaker-capture.sh\" ]; then exec bash \"\$GITHUB_WORKSPACE/scripts/breaker-capture.sh\" \"\$0\"; fi  # main-red breaker: capture this step\'s error block\n'
  '          true\n\n'
)
s = s[:i] + new + s[i:]" \
  "STEP_NAMES is missing gate step id(s): s99"

# M3: a step renamed without its map entry. byte-equality, not key presence:
# the breaker matches main's check run by NAME, so a one-word rename is enough.
mutate "4) a gate step renamed while STEP_NAMES keeps the old name" \
  "old = s
s = s.replace('      - name: Doc byte budgets (fails this job)\n', '      - name: Doc byte budgets (fails this job) RENAMED\n', 1)
assert s != old, 'anchor drifted: the s1 step name is not in the expected form'" \
  "the breaker would ask main about a name it never had"

# M4: the Decide step's exec line replaced. The map survives, so the file is
# still a candidate — and a candidate whose map feeds nothing is drift, not a
# reason to drop the file from the checked set.
mutate "5) the Decide exec line dropped while STEP_NAMES stays" \
  "old = s
s = s.replace('        run: bash \"\$GITHUB_WORKSPACE/scripts/main-red-breaker.sh\"', '        run: true', 1)
assert s != old, 'anchor drifted: the Decide exec line is not in the expected form'" \
  "carries a STEP_NAMES env key but has NO Decide step"

# ── case 6: the untouched tree is still green after the mutants ──────────────
# The mutants run on copies; this re-reads the real files and proves the harness
# left nothing behind and is not stuck red.
out2="$(drift_check "${abs[@]}" 2>&1)"
if [ $? -eq 0 ]; then
  ok "6) the untouched tree re-reads green after the mutants — $(tail -1 <<<"$out2")"
else
  no "6) the untouched tree is NOT green on re-read: $out2"
fi

echo
echo "breaker STEP_NAMES drift: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
