#!/usr/bin/env bash
set -euo pipefail

# Barkpark CMS — Hetzner VPS native deployment
#
# Installs everything directly on the server so you can
# SSH in, edit source code, rebuild, and restart instantly.
#
# Usage (from your local machine):
#   ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
#
# After setup, SSH in and use:
#   cd /opt/barkpark-cms
#   make rebuild   # rebuild + restart after code changes
#   make logs      # tail logs
#   make status    # check service status

APP_DIR="/opt/barkpark-cms"
REPO="https://github.com/FRIKKern/barkpark-cms.git"
DB_NAME="barkpark_prod"
DB_USER="barkpark"
DB_PASS="$(openssl rand -hex 16)"

echo "============================================"
echo "  Barkpark CMS — Native Server Setup"
echo "============================================"
echo ""

# ── 1. System ────────────────────────────────────────────────────────────────
echo ">> Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  build-essential git curl wget unzip \
  libssl-dev automake autoconf \
  inotify-tools

# ── 2. PostgreSQL ────────────────────────────────────────────────────────────
if ! command -v psql &>/dev/null; then
  echo ">> Installing PostgreSQL 17..."
  apt-get install -y -qq postgresql postgresql-contrib
fi
systemctl enable postgresql
systemctl start postgresql

# Create database and user
echo ">> Setting up database..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
sudo -u postgres psql -c "ALTER USER $DB_USER CREATEDB;"

# ── 3. Erlang + Elixir ──────────────────────────────────────────────────────
if ! command -v elixir &>/dev/null; then
  echo ">> Installing Erlang + Elixir..."
  # Add Erlang Solutions repo
  wget -q https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
  dpkg -i erlang-solutions_2.0_all.deb
  rm erlang-solutions_2.0_all.deb
  apt-get update -qq
  apt-get install -y -qq esl-erlang elixir
fi
mix local.hex --force
mix local.rebar --force
echo "   Elixir: $(elixir --version | tail -1)"

# ── 4. Go ────────────────────────────────────────────────────────────────────
if ! command -v go &>/dev/null; then
  echo ">> Installing Go..."
  GO_VERSION="1.24.2"
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
  rm "go${GO_VERSION}.linux-amd64.tar.gz"
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
  export PATH=$PATH:/usr/local/go/bin
fi
echo "   Go: $(go version)"

# ── 5. Clone or update repo ─────────────────────────────────────────────────
if [ -d "$APP_DIR" ]; then
  echo ">> Updating existing installation..."
  cd "$APP_DIR"
  git pull
else
  echo ">> Cloning repository..."
  git clone "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

# ── 6. Environment file ─────────────────────────────────────────────────────
ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo ">> Generating .env..."
  SECRET_KEY_BASE=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 48)
  IP=$(hostname -I | awk '{print $1}')
  cat > "$ENV_FILE" << EOF
# Barkpark CMS Configuration
DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME
SECRET_KEY_BASE=$SECRET_KEY_BASE
PHX_HOST=$IP
PORT=4000
MIX_ENV=prod
EOF
  echo "   Created .env"
else
  echo "   .env exists, keeping existing config"
fi

# Source env for the build
set -a
source "$ENV_FILE"
set +a

# ── 7. Build Phoenix API ────────────────────────────────────────────────────
echo ">> Building Phoenix API..."
cd "$APP_DIR/api"
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix ecto.migrate
mix run priv/repo/seeds.exs
echo "   Phoenix built and migrated"

# ── 8. Build Go TUI ─────────────────────────────────────────────────────────
echo ">> Building Go TUI..."
cd "$APP_DIR"
go build -o bin/barkpark .
echo "   TUI built at bin/barkpark"

# ── 9. Systemd service ──────────────────────────────────────────────────────
echo ">> Creating systemd service..."
cat > /etc/systemd/system/barkpark-cms.service << EOF
[Unit]
Description=Barkpark CMS Phoenix API
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR/api
EnvironmentFile=$APP_DIR/.env
Environment=MIX_ENV=prod
Environment=PHX_SERVER=true
ExecStartPre=/usr/bin/mix ecto.migrate
ExecStart=/usr/bin/mix phx.server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable barkpark-cms
systemctl restart barkpark-cms

# ── 10. Firewall ─────────────────────────────────────────────────────────────
echo ">> Configuring firewall..."
apt-get install -y -qq ufw
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (for future reverse proxy)
ufw allow 443/tcp   # HTTPS
ufw allow 4000/tcp  # Phoenix API
ufw --force enable

# ── 11. Wait for healthy ────────────────────────────────────────────────────
echo ">> Waiting for API..."
for i in $(seq 1 20); do
  if curl -s "http://localhost:4000/api/schemas" > /dev/null 2>&1; then
    echo "   API is ready!"
    break
  fi
  sleep 2
done

# ── Done ─────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================"
echo "  Barkpark CMS is running!"
echo "============================================"
echo ""
echo "  API:  http://$IP:4000"
echo "  Test: curl http://$IP:4000/api/documents/post"
echo ""
echo "  === Server workflow ==="
echo ""
echo "  SSH in:          ssh root@$IP"
echo "  Edit code:       cd $APP_DIR && nano api/lib/sanity_api/content.ex"
echo "  Rebuild:         make rebuild"
echo "  View logs:       make logs"
echo "  Check status:    make status"
echo "  Restart:         make restart"
echo "  Re-seed data:    make seed"
echo ""
echo "  === Connect TUI from your machine ==="
echo ""
echo "  BARKPARK_API_URL=http://$IP:4000 go run ."
echo ""
echo "  === Update from GitHub ==="
echo ""
echo "  cd $APP_DIR && git pull && make rebuild"
echo ""
