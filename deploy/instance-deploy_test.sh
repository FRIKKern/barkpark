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
#   - the /connectors route + barkpark-connectors install guard (connectors
#     D34/D46): the route is injected once, idempotently, BEFORE the bare slot
#     reverse_proxy, and its localhost:4020 survives the port-flip sed and the
#     rollback flip; the unit is installed ONLY when node resolves, `npm ci`
#     succeeds and the tsx runner exists, and is DISABLED again if it does not
#     stay active (no crash-loop); connectors.env is 0600, pins the stable
#     public front, and carries NO chat token (the multi-tenant hole)
#   - the name-encoding pin: the committed slot unit pins a UTF-8 locale BEFORE
#     its EnvironmentFile (so a per-slot env file still wins) and api/start.sh
#     defaults the same mode without clobbering an operator LANG — asserted by
#     replaying start.sh's own guard, because a fresh host image has no
#     /etc/default/locale and boots the VM in latin1
#   - advance vs stall (D292): the fake git keeps a STATEFUL HEAD, so a deploy
#     that reports SUCCESS without moving the box off its pre-deploy sha is
#     distinguishable from one that advances — the script's own claims (STATE,
#     slot stamp, HEALTHY line) are cross-checked against the box's actual HEAD
#   - the slot sha stamp (D291) is written only AFTER the health gate: a build
#     that fails (exit 12/13) never stamps, a slot that already held a good
#     stamp keeps it, and --rollback is therefore never offered a sha the slot
#     never successfully built
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

# Replays api/start.sh's committed name-encoding guard in a clean shell, so the
# start.sh half of the pin is asserted BEHAVIOURALLY (what LANG ends up as) and
# not by grepping for a line. $1 is an operator-supplied LANG; '' means unset.
start_sh_locale_guard() {
  local guard body
  guard="$(awk '/name-encoding pin \(start\)/,/name-encoding pin \(end\)/' "$HERE/../api/start.sh")"
  body="$guard"$'\n''printf %s "${LANG:-}"'
  if [ -n "$1" ]; then
    LANG="$1" bash -c "unset LC_ALL
$body"
  else
    bash -c "unset LANG LC_ALL
$body"
  fi
}

# Same shape as the Node engine's outer skip: without caddy NOT ONE case below
# runs, and this used to exit 0 — which every caller reads as "the instance
# deploy harness passed", including the CI step that runs it bare. The blue/green
# proofs this file owns (the post-flip public gate, the fail-closed rollback, the
# slot-sha ordering) are exactly the ones nobody would notice going missing.
# CI installs caddy in a dedicated step and asserts a version floor, so this
# should never fire there — but "should never fire" is not a reason to exit 0
# when it does. CI=true makes the harness self-defending under any workflow,
# including one that does not set the REQUIRE flag.
if ! command -v caddy >/dev/null 2>&1; then
  if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ] || [ "${CI:-}" = "true" ]; then
    echo "1 FAILURE(S): this harness is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1 or CI=true) but the caddy binary is missing from PATH — every case below needs REAL caddy validation, so none of them ran; a harness that ran nothing must not exit 0"
    exit 1
  fi
  echo "SKIP: caddy binary required (real validation) — nothing was proven, so this run reports no verdict"
  exit 0
fi

make_fakes() {
  local dir="$1"; mkdir -p "$dir"
  cat > "$dir/git" <<'EOF'
#!/usr/bin/env bash
# Fake git: record the invocation, honor refs. Skip leading -c KV / -C PATH
# option pairs to find the subcommand (the script calls e.g.
# `git -c core.hooksPath=/dev/null fetch origin <ref>`).
#
# STATEFUL HEAD (D292). This used to answer every `rev-parse` with one per-run
# CONSTANT, which made an ADVANCING deploy and a STALLED one byte-identical:
# both exited 0, both logged HEALTHY, both wrote the state file — so a harness
# assert of the form `[ current != target ]` was false in BOTH and no case here
# could ever fail on advance. The box's HEAD now lives in $GITSTATE/head.sha and
# the remote's offer in $GITSTATE/fetch_head:
#   fetch <remote> <ref>      -> fetch_head := $REMOTE_SHA (defaults to FAKE_SHA)
#   reset --hard FETCH_HEAD   -> head.sha  := fetch_head   (the advance)
#   reset --hard <sha>        -> head.sha  := <sha>        (rollback / failure reset)
#   rev-parse [--short] HEAD  -> head.sha  (truncated for --short)
#   merge-base --is-ancestor  -> 0 (no divergence warning)
# With $GITSTATE unset the old constant behaviour is kept, so any other caller
# of make_fakes is unaffected.
[ -n "${GITLOG:-}" ] && echo "git $*" >> "$GITLOG"
args=("$@"); i=0; sub=""
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -c|-C) i=$((i + 2)); continue ;;
    *) sub="${args[$i]}"; break ;;
  esac
done
if [ -z "${GITSTATE:-}" ]; then
  [ "$sub" = "rev-parse" ] && { echo "${FAKE_SHA:-deadbeef}"; exit 0; }
  exit 0
fi
mkdir -p "$GITSTATE"
case "$sub" in
  fetch)
    printf '%s' "${REMOTE_SHA:-${FAKE_SHA:-deadbeef}}" > "$GITSTATE/fetch_head"
    ;;
  reset)
    ref=""; k=0
    while [ "$k" -lt "${#args[@]}" ]; do
      [ "${args[$k]}" = "--hard" ] && { ref="${args[$((k + 1))]:-}"; break; }
      k=$((k + 1))
    done
    if [ "$ref" = "FETCH_HEAD" ]; then
      [ -f "$GITSTATE/fetch_head" ] && cp "$GITSTATE/fetch_head" "$GITSTATE/head.sha"
    elif [ -n "$ref" ]; then
      printf '%s' "$ref" > "$GITSTATE/head.sha"
    fi
    ;;
  rev-parse)
    head="$(cat "$GITSTATE/head.sha" 2>/dev/null || true)"
    [ -z "$head" ] && head="${FAKE_SHA:-deadbeef}"
    for a in "$@"; do
      [ "$a" = "--short" ] && head="$(printf '%s' "$head" | cut -c1-7)"
    done
    echo "$head"
    ;;
esac
exit 0
EOF
  cat > "$dir/mix" <<'EOF'
#!/usr/bin/env bash
echo "mix $* [MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-}]" >> "$MIXLOG"
# MIX_FAIL=<subcommand> fails exactly that step (e.g. compile -> exit 12,
# ecto.migrate -> exit 13): the build-failure half of the slot-stamp ordering.
[ -n "${MIX_FAIL:-}" ] && [ "$1" = "${MIX_FAIL}" ] && exit 1
if [ "$1" = "compile" ]; then
  mkdir -p "${MIX_BUILD_ROOT:-_build}/prod"
  echo built > "${MIX_BUILD_ROOT:-_build}/prod/MARKER"
fi
exit 0
EOF
  cat > "$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSCTLLOG"
# `is-active <unit>` answers the connectors health gate; UNIT_ACTIVE=failed
# simulates a bridge that boots and immediately dies (crash-loop).
[ "${1:-}" = "is-active" ] && echo "${UNIT_ACTIVE:-active}"
exit 0
EOF
  cat > "$dir/install" <<'EOF'
#!/usr/bin/env bash
echo "install $*" >> "$SYSCTLLOG"; exit 0
EOF
  # URL-aware: the connectors health probe (:4020) answers with its OWN code, so
  # a healthy app slot and a silent bridge can be simulated in the same run.
  # The PUBLIC post-flip probe (--resolve HOST:443:..., https://HOST/...) also
  # answers with its OWN code (PUBLIC_HEALTH_CODE, defaulting to HEALTH_CODE) —
  # so a slot that boots healthy on its OWN port (pre-flip, plain
  # http://localhost:$PORT) can still be driven to fail the PUBLIC post-flip
  # gate (pds-bl-w49: that curl used to be captured, logged, and ignored).
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *:4020*) printf '%s' "${CONNECTORS_HEALTH_CODE:-000}"; exit 0 ;; esac
done
for a in "$@"; do
  case "$a" in --resolve) printf '%s' "${PUBLIC_HEALTH_CODE:-${HEALTH_CODE:-200}}"; exit 0 ;; esac
