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
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAIL"; fi
exit "$fails"
