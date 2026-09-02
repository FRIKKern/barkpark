#!/usr/bin/env bash
# Offline harness for deploy/mcp-reachability-smoke.sh — the post-deploy LIVE
# reachability smoke for the public /mcp matrix.
#
# It drives the real script with a URL- AND METHOD-aware fake curl on PATH, so
# every leg can be moved independently without a box, a network, or a bearer:
#
#   FAKE_MCP_INIT_CODE / FAKE_MCP_INIT_BODY   POST /mcp
#   FAKE_MCP_GET_CODE                         GET  /mcp
#   FAKE_CONNECTORS_MCP_CODE                  GET  /connectors/mcp
#   FAKE_CONNECTORS_HEALTH_CODE               GET  /connectors/health
#
# WHAT IT PROVES
#   1) all four legs green -> exit 0 and "4/4 legs GREEN"
#   2) EACH leg red on its own -> exit 1, and the RED list names THAT leg and no other
#      (a smoke whose legs are not independent would go red in pairs and no one
#      would notice until a real outage)
#   3) 200-with-the-wrong-serverInfo is RED (the leg checks the NAME, not just the
#      code — a Caddy 200 or a squatter on :4010 must not read as a live endpoint)
#   4) a 503 on /mcp — guerrilla's state while barkpark-mcp.service is stopped —
#      reds exactly the two /mcp legs, leaves the two /connectors legs green, and
#      PRINTS 503 on both red lines (the verdict must carry the code it saw)
#   5) the smoke is WIRED into deploy/instance-deploy.sh's post-flip tail and is
#      swallowed into a WARN there (advisory, never a gate)
#
# HOUSE RULE, inherited from cp-deploy_test.sh: an assertion extracted from the
# script covers EVERY occurrence, never `head -1`.
# Run: bash deploy/mcp-reachability-smoke_test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/mcp-reachability-smoke.sh"
DEPLOY="$HERE/instance-deploy.sh"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"

# URL- and method-aware fake curl. Parses the flags the smoke actually passes
# (-s -o -w --max-time -X -H --data) and answers per ROUTE, writing the response
# body to the -o file so the serverInfo assertion has something real to read.
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|-o|-w|-H|--data|--max-time)
      [ "$1" = "-X" ] && method="$2"
      [ "$1" = "-o" ] && out="$2"
      shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
code=000; body=""
case "$url" in
  */connectors/health) code="${FAKE_CONNECTORS_HEALTH_CODE:-200}" ;;
  */connectors/mcp)    code="${FAKE_CONNECTORS_MCP_CODE:-404}" ;;
  */mcp)
    if [ "$method" = "POST" ]; then
      code="${FAKE_MCP_INIT_CODE:-200}"
      if [ -n "${FAKE_MCP_INIT_BODY+set}" ]; then
        body="$FAKE_MCP_INIT_BODY"
      else
        body='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"barkpark-tasks","title":"Barkpark Tasks","version":"0.0.0"}}}'
      fi
    else
      code="${FAKE_MCP_GET_CODE:-405}"
    fi ;;
esac
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
EOF
chmod +x "$FAKE/curl"

run_smoke() { # stdout -> $TMP/smoke.log ; echoes the exit code
  env PATH="$FAKE:$PATH" \
    FAKE_MCP_INIT_CODE="${FAKE_MCP_INIT_CODE:-}" \
    FAKE_MCP_GET_CODE="${FAKE_MCP_GET_CODE:-}" \
    FAKE_CONNECTORS_MCP_CODE="${FAKE_CONNECTORS_MCP_CODE:-}" \
    FAKE_CONNECTORS_HEALTH_CODE="${FAKE_CONNECTORS_HEALTH_CODE:-}" \
    bash "$SCRIPT" test.example > "$TMP/smoke.log" 2>&1
  echo $?
}
# reds -> the space-separated leg names on the summary line ("" when all green)
reds() { sed -n 's/.*legs GREEN against [^ ]* — RED: *//p' "$TMP/smoke.log" | head -1; }

echo "== Case 1: all four legs green =="
rc="$(run_smoke)"
check "exit 0"                      "[ '$rc' = '0' ]"
check "summary says 4/4 GREEN"      "grep -q '4/4 legs GREEN against https://test.example' '$TMP/smoke.log'"
check "exactly four LEG lines"      "[ \"\$(grep -c 'mcp-smoke: LEG' '$TMP/smoke.log')\" = '4' ]"
check "every LEG line is GREEN"     "[ \"\$(grep -c 'mcp-smoke: LEG.*=> GREEN' '$TMP/smoke.log')\" = '4' ]"
check "leg 1 names the server it saw" \
  "grep -q 'LEG 1/4 mcp-initialize .*POST https://test.example/mcp -> HTTP 200 .*serverInfo.name=barkpark-tasks => GREEN' '$TMP/smoke.log'"
