#!/usr/bin/env bash
# onramp-live-client-smoke.sh — the committed LIVE-CLIENT proof for the agent
# onramps epic (wave 4, task ao-w4-live-client-smoke, charter D27). Every onramp
# `--write` proof before this one was golden-file or doc-pin — a *real* MCP
# client had never been shown to read the config `bp onramp claude-code --write`
# emits. This harness retires that asterisk: the `claude` CLI (2.1.207, a real
# JSON MCP client) parses the exact `.mcp.json` the emitter writes, reports it
# byte-correct, and binds detection to that file (vanishes when removed, returns
# when restored). It then drives `bp mcp serve` through a direct JSON-RPC
# handshake to prove the server the config points at actually answers.
#
# WHY a bash harness (not a Go test): only a real, separately-shipped MCP client
# proves the config is client-legible — a unit test asserts the bytes WE wrote,
# never that a foreign parser accepts them. The `claude` binary is that foreign
# parser. This is strictly beyond the golden/doc-pin coverage in
# onramp_cmd_test.go + onramp_write_test.go.
#
# MANUAL RUN ONLY — NEVER wire into CI. The `claude` CLI is not on GitHub
# runners, and the handshake step dials the live Barkpark the local config
# points at. Same stance as scripts/cmux-smoke.sh / scripts/claude-chat-e2e.sh.
# It is self-contained: everything happens in a THROWAWAY tmp dir so it never
# touches the operator's real project `.mcp.json` or MCP approvals; claude's own
# state is redirected to a scratch CLAUDE_CONFIG_DIR so the operator's real
# ~/.claude.json is never mutated (proven byte-for-byte at the end); and it reads
# (never writes) the local token.
#
#   Invocation (from anywhere; it cd's to the repo root itself):
#     ./scripts/onramp-live-client-smoke.sh
#   Requires: `bp` on PATH (or BP=/path/to/bp), the `claude` CLI on PATH, and
#   python3. The JSON-RPC handshake step ALSO needs a manifest-capable token —
#   BARKPARK_API_TOKEN in the env, or the active token in
#   ~/.config/barkpark/config.json. Absent a token, the DETECTION half still
#   runs in full and the handshake is honestly recorded as skipped-no-token.
#
#   The RESIDUAL claude behaviour — its interactive trust-approval and connecting
#   the server so its OWN session lists the 8 tools (no non-interactive approve
#   verb exists) — is NOT covered here; it is the honest human gate filed as
#   ao-backlog-claude-code-connect-eyeball. This harness proves the
#   DETECTION/LISTING + server-answers halves only. Do not read more into a pass.
#
# GATE (ao-w4-live-client-smoke): `bash scripts/onramp-live-client-smoke.sh` must
# end in a PASS summary with 0 failures; paste the output as task evidence.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- resolve bp + claude + python3, or REFUSE (no silent skip: this harness's
#     whole point is a LIVE client, so a missing client is a hard refusal) ------
BP_BIN="${BP:-bp}"
if ! command -v "$BP_BIN" >/dev/null 2>&1; then
  echo "REFUSE: bp binary not found (looked for '${BP_BIN}'; set BP=/path/to/bp)." >&2
  echo "        This harness proves a LIVE client reads bp's emitted config — it needs bp." >&2
  exit 1
fi
BP="$(command -v "$BP_BIN")"
if ! command -v claude >/dev/null 2>&1; then
  echo "REFUSE: the 'claude' CLI is not on PATH." >&2
  echo "        This harness proves a REAL JSON MCP client detects the emitted .mcp.json;" >&2
  echo "        without the claude CLI there is nothing live to prove. Not a skip — a refusal." >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "REFUSE: 'python3' not found." >&2; exit 1; }

# --- pass/fail counters (cmux-smoke.sh / media-smoke.sh style) ------------------
pass=0
fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }
die() { echo "FATAL: $1" >&2; exit 1; }

# strip ANSI SGR colour codes claude emits, so substring asserts are stable
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

echo "=== onramp live-client smoke — claude $(claude --version 2>/dev/null | awk '{print $1}') · bp $BP ==="

