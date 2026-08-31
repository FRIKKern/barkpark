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
#   3) EVERY status-code classification in the script accepts only 2xx/3xx, and
#      the real script aborts/reverts when a probe answers 404.
#
# HOUSE RULE for this file: an assertion extracted from the script must cover
# EVERY occurrence, never `head -1`. Two defects of that shape have already been
# paid for here (the daemon-reload grep, the health-class grep) — each stayed
# green because a second, untouched occurrence answered for the broken one.
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
# ANCHORED to the pin block, not the whole file: `systemctl daemon-reload`
# occurs twice in cp-deploy.sh (the pin, and the image-bake timer install near
# the end), so a bare file-wide grep stays green when the pin's own reload is
# deleted — the unit file is rewritten and systemd never re-reads it. Proven:
# blanking only the pin's reload left this harness at ALL PASS.
PIN_BLOCK="$(mktemp)"
awk '/if grep -qE -- .--control-url\[= \]./,/^  else$/' "$SCRIPT" > "$PIN_BLOCK"
check "found the control-url pin block in the script" "[ -s '$PIN_BLOCK' ]"
check "runs systemctl daemon-reload INSIDE the pin block (not merely somewhere in the file)" \
  "grep -q 'systemctl daemon-reload' '$PIN_BLOCK'"