done
printf '%s' "${HEALTH_CODE:-200}"
EOF
  # Fake asdf: `asdf where nodejs` locates the node install below.
  # NODE_MISSING=1 makes it fail (box without an asdf nodejs).
  cat > "$dir/asdf" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "where" ]; then
  [ -n "${NODE_MISSING:-}" ] && exit 1
  echo "$HOME/.asdf/installs/nodejs/26.5.0"
  exit 0
fi
exit 0
EOF
  # A bare asdf SHIM on PATH: exits non-zero exactly like the real box's
  # `node -v` (=> "command not found"/no version set). resolve_node_bin MUST
  # reject it rather than point the unit at a binary that cannot run.
  printf '#!/usr/bin/env bash\nexit 126\n' > "$dir/node"
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
  # The asdf-managed node the box actually has (bare `node` is NOT on its PATH).
  # resolve_node_bin must find THIS one, via `asdf where nodejs`.
  NODEDIR="$TMP/home/.asdf/installs/nodejs/26.5.0/bin"; mkdir -p "$NODEDIR"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo v26.5.0; exit 0; }\nexit 0\n' > "$NODEDIR/node"
  # Fake npm: records the call, and `npm ci` materializes the tsx runner the
  # install guard demands. NPM_FAIL=1 fails the install; NPM_NO_TSX=1 installs
  # deps WITHOUT tsx (a --omit=dev regression) — the guard must catch both.
  cat > "$NODEDIR/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$SYSCTLLOG"
[ -n "${NPM_FAIL:-}" ] && exit 1
if [ "${1:-}" = "ci" ] && [ -z "${NPM_NO_TSX:-}" ]; then
  mkdir -p node_modules/tsx/dist && : > node_modules/tsx/dist/cli.mjs
