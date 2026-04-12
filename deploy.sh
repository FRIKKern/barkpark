#!/usr/bin/env bash
set -euo pipefail

# NextGen CMS — Hetzner VPS deployment script
# Run this on a fresh Ubuntu 22.04+ Hetzner Cloud VPS
#
# Usage:
#   ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
#   OR
#   scp deploy.sh root@YOUR_VPS_IP: && ssh root@YOUR_VPS_IP bash deploy.sh

APP_DIR="/opt/nextgen-cms"
REPO="https://github.com/FRIKKern/nextgen-cms.git"

echo "=== NextGen CMS — Hetzner Deployment ==="
echo ""

# ── 1. System updates ────────────────────────────────────────────────────────
echo ">> Updating system..."
apt-get update -qq
apt-get upgrade -y -qq

# ── 2. Install Docker ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo ">> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

if ! command -v docker compose &>/dev/null; then
  echo ">> Installing Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin
fi

echo "Docker: $(docker --version)"

# ── 3. Firewall ──────────────────────────────────────────────────────────────
echo ">> Configuring firewall..."
apt-get install -y -qq ufw
ufw allow 22/tcp   # SSH
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS
ufw allow 4000/tcp # Phoenix API
ufw --force enable

# ── 4. Clone or update repo ─────────────────────────────────────────────────
if [ -d "$APP_DIR" ]; then
  echo ">> Updating existing installation..."
  cd "$APP_DIR"
  git pull
else
  echo ">> Cloning repository..."
  git clone "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

# ── 5. Generate secrets ─────────────────────────────────────────────────────
ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo ">> Generating secrets..."
  SECRET_KEY_BASE=$(openssl rand -base64 48)
  cat > "$ENV_FILE" << EOF
SECRET_KEY_BASE=$SECRET_KEY_BASE
PHX_HOST=$(hostname -I | awk '{print $1}')
PORT=4000
EOF
  echo "   Created .env with SECRET_KEY_BASE"
else
  echo "   .env already exists, keeping existing secrets"
fi

# ── 6. Build and start ──────────────────────────────────────────────────────
echo ">> Building containers..."
docker compose --env-file "$ENV_FILE" build

echo ">> Starting services..."
docker compose --env-file "$ENV_FILE" up -d

# ── 7. Wait for healthy ─────────────────────────────────────────────────────
echo ">> Waiting for API to be ready..."
for i in $(seq 1 30); do
  if curl -s "http://localhost:4000/api/schemas" > /dev/null 2>&1; then
    echo "   API is ready!"
    break
  fi
  sleep 2
done

# ── 8. Print info ────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================"
echo "  NextGen CMS is running!"
echo "============================================"
echo ""
echo "  API:     http://$IP:4000"
echo "  Docs:    http://$IP:4000/api/documents/post"
echo "  Schemas: http://$IP:4000/v1/schemas/production"
echo "           (requires: Authorization: Bearer sanity-dev-token)"
echo ""
echo "  Go TUI:  SANITY_API_URL=http://$IP:4000 go run ."
echo ""
echo "  Logs:    docker compose -f $APP_DIR/docker-compose.yml logs -f"
echo "  Stop:    docker compose -f $APP_DIR/docker-compose.yml down"
echo "  Update:  cd $APP_DIR && git pull && docker compose build && docker compose up -d"
echo ""
