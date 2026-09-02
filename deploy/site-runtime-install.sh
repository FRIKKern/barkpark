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
  echo "== install docker + git =="
  apt-get update -qq && apt-get install -y -qq docker.io git
  systemctl enable --now docker
fi
docker --version
# git is load-bearing at BUILD time — the tools checkout below AND the builder's
# git-ref clone lane both shell out to it — so it is never assumed present. A
# box that already had docker skipped the apt run above, so probe it on its own.
# git ensure (start)
if ! command -v git >/dev/null; then
  echo "== install git =="
  apt-get update -qq && apt-get install -y -qq git
fi
git --version
# git ensure (end)
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
GO_VERSION=1.24.5
# The Go tarball is arch-specific. This used to hardcode linux-arm64, so a bare
# DEFAULT cx23 (x86_64) box aborted here under `set -e` — jarl's box only
# survived because Go was already installed. Same detection as PLATFORM below.
# go-toolchain arch (start)
case "$(uname -m)" in
  x86_64) GO_ARCH=linux-amd64 ;;
  aarch64) GO_ARCH=linux-arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
# go-toolchain arch (end)
if ! $GO version >/dev/null 2>&1; then
  echo "== install go ${GO_VERSION} (${GO_ARCH}) =="
  curl -sL "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz" | tar -xz -C /usr/local
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

# BOTH services authenticate with the box's own agent identity — one credential
# on the box, and it is the per-box, hashed, revocable one (jpf-w1-builder-identity).
#
# There used to be a preference here: if /etc/barkpark/worker.token existed (put
# there by cp-ops builder-token-fix) the builder used it instead. That token is
# the SHARED fleet WORKER_TOKEN, which also opens /v1/internal/* — list and
# deprovision any box — and, until this change, read any site's decrypted env.
# Preferring it meant a box that had ever been hand-fixed kept holding the
# fleet's keys through every reinstall, on hardware that runs untrusted nixpacks
# builds. The preference is deleted rather than inverted so reinstalls CONVERGE:
# a box cannot stay on the old credential by still having the old file.
#
# The builder unit therefore names agent.token directly and carries no token
# placeholder, exactly like the runtime unit beside it.
#
# The two heredocs below are BYTE-IDENTICAL copies of the staged canonical units
# deploy/systemd/barkpark-builder.service and deploy/systemd/barkpark-runtime.service
# (placeholder __PLATFORM__ included). They are inlined and
# not read from the repo on purpose: cp-ops scp's exactly ONE file to the box, so
# this script must stay self-contained. deploy/site-runtime-install_test.sh
# byte-diffs each heredoc against its staged file, so the copies cannot drift —
# edit BOTH sides or the gate goes red.
cat > /etc/systemd/system/barkpark-builder.service <<'UNIT'
[Unit]
Description=Barkpark site builder (build plane, co-located)
After=network-online.target docker.service

[Service]
ExecStart=/usr/local/bin/barkpark-builder \
  --control-url https://api.barkpark.cloud \
  --token-file /etc/barkpark/agent.token \
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
  --studio localhost:4000 \
  --retain-images 3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sed -i "s#__PLATFORM__#$PLATFORM#" /etc/systemd/system/barkpark-builder.service

systemctl daemon-reload
systemctl enable --now barkpark-builder barkpark-runtime
systemctl restart barkpark-builder barkpark-runtime
sleep 3
systemctl is-active barkpark-builder barkpark-runtime
echo "== site-runtime-install complete =="