# 2) Functional: the exact rewrite the script applies — EXTRACTED from the
# script, never mirrored. A hand-copied expression tests the copy: with the real
# sed re-pointed at `http://localhost:4100` (the precise regression dwb-16
# exists to prevent — the port-flip lockout that froze /new at "Starting") this
# harness still reported ALL PASS, because it was replaying its own good copy of
# a line the script no longer had. Now the script's own expression is pulled out
# and run, so any drift in it reds here.
PROV_CONTROL_URL="https://barkpark.cloud"
PIN_SED_EXPR="$(grep -- 'sed -i -E "s#--control-url' "$SCRIPT" | head -1)"
PIN_SED_EXPR="${PIN_SED_EXPR#*sed -i -E \"}"      # drop everything up to the opening quote
PIN_SED_EXPR="${PIN_SED_EXPR%%\" \"\$PROV_UNIT\"*}"  # drop the closing quote and the file arg
PIN_SED_EXPR="${PIN_SED_EXPR//\\\"/\"}"            # the line's \" is shell escaping, not sed syntax
PIN_SED_EXPR="${PIN_SED_EXPR//\$\{PROV_CONTROL_URL\}/$PROV_CONTROL_URL}"
# Kept OUT of check's eval string: the extracted expression contains a literal
# single quote (the character class excludes ' ), which no amount of quoting
# survives being re-evaluated. Same idiom as code_is_healthy below.
pin_expr_ok() { [ -n "$PIN_SED_EXPR" ] && case "$PIN_SED_EXPR" in 's#--control-url'*) return 0 ;; *) return 1 ;; esac; }
check "extracted the script's own control-url sed expression" "pin_expr_ok"
# head -1 above is only safe while there IS exactly one. A second control-url
# rewrite (a copy, a second unit) would be replayed by nothing — the same
# hide-behind-a-sibling shape as the two defects this file has already paid for.
one_pin_sed() { [ "$(grep -c -- 'sed -i -E "s#--control-url' "$SCRIPT")" = 1 ]; }
check "exactly one control-url rewrite exists in the script (head -1 hides no sibling)" "one_pin_sed"
# Runs the SCRIPT's expression, but writes via a temp instead of `-i` so the test
# is portable to BSD sed (macOS) as well as GNU sed (the box).
rewrite() {
  sed -E "$PIN_SED_EXPR" "$1" > "$1.out"
  mv "$1.out" "$1"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$PIN_BLOCK"' EXIT

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
# EVERY occurrence, never `head -1`. cp-deploy.sh classifies an HTTP code in TWO
# places — the pre-flip boot probe and the post-flip PUBLIC probe — and the old
# `grep '200|301|302' | head -1` read only the first. Proven: widening ONLY the
# post-flip class to accept 404 (the pre-flip one left clean) kept this harness
# at ALL PASS, rc=0. Identical shape to the daemon-reload defect above: a second,
# untouched occurrence answered for the broken one. Enumerating also means a
# third probe added later is covered without touching this file.
code_is_healthy() { echo "$1" | grep -qE "^(${HEALTH_RE})\$"; }  # replays the script's EXACT classification
n_health=0
while IFS= read -r hl; do
  [ -n "$hl" ] || continue
  n_health=$((n_health + 1))
  lineno="${hl%%:*}"
  body="${hl#*:}"
  HEALTH_RE="${body#*"grep -qE '^("}"
  HEALTH_RE="${HEALTH_RE%%")\$'"*}"
  check "line $lineno: extracted the health-check regex class" "[ -n '$HEALTH_RE' ]"
  check "line $lineno: 200 (OK) classified healthy"                     "code_is_healthy 200"
  check "line $lineno: 301 (redirect) classified healthy"                "code_is_healthy 301"
  check "line $lineno: 302 (redirect) classified healthy"                "code_is_healthy 302"
  check "line $lineno: 404 (not found) NOT healthy — the fixed defect"   "! code_is_healthy 404"
  check "line $lineno: 500 (server error) NOT healthy"                    "! code_is_healthy 500"
  check "line $lineno: 000 (curl failure / connection refused) NOT healthy" "! code_is_healthy 000"
done <<EOF
$(grep -n 'echo "\$code" | grep -qE' "$SCRIPT")
EOF
# Both probes must still BE there. Deleting one entirely would otherwise leave
# the survivor passing and this section silently half as strong.
check "both HTTP-code classifications are present (pre-flip boot + post-flip public)" \
  "[ '$n_health' -ge 2 ]"


# ===========================================================================
# FUNCTIONAL: the blue/green FLIP, driven end to end against fakes.
#
# Everything above this line is static grep + a sed replay. The flip itself —
# which slot is derived as live, whether the rewrite lands, and whether a
# broken flip stops the deploy — had NO coverage at all, and it is the step
# that can take barkpark.cloud down: the old slot is retired seconds after it.
#
# Fakes for docker/git/systemctl/curl/sleep; REAL caddy validate, REAL flock,
# REAL cp/grep/sed against a REAL Caddyfile in a tmpdir. No network, no
# containers, no box.
# ===========================================================================
echo
echo "cp-deploy blue/green flip (functional)"

command -v caddy >/dev/null 2>&1 || { echo "  FAIL: caddy binary required for the flip cases (real validation)"; fails=$((fails + 1)); echo; if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAIL"; fi; exit "$fails"; }

FTMP=""
cleanup_flip() { [ -n "$FTMP" ] && rm -rf "$FTMP"; }
trap 'cleanup_flip; rm -f "$tmp" "$PIN_BLOCK"' EXIT

make_flip_fakes() {
  local dir="$1"; mkdir -p "$dir"

  # Fake docker. Container liveness is a file per published port in $DSTATE, so
  # "was the OLD slot retired?" is an observable fact and not a log grep.
  cat > "$dir/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKERLOG"
slot_port() { case "$1" in
  control_plane_blue) printf '%s' "${PORT_BLUE:-4100}" ;;
  control_plane_green) printf '%s' "${PORT_GREEN:-4101}" ;;
esac; }
case "${1:-}" in
  tag) exit 0 ;;
  ps)
    p=""
    for a in "$@"; do case "$a" in publish=*) p="${a#publish=}" ;; esac; done
    [ -n "$p" ] && [ -f "$DSTATE/running.$p" ] && echo "c$p"
    exit 0 ;;
  stop)
    id=""; for a in "$@"; do id="$a"; done
    rm -f "$DSTATE/running.${id#c}"
    exit 0 ;;
  compose)
    shift
    args=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f|--profile) shift 2; continue ;;
      esac
      args="$args $1"; shift
    done
    set -- $args
    sub="${1:-}"
    case "$sub" in
      build) [ "${COMPOSE_BUILD_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
      up)
        for a in "$@"; do
          pp="$(slot_port "$a")"; [ -n "$pp" ] && touch "$DSTATE/running.$pp"
        done
        exit 0 ;;
      rm)
        for a in "$@"; do
          pp="$(slot_port "$a")"; [ -n "$pp" ] && rm -f "$DSTATE/running.$pp"
        done
        exit 0 ;;
    esac
    exit 0 ;;
  image)
    [ "${2:-}" = "prune" ] || exit 0
    [ "${IMAGE_PRUNE_FAIL:-0}" = 1 ] && { echo "Error: image prune blew up" >&2; exit 1; }
    echo "Total reclaimed space: 21.4GB"
    exit 0 ;;
  builder)
    [ "${2:-}" = "prune" ] || exit 0
    for a in "$@"; do case "$a" in
      --keep-storage) [ "${BUILDER_KEEP_FLAG_FAIL:-0}" = 1 ] && { echo "unknown flag: --keep-storage" >&2; exit 125; } ;;
    esac; done
    [ "${BUILDER_PRUNE_FAIL:-0}" = 1 ] && { echo "Error: builder prune blew up" >&2; exit 1; }
    echo "Total: 14.2GB"
    exit 0 ;;
