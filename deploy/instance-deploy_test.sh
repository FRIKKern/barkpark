#!/usr/bin/env bash
# Offline test for deploy/instance-deploy.sh (blue/green) — drives the whole
# script with fake git/mix/systemctl/install/curl/sleep/flock/sed in PATH
# against a temp dir. caddy is REAL (validation is genuine). Proves:
#   - slot selection: Caddy upstream :4000 -> deploy green, :4001 -> deploy blue
#   - only the idle slot's build root is (re)built; the active one is untouched
#   - the flip rewrites the Caddyfile upstream and the file stays caddy-valid
#   - an unhealthy new slot is stopped, NO flip, active slot never touched
#   - the maintenance-page arming is injected once, idempotently, and does not
#     confuse the ACTIVE_PORT grep or the port-flip sed
#   - the channel seam: a production box (no $APP/.staging) fast-forwards main
#     only and REFUSES a non-main DEPLOY_REF (exit 11); a staging box (.staging
#     present) fetch+hard-resets ANY ref (branch or PR pull/<n>/head) and flips
#   - the coalesce no-op stays a no-op; rm-ing the STATE file forces a rebuild
# The fake git records every invocation to $GITLOG so the channel asserts can
# see which git verb ran. Never touches a real server.
# Run: bash deploy/instance-deploy_test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/instance-deploy.sh"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

command -v caddy >/dev/null 2>&1 || { echo "SKIP: caddy binary required (real validation)"; exit 0; }

make_fakes() {
  local dir="$1"; mkdir -p "$dir"
  cat > "$dir/git" <<'EOF'
#!/usr/bin/env bash
# Fake git: record the invocation, honor refs. Skip leading -c KV / -C PATH
# option pairs to find the subcommand (the script calls e.g.
# `git -c core.hooksPath=/dev/null fetch origin <ref>`).
[ -n "${GITLOG:-}" ] && echo "git $*" >> "$GITLOG"
args=("$@"); i=0; sub=""
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -c|-C) i=$((i + 2)); continue ;;
    *) sub="${args[$i]}"; break ;;
  esac
done
[ "$sub" = "rev-parse" ] && { echo "${FAKE_SHA:-deadbeef}"; exit 0; }
exit 0
EOF
  cat > "$dir/mix" <<'EOF'
#!/usr/bin/env bash
echo "mix $* [MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-}]" >> "$MIXLOG"
if [ "$1" = "compile" ]; then
  mkdir -p "${MIX_BUILD_ROOT:-_build}/prod"
  echo built > "${MIX_BUILD_ROOT:-_build}/prod/MARKER"
fi
exit 0
EOF
  cat > "$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSCTLLOG"; exit 0
EOF
  cat > "$dir/install" <<'EOF'
#!/usr/bin/env bash
echo "install $*" >> "$SYSCTLLOG"; exit 0
EOF
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${HEALTH_CODE:-200}"
EOF
  # GNU-style `sed -i "expr" file` shim for macOS (the script targets Linux).
  cat > "$dir/sed" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-i" ]; then shift; expr="$1"; shift; exec perl -pi -e "$expr" "$@"; fi
