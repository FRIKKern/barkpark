#!/usr/bin/env bash
# required-context-never-cancels-check.sh — a REQUIRED context must never be
# able to conclude `cancelled`.
#
# THE DEFECT THIS FORBIDS. Branch protection reads a required context's LATEST
# conclusion on the head sha. A conclusion of `cancelled` is a THIRD refusal
# shape — `... is cancelled.` (honest-gates D38) — distinct from failing and
# from expected, and it names nothing a contributor can act on. It clears only
# on a re-run or a push.
#
# HOW A REQUIRED CONTEXT GETS CANCELLED WITHOUT ANYONE CANCELLING ANYTHING.
# A workflow with `cancel-in-progress` truthy cancels its own earlier run
# whenever a second qualifying event lands mid-run. `gh pr create --label hold`
# emits `opened` AND `labeled` about a second apart; both enter the same
# concurrency group; the second collapses the first. The cancelled run's check
# runs PERSIST as extra rows under the required name, and the merge refuses.
# Any second `pull_request`-type event mid-run does it — a body `edited` to fix
# a trailer, a `hotfix!` label applied to an already-red PR. The label-at-open
# case is just the one that fires reliably enough to be reproduced on demand.
#
# WHY `if: always()` IS THE EXEMPTION AND NOT A LOOPHOLE. An `always()` job
# still RUNS when its run is cancelled — that is precisely what `always()`
# means. An aggregator that decides over `needs.<job>.result` therefore sees
# cancelled upstreams and concludes `failure`, never `cancelled`, so the merge
# refusal it produces is the honest `is failing.` shape that names the upstream.
#
# MEASURED, not reasoned, on PR #18391 head d0a37cc469fd9d23c624c217bd4df8dc1be66b04:
# the `cloud`, `console-harness`, `elixir` AND `pr-task-gate` runs were ALL
# cancelled at run level inside the same second. The three aggregator contexts
# (`Cloud gate`, `Console gate`, `Elixir gate`) rendered `failure`. The one
# plain job (`PR references an active task`) rendered `cancelled`, twice.
# That is the whole predicate below, read off a real head.
#
# THE PREDICATE — exactly one reason to red. FAIL iff a job that publishes a
# REQUIRED context BOTH
#   (a) lives in a workflow whose `concurrency.cancel-in-progress` is anything
#       other than the literal boolean `false` (a bare `true`, or any `${{ }}`
#       expression, which can evaluate true), AND
#   (b) carries no `always()` in its job-level `if:`.
# Either half alone is a clean remedy, and the gate deliberately accepts BOTH:
# set `cancel-in-progress: false`, or make the job an `always()` decider. It
# asserts the INVARIANT, not one blessed spelling of the fix.
#
# THE REQUIRED NAMES ARE READ FROM .github/required-checks.json, never
# hardcoded here. A context promoted into required protection tomorrow is
# covered by this gate the same day, with no edit to this file. That file is
# the repo's single owner of "what blocks a merge"; a second list here would be
# a second owner, and the two would drift.
#
# SCOPE, stated so the green is not over-read: this gate judges the REQUIRED
# set only. A non-required context can conclude `cancelled` harmlessly — it
# blocks nothing — which is why `PR task gate self-test`, cancelled on the very
# head measured above, is correctly not a finding here.
#
# --selftest proves this gate is ABLE TO FAIL (charter D2: distrust vacuous
# green). It runs the predicate over synthetic fixtures in a temp dir, asserts
# red on each hazardous shape and green on each safe one, and then re-execs the
# WHOLE SCRIPT against fixture roots so the verdict wiring — the text-to-exit-
# code branch — is itself under test. It plants nothing in the tree.
#
# Usage: scripts/required-context-never-cancels-check.sh [--selftest]
set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOW_DIR="${REQCTX_WORKFLOW_DIR:-.github/workflows}"
SPEC="${REQCTX_SPEC:-.github/required-checks.json}"

