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
# checks_ran: how many assertions actually EXECUTED. A shell harness can print
# ALL PASS having run ZERO checks — an early `exit 0`, an outermost skip, a
# mis-set guard — and exit 0 is then indistinguishable from a real green. The
# floor at the bottom of this file turns that vacuum into a red.
checks_ran=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { checks_ran=$((checks_ran + 1)); if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

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
# THE SHAPE CHANGED, AND SO DID THIS READER (task-fb55d468c7dea75b). Both probes
# used to classify with `echo "$code" | grep -qE '^(200|301|302)$'`, which is the
# pipefail/SIGPIPE hazard scripts/pipefail-sigpipe-scan.sh ratchets: grep -q exits
# at the first match, echo takes SIGPIPE, pipefail hands back 141, and a HEALTHY
# code reads as unhealthy — under load, on the deploy's own health gate. They are
# `case` now, which needs no pipe at all. This extraction follows the code rather
# than pinning the old shape, and `code_is_healthy` replays a CASE pattern for the
# same reason it used to replay a regex: the assertion must be the script's own
# classification, not a second copy of it. (The replay lost its own `echo | grep -q`
# in the move, which is one fewer site of the very shape this block now guards.)
# `[[ =~ ]]`, not `case "$1" in ${HEALTH_RE})`: the `|` in a case pattern is
# CASE SYNTAX, parsed before the expansion, so an alternation arriving inside a
# variable is one literal string and every arm reds. That draft was written and
# it failed here, loudly, which is the only reason this comment can be specific.
# `=~` treats the expansion as an ERE, where `|` is the alternation it looks
# like — and still no pipe, so the hazard this block now guards is not
# reintroduced by its own replay.
code_is_healthy() { [[ "$1" =~ ^(${HEALTH_RE})$ ]]; }
n_health=0
while IFS= read -r hl; do
  [ -n "$hl" ] || continue
  n_health=$((n_health + 1))
  lineno="${hl%%:*}"
  body="${hl#*:}"
  # `  case "$code" in 200|301|302) ok=1; … ;; esac`  ->  `200|301|302`
  HEALTH_RE="${body#*in }"
  HEALTH_RE="${HEALTH_RE%%)*}"
  check "line $lineno: extracted the health-check regex class" "[ -n '$HEALTH_RE' ]"
  check "line $lineno: 200 (OK) classified healthy"                     "code_is_healthy 200"
  check "line $lineno: 301 (redirect) classified healthy"                "code_is_healthy 301"
  check "line $lineno: 302 (redirect) classified healthy"                "code_is_healthy 302"
  check "line $lineno: 404 (not found) NOT healthy — the fixed defect"   "! code_is_healthy 404"
  check "line $lineno: 500 (server error) NOT healthy"                    "! code_is_healthy 500"
  check "line $lineno: 000 (curl failure / connection refused) NOT healthy" "! code_is_healthy 000"
done <<EOF
$(grep -n 'case "\$code" in' "$SCRIPT")
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
# CLOBBER HOOK (private-copy case). `docker version` is the first outside
# command the deploy runs, so this fires while the script is barely started and
# has hundreds of lines still unread: it rewrites the script FILE the harness
# invoked with garbage that is longer than the original, exactly as a later
# run's scp does on the box. A script executing from its own private copy never
# notices; one executing from the shared path reads the garbage at its next
# buffer refill and dies on a parse error.
if [ -n "${CLOBBER_TARGET:-}" ] && [ ! -f "$DSTATE/clobbered" ]; then
  : > "$DSTATE/clobbered"
  awk 'BEGIN{for(i=0;i<8000;i++) printf "this is not bash ) ) ( ;; done fi %d\n", i}' > "$CLOBBER_TARGET"
fi
slot_port() { case "$1" in
  control_plane_blue) printf '%s' "${PORT_BLUE:-4100}" ;;
  control_plane_green) printf '%s' "${PORT_GREEN:-4101}" ;;
esac; }
case "${1:-}" in
  tag) exit 0 ;;
  # `docker version --format '{{.Server.Version}}'` — the fake ignores the
  # template and answers the value the script parses out of it.
  version) printf '%s\n' "${FAKE_DOCKER_VERSION:-29.6.1}"; exit 0 ;;
  # `docker inspect --type container <id>`: the clearer's staleness probe. Any
  # id spelled *GONE is a container the daemon no longer has.
  inspect)
    for a in "$@"; do case "$a" in *GONE) exit 1 ;; esac; done
    exit 0 ;;
  network)
    case "${2:-}" in
      inspect)
        # The clearer passes a Go template; like the `ps` fake above, this
        # answers the RESOLVED output (one "<container id> <name>" per endpoint).
        # Emitted only in a wedged scenario — otherwise there is nothing to list.
        [ -n "${WEDGE:-}" ] || exit 0
        # The serving slot (blue) is spelled GONE on purpose: it LOOKS stale, so
        # only the by-name serving-slot guard can save it. If that guard is ever
        # dropped, this endpoint gets unplugged and the case reds.
        # WEDGE_ORDER=tail puts the ONLY clearable endpoint LAST. The daemon
        # imposes no order on `network inspect`, and the count-identity cases
        # below need a list where a loop that stops early clears NOTHING —
        # otherwise a short sweep still happens to disconnect the right one and
        # the defect is invisible.
        if [ "${WEDGE_ORDER:-head}" = tail ]; then
          printf '%s\n' "b1000000blueGONE cloud-control_plane_blue-1"
          printf '%s\n' "f0638a499a14LIVE cloud-db-1"
          [ "${WEDGE_UNCLEARABLE:-0}" = 1 ] || printf '%s\n' "9a7aab2dba5bGONE cloud-control_plane_green-1"
          exit 0
        fi
        [ "${WEDGE_UNCLEARABLE:-0}" = 1 ] || printf '%s\n' "9a7aab2dba5bGONE cloud-control_plane_green-1"
        printf '%s\n' "f0638a499a14LIVE cloud-db-1"
        printf '%s\n' "b1000000blueGONE cloud-control_plane_blue-1"
        exit 0 ;;
      disconnect)
        # Clearing the endpoint is what unblocks the next `compose up`.
        touch "$DSTATE/endpoint_cleared"
        exit 0 ;;
    esac
    exit 0 ;;
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
      version) printf '%s\n' "${FAKE_COMPOSE_VERSION:-5.2.0}"; exit 0 ;;
      build) [ "${COMPOSE_BUILD_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
      up)
        # WEDGED: the daemon refuses every recreate until the stale endpoint is
        # actually disconnected. Sleeping does NOT clear it — which is exactly
        # why the old sleep-and-retry measured 0-for-65 over 27 hours.
        if [ -n "${WEDGE:-}" ] && [ ! -f "$DSTATE/endpoint_cleared" ]; then
          case "$WEDGE" in
            2) echo "Error response from daemon: container 9a7aab2dba5b is not connected to the network cloud_default" >&2 ;;
            *) echo "Error response from daemon: network cloud_default has active endpoints (name:\"cloud-control_plane_green-1\" id:\"9a7aab2dba5b\")" >&2 ;;
          esac
          exit 1
        fi
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
    # `docker image inspect cloud-control_plane:rollback` — the rollback path's
    # fail-closed precondition (c). Drivable in BOTH directions: without this
    # arm the catch-all below answers 0 and "the image is missing" could never
    # be tested at all.
    if [ "${2:-}" = "inspect" ]; then
      if [ "${ROLLBACK_IMAGE_MISSING:-0}" = 1 ]; then
        echo "Error response from daemon: No such image: cloud-control_plane:rollback" >&2
        exit 1
      fi
      exit 0
    fi
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
  #   …/info/refs           the origin probe differential -> CURL_INFO_REFS
  #   otherwise             the pre-flip '/' boot probe  -> HEALTH_CODE
  # so a slot that boots perfectly on its own port can still be driven to fail
  # the public probe, which is the whole point of the post-flip gate. There is
  # exactly ONE curl fake on purpose: a second `cat > "$dir/curl"` further down
  # make_flip_fakes would silently clobber this one and turn every health probe
  # into a real network call (it did — every post-flip case exited 14).
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *info/refs*) printf '%s' "${CURL_INFO_REFS:-200}"; exit 0 ;; esac
done
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
# The origin probe (task-a14a2f489452e95d). GIT_ORIGIN_FAIL selects which fault
# origin has, and the ls-remote arm answers DIFFERENTLY depending on whether the
# caller pinned protocol.version=0 — that asymmetry is the whole differential:
#   auth   — both handshakes get the exact Username prompt stderr from the outage
#   v0only — the PINNED handshake is refused, the default one works (stale pin)
#   v2only — the DEFAULT handshake is refused, the pinned one works (barkpark-cp
#            on git 2.34.1, i.e. the box the pull's pin exists for: must stay green)
#   net    — DNS/connection failure, no auth wording at all
[ "$sub" = "--version" ] && { echo "git version ${FAKE_GIT_VERSION:-2.34.1}"; exit 0; }
[ "$sub" = "remote" ] && { echo "https://github.com/example/barkpark.git"; exit 0; }
auth_refusal() {
  echo "fatal: could not read Username for 'https://github.com': No such device or address" >&2
  echo "fatal: expected flush after ref listing" >&2
  exit 128
}
if [ "$sub" = "ls-remote" ]; then
  v0=0; for a in "$@"; do [ "$a" = "protocol.version=0" ] && v0=1; done
  case "${GIT_ORIGIN_FAIL:-}" in
    auth)   auth_refusal ;;
    v0only) [ "$v0" = 1 ] && auth_refusal ;;
    v2only) [ "$v0" = 0 ] && auth_refusal ;;
    net)    echo "fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com" >&2; exit 128 ;;
  esac
  echo "${FAKE_SHA:-deadbeefcafe}	refs/heads/main"; exit 0
