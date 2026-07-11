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
#   - rollback (W6): every deploy stamps .slots/<target>.sha; a happy
#     --rollback resets the checkout to the stamp sha, reboots + health-gates
#     the idle slot, flips Caddy back, rewrites STATE; --rollback-preflight is
#     read-only and typed (21 no_previous_slot / 22 not_supported / 23 lock
#     held); an unhealthy rollback fails CLOSED (exit 24, Caddy byte-identical,
#     slot re-disabled, checkout reset back)
#   - the /mcp route (viable-everywhere D19): injected once, idempotently,
#     BEFORE the bare slot reverse_proxy; its localhost:4010 line never
#     confuses the (slot-port-exact) ACTIVE_PORT grep and the port-flip sed
#     provably leaves it untouched, forward flip and rollback alike
#   - the barkpark-mcp install guard (D18/D19): the unit is enabled ONLY when
#     the built bp binary advertises `mcp serve --http` (fake go emits a fake
#     bp; GO_HTTP=1 flips the advertisement); the written mcp.env pins the
#     stable front and carries NO token line
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
  # FLOCK_FAIL=1 simulates a held deploy lock (rollback modes must exit 23).
  printf '#!/usr/bin/env bash\n[ -n "${FLOCK_FAIL:-}" ] && exit 1\nexit 0\n' > "$dir/flock"
  # Fake go: `go build -o OUT …` writes a fake bp binary whose
  # `mcp serve --help` advertises --http only under GO_HTTP=1 (drives the
  # barkpark-mcp install guard); GO_FAIL=1 fails the build outright.
  cat > "$dir/go" <<'EOF'
#!/usr/bin/env bash
[ -n "${GO_FAIL:-}" ] && exit 1
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$out" ]; then
  if [ -n "${GO_HTTP:-}" ]; then
    printf '#!/usr/bin/env bash\necho "usage: bp mcp serve [--http addr] [--tools tasks|all]"\n' > "$out"
  else
    printf '#!/usr/bin/env bash\necho "usage: bp mcp serve [--tools tasks|all]"\n' > "$out"
  fi
  chmod +x "$out"
