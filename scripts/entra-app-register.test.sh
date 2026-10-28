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
# client secrets an existing app has, for the rotation case. REDIRECT_URIS is
# that app's redirect URIs, one per line, and GROUP_EXISTS the id of a group
# that already has the owners group name.
cat >"$BIN/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >>"$STUB_LOG"
case "$*" in
  "account show"*) echo tenant-1 ;;
  "ad app list"*) [ "${SECRETS:-0}" = 0 ] && echo "" || echo app-1 ;;
  "ad app show"*"length(passwordCredentials)"*) echo "${SECRETS:-0}" ;;
  "ad app show"*"endDateTime"*) echo 2027-10-28T00:00:00Z ;;
  "ad app show"*"displayName"*) echo "Barkpark pensum" ;;
  "ad app show"*"web.redirectUris"*) printf "%b" "${REDIRECT_URIS:-}" ;;
  "ad app create"*) echo app-1 ;;
  "ad sp list"*) echo "" ;;
  "ad sp create"*) echo sp-1 ;;
  "ad sp show"*) echo graph-sp ;;
  "rest --method GET --uri https://graph.microsoft.com/v1.0/oauth2PermissionGrants"*) echo "openid profile email" ;;
  "ad group list"*) echo "${GROUP_EXISTS:-}" ;;
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

echo "app found by name on another host"
SECRETS=1 REDIRECT_URIS='https://other.example.com/v1/auth/oidc/pensum/callback\n' \
  run --secret-file "$TMP/secret"
rc=$?
[ "$rc" = 1 ] && ok "exits 1" || bad "exit $rc, want 1: $(cat "$TMP/err")"
grep -q 'has no redirect URI on barkpark.example.com' "$TMP/err" \
  && ok "names the host mismatch" || bad "mismatch message: $(cat "$TMP/err")"
grep -q 'https://other.example.com/v1/auth/oidc/pensum/callback' "$TMP/err" \
  && ok "lists the app's redirect URIs" || bad "redirect URIs not listed"
grep -q -- '--app-id app-1' "$TMP/err" && ok "names --app-id as the deliberate route" || bad "no --app-id hint"
grep -Eq 'az ad (app (create|update|permission|credential)|sp create|group (create|member add))' "$STUB_LOG" \
  && bad "changed something before stopping: $(grep -E 'create|update|add|reset' "$STUB_LOG")" \
  || ok "changes nothing"

echo "app found by name on this host"
SECRETS=1 REDIRECT_URIS='https://other.example.com/v1/auth/oidc/pensum/callback\nhttps://barkpark.example.com/v1/auth/oidc/pensum/callback\n' \
  run --secret-file "$TMP/secret"
rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc: $(cat "$TMP/err")"

echo "app given by --app-id on another host"
SECRETS=1 REDIRECT_URIS='https://other.example.com/v1/auth/oidc/pensum/callback\n' \
  run --secret-file "$TMP/secret" --app-id app-1
rc=$?
[ "$rc" = 0 ] && ok "exits 0, --app-id is a deliberate choice" || bad "exit $rc: $(cat "$TMP/err")"

echo "new app, owners group name taken"
rm -f "$TMP/secret"
SECRETS=0 GROUP_EXISTS=group-other run --secret-file "$TMP/secret"
rc=$?
[ "$rc" = 1 ] && ok "exits 1" || bad "exit $rc, want 1: $(cat "$TMP/err")"
grep -q 'security group "Barkpark pensum owners" exists, but the app is new' "$TMP/err" \
  && ok "names the taken group" || bad "group message: $(cat "$TMP/err")"
grep -Eq 'az ad (app create|group create|group member add|app credential)' "$STUB_LOG" \
  && bad "created something before stopping" || ok "creates nothing"
[ -e "$TMP/secret" ] && bad "secret file written" || ok "no secret file"

echo "new app, existing group named with --owners-group"
SECRETS=0 GROUP_EXISTS=group-other run --secret-file "$TMP/secret" --owners-group "Barkpark pensum owners"
rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc: $(cat "$TMP/err")"
grep -q '"group-other":"owner"' "$TMP/out" && ok "maps the named group" || bad "mapping: $(grep mappings "$TMP/out")"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
