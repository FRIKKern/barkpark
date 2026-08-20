#!/usr/bin/env bash
# w11-isolated-turn-proof.sh — the Connectors Wave-11 isolated-turn proof (P1 crux).
#
# Drives ONE real Cloud turn through the `cloud-sandbox-runner.mjs` shim end to
# end — a real Vercel Sandbox, a real env-injection of a BOGUS ANTHROPIC_API_KEY,
# one isolated `claude` turn — and asserts the honest wire-level result: the
# terminal `type:result` frame is `is_error:true` / `api_error_status:401`
# ("Invalid API key"), field-matched to the committed fixture
# `api/test/fixtures/claude_chat/unauthed_stream.ndjson`. Then it proves
# `vercel sandbox ls` shows ZERO orphans from this run.
#
# This is the honest half of charter D113(c): it proves ISOLATION + SPAWN +
# ENV-INJECTION + the STREAM wire WITHOUT a live model response. A LIVE model turn
# (a valid ANTHROPIC key) and a real per-workspace Vercel deploy are NAMED human
# gates (`connectors-hg-live-isolated-cloud-turn`) — this script NEVER fabricates
# a model answer. A bogus key producing `Invalid API key` from the sandboxed
# claude IS the proof the injected key reached the CLI exactly as the host does.
#
# See .claude/workflows/bp-connectors-charter.md (D107–D115) and the wave paper
# connectors-wave-11-2026-07-16. Sibling: d10-vercel-sandbox-coldstart.sh (idioms
# reused: --check provisions nothing, EXIT-trap teardown, --tag, --timeout).
#
# Usage:
#   scripts/connectors/w11-isolated-turn-proof.sh --check   # lint + plan only, provisions NOTHING (what CI runs)
#   scripts/connectors/w11-isolated-turn-proof.sh           # LIVE: real sandbox + bogus-key turn + teardown (needs `vercel` authed)
#
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w11-isolated-turn-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"
FIXTURE="$HERE/../../api/test/fixtures/claude_chat/unauthed_stream.ndjson"

# The bogus key is DELIBERATELY invalid — it exercises the env-injection seam and
# forces the honest 401 (never a real model answer). Overridable, but the default
# must never be a real key.
BOGUS_KEY="${W11_BOGUS_ANTHROPIC_KEY:-sk-ant-bogus-w11-isolated-turn}"
SCOPE="${CLOUD_SANDBOX_SCOPE:-guerrilla}"
TIMEOUT="${CLOUD_SANDBOX_TIMEOUT:-10m}"
WORKSPACE="${W11_WORKSPACE:-w11-proof-ws}"
TAG_PURPOSE="cloud-turn"

# The non-volatile result-frame fields this proof asserts (byte-matched to the
# committed fixture — volatile fields like session_id/duration are NOT asserted).
EXPECT_IS_ERROR="true"
EXPECT_STATUS="401"
EXPECT_RESULT_SUBSTR="Invalid API key"

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-11 isolated-turn proof (bogus-key 401).

  --check    lint the shim + fixture, print the plan; provisions NO sandbox and
             calls NO API (this is what the CI gate runs).
  --help     this text.

