#!/usr/bin/env bash
# Refresh a Barkpark CONTENT instance (e.g. guerrilla) to origin/main.
#
# Run on the box as root (the CD workflow scps this script + executes it).
# Idempotent, ASDF-aware, build-before-restart, auto-rollback on an unhealthy boot.
# Honors the prod golden rules: clean _build/prod, force deps.compile, migrate,
# restart — never serve a half-built tree, never leave stale HEEx behind.
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
PORT="${BARKPARK_PORT:-4000}"
log() { echo "[instance-deploy $(date -u +%H:%M:%S)] $*"; }

export PATH="$HOME/.asdf/shims:/usr/local/go/bin:$PATH"
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

cd "$APP" || { log "no $APP"; exit 10; }
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

# Built artifacts (committed bin/, go.sum churn) block --ff-only; discard them.
git checkout -- . 2>/dev/null || true
log "git pull"
git pull --ff-only origin main || { log "pull failed"; exit 11; }
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Backfill the prod-required secret keys if absent (each RAISES at boot).
for v in BARKPARK_KEK BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET; do
  if ! grep -q "^${v}=" .env 2>/dev/null; then
    echo "${v}=$(openssl rand -base64 32)" >> .env
    log "added missing ${v} to .env"
  fi
done
set -a; . ./.env; set +a

# Build while the OLD service keeps serving — a build failure = zero downtime.
cd "$APP/api"
log "clean build (rm _build/prod; deps.compile --force; compile)"
rm -rf _build/prod
if ! MIX_ENV=prod mix deps.get;             then log "deps.get failed";     git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! MIX_ENV=prod mix deps.compile --force; then log "deps.compile failed"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! MIX_ENV=prod mix compile;              then log "compile failed";      git -C "$APP" reset --hard "$OLD"; exit 12; fi
log "migrate"
if ! MIX_ENV=prod mix ecto.migrate;         then log "migrate failed";      exit 13; fi

cd "$APP"
log "restart barkpark"
systemctl restart barkpark

# Health gate (start.sh may recompile on boot — allow generous time).
for i in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${PORT}/api/schemas" || true)"
  if [ "$code" = "200" ]; then log "HEALTHY ($code) at $(git rev-parse --short HEAD)"; exit 0; fi
  sleep 15
done

log "UNHEALTHY after restart — ROLLING BACK to $OLD"
git reset --hard "$OLD"
cd "$APP/api" && rm -rf _build/prod && MIX_ENV=prod mix deps.compile --force >/dev/null 2>&1 && MIX_ENV=prod mix compile >/dev/null 2>&1
cd "$APP" && systemctl restart barkpark
log "rollback restarted; check: curl http://localhost:${PORT}/api/schemas"
exit 14