fi
exit 0
EOF
  chmod +x "$NODEDIR"/*
  APP="$TMP/app"; mkdir -p "$APP/api" "$APP/deploy/systemd" "$APP/connectors" "$APP/scripts/connectors"
  # The Cloud sandbox runner source the deploy installs onto PATH (D265). A
  # distinctive body so the Case-15 cmp is meaningful (a stale/wrong copy would
  # differ). The env-node shebang is deliberately present — the whole point of the
  # wrapper is that we never rely on it.
  printf '#!/usr/bin/env node\n// fake cloud-sandbox-runner (harness source, %s)\nprocess.exit(0)\n' "$RANDOM" > "$APP/scripts/connectors/cloud-sandbox-runner.mjs"
  chmod 0755 "$APP/scripts/connectors/cloud-sandbox-runner.mjs"
  printf 'BARKPARK_KEK=x\nBARKPARK_CLOAK_KEY=y\nPREVIEW_JWT_SECRET=z\nBARKPARK_RELEASE_CAPTURE_HMAC_SECRET=h\nDATABASE_URL=postgres://bp:pw@localhost/bp\n' > "$APP/.env"
  cp "$HERE/systemd/barkpark-slot@.service" "$APP/deploy/systemd/"
  cp "$HERE/systemd/barkpark-mcp.service" "$APP/deploy/systemd/"
  cp "$HERE/systemd/barkpark-connectors.service" "$APP/deploy/systemd/"
  # The post-deploy /mcp reachability smoke lives in the CHECKOUT (the workflow
  # scp's only instance-deploy.sh; everything else the deploy runs it reads from
  # $APP after the pull), so stage it exactly where the box would find it.
  cp "$HERE/mcp-reachability-smoke.sh" "$APP/deploy/"
  CADDY="$TMP/Caddyfile"
  printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$CADDY"
  # The fake git's HEAD/FETCH_HEAD store — per case, so cases never bleed.
  GITSTATE="$TMP/gitstate"; mkdir -p "$GITSTATE"
  export MIXLOG="$TMP/mix.log" SYSCTLLOG="$TMP/sysctl.log" GITLOG="$TMP/git.log" GITSTATE
  : > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
}

run_deploy() { # $1=health code  $2=fake sha  (DEPLOY_REF/DEPLOY_REMOTE/GO_*/NODE_*/NPM_*/UNIT_ACTIVE/PUBLIC_HEALTH_CODE from env)
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    BARKPARK_CADDYFILE_LOCK="$TMP/caddyfile.lock" \
    BARKPARK_MCP_ENV_FILE="$TMP/mcp.env" \
    BARKPARK_CONNECTORS_ENV_FILE="$TMP/connectors.env" \
    BARKPARK_NODE_LINK="$TMP/barkpark-node" \
    BARKPARK_SANDBOX_RUNNER_BIN="$TMP/cloud-sandbox-runner" \
    BARKPARK_SANDBOX_RUNNER_MJS="$TMP/cloud-sandbox-runner.mjs" \
    HOME="$TMP/home" FAKE_SHA="$2" HEALTH_CODE="$1" \
    PUBLIC_HEALTH_CODE="${PUBLIC_HEALTH_CODE:-$1}" \
    REMOTE_SHA="${REMOTE_SHA:-$2}" MIX_FAIL="${MIX_FAIL:-}" \
    BARKPARK_CLOUD_EGRESS_IPS="${BARKPARK_CLOUD_EGRESS_IPS:-}" \
    DEPLOY_REF="${DEPLOY_REF:-}" DEPLOY_REMOTE="${DEPLOY_REMOTE:-}" \
    GO_HTTP="${GO_HTTP:-}" GO_FAIL="${GO_FAIL:-}" \
    NODE_MISSING="${NODE_MISSING:-}" NPM_FAIL="${NPM_FAIL:-}" NPM_NO_TSX="${NPM_NO_TSX:-}" \
    UNIT_ACTIVE="${UNIT_ACTIVE:-active}" CONNECTORS_HEALTH_CODE="${CONNECTORS_HEALTH_CODE:-000}" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
  echo $?
}
run_rollback() { # $1=health code  $2=fake sha (live HEAD)
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    PUBLIC_HEALTH_CODE="${PUBLIC_HEALTH_CODE:-$1}" \
    BARKPARK_CADDYFILE_LOCK="$TMP/caddyfile.lock" \
    HOME="$TMP/home" FAKE_SHA="$2" HEALTH_CODE="$1" \
    bash "$SCRIPT" --rollback > "$TMP/rollback.log" 2>&1
  echo $?
}
run_preflight() { # $1=fake sha (live HEAD); stdout kept for TARGET_* asserts
  env PATH="$FAKE:$PATH" \
    BARKPARK_APP_DIR="$APP" BARKPARK_DEPLOY_LOCK="$TMP/lock" \
    BARKPARK_CADDYFILE="$CADDY" BARKPARK_HEALTH_HOST=test.example \
    BARKPARK_CADDYFILE_LOCK="$TMP/caddyfile.lock" \
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
check "connectors route armed once"       "[ \"\$(grep -c 'BARKPARK_CONNECTORS_ROUTE' '$CADDY')\" = '1' ]"
check "connectors route proxies :4020, exactly one line" "[ \"\$(grep -c 'localhost:4020' '$CADDY')\" = '1' ]"
check "connectors matcher covers /connectors and its subtree" "grep -q '@barkpark_connectors path /connectors /connectors/\*' '$CADDY'"
check "connectors handle sits before the bare slot proxy" "[ \"\$(grep -n 'handle @barkpark_connectors' '$CADDY' | head -1 | cut -d: -f1)\" -lt \"\$(grep -nE 'reverse_proxy localhost:400[01]' '$CADDY' | head -1 | cut -d: -f1)\" ]"
check "flip sed left :4020 untouched"     "grep -q 'reverse_proxy localhost:4020' '$CADDY'"
# COPY, not symlink (ProtectHome slots 203/EXEC on a /root symlink — the bug
# this test used to ENSHRINE): assert a regular file, byte-equal to the
# resolved node, and executable.
check "node resolved via asdf, COPIED (not a symlink)" "[ ! -L '$TMP/barkpark-node' ] && [ -f '$TMP/barkpark-node' ] && cmp -s '$TMP/barkpark-node' '$TMP/home/.asdf/installs/nodejs/26.5.0/bin/node' && [ -x '$TMP/barkpark-node' ]"
check "npm ci ran in the connectors dir"  "grep -q '^npm ci' '$SYSCTLLOG' && [ -f '$APP/connectors/node_modules/tsx/dist/cli.mjs' ]"
check "connectors unit installed"         "grep -q 'barkpark-connectors.service /etc/systemd/system/barkpark-connectors.service' '$SYSCTLLOG'"
check "connectors unit enabled + restarted" "grep -q 'systemctl enable barkpark-connectors' '$SYSCTLLOG' && grep -q 'systemctl restart barkpark-connectors' '$SYSCTLLOG'"
check "connectors unit health-gated on is-active" "grep -q 'systemctl is-active barkpark-connectors' '$SYSCTLLOG'"
check "active bridge stays enabled"       "! grep -q 'disable --now barkpark-connectors' '$SYSCTLLOG'"
# GNU stat FIRST, BSD second — never the reverse. On Linux `stat -f` is a
# *filesystem* stat: it SUCCEEDS on a file and prints something that is not a
# mode, so a `stat -f ... || stat -c ...` fallback never reaches the GNU form
# and silently compares garbage to '600'. `stat -c` fails cleanly on macOS
# (illegal option), so probing it first is the only ordering that works on both.
# Post-deploy /mcp reachability smoke (deploy/mcp-reachability-smoke.sh),
# ADVISORY. The fake curl answers every URL with HEALTH_CODE=200 and writes no
# body, so three of the four legs are legitimately RED in this run — which is
# precisely the case worth pinning: the deploy must PRINT all four verdicts with
# the code each leg saw and STILL exit 0. A smoke wired in fatally would turn a
# stopped barkpark-mcp (guerrilla's state whenever that unit is down) into a
# failed deploy of an app that is serving fine.
check "post-deploy /mcp smoke ran"        "grep -q 'post-deploy /mcp reachability smoke' '$TMP/out.log'"
check "smoke printed all four leg verdicts" "[ \"\$(grep -c 'mcp-smoke: LEG' '$TMP/out.log')\" = '4' ]"
check "every verdict carries the HTTP code it saw, never a bare pass/fail" "[ \"\$(grep -c 'mcp-smoke: LEG .*-> HTTP [0-9][0-9][0-9] ' '$TMP/out.log')\" = '4' ]"
check "red legs are ADVISORY (WARN logged, deploy still exit 0)" "grep -q 'WARN: /mcp reachability smoke has RED leg' '$TMP/out.log' && [ '$rc' = '0' ]"
check "connectors.env is 0600 (holds real secrets)" "[ \"\$(stat -c '%a' '$TMP/connectors.env' 2>/dev/null || stat -f '%Lp' '$TMP/connectors.env')\" = '600' ]"
check "connectors.env pins the STABLE public front" "grep -q '^BARKPARK_API_URL=https://test.example\$' '$TMP/connectors.env'"
check "connectors.env carries the loopback listen addr" "grep -q '^CONNECTORS_HTTP_ADDR=127.0.0.1:4020\$' '$TMP/connectors.env'"
check "connectors.env carries the path prefix" "grep -q '^CONNECTORS_PATH_PREFIX=/connectors\$' '$TMP/connectors.env'"
check "connectors.env sources DATABASE_URL from .env" "grep -q '^DATABASE_URL=postgres://bp:pw@localhost/bp\$' '$TMP/connectors.env'"
check "connectors.env carries a NON-EMPTY credential key" "grep -qE '^CONNECTORS_CREDENTIAL_KEY=.+\$' '$TMP/connectors.env'"
check "credential key persisted in .env (stable across deploys)" "grep -q '^CONNECTORS_CREDENTIAL_KEY=' '$APP/.env'"
check "connectors.env NEVER carries a chat token (the multi-tenant hole)" "! grep -qi 'chat_token\|BARKPARK_CHAT_TOKEN' '$TMP/connectors.env'"
check "connectors.env holds no bare operator token line" "! grep -qiE '^[A-Z_]*TOKEN=' '$TMP/connectors.env'"
check "committed unit holds NO token env line" "! grep -qiE '^(Environment|ExecStart).*TOKEN' '$HERE/systemd/barkpark-connectors.service'"
check "committed unit is PLAIN (never the slot@ template)" "! grep -q '%i' '$HERE/systemd/barkpark-connectors.service'"
check "committed unit ExecStart uses the deploy-resolved node link" "grep -q '^ExecStart=/usr/local/bin/barkpark-node ' '$HERE/systemd/barkpark-connectors.service'"
check "committed unit hardcodes NO node version" "! grep -qE 'ExecStart=.*(asdf|nodejs/[0-9])' '$HERE/systemd/barkpark-connectors.service'"
# NAME-ENCODING PIN. The live box runs utf8 only because /etc/default/locale
# leaks LANG through systemd's MANAGER environment — strip it and the same erl
# reports latin1 with the VM warning it may malfunction, so a fresh image boots
# latin1. Both reachable paths are asserted: the slot unit (the service) and
# api/start.sh (a manual `mix` invocation). The ordering row matters — an
# Environment= placed AFTER EnvironmentFile= would stop a per-slot env file from
# overriding it. start.sh is asserted behaviourally, by replaying its guard.
check "committed slot unit pins a UTF-8 name-encoding locale" "grep -qE '^Environment=(LANG|LC_ALL)=(C|[A-Za-z_]+)\.(UTF-8|utf8)\$' '$HERE/systemd/barkpark-slot@.service'"
check "committed slot unit pins it BEFORE EnvironmentFile (slot env can still override)" "[ \"\$(grep -n '^Environment=' '$HERE/systemd/barkpark-slot@.service' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^EnvironmentFile=' '$HERE/systemd/barkpark-slot@.service' | head -1 | cut -d: -f1)\" ]"
check "committed slot unit records WHY (host-image accident, not a staging fix)" "grep -q 'host-image accident' '$HERE/systemd/barkpark-slot@.service' && grep -q 'NOT A STAGING FIX' '$HERE/systemd/barkpark-slot@.service'"
check "start.sh guard defaults the name mode to UTF-8 (fresh image, no locale)" "[ \"\$(start_sh_locale_guard '')\" = 'C.UTF-8' ]"
check "start.sh guard does NOT clobber an operator-supplied LANG" "[ \"\$(start_sh_locale_guard 'en_US.UTF-8')\" = 'en_US.UTF-8' ]"
check "start.sh records the measurement trap (Elixir readback measures the decoder)" "grep -q 'MEASUREMENT TRAP' '$HERE/../api/start.sh' && grep -q 'shell find/od' '$HERE/../api/start.sh'"
check "old slot + legacy unit retired"    "grep -q 'disable --now barkpark-slot@blue' '$SYSCTLLOG' && grep -q 'disable --now barkpark' '$SYSCTLLOG'"
check "green slot enabled (reboot-safe)"  "grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "state file = newsha"               "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'newsha' ]"
check "per-slot sha stamp written (W6)"   "[ \"\$(cat '$APP/.slots/green.sha' 2>/dev/null)\" = 'newsha' ]"
check "idle slot has no stamp yet"        "[ ! -e '$APP/.slots/blue.sha' ]"
check "prod channel: fetch origin main"           "grep -q 'fetch origin main' '$GITLOG'"
check "prod channel: hard reset to FETCH_HEAD (divergence-proof)" "grep -q 'reset --hard FETCH_HEAD' '$GITLOG'"
check "prod channel: NO ff-only pull (jams on divergence)" "! grep -q 'pull --ff-only' '$GITLOG'"

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
check "no double connectors arm (idempotent)" "[ \"\$(grep -c 'BARKPARK_CONNECTORS_ROUTE' '$CADDY')\" = '1' ]"
check "second flip sed left :4010 untouched" "[ \"\$(grep -c 'localhost:4010' '$CADDY')\" = '1' ]"
check "second flip sed left :4020 untouched" "[ \"\$(grep -c 'localhost:4020' '$CADDY')\" = '1' ]"
check "credential key NOT regenerated on redeploy" "[ \"\$(grep -c '^CONNECTORS_CREDENTIAL_KEY=' '$APP/.env')\" = '1' ]"
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

