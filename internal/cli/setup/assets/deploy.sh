#!/usr/bin/env bash
set -euo pipefail

# Barkpark — Server deployment
#
# Installs Erlang, Elixir (via ASDF), Go, and PostgreSQL directly on the server.
# Works on both ARM64 (Hetzner cax*) and x86_64 (Hetzner cpx*/ccx*).
#
# Usage:
#   ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
#
# After setup:
#   ssh root@YOUR_VPS_IP
#   cd /opt/barkpark
#   make rebuild   # after code changes
#   make logs      # tail service logs
#   make status    # check health

APP_DIR="/opt/barkpark"
REPO="https://github.com/FRIKKern/barkpark.git"
DB_NAME="barkpark_prod"
DB_USER="barkpark"
DB_PASS="$(openssl rand -hex 16)"
ARCH=$(uname -m)

# ── Required: DOMAIN ────────────────────────────────────────────────────────
# Phoenix endpoint check_origin whitelists exactly one host+scheme. If we bake
# an IP in while the public URL is https://<dns>, browsers get 403 on
# /live/websocket and the LiveView Studio becomes click-dead. See task #11 and
# docs/ops/studio-nav-bug-2026-04-19.md for the full incident.
if [ -z "${DOMAIN:-}" ]; then
  echo "ERROR: DOMAIN env var is required." >&2
  echo "" >&2
  echo "  Usage: DOMAIN=api.barkpark.cloud bash -s < deploy.sh" >&2
  echo "" >&2
  echo "  DOMAIN must be the public DNS hostname your users will visit," >&2
  echo "  not the VPS IP. If you want an IP-only dev box, set" >&2
  echo "  DOMAIN=<ip> PHX_SCHEME=http explicitly." >&2
  echo "" >&2
  echo "  Background: docs/ops/studio-nav-bug-2026-04-19.md (task #11)" >&2
  exit 2
fi
PHX_SCHEME="${PHX_SCHEME:-https}"

echo "============================================"
echo "  Barkpark — Server Setup"
echo "  Arch:   $ARCH"
echo "  Domain: $DOMAIN ($PHX_SCHEME)"
echo "============================================"
echo ""

export DEBIAN_FRONTEND=noninteractive

# ── 1. System packages ──────────────────────────────────────────────────────
echo ">> System packages..."
apt-get update -qq
apt-get install -y -qq \
  build-essential git curl wget unzip \
  libssl-dev automake autoconf libncurses5-dev \
  libvips-dev \
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

# Enable git hooks (auto-clean stale BEAM cache on pull)
git config core.hooksPath .githooks

# ── 6. Environment ──────────────────────────────────────────────────────────
if [ ! -f "$APP_DIR/.env" ]; then
  echo ">> Generating .env..."
  SECRET=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 48)
  # BARKPARK_CLOAK_KEY + PREVIEW_JWT_SECRET: prod runtime.exs RAISES at boot if
  # either is unset (Cloak vault key; preview-JWT signer). Independent of
  # SECRET_KEY_BASE so rotating one never invalidates the other.
  CLOAK=$(mix phx.gen.secret 32 2>/dev/null || openssl rand -base64 32)
  PREVIEW_JWT=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 32)
  cat > "$APP_DIR/.env" << ENVEOF
DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME
SECRET_KEY_BASE=$SECRET
BARKPARK_CLOAK_KEY=$CLOAK
PREVIEW_JWT_SECRET=$PREVIEW_JWT
PHX_HOST=$DOMAIN
PHX_SCHEME=$PHX_SCHEME
PORT=4000
MIX_ENV=prod
ENVEOF
else
  echo "   .env exists, keeping secrets"
  # Update DB password for existing installs
  sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
  sed -i "s|DATABASE_URL=.*|DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME|" "$APP_DIR/.env"
fi

# Backfill generated secrets required by prod runtime.exs but absent from .env
# files written by older deploy.sh versions (each RAISES at boot if unset).
# Idempotent: append only when missing, never overwrite an existing value.
for _var in BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET; do
  if ! grep -q "^${_var}=" "$APP_DIR/.env"; then
    echo ">> Adding missing ${_var} to .env"
    echo "${_var}=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 32)" >> "$APP_DIR/.env"
  fi
done

