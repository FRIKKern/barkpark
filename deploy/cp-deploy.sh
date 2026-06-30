#!/usr/bin/env bash
# Refresh the Barkpark Cloud CONTROL PLANE (barkpark.cloud / barkpark-cp) to
# origin/main. Run on the box as root (the CD workflow scps this + the
# cross-built provisioner binary, then executes it).
#
#   bash cp-deploy.sh [path-to-prebuilt-linux-amd64-provisioner]
#
# Zero-downtime: build the new image while the old container still serves; only
# swap on a clean build; auto-rollback to the tagged image + prior commit if the
# new container is unhealthy. The control_plane container auto-migrates its DB on
# boot. Go is NOT installed on barkpark-cp, so the provisioner is cross-built by
# the runner and passed in.
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
COMPOSE="$APP/cloud/docker-compose.yml"
PROV_BIN="${1:-}"
log() { echo "[cp-deploy $(date -u +%H:%M:%S)] $*"; }

cd "$APP" || { log "no $APP"; exit 10; }
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

docker tag cloud-control_plane:latest cloud-control_plane:rollback 2>/dev/null \
  && log "tagged rollback image" || log "no current image to tag (first deploy?)"

git checkout -- . 2>/dev/null || true
log "git pull"
git pull --ff-only origin main || { log "pull failed"; exit 11; }
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Secrets are passthrough — export cloud/.env so `up` resolves them.
if [ ! -f cloud/.env ]; then log "MISSING cloud/.env — abort (container untouched)"; git reset --hard "$OLD"; exit 12; fi
set -a; . cloud/.env; set +a

log "docker compose build (old container still serving)"
if ! docker compose -f "$COMPOSE" build; then
  log "BUILD FAILED — reset + abort (no downtime)"; git reset --hard "$OLD"; exit 13
fi

log "swap: docker compose up -d (auto-migrates on boot)"
docker compose -f "$COMPOSE" up -d

ok=0
for i in $(seq 1 24); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://localhost:4100/ || true)"
  if echo "$code" | grep -qE '^(200|301|302|404)$'; then ok=1; log "control plane healthy ($code)"; break; fi
  sleep 5
done

if [ "$ok" != "1" ]; then
  log "UNHEALTHY — ROLLING BACK to $OLD"
  docker compose -f "$COMPOSE" down || true
  docker tag cloud-control_plane:rollback cloud-control_plane:latest 2>/dev/null || true
  git reset --hard "$OLD"
  docker compose -f "$COMPOSE" up -d
  log "rollback up; :4100 = $(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://localhost:4100/ || true)"
  exit 14
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

log "DONE — control plane at $(git rev-parse --short HEAD)"