With no flag it runs LIVE: needs the \`vercel\` CLI authenticated (scope
'$SCOPE'), creates ONE real sandbox, injects a BOGUS ANTHROPIC_API_KEY, drives
one isolated turn through $SHIM, asserts the terminal result frame is
is_error:true / api_error_status:$EXPECT_STATUS ("$EXPECT_RESULT_SUBSTR"), proves
zero orphan sandboxes, and tears everything down on exit.

The LIVE MODEL turn (a valid key) is the human gate
connectors-hg-live-isolated-cloud-turn — this script never fabricates one.

Charter: $CHARTER (D107-D115).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# ── Resource tracking + teardown (fires on any exit, incl. error / Ctrl-C). ──
SANDBOXES=()

cleanup() {
  local rc=$?
  set +e
  if [ "${#SANDBOXES[@]}" -gt 0 ]; then
    echo "==> teardown: removing ${#SANDBOXES[@]} sandbox(es): ${SANDBOXES[*]}" >&2
    vercel sandbox remove "${SANDBOXES[@]}" --scope "$SCOPE" >/dev/null 2>&1 \
      || echo "    warn: 'vercel sandbox remove' returned nonzero (may already be gone)" >&2
  fi
  exit $rc
}
trap cleanup EXIT

lint() {
  echo "==> lint: node --check $SHIM"
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' not found on PATH." >&2; exit 1
  fi
  node --check "$SHIM" || { echo "ERROR: shim failed node --check" >&2; exit 1; }

  echo "==> lint: fixture present + carries the asserted 401 result frame"
  if [ ! -f "$FIXTURE" ]; then
    echo "ERROR: fixture missing: $FIXTURE" >&2; exit 1
  fi
  # The committed wire truth the LIVE assertion is diffed against.
  if ! grep -q '"api_error_status": *401' "$FIXTURE"; then
    echo "ERROR: fixture lost its api_error_status:401 result frame — the proof's ground truth drifted" >&2
    exit 1
  fi
  if ! grep -q "$EXPECT_RESULT_SUBSTR" "$FIXTURE"; then
    echo "ERROR: fixture lost its '$EXPECT_RESULT_SUBSTR' result — ground truth drifted" >&2
    exit 1
  fi
  echo "    OK: shim lints, fixture ground-truth intact."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN (--check: nothing is provisioned, no API is called)

A LIVE run would, in order:

  1. Pipe ONE stream-json user frame into the shim:
       {"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}

  2. ANTHROPIC_API_KEY=<BOGUS> \\
     CLOUD_SANDBOX_SCOPE=$SCOPE CLOUD_SANDBOX_TIMEOUT=$TIMEOUT \\
       node $SHIM --workspace $WORKSPACE -- \\
         --input-format stream-json --output-format stream-json \\
         --include-partial-messages --verbose --permission-mode plan

     The shim: vercel sandbox create (--scope $SCOPE --timeout $TIMEOUT
     --tag purpose=$TAG_PURPOSE --tag workspace=$WORKSPACE --allowed-domain
     api.anthropic.com — an allowlist IS deny-all-except; CLI 54.x refuses to
     combine it with --network-policy), fallback npm i -g
     @anthropic-ai/claude-code, base64-inject the frame, one-shot claude with an
     isolated HOME + clean cwd, stream stdout NDJSON verbatim, then
     vercel sandbox remove on stdin-EOF.

  3. ASSERT the terminal type:result frame:
       is_error == $EXPECT_IS_ERROR
       api_error_status == $EXPECT_STATUS
       result contains "$EXPECT_RESULT_SUBSTR"
     (field-matched to $FIXTURE — the committed wire truth.)

  4. ASSERT zero orphans: vercel sandbox ls --scope $SCOPE shows no sandbox
     tagged purpose=$TAG_PURPOSE workspace=$WORKSPACE left behind.

Teardown (ALWAYS, via EXIT trap): vercel sandbox remove <all-created-vms>.

HONESTY: the bogus key forces the 401 — NO model answer is produced or faked.
The LIVE model turn is the human gate connectors-hg-live-isolated-cloud-turn.
EOF
}

require_vercel_auth() {
  if ! command -v vercel >/dev/null 2>&1; then
    echo "ERROR: 'vercel' CLI not found on PATH. Install it and 'vercel login' first." >&2
    exit 1
  fi
  if ! vercel whoami >/dev/null 2>&1; then
    echo "ERROR: 'vercel' is not authenticated. Run 'vercel login'." >&2
    exit 1
  fi
  echo "==> vercel authenticated as: $(vercel whoami 2>/dev/null | tail -1)"
}

# The shim self-reports its created sandbox id on stderr ("sandbox created: <id>")
# so the harness can register it for teardown + orphan assertion even if the turn
# aborts mid-stream.
live_turn() {
  local stdout_f stderr_f
  stdout_f="$(mktemp)"; stderr_f="$(mktemp)"

  local user_frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'

  echo "==> driving one isolated bogus-key turn through the shim ..."
  printf '%s\n' "$user_frame" | \
    ANTHROPIC_API_KEY="$BOGUS_KEY" \
    CLOUD_SANDBOX_SCOPE="$SCOPE" \
    CLOUD_SANDBOX_TIMEOUT="$TIMEOUT" \
    node "$SHIM" --workspace "$WORKSPACE" -- \
      --input-format stream-json --output-format stream-json \
      --include-partial-messages --verbose --permission-mode plan \
      >"$stdout_f" 2>"$stderr_f"
  local rc=$?

  # Register any sandbox the shim reported for teardown (belt-and-suspenders — the
  # shim already removes on EOF, but a crash mid-turn must not orphan it).
  local sb
  sb="$(sed -n 's/.*sandbox created: \([^ ]*\).*/\1/p' "$stderr_f" | tail -1)"
  [ -n "$sb" ] && SANDBOXES+=("$sb")

  # NOTE: `vercel sandbox exec` does not propagate the in-VM exit code, so the
  # shim exit is typically 0 even though claude exited 1 — the terminal result
  # frame (asserted below), not this code, is the auth-outcome source of truth.
  echo "    shim exit=$rc  (result-frame is_error is the source of truth, not exit code)"
  echo "    --- shim stderr (diagnostics) ---" >&2
  sed 's/^/    /' "$stderr_f" >&2

  # The terminal result frame (last NDJSON line of type result).
  local result_line
  result_line="$(grep '"type":"result"' "$stdout_f" | tail -1)"
  if [ -z "$result_line" ]; then
    echo "FAIL: no type:result frame on stdout — the isolated turn produced no terminal frame" >&2
    echo "    --- shim stdout ---" >&2; sed 's/^/    /' "$stdout_f" >&2
    rm -f "$stdout_f" "$stderr_f"
    exit 1
  fi

  echo "==> asserting terminal result frame (field-matched to the committed fixture) ..."
  local ok=1
  echo "$result_line" | grep -q '"is_error":[[:space:]]*true' || { echo "FAIL: is_error != true" >&2; ok=0; }
  echo "$result_line" | grep -q "\"api_error_status\":[[:space:]]*$EXPECT_STATUS" || { echo "FAIL: api_error_status != $EXPECT_STATUS" >&2; ok=0; }
  echo "$result_line" | grep -q "$EXPECT_RESULT_SUBSTR" || { echo "FAIL: result missing '$EXPECT_RESULT_SUBSTR'" >&2; ok=0; }

  rm -f "$stdout_f" "$stderr_f"
  if [ "$ok" -ne 1 ]; then
    echo "    terminal frame was: $result_line" >&2
    exit 1
  fi
  echo "    PASS: is_error:true / api_error_status:$EXPECT_STATUS / '$EXPECT_RESULT_SUBSTR'"
}

assert_no_orphans() {
  echo "==> asserting zero orphan sandboxes (vercel sandbox ls) ..."
  # The shim removes the sandbox at turn-complete; `vercel sandbox ls` is
  # eventually-consistent (a just-removed sandbox lingers as 'stopping' for a few
  # seconds), so poll for it to disappear rather than demanding an instant absence.
  if [ -z "${SANDBOXES:-}" ]; then
    echo "    PASS: shim reported no sandbox to leak."
    return 0
  fi
  local tries=20 leaked
  while [ "$tries" -gt 0 ]; do
    leaked=""
    local ls_out
    ls_out="$(vercel sandbox ls --scope "$SCOPE" 2>/dev/null || true)"
    for sb in "${SANDBOXES[@]}"; do
      # A removed sandbox may show transiently as 'stopping'/'stopped'; only a
      # still-'running' row is a real orphan leak.
      if printf '%s' "$ls_out" | grep -E "\<$sb\>" | grep -qi "running"; then
        leaked="$sb"
      fi
    done
    [ -z "$leaked" ] && { echo "    PASS: no running orphan sandboxes from this run."; return 0; }
    tries=$((tries - 1))
    sleep 3
  done
  echo "FAIL: sandbox $leaked still 'running' after teardown — orphan leak" >&2
  exit 1
}

main() {
  echo "== Connectors Wave-11 isolated-turn proof =="
  echo "== charter: $CHARTER (D107-D115) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim + fixture linted, plan printed, nothing provisioned."
    return 0
  fi

  require_vercel_auth
  live_turn
  assert_no_orphans
  echo ""
  echo "== PROVEN: isolation + spawn + env-injection + stream wire (bogus-key 401). =="
  echo "== The LIVE model turn remains the human gate connectors-hg-live-isolated-cloud-turn. =="
}

main
