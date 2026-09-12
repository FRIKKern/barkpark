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

probe "deploy.sh (one-box provisioning bring-up probe)" \
  "$(extract_path 'deploy.sh' deploy.sh 's|.*bp_curl_body -s "http://localhost:\$APP_PORT\(/[^"]*\)".*|\1|p')"

probe "internal/cli/cloud/support.go (SupportLocalHealthProbe)" \
  "$(extract_path 'support.go' internal/cli/cloud/support.go 's|^const SupportLocalHealthProbe = .curl -fsS http://localhost:4000\(/[^ ]*\) .*|\1|p')"

# ── the cli fence (internal/cli + internal/provisioner). Nine probe sites, each
# extracted from its OWN file: reverting any one of them reds this harness
# without anyone editing this file.
probe "internal/cli/cloud/restore_driver.go (restoreHealthURL — the on-box agent's self-probe)" \
  "$(extract_path 'restore_driver const' internal/cli/cloud/restore_driver.go 's|^const restoreHealthURL = "http://localhost:4000\(/[^"]*\)"$|\1|p')"

probe "internal/cli/cloud/restore_driver.go (restoreDataScript post-restore wait)" \
  "$(extract_path 'restore_driver script' internal/cli/cloud/restore_driver.go 's|^curl -sf -m 60 .*4000}\(/[^"]*\)".*|\1|p')"

probe "internal/cli/cloud_deploy_cmd.go (deploySmokeURLs — the API check printed on success)" \
  "$(extract_path 'deploy smoke urls' internal/cli/cloud_deploy_cmd.go '/return \[\]string{/{n;s|.*"\(/[^"]*\)".*|\1|p;}')"

probe "internal/cli/cloud_support_cmd.go (supportEnableImportStep restart wait)" \
  "$(extract_path 'cloud support import step' internal/cli/cloud_support_cmd.go 's|^for i in \$(seq 1 60); do curl -fsS http://localhost:4000\(/[^ ]*\) .*|\1|p')"

probe "internal/cli/hetzner_instance_cmd.go (instHealth — resurrect/adopt/eject gate)" \
  "$(extract_path 'instHealth' internal/cli/hetzner_instance_cmd.go 's|^	url := "https://" + fqdn + "\(/[^"]*\)"$|\1|p')"

probe "internal/cli/hetzner_instance_transfer_cmd.go (post-import health wait)" \
  "$(extract_path 'instance transfer' internal/cli/hetzner_instance_transfer_cmd.go 's|^curl -sf -m 60 .*4000}\(/[^"]*\)".*|\1|p')"

probe "internal/cli/setup/assets/deploy.sh (the VENDORED provisioning bring-up probe bp ships to every box)" \
  "$(extract_path 'vendored deploy.sh' internal/cli/setup/assets/deploy.sh 's|.*bp_health_probe "http://localhost:\$APP_PORT\(/[^"]*\)".*|\1|p')"

