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

# ---- Arm the Caddy maintenance page (branded 503 + Retry-After) so ANY window
# where the app is unreachable — a crash/restart outside deploys; blue/green
# deploys themselves don't drop the upstream — shows "back in a moment", not a
# raw 502. Idempotent, backed up, `caddy validate`d, auto-reverting; NEVER fails
# the deploy. Reconciled with the blue/green machinery: the injected block
# contains no `localhost:40xx` token, so the ACTIVE_PORT grep below still hits
# the site upstream first and the port-flip sed passes over it untouched. The
# renderers in internal/caddyfile + internal/cli/setup bake the same block into
# every provisioned instance; this arms an already-running box on deploy.
# Reference copy: deploy/caddy/barkpark-maintenance.caddy.
arm_caddy_maintenance() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping maintenance page"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping maintenance page"; return 0; }
  if grep -q 'BARKPARK_MAINTENANCE' "$CADDYFILE"; then log "caddy maintenance page already armed"; return 0; fi
  if ! grep -qE 'reverse_proxy[[:space:]]+localhost:40[0-9]{2}([[:space:]]|$)' "$CADDYFILE"; then
    log "no 'reverse_proxy localhost:40xx' site in $CADDYFILE — leaving Caddy untouched (arm manually: deploy/caddy/barkpark-maintenance.caddy)"
    return 0
  fi
  local block; block="$(cat <<'MAINT'
	handle_errors {
		header Retry-After "15"
		respond 503 {
			body <<BARKPARK_MAINTENANCE
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Back in a moment</title>
<style>body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1115;color:#e7e9ee;display:grid;place-items:center;min-height:100vh;margin:0}.card{max-width:32rem;padding:2.5rem;text-align:center}h1{font-size:1.5rem;margin:0 0 .5rem}p{opacity:.7;line-height:1.5}.spinner{width:2rem;height:2rem;border:3px solid #2a2f3a;border-top-color:#6ea8fe;border-radius:50%;margin:0 auto 1.5rem;animation:spin 1s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}</style>
</head><body><div class="card"><div class="spinner"></div><h1>Back in a moment</h1>
<p>Barkpark is deploying an update and will be right back. This page refreshes automatically.</p></div>
<script>setTimeout(function(){location.reload()},15000)</script></body></html>
BARKPARK_MAINTENANCE
			close
		}
	}
MAINT
)"
  local bak; bak="${CADDYFILE}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert the block right after the FIRST `reverse_proxy localhost:40xx` line
  # (whichever slot port is live), so it lands inside that site block.
  BP_BLOCK="$block" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"] }
    { print }
    !ins && $0 ~ /reverse_proxy[ \t]+localhost:40[0-9][0-9]([ \t]|$)/ { print blk; ins=1 }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — the caddy user must still be
  # able to read its own config or `systemctl reload caddy` fails with
  # "permission denied" (bit the first live blue/green flip on guerrilla).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed Caddy maintenance page"; else log "caddy reload failed (config valid) — armed on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the injected block — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
arm_caddy_maintenance

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