# Persist the plugin whitelist ONLY when the caller set it (bp setup threads it
# through the ssh env prefix). Set-ness is tested with ${VAR+x} — NEVER
# ${BARKPARK_PLUGINS:-}, which expands an unset var to the empty string, and
# empty IS the server-side plugin kill switch. An unset var writes nothing, so
# manual deploys keep today's discover-everything behaviour byte-identically.
if [ -n "${BARKPARK_PLUGINS+x}" ]; then
  echo ">> Persisting BARKPARK_PLUGINS=$BARKPARK_PLUGINS into .env"
  if grep -q "^BARKPARK_PLUGINS=" "$APP_DIR/.env"; then
    sed -i "s|^BARKPARK_PLUGINS=.*|BARKPARK_PLUGINS=$BARKPARK_PLUGINS|" "$APP_DIR/.env"
  else
    echo "BARKPARK_PLUGINS=$BARKPARK_PLUGINS" >> "$APP_DIR/.env"
  fi
fi

set -a; source "$APP_DIR/.env"; set +a

# Admin token: on the `clean` profile, mint one now so the seed installs it and
# we can print the exact `bp` login command at the end. The `demo` profile
# (default) seeds the shared dev token instead. Never overrides a caller-set one.
SEED_PROFILE="${BARKPARK_SEED_PROFILE:-demo}"
ADMIN_TOKEN=""
if [ "$SEED_PROFILE" = "clean" ] && [ -z "${BARKPARK_SEED_ADMIN_TOKEN:-}" ]; then
  ADMIN_TOKEN="bp_admin_$(openssl rand 24 | base64 | tr '+/' '-_' | tr -d '=')"
  export BARKPARK_SEED_ADMIN_TOKEN="$ADMIN_TOKEN"
fi

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
go build -o bin/barkpark ./cmd/barkpark
echo "   Go TUI built"

# ── 9. Systemd service ──────────────────────────────────────────────────────
echo ">> Configuring systemd..."
cat > /etc/systemd/system/barkpark.service << SVCEOF
[Unit]
Description=Barkpark
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
systemctl enable barkpark
systemctl restart barkpark

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

# ── 12. TLS (Caddy) ──────────────────────────────────────────────────────────
# Auto-HTTPS for a real hostname. Skipped when PHX_SCHEME=http or DOMAIN is a
# bare IP, and NEVER clobbers an existing Caddy install (prod runs its own
# multi-site Caddy — see docs/ops/PROD_OPS.md). Caddy issues the Let's Encrypt
# cert automatically the moment public DNS points $DOMAIN at this box.
TLS_READY=""
if [ "$PHX_SCHEME" = "https" ] && printf '%s' "$DOMAIN" | grep -q '[a-zA-Z]'; then
  if command -v caddy >/dev/null 2>&1; then
    echo ">> TLS: Caddy already installed — leaving its config untouched"
  else
    echo ">> TLS: installing Caddy for $DOMAIN..."
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq && apt-get install -y -qq caddy
    cat > /etc/caddy/Caddyfile <<CADDYEOF
$DOMAIN {
	reverse_proxy localhost:4000
}
CADDYEOF
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
    TLS_READY=1
    echo "   Caddy serving https://$DOMAIN (cert issues once DNS points here)"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================"
echo "  Barkpark is running!"
echo "============================================"
echo ""
if [ -n "$TLS_READY" ]; then
  echo "  Live:   https://$DOMAIN/studio   (after DNS for $DOMAIN points at $IP)"
  echo "  API:    https://$DOMAIN/api/schemas"
else
  echo "  Studio: http://$IP:4000/studio"
  echo "  API:    http://$IP:4000/api/documents/post"
fi
echo ""
if [ -n "$ADMIN_TOKEN" ]; then
  echo "  Admin token (shown ONCE — save it now):"
  echo "    $ADMIN_TOKEN"
  echo ""
  echo "  Log in from your machine:"
  if [ -n "$TLS_READY" ]; then
    echo "    bp setup --target connect --server https://$DOMAIN --token $ADMIN_TOKEN"
  else
    echo "    bp setup --target connect --server http://$IP:4000 --token $ADMIN_TOKEN"
  fi
  echo ""
fi
echo "  SSH workflow:"
echo "    ssh root@$IP"
echo "    cd $APP_DIR"
echo "    make rebuild   # after code changes"
echo "    make logs      # tail logs"
echo "    make status    # service health"
echo ""
echo "  Update from GitHub:"
echo "    cd $APP_DIR && git pull && make rebuild"
echo ""
