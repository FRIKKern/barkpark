#!/usr/bin/env bash
# Refresh the Barkpark Cloud CONTROL PLANE (barkpark.cloud / barkpark-cp) to
# origin/main. Run on the box as root (the CD workflow scps this + the
# cross-built provisioner binary, then executes it).
#
#   bash cp-deploy.sh [path-to-prebuilt-linux-amd64-provisioner]
#
# ZERO-DOWNTIME blue/green: the control plane is two compose slots behind
# profiles (blue=:4100, green=:4101); exactly one serves at a time and host
# Caddy proxies barkpark.cloud to its port. A deploy builds the image while
# the active slot keeps serving, boots the IDLE slot (auto-migrates on boot),
# health-gates it, then flips Caddy's upstream (graceful reload — no dropped
# connections) and stops the old slot. An unhealthy new slot is simply stopped
# again — the active slot is never touched, so a bad deploy costs no downtime.
# Consequence: migrations must be backward-compatible (expand/contract) for
# the seconds both slots overlap. Go is NOT installed on barkpark-cp, so the
# provisioner is cross-built by the runner and passed in.
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
COMPOSE_FILE="$APP/cloud/docker-compose.yml"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-cp-deploy.lock}"
PROV_BIN="${1:-}"
log() { echo "[cp-deploy $(date -u +%H:%M:%S)] $*"; }
compose() { docker compose -f "$COMPOSE_FILE" --profile blue --profile green "$@"; }

# Serialize overlapping runs (back-to-back merges, manual + CD).
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy holds the lock — queueing (max 30 min)"
  flock -w 1800 9 || { log "gave up waiting for the deploy lock"; exit 15; }
fi

cd "$APP" || { log "no $APP"; exit 10; }
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

docker tag cloud-control_plane:latest cloud-control_plane:rollback 2>/dev/null \
  && log "tagged rollback image" || log "no current image to tag (first deploy?)"

git checkout -- . 2>/dev/null || true
log "git pull"
git -c core.hooksPath=/dev/null pull --ff-only origin main || { log "pull failed"; exit 11; }
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Secrets are passthrough — export cloud/.env so compose resolves them.
if [ ! -f cloud/.env ]; then log "MISSING cloud/.env — abort (containers untouched)"; git reset --hard "$OLD"; exit 12; fi
set -a; . cloud/.env; set +a

# ---- Which slot serves now? Caddy's upstream port is the source of truth.
ACTIVE_PORT="$(grep -oE 'localhost:41[0-9]{2}' "$CADDYFILE" | head -1 | cut -d: -f2)"
ACTIVE_PORT="${ACTIVE_PORT:-4100}"
if [ "$ACTIVE_PORT" = "4100" ]; then
  TARGET=green; TARGET_PORT="${PORT_GREEN:-4101}"
else
  TARGET=blue; TARGET_PORT="${PORT_BLUE:-4100}"
fi
log "active upstream :$ACTIVE_PORT -> deploying slot '$TARGET' on :$TARGET_PORT"

# Rolls back git + image tag and stops the target slot; the active slot keeps
# serving throughout, so every abort path here is zero-downtime.
abort_deploy() {
  compose rm -sf "control_plane_$TARGET" >/dev/null 2>&1 || true
  docker tag cloud-control_plane:rollback cloud-control_plane:latest 2>/dev/null || true
  git reset --hard "$OLD"
}

log "docker compose build (active slot still serving)"
if ! compose build; then
  log "BUILD FAILED — reset + abort (no downtime)"; git reset --hard "$OLD"; exit 13
fi

# Free the target port if a stale/failed slot (or the pre-blue/green legacy
# `control_plane` service) still holds it, then boot the new slot.
for c in $(docker ps -q --filter "publish=$TARGET_PORT"); do
  log "stopping stale container on :$TARGET_PORT ($c)"; docker stop -t 30 "$c"