# scan <workflow_dir> <spec> — prints "FAIL <ctx>" / "NOTE <ctx>" / "OK <ctx>"
# lines, one per required context. Exits 2 (never 0/1) if the harness itself is
# unavailable, so a broken harness can never be read as a verdict on the
# workflows (charter D3: an exit code alone cannot discriminate a dependency
# error from a real verdict — the text does).
scan() {
  python3 - "$1" "$2" <<'PY'
import sys, glob, os, json

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflows")
    sys.exit(2)

workflow_dir, spec_path = sys.argv[1], sys.argv[2]

try:
    spec = json.load(open(spec_path))
except Exception as exc:
    print(f"HARNESS-UNAVAILABLE: {spec_path} did not parse as JSON: {exc}")
    sys.exit(2)

try:
    checks = spec["protection"]["required_status_checks"]["checks"]
    required = [c["context"] for c in checks]
except Exception as exc:
    print(f"HARNESS-UNAVAILABLE: {spec_path} has no .protection.required_status_checks.checks: {exc}")
    sys.exit(2)

# A spec that enumerates ZERO required contexts would make every arm below
# vacuous and print a confident green over nothing measured.
if not required:
    print(f"HARNESS-UNAVAILABLE: {spec_path} enumerates zero required contexts; nothing to measure")
    sys.exit(2)

paths = sorted(glob.glob(os.path.join(workflow_dir, "*.yml"))
               + glob.glob(os.path.join(workflow_dir, "*.yaml")))
if not paths:
    print(f"HARNESS-UNAVAILABLE: no workflow files under {workflow_dir}; nothing to measure")
    sys.exit(2)


def can_cancel_itself(doc):
    """True unless the workflow is strictly never-cancel.

    Absent `concurrency` block, or absent `cancel-in-progress`, means GitHub
    never collapses runs -> safe. Only the LITERAL boolean False is the
    explicit never-cancel choice. A bare `true` is hazardous, and so is any
    `${{ ... }}` expression: it parses as a string here and can evaluate true
    on exactly the refs PRs run on.
    """
    conc = doc.get("concurrency")
    if not isinstance(conc, dict):
        return False
    if "cancel-in-progress" not in conc:
        return False
    return conc["cancel-in-progress"] is not False


def runs_when_cancelled(job):
    """True iff the job's `if:` makes it run even when the run is cancelled.

    Only `always()` does that. `success()`, `failure()` and a bare expression
    all skip on cancellation; `cancelled()` runs but is not a decider shape.
    """
    cond = job.get("if")
    return isinstance(cond, str) and "always()" in cond


# Index every published check-run name -> (workflow file, job dict).
index = {}
for path in paths:
    try:
        doc = yaml.safe_load(open(path))
    except Exception as exc:
        print(f"HARNESS-UNAVAILABLE: {path} did not parse as YAML: {exc}")
        sys.exit(2)
    if not isinstance(doc, dict):
        continue
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        continue
    for job_key, job in jobs.items():
        if not isinstance(job, dict):
            continue
        # GitHub publishes the job's `name:` when present, else the job key.
        published = job.get("name") or job_key
        if not isinstance(published, str):
            continue
        index.setdefault(published, []).append((os.path.basename(path), doc, job))

for ctx in required:
    emitters = index.get(ctx)
    if not emitters:
        # Not this gate's verdict to make: a required name that no job
        # publishes is the D18 absent-context deadlock, owned by
        # required-checks-verify.sh. Reported so it is visible, never as a
        # failure here -- a gate must red for exactly ONE reason.
        print(f"NOTE {ctx}: no job under {workflow_dir} publishes this name (not this gate's axis)")
        continue
    for wf_name, doc, job in emitters:
        if not can_cancel_itself(doc):
            print(f"OK {ctx} [{wf_name}]: workflow is strictly never-cancel")
        elif runs_when_cancelled(job):
            print(f"OK {ctx} [{wf_name}]: `always()` job — decides over needs, concludes failure not cancelled")
        else:
            print(f"FAIL {ctx} [{wf_name}]: required context on a self-cancelling workflow "
                  f"with no `always()` — this check run can conclude `cancelled` and block the merge")
PY
}

SELFTEST_TMP=""
cleanup_selftest() { [ -n "$SELFTEST_TMP" ] && rm -rf "$SELFTEST_TMP"; return 0; }
trap cleanup_selftest EXIT

write_spec() {
  # $1 = dir, remaining args = required context names
  local dir="$1"; shift
  local ctxs="" c
  for c in "$@"; do
    [ -n "$ctxs" ] && ctxs="$ctxs,"
    ctxs="$ctxs{\"context\":\"$c\",\"app_id\":15368}"
  done
  printf '{"protection":{"required_status_checks":{"checks":[%s]}}}\n' "$ctxs" >"$dir/required-checks.json"
}

