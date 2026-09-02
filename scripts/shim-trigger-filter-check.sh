#!/usr/bin/env bash
#
# shim-trigger-filter-check.sh — the D18 ratchet for SHIMMED workflows.
#
# ── THE DEFECT THIS EXISTS TO REFUSE ─────────────────────────────────────────
#
# A "shim" in this repo is a two-part shape: an always-running DISPATCHER job
# that computes a changed-path verdict, and an `if: always()` AGGREGATOR job
# that judges every upstream result and publishes ONE constant name. The whole
# purpose of that shape is that the name RENDERS ON EVERY HEAD, including heads
# whose path verdict says nothing needs to run. `.github/required-checks.json`
# states the rule it serves: a workflow-level `on: … paths:` filter emits NO
# workflow run and NO check run at all on a non-matching head, so a name pinned
# from such a workflow reports `is expected.` forever and the pull request is
# stuck with nothing to fix (honest-gates D18).
#
# Put a workflow-level `paths:` back on a shimmed workflow and the shim becomes
# dead code: the dispatcher, the job-level `if:`s and the aggregator all still
# exist, all still look right in review, and the name they were built to publish
# is simply absent on the heads that matter. Nothing in the tree noticed. Three
# separate files argue against it in PROSE — compose-smoke.yml's header, the
# capitalised standing sentence in security.yml's header ("THIS WORKFLOW MUST
# NEVER REGAIN A WORKFLOW-LEVEL `on: … paths:` KEY."), and required-checks.json's
# own preamble — and prose is not a ratchet. A line number would be the wrong
# pin here: these are headers, and headers grow.
#
# MEASURED 2026-09-02: a P1 row proposed exactly that edit for compose-smoke,
# security and go-tests, on the reasonable-looking ground that they start a run
# on every pull request. They do, on purpose. This file turns three prose
# refusals into one machine refusal, so the next reader meets a red instead of a
# plausible argument. This check is ADVISORY of no context and NEVER blocks a
# merge on its own: it runs as a step of pr-meta.yml, which is not required.
#
# ── THE SUBJECT IS DERIVED, NEVER TYPED ──────────────────────────────────────
#
# A hardcoded roster of "workflows that must stay unfiltered" rots the moment a
# seventh workflow gains a shim, and rots SILENTLY — the new one is unprotected
# and the file still reads complete. So the roster is computed from the YAML:
#
#   AGGREGATOR   a job whose `if:` is exactly `always()` (any surrounding
#                `${{ }}` stripped), with a non-empty `needs:` and no
#                `strategy.matrix` — a matrix makes the published name vary,
#                which is the one thing an aggregator name may never do.
#   DISPATCHER   a job in that aggregator's `needs` with no `if:`, no `needs:`
#                of its own, and a non-empty `outputs:` mapping — a job that
#                runs unconditionally and hands a verdict downstream.
#   SHIMMED      a workflow with at least one aggregator whose needs contain at
#                least one dispatcher.
#
# A shimmed workflow carrying `on.pull_request.paths` or
# `on.pull_request.paths-ignore` is the finding. Everything else is out of
# subject: a workflow with no shim is free to filter its trigger, which is why
# most of this repo's workflows do and why this guard says nothing about them.
#
# ── TWO WAYS THIS GUARD COULD GO BLIND, AND WHAT STOPS EACH ──────────────────
#
#   1. IT SCANS NOTHING. A parser change, a moved directory or a `--dir` typo
#      makes "0 shimmed workflows, 0 findings" — a green that measured nothing,
#      indistinguishable from a clean tree. Zero shimmed workflows is exit 2,
#      REFUSED TO MEASURE, never exit 0.
#   2. THE SHIM IS DELETED INSTEAD OF FILTERED. Dropping an aggregator removes
#      the workflow from the subject, so the filter that follows is legal. The
#      committed floor is what makes that visible: the roster may grow freely
#      and may never silently shrink.
#
# The floor is a ratchet in the safe direction — it demands MORE shims, never
# fewer — so it cannot be walked forward one waiver at a time. Retiring a shim
# on purpose means lowering it in the same commit, which is a diff a reviewer
# reads rather than a number nobody sees.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#
#   bash scripts/shim-trigger-filter-check.sh              # scan .github/workflows
#   bash scripts/shim-trigger-filter-check.sh --dir DIR    # scan DIR
#   bash scripts/shim-trigger-filter-check.sh --selftest   # mutation matrix
#
#   exit 0  every shimmed workflow's pull_request trigger is unfiltered
#   exit 1  a shimmed workflow carries a workflow-level paths filter
#   exit 2  refused to measure (no workflows, no shims, unreadable YAML,
#           floor breached, PyYAML missing)
#
set -euo pipefail