echo "== Case 3b: slot healthy on its OWN port but the PUBLIC post-flip probe fails -> flip REVERTED (pds-bl-w49) =="
# ROOT CAUSE this guards: the flip's public health curl used to be captured
# into \$code, logged, and never tested — a broken flip (bad Caddyfile sed,
# stale reload, SNI/TLS misroute on the public host) still exited 0 and the
# deploy reported success. The pre-flip own-port loop (localhost:$TARGET_PORT)
# passes here (HEALTH_CODE=200) — only the PUBLIC probe
# (https://test.example/api/schemas) is made to fail, so this proves the gate
# added AFTER the flip, not the pre-existing boot gate before it.
setup_case
rc="$(PUBLIC_HEALTH_CODE=500 run_deploy 200 postflipbadsha)"
check "exit 14 (not 0 — a broken flip must not report success)" "[ '$rc' = '14' ]"
check "post-flip failure logged by name" "grep -q 'post-flip public health check FAILED' '$TMP/out.log'"
check "Caddy flipped BACK to :4000 (not left on the unproven :4001)" "[ \"\$(first_upstream)\" = 'localhost:4000' ]"
check "reverted Caddyfile still caddy-valid" "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
check "unproven green slot disabled"      "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
check "active blue slot never stopped/disabled" "! grep -qE '(stop|disable --now) barkpark-slot@blue' '$SYSCTLLOG'"
check "legacy unit not touched on this failure" "! grep -qE 'disable --now barkpark($| )' '$SYSCTLLOG'"
check "no enable of the unproven slot"    "! grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "state file NOT advanced"           "[ ! -f '$APP/.instance-deploy-last' ]"
check "slot sha stamp NOT left claiming an unproven build" "[ ! -e '$APP/.slots/green.sha' ]"
check "checkout reset --hard ran on the failure path" "grep -q 'reset --hard' '$GITLOG'"
rm -rf "$TMP"

echo "== Case 3c: the flip sed matches NOTHING -> refused, the live slot is never retired =="
# ROOT CAUSE this guards: the post-flip PUBLIC gate above claims to catch "a sed
# that missed the live upstream line". It CANNOT. Both slots serve
# /api/schemas, so when the flip is a no-op the OLD slot answers the public
# probe 200 through the UNCHANGED Caddyfile and the gate passes -- and the very
# next thing the script does is disable that old slot, leaving Caddy proxying a
# dead port. A Caddyfile whose upstream is spelled 127.0.0.1:<port> (no literal
# 'localhost:<slot port>' token) is invisible to the ACTIVE_PORT grep, the
# FLIP_FROM re-read AND the flip sed, so the file comes out byte-identical and
# every downstream check still says healthy. Only the file itself can see this.
setup_case
printf 'guerrilla.barkpark.cloud {\n\treverse_proxy 127.0.0.1:4000\n}\n' > "$CADDY"
rc="$(run_deploy 200 noopflipsha)"
check "exit 14 (not 0 -- a flip that never landed must not report success)" "[ '$rc' = '14' ]"
check "the no-op flip is named in the log"   "grep -q 'FLIP DID NOT LAND' '$TMP/out.log'"
check "Caddyfile upstream untouched"         "grep -q 'reverse_proxy 127.0.0.1:4000' '$CADDY'"
check "the LIVE slot was NEVER disabled"     "! grep -qE 'disable --now barkpark-slot@blue' '$SYSCTLLOG'"
check "the unproven green slot disabled"     "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
check "no enable of the unproven slot"       "! grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "state file NOT advanced"              "[ ! -f '$APP/.instance-deploy-last' ]"
check "slot sha stamp NOT left claiming an unproven build" "[ ! -e '$APP/.slots/green.sha' ]"
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

echo "== Case 5: production box, default ref -> fetch origin main + hard reset (divergence-proof) =="
setup_case
rc="$(run_deploy 200 defaultsha)"   # DEPLOY_REF unset -> main
check "exit 0"                            "[ '$rc' = '0' ]"
check "fetch origin main"                 "grep -q 'fetch origin main' '$GITLOG'"
check "hard reset to FETCH_HEAD"          "grep -q 'reset --hard FETCH_HEAD' '$GITLOG'"
check "NO ff-only pull (would jam on a divergent box HEAD)" "! grep -q 'pull --ff-only' '$GITLOG'"
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
check "rollback flip sed left :4020 untouched" "[ \"\$(grep -c 'localhost:4020' '$CADDY')\" = '1' ]"
check "rolled-back Caddyfile caddy-valid" "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
check "STATE rewritten to rolled-back sha" "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'v1sha' ]"
check "rolled-back slot enabled (reboot-safe)" "grep -q 'enable barkpark-slot@green' '$SYSCTLLOG'"
check "rolled-away slot retired"          "grep -q 'disable --now barkpark-slot@blue' '$SYSCTLLOG'"
check "no rebuild during rollback"        "[ \"\$(grep -c compile '$MIXLOG')\" = '0' ]"
rm -rf "$TMP"