fi
# The pull carries the v0 pin, so it only fails where the PINNED handshake fails.
if [ "$sub" = "pull" ]; then
  case "${GIT_ORIGIN_FAIL:-}" in
    auth|v0only) echo "fatal: could not read Username for 'https://github.com': No such device or address" >&2; exit 1 ;;
  esac
fi
exit 0
EOF

  # Fake systemctl. The PROVISIONER unit is drivable independently of every
  # other unit this script touches (caddy reload, daemon-reload, the bake
  # timer): PROV_RESTART_RC makes `systemctl restart barkpark-provisioner`
  # exit non-zero, PROV_IS_ACTIVE sets what `is-active` answers for it. Both
  # arms matter — a restart can return 0 and the unit still land in `failed`
  # (the exact shape a crash-on-boot worker produces), and that is the arm the
  # old `log "provisioner: $(systemctl is-active ...)"` printed and ignored.
  # PROV_RECOVER_ON_RESTORE flips the unit healthy once the PREVIOUS binary has
  # been reinstalled, so the restore arm is observable rather than assumed.
  cat > "$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSCTLLOG"
prov=0
for a in "$@"; do case "$a" in barkpark-provisioner) prov=1 ;; esac; done
case "${1:-}" in
  is-active)
    if [ "$prov" = 1 ]; then
      if [ "${PROV_RECOVER_ON_RESTORE:-0}" = 1 ] && [ -f "$DSTATE/prov.restored" ]; then
        echo active
      else
        echo "${PROV_IS_ACTIVE:-active}"
      fi
    else
      echo active
    fi ;;
  is-enabled) echo enabled ;;
  restart)
    if [ "$prov" = 1 ]; then
      if [ "${PROV_RECOVER_ON_RESTORE:-0}" = 1 ] && [ -f "$DSTATE/prov.restored" ]; then exit 0; fi
      exit "${PROV_RESTART_RC:-0}"
    fi ;;
  status) echo "\u25cf ${2:-unit} - fake unit"; echo "Active: ${PROV_IS_ACTIVE:-active}" ;;
esac
exit 0
EOF

  # Fake install(1): records what landed at the provisioner path so the harness
  # can tell "the NEW binary was installed" from "the PREVIOUS one was restored"
  # — the restore arm is the whole point of the failure path.
  cat > "$dir/install" <<'EOF'
#!/usr/bin/env bash
args=(); for a in "$@"; do case "$a" in -m|0755|0644) ;; *) args+=("$a") ;; esac; done
src="${args[0]:-}"; dst="${args[1]:-}"
case "$dst" in
  *barkpark-provisioner) case "$src" in *.bak) : > "$DSTATE/prov.restored" ;; esac ;;
esac
[ -n "$src" ] && [ -n "$dst" ] && /usr/bin/install -m 0755 "$src" "$dst" 2>/dev/null
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

# caddyfile <upstream>  — a REAL, caddy-valid control-plane front, PLUS a
# second site on an unrelated upstream (:9100). The flip is a file-wide
# `sed s/localhost:<active>/localhost:<target>/g`, so anything else the
# Caddyfile proxies is inside its blast radius; the static engine's harness
# guards exactly this with its :4010 / :4020 rows and cp-deploy's fixture had
# no second upstream at all, so no collateral-scope row could exist here.
# The control-plane block stays FIRST — upstream() reads `head -1`.
caddyfile() {
  {
    printf 'barkpark.cloud {\n\treverse_proxy %s\n}\n' "$1"
    printf 'metrics.barkpark.cloud {\n\treverse_proxy localhost:9100\n}\n'
  } > "$CADDY"
}
collateral_intact() { [ "$(grep -c 'reverse_proxy localhost:9100' "$CADDY")" = 1 ]; }

# setup_flip <upstream> [blue_port] [green_port]
setup_flip() {
  cleanup_flip
  PROV_ARG=""   # each case opts IN to the provisioner block; never inherited
  FTMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-deploy-flip.XXXXXX")"
  APPDIR="$FTMP/opt/barkpark"; FAKEBIN="$FTMP/bin"; DSTATE="$FTMP/dstate"
  CADDY="$FTMP/etc/caddy/Caddyfile"
  DOCKERLOG="$FTMP/docker.log"; GITLOG="$FTMP/git.log"; SYSCTLLOG="$FTMP/systemctl.log"
  mkdir -p "$APPDIR/cloud" "$FAKEBIN" "$DSTATE" "$FTMP/etc/caddy" "$APPDIR/scripts/lib"
  # The health probes source $APP/scripts/lib/bp-curl.sh (429 backoff,
  # task-90059c5c680f6665). The sandbox IS the $APP the script sees, so it must
  # carry the helper — otherwise every arm below silently takes the script's
  # named degrade path and this harness proves nothing about the real helper
  # (the #17562 deploy-receipt-failure.test.sh trap).
  cp "$HERE/../scripts/lib/bp-curl.sh" "$APPDIR/scripts/lib/bp-curl.sh"
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
      BARKPARK_PROVISIONER_BIN="$FTMP/usr-local-bin-barkpark-provisioner" \
      DOCKERLOG="$DOCKERLOG" GITLOG="$GITLOG" SYSCTLLOG="$SYSCTLLOG" DSTATE="$DSTATE" \
      "$@" bash "${RUN_SCRIPT:-$SCRIPT}" ${PROV_ARG:+"$PROV_ARG"} > "$FTMP/out.log" 2>&1
  echo "$?"
}

# The provisioner block only runs when the CD workflow passes a cross-built
# binary as $1. Every case above leaves PROV_ARG empty (the "no provisioner
# binary passed" path); the provisioner cases set it.
with_provisioner() {
  PROV_ARG="$FTMP/barkpark-provisioner.new"
  printf '#!/bin/sh\nexit 0\n' > "$PROV_ARG"; chmod +x "$PROV_ARG"
  printf 'OLD-PROVISIONER\n' > "$FTMP/usr-local-bin-barkpark-provisioner"
}

PROV_ARG=""
RUN_SCRIPT=""   # cases run the repo script unless one opts into a copy
upstream() { grep -oE 'reverse_proxy [^ ]+' "$CADDY" | head -1 | awk '{print $2}'; }

# ---- Case 1: a healthy deploy flips blue(:4100) -> green(:4101) and retires blue
setup_flip localhost:4100
rc="$(run_flip)"
check "healthy: exit 0"                          "[ '$rc' = '0' ]"
check "healthy: Caddy upstream moved to :4101"   "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "healthy: Caddyfile still caddy-valid"     "caddy validate --config '$CADDY' >/dev/null 2>&1"
check "healthy: green slot booted"               "[ -f '$DSTATE/running.4101' ]"
check "healthy: old blue slot retired AFTER the flip" "[ ! -f '$DSTATE/running.4100' ]"
# COLLATERAL SCOPE — the analogue of the static engine's ":4010 / :4020
# untouched" rows (instance-deploy_test.sh:365,373). The flip is a file-wide
# `sed s/localhost:$ACTIVE_PORT/localhost:$TARGET_PORT/g` over the WHOLE
# Caddyfile, so every other site the box fronts is inside its blast radius: a
# pattern widened to `localhost:` , a port typo'd to a prefix another site
# shares, or a rewrite moved off the anchored port would rewrite them too and
# nothing else in this file would notice. cp-deploy's fixture had exactly ONE
# upstream, so no assertion here could distinguish "flipped the slot" from
# "flipped everything".
check "healthy: the unrelated :9100 upstream survived the flip sed, exactly once" "collateral_intact"
check "healthy: exactly one slot upstream in the file (the flip rewrote one line, not many)" \
  "[ \"\$(grep -c 'localhost:410[01]' '$CADDY')\" = '1' ]"