esac
exit 0
EOF

  # Fake curl, URL-aware — the three probes must be drivable INDEPENDENTLY:
  #   --resolve …           the PUBLIC post-flip probe   -> PUBLIC_HEALTH_CODE
  #   …/v1/auth/login       the pre-flip DB probe        -> DB_CODE
  #   otherwise             the pre-flip '/' boot probe  -> HEALTH_CODE
  # so a slot that boots perfectly on its own port can still be driven to fail
  # the public probe, which is the whole point of the post-flip gate.
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in --resolve) printf '%s' "${PUBLIC_HEALTH_CODE:-200}"; exit 0 ;; esac
done
for a in "$@"; do
  case "$a" in */v1/auth/login) printf '%s' "${DB_CODE:-401}"; exit 0 ;; esac
done
printf '%s' "${HEALTH_CODE:-200}"
EOF

  cat > "$dir/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$GITLOG"
args=("$@"); i=0; sub=""
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -c|-C) i=$((i + 2)); continue ;;
    *) sub="${args[$i]}"; break ;;
  esac
done
[ "$sub" = "rev-parse" ] && { echo "${FAKE_SHA:-deadbeefcafe}"; exit 0; }
exit 0
EOF

  cat > "$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSCTLLOG"
case "${1:-}" in
  is-active) echo active ;;
  is-enabled) echo enabled ;;
esac
exit 0
EOF

  # The flip's sleeps are real time in a harness that has no real containers.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/sleep"
  # GNU-style `sed -i "expr" file` shim for macOS (the script targets Linux).
  cat > "$dir/sed" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-i" ]; then shift; expr="$1"; shift; exec perl -pi -e "$expr" "$@"; fi
exec /usr/bin/sed "$@"
EOF
  # Fake df: DF_AVAIL_KB drives the headroom guard (default: 50G free, well
  # above any floor); DF_FAIL=1 makes df unanswerable (the guard's skip path).
  cat > "$dir/df" <<'EOF'