probe "internal/cli/setup/local.go (barkparkAnswering — the 'is a server already up?' fallback)" \
  "$(extract_path 'setup local' internal/cli/setup/local.go 's|.*range \[\]string{"/v1/capabilities", "\(/[^"]*\)"}.*|\1|p')"

probe "internal/provisioner/support.go (supportEnableImportStep restart wait)" \
  "$(extract_path 'provisioner support' internal/provisioner/support.go 's|^for i in \$(seq 1 60); do curl -fsS http://localhost:4000\(/[^ ]*\) .*|\1|p')"

# ── the api fence (the root entry points). Six probe sites, each extracted from
# its OWN file for the same reason: reverting one reds this harness with no edit
# here. PowerShell is not runnable on the CI/dev host, so setup-windows.ps1's two
# sites are checked the same way every other one is — the path is pulled out of
# the file and driven with curl. That measures the retarget, not the interpreter.
probe "Makefile (make deploy post-pull health poll)" \
  "$(extract_path 'Makefile deploy poll' Makefile 's|.*bp_curl_code -s -o /dev/null --max-time 5 http://localhost:4000\([a-z./]*\).*|\1|p')"

probe "bin/barkpark (wait_server — the boot gate barkpark up dies on)" \
  "$(extract_path 'bin/barkpark wait_server' bin/barkpark 's|^    if curl -sf "http://\$PHX_HOST:\$PORT\(/[^"]*\)" >/dev/null 2>&1; then$|\1|p')"

# server_answering keeps a DOCUMENTED legacy fallback on its SECOND line, for an
# older build (pre-d40092ab9, 2026-07-05) that has no /status.json and is not
# affected by the sunset because the removal lands in new builds, not in a
# running binary. What must survive the sunset is the PRIMARY path, and that is
# the line extracted here — the one every current build is decided by.
probe "bin/barkpark (server_answering PRIMARY — stop/status identity probe)" \
  "$(extract_path 'bin/barkpark server_answering' bin/barkpark 's|^  curl -sf "http://\$PHX_HOST:\$PORT\(/[^"]*\)" >/dev/null 2>&1 && return 0$|\1|p')"

probe "run.sh (api_answers — the dev bring-up 'is Phoenix already up?' test)" \
  "$(extract_path 'run.sh api_answers' run.sh 's|.*bp_curl_code -s -o /dev/null "\$API_URL\(/[^"]*\)".*|\1|p')"

probe "scripts/setup-windows.ps1 (Start-Server boot wait)" \
  "$(extract_path 'setup-windows Start-Server' scripts/setup-windows.ps1 's|^      \$r = Invoke-WebRequest "http://localhost:\$Port\(/[^"]*\)" -UseBasicParsing -TimeoutSec 3$|\1|p')"

probe "scripts/setup-windows.ps1 (Show-Status api line)" \
  "$(extract_path 'setup-windows Show-Status' scripts/setup-windows.ps1 's|^    \$r = Invoke-WebRequest "http://localhost:\$Port\(/[^"]*\)" -UseBasicParsing -TimeoutSec 3$|\1|p')"

echo ""
echo "---- CENSUS: who is STILL on the sunset route (a predicate over the tree, not a list)"
# A line is a PROBE when it names api/schemas AND carries a fetch verb or builds
# a probe URL. Positive matching, deliberately: an exclusion list ("drop
# anything with echo") already produced a MEASURED false absence here —
# Makefile:299 and run.sh:18 both pipe their probe through `|| echo 000` and
# vanished from the census.
#
# The verb set is VALIDATED IN BOTH DIRECTIONS against origin/main at fe01df112:
# run over the pre-repoint tree it names all eleven cli-fence sites that PR
# changed (the nine probes plus the vendored deploy.sh's `curl -v` diagnostic),
# and over the post-repoint tree it named only the api fence's seven. Those
# seven are this branch's subject: six are repointed above and the census now
# sees only the two ADJUDICATED files below.
#
# Scope is the shipping health surface: the root entry points, the deploy/setup
# scripts, and the Go CLI + provisioner. Tests, testdata and this harness are
# excluded — they are ABOUT the route, they do not gate on it.
census_files() {
  git ls-files deploy.sh run.sh Makefile bin/barkpark docker-compose.yml \
    'scripts/*.sh' 'scripts/*.ps1' 'deploy/*.sh' 'internal/cli/*' 'internal/provisioner/*' \
    | grep -vE '(_test\.(go|sh)|\.test\.sh|/testdata/|^scripts/sunset-route-consumers)'
}
census_probes() {
  local files; files="$(census_files)"
  # shellcheck disable=SC2086  # deliberate word-splitting: one grep over the set
  grep -nE 'api/schemas' $files 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(#|//)' \
    | grep -E '(curl|wget|bp_curl_[a-z]+|bp_health_probe|Invoke-WebRequest|http\.Get|client\.Get|healthcheck|[Uu][Rr][Ll][A-Za-z]*[[:space:]]*:?=|base \+|\[\]string\{)'
}

# CONTROL: the census must be able to SEE the route at all. If the file set or
# the grep is broken, "zero remaining" is free — the failure mode that made the
# exclusion-list version lie. api/router.ex is where the route is DEFINED, so a
# census that cannot find it there is not measuring anything.
if git grep -qn 'api/schemas' -- api/lib/barkpark_web/router.ex; then
  ok "c3. CONTROL — the census grep can still see /api/schemas where it is DEFINED (api/lib/barkpark_web/router.ex)"
else
  bad "c3. CONTROL — /api/schemas is not greppable in api/lib/barkpark_web/router.ex; every census verdict below is unearned"
fi
CENSUS_FILE_COUNT="$(census_files | wc -l | tr -d ' ')"
if [ "$CENSUS_FILE_COUNT" -gt 100 ]; then
  ok "c4. CONTROL — the census covers $CENSUS_FILE_COUNT files (a collapsed file set cannot report a free zero)"
else
  bad "c4. CONTROL — the census covers only $CENSUS_FILE_COUNT files; the path globs stopped matching"
fi

CENSUS="$(census_probes || true)"
printf '%s\n' "${CENSUS:-  (no probe anywhere on the health surface still names /api/schemas)}" | sed 's/^/  census: /' | cut -c1-160

# THE CLI FENCE: this task's half. Zero, no ledger, no exceptions.
CLI_LEFT="$(printf '%s\n' "$CENSUS" | grep -E '^internal/(cli|provisioner)/' || true)"
check "cli fence (internal/cli, internal/provisioner) has ZERO probes left on the sunset route" \
  "" "$(printf '%s' "$CLI_LEFT")"

# THE API FENCE: the root entry points. Everything the census can still see here
# must be ADJUDICATED — named in one of the two ledgers below, each of which is a
# list of FILES (never line numbers, which move) and fails in BOTH directions: a
# file that acquires a probe and is in neither ledger is a REGRESSION; a ledgered
# file that no longer has one is a STALE entry to delete. "Unadjudicated" is the
# only state that is a failure — the ledgers do not excuse, they ACCOUNT.
#
# ADJUDICATED — a remaining mention that is CORRECT, and whose correctness is
# measured elsewhere in this file rather than asserted here:
#   bin/barkpark  server_answering() keeps the legacy path as a documented
#                 SECOND probe so `stop`/`status` still recognise an older build
#                 (pre-d40092ab9, 2026-07-05) that has no /status.json and that
#                 the sunset cannot touch — the removal lands in new builds, not
#                 in a running binary. Its PRIMARY path has its own fixture case
#                 above, so this entry is backed by a measurement, not a note.
ADJUDICATED='bin/barkpark'
# STILL TO REPOINT — a real probe that will fail closed on removal day, left to
# the lane that owns the file. Shrink-only.
#   scripts/pds-pull-proof.sh:3109  reboot_target()'s post-reboot health wait,
#                 inside the pds loan fence (scripts/pds-*).
API_LEDGER='scripts/pds-pull-proof.sh'
API_LEFT="$(printf '%s\n' "$CENSUS" | grep -vE '^internal/(cli|provisioner)/' | cut -d: -f1 | sort -u | grep -v '^$' || true)"
ADJ_ALL="$(printf '%s\n%s\n' "$ADJUDICATED" "$API_LEDGER" | grep -v '^$' | sort -u)"
UNLEDGERED="$(comm -23 <(printf '%s\n' "$API_LEFT") <(printf '%s\n' "$ADJ_ALL"))"
STALE="$(comm -13 <(printf '%s\n' "$API_LEFT") <(printf '%s\n' "$ADJ_ALL"))"
check "no UNADJUDICATED file on the health surface names the sunset route (a new one is a regression)" "" "$(printf '%s' "$UNLEDGERED")"
if [ -n "$STALE" ]; then
  bad "a ledger is STALE — these files no longer name the sunset route, delete them from ADJUDICATED/API_LEDGER in this file: $(printf '%s' "$STALE" | tr '\n' ' ')"
else
  ok "the api-fence ledgers name exactly the files that still mention the sunset route ($(printf '%s\n' "$ADJUDICATED" | wc -l | tr -d ' ') adjudicated, $(printf '%s\n' "$API_LEDGER" | wc -l | tr -d ' ') still to repoint)"
fi

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
