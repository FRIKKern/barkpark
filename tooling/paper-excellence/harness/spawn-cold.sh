#!/usr/bin/env bash
# spawn-cold.sh — launch a COLD agent: no warm context, no host settings, no
# repo, no keychain OAuth. Just the published guide + the slice-built bp binary.
#
#   ANTHROPIC_API_KEY=sk-... \
#     bash tooling/paper-excellence/harness/spawn-cold.sh <prompt-file> [transcript-out]
#
# "Cold" is the whole point of this epic: a WARM agent acting cold is a vacuous
# green — it has already read the codebase, the wave papers, the friction log.
# The coldness protocol is mechanical, not a promise:
#
#   * env -i wipes the inherited environment — none of this session's variables
#     survive into the child.
#   * a SCRATCH HOME + XDG_CONFIG_HOME mean no ~/.claude, no warm project state,
#     and no keychain OAuth token to fall back on. Under --bare with a fresh
#     HOME the keychain path is proven dead, so ANTHROPIC_API_KEY is the ONLY
#     credential — and it is REQUIRED (see the loud fail below).
#   * --setting-sources '' loads ZERO settings files (no user, no project, no
#     enterprise settings leak in).
#   * cwd is OUTSIDE the repo, so the agent cannot read the codebase, the wave
#     paper, or this harness by walking the tree.
#   * --model is pinned EXPLICITLY: bare defaults to the high-effort opus-5[1m];
#     the cold run is judged at opus@medium, so the operator pins that id.
#
# The bp the agent uses is the slice-built binary (build-bp.sh) — put its dir on
# PATH via BP_BIN_DIR so the run consumes THIS checkout's CLI, not a stale one.
#
# The scratch bp config carries the minimal 5 fields the CLI needs to reach the
# store: server, token, workspace, project, dataset — sourced from this host's
# config (or BARKPARK_* env). Nothing else: no cloud creds, no known_servers.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROMPT_FILE="${1:?usage: spawn-cold.sh <prompt-file> [transcript-out]}"
[ -f "$PROMPT_FILE" ] || { echo "spawn-cold: no prompt file at $PROMPT_FILE" >&2; exit 2; }
TRANSCRIPT="${2:-${COLD_TRANSCRIPT:-${TMPDIR:-/tmp}/pe-cold/transcript.jsonl}}"

# --- The credential gate: fail LOUD, naming the human packet. ---------------
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  cat >&2 <<'EOF'
spawn-cold: FAIL — ANTHROPIC_API_KEY is not set.

  The cold agent has a scratch HOME and runs under --bare, so keychain OAuth is
  dead by design — an API key is the ONLY credential. This is the human gate
  pe-w7-hg-anthropic-key: an operator must export a real key before the cold
  authoring run can execute. (A deliberately-invalid key still launches the
  agent and auth-fails — that is the no-key probe, harness/probe-no-key.jsonl,
  which proves the stream parses without spending tokens.)
EOF
  exit 3
fi

CLAUDE_BIN="${CLAUDE_BIN:-/Users/pelle/.local/bin/claude}"
[ -x "$CLAUDE_BIN" ] || { echo "spawn-cold: no claude binary at $CLAUDE_BIN (set CLAUDE_BIN)" >&2; exit 2; }
COLD_MODEL="${COLD_MODEL:-opus}"   # explicit opus@medium pin; NOT bare's opus-5[1m]

# --- The scratch home + bp config (5 fields only). --------------------------
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pe-cold-XXXXXX")"
SCRATCH_HOME="$SCRATCH/home"
XDG="$SCRATCH/home/.config"
WORKDIR="$SCRATCH/work"        # cwd OUTSIDE the repo
mkdir -p "$SCRATCH_HOME" "$XDG/barkpark" "$WORKDIR"
mkdir -p "$(dirname "$TRANSCRIPT")"

# Source the 5 fields from this host's config unless overridden by env.
SRC_CONFIG="${BARKPARK_CONFIG:-$HOME/.config/barkpark/config.json}"
read_cfg() {  # read_cfg <key> <env-override>
  if [ -n "${2:-}" ]; then printf '%s' "$2"; return; fi
  [ -f "$SRC_CONFIG" ] || { echo "spawn-cold: no bp config at $SRC_CONFIG and no env override for $1" >&2; exit 2; }
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$SRC_CONFIG" "$1"
}
CFG_SERVER="$(read_cfg server "${BARKPARK_SERVER:-}")"
CFG_TOKEN="$(read_cfg token "${BARKPARK_TOKEN:-}")"
CFG_WS="$(read_cfg workspace "${BARKPARK_WORKSPACE:-}")"
CFG_PROJECT="$(read_cfg project "${BARKPARK_PROJECT:-}")"
CFG_DATASET="$(read_cfg dataset "${BARKPARK_DATASET:-}")"

python3 - "$XDG/barkpark/config.json" \
  "$CFG_SERVER" "$CFG_TOKEN" "$CFG_WS" "$CFG_PROJECT" "$CFG_DATASET" <<'PY'
import json, sys
path, server, token, ws, project, dataset = sys.argv[1:7]
json.dump({"server": server, "token": token, "workspace": ws,
           "project": project, "dataset": dataset},
          open(path, "w"), indent=2)
PY

# --- PATH: standard bins + the slice-built bp + claude's own dir. ------------
BP_BIN_DIR="${BP_BIN_DIR:-$HARNESS_DIR/.bin}"
COLD_PATH="$BP_BIN_DIR:$(dirname "$CLAUDE_BIN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROMPT="$(cat "$PROMPT_FILE")"

echo "spawn-cold: HOME=$SCRATCH_HOME  cwd=$WORKDIR  model=$COLD_MODEL" >&2
echo "spawn-cold: bp=$BP_BIN_DIR/bp  transcript=$TRANSCRIPT" >&2

set +e
( cd "$WORKDIR" && env -i \
    HOME="$SCRATCH_HOME" \
    XDG_CONFIG_HOME="$XDG" \
    PATH="$COLD_PATH" \
    TERM=dumb \
    ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    "$CLAUDE_BIN" --bare --setting-sources '' --model "$COLD_MODEL" \
      -p "$PROMPT" --output-format stream-json --verbose ) > "$TRANSCRIPT" 2>"$TRANSCRIPT.err"
RC=$?
set -e

echo "spawn-cold: claude exited $RC — transcript at $TRANSCRIPT ($(wc -l <"$TRANSCRIPT" | tr -d ' ') lines)" >&2
exit "$RC"
