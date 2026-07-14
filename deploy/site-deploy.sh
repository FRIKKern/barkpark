#!/usr/bin/env bash
# Deploy a content-bound STATIC site (Astro adapter × static symlink-swap target)
# next to Phoenix on a Barkpark content box (e.g. guerrilla). Site-Spawner W1.
#
# This is a NEW state machine — deliberately NOT a parameterization of
# instance-deploy.sh (which is Phoenix-specific: mix/ecto, fixed port-pair slots,
# /api/schemas gate, git-reset rollback). It MIRRORS instance-deploy.sh's proven
# skeleton — flock serialize, typed exit codes, backup+validate+reload-or-revert
# for any Caddy mutation, fail-closed reset on any failure — over an immutable
# releases/<build_id>/ layout that a static build (no process to boot) can flip
# with an atomic symlink rename.  [charter D4/D5/D7/D8/D11]
#
# STATE MACHINE (deploy mode):
#   PLAN   build_id is passed in by the caller; if it is already the live
#          release, exit 0 no-op (the sites(site_id,build_id) unique index makes
#          this idempotent upstream — this is the on-box mirror).
#   BUILD  npm ci && npm run build in the site source dir, wrapped in
#          `systemd-run --scope -p MemoryMax=1500M -p CPUQuota=150%` and a
#          SCRUBBED env — only the injected BARKPARK_* build vars, NOTHING
#          inherited.  Vite gives process.env precedence over .env, so an ambient
#          BARKPARK_TOKEN/URL silently shadows the per-site token (live-proven
#          failure mode) — hence the scrub.
#   STAGE  copy ONLY dist/ (12-16K) into releases/<build_id>/; node_modules
#          (~148M) stays in the ephemeral build sandbox.
#   HEALTH throwaway static file server on a loopback ephemeral port rooted at
#          releases/<build_id>/: assert HTTP 200 AND grep the bp-build-id /
#          bp-content-rev <meta> markers baked into index.html (content-truth,
#          not vacuous reachability).  A marker-missing or non-200 build does NOT
#          switch.
#   SWITCH atomic `current` symlink swap (rename(2)) — no Caddy reload in the flip.
#   RETIRE keep the newest N=5 release dirs, remove older (never current/previous).
# It also arms ONCE, idempotently, a marker-guarded Caddy `handle_path
# /sites/<slug>/*` block into the live FQDN block (mirrors arm_caddy_mcp_route):
# backup + caddy validate + reload-or-revert, never re-flipped per deploy.
#
# ROLLBACK (D5 — instant, symlink repoint, NO rebuild):
#   --rollback-preflight  read-only: is a rollback possible right now?  Typed
#                         exits (21 no_previous, 22 not_supported, 23 lock held);
#                         exit 0 prints TARGET_BUILD= (machine-parsed by the CLI).
#   --rollback            repoint `current` to the previous release dir in
#                         sub-second; a second --rollback flips forward again.
#
# --self-test  builds fixture release dirs in a tmpdir and PROVES the symlink
#              flip + retire-N + rollback logic WITHOUT npm/caddy/systemd, so the
#              gate (`bash deploy/site-deploy.sh --self-test`) runs anywhere.
#
# TYPED EXIT CODES:
#    0 success / no-op        11 missing required input
#    2 usage                  12 BUILD failed
#   10 missing site dir       13 STAGE failed (no dist/)
#   14 HEALTH failed          15 gave up waiting for lock
#   16 SWITCH failed          21 rollback: no_previous
#   22 rollback: not_supported  23 rollback: lock held (deploy running)
#   24 rollback failed
#
# Env inputs (a caller — bp cloud site deploy — injects these):
#   SITE_SLUG          required. Names releases root + the /sites/<slug>/ route.
#   BUILD_ID           required (deploy). hash(code_rev+content_rev+config).
#   SITE_SRC           source dir to build (npm ci/run build → dist/).
#                      Default: <site-root>/src
#   BARKPARK_SITES_DIR base dir for site roots. Default /opt/barkpark/sites
#   BARKPARK_API_URL / BARKPARK_TOKEN / BARKPARK_DATASET /
#   BARKPARK_WORKSPACE / BARKPARK_PROJECT   the ONLY vars passed into BUILD.
#   CONTENT_REV        dataset revision read at build (baked as bp-content-rev).
#   BARKPARK_CADDYFILE Caddyfile to arm. Default /etc/caddy/Caddyfile
#   BARKPARK_HEALTH_HOST  live FQDN (for logging). Default guerrilla.barkpark.cloud
set -uo pipefail

