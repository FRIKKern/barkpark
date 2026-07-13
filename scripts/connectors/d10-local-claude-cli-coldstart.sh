#!/usr/bin/env bash
# d10-local-claude-cli-coldstart.sh — the self-hosted / operator D10 baseline (Connectors epic, Wave 2 / P1).
#
# D5 [RATIFIED]: two execution profiles behind one Connector/Session layer. The
# SELF-HOSTED / operator profile is the `claude` CLI as a subprocess with full
# host access — no VM cold-start at all. This script measures THAT profile's
# first-response latency so the Cloud sandbox numbers (see the sibling
# d10-vercel-sandbox-coldstart.sh) have an apples-to-apples floor to sit beside.
#
# It decomposes the local `claude` first response into:
#   init  — process start -> the `system`/`init` event (CLI boot, config load,
#           MCP wiring). Measured off the stream, not guessed.
#   ttft  — init -> first model token (the first text delta / assistant chunk).
#           This is the real API round-trip (~5s per the charter's D10 context).
# first-response = init + ttft. On the self-hosted profile there is NO microVM
# boot, so this is the whole story; the Cloud profile adds the sandbox legs.
#
# CRITICAL — resolve the REAL claude binary, not the cmux wrapper shim. On the
# dev host `command -v claude` resolves FIRST to /Applications/cmux.app/.../claude,
# a bash wrapper that injects --session-id/--settings. Timing the shim would be a
# lie about the operator profile, so we skip it (path match + content sniff) and
# fall through to the real binary. Override with CLAUDE_BIN=/abs/path.
#
# Usage:
#   scripts/connectors/d10-local-claude-cli-coldstart.sh --check   # lint/plan + resolve the real binary; NO API call (this is what the gate runs)
#   scripts/connectors/d10-local-claude-cli-coldstart.sh           # LIVE: one `claude -p` turn, streamed + timed (spends real API budget, needs `claude auth login`)
#   CLAUDE_BIN=/abs/path/to/claude scripts/connectors/d10-local-claude-cli-coldstart.sh
#
# Charter: .claude/workflows/bp-connectors-charter.md (D5, D10, D21).
#
set -uo pipefail
export LC_ALL=C   # deterministic '.' decimal separator in awk/printf, any host locale

SCRIPT_NAME="d10-local-claude-cli-coldstart.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"

# Reference (charter D10 context): local CLI API TTFT ~5s; init is host-dependent
# so it is measured, not referenced.
REF_TTFT="5.00"

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — self-hosted/operator D10 baseline (local claude CLI first-response).

  --check    lint + resolve the real claude binary + print the plan; makes NO
             API call (this is what the CI gate runs).
  --help     this text.

