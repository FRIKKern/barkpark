#!/usr/bin/env bash
# workflow-job-shape-check.sh — every job in every workflow must have the shape
# GitHub Actions requires, or the WHOLE FILE dies at parse time.
#
# THE HAZARD, measured. A PR spliced a new job block between an existing job's
# `name:` line and its `runs-on:`/`steps:`. The result was still valid YAML —
# one job simply ended up with nothing but a `name:`, and the job below it
# inherited the orphaned steps. Every yaml.safe_load in the repo said fine.
# GitHub said "This run likely failed because of a workflow file issue",
# rendered ZERO jobs, took 0 seconds, and did it on every push to main for nine
# hours. Twenty-five shell harnesses were silently unexecuted the whole time.
#
# The rule GitHub enforces, and the first rule this script checks: a job is
# either a RUNNER job (`runs-on` AND a non-empty `steps` list) or a REUSABLE
# WORKFLOW CALL (`uses`). Nothing else parses. A YAML syntax error is the same
# failure one stage earlier, so it reds here too.
#
# THE SAME HAZARD ONE LEVEL DOWN — THE STEP CLAUSE (wave 42 finding).
# A PR shipped two new `report main failure` steps carrying `name:` and `env:`
# and NO `run:`. Valid YAML again; the job-shape clause above is satisfied
# (runs-on present, steps non-empty); and again GitHub refuses the file, so the
# very job whose purpose was to make a red main push reach a human never ran.
# So: EVERY element of EVERY job's `steps:` list must carry EXACTLY ONE of
# `run:` or `uses:`. Neither is the shipped defect; BOTH is equally invalid to
# Actions and is what a half-finished edit from `uses:` to `run:` leaves behind.
# A red names the file, the job id, the step INDEX and its `name:` if it has one.
#
# WHY THIS IS A SEPARATE SCRIPT AND NOT A NEW ARM OF workflow-portability-check.sh
# (or -run-shell-check, or -trigger-coverage). Those three are wired ONLY in
# .github/workflows/shell-harnesses.yml — the file this defect broke. A checker
# that lives exclusively in the workflow it must lint cannot fire when that
# workflow is the one that will not start; the harness would have been dead
# alongside its subject. This check is wired in required-checks-drift.yml
# instead, which is deliberately path-unfiltered and renders on every PR.
#
# EXIT CODES
#   0  every job AND every step in every parsed file has a legal shape
#   1  at least one job or step is malformed (or a file is unparseable) — named
#   2  CANNOT MEASURE: zero files, zero jobs, no PyYAML, or a bad flag.
#      Never a vacuous green: an empty scan is a failure, not a pass.
#
# USAGE
#   bash scripts/workflow-job-shape-check.sh                 # .github/workflows
#   bash scripts/workflow-job-shape-check.sh --dir <path>    # another tree
#   bash scripts/workflow-job-shape-check.sh a.yml b.yml     # explicit files
#   bash scripts/workflow-job-shape-check.sh --selftest      # prove red + green

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
usage() {
  sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'
}

TARGET_DIR=""
FILES=()
SELFTEST=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --dir)
      if [ "$#" -lt 2 ]; then
        echo "workflow-job-shape-check: --dir needs a path" >&2
        exit 2
      fi
      TARGET_DIR="$2"; shift 2 ;;
    --dir=*) TARGET_DIR="${1#--dir=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*)
      # An unknown flag NEVER passes. A typo'd flag that exits 0 is a gate that
      # silently stopped checking.
      echo "workflow-job-shape-check: unknown option '$1'" >&2
      echo "workflow-job-shape-check: CANNOT MEASURE (rc 2)" >&2
      exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

# ── the checker ─────────────────────────────────────────────────────────────
run_check() {
  python3 - "$@" <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "workflow-job-shape-check: PyYAML is not importable — CANNOT MEASURE (rc 2)\n"
    )
    sys.exit(2)