# ---- Config ----------------------------------------------------------------
SITES_DIR="${BARKPARK_SITES_DIR:-/opt/barkpark/sites}"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
HEALTH_HOST="${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}"
RETAIN="${BARKPARK_SITE_RETAIN:-5}"
# The ONLY env vars BUILD may see (Vite process.env-precedence scrub, D7).
BUILD_ALLOW=(BARKPARK_API_URL BARKPARK_TOKEN BARKPARK_DATASET BARKPARK_WORKSPACE \
             BARKPARK_PROJECT BARKPARK_BUILD_ID BARKPARK_CONTENT_REV BARKPARK_SITE_BASE)

log() { echo "[site-deploy $(date -u +%H:%M:%S)] $*"; }

# ---- Mode dispatch ---------------------------------------------------------
MODE=deploy
case "${1:-}" in
  --rollback)           MODE=rollback ;;
  --rollback-preflight) MODE=preflight ;;
  --self-test)          MODE=selftest ;;
  "")                   MODE=deploy ;;
  *) log "unknown flag '${1}' (supported: --rollback, --rollback-preflight, --self-test)"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Portable ATOMIC symlink swap.  BSD mv (macOS) and GNU mv WITHOUT -T both
# FOLLOW a symlink-to-directory destination and move the temp link INSIDE it
# instead of replacing it (proven on darwin).  perl's rename() calls rename(2)
# directly — it renames the link itself over the destination link atomically and
# is present on every macOS/Linux box.  GNU `mv -T` is the fallback; a last-ditch
# rm+mv (BSD, sub-ms non-atomic gap) keeps the flip working on a perl-less box.
# ---------------------------------------------------------------------------
atomic_symlink_swap() { # <tmp-link> <dest-link>
  if command -v perl >/dev/null 2>&1; then
    perl -e 'rename($ARGV[0],$ARGV[1]) or die "rename: $!"' "$1" "$2"
  elif mv --version >/dev/null 2>&1; then
    mv -Tf "$1" "$2"
  else
    rm -f "$2" && mv "$1" "$2"
  fi
}

# ---------------------------------------------------------------------------
# The four pure state-machine primitives operate on globals ROOT / RELEASES /
# CURRENT / BUILD_ID so --self-test can exercise the SAME code the deploy path
# runs (no fixture fork — the test proves the real primitives).
# ---------------------------------------------------------------------------

# SWITCH: atomic current -> releases/<BUILD_ID>.  Records the build we flip away
# from in .previous so --rollback (and a forward re-rollback) is a pure pointer.
do_switch() {
  local prev=""
  [ -L "$CURRENT" ] && prev="$(basename "$(readlink "$CURRENT")")"
  ln -sfn "releases/$BUILD_ID" "$CURRENT.tmp" || return 1
  atomic_symlink_swap "$CURRENT.tmp" "$CURRENT" || { rm -f "$CURRENT.tmp"; return 1; }
  if [ -n "$prev" ] && [ "$prev" != "$BUILD_ID" ]; then echo "$prev" > "$ROOT/.previous"; fi
  return 0
}

