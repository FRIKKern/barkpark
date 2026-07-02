#!/usr/bin/env bash
# Refresh a Barkpark CONTENT instance (e.g. guerrilla) to origin/main.
#
# Run on the box as root (the CD workflow scps this script + executes it).
# Idempotent, ASDF-aware, SERIALIZED (flock), ZERO-DOWNTIME blue/green.
#
# Blue/green (extends the 2026-07-01 build-aside fix): the app runs as systemd
# template units barkpark-slot@{blue,green} out of per-slot build roots of the
# SAME checkout (blue = api/_build_blue on :4000, green = api/_build_green on
# :4001); host Caddy proxies the public hostname to the active slot's port. A
# deploy clean-builds the IDLE slot's root (MIX_BUILD_ROOT) while the active
# slot keeps serving its own untouched root, migrates, boots the idle slot,
# health-gates it, then flips Caddy's upstream (graceful reload — no dropped
# connections) and retires the old slot. An unhealthy new slot is simply
# stopped again — the active slot is never touched, so a bad deploy costs no
# downtime. Consequence: migrations must be backward-compatible
# (expand/contract) for the minute both slots overlap.
#
# The pull suppresses the repo's post-merge hook (core.hooksPath=.githooks on
# the box): that hook nukes the live _build and restarts the legacy `barkpark`
# unit — exactly the outage this script exists to prevent.
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-instance-deploy.lock}"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
HEALTH_HOST="${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}"
BLUE_PORT="${BARKPARK_PORT_BLUE:-4000}"
GREEN_PORT="${BARKPARK_PORT_GREEN:-4001}"
log() { echo "[instance-deploy $(date -u +%H:%M:%S)] $*"; }

# ---- Serialize: overlapping runs (back-to-back merges, manual + CD) queue
# here. Each run pulls AFTER taking the lock, so a queued run deploys the
# latest HEAD; if its commits were already shipped by the run ahead of it,
# the coalesce check below turns it into a no-op.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy holds the lock — queueing (max 30 min)"
  flock -w 1800 9 || { log "gave up waiting for the deploy lock"; exit 15; }
fi

export PATH="$HOME/.asdf/shims:/usr/local/go/bin:$PATH"
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

cd "$APP" || { log "no $APP"; exit 10; }
STATE="$APP/.instance-deploy-last"   # commit of the last HEALTHY deploy
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