args = sys.argv[1:]
files = []
for a in args:
    if os.path.isdir(a):
        for name in sorted(os.listdir(a)):
            if name.endswith((".yml", ".yaml")):
                files.append(os.path.join(a, name))
    else:
        files.append(a)

if not files:
    sys.stderr.write(
        "workflow-job-shape-check: zero workflow files to parse — CANNOT MEASURE (rc 2)\n"
    )
    sys.exit(2)

bad = []
jobs_seen = 0
steps_seen = 0
files_parsed = 0

for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        bad.append((path, None, "file does not exist"))
        continue
    except yaml.YAMLError as exc:
        first = str(exc).splitlines()[0] if str(exc).strip() else exc.__class__.__name__
        bad.append((path, None, "not parseable as YAML: %s" % first))
        continue
    files_parsed += 1

    if not isinstance(doc, dict):
        bad.append((path, None, "top level is not a mapping"))
        continue

    jobs = doc.get("jobs")
    if jobs is None:
        # A workflow with no `jobs:` key at all is its own kind of dead file,
        # but it is a different defect class than a malformed job and some
        # fixtures legitimately have none. Report it, do not count it as a job.
        bad.append((path, None, "has no `jobs:` mapping"))
        continue
    if not isinstance(jobs, dict) or not jobs:
        bad.append((path, None, "`jobs:` is empty or not a mapping"))
        continue

    for job_id, job in jobs.items():
        jobs_seen += 1
        if not isinstance(job, dict):
            bad.append((path, job_id, "job body is not a mapping"))
            continue
        has_uses = "uses" in job and job["uses"]
        if has_uses:
            continue
        has_runs_on = "runs-on" in job and job["runs-on"] not in (None, "", [], {})
        steps = job.get("steps")
        has_steps = isinstance(steps, list) and len(steps) > 0

        # THE STEP CLAUSE. Walked for its own sake, not as part of the job
        # verdict: a job can be perfectly shaped and still carry a step Actions
        # refuses, and that is the wave-42 defect verbatim. Reported by INDEX
        # because a step is not required to have a name, and the index is what
        # survives a step whose only key was the one that got deleted.
        if isinstance(steps, list):
            for idx, step in enumerate(steps):
                steps_seen += 1
                label = "step[%d]" % idx
                if isinstance(step, dict) and isinstance(step.get("name"), str):
                    label += ' (name: "%s")' % step["name"]
                if not isinstance(step, dict):
                    bad.append((path, job_id, "%s is not a mapping" % label))
                    continue
                has_run = "run" in step and step["run"] not in (None, "")
                has_step_uses = "uses" in step and step["uses"] not in (None, "")
                if has_run and has_step_uses:
                    bad.append((
                        path, job_id,
                        "%s has BOTH run: and uses: — a step may carry exactly "
                        "one" % label,
                    ))
                elif not has_run and not has_step_uses:
                    bad.append((
                        path, job_id,
                        "%s has neither run: nor uses: — the step cannot "
                        "execute" % label,
                    ))

        if has_runs_on and has_steps:
            continue
        missing = []
        if not has_runs_on:
            missing.append("runs-on")
        if not has_steps:
            missing.append("steps" if steps is None else "non-empty steps")
        bad.append((
            path,
            job_id,
            "has neither (runs-on + steps) nor uses: — missing %s" % ", ".join(missing),
        ))

# ORDER MATTERS. The coverage floor exists to stop a VACUOUS GREEN, so it only
# fires when nothing was found AND nothing was measured. A file that would not
# parse is a real finding — rc 1 — even though it contributed zero jobs; if the
# floor were checked first, the single most severe input (a workflow GitHub
# cannot read at all) would downgrade itself into "cannot measure".
if not bad and jobs_seen == 0:
    sys.stderr.write(
        "workflow-job-shape-check: parsed %d file(s) but found ZERO jobs — CANNOT MEASURE (rc 2)\n"
        % files_parsed
    )
    sys.exit(2)

