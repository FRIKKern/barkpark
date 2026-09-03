#!/usr/bin/env bash
set -euo pipefail

# task-466aef17f2085404: this runs UNATTENDED over `ssh … 'bash -s'` with no tty.
# Without GIT_TERMINAL_PROMPT=0 a git that wants a username (a private $REPO, an
# expired token, git 2.34's protocol-v2 refusal — task-8a523f080fa406d2) HANGS on
# a prompt nobody can answer until the ssh session dies, and the only trace is a
# bare non-zero exit. Fail, never hang — and say WHICH call failed and why it
# probably did. Every git network call below goes through bp_git; a test scans
# this file for clone/pull/fetch and reds on one that does not.
export GIT_TERMINAL_PROMPT=0
# bp_git BEGIN
bp_git() {
  if ! git "$@"; then
    echo "!! git $1 failed (GIT_TERMINAL_PROMPT=0, so no credentials were asked for): $*" >&2
    echo "   likely cause: credentials (a private remote or an expired token) or the remote is unreachable." >&2
    return 1
  fi
}
# bp_git END

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
# The port the service binds to. Written into .env below, which api/start.sh
# sources — so this single value drives the systemd unit, the firewall, the
# health probe and every URL we print. A probe hardcoded to 4000 while the
# service listens elsewhere fails on a HEALTHY box, which would turn the
# honest "not answering" banner below into a new lie.
APP_PORT="${PORT:-4000}"
# A port that is not a number is REFUSED, never carried. It would otherwise
# reach `ufw allow <junk>/tcp` and the probe URL, where a broken firewall rule
# and a probe that can never succeed produce the "NOT ANSWERING" banner on a
# box whose only fault is a typo — the honest banner made dishonest by its own
# input. Same rule for the .env re-read below.
case "$APP_PORT" in
  '' | *[!0-9]*)
    echo "deploy.sh: PORT must be a number, got: $APP_PORT" >&2
    exit 2
    ;;
esac
# Health-probe shape. Overridable so scripts/deploy-health-banner.test.sh can
# drive the REAL loop without waiting out 60s per case.
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-30}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"

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
  bp_git clone https://github.com/asdf-vm/asdf.git /root/.asdf --branch v0.14.0
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
  cd "$APP_DIR" && bp_git pull
else
  bp_git clone "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

# Enable git hooks (auto-clean stale BEAM cache on pull)
git config core.hooksPath .githooks

# ── 6. Environment ──────────────────────────────────────────────────────────
if [ ! -f "$APP_DIR/.env" ]; then
  echo ">> Generating .env..."
  SECRET=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 48)
  # Cloak + preview + KEK + release-capture HMAC: prod runtime.exs
  # RAISES at boot if any is unset (Cloak vault key; preview-JWT signer;
  # field-seal key-encryption-key). Each is independent of SECRET_KEY_BASE and
  # of each other, so rotating one never invalidates the others.
  CLOAK=$(mix phx.gen.secret 32 2>/dev/null || openssl rand -base64 32)
  PREVIEW_JWT=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 32)
  # BARKPARK_KEK MUST be base64 of EXACTLY 32 bytes (Barkpark.Crypto.LocalKek
  # Base.decode64 → <<_::256>>). `mix phx.gen.secret 32` emits a TRUNCATED
  # 32-CHARACTER string (decodes to ~24 bytes), which LocalKek rejects → the app
  # raises at boot. openssl rand -base64 32 is exactly base64(32 bytes).
  KEK=$(openssl rand -base64 32)
  RELEASE_CAPTURE_HMAC=$(openssl rand -base64 32)
  cat > "$APP_DIR/.env" << ENVEOF
DATABASE_URL=ecto://$DB_USER:$DB_PASS@localhost/$DB_NAME
SECRET_KEY_BASE=$SECRET
BARKPARK_CLOAK_KEY=$CLOAK
PREVIEW_JWT_SECRET=$PREVIEW_JWT
BARKPARK_KEK=$KEK
BARKPARK_RELEASE_CAPTURE_HMAC_SECRET=$RELEASE_CAPTURE_HMAC
PHX_HOST=$DOMAIN
PHX_SCHEME=$PHX_SCHEME
PORT=$APP_PORT
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
for _var in BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_KEK BARKPARK_RELEASE_CAPTURE_HMAC_SECRET; do
  if ! grep -q "^${_var}=" "$APP_DIR/.env"; then
    echo ">> Adding missing ${_var} to .env"
    # BARKPARK_KEK needs base64(EXACTLY 32 bytes) — openssl, NOT the truncated
    # `mix phx.gen.secret` (see the heredoc above). This backfill path is what an
    # EXISTING install hits on upgrade (e.g. a box with CLOAK+PREVIEW but no KEK),
    # so a wrong-size KEK here bricks the upgrade at boot.
    case "$_var" in
      BARKPARK_KEK) _val=$(openssl rand -base64 32) ;;
      *) _val=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 32) ;;
    esac
    echo "${_var}=$_val" >> "$APP_DIR/.env"
  fi
done