echo "== Case 9b: a rollback flip that matches NOTHING is refused, live slot kept =="
# The rollback path's own post-flip curl is deliberately log-only (its pre-flip
# own-port loop is the gate), so a no-op rewrite here has NOTHING downstream to
# catch it: without the landed-check it logged ROLLED BACK, rewrote STATE,
# exited 0 -- and then disabled the slot Caddy was still pointing at.
setup_case
run_deploy 200 v1sha >/dev/null           # green live :4001
run_deploy 200 v2sha >/dev/null           # blue live  :4000
: > "$SYSCTLLOG"; : > "$GITLOG"
# Make the live upstream invisible to the grep AND to the sed, without touching
# the armed /mcp and /connectors routes.
sed -i.bak 's/reverse_proxy localhost:4000/reverse_proxy 127.0.0.1:4000/' "$CADDY" && rm -f "$CADDY.bak"
rc="$(run_rollback 200 v2sha)"
check "rollback exit 24 (not 0)"             "[ '$rc' = '24' ]"
check "the no-op flip is named in the log"   "grep -q 'FLIP DID NOT LAND' '$TMP/rollback.log'"
check "no ROLLED BACK claim"                 "! grep -q 'ROLLED BACK' '$TMP/rollback.log'"
check "Caddyfile upstream untouched"         "grep -q 'reverse_proxy 127.0.0.1:4000' '$CADDY'"
check "the LIVE blue slot was NEVER disabled" "! grep -qE 'disable --now barkpark-slot@blue' '$SYSCTLLOG'"
check "the rollback target slot re-disabled" "grep -q 'disable --now barkpark-slot@green' '$SYSCTLLOG'"
check "checkout reset back to the live sha"  "grep -q 'reset --hard v2sha' '$GITLOG'"
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
# task-1a641b21d19595d3 — the deploy step must READ the unit after the restart,
# not trust `systemctl restart`'s exit (Type=simple: it returns on fork).
check "mcp step re-reads is-active after the restart" "grep -q 'systemctl is-active barkpark-mcp' '$SYSCTLLOG'"
check "mcp step reports the unit ACTIVE by its own state" "grep -q 'barkpark-mcp active after' '$TMP/out.log'"
check "mcp step never claims 'enabled' off restart alone" "! grep -q 'barkpark-mcp enabled (' '$TMP/out.log'"
# The committed unit carries a START LIMIT: a serve that fails on every start
# stops after the burst instead of restarting every 10 s forever.
check "committed unit declares StartLimitIntervalSec" "grep -qE '^StartLimitIntervalSec=[0-9]+' '$HERE/systemd/barkpark-mcp.service'"
check "committed unit declares StartLimitBurst"       "grep -qE '^StartLimitBurst=[0-9]+' '$HERE/systemd/barkpark-mcp.service'"
check "start limit sits in [Unit] (systemd ignores it in [Service])" "awk '/^\\[Unit\\]/{u=1} /^\\[Service\\]/{u=0} u && /^StartLimit(IntervalSec|Burst)=/{n++} END{exit n==2?0:1}' '$HERE/systemd/barkpark-mcp.service'"
: > "$SYSCTLLOG"
rm -f "$TMP/mcp.env" "$APP/.instance-deploy-last"   # force a re-run; the unit now DIES after the restart
rc="$(GO_HTTP=1 UNIT_ACTIVE=failed run_deploy 200 mcpsha3)"
check "crash-looping mcp unit: deploy still exit 0 (non-fatal)" "[ '$rc' = '0' ]"
check "crash-looping mcp unit: named in the deploy log as NOT active" "grep -q 'WARN: barkpark-mcp is NOT active after' '$TMP/out.log'"
check "crash-looping mcp unit: state word carried (failed)" "grep -q 'state=failed' '$TMP/out.log'"
: > "$SYSCTLLOG"
rm -f "$TMP/mcp.env" "$APP/.instance-deploy-last"   # force a re-run; build now FAILS
rc="$(GO_FAIL=1 run_deploy 200 mcpsha2)"
check "go build failure: deploy still exit 0 (non-fatal)" "[ '$rc' = '0' ]"
check "go build failure: unit NOT enabled" "! grep -q 'enable barkpark-mcp' '$SYSCTLLOG'"
check "go build failure: no mcp.env written" "[ ! -f '$TMP/mcp.env' ]"
rm -rf "$TMP"

echo "== Case 12: barkpark-connectors install guard — node / npm / tsx / crash-loop =="
setup_case
# (a) no usable node: asdf has no nodejs and the bare `node` on PATH is a shim
# that cannot run. The unit must NOT be installed and the deploy must still pass.
rm -rf "$TMP/home/.asdf/installs"
rc="$(NODE_MISSING=1 run_deploy 200 nonodesha)"
check "no node: deploy still exit 0 (non-fatal)"  "[ '$rc' = '0' ]"
check "no node: unit NOT enabled"                 "! grep -q 'enable barkpark-connectors' '$SYSCTLLOG'"
check "no node: no connectors.env written"        "[ ! -f '$TMP/connectors.env' ]"
check "no node: refused honestly in the log"      "grep -q 'no usable node' '$TMP/out.log'"
check "no node: route STILL armed (upstream just dead -> maintenance 503)" "[ \"\$(grep -c 'BARKPARK_CONNECTORS_ROUTE' '$CADDY')\" = '1' ]"
rm -rf "$TMP"

# (b) npm ci fails: no unit, no env file, deploy survives.
setup_case
rc="$(NPM_FAIL=1 run_deploy 200 npmfailsha)"
check "npm ci failure: deploy still exit 0"       "[ '$rc' = '0' ]"
check "npm ci failure: unit NOT enabled"          "! grep -q 'enable barkpark-connectors' '$SYSCTLLOG'"
check "npm ci failure: no connectors.env written" "[ ! -f '$TMP/connectors.env' ]"
check "npm ci failure logged honestly"            "grep -q 'npm ci failed' '$TMP/out.log'"
rm -rf "$TMP"

# (c) deps installed but no tsx runner (an --omit=dev regression): the unit's
# ExecStart would point at a missing file, so the guard must refuse.
setup_case
rc="$(NPM_NO_TSX=1 run_deploy 200 notsxsha)"
check "no tsx runner: deploy still exit 0"        "[ '$rc' = '0' ]"
check "no tsx runner: unit NOT enabled"           "! grep -q 'enable barkpark-connectors' '$SYSCTLLOG'"
check "no tsx runner: refused honestly"           "grep -q 'no tsx runner' '$TMP/out.log'"
rm -rf "$TMP"

# (d) the bridge boots and immediately dies (missing config): systemd would
# Restart=on-failure it forever, so the deploy DISABLES it again and says so.
setup_case
rc="$(UNIT_ACTIVE=failed run_deploy 200 crashsha)"
check "crash-looping bridge: deploy still exit 0" "[ '$rc' = '0' ]"
check "crash-looping bridge: unit disabled again" "grep -q 'disable --now barkpark-connectors' '$SYSCTLLOG'"
check "crash-looping bridge: named honestly"      "grep -q 'did not stay active' '$TMP/out.log'"
check "crash-looping bridge: app slot still flipped (:4001)" "[ \"\$(first_upstream)\" = 'localhost:4001' ]"
rm -rf "$TMP"

# (e) healthy bridge WITH an HTTP surface: the health probe is log-only, and a
# 200 on the path prefix is what the post-merge live check asks for.
setup_case
rc="$(CONNECTORS_HEALTH_CODE=200 run_deploy 200 healthsha)"
check "healthy bridge: exit 0"                    "[ '$rc' = '0' ]"
check "healthy bridge: unit stays enabled"        "grep -q 'systemctl enable barkpark-connectors' '$SYSCTLLOG' && ! grep -q 'disable --now barkpark-connectors' '$SYSCTLLOG'"
check "healthy bridge: health probe logged 200"   "grep -q '/connectors/health = 200' '$TMP/out.log'"
rm -rf "$TMP"

echo "== Case 13: the shared Caddyfile lock (site-spawner D27) — a concurrent site-deploy cannot lose the port flip =="
# THE RACE, reproduced against the REAL scripts. $CADDYFILE has two writers:
# this script's blue/green port flip and site-deploy.sh's /sites/<slug>/ route
# arming. Both do read -> backup -> rewrite -> mv. If site-deploy READS before
# our flip lands and WRITES after it, its stale write silently discards the flip
# — and then reloads Caddy onto the slot we are about to `disable --now`: a hard
# 502 on the content API. `caddy validate` passes in BOTH processes, because a
# lost update is syntactically VALID config — which is why the backup/validate/
# revert discipline both scripts already had could never catch this.
#
# Determinism: a slow-awk shim makes site-deploy read the Caddyfile NOW, touch a
# sentinel, and write 6s LATER. The test waits for the sentinel, then runs the
# deploy — so the interleave is forced, not raced.
# FAIL-BEFORE vs FIXED is the SAME code both times; the only difference is
# whether flock is real (fixed) or a no-op stub (locking defeated = the old
# behaviour). Needs a real flock(1) — absent on macOS.
if ! command -v flock >/dev/null 2>&1; then
  echo "  SKIP: flock(1) required (absent on macOS) — run this case on Linux/CI"