With no flag it runs LIVE: one \`claude -p "say ok"\` turn with
--output-format stream-json --include-partial-messages, timing the process->init
and init->first-token legs. Spends real API budget (~1 short turn); needs
\`claude auth login\` (or ANTHROPIC_API_KEY) on the host.

Charter: $CHARTER (D5, D10, D21).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# ── High-resolution clock (portable). ──
now_s() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time;print("%.3f"%time.time())'
  elif command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
  elif date +%s.%N 2>/dev/null | grep -Eq '\.[0-9]'; then
    date +%s.%N
  else
    date +%s
  fi
}

elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.2f", d}'; }

# ── Is this path the cmux wrapper shim (which we must NOT time)? ──
is_cmux_shim() {
  local p="$1"
  case "$p" in
    *cmux*|*Cmux*|*CMUX*) return 0 ;;
  esac
  # Only content-sniff scripts (start with '#!'), never the real Mach-O/node binary.
  if head -c 2 "$p" 2>/dev/null | grep -q '#!'; then
    if head -c 4096 "$p" 2>/dev/null | grep -qi 'cmux'; then
      return 0
    fi
  fi
  return 1
}

# ── Resolve the REAL claude binary: explicit override → PATH (skip shim) → known locations. ──
resolve_claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then
    if [ -x "$CLAUDE_BIN" ] && ! is_cmux_shim "$CLAUDE_BIN"; then
      echo "$CLAUDE_BIN"; return 0
    fi
    echo "ERROR: CLAUDE_BIN=$CLAUDE_BIN is not an executable real claude (or it is the cmux shim)." >&2
    return 1
  fi
  local dir cand
  local oldifs="$IFS"
  IFS=:
  for dir in $PATH; do
    cand="$dir/claude"
    if [ -x "$cand" ] && ! is_cmux_shim "$cand"; then
      IFS="$oldifs"; echo "$cand"; return 0
    fi
  done
  IFS="$oldifs"
  for cand in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
    if [ -x "$cand" ] && ! is_cmux_shim "$cand"; then
      echo "$cand"; return 0
    fi
  done
  return 1
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN (--check: the real binary is resolved but NO API call is made)

A LIVE run would execute one streamed turn and wall-clock two legs off the stream:

  <real-claude> -p "say ok" \\
     --output-format stream-json --include-partial-messages --verbose

  init : process start  ->  first {"type":"system","subtype":"init",...} line
  ttft : that init line ->  first model token (content_block_delta text / assistant chunk)
  first-response = init + ttft         (reference API ttft ~ ${REF_TTFT}s, charter D10)

This is the D5 self-hosted/operator profile: a plain subprocess, full host access,
NO microVM boot. Contrast the Cloud profile in d10-vercel-sandbox-coldstart.sh.
EOF
}

# ── LIVE measurement. ──
run_live() {
  local bin="$1"
  local tmp t0 line ts
  tmp="$(mktemp "${TMPDIR:-/tmp}/d10-local-claude.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  echo "==> streaming one turn (this spends API budget) ..."
  t0=$(now_s)
  # Timestamp every stream line as it arrives.
  "$bin" -p "say ok" --output-format stream-json --include-partial-messages --verbose 2>/dev/null \
    | while IFS= read -r line; do
        ts=$(now_s)
        printf '%s\t%s\n' "$ts" "$line" >> "$tmp"
      done

  if [ ! -s "$tmp" ]; then
    echo "ERROR: no stream output. Is the host logged in ('claude auth login' / ANTHROPIC_API_KEY)?" >&2
    exit 1
  fi

  # init: first system/init line.
  local init_ts="" tok_ts="" typ sub is_tok
  while IFS=$'\t' read -r ts line; do
    typ=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    if [ -z "$init_ts" ] && [ "$typ" = "system" ]; then
      sub=$(printf '%s' "$line" | jq -r '.subtype // empty' 2>/dev/null)
      [ "$sub" = "init" ] && init_ts="$ts"
    fi
    if [ -z "$tok_ts" ]; then
      # first model token: a partial-message text delta, or an assistant chunk.
      is_tok=$(printf '%s' "$line" | jq -r '
        if (.type=="stream_event" and (.event.type=="content_block_delta")) then "y"
        elif (.type=="assistant") then "y"
        else empty end' 2>/dev/null)
      [ "$is_tok" = "y" ] && tok_ts="$ts"
    fi
  done < "$tmp"

  echo ""
  printf '  %-24s %12s\n' "leg" "seconds"
  printf '  %s\n' "-------------------------------------"
  if [ -n "$init_ts" ]; then
    printf '  %-24s %12s\n' "process -> init" "$(elapsed "$t0" "$init_ts")"
  else
    printf '  %-24s %12s\n' "process -> init" "n/a (no system/init line)"
  fi
  if [ -n "$init_ts" ] && [ -n "$tok_ts" ]; then
    printf '  %-24s %12s\n' "init -> first token" "$(elapsed "$init_ts" "$tok_ts")"
  elif [ -n "$tok_ts" ]; then
    printf '  %-24s %12s\n' "process -> first token" "$(elapsed "$t0" "$tok_ts")"
  else
    printf '  %-24s %12s\n' "init -> first token" "n/a (no token line matched)"
  fi
  if [ -n "$tok_ts" ]; then
    printf '  %s\n' "-------------------------------------"
    printf '  %-24s %12s\n' "=> first-response" "$(elapsed "$t0" "$tok_ts")"
  fi
  echo ""
  echo "  (reference API ttft ~${REF_TTFT}s, charter D10. init is host-dependent — measured above.)"
}

main() {
  echo "== D10 local claude CLI cold-start baseline (self-hosted/operator, D5) =="
  echo "== charter: $CHARTER =="

  local bin
  if ! bin="$(resolve_claude_bin)"; then
    echo "ERROR: could not resolve a real (non-shim) claude binary." >&2
    echo "       Set CLAUDE_BIN=/abs/path/to/claude and retry." >&2
    exit 1
  fi
  echo "==> real claude binary: $bin"
  if command -v "$bin" >/dev/null 2>&1; then
    "$bin" --version 2>/dev/null | head -1 | sed 's/^/    version: /' || true
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: real binary resolved, plan linted, NO API call made."
    return 0
  fi

  run_live "$bin"
  echo ""
  echo "== done =="
}

main