# Re-derive the port from the .env that is actually on disk — the file
# api/start.sh sources, i.e. the same source the service binds to. On an
# EXISTING install we keep the file's secrets (and its PORT), so the value we
# computed from the environment above may not be what boots. Everything after
# this line (firewall, health probe, printed URLs) descends from this one read.
# Quotes are stripped as well as whitespace: deploy.sh only ever writes a bare
# value, but a hand-edited `PORT="5000"` is a real shape, and carrying the
# quotes into `ufw allow "5000"/tcp` breaks the rule silently.
_env_port="$(sed -n 's/^PORT=//p' "$APP_DIR/.env" | tail -n1 | tr -d '[:space:]"'"'")"
if [ -n "$_env_port" ]; then
  case "$_env_port" in
    *[!0-9]*)
      # Do NOT carry it. Everything downstream — firewall rule, probe URL,
      # printed URLs — would then descend from a value that cannot be a port,
      # and the failure would surface as a false "NOT ANSWERING" banner rather
      # than as the .env defect it is.
      echo "deploy.sh: PORT in $APP_DIR/.env is not a number ($_env_port); fix it before deploying." >&2
      exit 2
      ;;
    *) APP_PORT="$_env_port" ;;
  esac
fi

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

# Persist BARKPARK_CLOUD_URL the same way — set-ness only, ${VAR+x} not
# ${VAR:-}. This is the control-plane ORIGIN constant (https://barkpark.cloud)
# that arms the "Log in with Barkpark Cloud" button on /login; runtime.exs reads
# it into :cloud_login_url and the session page deep-links to
# <origin>/#/instance-login?url=<this instance's own origin>. bp setup deploy
# always threads it through the ssh env prefix, so this backfills the value onto
# boxes provisioned before caddy.go's go-live step stamped it (older instances
# render NO Cloud button until this runs). An unset var writes nothing, so a
# manual `bash deploy.sh` keeps today's behaviour byte-identically.
if [ -n "${BARKPARK_CLOUD_URL+x}" ]; then
  echo ">> Persisting BARKPARK_CLOUD_URL=$BARKPARK_CLOUD_URL into .env"
  if grep -q "^BARKPARK_CLOUD_URL=" "$APP_DIR/.env"; then
    sed -i "s|^BARKPARK_CLOUD_URL=.*|BARKPARK_CLOUD_URL=$BARKPARK_CLOUD_URL|" "$APP_DIR/.env"
  else
    echo "BARKPARK_CLOUD_URL=$BARKPARK_CLOUD_URL" >> "$APP_DIR/.env"
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
# bin/barkpark is the tracked personal-local launcher script — build the TUI
# to a different name so go build never collides with it.
go build -o bin/barkpark-tui ./cmd/barkpark
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
ufw allow "$APP_PORT"/tcp
ufw --force enable

# ── 11. Wait for healthy ────────────────────────────────────────────────────
# HEALTHY is the measurement this whole script's closing banner descends from.
# It used to be taken and discarded: 30 failed probes fell through silently and
# the "Barkpark is running!" banner printed unconditionally, exit 0. Never let
# the banner outrun the probe again.
echo ">> Waiting for API on localhost:$APP_PORT..."
HEALTHY=0
for i in $(seq 1 "$HEALTH_ATTEMPTS"); do
  # -f so a non-2xx (a booting or crashed endpoint answering 500) is NOT read
  # as healthy: the measurement is a good answer, not merely an open socket.
  if curl -fs "http://localhost:$APP_PORT/api/schemas" > /dev/null 2>&1; then
    echo "   Ready! (probe $i/$HEALTH_ATTEMPTS)"
    HEALTHY=1
    break
  fi
  sleep "$HEALTH_INTERVAL"
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
	reverse_proxy localhost:$APP_PORT
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
if [ "$HEALTHY" = "1" ]; then
  echo "  Barkpark is running!"
else
  echo "  Barkpark is INSTALLED but NOT ANSWERING"
fi
echo "============================================"
echo ""
if [ "$HEALTHY" != "1" ]; then
  echo "  The API never answered http://localhost:$APP_PORT/api/schemas —"
  echo "  $HEALTH_ATTEMPTS probes over ~$((HEALTH_ATTEMPTS * HEALTH_INTERVAL))s, every one failed."
  echo "  Packages, database, secrets and the systemd unit ARE installed; the"
  echo "  URLs below are where Barkpark will answer once the service comes up."
  echo ""
  echo "  Diagnose on this box:"
  echo "    journalctl -u barkpark -n 200 --no-pager"
  echo "    systemctl status barkpark"
  echo "    curl -v http://localhost:$APP_PORT/api/schemas"
  echo ""
  echo "  Port checked: $APP_PORT (from PORT= in $APP_DIR/.env)"
  echo ""
fi
if [ -n "$TLS_READY" ]; then
  echo "  Live:   https://$DOMAIN/studio   (after DNS for $DOMAIN points at $IP)"
  echo "  API:    https://$DOMAIN/api/schemas"
else
  echo "  Studio: http://$IP:$APP_PORT/studio"
  echo "  API:    http://$IP:$APP_PORT/api/documents/post"
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
    echo "    bp setup --target connect --server http://$IP:$APP_PORT --token $ADMIN_TOKEN"
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

# The exit code descends from the measurement too. The failure path still
# prints the admin token first — it is seeded into the database and shown
# ONCE, so exiting before it would destroy the operator's only credential —
# and only then refuses. A deploy that leaves the API dead is a failed deploy;
# `bash -s < deploy.sh` in a provisioning script must be able to see that.
if [ "$HEALTHY" != "1" ]; then
  echo "  Deploy FAILED: the API is not answering on port $APP_PORT (see diagnostics above)." >&2
  exit 1
fi