elif ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 required (site-deploy's throwaway health server)"
else
  race_setup() {
    setup_case
    run_deploy 200 racebase >/dev/null     # arms maintenance/mcp/connectors, flips :4000 -> :4001
    rm -f "$APP/.instance-deploy-last"     # so the racing deploy is not coalesced away
    # A staged, healthy site release: site-deploy takes its SKIP_BUILD path (no
    # npm) and goes PLAN -> HEALTH -> arm -> SWITCH.
    SITES="$TMP/sites"; mkdir -p "$SITES/racesite/releases/r1"
    printf '<meta name="bp-build-id" content="r1"><meta name="bp-content-rev" content="rev1"><meta name="bp-doc-id" content="doc1">' \
      > "$SITES/racesite/releases/r1/index.html"
    SENT="$TMP/site-read-done"; rm -f "$SENT"
    SLOW="$TMP/slowbin"; mkdir -p "$SLOW" "$TMP/nolock" "$TMP/empty"
    REAL_AWK="$(command -v awk)"
    # Read the input NOW, signal, sleep, THEN write: the read-early/write-late
    # half of a lost update. /bin/sleep by absolute path — a fake `sleep` on PATH
    # would make the window vanish.
    # ONLY the Caddyfile read is slowed. site-deploy also awks the SERVED html in
    # its health gate (meta_value): slowing that fired the sentinel during HEALTH,
    # long before the Caddyfile was ever read — which let both halves of this case
    # pass for the wrong reason. A green that proves nothing is worse than a red.
    cat > "$SLOW/awk" <<EOF
#!/usr/bin/env bash
slow=0
for a in "\$@"; do [ "\$a" = "$CADDY" ] && slow=1; done
[ "\$slow" = 0 ] && exec "$REAL_AWK" "\$@"
out="\$("$REAL_AWK" "\$@")"
: > "$SENT"
/bin/sleep "\${RACE_AWK_DELAY:-6}"
printf '%s\n' "\$out"
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SLOW/systemctl"   # never touch the host's caddy
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/nolock/flock" # locking DEFEATED
    chmod +x "$SLOW"/* "$TMP/nolock/flock"
  }
  # site-deploy in the background. $1 = a PATH dir prepended for lock behaviour
  # (nolock/ = stubbed flock; empty/ = the REAL flock). Everything else it needs
  # (curl, python3, perl, caddy) is real.
  run_site_arm() {
    env PATH="$1:$SLOW:$PATH" \
      SITE_SLUG=racesite BUILD_ID=r1 CONTENT_REV=rev1 \
      BARKPARK_SITES_DIR="$SITES" BARKPARK_CADDYFILE="$CADDY" \
      BARKPARK_SITE_DEPLOY_LOCK="$TMP/site.lock" \
      BARKPARK_CADDYFILE_LOCK="$TMP/caddyfile.lock" \
      bash "$HERE/site-deploy.sh" > "$TMP/site.log" 2>&1 &
  }
  await_read() { local i; for i in $(seq 1 400); do [ -f "$SENT" ] && return 0; /bin/sleep 0.05; done; return 1; }

  # --- FAIL-BEFORE: locking defeated on both sides -> the flip is LOST.
  race_setup
  run_site_arm "$TMP/nolock"; sitepid=$!            # $FAKE/flock (no-op) is still on instance-deploy's PATH
  check "fail-before: site-deploy reached its Caddyfile read" "await_read"
  rc="$(run_deploy 200 raceflip)"                   # flips :4001 -> :4000 while site-deploy sleeps
  wait "$sitepid"
  check "fail-before: instance-deploy believes it flipped (exit 0)" "[ '$rc' = '0' ]"
  check "fail-before: the port flip is LOST (upstream still :4001)" "[ \"\$(first_upstream)\" = 'localhost:4001' ]"
  check "fail-before: the lost update is still caddy-VALID (validate is blind to it)" \
    "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
  rm -rf "$TMP"

  # --- FIXED: both writers take the REAL shared lock -> both mutations survive.
  race_setup
  rm -f "$FAKE/flock"                               # instance-deploy takes the REAL lock
  run_site_arm "$TMP/empty"; sitepid=$!             # ... and so does site-deploy
  check "fixed: site-deploy reached its Caddyfile read" "await_read"
  rc="$(run_deploy 200 raceflip)"                   # must BLOCK on fd 8 until the arm completes
  wait "$sitepid"; site_rc=$?
  check "fixed: site-deploy exit 0"                 "[ '$site_rc' = '0' ]"
  check "fixed: instance-deploy exit 0"             "[ '$rc' = '0' ]"
  check "fixed: the port flip SURVIVED (upstream :4000)" "[ \"\$(first_upstream)\" = 'localhost:4000' ]"
  check "fixed: the site route SURVIVED too (neither writer lost)" "grep -q 'BARKPARK_SITE_ROUTE:racesite' '$CADDY'"
  check "fixed: the /mcp + /connectors routes survived" \
    "[ \"\$(grep -c 'localhost:4010' '$CADDY')\" = '1' ] && [ \"\$(grep -c 'localhost:4020' '$CADDY')\" = '1' ]"
  check "fixed: Caddyfile still caddy-valid"        "caddy validate --adapter caddyfile --config '$CADDY' >/dev/null 2>&1"
  check "fixed: site-deploy actually armed under the lock (it waited, nobody deadlocked)" \
    "grep -q 'armed caddy /sites/racesite route' '$TMP/site.log' || grep -q 'caddy reload failed (config valid)' '$TMP/site.log'"
  rm -rf "$TMP"
fi

echo "== Case 14: slot-env regen PRESERVES an operator-set BARKPARK_SITE_DEPLOY_APPLY (D38) =="
# The seam-enable flag lives in .slots/%i.env (read at BEAM boot via the unit's
# EnvironmentFile). The generator truncate-regenerates both env files EVERY
# deploy — before this fix the flag was silently dropped, reverting the
# site-deploy admin route to 503. Seed the flag BEFORE a deploy, prove it
# survives the regen, and prove the untouched slot does NOT get it hardcoded on.
setup_case
mkdir -p "$APP/.slots"
printf 'BARKPARK_SITE_DEPLOY_APPLY=1\n' > "$APP/.slots/green.env"   # operator opt-in, pre-deploy
rc="$(run_deploy 200 seedsha1)"                                    # blue active -> deploys green
check "exit 0"                                    "[ '$rc' = '0' ]"
check "seeded flag survives regen (green.env)"    "grep -q '^BARKPARK_SITE_DEPLOY_APPLY=1\$' '$APP/.slots/green.env'"
check "slot env files still written (regression anchor)" "grep -q 'BARKPARK_PORT_OVERRIDE=4001' '$APP/.slots/green.env' && grep -q '_build_blue' '$APP/.slots/blue.env'"
check "flag NOT hardcoded onto the unseeded slot (fail-closed)" "! grep -q 'BARKPARK_SITE_DEPLOY_APPLY' '$APP/.slots/blue.env'"
# Survives a SECOND deploy too — the one that TARGETS blue still rewrites
# green.env, the exact truncation that dropped the flag before.
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rm -f "$APP/.instance-deploy-last"
rc="$(run_deploy 200 seedsha2)"                                    # green active -> deploys blue, rewrites green.env
check "second deploy exit 0"                      "[ '$rc' = '0' ]"
check "flag still present after a full regen cycle" "grep -q '^BARKPARK_SITE_DEPLOY_APPLY=1\$' '$APP/.slots/green.env'"
check "unseeded blue slot still has no flag"      "! grep -q 'BARKPARK_SITE_DEPLOY_APPLY' '$APP/.slots/blue.env'"
rm -rf "$TMP"

echo "== Case 15: cloud-sandbox-runner install (connectors D265) — wrapper execs barkpark-node, NOT the env-node shebang =="
# NON-VACUITY (D266): file-presence alone would GREEN a shebang-only no-op (a bare
# copy of the runner, whose `#!/usr/bin/env node` line cannot resolve node on the
# live BEAM PATH). So the load-bearing check is on the wrapper CONTENT — it must
# exec /usr/local/bin/barkpark-node — plus a byte-cmp of the installed .mjs against
# the checkout source. Deleting the install lines flips EXACTLY these checks red;
# every earlier case stays green (mutation-proof captured in the wave paper).
setup_case
rc="$(run_deploy 200 runnersha)"
check "runner install: deploy exit 0 (non-fatal region)" "[ '$rc' = '0' ]"
check "runner install: wrapper present + executable"     "[ -x '$TMP/cloud-sandbox-runner' ]"
check "runner install: wrapper is a POSIX sh script"     "[ \"\$(head -1 '$TMP/cloud-sandbox-runner')\" = '#!/bin/sh' ]"
check "runner install: wrapper CONTENT execs barkpark-node (not the env-node shebang)" "grep -q '^exec /usr/local/bin/barkpark-node ' '$TMP/cloud-sandbox-runner'"
check "runner install: wrapper hands the .mjs to barkpark-node with argv passthrough" "grep -q '/usr/local/bin/cloud-sandbox-runner.mjs \"\$@\"' '$TMP/cloud-sandbox-runner'"
check "runner install: wrapper is exactly 2 lines"       "[ \"\$(wc -l < '$TMP/cloud-sandbox-runner')\" -eq 2 ]"
check "runner install: .mjs installed"                   "[ -f '$TMP/cloud-sandbox-runner.mjs' ]"
check "runner install: installed .mjs is cmp-identical to the checkout source" "cmp -s '$TMP/cloud-sandbox-runner.mjs' '$APP/scripts/connectors/cloud-sandbox-runner.mjs'"
check "runner install: success logged honestly"          "grep -q 'cloud-sandbox-runner installed' '$TMP/out.log'"
# Idempotent redeploy: a second deploy re-copies both and stays green + identical.
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rm -f "$APP/.instance-deploy-last"
rc="$(run_deploy 200 runnersha2)"
check "runner redeploy: exit 0"                          "[ '$rc' = '0' ]"
check "runner redeploy: wrapper still execs barkpark-node" "grep -q '^exec /usr/local/bin/barkpark-node ' '$TMP/cloud-sandbox-runner'"
check "runner redeploy: .mjs still cmp-identical to source" "cmp -s '$TMP/cloud-sandbox-runner.mjs' '$APP/scripts/connectors/cloud-sandbox-runner.mjs'"
check "runner redeploy: no leftover .new tmpfiles"       "[ ! -e '$TMP/cloud-sandbox-runner.new' ] && [ ! -e '$TMP/cloud-sandbox-runner.mjs.new' ]"
rm -rf "$TMP"

# Missing source: the deploy must stay green (non-fatal) and say so — never brick
# a good deploy because a checkout lacks the runner.
setup_case
rm -f "$APP/scripts/connectors/cloud-sandbox-runner.mjs"
rc="$(run_deploy 200 norunnersha)"
check "no runner source: deploy still exit 0 (non-fatal)" "[ '$rc' = '0' ]"
check "no runner source: nothing installed"               "[ ! -e '$TMP/cloud-sandbox-runner' ]"
check "no runner source: refused honestly (binary_not_found until next deploy)" "grep -q 'cloud-sandbox-runner NOT installed' '$TMP/out.log'"
rm -rf "$TMP"

echo "== Case 16: BARKPARK_TRUSTED_PROXIES backfill — the x-forwarded-for trust boundary =="
# The control plane's egress address must reach the box's .env or the caller
# address it relays is DISBELIEVED and every proxied request keys on ONE bucket per
# team (the pre-#6224 coarseness). Four states, all of them here: configured,
# already-set (never clobbered), malformed (refused — runtime.exs would raise at
# boot), absent (commented placeholder + a loud log, deploy still green).
setup_case
rc="$(BARKPARK_CLOUD_EGRESS_IPS=203.0.113.7 run_deploy 200 xffsha)"
check "configured: exit 0"                        "[ '$rc' = '0' ]"
check "configured: exact line written"            "grep -q '^BARKPARK_TRUSTED_PROXIES=203.0.113.7\$' '$APP/.env'"
check "configured: logged honestly"               "grep -q 'added BARKPARK_TRUSTED_PROXIES=203.0.113.7' '$TMP/out.log'"
check "configured: no placeholder comment"        "! grep -q '^# BARKPARK_TRUSTED_PROXIES=' '$APP/.env'"
# A second deploy must NOT duplicate or rewrite the line — provisioning may have
# written it, and an operator may trust a different front.
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rm -f "$APP/.instance-deploy-last"
rc="$(BARKPARK_CLOUD_EGRESS_IPS=198.51.100.9 run_deploy 200 xffsha2)"
check "existing line: exit 0"                     "[ '$rc' = '0' ]"
check "existing line: NEVER overwritten"          "grep -q '^BARKPARK_TRUSTED_PROXIES=203.0.113.7\$' '$APP/.env'"
check "existing line: exactly one, no duplicate"  "[ \"\$(grep -c '^BARKPARK_TRUSTED_PROXIES=' '$APP/.env')\" = '1' ]"
check "existing line: left-untouched logged"      "grep -q 'BARKPARK_TRUSTED_PROXIES already set' '$TMP/out.log'"
rm -rf "$TMP"

# Malformed: a CIDR range (the tempting wrong answer — the Elixir side REFUSES it
# because trusting a range lets any host in it forge every bucket key) and a
# hostname. Neither may be written: runtime.exs raises on a non-IP entry, so the
# write would brick the app at the slot restart later in this very run.
setup_case
rc="$(BARKPARK_CLOUD_EGRESS_IPS=10.0.0.0/8 run_deploy 200 cidrsha)"
check "CIDR: deploy still exit 0 (non-fatal)"     "[ '$rc' = '0' ]"
check "CIDR: NOT written"                         "! grep -q '^BARKPARK_TRUSTED_PROXIES=' '$APP/.env'"
check "CIDR: refused loudly"                      "grep -q 'WARN: BARKPARK_CLOUD_EGRESS_IPS' '$TMP/out.log'"
rm -rf "$TMP"
setup_case
rc="$(BARKPARK_CLOUD_EGRESS_IPS=barkpark.cloud run_deploy 200 hostsha)"
check "hostname: NOT written (runtime.exs takes IPs only)" "! grep -q '^BARKPARK_TRUSTED_PROXIES=' '$APP/.env'"
check "hostname: refused loudly"                  "grep -q 'WARN: BARKPARK_CLOUD_EGRESS_IPS' '$TMP/out.log'"
rm -rf "$TMP"
# A mixed list must be refused WHOLE — one good hop does not license a bad one.
setup_case
rc="$(BARKPARK_CLOUD_EGRESS_IPS='203.0.113.7,notanip' run_deploy 200 mixedsha)"
check "mixed list: refused whole (no partial write)" "! grep -q '^BARKPARK_TRUSTED_PROXIES=' '$APP/.env'"
rm -rf "$TMP"
# A valid v4+v6 pair IS accepted (a CP that reaches instances over both).
setup_case
rc="$(BARKPARK_CLOUD_EGRESS_IPS='203.0.113.7, 2a01:4f9::1' run_deploy 200 v6sha)"
check "v4+v6 pair accepted verbatim"              "grep -q '^BARKPARK_TRUSTED_PROXIES=203.0.113.7, 2a01:4f9::1\$' '$APP/.env'"
rm -rf "$TMP"

# Absent: the honest gap. A commented placeholder lands in .env, the log names the
# cost, and the deploy stays green — a missing trust list is coarse bucketing, not
# an outage, so it must never fail a deploy.
setup_case
rc="$(run_deploy 200 noxffsha)"
check "absent: exit 0"                            "[ '$rc' = '0' ]"
check "absent: no live line written"              "! grep -q '^BARKPARK_TRUSTED_PROXIES=' '$APP/.env'"
check "absent: commented placeholder written"     "grep -q '^# BARKPARK_TRUSTED_PROXIES=203.0.113.7\$' '$APP/.env'"
check "absent: gap logged loudly"                 "grep -q 'WARN: no BARKPARK_CLOUD_EGRESS_IPS' '$TMP/out.log'"
# The placeholder must survive being SOURCED (the script does `set -a; . ./.env`)
# and must not become a live value on the next deploy either.
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rm -f "$APP/.instance-deploy-last"
rc="$(run_deploy 200 noxffsha2)"
check "absent redeploy: exit 0 (comment is sourceable)" "[ '$rc' = '0' ]"
check "absent redeploy: still no live line"       "! grep -q '^BARKPARK_TRUSTED_PROXIES=' '$APP/.env'"
check "absent redeploy: placeholder NOT re-appended (.env does not grow)" "[ \"\$(grep -c '^# BARKPARK_TRUSTED_PROXIES=' '$APP/.env')\" = '1' ]"
check "absent redeploy: gap still logged (visible every deploy)" "grep -q 'WARN: no BARKPARK_CLOUD_EGRESS_IPS' '$TMP/out.log'"
rm -rf "$TMP"

echo "== Case 17: ADVANCE vs STALL — a deploy that reports SUCCESS without moving HEAD is now VISIBLE =="
# THE FAILURE CLASS (D292): "deploy said SUCCESS while the box stayed one commit
# behind". Until the fake git became stateful this harness could not even STATE
# the question: `rev-parse` answered one per-run CONSTANT, so an advancing run and
# a stalled run produced byte-identical evidence (exit 0, HEALTHY, state file) and
# an assert of the form `[ current != target ]` was false in BOTH.
# The discriminator is a CROSS-CHECK, never a self-report: box_head() reads the
# fake VCS state directly (what the box actually holds) and is compared against
# what the SCRIPT claims (its STATE file, its slot stamp, its HEALTHY line).
# MUTATION PROOF: put the old one-line constant handler back
# (`[ "$sub" = "rev-parse" ] && { echo "${FAKE_SHA:-deadbeef}"; exit 0; }`) and
# exactly three checks flip RED — "advance: the deploy's STATE claim matches the
# box's actual HEAD", "advance: the slot stamp records the sha that was built"
# and "stall: HEALTHY log line carries a SHORT sha" — i.e. the script's claim and
# the box's truth come apart, which is exactly the class this case exists for.
# Everything else, including the whole STALL block, stays green: the stall half
# was ALWAYS green, which is precisely why the old harness proved nothing.
box_head() { cat "$GITSTATE/head.sha" 2>/dev/null; }
setup_case
run_deploy 200 basesha >/dev/null                      # box lands at basesha, green live
check "pre-state: box HEAD is basesha"          "[ \"\$(box_head)\" = 'basesha' ]"
# --- ADVANCE: the remote offers a NEW sha; the box must end up on it.
pre="$(box_head)"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(REMOTE_SHA=advancesha run_deploy 200 basesha)"
check "advance: exit 0"                                  "[ '$rc' = '0' ]"
check "advance: HEAD moved off the pre-deploy sha"       "[ \"\$(box_head)\" != '$pre' ]"
check "advance: HEAD == the sha the remote offered"      "[ \"\$(box_head)\" = 'advancesha' ]"
check "advance: the deploy's STATE claim matches the box's actual HEAD" "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = \"\$(box_head)\" ]"
check "advance: the slot stamp records the sha that was built" "[ \"\$(cat '$APP/.slots/blue.sha' 2>/dev/null)\" = 'advancesha' ]"
# --- STALL: the remote offers what the box already has. The run still succeeds
# (nothing is broken — the deploy is just a re-deploy), but "success" must NOT be
# readable as "advanced". STATE is removed first so the coalesce no-op does not
# short-circuit the run: this is the full deploy path, landing on the same sha.
pre2="$(box_head)"
rm -f "$APP/.instance-deploy-last"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(REMOTE_SHA=advancesha run_deploy 200 advancesha)"
check "stall: the run still reports SUCCESS (exit 0)"    "[ '$rc' = '0' ]"
check "stall: the run still logs HEALTHY"                "grep -q 'HEALTHY — slot' '$TMP/out.log'"
check "stall: the run still writes the state file"       "[ \"\$(cat '$APP/.instance-deploy-last' 2>/dev/null)\" = 'advancesha' ]"
check "stall: but HEAD did NOT advance — and the harness can SEE it" "[ \"\$(box_head)\" = '$pre2' ]"
check "stall: HEALTHY log line carries a SHORT sha (7 chars)" "grep -qE 'HEALTHY — slot (blue|green) live at [0-9a-z]{7}\$' '$TMP/out.log'"
rm -rf "$TMP"

echo "== Case 18: a failed build never stamps the slot (the poisoned rollback target) =="
# .slots/<slot>.sha used to be written BEFORE deps.get/deps.compile/compile/
# ecto.migrate, and no exit-12/13 path reverted it — so a deploy that never built
# left the idle slot claiming a sha it does not hold, and --rollback (which reads
# exactly that file) would reset the checkout to it and reboot a stale build root.
# FAIL-BEFORE: with the pre-fix ordering these four checks are RED (blue.sha =
# brokensha; preflight exits 0 offering a build that does not exist).
setup_case
run_deploy 200 goodsha >/dev/null                       # green live + stamped at goodsha
rm -f "$APP/.instance-deploy-last"                      # defeat the coalesce
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(MIX_FAIL=compile REMOTE_SHA=brokensha run_deploy 200 goodsha)"
check "compile failure: exit 12"                        "[ '$rc' = '12' ]"
check "compile failure: target slot NOT stamped"        "[ ! -e '$APP/.slots/blue.sha' ]"
check "compile failure: live slot stamp untouched"      "[ \"\$(cat '$APP/.slots/green.sha' 2>/dev/null)\" = 'goodsha' ]"
check "compile failure: STATE not advanced"             "[ ! -f '$APP/.instance-deploy-last' ]"
rc="$(run_preflight goodsha)"
check "compile failure: rollback still refuses (21 no_previous_slot)" "[ '$rc' = '21' ]"
# ecto.migrate failure (exit 13) is the same law one step later.
rm -f "$APP/.instance-deploy-last"
rc="$(MIX_FAIL=ecto.migrate REMOTE_SHA=brokensha2 run_deploy 200 goodsha)"
check "migrate failure: exit 13"                        "[ '$rc' = '13' ]"
check "migrate failure: target slot still NOT stamped"  "[ ! -e '$APP/.slots/blue.sha' ]"
rm -rf "$TMP"

# A slot that ALREADY holds a good stamp keeps it when the next deploy into it
# fails: the previous build is still what that build root contains, so it stays
# the honest rollback target.
setup_case
run_deploy 200 v1sha >/dev/null                          # green stamped v1sha
run_deploy 200 v2sha >/dev/null                          # blue  stamped v2sha, blue live
rm -f "$APP/.instance-deploy-last"
: > "$MIXLOG"; : > "$SYSCTLLOG"; : > "$GITLOG"
rc="$(MIX_FAIL=compile REMOTE_SHA=v3sha run_deploy 200 v2sha)"   # targets green, fails
check "failed redeploy: exit 12"                         "[ '$rc' = '12' ]"
check "failed redeploy: green keeps its PREVIOUS stamp (v1sha)" "[ \"\$(cat '$APP/.slots/green.sha' 2>/dev/null)\" = 'v1sha' ]"
check "failed redeploy: live blue stamp untouched (v2sha)" "[ \"\$(cat '$APP/.slots/blue.sha' 2>/dev/null)\" = 'v2sha' ]"
# The stamp is honest, but rollback is still refused — the clean build wiped
# _build_green before compiling, so the old build root is gone. That refusal is
# TYPED and fail-closed (21 no_previous_slot, naming the missing build root),
# which is the point: the box never offers a rollback it cannot perform.
rc="$(run_preflight v2sha)"
check "failed redeploy: preflight refuses fail-closed (21)" "[ '$rc' = '21' ]"
check "failed redeploy: refusal names the wiped build root, not a bogus sha" "grep -q 'no complete build root' '$TMP/preflight.log'"
rm -rf "$TMP"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