#!/usr/bin/env bash
[ "${DF_FAIL:-0}" = 1 ] && exit 1
avail="${DF_AVAIL_KB:-52428800}"
total=104857600
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake $total $((total - avail)) $avail 50% /"
EOF
  # macOS has no flock(1) and the deploy lock is not under test here. Faked
  # ONLY when the real one is absent, so Linux CI still exercises the real
  # thing — without this every case on a Mac dies at exit 15 (lock wait).
  if ! command -v flock >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/flock"
  fi
  chmod +x "$dir"/*
}

# caddyfile <upstream>  — a REAL, caddy-valid control-plane front.
caddyfile() { printf 'barkpark.cloud {\n\treverse_proxy %s\n}\n' "$1" > "$CADDY"; }

# setup_flip <upstream> [blue_port] [green_port]
setup_flip() {
  cleanup_flip
  FTMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-deploy-flip.XXXXXX")"
  APPDIR="$FTMP/opt/barkpark"; FAKEBIN="$FTMP/bin"; DSTATE="$FTMP/dstate"
  CADDY="$FTMP/etc/caddy/Caddyfile"
  DOCKERLOG="$FTMP/docker.log"; GITLOG="$FTMP/git.log"; SYSCTLLOG="$FTMP/systemctl.log"
  mkdir -p "$APPDIR/cloud" "$FAKEBIN" "$DSTATE" "$FTMP/etc/caddy"
  : > "$DOCKERLOG"; : > "$GITLOG"; : > "$SYSCTLLOG"
  make_flip_fakes "$FAKEBIN"
  : > "$APPDIR/cloud/docker-compose.yml"
  {
    printf 'PORT_BLUE=%s\n' "${2:-4100}"
    printf 'PORT_GREEN=%s\n' "${3:-4101}"
  } > "$APPDIR/cloud/.env"
  caddyfile "$1"
  # The live slot's container. Retiring it is the LAST thing a healthy deploy
  # does, so "is it still there?" separates a clean abort from a real outage.
  touch "$DSTATE/running.${2:-4100}"
}

# run_flip [VAR=VAL …] -> prints the exit code; stdout+stderr land in $FTMP/out.log
run_flip() {
  env PATH="$FAKEBIN:$PATH" \
      BARKPARK_APP_DIR="$APPDIR" \
      BARKPARK_CADDYFILE="$CADDY" \
      BARKPARK_DEPLOY_LOCK="$FTMP/deploy.lock" \
      BARKPARK_PROVISIONER_UNIT="$FTMP/nonexistent-provisioner.service" \
      DOCKERLOG="$DOCKERLOG" GITLOG="$GITLOG" SYSCTLLOG="$SYSCTLLOG" DSTATE="$DSTATE" \
      "$@" bash "$SCRIPT" > "$FTMP/out.log" 2>&1
  echo "$?"
}

upstream() { grep -oE 'reverse_proxy [^ ]+' "$CADDY" | head -1 | awk '{print $2}'; }

# ---- Case 1: a healthy deploy flips blue(:4100) -> green(:4101) and retires blue
setup_flip localhost:4100
rc="$(run_flip)"
check "healthy: exit 0"                          "[ '$rc' = '0' ]"
check "healthy: Caddy upstream moved to :4101"   "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "healthy: Caddyfile still caddy-valid"     "caddy validate --config '$CADDY' >/dev/null 2>&1"
check "healthy: green slot booted"               "[ -f '$DSTATE/running.4101' ]"
check "healthy: old blue slot retired AFTER the flip" "[ ! -f '$DSTATE/running.4100' ]"

# ---- Case 2: the PUBLIC post-flip probe fails -> flip REVERTED, old slot kept
# ROOT CAUSE this guards: this curl was captured into $code, logged, and never
# tested. A flip that landed on a dead public front still exited 0 — and the
# very next thing the script does is stop the slot that WAS serving, so the
# control plane went dark while the deploy reported DONE. The pre-flip probes
# both pass here (HEALTH_CODE=200, DB_CODE=401); only the PUBLIC one fails, so
# this proves the gate AFTER the flip, not the boot gate before it.
setup_flip localhost:4100
rc="$(run_flip PUBLIC_HEALTH_CODE=502)"
check "public probe fails: exit 14 (not 0 — a broken flip must not report success)" "[ '$rc' = '14' ]"
check "public probe fails: named in the log"     "grep -q 'post-flip public health check FAILED' '$FTMP/out.log'"
check "public probe fails: Caddy flipped BACK to :4100" "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "public probe fails: reverted Caddyfile still valid" "caddy validate --config '$CADDY' >/dev/null 2>&1"
check "public probe fails: caddy reloaded on the way back" "[ \"\$(grep -c 'systemctl reload caddy' '$SYSCTLLOG')\" -ge 2 ]"
check "public probe fails: the LIVE blue slot was NEVER stopped" "[ -f '$DSTATE/running.4100' ]"
check "public probe fails: the unproven green slot was removed" "[ ! -f '$DSTATE/running.4101' ]"
check "public probe fails: checkout reset back"  "grep -q 'reset --hard' '$GITLOG'"

# ---- Case 3: the flip sed matches NOTHING -> refused before anything is retired
# A Caddyfile whose upstream is spelled 127.0.0.1:<port> (or any form without
# the literal 'localhost:<slot port>') is invisible to both the ACTIVE_PORT grep
# and the flip sed. The file comes out BYTE-IDENTICAL, caddy validate passes on
# it, the reload succeeds, and the public probe answers 200 — because the OLD
# slot is still the one serving. Before the landed-check the deploy then retired
# that old slot and exited 0: a total outage reported as success.
setup_flip 127.0.0.1:4100
rc="$(run_flip)"
check "sed matched nothing: exit 14 (not 0)"     "[ '$rc' = '14' ]"
check "sed matched nothing: named in the log"    "grep -q 'FLIP DID NOT LAND' '$FTMP/out.log'"
check "sed matched nothing: Caddyfile byte-identical" "[ \"\$(upstream)\" = '127.0.0.1:4100' ]"
check "sed matched nothing: the serving slot was NEVER stopped" "[ -f '$DSTATE/running.4100' ]"

# ---- Case 4: PORT_BLUE/PORT_GREEN are honoured, not hardcoded 4100
# `[ "$ACTIVE_PORT" = "4100" ]` compared a configurable port against a literal.
# With the ports moved, the old code derived the WRONG slot and its sed matched
# nothing — a deploy that built, booted and reported DONE while Caddy never
# moved and the new code was never served.
setup_flip localhost:4200 4200 4201
rc="$(run_flip)"
check "custom ports: exit 0"                     "[ '$rc' = '0' ]"
check "custom ports: derived blue as live"       "grep -q 'active upstream :4200' '$FTMP/out.log'"
check "custom ports: flipped to the green port"  "[ \"\$(upstream)\" = 'localhost:4201' ]"
check "custom ports: green slot booted"          "[ -f '$DSTATE/running.4201' ]"

# ---- Case 5: a derivation that names the LIVE port is refused before any work
setup_flip localhost:4100 4100 4100
rc="$(run_flip)"
check "collided ports: exit 16"                  "[ '$rc' = '16' ]"
check "collided ports: refusal names the reason" "grep -q 'the port Caddy already serves' '$FTMP/out.log'"
check "collided ports: nothing was built"        "! grep -q 'compose.*build' '$DOCKERLOG'"
check "collided ports: Caddy untouched"          "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "collided ports: the live container survives" "[ -f '$DSTATE/running.4100' ]"

# ---- Case 6: the PRE-FLIP boot probe answers 404 -> refused before any flip
# The static replay above proves the CLASS excludes 404; this proves the script
# ACTS on it. A container that boots and serves nothing but 404s (crashed app,
# wrong port, static server up with the SPA missing) must never reach the flip.
setup_flip localhost:4100
rc="$(run_flip HEALTH_CODE=404)"
check "boot probe 404: exit 14 (not 0)"          "[ '$rc' = '14' ]"
check "boot probe 404: named UNHEALTHY in the log" "grep -q 'UNHEALTHY' '$FTMP/out.log'"
check "boot probe 404: Caddy never moved"        "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "boot probe 404: the live blue slot survives" "[ -f '$DSTATE/running.4100' ]"

# ---- Case 7: the POST-FLIP public probe answers 404 -> flip REVERTED
# This is the case the `head -1` extraction could not see: widening ONLY the
# post-flip class to accept 404 left the whole harness green. Driving the real
# script makes that regression fail here regardless of how the check is spelled.
setup_flip localhost:4100
rc="$(run_flip PUBLIC_HEALTH_CODE=404)"
check "public probe 404: exit 14 (not 0)"        "[ '$rc' = '14' ]"
check "public probe 404: named in the log"       "grep -q 'post-flip public health check FAILED' '$FTMP/out.log'"
check "public probe 404: Caddy flipped BACK to :4100" "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "public probe 404: the LIVE blue slot was NEVER stopped" "[ -f '$DSTATE/running.4100' ]"

# ===========================================================================
# Disk hygiene: post-flip prune + pre-build headroom guard
# (task-646054a48241ffe2 — the 2026-08-31 outage: 839 never-pruned deploy
# images + 14GB build cache filled the box to 100% and Postgres 500'd the
# fleet list). Two arms: every SUCCESSFUL deploy prunes what nothing
# references (the rollback slot's image survives — its stopped container
# references it), and a deploy that would build below the headroom floor
# REFUSES before touching anything.
# ===========================================================================
echo
echo "cp-deploy disk hygiene (task-646054a48241ffe2)"

# Prune must run AFTER the old slot is retired — the stopped container is what
# anchors the rollback image through `docker image prune -af`. Order is read
# from the docker log, not inferred from the script text.
prune_after_stop() {
  local stop_ln prune_ln
  stop_ln="$(grep -n '^docker stop' "$DOCKERLOG" | tail -1 | cut -d: -f1)"
  prune_ln="$(grep -n '^docker image prune' "$DOCKERLOG" | head -1 | cut -d: -f1)"
  [ -n "$stop_ln" ] && [ -n "$prune_ln" ] && [ "$prune_ln" -gt "$stop_ln" ]
}

# ---- Case 8: a healthy deploy prunes after retiring the old slot, and the
# output carries the evidence: reclaimed bytes + a df line.
setup_flip localhost:4100
rc="$(run_flip)"
check "healthy: exit 0" "[ '$rc' = '0' ]"
check "healthy: headroom measured + logged before the build" "grep -q 'headroom ok:' '$FTMP/out.log'"
check "healthy: image prune ran" "grep -q '^docker image prune -af' '$DOCKERLOG'"
check "healthy: builder prune ran with a cache floor" "grep -q -- '^docker builder prune -af --keep-storage' '$DOCKERLOG'"
check "healthy: reclaimed image bytes logged" "grep -q 'image prune: Total reclaimed space: 21.4GB' '$FTMP/out.log'"
check "healthy: reclaimed build-cache bytes logged" "grep -q 'Total: 14.2GB' '$FTMP/out.log'"
check "healthy: df line logged after the prune" "grep -q 'disk after prune: .*free of' '$FTMP/out.log'"
check "healthy: prune ran AFTER the old slot was stopped" "prune_after_stop"

# ---- Case 9: prune fires ONLY on a successful flip — every abort path skips
# it. A failed deploy must never reclaim anything: the abort paths lean on the
# rollback image + old slot, and pruning mid-abort is exactly the wrong moment.
setup_flip localhost:4100
rc="$(run_flip PUBLIC_HEALTH_CODE=502)"
check "public probe fails: exit 14" "[ '$rc' = '14' ]"
check "public probe fails: NO image prune ran" "! grep -q 'image prune' '$DOCKERLOG'"
check "public probe fails: NO builder prune ran" "! grep -q 'builder prune' '$DOCKERLOG'"

setup_flip localhost:4100
rc="$(run_flip HEALTH_CODE=404)"
check "boot probe fails: exit 14" "[ '$rc' = '14' ]"
check "boot probe fails: NO image prune ran" "! grep -q 'image prune' '$DOCKERLOG'"
check "boot probe fails: NO builder prune ran" "! grep -q 'builder prune' '$DOCKERLOG'"

setup_flip localhost:4100
rc="$(run_flip COMPOSE_BUILD_FAIL=1)"
check "build fails: exit 13" "[ '$rc' = '13' ]"
check "build fails: NO image prune ran" "! grep -q 'image prune' '$DOCKERLOG'"
check "build fails: NO builder prune ran" "! grep -q 'builder prune' '$DOCKERLOG'"

# ---- Case 10: below the floor (1G free vs the 5G default) the deploy REFUSES
# before building — a build on a full disk digs the hole deeper and the live DB
# shares the filesystem.
setup_flip localhost:4100
rc="$(run_flip DF_AVAIL_KB=1048576)"
check "headroom refusal: exit 17" "[ '$rc' = '17' ]"
check "headroom refusal: names the floor" "grep -q '5G floor' '$FTMP/out.log'"
check "headroom refusal: names the actual free space" "grep -q 'only 1.0G free' '$FTMP/out.log'"
check "headroom refusal: names the box-prune remediation" "grep -q 'box-prune' '$FTMP/out.log'"
check "headroom refusal: nothing was built" "! grep -q 'compose.*build' '$DOCKERLOG'"
check "headroom refusal: Caddy untouched" "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "headroom refusal: the live slot survives" "[ -f '$DSTATE/running.4100' ]"
check "headroom refusal: checkout reset back" "grep -q 'reset --hard' '$GITLOG'"

# ---- Case 11: above the floor the deploy proceeds; a raised floor is honoured
setup_flip localhost:4100
rc="$(run_flip DF_AVAIL_KB=$((6 * 1024 * 1024)))"
check "6G free vs 5G floor: exit 0" "[ '$rc' = '0' ]"
check "6G free vs 5G floor: flip landed" "[ \"\$(upstream)\" = 'localhost:4101' ]"

setup_flip localhost:4100
rc="$(run_flip DF_AVAIL_KB=$((6 * 1024 * 1024)) BARKPARK_MIN_FREE_GB=10)"
check "6G free vs raised 10G floor: exit 17" "[ '$rc' = '17' ]"
check "6G free vs raised 10G floor: refusal names the raised floor" "grep -q '10G floor' '$FTMP/out.log'"

# ---- Case 12: df unanswerable -> the guard skips OPEN, loudly. A guard that
# refuses every deploy on a healthy box is worse than none (fleet-build-gate
# precedent), but the skip must be visible in the log.
setup_flip localhost:4100
rc="$(run_flip DF_FAIL=1)"
check "df dead: deploy proceeds (exit 0)" "[ '$rc' = '0' ]"
check "df dead: the skip is loud in the log" "grep -q 'headroom guard SKIPPED' '$FTMP/out.log'"

# ---- Case 13: a prune failure never turns a PROVEN deploy red — the flip has
# already landed and been health-gated; hygiene is best-effort after that.
setup_flip localhost:4100
rc="$(run_flip IMAGE_PRUNE_FAIL=1 BUILDER_PRUNE_FAIL=1)"
check "prunes fail: deploy still exit 0" "[ '$rc' = '0' ]"
check "prunes fail: image prune WARNING logged" "grep -q 'WARNING: docker image prune failed' '$FTMP/out.log'"
check "prunes fail: builder prune WARNING logged" "grep -q 'WARNING: docker builder prune failed' '$FTMP/out.log'"
check "prunes fail: the flip stands" "[ \"\$(upstream)\" = 'localhost:4101' ]"

# ---- Case 14: --keep-storage refused (buildx renamed it once already) -> the
# cache is still pruned flagless. An unbounded cache IS the outage; a cold
# cache is only a slower next build.
setup_flip localhost:4100
rc="$(run_flip BUILDER_KEEP_FLAG_FAIL=1)"
check "keep-storage refused: deploy still exit 0" "[ '$rc' = '0' ]"
check "keep-storage refused: fallback named in the log" "grep -q 'pruned ALL build cache' '$FTMP/out.log'"
check "keep-storage refused: a flagless builder prune ran" "grep -q '^docker builder prune -af\$' '$DOCKERLOG'"
echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAIL"; fi
exit "$fails"
