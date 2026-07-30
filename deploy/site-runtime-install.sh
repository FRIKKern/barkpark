#!/usr/bin/env bash
# site-runtime-install.sh — install the site-hosting stack on a managed box.
#
# A box provisioned by `bp launch` gets barkpark-agent (health + approved
# commands) but NOT the site-deploy plane, so hosted-site deployments for that
# box sit queued forever: nothing runs the builder (queued → pushing) or the
# runtime executor (pushing → live). This script closes that gap on ONE box.
# It is streamed to the box by the cp-ops `site-runtime-install` operation
# (runner → CP over DEPLOY_SSH_KEY, CP → box over the warm-pool key) and is
# idempotent — every step probes before it installs, so re-running is safe.
#
# The proper long-term fix is provisioning-time install (bake-server-image /
# the go-live chain); until then this is the sanctioned operator lever.
set -euo pipefail

echo "== probe: $(hostname) $(uname -m) =="

if ! command -v docker >/dev/null; then
  echo "== install docker =="
  apt-get update -qq && apt-get install -y -qq docker.io
  systemctl enable --now docker
fi
docker --version
# nixpacks builds need BuildKit's buildx component (docker.io ships without it).
if ! docker buildx version >/dev/null 2>&1; then
  echo "== install docker-buildx =="
  apt-get update -qq && apt-get install -y -qq docker-buildx
fi
docker buildx version

if ! command -v nixpacks >/dev/null; then
  echo "== install nixpacks =="
  curl -sSL https://nixpacks.com/install.sh | bash
fi
nixpacks --version

# Isolated Go toolchain — never touches the box's PATH or the live CMS.
GO=/usr/local/go/bin/go
if ! $GO version >/dev/null 2>&1; then
  echo "== install go =="
  curl -sL https://go.dev/dl/go1.24.5.linux-arm64.tar.gz | tar -xz -C /usr/local
fi
$GO version

# Fresh shallow tools checkout — NEVER the live /opt/barkpark (its post-merge
# hook rebuilds and restarts the serving CMS; see repo Golden Rule 7).
if [ -d /opt/barkpark-tools/.git ]; then
  git -C /opt/barkpark-tools fetch --depth 1 origin main
  git -C /opt/barkpark-tools reset --hard origin/main
else
  git clone --depth 1 https://github.com/FRIKKern/barkpark /opt/barkpark-tools
fi

# Build platform follows the box architecture — never hardcode it.
case "$(uname -m)" in
  x86_64) PLATFORM=linux/amd64 ;;
  aarch64) PLATFORM=linux/arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

cd /opt/barkpark-tools
$GO build -o /usr/local/bin/barkpark-builder ./cmd/barkpark-builder
$GO build -o /usr/local/bin/barkpark-runtime ./cmd/barkpark-runtime
echo "== binaries built =="

mkdir -p /var/lib/barkpark-builder/images /var/log/barkpark-builder

# The builder claims with the shared WORKER token when the box has one
# (installed by cp-ops builder-token-fix); reinstalls must not clobber that.
BUILDER_TOKEN=/etc/barkpark/agent.token
[ -f /etc/barkpark/worker.token ] && BUILDER_TOKEN=/etc/barkpark/worker.token

# Both services otherwise authenticate with the box's existing agent identity.
cat > /etc/systemd/system/barkpark-builder.service <<'UNIT'
[Unit]
Description=Barkpark site builder (build plane, co-located)
After=network-online.target docker.service

[Service]
ExecStart=/usr/local/bin/barkpark-builder \
  --control-url https://api.barkpark.cloud \
  --token-file __BUILDER_TOKEN__ \
  --cache-dir /var/lib/barkpark-builder/images \
  --log-dir /var/log/barkpark-builder \
  --platform __PLATFORM__
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/barkpark-runtime.service <<'UNIT'
[Unit]
Description=Barkpark site runtime (on-box deployment executor)
After=network-online.target docker.service caddy.service

[Service]
ExecStart=/usr/local/bin/barkpark-runtime \
  --control-url https://api.barkpark.cloud \
  --token-file /etc/barkpark/agent.token \
  --cache-dir /var/lib/barkpark-builder/images \
  --caddyfile /etc/caddy/Caddyfile \
  --studio localhost:4000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sed -i "s#__PLATFORM__#$PLATFORM#;s#__BUILDER_TOKEN__#$BUILDER_TOKEN#" /etc/systemd/system/barkpark-builder.service

systemctl daemon-reload
systemctl enable --now barkpark-builder barkpark-runtime
systemctl restart barkpark-builder barkpark-runtime
sleep 3
systemctl is-active barkpark-builder barkpark-runtime
echo "== site-runtime-install complete =="
