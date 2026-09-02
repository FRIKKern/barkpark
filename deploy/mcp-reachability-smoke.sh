#!/usr/bin/env bash
# deploy/mcp-reachability-smoke.sh — POST-DEPLOY LIVE reachability smoke for the
# public /mcp matrix (task connectors-mcp-live-reachability-smoke).
#
# WHY IT IS NOT A CI GATE. The auth fail-closed contract and the Caddy arming are
# already proven hermetically (internal/cli/mcp_http_test.go,
# deploy/instance-deploy_test.sh). What NEITHER can prove is that the four public
# paths answer correctly on a real box: a CI runner cannot reach guerrilla and
# holds no bearer. So the durable form of that proof is a post-deploy smoke that
# runs ON the box, against the stable public front, AFTER every unit is refreshed.
#
# THE FOUR LEGS (the whole matrix; a leg is one HTTP request, never a bundle):
#   1 mcp-initialize    POST /mcp              -> 200 AND serverInfo.name=barkpark-tasks
#                       (the name the --http server advertises; internal/cli/mcp_serve.go
#                        mcp.Implementation{Name: "barkpark-tasks"}). 200-with-the-wrong-name
#                        is RED on purpose: it means Caddy answered, or some other
#                        process holds :4010, not that the MCP endpoint is live.
#   2 mcp-get-405       GET  /mcp              -> 405  (Streamable HTTP rejects a bare GET;
#                        a 200 here means something that is NOT the MCP server answered)
#   3 connectors-mcp-404 GET /connectors/mcp   -> 404  (BY DESIGN — the bridge owns
#                        /connectors and deliberately exposes no MCP surface there.
#                        Anything but 404 means the two routes have collided.)
#   4 connectors-health GET /connectors/health -> 200  (the ONE unauthenticated bridge
#                        surface; a 503 is Caddy's maintenance page, i.e. bridge down)
#
# ADVISORY IN THE DEPLOY PATH, EXACT STANDALONE. instance-deploy.sh runs this at the
# very end, when the app slot is ALREADY live and Caddy has ALREADY flipped, and
# swallows the exit code into a WARN: a stopped barkpark-mcp must never brick a good
# app deploy. Standalone it exits 1 on any RED leg, so an operator (or a future gate
# that CAN reach the host) gets a real verdict.
#
# EVERY LEG PRINTS THE CODE IT SAW — never a bare pass/fail. A smoke that says only
# "FAIL" sends you to the box to re-run curl by hand; one that says "HTTP 503 want
# 405" has already told you the unit is down.
#
# READ-ONLY AND UNAUTHENTICATED. No bearer is sent on any leg: initialize is the
# pre-auth handshake, and the other three need none. Nothing here mutates anything.
#
# Usage:
#   bash deploy/mcp-reachability-smoke.sh [host]     # default guerrilla.barkpark.cloud
# Env: MCP_SMOKE_SCHEME (https) MCP_SMOKE_TIMEOUT (15) MCP_SMOKE_SERVER_NAME (barkpark-tasks)
set -uo pipefail

HOST="${1:-${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}}"
SCHEME="${MCP_SMOKE_SCHEME:-https}"
TIMEOUT="${MCP_SMOKE_TIMEOUT:-15}"
SERVER_NAME="${MCP_SMOKE_SERVER_NAME:-barkpark-tasks}"
BASE="$SCHEME://$HOST"

case "$HOST" in
  -h|--help)
    echo "usage: bash deploy/mcp-reachability-smoke.sh [host]   (default guerrilla.barkpark.cloud)"
    exit 0 ;;
esac

command -v curl >/dev/null 2>&1 || {
  echo "mcp-smoke: no curl on PATH — cannot probe $BASE (smoke SKIPPED)" >&2
  exit 2
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

leg=0; green=0; red_names=""

# report <name> <method> <url> <code> <want> <detail>  -- $7=0 green, else red
report() {
  local verdict="RED"
  leg=$((leg + 1))
  if [ "$7" = "0" ]; then verdict="GREEN"; green=$((green + 1)); else red_names="$red_names $1"; fi
  printf 'mcp-smoke: LEG %d/4 %-18s %-4s %s -> HTTP %s (want %s) %s => %s\n' \
    "$leg" "$1" "$2" "$3" "$4" "$5" "$6" "$verdict"
}

# The initialize handshake. protocolVersion is pinned so a server that negotiates
# is answering us, not echoing; clientInfo names this smoke in the server's log.
INIT_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"barkpark-deploy-smoke","version":"1"}}}'

# serverInfo.name out of a JSON-RPC (or SSE-framed) initialize response. Prefers the
# serverInfo object; falls back to the first "name" so a shape change reports SOMETHING
# rather than silently reading empty.
server_name_from() {
  local f="$1" flat chunk
  [ -s "$f" ] || return 0
  flat="$(tr -d '\n\r' < "$f")"
  chunk="$(printf '%s' "$flat" | grep -o '"serverInfo"[[:space:]]*:[[:space:]]*{[^}]*}' | head -1)"
  [ -n "$chunk" ] || chunk="$flat"
  printf '%s' "$chunk" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed 's/.*"\([^"]*\)"/\1/'
}

echo "mcp-smoke: public /mcp reachability matrix against $BASE (read-only, unauthenticated)"

# ---- LEG 1: POST /mcp initialize -> 200 + serverInfo.name
body="$TMPD/init.body"; : > "$body"
code="$(curl -s -o "$body" -w '%{http_code}' --max-time "$TIMEOUT" \
  -X POST \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data "$INIT_PAYLOAD" \
  "$BASE/mcp" 2>/dev/null)"
[ -n "$code" ] || code="000"
got_name="$(server_name_from "$body")"
ok=1
if [ "$code" = "200" ] && [ "$got_name" = "$SERVER_NAME" ]; then ok=0; fi
report mcp-initialize POST "$BASE/mcp" "$code" \
  "200 + serverInfo.name=$SERVER_NAME" "serverInfo.name=${got_name:-<none>}" "$ok"

# ---- LEG 2: GET /mcp -> 405
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$BASE/mcp" 2>/dev/null)"
[ -n "$code" ] || code="000"
ok=1; [ "$code" = "405" ] && ok=0
report mcp-get-405 GET "$BASE/mcp" "$code" "405" "method-not-allowed" "$ok"

# ---- LEG 3: GET /connectors/mcp -> 404 (by design: no MCP surface on the bridge)
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$BASE/connectors/mcp" 2>/dev/null)"
[ -n "$code" ] || code="000"
ok=1; [ "$code" = "404" ] && ok=0
report connectors-mcp-404 GET "$BASE/connectors/mcp" "$code" "404" "no-mcp-on-the-bridge" "$ok"

# ---- LEG 4: GET /connectors/health -> 200 (the one unauthenticated bridge surface)
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$BASE/connectors/health" 2>/dev/null)"
[ -n "$code" ] || code="000"
ok=1; [ "$code" = "200" ] && ok=0
report connectors-health GET "$BASE/connectors/health" "$code" "200" "bridge-liveness" "$ok"

if [ "$green" -eq 4 ]; then
  echo "mcp-smoke: 4/4 legs GREEN against $BASE"
  exit 0
fi
echo "mcp-smoke: $green/4 legs GREEN against $BASE — RED:$red_names"
exit 1