check "leg 2 asserts 405 on a bare GET" \
  "grep -q 'LEG 2/4 mcp-get-405 *GET *https://test.example/mcp -> HTTP 405 (want 405)' '$TMP/smoke.log'"
check "leg 3 asserts the bridge has NO mcp surface" \
  "grep -q 'LEG 3/4 connectors-mcp-404 *GET *https://test.example/connectors/mcp -> HTTP 404 (want 404)' '$TMP/smoke.log'"
check "leg 4 asserts bridge liveness" \
  "grep -q 'LEG 4/4 connectors-health *GET *https://test.example/connectors/health -> HTTP 200 (want 200)' '$TMP/smoke.log'"
# CODE only, comments stripped: the script's own header says the word "bearer"
# while EXPLAINING that it sends none, and a whole-file grep would red on the
# sentence rather than on a header.
check "no leg sends a bearer (read-only, unauthenticated)" \
  "! sed 's/#.*//' '$SCRIPT' | grep -qi 'authorization\|bearer'"

echo "== Case 2: leg 1 red — the endpoint answers 500 =="
rc="$(FAKE_MCP_INIT_CODE=500 run_smoke)"
check "exit 1"                      "[ '$rc' = '1' ]"
check "ONLY mcp-initialize is red"  "[ \"\$(reds)\" = 'mcp-initialize' ]"
check "the red line carries the 500 it saw" \
  "grep -q 'LEG 1/4 mcp-initialize .*-> HTTP 500 .*=> RED' '$TMP/smoke.log'"
check "3/4 green"                   "grep -q '3/4 legs GREEN' '$TMP/smoke.log'"

echo "== Case 3: leg 1 red — 200 but the WRONG serverInfo (a squatter on :4010) =="
rc="$(FAKE_MCP_INIT_BODY='{"result":{"serverInfo":{"name":"some-other-server","version":"9"}}}' run_smoke)"
check "exit 1"                      "[ '$rc' = '1' ]"
check "ONLY mcp-initialize is red"  "[ \"\$(reds)\" = 'mcp-initialize' ]"
check "the red line names the WRONG server, not just the code" \
  "grep -q 'LEG 1/4 mcp-initialize .*-> HTTP 200 .*serverInfo.name=some-other-server => RED' '$TMP/smoke.log'"

echo "== Case 4: leg 1 red — 200 with an empty body (nothing answered the handshake) =="
rc="$(FAKE_MCP_INIT_BODY='' run_smoke)"
check "exit 1"                      "[ '$rc' = '1' ]"
check "ONLY mcp-initialize is red"  "[ \"\$(reds)\" = 'mcp-initialize' ]"
check "the red line reports <none> rather than reading empty in silence" \
  "grep -q 'LEG 1/4 mcp-initialize .*serverInfo.name=<none> => RED' '$TMP/smoke.log'"

echo "== Case 5: leg 2 red — a bare GET /mcp answers 200 =="
rc="$(FAKE_MCP_GET_CODE=200 run_smoke)"
check "exit 1"                      "[ '$rc' = '1' ]"
check "ONLY mcp-get-405 is red"     "[ \"\$(reds)\" = 'mcp-get-405' ]"
check "the red line carries the 200 it saw against want 405" \
  "grep -q 'LEG 2/4 mcp-get-405 .*-> HTTP 200 (want 405).*=> RED' '$TMP/smoke.log'"

echo "== Case 6: leg 3 red — /connectors/mcp answers 200 (the routes collided) =="
rc="$(FAKE_CONNECTORS_MCP_CODE=200 run_smoke)"
check "exit 1"                        "[ '$rc' = '1' ]"
check "ONLY connectors-mcp-404 is red" "[ \"\$(reds)\" = 'connectors-mcp-404' ]"
check "the red line carries the 200 it saw against want 404" \
  "grep -q 'LEG 3/4 connectors-mcp-404 .*-> HTTP 200 (want 404).*=> RED' '$TMP/smoke.log'"