exec /usr/bin/sed "$@"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/sleep"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/flock"
  chmod +x "$dir"/*
}

setup_case() {
  TMP="$(mktemp -d)"
  FAKE="$TMP/fakebin"; make_fakes "$FAKE"
  APP="$TMP/app"; mkdir -p "$APP/api" "$APP/deploy/systemd"
  printf 'BARKPARK_KEK=x\nBARKPARK_CLOAK_KEY=y\nPREVIEW_JWT_SECRET=z\n' > "$APP/.env"
  cp "$HERE/systemd/barkpark-slot@.service" "$APP/deploy/systemd/"
  CADDY="$TMP/Caddyfile"
  printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$CADDY"
  export MIXLOG="$TMP/mix.log" SYSCTLLOG="$TMP/sysctl.log" GITLOG="$TMP/git.log"
  : > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
}

run_deploy() { # $1=health code  $2=fake sha  (DEPLOY_REF/DEPLOY_REMOTE from env)
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    HOME="$TMP/home" FAKE_SHA="$2" HEALTH_CODE="$1" \
    DEPLOY_REF="${DEPLOY_REF:-}" DEPLOY_REMOTE="${DEPLOY_REMOTE:-}" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
  echo $?
}
# shellcheck disable=SC2329  # invoked indirectly via eval inside check()
first_upstream() { grep -oE 'localhost:40[0-9]{2}' "$CADDY" | head -1; }

echo "== Case 1: blue active (:4000) -> healthy deploy of green =="
setup_case
rc="$(run_deploy 200 newsha)"
check "exit 0"                            "[ '$rc' = '0' ]"
check "green root built"                  "[ -f '$APP/api/_build_green/prod/MARKER' ]"
check "blue root never created/touched"   "[ ! -e '$APP/api/_build_blue' ]"
check "build used MIX_BUILD_ROOT=_build_green" "grep -q 'MIX_BUILD_ROOT=_build_green' '$MIXLOG'"
check "exactly one clean build (2 compile lines)" "[ \"\$(grep -c compile '$MIXLOG')\" = '2' ]"
check "slot env files written"            "grep -q 'BARKPARK_PORT_OVERRIDE=4001' '$APP/.slots/green.env' && grep -q '_build_blue' '$APP/.slots/blue.env'"
check "green slot booted"                 "grep -q 'restart barkpark-slot@green' '$SYSCTLLOG'"
check "Caddy flipped to :4001"            "[ \"\$(first_upstream)\" = 'localhost:4001' ]"
check "armed Caddyfile caddy-valid"       "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
check "maintenance handler armed once"    "[ \"\$(grep -c 'handle_errors {' '$CADDY')\" = '1' ]"
check "old slot + legacy unit retired"    "grep -q 'disable --now barkpark-slot@blue' '$SYSCTLLOG' && grep -q 'disable --now barkpark' '$SYSCTLLOG'"
check "green slot enabled (reboot-safe)"  "grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "state file = newsha"               "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'newsha' ]"
check "prod channel: ff-only pull of origin main" "grep -q 'pull --ff-only origin main' '$GITLOG'"
check "prod channel: no staging fetch/reset"       "! grep -qE 'fetch|reset --hard FETCH_HEAD' '$GITLOG'"

echo "== Case 2: green active (:4001) -> healthy deploy flips back to blue =="
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(run_deploy 200 newsha2)"
check "exit 0"                            "[ '$rc' = '0' ]"
check "blue root built this time"         "[ -f '$APP/api/_build_blue/prod/MARKER' ]"
check "build used MIX_BUILD_ROOT=_build_blue" "grep -q 'MIX_BUILD_ROOT=_build_blue' '$MIXLOG'"
check "green root left in place (instant rollback)" "[ -f '$APP/api/_build_green/prod/MARKER' ]"
check "Caddy flipped back to :4000"       "[ \"\$(first_upstream)\" = 'localhost:4000' ]"
check "no double arm (idempotent)"        "[ \"\$(grep -c 'handle_errors {' '$CADDY')\" = '1' ]"
check "flipped Caddyfile still caddy-valid" "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
check "green slot retired"                "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
rm -rf "$TMP"

echo "== Case 3: unhealthy new slot -> stopped, NO flip, active untouched =="
setup_case
rc="$(run_deploy 000 badsha)"
check "exit 14"                           "[ '$rc' = '14' ]"
check "Caddy upstream unchanged (:4000)"  "[ \"\$(first_upstream)\" = 'localhost:4000' ]"
check "unhealthy green slot stopped"      "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
check "active blue slot never stopped"    "! grep -qE '(stop|disable --now) barkpark-slot@blue' '$SYSCTLLOG'"
check "legacy unit not touched on failure" "! grep -qE 'disable --now barkpark($| )' '$SYSCTLLOG'"
check "no enable of the failed slot"      "! grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "state file NOT advanced"           "[ ! -f '$APP/.instance-deploy-last' ]"
check "no recompile after failure (2 compile lines)" "[ \"\$(grep -c compile '$MIXLOG')\" = '2' ]"
rm -rf "$TMP"

echo "== Case 4: production box (no .staging) REFUSES a non-main DEPLOY_REF =="
setup_case   # no $APP/.staging marker
rc="$(DEPLOY_REF=feature-x run_deploy 200 refusesha)"
check "exit 11"                           "[ '$rc' = '11' ]"
check "no fetch of the branch"            "! grep -q 'fetch' '$GITLOG'"
check "no hard reset to FETCH_HEAD"       "! grep -q 'reset --hard FETCH_HEAD' '$GITLOG'"
check "no pull either (refused first)"    "! grep -q 'pull --ff-only' '$GITLOG'"
check "no build attempted"               "[ ! -e '$APP/api/_build_green' ] && [ ! -e '$APP/api/_build_blue' ]"
check "no slot booted"                    "! grep -q 'restart barkpark-slot' '$SYSCTLLOG'"
check "Caddy upstream unchanged (:4000)"  "[ \"\$(first_upstream)\" = 'localhost:4000' ]"
check "state file NOT written"            "[ ! -f '$APP/.instance-deploy-last' ]"
: > "$GITLOG"
rc="$(DEPLOY_REMOTE=fork run_deploy 200 refusesha)"   # ref=main, remote=fork
check "non-origin remote: exit 11"        "[ '$rc' = '11' ]"
check "non-origin remote: no git mutation" "! grep -qE 'fetch|reset --hard FETCH_HEAD|pull --ff-only' '$GITLOG'"
rm -rf "$TMP"

echo "== Case 5: production box, default ref -> unchanged guerrilla ff-only path =="
setup_case
rc="$(run_deploy 200 defaultsha)"   # DEPLOY_REF unset -> main
check "exit 0"                            "[ '$rc' = '0' ]"
check "ff-only pull of origin main"       "grep -q 'pull --ff-only origin main' '$GITLOG'"
check "artifact-discard checkout ran"     "grep -q 'checkout -- .' '$GITLOG'"
check "no staging fetch/reset on prod"    "! grep -qE 'fetch|reset --hard FETCH_HEAD' '$GITLOG'"
check "healthy full flip to :4001"        "[ \"\$(first_upstream)\" = 'localhost:4001' ]"
rm -rf "$TMP"

echo "== Case 6: staging box (.staging) deploys a branch, then a PR ref, full flip each =="
setup_case
touch "$APP/.staging"
rc="$(DEPLOY_REF=feature-x run_deploy 200 branchsha)"
check "branch exit 0"                     "[ '$rc' = '0' ]"
check "fetched origin feature-x"          "grep -q 'fetch origin feature-x' '$GITLOG'"
check "hard reset to FETCH_HEAD"          "grep -q 'reset --hard FETCH_HEAD' '$GITLOG'"
check "staging skips ff-only pull"        "! grep -q 'pull --ff-only' '$GITLOG'"
check "staging skips artifact checkout"   "! grep -q 'checkout -- .' '$GITLOG'"
check "green root built (full flip)"      "[ -f '$APP/api/_build_green/prod/MARKER' ]"
check "Caddy flipped to :4001"            "[ \"\$(first_upstream)\" = 'localhost:4001' ]"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(DEPLOY_REF=pull/123/head run_deploy 200 prsha)"
check "PR-ref exit 0"                     "[ '$rc' = '0' ]"
check "fetched origin pull/123/head"      "grep -q 'fetch origin pull/123/head' '$GITLOG'"
check "PR hard reset to FETCH_HEAD"       "grep -q 'reset --hard FETCH_HEAD' '$GITLOG'"
check "blue root built this time"         "[ -f '$APP/api/_build_blue/prod/MARKER' ]"
check "Caddy flipped back to :4000"       "[ \"\$(first_upstream)\" = 'localhost:4000' ]"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(DEPLOY_REMOTE=fork DEPLOY_REF=feature-y run_deploy 200 forksha)"
check "non-origin remote honored on staging" "grep -q 'fetch fork feature-y' '$GITLOG'"
check "non-origin remote: hard reset ran"    "grep -q 'reset --hard FETCH_HEAD' '$GITLOG'"
check "non-origin remote: exit 0"            "[ '$rc' = '0' ]"
rm -rf "$TMP"

echo "== Case 7: coalesce no-op, then rm STATE forces a rebuild =="
setup_case
run_deploy 200 coalsha >/dev/null        # first healthy deploy writes STATE=coalsha
check "state file = coalsha"              "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'coalsha' ]"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(run_deploy 200 coalsha)"           # same HEAD, STATE matches -> no-op
check "coalesce exit 0"                   "[ '$rc' = '0' ]"
check "coalesce: no build"                "[ \"\$(grep -c compile '$MIXLOG')\" = '0' ]"
check "coalesce: no slot restart"         "! grep -q 'restart barkpark-slot' '$SYSCTLLOG'"
rm -f "$APP/.instance-deploy-last"        # the force-rebuild lever
: > "$MIXLOG"; : > "$SYSCTLLOG"
rc="$(run_deploy 200 coalsha)"
check "rebuild after rm STATE: exit 0"    "[ '$rc' = '0' ]"
check "rebuild recompiled (2 compile lines)" "[ \"\$(grep -c compile '$MIXLOG')\" = '2' ]"
check "state file re-written = coalsha"   "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'coalsha' ]"
rm -rf "$TMP"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