# =================================================================================
# Isolation: claude persists state (per-project MCP approvals, startup counters)
# in ~/.claude.json, and even a read-only `claude mcp get` touches it. Redirect
# claude to a THROWAWAY CLAUDE_CONFIG_DIR so the operator's real ~/.claude.json is
# never mutated — barkpark is detected from the PROJECT-scoped .mcp.json in cwd,
# which is independent of the config dir, so detection is unaffected. We snapshot
# the real file's shasum up front and HARD-ASSERT it is unchanged at the end.
# =================================================================================
sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "ABSENT"; }
REAL_CLAUDE_STATE="$HOME/.claude.json"
BEFORE_CLAUDE_STATE="$(sha_of "$REAL_CLAUDE_STATE")"
CLAUDE_HOME="$(mktemp -d)"
export CLAUDE_CONFIG_DIR="$CLAUDE_HOME"

# =================================================================================
# The expected stanza is derived from the emitter's OWN print mode (`bp onramp
# claude-code` with no --write) — never hardcoded — so this proof tracks the doc
# ⇄ stanza ⇄ golden byte-parity law (wave-1 decision) automatically. Print mode's
# files[].content IS the exact bytes --write lays down (modulo the trailing
# newline atomicWriteFile appends). We pass no --server/--token: the active
# config default is what a real user gets, and both print + write see it.
# =================================================================================
PRINT_JSON="$("$BP" onramp claude-code -o json 2>/dev/null)" \
  || die "bp onramp claude-code (print mode) failed."

# Pull the .mcp.json stanza content + the expected server-entry fields straight
# out of the print JSON. One python pass emits shell-eval'able assignments.
eval "$(printf '%s' "$PRINT_JSON" | python3 -c '
import json, sys, shlex
d = json.load(sys.stdin)
f = next((x for x in d.get("files", []) if x.get("path") == ".mcp.json"), None)
if f is None:
    sys.exit("no .mcp.json file in print output")
content = f["content"]
srv = json.loads(content)["mcpServers"]["barkpark"]
cmd  = srv["command"]
args = " ".join(srv["args"])
url  = srv["env"]["BARKPARK_API_URL"]
tok  = srv["env"]["BARKPARK_API_TOKEN"]
typ  = srv.get("type", "")
def out(k, v): print(f"{k}={shlex.quote(v)}")
out("EXP_CONTENT", content)
out("EXP_CMD", cmd)
out("EXP_ARGS", args)
out("EXP_URL", url)
out("EXP_TOK", tok)
out("EXP_TYPE", typ)
')" || die "could not parse the print-mode stanza."

# =================================================================================
# Throwaway project dir. cd in so claude reads THIS .mcp.json as project scope and
# nothing in the operator's real tree is touched. Trap cleans it up on any exit.
# =================================================================================
SCRATCH="$(mktemp -d)"
cleanup() { cd / 2>/dev/null || true; rm -rf "$SCRATCH" "$CLAUDE_HOME"; }
trap cleanup EXIT
cd "$SCRATCH"

# --- (a) --write emits .mcp.json, action=created, bytes == print stanza + \n -----
echo "--- (a) bp onramp claude-code --write ---"
WRITE_JSON="$("$BP" onramp claude-code --write -o json 2>/dev/null)" \
  || die "bp onramp claude-code --write failed."
ACTION="$(printf '%s' "$WRITE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
a = next((x for x in d.get("actions", []) if x.get("path") == ".mcp.json"), {})
print(a.get("action", ""))
')"
[ "$ACTION" = "created" ] && ok "write reports action=created for .mcp.json" \
  || bad "write action was '$ACTION' (want created)"
[ -f "$SCRATCH/.mcp.json" ] || die ".mcp.json was not written."

# print stanza + the single trailing newline atomicWriteFile appends == the file
printf '%s\n' "$EXP_CONTENT" > "$SCRATCH/.expected-stanza"
if cmp -s "$SCRATCH/.mcp.json" "$SCRATCH/.expected-stanza"; then
  ok "written .mcp.json is byte-identical to the print-mode stanza (+ trailing \\n)"