if bad:
    for path, job_id, why in bad:
        if job_id is None:
            sys.stderr.write("RED  %s — %s\n" % (path, why))
        else:
            sys.stderr.write("RED  %s: job `%s` %s\n" % (path, job_id, why))
    sys.stderr.write(
        "\nGitHub refuses the ENTIRE workflow file when a job or a step has no legal shape: "
        "the run reports 'a workflow file issue', renders zero jobs, and every "
        "check in that file silently stops running.\n"
    )
    sys.stderr.write(
        "workflow-job-shape-check: FAIL — %d problem(s) across %d file(s), %d job(s) and %d step(s) inspected\n"
        % (len(bad), len(files), jobs_seen, steps_seen)
    )
    sys.exit(1)

print(
    "workflow-job-shape-check: OK — %d file(s), %d job(s), %d step(s); every job has runs-on+steps or uses, and every step exactly one of run:/uses:"
    % (files_parsed, jobs_seen, steps_seen)
)
sys.exit(0)
PY
}

# ── selftest ────────────────────────────────────────────────────────────────
selftest() {
  local fails=0
  # NOT `local`: the EXIT trap runs after this function's locals are gone, and
  # a trap that references a dead local dies with "unbound variable" under
  # `set -u` — after the assertions have already printed, which is exactly the
  # shape that makes a harness look flaky instead of broken.
  SELFTEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-job-shape-selftest.XXXXXX")"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT
  local tmp="$SELFTEST_TMP"

  mkdir -p "$tmp/only-name" "$tmp/no-steps" "$tmp/valid-uses" "$tmp/empty" "$tmp/broken-yaml"

  # (a) the measured specimen: a job with nothing but a `name:`.
  cat >"$tmp/only-name/wf.yml" <<'YML'
name: only-name
on: [push]
jobs:
  healthy-job:
    name: healthy
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  compose-smoke-dispatcher:
    name: compose-smoke dispatcher covers the census roots
YML

  # (b) runs-on present, steps absent.
  cat >"$tmp/no-steps/wf.yml" <<'YML'
name: no-steps
on: [push]
jobs:
  runner-without-steps:
    name: has a runner and nothing to run
    runs-on: ubuntu-latest
    timeout-minutes: 5
YML

  # (c) a legal reusable-workflow call — no runs-on, no steps, and correct.
  cat >"$tmp/valid-uses/wf.yml" <<'YML'
name: valid-uses
on: [push]
jobs:
  call-a-reusable-workflow:
    uses: ./.github/workflows/reusable.yml
    with:
      arg: value
  ordinary-runner:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YML

  # (d) unparseable YAML — the same failure one stage earlier.
  cat >"$tmp/broken-yaml/wf.yml" <<'YML'
name: broken
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
   steps:
      - run: echo hi
YML

  echo "── selftest ─────────────────────────────────────────────────────────"

  # _expect leaves the checker's own output in the global LAST_OUT so an
  # assertion can inspect WHAT the red said, not merely that it was red.
  # NEVER `printf '%s' "$out" | grep -q ...`. grep -q exits on first match and
  # closes the pipe; under `set -o pipefail` the printf takes SIGPIPE and the
  # PIPELINE returns 141, so the assertion reads FAIL on output that matched.
  # It only shows up when the match lands early enough to beat the writer —
  # i.e. intermittently. Here-strings have no upstream process to kill.
  LAST_OUT=""
  _expect() { # label expected_rc  (rest = args to run_check)
    local label="$1" want="$2"; shift 2
    local rc=0
    LAST_OUT="$(run_check "$@" 2>&1)" || rc=$?
    if [ "$rc" -eq "$want" ]; then
      printf 'PASS  %-46s rc=%d\n' "$label" "$rc"
    else
      printf 'FAIL  %-46s rc=%d (wanted %d)\n' "$label" "$rc" "$want"
      printf '%s\n' "$LAST_OUT" | sed 's/^/      | /'
      fails=$((fails + 1))
    fi
  }

  local out
  _expect '(a) job with only name: reds' 1 "$tmp/only-name"
  out="$LAST_OUT"
  if grep -q 'compose-smoke-dispatcher' <<<"$out"; then
    printf 'PASS  %-46s\n' '(a) the red NAMES the malformed job'
  else
    printf 'FAIL  %-46s\n' '(a) the red does not name the job'
    fails=$((fails + 1))
  fi
  # non-vacuity: the healthy sibling in the same file must NOT be reported.
  if grep -q 'healthy-job' <<<"$out"; then
    printf 'FAIL  %-46s\n' '(a) a healthy job was flagged too'
    fails=$((fails + 1))
  else
    printf 'PASS  %-46s\n' '(a) the healthy sibling is not flagged'
  fi

  _expect "(b) runs-on without steps reds" 1 "$tmp/no-steps"
  _expect '(c) a uses: job is green' 0 "$tmp/valid-uses"
  _expect '(d) unparseable YAML reds' 1 "$tmp/broken-yaml"
  _expect '(e) empty dir = CANNOT MEASURE, not green' 2 "$tmp/empty"
  _expect '(f) a single explicit file is checkable' 1 "$tmp/only-name/wf.yml"

  # ── the step clause ───────────────────────────────────────────────────────
  # (h) THE MUTATION PLANT, on a COPY OF A REAL WORKFLOW. A synthetic fixture
  # proves the rule; deleting the `run:` line out of a file this repo actually
  # ships proves the rule fires on the shape we actually write. The subject is
  # this checker's own wiring step, so the plant is self-referential on purpose:
  # if someone deletes that step's `run:`, this assertion is what notices.
  local root real
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  real="${root:-.}/.github/workflows/required-checks-drift.yml"
  if [ ! -f "$real" ]; then
    # NOT a skip. The criterion this plant exists to satisfy is "a real step,
    # mutated", and a plant that quietly opts out is the vacuous green the
    # coverage floor above exists to forbid.
    printf 'FAIL  %-46s\n' '(h) the real workflow to plant into is missing'
    fails=$((fails + 1))
  else
    mkdir -p "$tmp/real-clean" "$tmp/real-planted"
    cp "$real" "$tmp/real-clean/wf.yml"
    _expect '(h) a copied REAL workflow is green' 0 "$tmp/real-clean"

    local anchor n_before n_after
    anchor='run: bash scripts/workflow-job-shape-check.sh --selftest'
    n_before="$(grep -c -F -e "$anchor" "$tmp/real-clean/wf.yml" || true)"
    grep -v -F -e "$anchor" "$tmp/real-clean/wf.yml" >"$tmp/real-planted/wf.yml" || true
    n_after="$(grep -c -F -e "$anchor" "$tmp/real-planted/wf.yml" || true)"
    # ASSERT THE MUTATION APPLIED before believing any red it produces: the
    # anchor must have matched EXACTLY ONCE and be gone afterwards. A red from
    # a plant that never landed is a red about nothing.
    if [ "$n_before" = "1" ] && [ "$n_after" = "0" ] && \
       ! cmp -s "$tmp/real-clean/wf.yml" "$tmp/real-planted/wf.yml"; then
      printf 'PASS  %-46s\n' '(h) the plant APPLIED (anchor 1 -> 0, diff)'
    else
      printf 'FAIL  %-46s (before=%s after=%s)\n' \
        '(h) the plant did not apply' "$n_before" "$n_after"
      fails=$((fails + 1))
    fi

    _expect '(i) the de-run: real step reds' 1 "$tmp/real-planted"
    out="$LAST_OUT"
    # The red must be locatable: file, job id, and the step INDEX.
    if grep -q 'real-planted/wf.yml' <<<"$out" &&
       grep -q 'job `workflow-job-shape`' <<<"$out" &&
       grep -qE 'step\[[0-9]+\]' <<<"$out"; then
      printf 'PASS  %-46s\n' '(i) red names file, job and step index'
    else
      printf 'FAIL  %-46s\n' '(i) red is not locatable'
      printf '%s\n' "$out" | sed 's/^/      | /'
      fails=$((fails + 1))
    fi
    # and it must name THAT step, not merely some step.
    if grep -q 'Prove the shape checker on planted fixtures' <<<"$out"; then
      printf 'PASS  %-46s\n' '(i) red names the planted step by name:'
    else
      printf 'FAIL  %-46s\n' '(i) red does not name the planted step'
      fails=$((fails + 1))
    fi
    # non-vacuity: the two SIBLING steps in the same job are still legal and
    # must not be swept in with the planted one.
    if grep -q 'step\[0\]' <<<"$out"; then
      printf 'FAIL  %-46s\n' '(i) a healthy sibling step was flagged'
      fails=$((fails + 1))
    else
      printf 'PASS  %-46s\n' '(i) healthy sibling steps are not flagged'
    fi
  fi

  # (j) BOTH run: and uses: — equally invalid to Actions, and what a
  # half-finished edit from one to the other leaves behind.
  mkdir -p "$tmp/both-keys"
  cat >"$tmp/both-keys/wf.yml" <<'YML'
name: both-keys
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: legal
        run: echo ok
      - name: carries run and uses
        uses: actions/checkout@v4
        run: echo also
YML
  _expect '(j) a step with BOTH run: and uses: reds' 1 "$tmp/both-keys"
  out="$LAST_OUT"
  if grep -q 'BOTH run: and uses:' <<<"$out"; then
    printf 'PASS  %-46s\n' '(j) the red says which clause fired'
  else
    printf 'FAIL  %-46s\n' '(j) the red does not say BOTH'
    fails=$((fails + 1))
  fi

  # (k) a synthetic step with NEITHER key — the wave-42 shape verbatim
  # (`name:` + `env:` and nothing to execute), in a job that is otherwise
  # perfectly shaped, so only the step clause can catch it.
  mkdir -p "$tmp/name-env-step"
  cat >"$tmp/name-env-step/wf.yml" <<'YML'
name: name-env-step
on: [push]
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - name: File the failure
        env:
          TOKEN: ${{ secrets.TOKEN }}
YML
  _expect '(k) name:+env: step with no run: reds' 1 "$tmp/name-env-step"

  # (g) a bad flag must never exit 0. Run the SCRIPT, not run_check.
  local rc=0
  bash "$SELF" --no-such-flag >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'PASS  %-46s rc=2\n' '(g) unknown flag exits 2'
  else
    printf 'FAIL  %-46s rc=%d (wanted 2)\n' '(g) unknown flag exits 2' "$rc"
    fails=$((fails + 1))
  fi

  echo "─────────────────────────────────────────────────────────────────────"
  if [ "$fails" -ne 0 ]; then
    echo "workflow-job-shape-check --selftest: $fails assertion(s) FAILED"
    return 1
  fi
  echo "workflow-job-shape-check --selftest: all assertions passed"
  return 0
}

if [ "$SELFTEST" -eq 1 ]; then
  selftest
  exit $?
fi

if [ "${#FILES[@]}" -eq 0 ] && [ -z "$TARGET_DIR" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$root" ]; then
    TARGET_DIR="$root/.github/workflows"
  else
    TARGET_DIR=".github/workflows"
  fi
fi

if [ -n "$TARGET_DIR" ]; then
  if [ ! -d "$TARGET_DIR" ]; then
    echo "workflow-job-shape-check: '$TARGET_DIR' is not a directory — CANNOT MEASURE (rc 2)" >&2
    exit 2
  fi
  FILES+=("$TARGET_DIR")
fi

run_check "${FILES[@]}"