fi
exit 0
EOF
  # Fake make: the wasm step sees `command -v go` succeed (fake go above) and
  # calls `make wasm` — keep that hermetic too.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/make"
  chmod +x "$dir"/*
}

setup_case() {
  TMP="$(mktemp -d)"
  FAKE="$TMP/fakebin"; make_fakes "$FAKE"
  # The script prepends $HOME/.asdf/shims:/usr/local/go/bin to PATH — a real
  # /usr/local/go/bin/go on the test host would shadow the fake. Plant the
  # fake go in the shims dir (HOME is $TMP/home), which the script puts FIRST.
  mkdir -p "$TMP/home/.asdf/shims"
  cp "$FAKE/go" "$TMP/home/.asdf/shims/go"
  APP="$TMP/app"; mkdir -p "$APP/api" "$APP/deploy/systemd"
  printf 'BARKPARK_KEK=x\nBARKPARK_CLOAK_KEY=y\nPREVIEW_JWT_SECRET=z\n' > "$APP/.env"
  cp "$HERE/systemd/barkpark-slot@.service" "$APP/deploy/systemd/"
  cp "$HERE/systemd/barkpark-mcp.service" "$APP/deploy/systemd/"
  CADDY="$TMP/Caddyfile"
  printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$CADDY"
  export MIXLOG="$TMP/mix.log" SYSCTLLOG="$TMP/sysctl.log" GITLOG="$TMP/git.log"
  : > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
}

run_deploy() { # $1=health code  $2=fake sha  (DEPLOY_REF/DEPLOY_REMOTE/GO_* from env)
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    BARKPARK_MCP_ENV_FILE="$TMP/mcp.env" \
    HOME="$TMP/home" FAKE_SHA="$2" HEALTH_CODE="$1" \
    DEPLOY_REF="${DEPLOY_REF:-}" DEPLOY_REMOTE="${DEPLOY_REMOTE:-}" \
    GO_HTTP="${GO_HTTP:-}" GO_FAIL="${GO_FAIL:-}" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
  echo $?
}
run_rollback() { # $1=health code  $2=fake sha (live HEAD)
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    HOME="$TMP/home" FAKE_SHA="$2" HEALTH_CODE="$1" \
    bash "$SCRIPT" --rollback > "$TMP/rollback.log" 2>&1
  echo $?
}
run_preflight() { # $1=fake sha (live HEAD); stdout kept for TARGET_* asserts
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    HOME="$TMP/home" FAKE_SHA="$1" HEALTH_CODE=200 \
    bash "$SCRIPT" --rollback-preflight > "$TMP/preflight.log" 2>&1
  echo $?
}
# shellcheck disable=SC2329  # invoked indirectly via eval inside check()
# Slot ports only — the armed /mcp route's localhost:4010 sits ABOVE the site
# upstream, so a loose 40[0-9]{2} grep would report the wrong "active" port
# (exactly the bug the script's tightened ACTIVE_PORT grep prevents).
first_upstream() { grep -oE 'localhost:400[01]' "$CADDY" | head -1; }

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
check "mcp route armed once"              "[ \"\$(grep -c 'BARKPARK_MCP_ROUTE' '$CADDY')\" = '1' ]"
check "mcp route proxies :4010, exactly one line" "[ \"\$(grep -c 'localhost:4010' '$CADDY')\" = '1' ]"
check "mcp handle sits before the bare slot proxy" "[ \"\$(grep -n 'handle @barkpark_mcp' '$CADDY' | head -1 | cut -d: -f1)\" -lt \"\$(grep -nE 'reverse_proxy localhost:400[01]' '$CADDY' | head -1 | cut -d: -f1)\" ]"
check "flip sed left :4010 untouched"     "grep -q 'reverse_proxy localhost:4010' '$CADDY'"
check "mcp unit NOT enabled (bp lacks --http)" "! grep -q 'enable barkpark-mcp' '$SYSCTLLOG'"
check "guard skip logged honestly"        "grep -q 'skipping barkpark-mcp install' '$TMP/out.log'"
check "no mcp.env written on skip"        "[ ! -f '$TMP/mcp.env' ]"
check "old slot + legacy unit retired"    "grep -q 'disable --now barkpark-slot@blue' '$SYSCTLLOG' && grep -q 'disable --now barkpark' '$SYSCTLLOG'"
check "green slot enabled (reboot-safe)"  "grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "state file = newsha"               "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'newsha' ]"
check "per-slot sha stamp written (W6)"   "[ \"\$(cat '$APP/.slots/green.sha' 2>/dev/null)\" = 'newsha' ]"
check "idle slot has no stamp yet"        "[ ! -e '$APP/.slots/blue.sha' ]"
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
check "no double mcp arm (idempotent)"    "[ \"\$(grep -c 'BARKPARK_MCP_ROUTE' '$CADDY')\" = '1' ]"
check "second flip sed left :4010 untouched" "[ \"\$(grep -c 'localhost:4010' '$CADDY')\" = '1' ]"
check "flipped Caddyfile still caddy-valid" "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
check "green slot retired"                "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
check "blue stamp written, green stamp kept" "[ \"\$(cat '$APP/.slots/blue.sha' 2>/dev/null)\" = 'newsha2' ] && [ \"\$(cat '$APP/.slots/green.sha' 2>/dev/null)\" = 'newsha' ]"
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

echo "== Case 8: rollback refusals — not_supported, no_previous_slot, lock held =="
setup_case
rc="$(run_preflight freshsha)"            # no .slots dir at all (pre-stamp box)
check "preflight on pre-slot box: exit 22 not_supported" "[ '$rc' = '22' ]"
run_deploy 200 v1sha >/dev/null           # ONE deploy: green live, blue never built
cp "$CADDY" "$TMP/caddy.before"
: > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(run_preflight v1sha)"
check "preflight single-deploy box: exit 21 no_previous_slot" "[ '$rc' = '21' ]"
rc="$(run_rollback 200 v1sha)"
check "rollback single-deploy box: exit 21 no_previous_slot"  "[ '$rc' = '21' ]"
check "refusal leaves Caddyfile byte-identical" "cmp -s '$CADDY' '$TMP/caddy.before'"
check "refusal makes zero systemctl mutations"  "! grep -qE 'restart|enable|disable|reload' '$SYSCTLLOG'"
check "refusal never resets the checkout"       "! grep -q 'reset --hard' '$GITLOG'"
rc="$(FLOCK_FAIL=1 run_preflight v1sha)"
check "deploy lock held: exit 23 already_running" "[ '$rc' = '23' ]"
rm -rf "$TMP"

echo "== Case 9: happy rollback — two deploys populate both slots, --rollback flips back =="
setup_case
run_deploy 200 v1sha >/dev/null           # green live :4001, .slots/green.sha=v1sha
run_deploy 200 v2sha >/dev/null           # blue live :4000,  .slots/blue.sha=v2sha
check "both slot stamps recorded"         "[ \"\$(cat '$APP/.slots/green.sha')\" = 'v1sha' ] && [ \"\$(cat '$APP/.slots/blue.sha')\" = 'v2sha' ]"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(run_preflight v2sha)"
check "preflight exit 0"                  "[ '$rc' = '0' ]"
check "preflight prints TARGET_SLOT=green" "grep -q '^TARGET_SLOT=green$' '$TMP/preflight.log'"
check "preflight prints TARGET_SHA=v1sha"  "grep -q '^TARGET_SHA=v1sha$' '$TMP/preflight.log'"
check "preflight is read-only"            "! grep -qE 'restart|enable|disable|reload' '$SYSCTLLOG' && ! grep -q 'reset --hard' '$GITLOG'"
rc="$(run_rollback 200 v2sha)"
check "rollback exit 0"                   "[ '$rc' = '0' ]"
check "checkout reset to the stamp sha"   "grep -q 'reset --hard v1sha' '$GITLOG'"
check "old slot rebooted"                 "grep -q 'restart barkpark-slot@green' '$SYSCTLLOG'"
check "Caddy flipped back to :4001"       "[ \"\$(first_upstream)\" = 'localhost:4001' ]"
check "rollback flip sed left :4010 untouched" "[ \"\$(grep -c 'localhost:4010' '$CADDY')\" = '1' ]"
check "rolled-back Caddyfile caddy-valid" "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
check "STATE rewritten to rolled-back sha" "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'v1sha' ]"
check "rolled-back slot enabled (reboot-safe)" "grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "rolled-away slot retired"          "grep -q 'disable --now barkpark-slot@blue' '$SYSCTLLOG'"
check "no rebuild during rollback"        "[ \"\$(grep -c compile '$MIXLOG')\" = '0' ]"
rm -rf "$TMP"

echo "== Case 10: unhealthy rollback fails CLOSED — Caddy untouched, slot re-disabled, checkout back =="
setup_case
run_deploy 200 v1sha >/dev/null
run_deploy 200 v2sha >/dev/null           # blue live :4000, green idle at v1sha
cp "$CADDY" "$TMP/caddy.before"
: > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(run_rollback 000 v2sha)"            # resurrected slot never turns healthy
check "exit 24 unhealthy_fail_closed"     "[ '$rc' = '24' ]"
check "Caddyfile byte-identical (no flip)" "cmp -s '$CADDY' '$TMP/caddy.before'"
check "resurrected slot re-disabled"      "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
check "live blue slot never touched"      "! grep -qE '(stop|disable --now) barkpark-slot@blue' '$SYSCTLLOG'"
check "checkout reset back to live sha"   "grep -q 'reset --hard v2sha' '$GITLOG'"
check "STATE untouched (still v2sha)"     "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'v2sha' ]"
check "no caddy reload attempted"         "! grep -q 'reload caddy' '$SYSCTLLOG'"
rm -rf "$TMP"

echo "== Case 11: barkpark-mcp install guard — enabled only when bp advertises --http =="
setup_case
rc="$(GO_HTTP=1 run_deploy 200 mcpsha)"
check "exit 0"                            "[ '$rc' = '0' ]"
check "mcp unit installed"                "grep -q 'barkpark-mcp.service /etc/systemd/system/barkpark-mcp.service' '$SYSCTLLOG'"
check "mcp unit enabled + restarted"      "grep -q 'systemctl enable barkpark-mcp' '$SYSCTLLOG' && grep -q 'systemctl restart barkpark-mcp' '$SYSCTLLOG'"
check "mcp binary installed under its own name" "grep -q 'install -m 0755 .* /usr/local/bin/barkpark-mcp' '$SYSCTLLOG'"
check "mcp.env pins the stable front"     "grep -q '^BARKPARK_API_URL=https://test.example$' '$TMP/mcp.env'"
check "mcp.env carries the listen addr"   "grep -q '^BARKPARK_MCP_HTTP_ADDR=127.0.0.1:4010$' '$TMP/mcp.env'"
check "mcp.env holds NO token (forward-through D18)" "! grep -qi 'token' '$TMP/mcp.env'"
check "committed unit holds NO token env line" "! grep -qiE '^(Environment|ExecStart).*TOKEN' '$HERE/systemd/barkpark-mcp.service'"
check "mcp route armed alongside"         "[ \"\$(grep -c 'BARKPARK_MCP_ROUTE' '$CADDY')\" = '1' ]"
: > "$SYSCTLLOG"
rm -f "$TMP/mcp.env" "$APP/.instance-deploy-last"   # force a re-run; build now FAILS
rc="$(GO_FAIL=1 run_deploy 200 mcpsha2)"
check "go build failure: deploy still exit 0 (non-fatal)" "[ '$rc' = '0' ]"
check "go build failure: unit NOT enabled" "! grep -q 'enable barkpark-mcp' '$SYSCTLLOG'"
check "go build failure: no mcp.env written" "[ ! -f '$TMP/mcp.env' ]"
rm -rf "$TMP"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
