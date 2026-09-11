#!/usr/bin/env bash
# shellcheck disable=SC2016  # every sed expression below quotes LITERAL $API_URL /
# $PDS_SCRATCH_BASE / ${BP_HEALTH_URL:-...} text as it appears in the consumer
# file. Expanding it here would destroy the match the extraction depends on.
# ─────────────────────────────────────────────────────────────────────────────
# scripts/sunset-route-consumers.test.sh — ONE fake server, POST-SUNSET.
#
# WHAT IT MEASURES. `/api/schemas` is mounted through
# BarkparkWeb.Plugs.LegacyDeprecation and carries a PUBLISHED removal date
# (`sunset: Wed, 31 Dec 2026 23:59:59 GMT`). Every health consumer in this
# repo's deploy surface gates on the STATUS CODE, so on 2027-01-01 a healthy
# box turns every one of them red. This harness builds the world of that day —
# a server that 404s `/api/schemas` and serves `/status.json` — and drives each
# consumer's OWN probe URL against it.
#
# WHY IT CANNOT GO STALE. No probe string is retyped here. Each consumer's URL
# is EXTRACTED from the consumer file at run time (`extract_path`), so reverting
# a retarget reds this file without anyone editing it — that is the mutation
# sensitivity the retarget is worth. A missing extraction is a HARD FAILURE,
# never a skip: an empty match must not read as a pass.
#
# CONTROLS. Two, and both must fire before any verdict is trusted:
#   c1. the fake server really does 404 `/api/schemas` (else every green is free)
#   c2. the fake server really does 200 `/status.json` (else every red is free)
#
# Run: bash scripts/sunset-route-consumers.test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

PASS=0; FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 — expected '$2', measured '$3'"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

# ── the POST-SUNSET fake box ─────────────────────────────────────────────────
cat > "$TMP/server.py" <<'PY'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path.startswith('/api/'):
            # The world of 2027-01-01: the legacy scope is GONE.
            body = b'{"error":"not_found"}'
            self.send_response(404)
        elif path == '/status.json':
            body = json.dumps({"status": "operational", "commit": "deadbeefcafe"}).encode()
            self.send_response(200)
        elif path == '/login':
            body = b'<html>login</html>'
            self.send_response(200)
        else:
            body = b'{"error":"not_found"}'
            self.send_response(404)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

srv = HTTPServer(('127.0.0.1', 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY

python3 "$TMP/server.py" > "$TMP/port" 2>"$TMP/srv.err" &
SRV_PID=$!
PORT=""
for _ in $(seq 1 100); do
  PORT="$(head -1 "$TMP/port" 2>/dev/null || true)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "FATAL: the fake post-sunset server never reported a port" >&2
  cat "$TMP/srv.err" >&2
  exit 2
fi
BASE="http://127.0.0.1:$PORT"
echo "post-sunset fake box on $BASE"

code_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }

echo ""
echo "---- CONTROLS: the fixture is the world of 2027-01-01, not a friendly server"
check "c1. the fake box 404s the SUNSET route (every green below is earned)" 404 "$(code_of "$BASE/api/schemas")"
check "c2. the fake box 200s /status.json (every red below is earned)"       200 "$(code_of "$BASE/status.json")"

# extract_path <label> <file> <sed-expression> — pull a probe path OUT of the
# consumer file. Empty is a HARD failure: an absence must never read as a pass.
extract_path() {
  local label="$1" file="$2" expr="$3" got
  got="$(sed -n "$expr" "$file" | head -1)"
  if [ -z "$got" ]; then
    bad "$label: could not extract a probe path from $file — the harness lost its subject (NOT a pass)"
    printf '%s' ""
    return 1
  fi
  printf '%s' "$got"
}

probe() { # probe <label> <path>
  local label="$1" path="$2"
  [ -z "$path" ] && return 0
  check "$label probes '$path' — survives the sunset" 200 "$(code_of "$BASE$path")"
}

echo ""
echo "---- ONE FIXTURE CHECK PER CODE CONSUMER (path extracted from the file itself)"

probe "scripts/deploy-rebuild.sh (BP_HEALTH_URL default)" \
  "$(extract_path 'deploy-rebuild' scripts/deploy-rebuild.sh 's|^BP_HEALTH_URL="\${BP_HEALTH_URL:-http://localhost:4000\(/[^"}]*\)}"$|\1|p')"

probe "scripts/create-quickstart-smoke.sh (boot health-poll)" \
  "$(extract_path 'quickstart' scripts/create-quickstart-smoke.sh 's|.*bp_curl_body -sS "\$API_URL\(/[^"]*\)".*|\1|p')"

probe "scripts/compose-smoke.sh (green-arm in-container probe)" \
  "$(extract_path 'compose-smoke' scripts/compose-smoke.sh 's|.*compose exec -T api wget -q -O /dev/null http://localhost:4000\(/[^ ;]*\).*|\1|p')"

probe "scripts/pds-scratch-target.sh (scratch-server probe)" \
  "$(extract_path 'pds-scratch' scripts/pds-scratch-target.sh 's|.*bp_curl_code -s -o /dev/null "\$PDS_SCRATCH_BASE\(/[^"]*\)".*|\1|p')"

probe "docker-compose.yml (api healthcheck)" \
  "$(extract_path 'compose healthcheck' docker-compose.yml 's|.*wget -q -O /dev/null http://localhost:4000\(/[^ ]*\) .*|\1|p')"

probe "internal/cli/cloud/support.go (SupportLocalHealthProbe)" \
  "$(extract_path 'support.go' internal/cli/cloud/support.go 's|^const SupportLocalHealthProbe = .curl -fsS http://localhost:4000\(/[^ ]*\) .*|\1|p')"

echo ""
echo "---- THE TWO DOCS name the surviving route"
for d in deploy/uptime-kuma/README.md deploy/README.md; do
  if grep -q 'status\.json' "$d"; then ok "$d names /status.json"; else bad "$d does not name /status.json"; fi
done
if grep -qE '^\| URL .*api/schemas' deploy/uptime-kuma/README.md; then
  bad "deploy/uptime-kuma/README.md still configures the monitor URL at the sunset route"
else
  ok "deploy/uptime-kuma/README.md's monitor URL row has left the sunset route"
fi

echo ""
echo "---- $FAIL failure(s), $PASS pass(es)"
[ "$FAIL" = 0 ] || exit 1
echo "SUNSET-CONSUMER TEST PASSED — every fenced consumer's own probe URL answers 200 on a box where /api/schemas is gone."