selftest() {
  local tmp failed=0 out
  SELFTEST_TMP="$(mktemp -d)"
  tmp="$SELFTEST_TMP"
  mkdir -p "$tmp/wf"

  # HAZARDOUS — the real shape: a plain required job on a workflow whose
  # cancel-in-progress is a `${{ }}` expression that is TRUE on every PR ref.
  cat >"$tmp/wf/hazard.yml" <<'EOF'
name: hazard
on:
  pull_request:
    types: [opened, labeled]
concurrency:
  group: hazard-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  gate:
    name: Required plain job
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # HAZARDOUS — the same thing spelled as a bare literal true.
  cat >"$tmp/wf/hazard-bare.yml" <<'EOF'
name: hazard-bare
on: pull_request
concurrency:
  group: hazard-bare-${{ github.ref }}
  cancel-in-progress: true
jobs:
  gate:
    name: Required bare true
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — remedy 1: strictly never-cancel. This is the fix shipped for
  # pr-task-gate.yml, so this arm is the one that must stay green forever.
  cat >"$tmp/wf/nevercancel.yml" <<'EOF'
name: nevercancel
on: pull_request
concurrency:
  group: nevercancel-${{ github.ref }}
  cancel-in-progress: false
jobs:
  gate:
    name: Required never-cancel
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — remedy 2: an `always()` aggregator. This is the shape Cloud/Console/
  # Elixir gate carry, MEASURED concluding `failure` on a cancelled run.
  cat >"$tmp/wf/aggregator.yml" <<'EOF'
name: aggregator
on: pull_request
concurrency:
  group: aggregator-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  unit:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
  gate:
    name: Required aggregator
    if: always()
    needs: [unit]
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — no concurrency block at all: GitHub never collapses these runs.
  cat >"$tmp/wf/noconcurrency.yml" <<'EOF'
name: noconcurrency
on: pull_request
jobs:
  gate:
    name: Required no concurrency
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  write_spec "$tmp" \
    "Required plain job" "Required bare true" "Required never-cancel" \
    "Required aggregator" "Required no concurrency"

  out="$(scan "$tmp/wf" "$tmp/required-checks.json")" || {
    echo "SELFTEST FAILED: scan exited non-zero over the fixture root" >&2
    exit 1
  }

  # --- RED arms: each hazardous shape must be named as a FAIL ---
  if ! grep -q '^FAIL Required plain job ' <<<"$out"; then
    echo "SELFTEST FAILED: the gate did not red on a plain required job with a truthy cancel expression" >&2
    failed=1
  fi
  if ! grep -q '^FAIL Required bare true ' <<<"$out"; then
    echo "SELFTEST FAILED: the gate did not red on a plain required job with a bare \`cancel-in-progress: true\`" >&2
    failed=1
  fi

  # --- GREEN arms: each safe shape must NOT be a FAIL. Without these a gate
  #     hard-wired to red would pass every arm above and fail every real PR. ---
  local safe
  for safe in "Required never-cancel" "Required aggregator" "Required no concurrency"; do
    if grep -q "^FAIL ${safe} " <<<"$out"; then
      echo "SELFTEST FAILED: the gate red on a SAFE shape: ${safe}" >&2
      failed=1
    fi
    if ! grep -q "^OK ${safe} " <<<"$out"; then
      echo "SELFTEST FAILED: the gate did not report OK for the safe shape: ${safe}" >&2
      failed=1
    fi
  done

  # --- SCOPE arm: a job that is NOT a required context must never be judged,
  #     however hazardous its shape. `PR task gate self-test` is exactly this
  #     -- it concluded `cancelled` on the measured head and blocks nothing. ---
  if grep -qE '^(FAIL|OK) hazard-unrequired' <<<"$out"; then
    echo "SELFTEST FAILED: the gate judged a job outside the required set" >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo "--- selftest scan output ---" >&2
    echo "$out" >&2
    exit 1
  fi

  # ── E2E ARMS: the VERDICT WIRING, not just scan() ────────────────────────
  # Every arm above asserts on the TEXT scan() returned. None executes the
  # branch that turns that text into an exit code. The sibling gate
  # never-cancel-main-check.sh was MEASURED (task-5c4187dda277d445) to stay
  # fully green while its real verdict was disarmed, precisely because its
  # arms stopped at the text. These re-exec THIS SCRIPT and assert on the exit
  # code of the whole program.
  local e2e_rc

  # (a) a root carrying the hazard must exit 1.
  e2e_rc=0
  REQCTX_WORKFLOW_DIR="$tmp/wf" REQCTX_SPEC="$tmp/required-checks.json" \
    bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 1 ]; then
    echo "SELFTEST FAILED (E2E): a root carrying the hazard must exit 1, got ${e2e_rc}." >&2
    echo "  The verdict wiring — \`grep -q '^FAIL ' <<<\"\$RESULT\"\` then exit 1 — is disarmed or unreachable." >&2
    failed=1
  fi

  # (b) a root of ONLY safe shapes must exit 0.
  local safe_dir="$tmp/safe-only"
  mkdir -p "$safe_dir/wf"
  cp "$tmp/wf/nevercancel.yml" "$tmp/wf/aggregator.yml" "$tmp/wf/noconcurrency.yml" "$safe_dir/wf/"
  write_spec "$safe_dir" "Required never-cancel" "Required aggregator" "Required no concurrency"
  e2e_rc=0
  REQCTX_WORKFLOW_DIR="$safe_dir/wf" REQCTX_SPEC="$safe_dir/required-checks.json" \
    bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 0 ]; then
    echo "SELFTEST FAILED (E2E): a root of only safe shapes must exit 0, got ${e2e_rc}." >&2
    failed=1
  fi

  # (c) an EMPTY workflow root must exit 2, never 0. A glob matching nothing
  #     prints nothing and would otherwise report "gate OK" over zero files.
  local empty_dir="$tmp/empty-root"
  mkdir -p "$empty_dir/wf"
  write_spec "$empty_dir" "Required plain job"
  e2e_rc=0
  REQCTX_WORKFLOW_DIR="$empty_dir/wf" REQCTX_SPEC="$empty_dir/required-checks.json" \
    bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 2 ]; then
    echo "SELFTEST FAILED (E2E): an EMPTY workflow root must exit 2 (could not RUN), got ${e2e_rc}." >&2
    failed=1
  fi

  # (d) a spec enumerating ZERO required contexts must exit 2. Otherwise the
  #     gate loops over nothing and prints a confident green — the vacuous
  #     shape this whole harness exists to refuse.
  local nospec_dir="$tmp/no-required"
  mkdir -p "$nospec_dir"
  write_spec "$nospec_dir"
  e2e_rc=0
  REQCTX_WORKFLOW_DIR="$tmp/wf" REQCTX_SPEC="$nospec_dir/required-checks.json" \
    bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 2 ]; then
    echo "SELFTEST FAILED (E2E): a spec with zero required contexts must exit 2, got ${e2e_rc}." >&2
    failed=1
  fi

  # (e) a MISSING spec must exit 2 too — a typo'd override must never green.
  e2e_rc=0
  REQCTX_WORKFLOW_DIR="$tmp/wf" REQCTX_SPEC="$tmp/does-not-exist.json" \
    bash "$0" >/dev/null 2>&1 || e2e_rc=$?
  if [ "$e2e_rc" -ne 2 ]; then
    echo "SELFTEST FAILED (E2E): a MISSING spec must exit 2 (could not RUN), got ${e2e_rc}." >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi

  echo "required-context-never-cancels selftest OK — reds on a plain required job under both truthy spellings; green on never-cancel, on \`always()\`, and on no-concurrency; scope-limited to the required set; and E2E: exits 1 on a hazard root, 0 on a safe root, 2 on an empty root, a zero-context spec, and a missing spec."
}

# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "required-context-never-cancels-check: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

RESULT="$(scan "$WORKFLOW_DIR" "$SPEC")" || exit 2
if grep -q '^HARNESS-UNAVAILABLE' <<<"$RESULT"; then
  echo "$RESULT" >&2
  exit 2
fi

echo "$RESULT"

if grep -q '^FAIL ' <<<"$RESULT"; then
  cat >&2 <<'MSG'

required-context-never-cancels: FAILED.

A job publishing a REQUIRED context can conclude `cancelled`, which blocks the
merge with the `... is cancelled.` refusal that names nothing actionable
(honest-gates D38). It happens with nobody cancelling anything: a second
`pull_request`-type event mid-run (a label applied at open, a body edit)
collapses the first run, and the cancelled run's check runs persist as extra
rows under the required name.

Two remedies, either is accepted by this gate:
  1. Set `cancel-in-progress: false` on that workflow. Correct when the job is
     cheap — the saving was never worth a merge that explains nothing.
  2. Make the job an `if: always()` decider over `needs.<job>.result`. An
     `always()` job still runs when its run is cancelled, so it concludes
     `failure` — a refusal that names the upstream.

Do NOT narrow the workflow's `on: ... types:` to dodge the second event: on
pr-task-gate.yml those types are the emergency lane's only re-fire path.
MSG
  exit 1
fi

echo "required-context-never-cancels gate OK — every required context is structurally unable to conclude \`cancelled\`."
