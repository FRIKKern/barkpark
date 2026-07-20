#!/usr/bin/env bash
# never-cancel-main-check.sh — the ratchet for honest-gates D12: `cancelled` is a NON-PASS.
#
# THE DEFECT THIS FORBIDS. A workflow that runs on push-to-main and sets
# `cancel-in-progress: true` cancels its own main runs whenever pushes land
# faster than the suite completes. On 2026-06-10 that starved the Elixir suite
# dark: 19 consecutive main runs cancelled, zero completions all day. Commit
# a547ff75a fixed it with `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}`
# — but at SAMPLE scope. Five workflows got the guard; cloud.yml and
# doc-gates.yml were missed and kept a bare `true` for 40 days. That regrowth is
# what this gate exists to make impossible.
#
# WHY IT IS NOT COSMETIC. A cancelled check is not a pass. Under branch
# protection a cancelled required check is an unexplainable merge block, so a
# regrown bare `true` turns an otherwise-honest-green check into a lying gate
# the moment it is promoted.
#
# THE PREDICATE — exactly one reason to red. FAIL iff a workflow BOTH
#   (a) triggers on `push:` with `main` among its branches, AND
#   (b) sets `concurrency.cancel-in-progress` to the literal boolean `true`.
# Both halves are load-bearing. A pull_request-only workflow can carry a bare
# `true` honestly: `github.ref` is never `refs/heads/main` there, so the guard
# expression would evaluate to `true` anyway — identical behaviour. Flagging
# those would red for a reason other than the thing measured (charter: a gate
# must red for exactly ONE reason). They are reported as NOTE, never as failure,
# so the latent shape stays visible without manufacturing a false red.
#
# `cancel-in-progress: false` is always fine — it is strictly never-cancel, the
# deliberate choice in deploy/release workflows.
#
# --selftest proves this gate is ABLE TO FAIL (charter D2: distrust vacuous
# green). It runs the predicate over synthetic fixtures in a temp dir and
# asserts red on the hazardous shape and green on each safe one. It plants
# nothing in the tree.
#
# Usage: scripts/never-cancel-main-check.sh [--selftest]
set -euo pipefail
cd "$(dirname "$0")/.."

# scan <dir> — prints "FAIL <file>" / "NOTE <file>" lines, one per finding.
# Exits 2 (never 0/1) if the YAML harness itself is unavailable, so a broken
# harness can never be read as a verdict on the workflows (charter D3: exit code
# alone cannot discriminate a dep error from a real verdict — the text does).
scan() {
  python3 - "$1" <<'PY'
import sys, glob, os

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflows")
    sys.exit(2)

root = sys.argv[1]
for path in sorted(glob.glob(os.path.join(root, "*.yml")) + glob.glob(os.path.join(root, "*.yaml"))):
    try:
        doc = yaml.safe_load(open(path))
    except Exception as exc:
        print(f"HARNESS-UNAVAILABLE: {path} did not parse as YAML: {exc}")
        sys.exit(2)
    if not isinstance(doc, dict):
        continue

    # YAML 1.1 resolves a bare `on:` key to boolean True, so accept both forms.
    on = doc.get("on", doc.get(True))
    conc = doc.get("concurrency")
    if not isinstance(conc, dict):
        continue

    # Only a LITERAL boolean true is the hazard. The guard expression parses as
    # the string "${{ ... }}", and `false` is strictly never-cancel.
    if conc.get("cancel-in-progress") is not True:
        continue

    push = on.get("push") if isinstance(on, dict) else None
    branches = push.get("branches") if isinstance(push, dict) else None
    on_main = isinstance(branches, list) and "main" in branches

    name = os.path.basename(path)
    if on_main:
        print(f"FAIL {name}: runs on push-to-main with a bare `cancel-in-progress: true`")
    else:
        print(f"NOTE {name}: bare `cancel-in-progress: true`, but no push-to-main trigger (harmless today)")
PY
}

