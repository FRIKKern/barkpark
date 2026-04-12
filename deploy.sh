#!/usr/bin/env bash
set -euo pipefail

# Barkpark CMS — Server deployment
#
# Installs Erlang, Elixir (via ASDF), Go, and PostgreSQL directly on the server.
# Works on both ARM64 (Hetzner cax*) and x86_64 (Hetzner cpx*/ccx*).
#
# Usage:
#   ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
#
# After setup:
#   ssh root@YOUR_VPS_IP
#   cd /opt/barkpark-cms
#   make rebuild   # after code changes
#   make logs      # tail service logs
#   make status    # check health

APP_DIR="/opt/barkpark-cms"
REPO="https://github.com/FRIKKern/barkpark-cms.git"
DB_NAME="barkpark_prod"
DB_USER="barkpark"
DB_PASS="$(openssl rand -hex 16)"
ARCH=$(uname -m)

echo "============================================"
echo "  Barkpark CMS — Server Setup"
echo "  Arch: $ARCH"
echo "============================================"
echo ""

export DEBIAN_FRONTEND=noninteractive

# ── 1. System packages ──────────────────────────────────────────────────────
echo ">> System packages..."
apt-get update -qq
apt-get install -y -qq \
  build-essential git curl wget unzip \
  libssl-dev automake autoconf libncurses5-dev \
  inotify-tools ufw

# ── 2. PostgreSQL ────────────────────────────────────────────────────────────
echo ">> PostgreSQL..."
apt-get install -y -qq postgresql postgresql-contrib
systemctl enable postgresql
systemctl start postgresql

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS' CREATEDB;"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
echo "   Database: $DB_NAME (user: $DB_USER)"

# ── 3. ASDF + Erlang + Elixir ───────────────────────────────────────────────
echo ">> Erlang + Elixir (via ASDF)..."
if [ ! -d /root/.asdf ]; then
  git clone https://github.com/asdf-vm/asdf.git /root/.asdf --branch v0.14.0
  echo '. /root/.asdf/asdf.sh' >> /root/.bashrc
fi
export PATH="/root/.asdf/bin:/root/.asdf/shims:$PATH"
. /root/.asdf/asdf.sh

asdf plugin list 2>/dev/null | grep -q erlang || asdf plugin add erlang
asdf plugin list 2>/dev/null | grep -q elixir || asdf plugin add elixir

if ! asdf list erlang 2>/dev/null | grep -q 27; then
  echo "   Building Erlang 27 (takes 5-10 min on first run)..."
  asdf install erlang 27.3.4
  asdf global erlang 27.3.4
fi

if ! asdf list elixir 2>/dev/null | grep -q 1.18; then
  asdf install elixir 1.18.4-otp-27
  asdf global elixir 1.18.4-otp-27
fi

mix local.hex --force 2>/dev/null
mix local.rebar --force 2>/dev/null
echo "   Elixir: $(elixir --version 2>&1 | tail -1)"

# ── 4. Go ────────────────────────────────────────────────────────────────────
echo ">> Go..."
if ! command -v go &>/dev/null; then
  GO_VERSION="1.24.2"
  case "$ARCH" in
    aarch64|arm64) GO_ARCH="arm64" ;;
    *)             GO_ARCH="amd64" ;;
  esac
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  rm "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
fi
export PATH=$PATH:/usr/local/go/bin
echo "   $(go version)"

# ── 5. Clone repo ────────────────────────────────────────────────────────────
echo ">> Cloning repo..."
if [ -d "$APP_DIR" ]; then
  cd "$APP_DIR" && git pull
else
  git clone "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

# ── 6. Environment ──────────────────────────────────────────────────────────
if [ ! -f "$APP_DIR/.env" ]; then
  echo ">> Generating .env..."
  SECRET=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 48)
  IP=$(hostname -I | awk '{print $1}')
  cat > "$APP_DIR/.env" << ENVEOF
DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME
SECRET_KEY_BASE=$SECRET
PHX_HOST=$IP
PORT=4000
MIX_ENV=prod
ENVEOF
else
  echo "   .env exists, keeping secrets"
  # Update DB password for existing installs
  sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
  sed -i "s|DATABASE_URL=.*|DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME|" "$APP_DIR/.env"
fi

set -a; source "$APP_DIR/.env"; set +a

# ── 7. Build Phoenix ────────────────────────────────────────────────────────
echo ">> Building Phoenix API..."
cd "$APP_DIR/api"
export MIX_ENV=prod
mix deps.get
mix deps.compile
mix compile
mix ecto.migrate
mix run priv/repo/seeds.exs
echo "   Phoenix built"

# ── 8. Build Go TUI ─────────────────────────────────────────────────────────
echo ">> Building Go TUI..."
cd "$APP_DIR"
go mod tidy
go build -o bin/barkpark .
echo "   Go TUI built"

# ── 9. Systemd service ──────────────────────────────────────────────────────
echo ">> Configuring systemd..."
cat > /etc/systemd/system/barkpark-cms.service << SVCEOF
[Unit]
Description=Barkpark CMS
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
ExecStart=$APP_DIR/api/start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable barkpark-cms
systemctl restart barkpark-cms

# ── 10. Firewall ─────────────────────────────────────────────────────────────
echo ">> Firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 4000/tcp
ufw --force enable

# ── 11. Wait for healthy ────────────────────────────────────────────────────
echo ">> Waiting for API..."
for i in $(seq 1 30); do
  if curl -s "http://localhost:4000/api/schemas" > /dev/null 2>&1; then
    echo "   Ready!"
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
echo "  Studio: http://$IP:4000/studio"
echo "  API:    http://$IP:4000/api/documents/post"
echo ""
echo "  SSH workflow:"
echo "    ssh root@$IP"
echo "    cd $APP_DIR"
echo "    make rebuild   # after code changes"
echo "    make logs      # tail logs"
echo "    make status    # service health"
echo ""
echo "  Connect TUI from your machine:"
echo "    BARKPARK_API_URL=http://$IP:4000 go run ."
echo ""
echo "  Update from GitHub:"
echo "    cd $APP_DIR && git pull && make rebuild"
echo ""
