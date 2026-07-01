#!/usr/bin/env bash
# Refresh a Barkpark CONTENT instance (e.g. guerrilla) to origin/main.
#
# Run on the box as root (the CD workflow scps this script + executes it).
# Idempotent, ASDF-aware, SERIALIZED (flock), build-ASIDE + atomic swap,
# auto-rollback on an unhealthy boot.
#
# Why build-aside (2026-07-01 guerrilla outage): the service is
# `exec mix phx.server` straight out of api/_build/prod with LAZY module
# loading. `rm -rf _build/prod` under the live BEAM makes the next lazy load
# (error pages, DBConnection.ConnectionError, Bandit loggers) raise
# UndefinedFunctionError — the app dies mid-request and systemd restarts it
# into the half-built tree, crash-looping for the whole 3-10 min build.
# So: build the NEW tree into api/_build_next (MIX_BUILD_ROOT) while the old
# service keeps serving from api/_build, then stop -> swap dirs -> start.
# Downtime is the swap+boot seconds. The golden rules still hold: the aside
# build is a from-scratch clean build (fresh HEEx, deps.compile --force), and
# the service is always restarted after the swap.
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
PORT="${BARKPARK_PORT:-4000}"
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-instance-deploy.lock}"
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
log "git pull"
git pull --ff-only origin main || { log "pull failed"; exit 11; }
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

# ---- Build ASIDE while the OLD service keeps serving from _build.
# A build failure = zero downtime (the live tree was never touched).
cd "$APP/api" || { log "no $APP/api"; exit 10; }
log "clean aside build into _build_next (deps.get; deps.compile --force; compile)"
rm -rf _build_next
if ! MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix deps.get;             then log "deps.get failed";     git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix deps.compile --force; then log "deps.compile failed"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix compile;              then log "compile failed";      git -C "$APP" reset --hard "$OLD"; exit 12; fi
if [ ! -d _build_next/prod ]; then log "aside build produced no _build_next/prod — aborting before touching the live tree"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
log "migrate (new code, old service still serving)"
if ! MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix ecto.migrate;         then log "migrate failed";      exit 13; fi

# ---- Atomic swap: the ONLY window the service is down (seconds, not the
# whole build). Keep the old compiled tree as _build_prev for instant rollback.
cd "$APP" || { log "no $APP"; exit 10; }
log "swap: stop -> _build_next into place -> start"
systemctl stop barkpark
rm -rf api/_build_prev
[ -d api/_build ] && mv api/_build api/_build_prev
mv api/_build_next api/_build
systemctl start barkpark

# Health gate (boot serves a prebuilt tree now, but stay generous).
for _ in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${PORT}/api/schemas" || true)"
  if [ "$code" = "200" ]; then
    log "HEALTHY ($code) at $(git rev-parse --short HEAD)"
    echo "$NEW" > "$STATE"
    rm -rf api/_build_prev
    exit 0
  fi
  sleep 15
done

# ---- Rollback: same safe sequence — never rebuild under a running BEAM.
log "UNHEALTHY after restart — ROLLING BACK to $OLD"
systemctl stop barkpark
git reset --hard "$OLD"
if [ -d api/_build_prev ]; then
  rm -rf api/_build
  mv api/_build_prev api/_build   # old compiled tree restored instantly
else
  # First-ever deploy on this box: no previous build — rebuild while stopped.
  ( cd api && rm -rf _build && MIX_ENV=prod mix deps.compile --force >/dev/null 2>&1 && MIX_ENV=prod mix compile >/dev/null 2>&1 )
fi
systemctl start barkpark
log "rollback restarted; check: curl http://localhost:${PORT}/api/schemas"
exit 14