done
compose up -d db postfix
log "boot slot $TARGET (auto-migrates on boot; active slot untouched)"
if ! compose up -d --no-build "control_plane_$TARGET"; then
  log "SLOT BOOT FAILED — abort (active slot untouched)"; abort_deploy; exit 13
fi

ok=0
for _ in $(seq 1 36); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://localhost:${TARGET_PORT}/" || true)"
  if echo "$code" | grep -qE '^(200|301|302|404)$'; then ok=1; log "slot $TARGET healthy ($code)"; break; fi
  sleep 5
done
if [ "$ok" != "1" ]; then
  log "slot $TARGET UNHEALTHY — stopping it; :$ACTIVE_PORT was never touched (no downtime)"
  abort_deploy; exit 14
fi

# ---- Hot swap: point Caddy at the new slot (graceful reload, no drops).
cp -a "$CADDYFILE" "$CADDYFILE.pre-deploy"
sed -i "s/localhost:${ACTIVE_PORT}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  log "Caddyfile invalid after port flip — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; abort_deploy; exit 14
fi
if ! systemctl reload caddy; then
  log "caddy reload failed — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; systemctl reload caddy || true
  abort_deploy; exit 14
fi
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "barkpark.cloud:443:127.0.0.1" "https://barkpark.cloud/" || true)"
log "Caddy now -> :$TARGET_PORT (https://barkpark.cloud/ = $code)"

# ---- Drain, then retire the old slot. Its container is kept stopped for
# instant manual rollback: flip the Caddyfile port back, reload caddy,
# `docker start` it.
sleep 5
for c in $(docker ps -q --filter "publish=$ACTIVE_PORT"); do
  log "stopping old slot container on :$ACTIVE_PORT ($c)"; docker stop -t 30 "$c"
done

# ---- Pin the provisioner's control-url to the STABLE FRONT (dwb-16).
# ROOT CAUSE of the "/new froze at Starting" incident: the worker unit hardcoded
# `--control-url http://localhost:4100`, but this blue/green deploy FLIPS the
# active port (4100<->4101). After a flip the worker kept POSTing to the now-dead
# old port and was silently locked out — jobs sat pending, unclaimed, forever.
# The fix: pin the worker at the stable public front (Caddy always proxies it to
# whichever slot is live), so a port flip can never lock the worker out again.
# Idempotent: re-running rewrites the same value. Only touches the control-url.
PROV_UNIT="${BARKPARK_PROVISIONER_UNIT:-/etc/systemd/system/barkpark-provisioner.service}"
PROV_CONTROL_URL="${PROVISIONER_CONTROL_URL:-https://barkpark.cloud}"
if [ -f "$PROV_UNIT" ]; then
  if grep -qE -- '--control-url[= ]' "$PROV_UNIT"; then
    # Replace the flag's value (space- OR =-separated) with the stable front.
    sed -i -E "s#--control-url[= ][^[:space:]\"']+#--control-url ${PROV_CONTROL_URL}#g" "$PROV_UNIT"
    systemctl daemon-reload
    log "provisioner control-url pinned to $PROV_CONTROL_URL (blue/green-safe)"
  else
    log "provisioner unit has no --control-url flag; leaving control-url as-is"
  fi
else
  log "no provisioner unit at $PROV_UNIT; skipping control-url pin"
fi

# Provisioner worker (cross-built by the runner; Go absent on this host).
if [ -n "$PROV_BIN" ] && [ -f "$PROV_BIN" ]; then
  log "install provisioner"
  cp /usr/local/bin/barkpark-provisioner "/usr/local/bin/barkpark-provisioner.bak" 2>/dev/null || true
  install -m 0755 "$PROV_BIN" /usr/local/bin/barkpark-provisioner
  systemctl restart barkpark-provisioner
  sleep 3
  log "provisioner: $(systemctl is-active barkpark-provisioner)"
else
  log "no provisioner binary passed; leaving worker as-is"
fi

log "DONE — control plane slot $TARGET live at $(git rev-parse --short HEAD)"