# RETIRE: keep the newest RETAIN release dirs (mtime), remove older — but NEVER
# the live target or the .previous rollback target.
do_retire() {
  [ -d "$RELEASES" ] || return 0
  local livecur="" prev="" d id i=0
  [ -L "$CURRENT" ] && livecur="$(basename "$(readlink "$CURRENT")")"
  [ -f "$ROOT/.previous" ] && prev="$(cat "$ROOT/.previous")"
  # ls -1dt: newest-first by mtime.  Trailing slash restricts to directories.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    id="$(basename "$d")"
    i=$((i + 1))
    [ "$i" -le "$RETAIN" ] && continue
    [ "$id" = "$livecur" ] && continue
    [ "$id" = "$prev" ] && continue
    rm -rf "$d" && log "RETIRE: removed old release $id"
  done < <(ls -1dt "$RELEASES"/*/ 2>/dev/null)
}

# ROLLBACK: repoint current to the .previous release (sub-second, no rebuild).
# Typed returns: 21 no_previous, 22 not_supported, 24 flip failed.
do_rollback() {
  [ -L "$CURRENT" ] || { log "rollback: no live 'current' symlink (not_supported)"; return 22; }
  [ -f "$ROOT/.previous" ] || { log "rollback: no .previous release recorded (no_previous)"; return 21; }
  local prev livenow
  prev="$(cat "$ROOT/.previous")"
  [ -n "$prev" ] || { log "rollback: empty .previous (no_previous)"; return 21; }
  [ -d "$RELEASES/$prev" ] || { log "rollback: previous release '$prev' dir is gone (no_previous)"; return 21; }
  livenow="$(basename "$(readlink "$CURRENT")")"
  if [ "$prev" = "$livenow" ]; then log "rollback: previous == current ($prev) — nothing to do"; return 0; fi
  ln -sfn "releases/$prev" "$CURRENT.tmp" || return 24
  atomic_symlink_swap "$CURRENT.tmp" "$CURRENT" || { rm -f "$CURRENT.tmp"; return 24; }
  # A subsequent --rollback flips FORWARD again — record where we came from.
  echo "$livenow" > "$ROOT/.previous"
  log "ROLLED BACK: current -> releases/$prev (was $livenow)"
  return 0
}

# Basename of the live release, or "" if none.
live_build() { [ -L "$CURRENT" ] && basename "$(readlink "$CURRENT")" || true; }

# ---------------------------------------------------------------------------
# SELF-TEST — fixtures in a tmpdir; proves the real primitives, no npm/caddy.
# ---------------------------------------------------------------------------
if [ "$MODE" = selftest ]; then
  TESTS=0; FAILS=0
  check() { # <label> <cond-cmd...>
    local label="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@"; then echo "  ok   - $label"; else echo "  FAIL - $label"; FAILS=$((FAILS + 1)); fi
  }
  TD="$(mktemp -d "${TMPDIR:-/tmp}/site-deploy-selftest.XXXXXX")"
  trap 'rm -rf "$TD"' EXIT
  ROOT="$TD/site"; RELEASES="$ROOT/releases"; CURRENT="$ROOT/current"
  mkdir -p "$RELEASES"
  # Seven fixture releases with strictly increasing mtime (b1 oldest..b7 newest).
  for n in 1 2 3 4 5 6 7; do
    mkdir -p "$RELEASES/b$n"
    printf '<meta name="bp-build-id" content="b%s">' "$n" > "$RELEASES/b$n/index.html"
    touch -t "20260713$(printf '%02d' "$n")00" "$RELEASES/b$n"
  done

  echo "[selftest] SWITCH flips the current symlink atomically"
  BUILD_ID=b1; do_switch
  check "current -> releases/b1"        [ "$(live_build)" = b1 ]
  check "current resolves to a dir"     [ -d "$CURRENT" ]
  check "current/index.html readable"   [ -f "$CURRENT/index.html" ]
  BUILD_ID=b2; do_switch
  check "current -> releases/b2"        [ "$(live_build)" = b2 ]
  check ".previous records b1"          [ "$(cat "$ROOT/.previous")" = b1 ]
  check "no current.tmp residue"        [ ! -e "$CURRENT.tmp" ]

  echo "[selftest] ROLLBACK repoints to the previous release, forward-rollable"
  do_rollback
  check "rollback: current -> b1"       [ "$(live_build)" = b1 ]
  check "rollback: .previous now b2"    [ "$(cat "$ROOT/.previous")" = b2 ]
  do_rollback
  check "re-rollback flips forward -> b2" [ "$(live_build)" = b2 ]

  echo "[selftest] RETIRE keeps newest N=5, protects current + previous"
  # Live=b2, previous=b1 (both OLD by mtime) — retire must still spare them.
  BUILD_ID=b7; do_switch          # current=b7, .previous=b2
  RETAIN=5; do_retire
  # Newest 5 by mtime = b3,b4,b5,b6,b7.  Plus protected current(b7,already in)
  # and previous(b2).  So b1 is the only removable one.
  check "retire removed b1"             [ ! -d "$RELEASES/b1" ]
  check "retire kept b2 (previous)"     [ -d "$RELEASES/b2" ]
  check "retire kept b3"                [ -d "$RELEASES/b3" ]
  check "retire kept b7 (current)"      [ -d "$RELEASES/b7" ]
  remaining="$(ls -1d "$RELEASES"/*/ 2>/dev/null | wc -l | tr -d ' ')"
  check "6 dirs remain (5 newest + protected previous)" [ "$remaining" = 6 ]

  echo "[selftest] no-op rollback when previous == current is safe"
  echo b7 > "$ROOT/.previous"; do_rollback
  check "current still b7 after no-op rollback" [ "$(live_build)" = b7 ]

  echo ""
  echo "[selftest] $((TESTS - FAILS))/$TESTS checks passed"
  [ "$FAILS" -eq 0 ] || { echo "[selftest] FAILED ($FAILS)"; exit 1; }
  echo "[selftest] PASS"
  exit 0
fi

# ---------------------------------------------------------------------------
# From here on: real deploy/rollback modes need SITE_SLUG + a live layout.
# ---------------------------------------------------------------------------
SITE_SLUG="${SITE_SLUG:-}"
if [ -z "$SITE_SLUG" ]; then log "SITE_SLUG is required"; exit 11; fi
# Slug hygiene: it names a filesystem dir AND a Caddy path matcher.
if ! printf '%s' "$SITE_SLUG" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$'; then
  log "invalid SITE_SLUG '$SITE_SLUG' (want ^[a-z0-9][a-z0-9-]{0,62}\$)"; exit 11
fi

ROOT="$SITES_DIR/$SITE_SLUG"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
SITE_SRC="${SITE_SRC:-$ROOT/src}"
LOCK="${BARKPARK_SITE_DEPLOY_LOCK:-/var/lock/barkpark-site-deploy-$SITE_SLUG.lock}"

# ---- Serialize per-site (queue depth 1).  A held lock means a deploy is in
# flight: another deploy queues behind it; a rollback REFUSES (racing a deploy
# would flip current mid-STAGE) with a typed 23.
if ! mkdir -p "$(dirname "$LOCK")" 2>/dev/null; then
  # Unwritable /var/lock (dev box) — fall back to a tmp lock so we still serialize.
  LOCK="${TMPDIR:-/tmp}/barkpark-site-deploy-$SITE_SLUG.lock"
fi
exec 9>"$LOCK"
if ! flock -n 9; then
  if [ "$MODE" != deploy ]; then
    log "deploy lock held for '$SITE_SLUG' — refusing to $MODE while a deploy runs (lock_held)"
    exit 23
  fi
  log "another deploy holds the lock for '$SITE_SLUG' — queueing (max 20 min)"
  flock -w 1200 9 || { log "gave up waiting for the site deploy lock"; exit 15; }
fi

mkdir -p "$RELEASES"

# ---- Rollback / preflight (D5) — pure pointer, no rebuild ------------------
if [ "$MODE" = preflight ]; then
  if [ ! -L "$CURRENT" ]; then log "no live release for '$SITE_SLUG' (not_supported)"; exit 22; fi
  if [ ! -f "$ROOT/.previous" ] || [ -z "$(cat "$ROOT/.previous" 2>/dev/null)" ]; then
    log "no previous release recorded for '$SITE_SLUG' (no_previous)"; exit 21
  fi
  prev="$(cat "$ROOT/.previous")"
  if [ ! -d "$RELEASES/$prev" ]; then log "previous release '$prev' dir is gone (no_previous)"; exit 21; fi
  log "rollback possible: would repoint current ($(live_build)) -> releases/$prev"
  echo "TARGET_BUILD=$prev"
  exit 0
fi

if [ "$MODE" = rollback ]; then
  do_rollback; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  do_retire
  log "ROLLED BACK — '$SITE_SLUG' now at $(live_build)"
  exit 0
fi

# ===========================================================================
# DEPLOY: PLAN -> BUILD -> STAGE -> HEALTH -> SWITCH -> RETIRE
# ===========================================================================
BUILD_ID="${BUILD_ID:-}"
if [ -z "$BUILD_ID" ]; then log "BUILD_ID is required for a deploy"; exit 11; fi
if ! printf '%s' "$BUILD_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
  log "invalid BUILD_ID '$BUILD_ID'"; exit 11
fi

# ---- PLAN ------------------------------------------------------------------
# Already live?  Idempotent no-op (mirrors the sites(site_id,build_id) unique
# index that makes a re-deploy of an unchanged code+content+config a no-op).
if [ "$(live_build)" = "$BUILD_ID" ]; then
  log "PLAN: build_id $BUILD_ID is already live for '$SITE_SLUG' — nothing to do"
  exit 0
fi
RELDIR="$RELEASES/$BUILD_ID"
if [ -d "$RELDIR" ] && [ -f "$RELDIR/index.html" ]; then
  # A previously-staged but not-live build (e.g. a rollback target): skip the
  # rebuild, re-health-gate + switch straight to it.
  log "PLAN: release $BUILD_ID already staged — re-gating, skipping BUILD/STAGE"
  SKIP_BUILD=1
else
  SKIP_BUILD=0
fi
log "PLAN: deploy '$SITE_SLUG' build $BUILD_ID (live now: $(live_build))"

# ---- BUILD -----------------------------------------------------------------
# Serialized (flock, above) + capped (systemd-run scope) + env-SCRUBBED.  Only
# the BUILD_ALLOW vars reach npm/Vite; ambient BARKPARK_TOKEN cannot shadow the
# per-site token (D7).  cwd is inherited into the scrubbed child, so we cd first.
if [ "$SKIP_BUILD" = 0 ]; then
  if [ ! -d "$SITE_SRC" ]; then log "BUILD: no site source dir $SITE_SRC"; exit 10; fi
  if [ ! -f "$SITE_SRC/package.json" ]; then log "BUILD: $SITE_SRC has no package.json"; exit 11; fi

  # Build the scrubbed env allow-list.  BUILD_ID + base path + content rev are
  # exported under their BARKPARK_ build-var names so the adapter can bake the
  # bp-build-id / bp-content-rev markers HEALTH asserts on.
  export BARKPARK_BUILD_ID="$BUILD_ID"
  export BARKPARK_SITE_BASE="/sites/$SITE_SLUG/"
  [ -n "${CONTENT_REV:-}" ] && export BARKPARK_CONTENT_REV="$CONTENT_REV"
  scrub=(env -i "PATH=$PATH" "HOME=${HOME:-/root}" NODE_ENV=production CI=1)
  for v in "${BUILD_ALLOW[@]}"; do
    [ -n "${!v:-}" ] && scrub+=("$v=${!v}")
  done

  log "BUILD: npm ci && npm run build in $SITE_SRC (scrubbed env, capped)"
  cd "$SITE_SRC" || { log "BUILD: cannot cd $SITE_SRC"; exit 10; }
  # systemd-run --scope caps memory+cpu and inherits cwd; env -i inside scrubs.
  # On a non-systemd box (dev) run the scrubbed env directly — capping is
  # best-effort, the scrub is not.
  if command -v systemd-run >/dev/null 2>&1 && [ "${BARKPARK_SITE_NO_CAP:-0}" != 1 ]; then
    cap=(systemd-run --scope --quiet --collect -p MemoryMax=1500M -p CPUQuota=150%)
  else
    log "BUILD: systemd-run unavailable (or capping disabled) — running uncapped, still scrubbed"
    cap=()
  fi
  if ! "${cap[@]}" "${scrub[@]}" bash -euo pipefail -c 'npm ci --no-audit --no-fund && npm run build'; then
    log "BUILD failed for '$SITE_SLUG' build $BUILD_ID — live release untouched"
    exit 12
  fi

  # ---- STAGE — copy ONLY dist/ (D8) ---------------------------------------
  if [ ! -d "$SITE_SRC/dist" ]; then log "STAGE: build produced no $SITE_SRC/dist — abort"; exit 13; fi
  if [ ! -f "$SITE_SRC/dist/index.html" ]; then log "STAGE: $SITE_SRC/dist has no index.html — abort"; exit 13; fi
  # Stage into a .partial dir then rename, so a crash mid-copy never leaves a
  # half-populated releases/<build_id>/ that a later PLAN mistakes for staged.
  rm -rf "$RELDIR" "$RELDIR.partial"
  mkdir -p "$RELDIR.partial"
  if ! cp -a "$SITE_SRC/dist/." "$RELDIR.partial/"; then
    log "STAGE: copy of dist/ failed"; rm -rf "$RELDIR.partial"; exit 13
  fi
  mv "$RELDIR.partial" "$RELDIR" || { log "STAGE: rename into place failed"; rm -rf "$RELDIR.partial"; exit 13; }
  log "STAGE: dist/ -> releases/$BUILD_ID/ ($(du -sh "$RELDIR" 2>/dev/null | cut -f1 || echo '?'))"
fi

# ---- HEALTH — content-truth, not vacuous reachability (D11) ----------------
# Throwaway static server on a loopback ephemeral port over the release dir:
# assert 200 AND grep the baked bp-build-id / bp-content-rev markers.  Fail =>
# NO switch (fail closed).
health_gate() { # sets nothing; returns 0 healthy, 1 not
  local idx="$RELDIR/index.html"
  if [ ! -f "$idx" ]; then log "HEALTH: no index.html in releases/$BUILD_ID"; return 1; fi
  if ! grep -Eiq 'name=["'"'"']?bp-build-id' "$idx"; then
    log "HEALTH: bp-build-id <meta> marker missing from index.html — refusing to switch"; return 1
  fi
  if ! grep -Eiq 'name=["'"'"']?bp-content-rev' "$idx"; then
    log "HEALTH: bp-content-rev <meta> marker missing from index.html — refusing to switch"; return 1
  fi
  # Ephemeral loopback port.
  local port
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
  [ -n "$port" ] || port=$(( (RANDOM % 20000) + 20000 ))
  local srv=0
  if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$RELDIR" >/dev/null 2>&1 &
    srv=$!
  elif command -v caddy >/dev/null 2>&1; then
    caddy file-server --listen "127.0.0.1:$port" --root "$RELDIR" >/dev/null 2>&1 &
    srv=$!
  else
    log "HEALTH: no python3 or caddy to run the throwaway server — cannot gate"; return 1
  fi
  local code=000 i
  for i in $(seq 1 25); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/index.html" 2>/dev/null || true)"
    [ "$code" = 200 ] && break
    sleep 0.2
  done
  kill "$srv" 2>/dev/null || true
  wait "$srv" 2>/dev/null || true
  if [ "$code" != 200 ]; then log "HEALTH: throwaway server returned $code (want 200) — refusing to switch"; return 1; fi
  log "HEALTH: 200 + bp-build-id/bp-content-rev markers present (build $BUILD_ID)"
  return 0
}

if ! health_gate; then
  log "HEALTH gate FAILED for build $BUILD_ID — live release untouched, no switch (fail closed)"
  # Leave the staged dir for inspection; the next healthy deploy retires it.
  exit 14
fi

# ---- Arm the Caddy path handle ONCE (D4) -----------------------------------
# Marker-guarded `handle_path /sites/<slug>/*` into the live FQDN block, mirrors
# arm_caddy_mcp_route: backup + caddy validate + reload-or-revert, NEVER re-armed
# per deploy (the swap below is just a symlink flip Caddy already follows).
# Non-fatal — the release is served the moment `current` flips; the route just
# exposes it publicly, and a Caddy hiccup must not fail a healthy build.
arm_caddy_site_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping /sites/$SITE_SLUG route"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping /sites/$SITE_SLUG route"; return 0; }
  local marker="BARKPARK_SITE_ROUTE:$SITE_SLUG"
  if grep -q "$marker" "$CADDYFILE"; then log "caddy /sites/$SITE_SLUG route already armed"; return 0; fi
  # Anchor on the FIRST slot/site reverse_proxy so the handle lands INSIDE the
  # live FQDN site block (ahead of the fallback proxy).  Matches the guerrilla
  # blue/green slot ports 4000/4001 (same anchor arm_caddy_mcp_route uses).
  if ! grep -qE 'reverse_proxy[[:space:]]+localhost:(4000|4001)([[:space:]]|$)' "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (/sites/$SITE_SLUG not armed)"
    return 0
  fi
  local block; block="$(cat <<SITEROUTE
	# $marker — static site '$SITE_SLUG' served from its immutable current release.
	# handle_path strips the /sites/$SITE_SLUG prefix; root follows the symlink.
	handle_path /sites/$SITE_SLUG/* {
		root * $ROOT/current
		file_server
	}
SITEROUTE
)"
  local bak; bak="${CADDYFILE}.bak.site.${SITE_SLUG}.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert BEFORE the first slot reverse_proxy so /sites/<slug>/* terminates in
  # the handle ahead of the app fallback.  Slot ports only.
  BP_BLOCK="$block" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"] }
    !ins && $0 ~ /reverse_proxy[[:blank:]]+localhost:(4000|4001)([[:blank:]]|$)/ { print blk; ins=1 }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed caddy /sites/$SITE_SLUG route -> $ROOT/current"; else log "caddy reload failed (config valid) — /sites/$SITE_SLUG live on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the /sites/$SITE_SLUG route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
arm_caddy_site_route

# ---- SWITCH (D11) — atomic symlink flip, no Caddy reload -------------------
if ! do_switch; then
  log "SWITCH failed for build $BUILD_ID — live release untouched (fail closed)"
  exit 16
fi
log "SWITCH: '$SITE_SLUG' current -> releases/$BUILD_ID (atomic)"

# ---- RETIRE (D8) — keep newest N=5 ----------------------------------------
do_retire

log "HEALTHY — '$SITE_SLUG' live at build $BUILD_ID (https://$HEALTH_HOST/sites/$SITE_SLUG/)"
exit 0