SELFTEST_TMP=""
cleanup_selftest() { [ -n "$SELFTEST_TMP" ] && rm -rf "$SELFTEST_TMP"; return 0; }
trap cleanup_selftest EXIT

selftest() {
  local tmp
  SELFTEST_TMP="$(mktemp -d)"
  tmp="$SELFTEST_TMP"

  # HAZARDOUS — push-to-main + bare true. Must red.
  cat >"$tmp/hazard.yml" <<'EOF'
name: hazard
on:
  push:
    branches: [main]
concurrency:
  group: hazard-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — push-to-main + the ref guard.
  cat >"$tmp/guarded.yml" <<'EOF'
name: guarded
on:
  push:
    branches: [main]
concurrency:
  group: guarded-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — pull_request only, bare true is behaviourally identical to the guard.
  cat >"$tmp/pronly.yml" <<'EOF'
name: pronly
on:
  pull_request:
    paths: ["**/*.ex"]
concurrency:
  group: pronly-${{ github.ref }}
  cancel-in-progress: true
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  # SAFE — push-to-main + explicit never-cancel.
  cat >"$tmp/nevercancel.yml" <<'EOF'
name: nevercancel
on:
  push:
    branches: [main]
concurrency:
  group: nevercancel-${{ github.ref }}
  cancel-in-progress: false
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF

  local out
  out="$(scan "$tmp")"

  local failed=0
  if ! grep -q '^FAIL hazard.yml' <<<"$out"; then
    echo "SELFTEST FAILED: the gate did NOT red on push-to-main + bare true" >&2
    failed=1
  fi
  for safe in guarded.yml nevercancel.yml; do
    if grep -q "^FAIL $safe" <<<"$out"; then
      echo "SELFTEST FAILED: the gate red on the safe shape $safe" >&2
      failed=1
    fi
  done
  if grep -q '^FAIL pronly.yml' <<<"$out"; then
    echo "SELFTEST FAILED: the gate red on a pull_request-only bare true (behaviourally identical to the guard)" >&2
    failed=1
  fi
  if ! grep -q '^NOTE pronly.yml' <<<"$out"; then
    echo "SELFTEST FAILED: the gate did not NOTE a pull_request-only bare true" >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo "--- selftest scan output ---" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "never-cancel-main selftest OK — reds on push-to-main + bare true, green on the guard, on never-cancel, and on pull_request-only."
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

RESULT="$(scan .github/workflows)"

if grep -q '^HARNESS-UNAVAILABLE' <<<"$RESULT"; then
  echo "$RESULT" >&2
  exit 2
fi

grep '^NOTE ' <<<"$RESULT" || true

if grep -q '^FAIL ' <<<"$RESULT"; then
  echo "" >&2
  # shellcheck disable=SC2016  # the backticks are literal prose, not substitution
  echo 'never-cancel-main gate FAILED — `cancelled` is a NON-PASS (honest-gates D12).' >&2
  grep '^FAIL ' <<<"$RESULT" >&2
  echo "" >&2
  echo "Fix: in that workflow's concurrency block, replace" >&2
  echo "    cancel-in-progress: true" >&2
  echo "with the ref guard (mirroring .github/workflows/elixir.yml:37-40)" >&2
  echo "    # Cancel superseded PR runs, but NEVER cancel main: fast push cadence" >&2
  echo "    # otherwise starves the suite (2026-06-10: 19 consecutive main runs" >&2
  echo "    # cancelled, zero completions all day). Queued main runs collapse to one." >&2
  echo "    cancel-in-progress: \${{ github.ref != 'refs/heads/main' }}" >&2
  echo "" >&2
  echo "Deliberate never-cancel (deploy/release) may use \`cancel-in-progress: false\`." >&2
  exit 1
fi

echo "never-cancel-main gate OK — no push-to-main workflow cancels its own in-progress runs."