# Built artifacts (committed bin/, go.sum churn) block --ff-only; discard them.
git checkout -- . 2>/dev/null || true
log "git pull (post-merge hook suppressed — this script IS the deploy)"
git -c core.hooksPath=/dev/null pull --ff-only origin main || { log "pull failed"; exit 11; }
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Coalesce: the run ahead of us already deployed this exact commit healthily.
if [ "$NEW" = "$OLD" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$NEW" ]; then
  log "HEAD $NEW already deployed healthy — nothing to do"
  exit 0
fi

# Backfill the prod-required secret keys if absent (each RAISES at boot).
for v in BARKPARK_KEK BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET; do
  if ! grep -q "^${v}=" .env 2>/dev/null; then
    echo "${v}=$(openssl rand -base64 32)" >> .env
    log "added missing ${v} to .env"
  fi
done
set -a; . ./.env; set +a

# ---- Which slot serves now? Caddy's upstream port is the source of truth
# (on the pre-blue/green layout it reads 4000, which maps to legacy-as-blue).
ACTIVE_PORT="$(grep -oE 'localhost:40[0-9]{2}' "$CADDYFILE" | head -1 | cut -d: -f2)"
ACTIVE_PORT="${ACTIVE_PORT:-$BLUE_PORT}"
if [ "$ACTIVE_PORT" = "$BLUE_PORT" ]; then
  TARGET=green; TARGET_PORT="$GREEN_PORT"; OTHER=blue
else
  TARGET=blue; TARGET_PORT="$BLUE_PORT"; OTHER=green
fi
log "active upstream :$ACTIVE_PORT -> deploying slot '$TARGET' on :$TARGET_PORT"

# ---- Install/refresh the slot units + per-slot env (idempotent).
install -m 0644 "$APP/deploy/systemd/barkpark-slot@.service" /etc/systemd/system/barkpark-slot@.service
mkdir -p "$APP/.slots"
printf 'BARKPARK_PORT_OVERRIDE=%s\nMIX_BUILD_ROOT=%s\n' "$BLUE_PORT" "$APP/api/_build_blue" > "$APP/.slots/blue.env"
printf 'BARKPARK_PORT_OVERRIDE=%s\nMIX_BUILD_ROOT=%s\n' "$GREEN_PORT" "$APP/api/_build_green" > "$APP/.slots/green.env"
systemctl daemon-reload

# ---- Clean-build the idle slot's root while the active slot keeps serving
# its own untouched root. A build failure = zero downtime. The golden rules
# still hold: from-scratch build (fresh HEEx), deps.compile --force.
cd "$APP/api" || { log "no $APP/api"; exit 10; }
build() { MIX_ENV=prod MIX_BUILD_ROOT="_build_$TARGET" mix "$@"; }
log "clean build into _build_$TARGET (deps.get; deps.compile --force; compile)"
rm -rf "_build_$TARGET"
if ! build deps.get;             then log "deps.get failed";     git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! build deps.compile --force; then log "deps.compile failed"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! build compile;              then log "compile failed";      git -C "$APP" reset --hard "$OLD"; exit 12; fi
if [ ! -d "_build_$TARGET/prod" ]; then log "build produced no _build_$TARGET/prod — abort, live slot untouched"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
log "migrate (new code, active slot still serving)"
if ! build ecto.migrate;         then log "migrate failed";      exit 13; fi

# ---- Boot the idle slot and gate on it. The active slot is never touched;
# every failure path from here on is zero-downtime.
cd "$APP" || { log "no $APP"; exit 10; }
log "boot barkpark-slot@$TARGET on :$TARGET_PORT"
systemctl restart "barkpark-slot@$TARGET"

ok=0
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${TARGET_PORT}/api/schemas" || true)"
  if [ "$code" = "200" ]; then ok=1; log "slot $TARGET healthy ($code)"; break; fi
  sleep 5
done
if [ "$ok" != "1" ]; then
  log "slot $TARGET UNHEALTHY — stopping it; :$ACTIVE_PORT was never touched (no downtime)"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  git reset --hard "$OLD"   # keep sources in step with the still-serving old build
  exit 14
fi

# ---- Hot swap: point Caddy at the new slot (graceful reload, no drops).
cp -a "$CADDYFILE" "$CADDYFILE.pre-deploy"
sed -i "s/localhost:${ACTIVE_PORT}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  log "Caddyfile invalid after port flip — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  git reset --hard "$OLD"; exit 14
fi
if ! systemctl reload caddy; then
  log "caddy reload failed — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; systemctl reload caddy || true
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  git reset --hard "$OLD"; exit 14
fi
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${HEALTH_HOST}:443:127.0.0.1" "https://${HEALTH_HOST}/api/schemas" || true)"
log "Caddy now -> :$TARGET_PORT (https://${HEALTH_HOST}/api/schemas = $code)"

# ---- Drain, then retire the old slot AND the pre-blue/green legacy unit.
# Exactly one slot stays enabled (survives reboot). Instant manual rollback:
# flip the Caddyfile port back, reload caddy, start the old slot again.
sleep 5
systemctl enable "barkpark-slot@$TARGET" >/dev/null 2>&1 || true
systemctl disable --now "barkpark-slot@$OTHER" >/dev/null 2>&1 || true
systemctl disable --now barkpark >/dev/null 2>&1 || true

echo "$NEW" > "$STATE"
log "HEALTHY — slot $TARGET live at $(git rev-parse --short HEAD)"
exit 0