DEFAULT_DIR=".github/workflows"

# The committed roster size: cloud, compose-smoke, console-harness, elixir,
# go-tests, security. RAISE it when a workflow gains a shim; lowering it is only
# correct in the same commit that deliberately retires one.
SHIMMED_WORKFLOW_FLOOR="${SHIMMED_WORKFLOW_FLOOR:-6}"

scan() {
  local dir="$1" floor="$2"
  python3 - "$dir" "$floor" <<'PY'
import os
import sys

try:
    import yaml
except Exception as exc:  # environment defect, not a finding
    print(
        f"shim-trigger-filter-check: REFUSING TO MEASURE — PyYAML unavailable ({exc}).",
        file=sys.stderr,
    )
    sys.exit(2)

directory = sys.argv[1]
floor = int(sys.argv[2])

if not os.path.isdir(directory):
    print(
        f"shim-trigger-filter-check: REFUSING TO MEASURE — '{directory}' is not a directory.",
        file=sys.stderr,
    )
    sys.exit(2)

files = sorted(
    os.path.join(directory, name)
    for name in os.listdir(directory)
    if name.endswith((".yml", ".yaml"))
)
if not files:
    print(
        f"shim-trigger-filter-check: REFUSING TO MEASURE — no workflow files under '{directory}'.",
        file=sys.stderr,
    )
    sys.exit(2)


def triggers(doc):
    # PyYAML resolves the bare key `on:` to the boolean True. Both spellings
    # reach the same mapping and a workflow may legally carry either.
    on = doc.get("on", doc.get(True))
    return on if isinstance(on, dict) else {}


def is_always(value):
    if value is None:
        return False
    text = str(value).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    return text == "always()"


def needs_of(cfg):
    needs = cfg.get("needs")
    if isinstance(needs, str):
        return [needs]
    return list(needs or [])


shimmed = []
findings = []
unreadable = []

for path in files:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except Exception as exc:
        unreadable.append(f"{path}: {exc}")
        continue
    if not isinstance(doc, dict):
        continue

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        continue

    dispatchers = {
        jid
        for jid, cfg in jobs.items()
        if isinstance(cfg, dict)
        and cfg.get("if") is None
        and not cfg.get("needs")
        and isinstance(cfg.get("outputs"), dict)
        and cfg.get("outputs")
    }

    aggregators = []
    for jid, cfg in jobs.items():
        if not isinstance(cfg, dict) or not is_always(cfg.get("if")):
            continue
        needs = needs_of(cfg)
        if not needs:
            continue
        strategy = cfg.get("strategy")
        if isinstance(strategy, dict) and strategy.get("matrix"):
            continue
        if set(needs) & dispatchers:
            aggregators.append(cfg.get("name") or jid)

    if not aggregators:
        continue
    shimmed.append((path, aggregators))

    pull_request = triggers(doc).get("pull_request")
    if isinstance(pull_request, dict):
        for key in ("paths", "paths-ignore"):
            if key in pull_request:
                findings.append((path, key, aggregators))

if unreadable:
    print(
        "shim-trigger-filter-check: REFUSING TO MEASURE — unparseable workflow(s):",
        file=sys.stderr,
    )
    for line in unreadable:
        print(f"  {line}", file=sys.stderr)
    sys.exit(2)

print(
    f"shim-trigger-filter-check: {len(shimmed)} shimmed workflow(s) "
    f"of {len(files)} scanned in {directory}"
)
for path, aggregators in shimmed:
    names = ", ".join(f"'{n}'" for n in aggregators)
    print(f"  shim  {os.path.basename(path)} -> aggregator name(s): {names}")

if not shimmed:
    print(
        "shim-trigger-filter-check: REFUSING TO MEASURE — zero shimmed workflows found. "
        "A scan with no subject prints the same green as a clean tree; that is not a reading.",
        file=sys.stderr,
    )
    sys.exit(2)

if len(shimmed) < floor:
    print("", file=sys.stderr)
    print(
        f"shim-trigger-filter-check: FAILED — {len(shimmed)} shimmed workflow(s), "
        f"below the committed floor of {floor}.",
        file=sys.stderr,
    )
    print(
        "  A shim disappeared. Deleting an aggregator takes its workflow OUT of this guard's "
        "subject, so the paths filter that follows would be legal and unremarked. If a shim was "
        "retired on purpose, lower SHIMMED_WORKFLOW_FLOOR in the same commit and say which one.",
        file=sys.stderr,
    )
    sys.exit(2)

if findings:
    print("", file=sys.stderr)
    for path, key, aggregators in findings:
        names = ", ".join(f"'{n}'" for n in aggregators)
        print(
            f"shim-trigger-filter-check: FAILED — {path} is SHIMMED "
            f"(aggregator name(s): {names}) and carries a workflow-level "
            f"on.pull_request.{key} filter.",
            file=sys.stderr,
        )
    print("", file=sys.stderr)
    print(
        "  A workflow-level paths filter emits no workflow run and no check run on a "
        "non-matching head, so the aggregator name above is ABSENT there — which is the one "
        "state the shim was built to prevent (honest-gates D18). The path decision belongs in "
        "the dispatcher, which is where these workflows already make it. To cut runner cost, "
        "narrow what the arms DO behind the job-level `if:`; do not filter the trigger.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"shim-trigger-filter-check: OK — no shimmed workflow carries a workflow-level "
    f"pull_request paths filter (floor {floor})."
)
PY
}

