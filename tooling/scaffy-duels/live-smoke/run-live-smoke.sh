#!/usr/bin/env bash
# run-live-smoke.sh — the ctx-s6 n=1 DIRECTIONAL SMOKE runner.
#
# Spawns exactly ONE `claude -p … --output-format json` envelope per arm, serial,
# same cwd, no session sharing — the implemented D66 recipe (run-cell.sh:241-246).
# Arm A = brief-default capabilities; arm B = --full-forced. Prompts are the
# frozen, pre-registered prompt-{A,B}.txt in this directory. Metering is done
# afterward by meter.py straight off the envelopes; JSONL summation is BANNED.
#
# NOT a statistical claim: n=1, pre-registered as directional smoke (charter
# decision 13). Requires an UN-SANDBOXED shell (bp needs network).
#
# Usage: run-live-smoke.sh <bp-binary> <results-dir> [cap-usd]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP_REAL="${1:?usage: run-live-smoke.sh <bp-binary> <results-dir> [cap-usd]}"
RESULTS="${2:?usage: run-live-smoke.sh <bp-binary> <results-dir> [cap-usd]}"
CAP="${3:-3.00}"
MODEL="claude-sonnet-5"          # pin — must match ctx-s5's count_tokens model id
WT="$(cd "$(dirname "$BP_REAL")" && pwd)"

BP_REAL="$(cd "$(dirname "$BP_REAL")" && pwd)/$(basename "$BP_REAL")"
mkdir -p "$RESULTS"

# Build the PATH shim so the agent's `bp` routes through bp-shim → real binary.
SHIMDIR="$(mktemp -d)"
cp "$HERE/bp-shim" "$SHIMDIR/bp"
chmod +x "$SHIMDIR/bp"
trap 'rm -rf "$SHIMDIR"' EXIT

run_arm() {
  local arm="$1" prompt_file="$2"
  local cell="live-smoke--${arm}--1"
  local env_out="$RESULTS/${cell}.agent.json"
  local shim_log="$RESULTS/${cell}.shimlog"
  : > "$shim_log"
  echo ">>> arm $arm — spawning claude (cap \$$CAP, model $MODEL)…" >&2
  local start end
  start="$(date +%s)"
  (
    cd "$WT"
    PATH="$SHIMDIR:$PATH" BP_SHIM_LOG="$shim_log" BP_REAL="$BP_REAL" \
      claude -p "$(cat "$prompt_file")" \
        --model "$MODEL" \
        --output-format json \
        --permission-mode bypassPermissions \
        --no-session-persistence \
        --max-budget-usd "$CAP"
  ) > "$env_out" || true
  end="$(date +%s)"
  echo ">>> arm $arm — done in $((end-start))s; envelope: $env_out" >&2

  # Envelope-independent guard: prove the agent actually routed through OUR binary.
  if ! grep -q 'capabilities' "$shim_log" 2>/dev/null; then
    echo "!!! arm $arm — WARNING: no 'capabilities' call in shim log; measurement may not have routed through the built binary" >&2
  fi
}

# Serial: A fully, then B. No session sharing (each --no-session-persistence).
run_arm A "$HERE/prompt-A.txt"
run_arm B "$HERE/prompt-B.txt"

echo ">>> both arms complete. Verify with: python3 tooling/scaffy-duels/meter.py verify $RESULTS/live-smoke--A--1.agent.json $RESULTS/live-smoke--B--1.agent.json" >&2
