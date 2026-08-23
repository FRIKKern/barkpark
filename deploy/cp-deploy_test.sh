#!/usr/bin/env bash
# Offline test for the dwb-16 control-url PIN in deploy/cp-deploy.sh.
#
# ROOT CAUSE it guards: the blue/green control-plane deploy flips the active port
# (4100<->4101), but the provisioner unit hardcoded `--control-url
# http://localhost:4100`. After a flip the worker was silently locked out — jobs
# sat pending, unclaimed, forever (the "/new froze at Starting" incident). The fix
# pins the worker at the stable public front so a port flip can never lock it out.
#
# This proves two things WITHOUT touching a real box or driving the whole deploy:
#   1) cp-deploy.sh statically contains the pin (stable front + daemon-reload).
#   2) the exact sed rewrite the script uses turns a localhost:4100 (or :4101, or
#      an =-separated) control-url into https://barkpark.cloud, idempotently.
# Run: bash deploy/cp-deploy_test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/cp-deploy.sh"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

echo "cp-deploy control-url pin (dwb-16)"

# 1) Static: the pin targets the STABLE FRONT and reloads systemd.
check "pins control-url to the stable front https://barkpark.cloud" \
  "grep -q 'PROVISIONER_CONTROL_URL:-https://barkpark.cloud' '$SCRIPT'"
check "rewrites the --control-url flag via sed" \
  "grep -q -- '--control-url\\[= \\]' '$SCRIPT'"
check "runs systemctl daemon-reload after the rewrite" \
  "grep -q 'systemctl daemon-reload' '$SCRIPT'"

# 2) Functional: the exact rewrite the script applies. Mirror the script's sed so
# a drift in the rewrite expression fails here too.
PROV_CONTROL_URL="https://barkpark.cloud"
# Mirrors cp-deploy.sh's sed expression EXACTLY, but writes via a temp instead of
# `-i` so the test is portable to BSD sed (macOS) as well as GNU sed (the box).
rewrite() {
  sed -E "s#--control-url[= ][^[:space:]\"']+#--control-url ${PROV_CONTROL_URL}#g" "$1" > "$1.out"
  mv "$1.out" "$1"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# a) space-separated localhost:4100 (the exact bug) -> stable front
printf 'ExecStart=/usr/local/bin/barkpark-provisioner --control-url http://localhost:4100 --token-file /etc/barkpark/worker.token\n' > "$tmp"
rewrite "$tmp"
check "localhost:4100 rewritten to the stable front" \
  "grep -q -- '--control-url https://barkpark.cloud --token-file /etc/barkpark/worker.token' '$tmp'"
check "no localhost:4100 remains" "! grep -q 'localhost:4100' '$tmp'"

# b) the flipped port :4101 -> stable front (the flip that caused the lockout)
printf 'ExecStart=/usr/local/bin/barkpark-provisioner --control-url http://localhost:4101\n' > "$tmp"
rewrite "$tmp"
check "flipped port :4101 rewritten to the stable front" \
  "! grep -q 'localhost:4101' '$tmp' && grep -q 'https://barkpark.cloud' '$tmp'"

# c) idempotent: re-running keeps the stable front (no double-mangle)
rewrite "$tmp"
check "idempotent re-run keeps a single stable-front control-url" \
  "[ \"\$(grep -oc -- '--control-url https://barkpark.cloud' '$tmp')\" = '1' ]"

echo
echo "cp-deploy slot health-check status codes (pds-bl-w49)"
# ROOT CAUSE it guards: the '/' probe used to accept 404 as "healthy" — a
# container that boots but serves nothing but 404s (crashed app, wrong port, a
# static server up with the SPA missing) is exactly the broken-deploy shape
# this gate exists to catch, and 404 waved it through as green. Extract the
# EXACT status-code class the script classifies as healthy, so a regression
# (404 sneaking back in, or 200/301/302 sneaking OUT) fails here too — not just
# a hardcoded string match.
HEALTH_LINE="$(grep -n '200|301|302' "$SCRIPT" | head -1)"
HEALTH_LINE="${HEALTH_LINE#*:}"
HEALTH_RE="${HEALTH_LINE#*"grep -qE '^("}"
HEALTH_RE="${HEALTH_RE%%")\$'"*}"
check "found the health-check regex class in the script" "[ -n '$HEALTH_RE' ]"

code_is_healthy() { echo "$1" | grep -qE "^(${HEALTH_RE})\$"; }  # replays the script's EXACT classification

check "200 (OK) classified healthy"                     "code_is_healthy 200"
check "301 (redirect) classified healthy"                "code_is_healthy 301"
check "302 (redirect) classified healthy"                "code_is_healthy 302"
check "404 (not found) NOT healthy — the fixed defect"   "! code_is_healthy 404"
check "500 (server error) NOT healthy"                    "! code_is_healthy 500"
check "000 (curl failure / connection refused) NOT healthy" "! code_is_healthy 000"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAIL"; fi
exit "$fails"