# ── SELFTEST ─────────────────────────────────────────────────────────────────
# A guard whose steady state is "clean" is indistinguishable from a guard that
# stopped working, so every case below is run against a planted tree and the
# exit code is asserted. Six cases: the clean shape passes, BOTH filter keys are
# caught, an unshimmed workflow keeps its right to filter, an aggregator with no
# dispatcher behind it is not mistaken for a shim, and the two blind spots named
# in the header (nothing scanned, floor breached) exit 2 instead of 0.
SELFTEST_TMP=""
_selftest_cleanup() { [ -n "${SELFTEST_TMP:-}" ] && rm -rf "$SELFTEST_TMP"; return 0; }

selftest() {
  # `tmp` is deliberately NOT `local`: the EXIT trap fires after this function
  # has returned, when a `local` is already out of scope, and reading an unset
  # name under `set -u` would abort the shell AFTER the tally printed — a run
  # that says "8 passed, 0 failed" and exits non-zero.
  local pass=0 fail=0
  SELFTEST_TMP="$(mktemp -d)"
  tmp="$SELFTEST_TMP"
  trap _selftest_cleanup EXIT

  _case() {
    local label="$1" want="$2" dir="$3" floor="${4:-1}"
    local got=0 out
    out="$(SHIMMED_WORKFLOW_FLOOR="$floor" scan "$dir" "$floor" 2>&1)" || got=$?
    if [ "$got" -eq "$want" ]; then
      printf 'ok   %s (exit %s)\n' "$label" "$got"
      pass=$((pass + 1))
    else
      printf 'FAIL %s — wanted exit %s, got %s\n%s\n' "$label" "$want" "$got" "$out"
      fail=$((fail + 1))
    fi
  }

  _shim_body() {
    cat <<'EOF'
jobs:
  changes:
    name: Dispatch (paths)
    runs-on: ubuntu-latest
    outputs:
      hit: ${{ steps.s.outputs.hit }}
    steps:
      - run: echo hit=true >> "$GITHUB_OUTPUT"
  work:
    name: The expensive arm
    needs: changes
    if: needs.changes.outputs.hit == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo work
  gate:
    name: Example gate
    if: always()
    needs: [changes, work]
    runs-on: ubuntu-latest
    steps:
      - run: echo decide
EOF
  }

  # 1. the clean shape — a shim with an unfiltered pull_request trigger.
  mkdir -p "$tmp/clean"
  { printf 'name: ex\non:\n  pull_request:\n  push:\n    branches: [main]\n'; _shim_body; } > "$tmp/clean/ex.yml"
  _case "a shimmed workflow with an unfiltered pull_request trigger PASSES" 0 "$tmp/clean"

  # 2 + 3. the mutation this guard exists for, in both spellings.
  for key in paths paths-ignore; do
    mkdir -p "$tmp/filtered-$key"
    { printf 'name: ex\non:\n  pull_request:\n    %s:\n      - "api/**"\n  push:\n    branches: [main]\n' "$key"; _shim_body; } \
      > "$tmp/filtered-$key/ex.yml"
    _case "a shimmed workflow with on.pull_request.$key is DETECTED" 1 "$tmp/filtered-$key"
  done

  # 4. out of subject: no shim, so the filter is legal and unremarked. The
  #    planted tree also carries the clean shim, so the floor is still met and
  #    the pass is about the unshimmed file rather than an empty scan.
  mkdir -p "$tmp/unshimmed"
  cp "$tmp/clean/ex.yml" "$tmp/unshimmed/ex.yml"
  cat > "$tmp/unshimmed/plain.yml" <<'EOF'
name: plain
on:
  pull_request:
    paths:
      - "docs/**"
jobs:
  test:
    name: Plain test
    runs-on: ubuntu-latest
    steps:
      - run: echo test
EOF
  _case "an UNSHIMMED workflow keeps its right to filter its trigger" 0 "$tmp/unshimmed"

  # 5. an `always()` aggregator whose needs hold no dispatcher is not a shim —
  #    without this the guard would claim authority over workflows it cannot
  #    reason about.
  mkdir -p "$tmp/no-dispatcher"
  cp "$tmp/clean/ex.yml" "$tmp/no-dispatcher/ex.yml"
  cat > "$tmp/no-dispatcher/agg.yml" <<'EOF'
name: agg
on:
  pull_request:
    paths:
      - "docs/**"
jobs:
  build:
    name: Build
    runs-on: ubuntu-latest
    steps:
      - run: echo build
  summary:
    name: Summary
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - run: echo summary
EOF
  _case "an always() job with no DISPATCHER upstream is not read as a shim" 0 "$tmp/no-dispatcher"

  # 6. blind spot one: a scan with no subject must refuse, never pass.
  mkdir -p "$tmp/empty-subject"
  cp "$tmp/no-dispatcher/agg.yml" "$tmp/empty-subject/agg.yml"
  _case "a directory with ZERO shimmed workflows REFUSES TO MEASURE" 2 "$tmp/empty-subject"

  # 7. blind spot two: deleting a shim must red, not silently shrink the subject.
  _case "a roster below the committed floor REFUSES TO MEASURE" 2 "$tmp/clean" 2

  # 8. an unreadable workflow must refuse rather than skip quietly.
  mkdir -p "$tmp/broken"
  cp "$tmp/clean/ex.yml" "$tmp/broken/ex.yml"
  printf 'name: broken\non:\n  pull_request:\n   bad: [unclosed\n' > "$tmp/broken/broken.yml"
  _case "an unparseable workflow REFUSES TO MEASURE" 2 "$tmp/broken"

  printf '\nshim-trigger-filter-check --selftest: %s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

main() {
  local dir="$DEFAULT_DIR"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --selftest)
        selftest
        return $?
        ;;
      --dir)
        dir="${2:-}"
        [ -n "$dir" ] || { echo "--dir needs a value" >&2; exit 2; }
        shift 2
        ;;
      *)
        echo "unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done
  scan "$dir" "$SHIMMED_WORKFLOW_FLOOR"
}

main "$@"