# ---- Case 1b: QUEUED behind the deploy lock — the wait must not be SILENT
# (task-8811b4b25c529dbe). MEASURED on main 2026-09-05..06: ten of the last
# fourteen failed deploy.yml runs died with `client_loop: send disconnect:
# Broken pipe` / exit 255, every one AFTER logging the "holds the lock" line.
# The deploy was fine; the ssh session carrying it was idle for the length of
# the lock wait and the runner NAT dropped it. A heartbeat is what puts bytes on
# that session — and what lets a human reading the log tell a queue from a hang.
#
# The fake flock refuses `-n` (someone holds it) and times out THREE `-w` waits
# before granting, so the wait crosses more than two heartbeat intervals with
# the interval driven down to 1 s. Nothing here sleeps: the budget arithmetic is
# what is under test, not the clock.
setup_flip localhost:4100
cat > "$FAKEBIN/flock" <<'FLOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
  -n) exit 1 ;;
  -w) n=$(cat "$FLOCK_TRIES" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$FLOCK_TRIES"
      [ "$n" -le "${FLOCK_BLOCK_N:-0}" ] && exit 1
      exit 0 ;;
esac
exit 0
FLOCKEOF
chmod +x "$FAKEBIN/flock"
: > "$FTMP/flock.tries"
rc="$(run_flip "FLOCK_TRIES=$FTMP/flock.tries" FLOCK_BLOCK_N=3 BARKPARK_LOCK_HEARTBEAT_SECS=1)"
check "queued: the deploy still completes once the lock frees" "[ '$rc' = '0' ]"
check "queued: the queueing line is still logged"  "grep -q 'another deploy holds the lock' '$FTMP/out.log'"
check "queued: at least one HEARTBEAT while waiting (the ssh session carries bytes)" \
  "[ \"\$(grep -c 'still queued for the deploy lock' '$FTMP/out.log')\" -ge 1 ]"
check "queued: one heartbeat PER interval, not one for the whole wait" \
  "[ \"\$(grep -c 'still queued for the deploy lock' '$FTMP/out.log')\" = '3' ]"
check "queued: the heartbeat names seconds waited AND the unchanged 1800s budget" \
  "grep -qE 'still queued for the deploy lock — [0-9]+s waited of 1800s max' '$FTMP/out.log'"
check "queued: the lock was actually taken, not bypassed (the flip happened)" \
  "[ \"\$(upstream)\" = 'localhost:4101' ]"

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
check "public probe fails: the unrelated :9100 upstream survived the revert sed too" "collateral_intact"

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
# ===========================================================================
# THE WEDGED ENDPOINT (dr-w20-bl-cp-deploy-cannot-clear-a-wedged-endpoint)
#
# ROOT CAUSE these guard: 2026-07-21T07:59:48Z..07-23T08:46:54Z, 48h47m, 121
# deploy.yml runs, 84 failures, ZERO successes — ONE stale docker network
# endpoint (id 9a7aab2dba5b, byte-identical across 27 hours) that the daemon
# named in every refusal, in two phrasings. The only in-tree mitigation was a
# sleep-3-and-retry-once, measured 0-FOR-65: a stale endpoint is DAEMON STATE
# and sleeping does not remove daemon state, so the retry met the same refusal.
# The blackout ended by hand — cloud_default was destroyed and recreated at
# 2026-07-23T09:48:58Z (read off barkpark-cp; the network's own Created stamp) —
# with no commit anywhere in the tree.
#
# The fakes drive the real script: `compose up` refuses with the daemon's exact
# wording until `docker network disconnect` has actually been called, so nothing
# here can pass by retrying. Endpoint liveness is a real probe (`docker inspect`
# fails for any id spelled *GONE), and the SERVING slot's endpoint is spelled
# GONE too — so only the by-name guard keeps it plugged in.
# ===========================================================================
echo
echo "cp-deploy wedged endpoint (dr-w20-bl-cp-deploy-cannot-clear-a-wedged-endpoint)"

n_disconnect() { grep -c "^docker network disconnect" "$DOCKERLOG"; }

# ---- Case 15: the blackout's own message -> the endpoint is CLEARED and the
# deploy completes. FAIL-BEFORE: the old script sleeps 3s, retries, meets the
# identical refusal, logs "db/postfix up FAILED twice" and exits 13.
setup_flip localhost:4100
rc="$(run_flip WEDGE=1)"
check "wedge: exit 0 — the deploy COMPLETES (old script: exit 13)" "[ '$rc' = '0' ]"
check "wedge: the daemon's refusal is recognised as the wedge, not a generic race" \
  "grep -q 'refused on a WEDGED ENDPOINT' '$FTMP/out.log'"
check "wedge: the stale endpoint is named with its container" \
  "grep -q \"STALE ENDPOINT on cloud_default: 'cloud-control_plane_green-1'\" '$FTMP/out.log'"
check "wedge: docker network disconnect -f ran on cloud_default with the right name" \
  "grep -q '^docker network disconnect -f cloud_default cloud-control_plane_green-1\$' '$DOCKERLOG'"
check "wedge: EXACTLY one endpoint was disconnected" "[ \"\$(n_disconnect)\" = '1' ]"
# THE GUARD. cloud-control_plane_blue-1 is the slot Caddy is serving and its id
# is spelled GONE, so the staleness probe alone would unplug it — taking the
# live control plane off the network mid-deploy. Only the by-name serving-slot
# check stops that.
check "wedge: the SERVING slot's endpoint was NEVER disconnected (the guard)" \
  "! grep -q 'disconnect .*cloud-control_plane_blue-1' '$DOCKERLOG'"
check "wedge: the guard says so out loud" \
  "grep -q \"endpoint 'cloud-control_plane_blue-1' is the SERVING slot on :4100\" '$FTMP/out.log'"
check "wedge: a LIVE container's endpoint was left alone" \
  "! grep -q 'disconnect .*cloud-db-1' '$DOCKERLOG'"
check "wedge: the flip still landed on :4101" "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "wedge: green slot booted" "[ -f '$DSTATE/running.4101' ]"
check "wedge: old blue slot retired after the flip" "[ ! -f '$DSTATE/running.4100' ]"

# ---- Case 16: the SIBLING phrasing (15 of the 84 runs) reaches the clearer
# too. It arrived on the SLOT BOOT path, not db/postfix, and ended in "SLOT BOOT
# FAILED" — a detector that matched only the first phrasing would miss a fifth
# of the outage.
setup_flip localhost:4100
rc="$(run_flip WEDGE=2)"
check "sibling phrasing: exit 0" "[ '$rc' = '0' ]"
check "sibling phrasing: 'is not connected to the network' also detected as the wedge" \
  "grep -q 'refused on a WEDGED ENDPOINT' '$FTMP/out.log'"
check "sibling phrasing: the endpoint was disconnected" \
  "grep -q '^docker network disconnect -f cloud_default cloud-control_plane_green-1\$' '$DOCKERLOG'"
check "sibling phrasing: the flip landed" "[ \"\$(upstream)\" = 'localhost:4101' ]"

# ---- Case 17: the daemon names a wedge but NOTHING is stale -> the clearer
# must not invent work, must not loop, and must not mask the failure. Exactly
# one retry, an honest exit 13, and the live slot untouched.
setup_flip localhost:4100
rc="$(run_flip WEDGE=1 WEDGE_UNCLEARABLE=1)"
check "unclearable wedge: exit 13 (fails honestly, does not mask)" "[ '$rc' = '13' ]"
check "unclearable wedge: says nothing was stale" \
  "grep -q 'none of cloud_default.*endpoints is stale' '$FTMP/out.log'"
check "unclearable wedge: NOTHING was disconnected" "[ \"\$(n_disconnect)\" = '0' ]"
check "unclearable wedge: the LIVE blue slot was never stopped" "[ -f '$DSTATE/running.4100' ]"
check "unclearable wedge: Caddy never moved" "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "unclearable wedge: nothing was pruned" "! grep -q 'image prune' '$DOCKERLOG'"

# ---- Case 18: the docker version is ASSERTED and LOGGED. The blackout was a
# daemon-behaviour bug and the box's docker is mutable state no commit records,
# so a version change must at least be dateable from the deploy log. A mismatch
# WARNS and never refuses — a stale pin that blocks every deploy is worse than
# drift you can read.
setup_flip localhost:4100
rc="$(run_flip)"
check "docker version: logged on every deploy" \
  "grep -q 'docker server 29.6.1 / compose 5.2.0' '$FTMP/out.log'"
check "docker version: the expected major raises no warning" \
  "! grep -q 'is not the expected' '$FTMP/out.log'"

setup_flip localhost:4100
rc="$(run_flip FAKE_DOCKER_VERSION=31.0.2)"
check "docker version drift: WARNS, naming both versions" \
  "grep -q 'docker server 31.0.2 is not the expected 29.x' '$FTMP/out.log'"
check "docker version drift: never refuses the deploy (exit 0)" "[ '$rc' = '0' ]"
check "docker version drift: the flip still landed" "[ \"\$(upstream)\" = 'localhost:4101' ]"

setup_flip localhost:4100
rc="$(run_flip BARKPARK_EXPECT_DOCKER_MAJOR=29)"
check "docker version: the expectation is overridable" "[ '$rc' = '0' ]"

# ---- Case 19: the GIT WIRE PROTOCOL PIN on the pull (the 2026-09-02 outage).
# barkpark-cp runs git 2.34.1, whose protocol-v2 ref-listing parse fails against
# GitHub with "could not read Username" + "expected flush after ref listing";
# v0 and v1 both succeed from the same box. Every control-plane deploy from
# ~15:22Z died at this pull while the instance job (git 2.43) stayed green.
# Nothing in CI can reach that box, so this is a STATIC assertion — which is
# exactly why it must be anchored to the pull line itself and not to the file:
# a file-wide `grep -q protocol.version` would stay green if the pin migrated
# to a comment, or to some other git call, and the deploy would strand again.
# shellcheck disable=SC2034  # read inside check's eval strings below, which shellcheck does not follow
PULL_LINE="$(grep '^git .*pull --ff-only origin main' "$SCRIPT")"
check "found the control-plane pull line" "[ -n \"\$PULL_LINE\" ]"
one_pull_line() { [ "$(grep -c '^git .*pull --ff-only origin main' "$SCRIPT")" = 1 ]; }
check "exactly one such pull line exists (this assertion hides no sibling)" "one_pull_line"
check "the pull pins the wire protocol to v0 ON THE PULL ITSELF" \
  "case \"\$PULL_LINE\" in *'-c protocol.version=0'*) true ;; *) false ;; esac"
check "the pull still suppresses the post-merge hook (the pin did not displace it)" \
  "case \"\$PULL_LINE\" in *'-c core.hooksPath=/dev/null'*) true ;; *) false ;; esac"
check "the pull is still --ff-only (the pin did not weaken the fast-forward guard)" \
  "case \"\$PULL_LINE\" in *'--ff-only'*) true ;; *) false ;; esac"
# The signature is recorded NEXT TO the pin so a future reader who cannot
# reproduce it from a modern box does not delete the pin as cargo cult.
check "the failing signature is recorded in the script (the auth-prompt line)" \
  "grep -q \"could not read Username for 'https://github.com'\" '$SCRIPT'"
check "the failing signature is recorded in the script (the ref-listing line)" \
  "grep -q 'expected flush after ref listing' '$SCRIPT'"
check "the box's git version is recorded next to the pin" \
  "grep -q 'git 2.34.1' '$SCRIPT'"

# ---- Case 19b: the origin probe NAMES which of THREE faults hides behind the one
# "could not read Username" line (task-a14a2f489452e95d). 2026-09-02: three hours
# of bare "pull failed". The probe must run the pull's OWN protocol pin, quote
# git's stderr verbatim, run the differential (unpinned retry, anonymous
# info/refs), name a verdict, emit an ::error:: line, exit 11, and never pull.
setup_flip localhost:4100
: > "$GITLOG"
rc="$(run_flip GIT_ORIGIN_FAIL=auth CURL_INFO_REFS=401)"
check "private-repo probe: exit 11" "[ '$rc' = '11' ]"
check "private-repo probe: verdict names REPO PRIVATE and past-mistake #9" \
  "grep -q 'REPO PRIVATE' '$FTMP/out.log' && grep -q 'past-mistake #9' '$FTMP/out.log'"
check "private-repo probe: git stderr quoted VERBATIM, prefixed" \
  "grep -q \"git: fatal: could not read Username for 'https://github.com': No such device or address\" '$FTMP/out.log'"
check "private-repo probe: the second stderr line survives too" \
  "grep -q 'git: fatal: expected flush after ref listing' '$FTMP/out.log'"
check "private-repo probe: ::error:: carries the verdict for the check-run summary" \
  "grep -q '::error::cp-deploy: pull refused — REPO PRIVATE' '$FTMP/out.log'"
check "private-repo probe: the probe ran the pull's own protocol pin" \
  "grep -qE 'git .*protocol.version=0 .*ls-remote' '$GITLOG'"
check "private-repo probe: the pull itself never ran" "! grep -qE 'git .*pull --ff-only' '$GITLOG'"
check "private-repo probe: no bare 'pull failed' line survives" "! grep -q '] pull failed' '$FTMP/out.log'"
: > "$GITLOG"
rc="$(run_flip GIT_ORIGIN_FAIL=auth CURL_INFO_REFS=200)"
check "unauthenticated-remote probe: anonymous info/refs 200 → REMOTE UNAUTHENTICATED, exit 11" \
  "[ '$rc' = '11' ] && grep -q 'REMOTE UNAUTHENTICATED' '$FTMP/out.log' && ! grep -q 'REPO PRIVATE' '$FTMP/out.log'"
: > "$GITLOG"
rc="$(run_flip GIT_ORIGIN_FAIL=v0only CURL_INFO_REFS=200)"
check "stale-pin probe: v0 refused but the default handshake works → PROTOCOL PIN STALE, exit 11" \
  "[ '$rc' = '11' ] && grep -q 'PROTOCOL PIN STALE' '$FTMP/out.log' && ! grep -qE 'REPO PRIVATE|REMOTE UNAUTHENTICATED' '$FTMP/out.log'"
: > "$GITLOG"
rc="$(run_flip GIT_ORIGIN_FAIL=net)"
check "network probe: exit 11 with the network classification, none of the three auth verdicts" \
  "[ '$rc' = '11' ] && grep -q 'origin refused the ref listing (network' '$FTMP/out.log' && ! grep -qE 'PROTOCOL PIN STALE|REMOTE UNAUTHENTICATED|REPO PRIVATE' '$FTMP/out.log'"
# NEGATIVE ARM 1 — the probe must not refuse the very box the pin above exists for.
# GIT_ORIGIN_FAIL=v2only is barkpark-cp's 2026-09-02 git 2.34.1: protocol v2
# refused, v0 fine. A probe that did not carry the pin would red here.
: > "$GITLOG"
rc="$(run_flip GIT_ORIGIN_FAIL=v2only)"
check "pinned box (v2 refused, v0 fine): the probe passes and the deploy proceeds" "[ '$rc' = '0' ]"
check "pinned box: the pull still ran" "grep -qE 'git .*pull --ff-only' '$GITLOG'"
check "pinned box: no refusal verdict was printed" \
  "! grep -q 'pull refused before it ran' '$FTMP/out.log'"
# NEGATIVE ARM 2 — a healthy origin leaves the pull path behaviourally identical:
# the deploy still exits 0, still flips, and the probe adds exactly ONE log line.
# Fresh setup_flip: the arm above already consumed one flip (4100 -> 4101), and a
# second deploy from that state flips BACK, so re-asserting 4101 needs a reset.
setup_flip localhost:4100
: > "$GITLOG"
rc="$(run_flip)"
check "healthy origin: the probe passes and the pull runs" \
  "[ '$rc' = '0' ] && grep -qE 'git .*pull --ff-only' '$GITLOG'"
check "healthy origin: the flip still landed" "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "healthy origin: the probe adds exactly one log line, no ::error::" \
  "[ \"\$(grep -c 'git ls-remote origin (probe before pull' '$FTMP/out.log')\" = 1 ] && ! grep -q '::error::' '$FTMP/out.log'"
rm -rf "$FTMP"

# ===========================================================================
# THE PROVISIONER RESTART GATE
# (dr-w20-bl-provisioner-restart-cannot-fail-the-deploy / dr-w19 criterion 2)
#
# ROOT CAUSE these guard: cp-deploy.sh is `set -uo pipefail` with NO -e. The
# restart ran with no `||` and no rc test, and the whole verdict was
# `log "provisioner: $(systemctl is-active barkpark-provisioner)"` — a line
# that PRINTS the word `failed` and then falls through to `log DONE` and exit
# 0. Provisioning IS the control plane's product, so a green deploy could ship
# a box that cannot create a single instance, and deploy.yml's smoke (a curl of
# `/`) cannot see it.
#
# The block only runs when a provisioner binary is passed as $1 (the CD
# workflow scps a cross-built one), which is why every case above — none of
# which passes one — never reached it. with_provisioner arms that path.
# ===========================================================================
echo
echo "cp-deploy provisioner restart gate (dr-w20-bl-provisioner-restart-cannot-fail-the-deploy)"

# ---- Case 20: provisioner comes back active -> the deploy is a normal exit 0
setup_flip localhost:4100
with_provisioner
rc="$(run_flip)"
check "provisioner ok: exit 0"                    "[ '$rc' = '0' ]"
check "provisioner ok: the restart ran"           "grep -q '^systemctl restart barkpark-provisioner\$' '$SYSCTLLOG'"
check "provisioner ok: the state is logged WITH the restart rc" \
  "grep -q 'provisioner: active (restart rc=0)' '$FTMP/out.log'"
check "provisioner ok: the deploy still reports DONE" "grep -q 'DONE — control plane slot' '$FTMP/out.log'"
check "provisioner ok: nothing was restored"      "[ ! -f '$DSTATE/prov.restored' ]"
check "provisioner ok: the flip stands"           "[ \"\$(upstream)\" = 'localhost:4101' ]"

# ---- Case 21: THE FILED DEFECT. `systemctl restart` returns 0 but the unit
# lands in `failed` — a worker that crashes on boot. This is the exact arm the
# old code printed and ignored.
# FAIL-BEFORE (main): rc 0, the log carries the literal line
# `[cp-deploy …] provisioner: failed`, and the very next line is
# `DONE — control plane slot green live at …`.
setup_flip localhost:4100
with_provisioner
rc="$(run_flip PROV_IS_ACTIVE=failed)"
check "provisioner failed: exit 18 (NOT 0 — a dead worker cannot ride a green deploy)" "[ '$rc' = '18' ]"
check "provisioner failed: the failure is named, not merely interpolated" \
  "grep -q 'PROVISIONER FAILED TO COME BACK' '$FTMP/out.log'"
check "provisioner failed: the log states the run is red while the slot IS live" \
  "grep -q 'IS LIVE and was NOT rolled back' '$FTMP/out.log'"
check "provisioner failed: the previous binary was restored" "[ -f '$DSTATE/prov.restored' ]"
check "provisioner failed: the worker was restarted again after the restore" \
  "[ \"\$(grep -c '^systemctl restart barkpark-provisioner\$' '$SYSCTLLOG')\" -ge 2 ]"
check "provisioner failed: the unit's status is dumped for the human" \
  "grep -q '\\[provisioner\\]' '$FTMP/out.log'"
# The flip is NOT unwound: it was proven publicly healthy before this step and
# the old slot is already retired. Failing the RUN is the whole remedy.
check "provisioner failed: the proven flip was NOT unwound"  "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "provisioner failed: the new slot is still serving"    "[ -f '$DSTATE/running.4101' ]"
check "provisioner failed: the script did NOT print DONE"    "! grep -q 'DONE — control plane slot' '$FTMP/out.log'"

# ---- Case 22: the OTHER arm — `systemctl restart` itself exits non-zero (the
# unit file is broken, the binary is not executable). Under `set -uo pipefail`
# with no -e this returned control to the script with nothing recorded at all.
setup_flip localhost:4100
with_provisioner
rc="$(run_flip PROV_RESTART_RC=1 PROV_IS_ACTIVE=failed)"
check "restart rc!=0: exit 18"                    "[ '$rc' = '18' ]"
check "restart rc!=0: the rc is in the log"       "grep -q 'restart rc=1' '$FTMP/out.log'"
check "restart rc!=0: the previous binary was restored" "[ -f '$DSTATE/prov.restored' ]"
check "restart rc!=0: no DONE"                    "! grep -q 'DONE — control plane slot' '$FTMP/out.log'"

# ---- Case 23: the restore WORKS — the previous binary boots. The run is still
# red (a deploy that could not ship its worker did not succeed), but the box is
# left with a LIVE provisioner rather than a dead one.
setup_flip localhost:4100
with_provisioner
rc="$(run_flip PROV_IS_ACTIVE=failed PROV_RECOVER_ON_RESTORE=1)"
check "restore recovers: still exit 18 (the run does not claim success)" "[ '$rc' = '18' ]"
check "restore recovers: the recovered state is logged" \
  "grep -q 'provisioner after restoring the previous binary: active' '$FTMP/out.log'"

# ---- Case 24: no binary passed -> the block is skipped entirely and a deploy
# that never touched the worker is not held to the worker's health. This is the
# path every OTHER case in this file takes, asserted here so a future change
# that makes the gate unconditional reds.
setup_flip localhost:4100
rc="$(run_flip PROV_IS_ACTIVE=failed)"
check "no binary passed: exit 0 even with a failed unit" "[ '$rc' = '0' ]"
check "no binary passed: the skip is stated"      "grep -q 'no provisioner binary passed' '$FTMP/out.log'"
check "no binary passed: no provisioner restart was issued" \
  "! grep -q '^systemctl restart barkpark-provisioner\$' '$SYSCTLLOG'"

# ---- Static: the restart's result is TESTED, not interpolated into a log.
# Anchored at the script, so deleting the gate and going back to the one-liner
# reds here even if the harness fakes drift.
check "the script tests the restart rc rather than firing it bare" \
  "grep -q 'systemctl restart \"\$PROV_UNIT_NAME\" || restart_rc=' '$SCRIPT'"
check "exactly one provisioner restart-with-rc-capture exists (this hides no sibling)" \
  "[ \"\$(grep -c 'systemctl restart \"\$PROV_UNIT_NAME\" || restart_rc=' '$SCRIPT')\" = '1' ]"
check "the script exits non-zero on a provisioner that did not come back" \
  "grep -q 'exit 18' '$SCRIPT'"

# ---- Static: the documented rollback recipe RECREATES, it does not `docker
# start` (gr-blk-cp-deploy-rollback-stale-env criterion 0). `docker start`
# replays the env baked into the container at creation time, so a rollback onto
# a slot older than a cloud/.env change silently serves the old env.
echo
echo "cp-deploy documented rollback recipe (gr-blk-cp-deploy-rollback-stale-env)"
# These three used to pin the PROSE recipe that replaced the `docker start` one.
# The recipe is now EXECUTABLE (do_rollback + --rollback), so they pin the code
# instead: a comment can be followed wrong, and under pressure it will be.
# Retargeted, not deleted — the property each asserted is unchanged.
check "the retired 'reload caddy, docker start it' recipe is gone as an instruction" \
  "[ \"\$(grep -c 'reload caddy, .docker start. it\\.' '$SCRIPT')\" = '0' ]"
check "the rollback recreates the container" \
  "grep -q -- '--force-recreate' '$SCRIPT'"
check "the rollback re-exports cloud/.env first (the same door the deploy uses)" \
  "[ \"\$(grep -c 'set -a' '$SCRIPT')\" -ge 2 ]"
check "the recipe retags the rollback image (both slots are :latest in compose)" \
  "grep -q 'docker tag cloud-control_plane:rollback cloud-control_plane:latest' '$SCRIPT'"
check "the script still saves that rollback tag before the pull" \
  "grep -q '^docker tag cloud-control_plane:latest cloud-control_plane:rollback' '$SCRIPT'"

# ---- Case 25 (dr-private-copy): the script file is REWRITTEN under the running
# bash and the deploy still completes on the ORIGINAL bytes.
#
# ROOT CAUSE: deploy.yml scps this script to the SHARED /tmp/cp-deploy.sh on
# barkpark-cp and runs `bash /tmp/cp-deploy.sh`. bash reads a script by byte
# offset from an fd it keeps open while executing, so a later run's scp — normal
# under our merge cadence, where queued runs sit on the deploy lock — rewrites
# that file under a running deploy, which then reads shifted bytes of a
# DIFFERENT file. Observed twice in nine runs: run 34021843141 "line 329:
# return: can only `return' from a function or sourced script" / "line 334: what:
# unbound variable", run 34025907184 "line 383: syntax error near unexpected
# token `)'" — function bodies executed as top-level code.
#
# The case runs a COPY of the script (never the repo file) and has the fake
# docker rewrite that copy on the deploy's FIRST outside command. The clobber is
# asserted to have actually landed, so a hook that silently stopped firing reds
# here instead of passing vacuously.
setup_flip localhost:4100
RUN_SCRIPT="$FTMP/cp-deploy.shared.sh"
cp "$SCRIPT" "$RUN_SCRIPT"
rc="$(run_flip CLOBBER_TARGET="$RUN_SCRIPT")"
check "clobber: the harness actually rewrote the script file mid-run (non-vacuity)" \
  "[ -f '$DSTATE/clobbered' ] && grep -q 'this is not bash' '$RUN_SCRIPT'"
check "clobber: the rewritten file is no longer the script" \
  "! grep -q 'BARKPARK_DEPLOY_PRIVATE_COPY' '$RUN_SCRIPT'"
check "clobber: exit 0 — the run completed on its own bytes"  "[ '$rc' = '0' ]"
check "clobber: no bash parse error in the run's output" \
  "! grep -qE 'syntax error|unexpected token|can only .return. from a function' '$FTMP/out.log'"
check "clobber: the flip still happened (:4101)"  "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "clobber: green slot booted"                "[ -f '$DSTATE/running.4101' ]"
check "clobber: old blue slot retired"            "[ ! -f '$DSTATE/running.4100' ]"
check "clobber: the private copy left nothing behind in TMPDIR" \
  "[ -z \"\$(find \"${TMPDIR:-/tmp}\" -maxdepth 1 -name 'bp-deploy-self.*' -print -quit 2>/dev/null)\" ]"
RUN_SCRIPT=""

# ---- Static: the private-copy preamble, in EVERY sibling the CD workflows scp
# to a shared /tmp path and then `bash`. Derived from the workflows, not from
# memory: .github/workflows/deploy.yml scps cp-deploy.sh (control plane) and
# instance-deploy.sh (guerrilla); .github/workflows/cp-ops.yml streams
# site-runtime-install.sh. A new script joining that list without the preamble
# is the same defect again, so the count is asserted, not just the presence.
echo
echo "private-copy preamble across the scp'd siblings (dr-private-copy)"
SIBLINGS="cp-deploy.sh instance-deploy.sh site-runtime-install.sh"
for sib in $SIBLINGS; do
  check "$sib re-execs from a private copy before doing anything" \
    "grep -q 'exec bash \"\$__bp_self\" \"\\\$@\"' '$HERE/$sib'"
  check "$sib guards the copy on the copy's own PATH (an inherited flag cannot delete the real script)" \
    "grep -q '\\[ \"\${BARKPARK_DEPLOY_PRIVATE_COPY:-}\" = \"\$0\" \\]' '$HERE/$sib'"
  check "$sib puts the copy outside any checkout (mktemp in TMPDIR), never beside itself" \
    "grep -q 'mktemp \"\${TMPDIR:-/tmp}/bp-deploy-self.XXXXXX\"' '$HERE/$sib'"
  check "$sib unlinks the copy as it starts, so a killed run leaks nothing" \
    "grep -q 'rm -f \"\$0\" 2>/dev/null' '$HERE/$sib'"
  check "$sib warns rather than refusing when the copy cannot be made" \
    "grep -q 'private-copy. WARNING' '$HERE/$sib'"
  check "$sib runs the preamble BEFORE its set -.uo pipefail line" \
    "[ \"\$(grep -n 'BARKPARK_DEPLOY_PRIVATE_COPY' '$HERE/$sib' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^set -[eu]' '$HERE/$sib' | head -1 | cut -d: -f1)\" ]"
done

# ── the wedged-endpoint predicate survives a LONG compose transcript ─────────
# BEHAVIOURAL, not a grep for the source shape. compose_up_repair decides on
# `$out`, a whole `compose up -d 2>&1` transcript, and the daemon names the
# wedged endpoint EARLY in it. Written as `printf '%s' "$out" | grep -qE …`,
# under this file's and cp-deploy.sh's `pipefail`, grep -q answers at that first
# match and closes the pipe, printf takes SIGPIPE and dies 141, and pipefail
# returns 141 as the pipeline's status — which is not 0, so the branch reads
# "not a wedged endpoint" and the repair is SKIPPED. That is the 2026-07-21
# 48h47m blackout's sleep-and-retry, measured 0-for-65.
#
# It is OUTPUT-LENGTH DEPENDENT: a short transcript fits the pipe buffer and
# never SIGPIPEs, so a fixture SHORTER than the buffer would pass either way and
# this check would be vacuous. The fixture is deliberately >64KB, with the error
# on line 1 and thousands of lines of container progress after it.
echo
echo "== compose_up_repair's wedged-endpoint predicate, over a >64KB transcript =="
long_out="Error response from daemon: network cloud_default has active endpoints (name:\"cloud-control_plane_green-1\" id:\"9a7aab2dba5b\")"
_svc=0
while [ "${#long_out}" -lt 200000 ]; do
  _svc=$((_svc + 1))
  long_out="$long_out
 Container barkpark-svc-$_svc  Creating
 Container barkpark-svc-$_svc  Created
 Container barkpark-svc-$_svc  Starting
 Container barkpark-svc-$_svc  Started"
done
# non-vacuity: the fixture must actually be big enough to SIGPIPE, and it must
# actually contain the string, or a green below proves nothing.
check "the long-transcript fixture clears the 64KB pipe buffer" \
  "[ ${#long_out} -gt 65536 ]"
check "the long-transcript fixture really contains the wedged-endpoint phrase" \
  "case \"\$long_out\" in *'has active endpoints'*) true ;; *) false ;; esac"
# the RED-before arm: prove the piped form still fails on this fixture, so this
# check is measuring the defect and not the weather.
_piped_rc=0
# stderr silenced: the write error IS the SIGPIPE, and it is the point — but it
# would read as a harness fault in the log.  The status is what is asserted.
printf '%s' "$long_out" 2>/dev/null | grep -qE 'has active endpoints|is not connected to the network' || _piped_rc=$?
check "the piped form DOES return non-zero on it (the defect is real here, not a ghost)" \
  "[ $_piped_rc -ne 0 ]"
# and cp-deploy.sh's ACTUAL predicate, lifted from the file, answers TRUE.
_pred="$(grep -oE "grep -qE 'has active endpoints[^']*' <<<" "$HERE/cp-deploy.sh" | head -1)"
check "cp-deploy.sh decides the wedged endpoint WITHOUT a pipe into grep -q" \
  "[ -n \"\$_pred\" ]"
_fixed_rc=0
grep -qE 'has active endpoints|is not connected to the network' <<<"$long_out" || _fixed_rc=$?
check "the pipe-less form answers TRUE (exit 0) on the same >64KB transcript" \
  "[ $_fixed_rc -eq 0 ]"

# ===========================================================================
# THE CUTOVER LEDGER (dr-w26-bl-cp-deploy-eats-a-scheduled-sampler-tick)
# ===========================================================================
# `deploy/cp-cutover-gaps.sh --self-test` is an offline check suite over the ledger
# (the count is published once, in deploy/README.md, and READ BACK by that engine
# itself — naming it a second time here is how the two copies drift)
# cp-deploy.sh writes and the analyzer that reads it. It is CHAINED here rather
# than registered as its own step because `.github/workflows/deploy-harnesses.yml`
# names each harness explicitly and this harness is already in that list — a
# self-test that no workflow invokes is a gate nobody runs.
#
# Captured as `out=$(...); rc=$?`, never piped into tail/grep: a gate piped to
# another process reports THAT process's exit code, and empty output with rc=0
# is indistinguishable from a harness that never ran. Both the rc AND the
# child's own non-vacuity line are asserted.
GAPS="$HERE/cp-cutover-gaps.sh"
check "cp-cutover-gaps.sh exists beside cp-deploy.sh" "[ -r '$GAPS' ]"
if [ -r "$GAPS" ]; then
  gaps_out="$(bash "$GAPS" --self-test 2>&1)"; gaps_rc=$?
  check "cp-cutover-gaps.sh --self-test exits 0" "[ $gaps_rc -eq 0 ]"
  # The child's own floor line, asserted here too: a child that printed ALL PASS
  # having run zero checks must not launder a green up into this harness.
  # shellcheck disable=SC2034  # read inside check()'s eval string
  gaps_count="$(printf '%s\n' "$gaps_out" | sed -n 's/^ALL PASS (\([0-9]*\) checks)$/\1/p')"
  check "and it reports a check count (not a bare ALL PASS)" "[ -n \"\$gaps_count\" ]"
  check "and that count is at least 38 (the child's own non-vacuity floor)" \
    "[ -n \"\$gaps_count\" ] && [ \"\$gaps_count\" -ge 38 ]"
  if [ "$gaps_rc" -ne 0 ]; then printf '%s\n' "$gaps_out" | sed 's/^/    [gaps] /'; fi
fi
# Static arms on THIS script's side of the seam — EVERY stamp, never head -1.
# Deleting any one of the five leaves the ledger unable to bound its window and
# the analyzer then over- or under-attributes with no signal that it is doing so.
for _ev in deploy_start flip old_slot_stopped deploy_end deploy_aborted; do
  check "cp-deploy.sh stamps the cutover event '$_ev'" \
    "grep -qE '^[[:space:]]*cutover_stamp $_ev' '$SCRIPT'"
done
check "the ledger path is overridable for tests but defaults under the app dir" \
  "grep -q 'BARKPARK_CP_CUTOVER_LEDGER:-\$APP/.slots/cp-cutovers.log' '$SCRIPT'"
check "the ledger is line-bounded (a deploy-rate leak on a box whose disk filling is a recorded outage)" \
  "grep -q 'BARKPARK_CP_CUTOVER_LEDGER_MAX_LINES:-' '$SCRIPT'"
# deploy_start must come BEFORE anything that can replace a container, or the
# window it opens does not contain the loss it exists to explain. The slot
# decision line is the last point at which nothing has been built or booted.
_start_ln="$(grep -n '^cutover_stamp deploy_start' "$SCRIPT" | head -1 | cut -d: -f1)"
# The DEPLOY body's first container-replacing step. do_rollback() runs on a
# path that exits before the deploy body ever starts, so its own `compose up`
# is not inside the cutover window and must not be read as the window's first
# step — blank that function out (line numbers preserved) before looking.
_deploy_body="$(mktemp)"
awk '/^do_rollback\(\) \{/{inrb=1} {print (inrb ? "" : $0)} /^\}/{inrb=0}' "$SCRIPT" > "$_deploy_body"
_build_ln="$(grep -n 'compose build\|compose up' "$_deploy_body" | head -1 | cut -d: -f1)"
rm -f "$_deploy_body"
check "the window OPENS before the first container-replacing step" \
  "[ -n \"\$_start_ln\" ] && [ -n \"\$_build_ln\" ] && [ \"\$_start_ln\" -lt \"\$_build_ln\" ]"
# ...and it must CLOSE on both exits. An abort still replaced containers.
check "cutover_stamp deploy_aborted is inside abort_deploy(), not merely in the file" \
  "[ \"\$(awk '/^abort_deploy\(\) \{/,/^\}/' '$SCRIPT' | grep -c 'cutover_stamp deploy_aborted')\" -ge 1 ]"
check "a stamp failure can never fail the deploy (the function always returns 0)" \
  "[ \"\$(awk '/^cutover_stamp\(\) \{/,/^\}/' '$SCRIPT' | grep -c '^  return 0\$')\" -ge 1 ]"

# ============================================================================
# ROLLBACK — RECREATE, NEVER `docker start` (gr-blk-cp-deploy-rollback-stale-env)
# ============================================================================
# What is under test: cp-deploy.sh --rollback / --rollback-preflight, the
# EXECUTABLE replacement for a prose recipe that told an operator to
# `docker start` the dormant slot. `docker start` resumes an existing container
# object and replays the environment baked in when that container was CREATED,
# so a slot older than a cloud/.env change comes back on stale configuration
# with a 200 on every probe. There is no live box in this harness and there does
# not need to be: what the rollback path DOES is observable from the command log
# (a recreate, not a start), the Caddyfile, and the exit code.
#
# BOTH ARMS, deliberately. A rollback that refuses everything is not a fix
# either — the happy case below must stay green, and it is the arm that reds if
# a precondition is ever made too strict.
echo
echo "rollback path (gr-blk-cp-deploy-rollback-stale-env)"

# run_rollback <flag> [VAR=VAL …] -> prints the exit code
run_rollback() {
  local flag="$1"; shift
  env PATH="$FAKEBIN:$PATH" \
      BARKPARK_APP_DIR="$APPDIR" \
      BARKPARK_CADDYFILE="$CADDY" \
      BARKPARK_DEPLOY_LOCK="$FTMP/deploy.lock" \
      BARKPARK_PROVISIONER_UNIT="$FTMP/nonexistent-provisioner.service" \
      BARKPARK_PROVISIONER_BIN="$FTMP/usr-local-bin-barkpark-provisioner" \
      DOCKERLOG="$DOCKERLOG" GITLOG="$GITLOG" SYSCTLLOG="$SYSCTLLOG" DSTATE="$DSTATE" \
      "$@" bash "$SCRIPT" "$flag" > "$FTMP/out.log" 2>&1
  echo "$?"
}

# The state a rollback actually starts from: GREEN (:4101) is serving the bad
# deploy, BLUE (:4100) is the dormant slot the deploy left stopped.
setup_rollback() {
  setup_flip localhost:4101 4100 4101
  rm -f "$DSTATE/running.4100"
  touch "$DSTATE/running.4101"
}

# ---- R1: the HAPPY rollback. green(:4101) -> blue(:4100), recreated.
setup_rollback
rc="$(run_rollback --rollback)"
check "rollback: exit 0"                              "[ '$rc' = '0' ]"
check "rollback: Caddy upstream moved back to :4100"  "[ \"\$(upstream)\" = 'localhost:4100' ]"
check "rollback: Caddyfile still caddy-valid"         "caddy validate --config '$CADDY' >/dev/null 2>&1"
check "rollback: the dormant blue slot is running again" "[ -f '$DSTATE/running.4100' ]"
# THE FIX ITSELF. --force-recreate is the single flag that makes current
# cloud/.env reach the container; without it compose reuses the existing
# container and the rollback serves the env baked in at creation.
check "rollback: recreated the slot with --force-recreate (NOT a reuse)" \
  "grep -q 'compose.*up -d --force-recreate --no-build control_plane_blue' '$DOCKERLOG'"
# THE DEFECT THE ROW NAMES. Not "the log does not obviously start a container"
# — the literal command must be absent from everything the run issued.
check "rollback: NEVER issued 'docker start' (the stale-env recipe this replaced)" \
  "! grep -qE '^docker start( |\$)' '$DOCKERLOG'"
# The second defect the original recipe carried: both slots are :latest, so a
# recreate without the retag reinstalls the code being rolled back FROM.
check "rollback: retagged the rollback image to :latest before recreating" \
  "grep -q 'docker tag cloud-control_plane:rollback cloud-control_plane:latest' '$DOCKERLOG'"
# ORDER, not merely presence. The prose recipe flipped Caddy FIRST, pointing the
# public front at a port with nothing listening on it.
# shellcheck disable=SC2034  # read back inside the check eval below
rb_tag_ln="$(grep -n 'tag cloud-control_plane:rollback' "$DOCKERLOG" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2034  # read back inside the check eval below
rb_up_ln="$(grep -n 'up -d --force-recreate' "$DOCKERLOG" | head -1 | cut -d: -f1)"
check "rollback: the retag precedes the recreate (a recreate first would boot the NEW code)" \
  "[ -n \"\$rb_tag_ln\" ] && [ -n \"\$rb_up_ln\" ] && [ \"\$rb_tag_ln\" -lt \"\$rb_up_ln\" ]"
check "rollback: the slot was recreated and health-gated BEFORE caddy was reloaded" \
  "grep -q 'rollback slot blue healthy' '$FTMP/out.log'"
check "rollback: the unrelated :9100 upstream survived the rollback sed" "collateral_intact"
check "rollback: it did NOT run the deploy (no git pull, no compose build)" \
  "! grep -q 'git pull' '$GITLOG' && ! grep -q 'compose build' '$DOCKERLOG'"
# The bad slot stays up on purpose — stopping it is a human decision, and a
# rollback that tears down the evidence is a rollback nobody can diagnose.
check "rollback: the slot being rolled back FROM is left running for inspection" \
  "[ -f '$DSTATE/running.4101' ]"

# ---- R2: cloud/.env absent -> REFUSE. This is the whole point: the recipe that
# "works" here (docker start) is the one that serves stale env.
setup_rollback
rm -f "$APPDIR/cloud/.env"
rc="$(run_rollback --rollback)"
check "rollback/no-env: exit 21 (refused, not best-effort)"  "[ '$rc' = '21' ]"
check "rollback/no-env: the refusal names cloud/.env"        "grep -q 'cloud/.env is missing or unreadable' '$FTMP/out.log'"
check "rollback/no-env: the refusal warns against the docker start fallback" \
  "grep -q \"Do NOT fall back to 'docker start'\" '$FTMP/out.log'"
check "rollback/no-env: Caddy was NEVER touched"             "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "rollback/no-env: no container was recreated"          "! grep -q 'force-recreate' '$DOCKERLOG'"
check "rollback/no-env: the image tag was NOT moved"         "! grep -q 'docker tag' '$DOCKERLOG'"

# ---- R3: no rollback image -> REFUSE. Recreating now would reinstall the very
# code being rolled back from, and report success.
setup_rollback
rc="$(run_rollback --rollback ROLLBACK_IMAGE_MISSING=1)"
check "rollback/no-image: exit 22"                     "[ '$rc' = '22' ]"
check "rollback/no-image: the refusal explains the :latest collision" \
  "grep -q 'Both slots run cloud-control_plane:latest' '$FTMP/out.log'"
check "rollback/no-image: Caddy untouched"             "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "rollback/no-image: nothing was recreated"       "! grep -q 'force-recreate' '$DOCKERLOG'"

# ---- R4: the recreated slot never becomes healthy -> REFUSE, do not flip.
# The prose recipe had no gate at all: it flipped Caddy onto the old port and
# only then tried to bring the slot up.
setup_rollback
rc="$(run_rollback --rollback HEALTH_CODE=500)"
check "rollback/unhealthy: exit 26"                    "[ '$rc' = '26' ]"
check "rollback/unhealthy: Caddy still serves the slot that WAS serving" \
  "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "rollback/unhealthy: the refusal says the front was not moved" \
  "grep -q 'Caddy was NOT flipped' '$FTMP/out.log'"
check "rollback/unhealthy: caddy was never reloaded"   "! grep -q 'reload caddy' '$SYSCTLLOG'"

# ---- R5: --rollback-preflight is READ-ONLY and names the slot.
setup_rollback
rc="$(run_rollback --rollback-preflight)"
check "preflight: exit 0"                              "[ '$rc' = '0' ]"
check "preflight: names the dormant slot"              "grep -q '^ROLLBACK_SLOT=blue$' '$FTMP/out.log'"
check "preflight: names its port"                      "grep -q '^ROLLBACK_PORT=4100$' '$FTMP/out.log'"
check "preflight: names the live port"                 "grep -q '^LIVE_PORT=4101$' '$FTMP/out.log'"
check "preflight: Caddy untouched"                     "[ \"\$(upstream)\" = 'localhost:4101' ]"
check "preflight: no container touched"                "! grep -qE 'force-recreate|^docker start' '$DOCKERLOG'"
check "preflight: no image retagged"                   "! grep -q 'docker tag' '$DOCKERLOG'"
check "preflight: caddy never reloaded"                "! grep -q 'reload caddy' '$SYSCTLLOG'"

# ---- R6: an unrecognised flag is refused rather than silently treated as the
# provisioner-binary argument (which would run a FULL DEPLOY — the opposite of
# what the operator typed).
setup_rollback
rc="$(run_rollback --rollbck)"
check "typo'd flag: exit 2, not a deploy"              "[ '$rc' = '2' ]"
check "typo'd flag: names the accepted flags"          "grep -q 'want --rollback or --rollback-preflight' '$FTMP/out.log'"
check "typo'd flag: nothing was pulled"                "! grep -q 'git pull' '$GITLOG'"

# ---- R7: DOCUMENTATION GUARD, as a predicate rather than a list of two files'
# current wording. Every `docker start` mention that survives in the deploy lane
# must be a PROHIBITION, not a recommendation: the retired recipe's whole
# failure mode is that it read as helpful advice. The rule is "a `docker start`
# line must carry, within one line either side, a word that negates or explains
# it"; the match set is PRINTED, and a positive control below proves the scanner
# can actually flag a bad line — an absence claim from a silent scanner is
# worth nothing.
rb_scan() {
  awk '
    { l[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (l[i] !~ /docker start/) continue
        # DISTANCE IN CHARACTERS, not lines. A +-3 LINE window was fooled by
        # deploy/README.md, whose pipeline table is one 900-character line per
        # target: the neighbouring "Content instance" row contains "never" for
        # an unrelated reason, and that exempted a `docker start` recommendation
        # three rows away. Measured: with the retired README wording restored,
        # the line-window scanner stayed silent. 200 characters either side of
        # the occurrence itself is the same "same sentence" intent, and it holds
        # for both wrapped comment prose and one-line table rows.
        ctx = ""
        for (j = i - 3; j <= i + 3; j++) if (j >= 1 && j <= NR) ctx = ctx "\n" l[j]
        at = index(ctx, "docker start")
        near = substr(ctx, (at > 200 ? at - 200 : 1), 400 + length("docker start"))
        if (near ~ /[Nn]ever|NOT|not |[Dd]o not|refus|REFUS|stale|instead|rather than|replay|SILENT|used to|trap/) continue
        printf "%s:%d: %s\n", FILENAME, i, l[i]
      }
    }' "$1"
}
RB_HITS="$FTMP/rb-doc-hits.txt"
: > "$RB_HITS"
for f in "$SCRIPT" "$HERE/README.md"; do rb_scan "$f" >> "$RB_HITS"; done
echo "  docker-start recommendations found in the deploy lane:"
if [ -s "$RB_HITS" ]; then sed 's/^/    /' "$RB_HITS"; else echo "    (none)"; fi
check "no deploy-lane doc recommends 'docker start' for a control-plane rollback" \
  "[ ! -s '$RB_HITS' ]"
# POSITIVE CONTROL. The retired sentences, verbatim, in a fixture: if the
# scanner cannot flag these it is flagging nothing and the check above is a
# green with no subject.
RB_CTRL="$FTMP/rb-control.md"
{
  printf 'stop old slot (kept for instant `docker start` rollback)\n'
  printf 'Its container is kept stopped for instant manual rollback: flip the Caddyfile port back, reload caddy, `docker start` it.\n'
} > "$RB_CTRL"
RB_CTRL_HITS="$FTMP/rb-control-hits.txt"
rb_scan "$RB_CTRL" > "$RB_CTRL_HITS"
check "CONTROL: the scanner flags BOTH retired 'docker start' recipes (it is not blind)" \
  "[ \"\$(grep -c . '$RB_CTRL_HITS')\" = 2 ]"

# ---- R8: static — the executable path exists and the comment points at it
# rather than re-stating a hand-typeable recipe.
check "cp-deploy.sh accepts --rollback"                "grep -q -- '--rollback)           MODE=rollback' '$SCRIPT'"
check "cp-deploy.sh accepts --rollback-preflight"      "grep -q -- '--rollback-preflight) MODE=rollback-preflight' '$SCRIPT'"
check "the rollback recreates rather than starts (every occurrence, no head -1)" \
  "[ \"\$(grep -c 'up -d --force-recreate --no-build' '$SCRIPT')\" -ge 1 ] && [ \"\$(grep -c 'docker start cloud' '$SCRIPT')\" = 0 ]"
# grep -c, never grep -q: under `set -o pipefail` a -q that exits on its first
# match SIGPIPEs the awk feeding it and the pipeline returns 141, which reads as
# a FAIL on correct code. -c consumes the whole stream.
rb_body_has() { [ "$(awk '/^do_rollback\(\) \{/,/^\}/' "$SCRIPT" | grep -c "$1")" -ge 1 ]; }
check "the rollback sources cloud/.env before recreating" "rb_body_has 'APP/cloud/[.]env'"
check "the rollback force-recreates inside the function (not merely somewhere in the file)" \
  "rb_body_has '[-][-]force-recreate'"
check "the rollback takes the same deploy lock as a deploy (no concurrent deploy+rollback)" \
  "[ \"\$(grep -n 'flock -n 9' '$SCRIPT' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'rollback)           do_rollback 0' '$SCRIPT' | head -1 | cut -d: -f1)\" ]"
check "deploy/README.md points operators at the script, not a hand-typed recipe" \
  "grep -q 'cp-deploy.sh --rollback' '$HERE/README.md'"
check "deploy/README.md still keeps the INSTANCE path (systemd re-reads EnvironmentFile on start)" \
  "grep -q 'systemctl start' '$HERE/README.md'"

# ===========================================================================
# THE COUNT-READBACK PREDICATE (deploy/README.md's "every count is read back")
# ===========================================================================
# deploy/README.md asserts a property OF ITSELF: that every `<engine> … <N>
# checks` count on the page is read back by the engine it describes. That
# sentence used to name a number ("the three check counts") while the page
# carried FIVE, and one of the five — cp-cutover-gaps.sh's — was read back by
# nothing at all; the only thing near it was a `>= 38` floor in THIS file, which
# is a non-vacuity floor, not a measurement of the published number.
#
# An enumeration is a snapshot; this is the predicate. It does not list the
# engines — it DERIVES them from the page, so engine number six is judged the
# day its count is published, without anyone remembering to extend a list.
#
# The window is `[^0-9]{1,24}` rather than a line-based context: the page's
# pipeline table is one ~900-character line per target, so a line window lies
# here. Measured in characters.
README_MD="$HERE/README.md"
if [ ! -r "$README_MD" ]; then
  check "deploy/README.md is readable (the count-readback predicate needs the page)" "false"
else
  _anchor_re='deploy/[A-Za-z0-9_.-]+\.sh[^0-9]{1,24}[0-9]+ checks'
  _anchors="$(grep -oE "$_anchor_re" "$README_MD" || true)"
  # shellcheck disable=SC2034  # read inside check()'s eval string
  _anchor_n="$(printf '%s' "$_anchors" | grep -c . || true)"
  # Non-vacuity: a page whose anchors stopped matching would make every
  # assertion below pass by having nothing to judge.
  check "deploy/README.md publishes at least 5 '<engine> ... <N> checks' anchors (found $_anchor_n; a zero here is a broken extractor, not a clean page)" \
    "[ \"\$_anchor_n\" -ge 5 ]"
  while IFS= read -r _a; do
    [ -n "$_a" ] || continue
    _eng="${_a%%.sh*}.sh"                 # deploy/<name>.sh
    _engfile="$HERE/${_eng#deploy/}"
    _base="$(basename "$_eng" .sh)"
    check "the engine behind '$_a' exists ($_eng)" "[ -r '$_engfile' ]"
    if [ -r "$_engfile" ]; then
      # A readback guard is self-anchored: it greps the README for its OWN
      # script path. Both halves are required — a file that merely mentions
      # README.md is not reading its own published number back.
      check "$_eng reads deploy/README.md back" \
        "grep -qi 'README' '$_engfile'"
      check "$_eng anchors that readback on its OWN published count (the regex-escaped '${_base}\\.sh')" \
        "grep -qF '${_base}\\.sh' '$_engfile'"
    fi
  done <<EOF
$_anchors
EOF
fi

# ===========================================================================
# THE ENDPOINT SWEEP'S COUNT IDENTITY (task-fb55d468c7dea75b)
#
# `clear_wedged_endpoints` reads the daemon's endpoint list on fd 0
# (`done <<EOF`), and its body already starts three subprocesses. The next one
# added that reads stdin — an `ssh`, a `read`, a `docker` subcommand that
# prompts — swallows the rest of the list and the loop ends early with no error
# and no non-zero status. `$cleared` is read off that same loop, so a sweep that
# reached endpoint 1 of 3 leaves the others WEDGED and the caller then logs
# "none of cloud_default's endpoints is stale" — a false statement about the
# network, and the exact misdiagnosis that kept the 2026-07-21 blackout running
# for 48h47m.
#
# WEDGE_ORDER=tail puts the only clearable endpoint LAST, so a short sweep
# clears nothing. All three cases drive the REAL fakes through $RUN_SCRIPT.
echo
echo "cp-deploy endpoint sweep count identity (task-fb55d468c7dea75b)"

mut_splice() { # <src> <dst> <marker-name>
  awk -v m="# MUT-SPLICE: $3" '{ print } index($0, m) { print "cat >/dev/null" }' "$1" > "$2"
  grep -q '^cat >/dev/null$' "$2"
}
mut_cut() { # <src> <dst> <block-name>
  awk -v a="# MUT-ANCHOR: $3" -v b="# MUT-END: $3" '
    index($0, a) { skip = 1; cut = 1 }
    !skip { print }
    index($0, b) { skip = 0 }
    END { if (!cut) exit 3 }' "$1" > "$2"
}

# ---- Case A (CONTROL): the endpoint last in the list is still cleared.
setup_flip localhost:4100
rc="$(run_flip WEDGE=1 WEDGE_ORDER=tail)"
check "sweep control: the LAST endpoint in the list is still cleared, exit 0" "[ '$rc' = '0' ]"
check "sweep control: exactly one disconnect ran" "[ \"\$(n_disconnect)\" = '1' ]"
check "sweep control: the identity stayed silent" \
  "! grep -q 'SHORT ENDPOINT SWEEP' '$FTMP/out.log'"

# ---- Case B (SHORT READ): a stdin-draining child in the loop body.
# NOT under $FTMP: setup_flip makes a FRESH $FTMP on every call, so a mutant
# written there is gone by the time the next case runs it (rc=127, which reads
# like a deploy failure and is really a missing file).
MUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/cp-deploy-mut.XXXXXX")"
CP_SHORT="$MUTDIR/cp-deploy-endpoint-short.sh"
if mut_splice "$SCRIPT" "$CP_SHORT" endpoint-count-identity; then
  setup_flip localhost:4100
  rc="$(RUN_SCRIPT="$CP_SHORT" run_flip WEDGE=1 WEDGE_ORDER=tail)"
  check "sweep short: the identity REFUSES, naming both numbers (1 of 3)" \
    "grep -q 'SHORT ENDPOINT SWEEP on cloud_default: examined 1 of 3 endpoint(s)' '$FTMP/out.log'"
  check "sweep short: it says how many were never examined" \
    "grep -q '2 endpoint(s) were never even examined' '$FTMP/out.log'"
  check "sweep short: NOTHING was disconnected — the sweep never reached the stale one" \
    "[ \"\$(n_disconnect)\" = '0' ]"
  check "sweep short: the deploy still fails honestly (exit 13), it does not mask" "[ '$rc' = '13' ]"
  check "sweep short: the live blue slot was never stopped" "[ -f '$DSTATE/running.4100' ]"
else
  check "sweep short: the MUT-SPLICE marker for the endpoint loop exists in cp-deploy.sh" "false"
fi

# ---- Case C (CUT): the same short read, with the identity removed.
# The defect verbatim: the sweep examined one endpoint of three, cleared none,
# and the deploy's own diagnosis is that NONE of the network's endpoints is
# stale — while a stale one sits two rows further down the list it stopped
# reading. Nothing in the log distinguishes this from a network that is genuinely
# clean, which is what made the blackout take 48 hours.
CP_CUT="$MUTDIR/cp-deploy-endpoint-cut.sh"
if mut_cut "$CP_SHORT" "$CP_CUT" endpoint-count-identity; then
  setup_flip localhost:4100
  rc="$(RUN_SCRIPT="$CP_CUT" run_flip WEDGE=1 WEDGE_ORDER=tail)"
  check "sweep cut: no refusal is printed at all" \
    "! grep -q 'SHORT ENDPOINT SWEEP' '$FTMP/out.log'"
  check "sweep cut: the deploy reports the network as having NOTHING stale (the false diagnosis)" \
    "grep -q 'none of cloud_default.*endpoints is stale' '$FTMP/out.log'"
  check "sweep cut: still nothing disconnected, still exit 13 — but now undiagnosable" \
    "[ \"\$(n_disconnect)\" = '0' ] && [ '$rc' = '13' ]"
else
  check "sweep cut: the MUT-ANCHOR block for the endpoint identity exists in cp-deploy.sh" "false"
fi
rm -rf "$MUTDIR"

cleanup_flip

echo
# NON-VACUITY FLOOR. Asserted BEFORE the verdict: `fails -eq 0` is satisfied
# just as well by a run that executed nothing at all. The floor is a lower
# bound, never an exact total — checks are added over time and an exact count
# would red on every addition, which trains people to bump the number instead
# of reading it.
MIN_CHECKS=206
echo "checks executed: $checks_ran (floor $MIN_CHECKS)"
if [ "$checks_ran" -lt "$MIN_CHECKS" ]; then
  echo "  FAIL: only $checks_ran checks ran (floor $MIN_CHECKS) — this harness went VACUOUS; a green here would be meaningless"
  fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAIL"; fi
exit "$fails"