else
  bad "written .mcp.json DIVERGES from the print-mode stanza:"
  diff "$SCRATCH/.expected-stanza" "$SCRATCH/.mcp.json" >&2 || true
fi

# --- (b) the live claude CLI detects it, byte-correct ---------------------------
echo "--- (b) claude mcp get barkpark ---"
GET_OUT="$(claude mcp get barkpark 2>&1 | strip_ansi || true)"
grep -q "^  *Type: *${EXP_TYPE}$"    <<<"$GET_OUT" && ok "claude reports Type: ${EXP_TYPE}"       || bad "claude Type mismatch (want ${EXP_TYPE})"
grep -q "^  *Command: *${EXP_CMD}$"  <<<"$GET_OUT" && ok "claude reports Command: ${EXP_CMD}"      || bad "claude Command mismatch (want ${EXP_CMD})"
grep -q "^  *Args: *${EXP_ARGS}$"    <<<"$GET_OUT" && ok "claude reports Args: ${EXP_ARGS}"        || bad "claude Args mismatch (want ${EXP_ARGS})"
grep -qF "BARKPARK_API_URL=${EXP_URL}"   <<<"$GET_OUT" && ok "claude reports env BARKPARK_API_URL=${EXP_URL}" || bad "claude env BARKPARK_API_URL mismatch (want ${EXP_URL})"
grep -qF "BARKPARK_API_TOKEN=${EXP_TOK}" <<<"$GET_OUT" && ok "claude reports env BARKPARK_API_TOKEN=${EXP_TOK} (env-var placeholder, not a literal secret)" || bad "claude env BARKPARK_API_TOKEN mismatch (want ${EXP_TOK})"

# --- (c) negative control: detection is bound to the FILE, not a global cache ---
echo "--- (c) negative control (remove → gone, restore → back) ---"
mv "$SCRATCH/.mcp.json" "$SCRATCH/.mcp.json.bak"
GONE_OUT="$(claude mcp get barkpark 2>&1 | strip_ansi || true)"
grep -qF 'No MCP server named "barkpark"' <<<"$GONE_OUT" \
  && ok "with .mcp.json removed, claude: No MCP server named \"barkpark\"" \
  || bad "claude still reports barkpark after the file was removed (stale/global cache?): $GONE_OUT"
mv "$SCRATCH/.mcp.json.bak" "$SCRATCH/.mcp.json"
BACK_OUT="$(claude mcp get barkpark 2>&1 | strip_ansi || true)"
grep -q "^  *Command: *${EXP_CMD}$" <<<"$BACK_OUT" \
  && ok "with .mcp.json restored, claude detects barkpark again" \
  || bad "claude did not re-detect barkpark after the file was restored"

# --- (d) the server the config points at actually answers: JSON-RPC handshake ---
echo "--- (d) bp mcp serve JSON-RPC handshake ---"
# A manifest-capable token: env first, else the active token in the real config.
HS_TOKEN="${BARKPARK_API_TOKEN:-}"
HS_URL="${BARKPARK_API_URL:-}"
REAL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/barkpark/config.json"
if [ -z "$HS_TOKEN" ] && [ -f "$REAL_CFG" ]; then
  HS_TOKEN="$(python3 -c "import json;print(json.load(open('$REAL_CFG')).get('token',''))")"
  [ -z "$HS_URL" ] && HS_URL="$(python3 -c "import json;print(json.load(open('$REAL_CFG')).get('server',''))")"
fi

if [ -z "$HS_TOKEN" ]; then
  echo "  ⏸ handshake SKIPPED — no manifest-capable token (set BARKPARK_API_TOKEN or configure ~/.config/barkpark)."
  echo "     Detection half above stands on its own; the handshake is token-gated by design."
else
  # Drive the server over real pipes: initialize → notifications/initialized →
  # tools/list → tools/call task_ready. A watchdog thread kills a hung server
  # (macOS has no coreutils `timeout`). Python emits KEY=VALUE lines we eval.
  HS_RESULT="$(BARKPARK_API_URL="$HS_URL" BARKPARK_API_TOKEN="$HS_TOKEN" python3 - "$BP" <<'PY'