echo "== Case 7: leg 4 red — the bridge is down, Caddy serves the maintenance 503 =="
rc="$(FAKE_CONNECTORS_HEALTH_CODE=503 run_smoke)"
check "exit 1"                        "[ '$rc' = '1' ]"
check "ONLY connectors-health is red"  "[ \"\$(reds)\" = 'connectors-health' ]"
check "the red line carries the 503 it saw" \
  "grep -q 'LEG 4/4 connectors-health .*-> HTTP 503 (want 200).*=> RED' '$TMP/smoke.log'"

echo "== Case 8: barkpark-mcp.service STOPPED — /mcp is 503, /connectors still fine =="
# This is guerrilla's real state whenever the MCP unit is down (it was, by ruling,
# while `bp mcp serve --http` fast-failed on an anonymous manifest with no task
# noun). The smoke must red exactly the two /mcp legs, print 503 on both, and leave
# the bridge legs alone — a smoke that collapsed this into one verdict would send an
# operator to the wrong unit.
rc="$(FAKE_MCP_INIT_CODE=503 FAKE_MCP_INIT_BODY='' FAKE_MCP_GET_CODE=503 run_smoke)"
check "exit 1"                        "[ '$rc' = '1' ]"
check "both /mcp legs red, both /connectors legs green" \
  "[ \"\$(reds)\" = 'mcp-initialize mcp-get-405' ]"
check "2/4 green"                     "grep -q '2/4 legs GREEN' '$TMP/smoke.log'"
check "leg 1 prints the 503, not a bare FAIL" \
  "grep -q 'LEG 1/4 mcp-initialize .*-> HTTP 503 .*=> RED' '$TMP/smoke.log'"
check "leg 2 prints the 503, not a bare FAIL" \
  "grep -q 'LEG 2/4 mcp-get-405 .*-> HTTP 503 (want 405).*=> RED' '$TMP/smoke.log'"
check "the two bridge legs stayed GREEN" \
  "[ \"\$(grep -c 'mcp-smoke: LEG [34]/4.*=> GREEN' '$TMP/smoke.log')\" = '2' ]"

echo "== Case 9: total outage — curl cannot connect at all =="
rc="$(FAKE_MCP_INIT_CODE=000 FAKE_MCP_INIT_BODY='' FAKE_MCP_GET_CODE=000 \
      FAKE_CONNECTORS_MCP_CODE=000 FAKE_CONNECTORS_HEALTH_CODE=000 run_smoke)"
check "exit 1"                        "[ '$rc' = '1' ]"
check "0/4 green"                     "grep -q '0/4 legs GREEN' '$TMP/smoke.log'"
check "every leg reports HTTP 000 rather than going quiet" \
  "[ \"\$(grep -c 'mcp-smoke: LEG .*-> HTTP 000 ' '$TMP/smoke.log')\" = '4' ]"

echo "== Case 10: wired into the deploy, and ADVISORY there =="
check "instance-deploy.sh calls the smoke by name" \
  "grep -q 'deploy/mcp-reachability-smoke.sh' '$DEPLOY'"
check "it runs against the STABLE public front (\$HEALTH_HOST), never a slot port" \
  "grep -q 'bash \"\$MCP_SMOKE\" \"\$HEALTH_HOST\"' '$DEPLOY'"
# EVERY occurrence, not head -1: a second, unguarded invocation would make the
# deploy fatal on a red leg and this check would still pass on the first one.
check "EVERY invocation is swallowed into a WARN (advisory, never a gate)" \
  "[ \"\$(grep -c 'bash \"\$MCP_SMOKE\"' '$DEPLOY')\" = \"\$(grep -c 'bash \"\$MCP_SMOKE\" \"\$HEALTH_HOST\" || log' '$DEPLOY')\" ]"
check "a missing script logs an honest skip instead of dying" \
  "grep -q 'reachability smoke skipped' '$DEPLOY'"
check "the smoke runs AFTER the barkpark-mcp unit refresh" \
  "[ \"\$(grep -n 'systemctl restart barkpark-mcp' '$DEPLOY' | tail -1 | cut -d: -f1)\" -lt \"\$(grep -n 'bash \"\$MCP_SMOKE\"' '$DEPLOY' | head -1 | cut -d: -f1)\" ]"
check "the smoke runs AFTER the connectors unit refresh" \
  "[ \"\$(grep -n 'systemctl restart barkpark-connectors' '$DEPLOY' | tail -1 | cut -d: -f1)\" -lt \"\$(grep -n 'bash \"\$MCP_SMOKE\"' '$DEPLOY' | head -1 | cut -d: -f1)\" ]"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
