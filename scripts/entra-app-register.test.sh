#!/usr/bin/env bash
# ok and bad always return 0, so `test && ok || bad` reports one of them.
# shellcheck disable=SC2015
#
# entra-app-register.test.sh: checks what scripts/entra-app-register.sh prints.
#
# Hermetic. `az`, `curl` and `sleep` are stubs on PATH that answer a fresh
# tenant, so no Azure or network call is made.
#
#   scripts/entra-app-register.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/entra-app-register.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }

BIN="$TMP/bin"; mkdir -p "$BIN"
# The az stub answers a tenant with no app yet. SECRETS holds the number of
# client secrets an existing app has, for the rotation case.
cat >"$BIN/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >>"$STUB_LOG"
case "$*" in
  "account show"*) echo tenant-1 ;;
  "ad app list"*) [ "${SECRETS:-0}" = 0 ] && echo "" || echo app-1 ;;
  "ad app show"*"length(passwordCredentials)"*) echo "${SECRETS:-0}" ;;
  "ad app show"*"endDateTime"*) echo 2027-10-28T00:00:00Z ;;
  "ad app show"*"web.redirectUris"*) echo "" ;;
  "ad app create"*) echo app-1 ;;
  "ad sp list"*) echo "" ;;
  "ad sp create"*) echo sp-1 ;;
  "ad sp show"*) echo graph-sp ;;
  "rest --method GET --uri https://graph.microsoft.com/v1.0/oauth2PermissionGrants"*) echo "openid profile email" ;;
  "ad group list"*) echo "" ;;
  "ad group create"*) echo group-1 ;;
  "ad user show"*) echo user-1 ;;
  "ad group member check"*) echo false ;;
  "ad app credential reset"*) echo secret-value ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/curl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
chmod +x "$BIN/az" "$BIN/curl" "$BIN/sleep"

run() {
  export STUB_LOG="$TMP/calls.log"
  : >"$STUB_LOG"
  PATH="$BIN:$PATH" bash "$SCRIPT" --host barkpark.example.com --org pensum \
    --group-claims security "$@" >"$TMP/out" 2>"$TMP/err"
}

echo "first secret"
rm -f "$TMP/secret"
SECRETS=0 run --secret-file "$TMP/secret" --org-name "Pensum test"
rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc: $(cat "$TMP/err")"
grep -qx 'bp org create pensum "Pensum test" --yes' "$TMP/out" \
  && ok "bp org create carries --org-name" || bad "bp org create line: $(grep 'org create' "$TMP/out")"
grep -q '<display name>' "$TMP/out" && bad "placeholder <display name> printed" || ok "no <display name> placeholder"
grep -q 'permission add .*--only-show-errors' "$STUB_LOG" \
  && ok "permission add hides the az grant hint" || bad "permission add without --only-show-errors"
grep -q 'Run the bp org commands below now' "$TMP/err" \
  && ok "first secret says to store it now" || bad "first secret message: $(cat "$TMP/err")"
grep -q 'Store it in Barkpark after' "$TMP/err" && bad "first secret asks for a wait" || ok "first secret asks for no wait"
[ "$(cat "$TMP/secret")" = secret-value ] && ok "secret written to the file" || bad "secret file content"
grep -q secret-value "$TMP/out" "$TMP/err" && bad "secret printed" || ok "secret never printed"

echo "default org name"
rm -f "$TMP/secret"
SECRETS=0 run --secret-file "$TMP/secret"
grep -qx 'bp org create pensum "pensum" --yes' "$TMP/out" \
  && ok "org name defaults to the slug" || bad "default org create line: $(grep 'org create' "$TMP/out")"

echo "rotated secret"
SECRETS=1 run --secret-file "$TMP/secret" --rotate-secret
rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc: $(cat "$TMP/err")"
grep -q 'Store it in Barkpark after' "$TMP/err" \
  && ok "rotation waits before storing" || bad "rotation message: $(cat "$TMP/err")"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