import json, subprocess, sys, threading
bp = sys.argv[1]
p = subprocess.Popen([bp, "mcp", "serve"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
watchdog = threading.Timer(45.0, p.kill)
watchdog.start()

def emit(k, v): print(f"{k}={v}")

try:
    def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
    def recv():
        while True:
            line = p.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if line:
                return json.loads(line)

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                     "clientInfo": {"name": "onramp-live-smoke", "version": "0"}}})
    init = recv() or {}
    emit("SERVERINFO", (init.get("result", {}).get("serverInfo", {}) or {}).get("name", ""))

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    tl = recv() or {}
    tools = [t.get("name") for t in tl.get("result", {}).get("tools", [])]
    emit("TOOLS", len(tools))

    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
          "params": {"name": "task_ready", "arguments": {}}})
    tc = recv() or {}
    res = tc.get("result", {}) or {}
    # task_ready's payload rides content[].text as a JSON string (the CLI's own
    # -o json receipt); parse it and read its ok flag.
    text = next((c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"), "")
    ready_ok = False
    try:
        ready_ok = bool(json.loads(text).get("ok"))
    except Exception:
        pass
    emit("READY_OK", "true" if ready_ok else "false")
    emit("IS_ERROR", "true" if res.get("isError") else "false")
finally:
    watchdog.cancel()
    try:
        p.stdin.close()
    except Exception:
        pass
    try:
        p.wait(timeout=10)
    except Exception:
        p.kill()
PY
)" || true

  # eval the KEY=VALUE lines into shell vars (SERVERINFO/TOOLS/READY_OK/IS_ERROR)
  SERVERINFO=""; TOOLS=""; READY_OK=""; IS_ERROR=""
  while IFS='=' read -r k v; do
    case "$k" in
      SERVERINFO) SERVERINFO="$v" ;;
      TOOLS)      TOOLS="$v" ;;
      READY_OK)   READY_OK="$v" ;;
      IS_ERROR)   IS_ERROR="$v" ;;
    esac
  done <<<"$HS_RESULT"

  [ "$SERVERINFO" = "barkpark-tasks" ] && ok "handshake serverInfo.name = barkpark-tasks" \
    || bad "handshake serverInfo.name = '${SERVERINFO}' (want barkpark-tasks)"
  [ "$TOOLS" = "8" ] && ok "handshake tools/list count = 8 (the curated task tools)" \
    || bad "handshake tools/list count = '${TOOLS}' (want 8)"
  { [ "$READY_OK" = "true" ] && [ "$IS_ERROR" != "true" ]; } \
    && ok "handshake tools/call task_ready returned ok:true from ${HS_URL}" \
    || bad "handshake task_ready did not return ok:true (ok='${READY_OK}' isError='${IS_ERROR}')"
fi

# --- isolation proof: the operator's real ~/.claude.json was never touched ------
echo "--- isolation ---"
AFTER_CLAUDE_STATE="$(sha_of "$REAL_CLAUDE_STATE")"
[ "$BEFORE_CLAUDE_STATE" = "$AFTER_CLAUDE_STATE" ] \
  && ok "real ~/.claude.json shasum unchanged (claude state redirected to scratch CLAUDE_CONFIG_DIR)" \
  || bad "real ~/.claude.json CHANGED during the run (before=$BEFORE_CLAUDE_STATE after=$AFTER_CLAUDE_STATE) — isolation leaked"

# =================================================================================
echo
echo "=== summary: $pass passed, $fail failed ==="
if [ "$fail" -eq 0 ]; then
  echo "LIVE-CLIENT PROOF PASSED — the claude CLI reads bp's emitted .mcp.json byte-correct,"
  echo "detection is file-bound, and bp mcp serve answers a real JSON-RPC handshake."
  echo "(Residual interactive approve+connect eyeball: ao-backlog-claude-code-connect-eyeball.)"
fi
[ "$fail" -eq 0 ]
