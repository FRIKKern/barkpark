#!/usr/bin/env bash
set -euo pipefail

# The whole body sits in one { ... } block. Over `ssh host 'bash -s' < deploy.sh`
# bash reads the script from stdin as it runs, and any child that reads stdin
# eats the rest of it. Measured 2026-10-27 on Ubuntu 22.04: the run stopped with
# exit 0 right after `asdf install erlang`, before Elixir. A block is parsed in
# full before it runs, so no child can take the script away.
{

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

# install_caddy_pkg BEGIN
# ONE Caddy installer, byte-identical in deploy.sh (and its go:embedded copy),
# deploy/azure-base-install.sh, and — extracted from the embedded deploy.sh at
# run time — internal/cli/setup/caddy.go. internal/cli/setup/caddy_test.go reds
# if the copies drift (task-8fcdc94b07a9dc60).
#
# 1. The upstream apt repo FIRST, so a box keeps apt-managed Caddy updates.
# 2. If that repo cannot be used, the SAME upstream package from the pinned
#    GitHub release, verified against a pinned sha512 before it is installed.
#    Measured 2026-10-01: cloudsmith signs caddy/stable's InRelease with subkey
#    531A6B20FA058A70, expired 2024-03-30, so `apt-get update` exits 100
#    (EXPKEYSIG; upstream caddyserver/caddy issue 8095). The repo's source list is
#    then REMOVED, so it cannot fail every later `apt-get update` on the box.
# BARKPARK_CADDY_SKIP_APT=1 skips step 1 (the harness uses it to keep step 2
# tested after the upstream repo recovers). Bumping the fallback: version plus
# both sha512 lines, from that release's caddy_<v>_checksums.txt.
install_caddy_pkg() {
  local v=2.11.4 arch sum deb
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg curl ca-certificates >/dev/null || return 1
  if [ "${BARKPARK_CADDY_SKIP_APT:-0}" != 1 ]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    if apt-get update -qq && apt-get install -y -qq caddy; then
      echo ">> caddy: installed from the upstream apt repo"
      return 0
    fi
    echo "!! caddy: the upstream apt repo is unusable; removing its source list and installing the pinned v$v release .deb" >&2
    rm -f /etc/apt/sources.list.d/caddy-stable.list
  fi
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) sum=1c6f5404f3622e46d401d81f4af59677d46b886229c6694d60fd936b87c72d3bb5d1fcf42b55c8d555769fa75acf434ab618fc7e0df2c79cf8512ee580d38d06 ;;
    arm64) sum=c43c62b7b583b31c682b3c3e1a31cf03759fbab01dcb0fc7d7fc3a5ce1bef43403583e26133920634a730a9fe31dae1386af4d3f9f3fc19fcc2c29ebf19de235 ;;
    *) echo "!! caddy: no pinned release checksum for architecture $arch" >&2; return 1 ;;
  esac
  deb="/tmp/caddy_${v}_linux_${arch}.deb"
  curl -fsSL --retry 3 -o "$deb" "https://github.com/caddyserver/caddy/releases/download/v${v}/caddy_${v}_linux_${arch}.deb" || return 1
  if ! echo "$sum  $deb" | sha512sum -c - >/dev/null; then
    echo "!! caddy: sha512 mismatch for $deb — refusing to install it" >&2
    rm -f "$deb"
    return 1
  fi
  apt-get install -y -qq "$deb" || return 1
  rm -f "$deb"
  echo ">> caddy: installed v$v from the pinned, sha512-verified release .deb"
}
# install_caddy_pkg END

# Barkpark — Server deployment
#
# Installs Erlang, Elixir (via ASDF), Go, and PostgreSQL 17 directly on the server.
# Works on both ARM64 (Hetzner cax*) and x86_64 (Hetzner cpx*/ccx*).
#
# Usage:
#   ssh root@YOUR_VPS_IP 'DOMAIN=example.com bash -s' < deploy.sh
#   ssh azureuser@YOUR_VM_IP 'sudo DOMAIN=example.com bash -s' < deploy.sh
#
# Optional settings file (BARKPARK_ENV_FILE): KEY=VALUE lines in a file on the
# server, merged into /opt/barkpark/.env before the seed and the first start.
#   scp barkpark.env azureuser@YOUR_VM_IP:/tmp/barkpark.env
#   ssh azureuser@YOUR_VM_IP 'sudo DOMAIN=example.com BARKPARK_ENV_FILE=/tmp/barkpark.env bash -s' < deploy.sh
#
# After setup:
#   ssh root@YOUR_VPS_IP
#   cd /opt/barkpark
#   make rebuild   # after code changes
#   make logs      # tail service logs
#   make status    # check health

# Root is required: the script installs packages, writes /etc and runs the
# service as root. A sudo user runs it as `sudo bash -s`. sudo can keep the
# caller's HOME, and asdf, hex and rebar install under $HOME, while the
# service (User=root) and api/start.sh read /root. Pin HOME so both agree.
if [ "$(id -u)" != 0 ]; then
  echo "ERROR: deploy.sh must run as root. As a sudo user: sudo DOMAIN=... bash -s < deploy.sh" >&2
  exit 2
fi
export HOME=/root

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
# --no-install-recommends: without it Ubuntu 22.04 pulled about 300 packages.
# Only what the build needs: a C toolchain, libssl-dev and libncurses-dev for
# the Erlang build (asdf/kerl), autoconf for kerl, unzip for the Elixir
# release zip. No libvips: the :image dep uses vix, which downloads a
# precompiled NIF with libvips bundled, so the system library goes unused.
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential ca-certificates openssl git curl wget unzip \
  libssl-dev autoconf m4 libncurses-dev \
  inotify-tools ufw

# ── 1b. Swap on small VMs ───────────────────────────────────────────────────
# A clean MIX_ENV=prod `mix compile` of the API peaked at 0.95 GB resident
# (measured 2026-10-27), and an update compiles next to the running server and
# Postgres. A VM under 4 GiB with no swap gets a 2 GiB /swapfile so the build
# is slow instead of killed. The limit is 3500000 kB because a 4 GiB VM reports
# a little under 4 GiB in MemTotal. A failed swap step warns and goes on.
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${MEM_KB:-0}" -gt 0 ] && [ "$MEM_KB" -lt 3500000 ] && [ -z "$(swapon --noheadings 2>/dev/null)" ]; then
  echo ">> Swap: ${MEM_KB} kB memory and no swap, adding a 2 GiB /swapfile..."
  if { [ -f /swapfile ] || { { fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; } \
      && chmod 600 /swapfile && mkswap /swapfile >/dev/null; }; } && swapon /swapfile; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    echo "   WARNING: could not add swap; the build may run out of memory on this VM." >&2
  fi
fi

# ── 2. PostgreSQL ────────────────────────────────────────────────────────────
# PostgreSQL 17 from the PostgreSQL apt repository (PGDG), the major that
# deploy/azure/main.bicep runs on Flexible Server, so a backup restores on
# either path. Ubuntu's own package is 14 on 22.04 and 16 on 24.04. A box that
# already has a cluster keeps it and its major: a second major would start a
# second cluster on port 5433 while the database stays on the first.
# postgresql-17 carries citext, pg_trgm and pgcrypto, which the migrations need.
PG_MAJOR=17
echo ">> PostgreSQL..."
if command -v pg_lsclusters >/dev/null 2>&1 && [ -n "$(pg_lsclusters -h 2>/dev/null)" ]; then
  echo "   Keeping the existing cluster: $(pg_lsclusters -h | awk '{print $1 "/" $2}' | tr '\n' ' ')"
else
  . /etc/os-release
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL --retry 3 -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  if ! apt-get install -y -qq --no-install-recommends "postgresql-$PG_MAJOR"; then
    echo "!! PostgreSQL: could not install postgresql-$PG_MAJOR from apt.postgresql.org for $VERSION_CODENAME" >&2
    exit 1
  fi
fi
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
FRESH_ENV=""
if [ ! -f "$APP_DIR/.env" ]; then
  FRESH_ENV=1
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

# .env holds the keys and the database password. The service runs as root, so
# root only. Set on every run: a file from an older deploy.sh was 644.
secure_env() { chown root:root "$APP_DIR/.env" && chmod 600 "$APP_DIR/.env"; }
secure_env

# Operator settings file. BARKPARK_ENV_FILE names a file ON THIS SERVER with
# KEY=VALUE lines (blank lines, # comments and a leading `export ` are fine).
# Each key replaces the same key in .env or is appended, so settings such as
# BARKPARK_BOOTSTRAP_OWNER_EMAIL apply to the seed and the first start below
# instead of needing a second restart. It runs before the PORT read, so a PORT
# in the file drives the firewall and the health probe. Values are never
# printed, only key names. Variables passed on the command line and persisted
# below (BARKPARK_PLUGINS, BARKPARK_SHAPE, BARKPARK_CLOUD_URL) win over the file.
# deploy.sh owns DATABASE_URL and the generated keys (DEPLOY_OWNED_KEYS): the
# file cannot replace them, so an env file from an older `bp instance init`
# cannot point the server at a database or password that does not exist here.
if [ -n "${BARKPARK_ENV_FILE:-}" ]; then
  if [ ! -r "$BARKPARK_ENV_FILE" ]; then
    echo "deploy.sh: BARKPARK_ENV_FILE=$BARKPARK_ENV_FILE is not a readable file on this server." >&2
    exit 2
  fi
  _bad="$(awk '/^[[:space:]]*(#|$)/{next} { sub(/^[[:space:]]*export[[:space:]]+/, "") } !/^[A-Za-z_][A-Za-z0-9_]*=/{print NR}' "$BARKPARK_ENV_FILE" | tr '\n' ' ')"
  if [ -n "$_bad" ]; then
    echo "deploy.sh: BARKPARK_ENV_FILE has lines that are not KEY=VALUE: line(s) $_bad" >&2
    exit 2
  fi
  DEPLOY_OWNED_KEYS="DATABASE_URL SECRET_KEY_BASE BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_KEK BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"
  _kept="$(awk -v owned=" $DEPLOY_OWNED_KEYS " '/^[[:space:]]*(#|$)/{next} {sub(/^[[:space:]]*export[[:space:]]+/, ""); sub(/=.*/, ""); if (index(owned, " " $0 " ") && !seen[$0]++) printf "%s ", $0}' "$BARKPARK_ENV_FILE")"
  _merged="$(mktemp)"
  awk -v owned=" $DEPLOY_OWNED_KEYS " '
    FNR==NR {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      line=$0; sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      k=substr(line, 1, index(line, "=")-1)
      if (index(owned, " " k " ")) next
      if (!(k in val)) order[++n]=k
      val[k]=line; next
    }
    {
      k=$0; sub(/=.*/, "", k)
      if (k in val) { if (!(k in done)) print val[k]; done[k]=1; next }
      print
    }
    END { for (i=1; i<=n; i++) if (!(order[i] in done)) print val[order[i]] }
  ' "$BARKPARK_ENV_FILE" "$APP_DIR/.env" > "$_merged"
  # cat into the existing file keeps its owner and mode.
  cat "$_merged" > "$APP_DIR/.env"
  rm -f "$_merged"
  echo ">> Merged settings from $BARKPARK_ENV_FILE into .env: $(awk -v owned=" $DEPLOY_OWNED_KEYS " '/^[[:space:]]*(#|$)/{next} {sub(/^[[:space:]]*export[[:space:]]+/, ""); sub(/=.*/, ""); if (!index(owned, " " $0 " ") && !seen[$0]++) printf "%s ", $0}' "$BARKPARK_ENV_FILE")"
  if [ -n "$_kept" ]; then
    echo ">> Kept deploy.sh's own values, ignored the file's: $_kept"
  fi
  # The file holds secrets and .env now has every value, so remove it. A file
  # that is .env itself stays.
  if [ "$(readlink -f "$BARKPARK_ENV_FILE")" != "$(readlink -f "$APP_DIR/.env")" ]; then
    rm -f "$BARKPARK_ENV_FILE"
    echo ">> Deleted $BARKPARK_ENV_FILE. Its settings are in $APP_DIR/.env."
  fi
fi

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

# Declare the shape (docs/contracts/product-era.md): a box this script installs
# is Solo unless the caller says otherwise. A BARKPARK_SHAPE the caller set is
# persisted; otherwise an existing line is left alone (the Cloud provisioner
# writes `cloud` over it at go-live, and a re-run must not undo that), and a
# missing line gets `solo`. status.json reports it (Barkpark.Shape).
if [ -n "${BARKPARK_SHAPE:-}" ]; then
  echo ">> Persisting BARKPARK_SHAPE=$BARKPARK_SHAPE into .env"
  if grep -q "^BARKPARK_SHAPE=" "$APP_DIR/.env"; then
    sed -i "s|^BARKPARK_SHAPE=.*|BARKPARK_SHAPE=$BARKPARK_SHAPE|" "$APP_DIR/.env"
  else
    echo "BARKPARK_SHAPE=$BARKPARK_SHAPE" >> "$APP_DIR/.env"
  fi
elif ! grep -q "^BARKPARK_SHAPE=" "$APP_DIR/.env"; then
  echo "BARKPARK_SHAPE=solo" >> "$APP_DIR/.env"
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

# Admin token: on the `clean` profile (the default), mint one now so the seed
# installs it. The `demo` profile, only when asked for by name, seeds the shared
# dev token instead. Never overrides a caller-set one (bp setup deploy passes
# its own and prints it on the operator's machine).
# The token goes to a root-only file, never to stdout, so it stays out of ssh
# logs and CI output. The file is written before the build, so it survives a
# failed run. A re-run reuses the token in the file: the seed installs a token
# only when no unrevoked admin token exists, so a fresh one would not work. A
# box with an existing .env and no token file already has an admin token the
# seed will not replace. After the seed, that box gets a new one from the
# server-side recovery command (start.sh admin-token), into the same file.
SEED_PROFILE="${BARKPARK_SEED_PROFILE:-clean}"
ADMIN_TOKEN=""
ADMIN_TOKEN_FILE="${BARKPARK_ADMIN_TOKEN_FILE:-/etc/barkpark/admin-token}"
RECOVERY_MINT=""
if [ "$SEED_PROFILE" = "clean" ] && [ -z "${BARKPARK_SEED_ADMIN_TOKEN:-}" ]; then
  if [ -s "$ADMIN_TOKEN_FILE" ]; then
    ADMIN_TOKEN="$(tr -d '[:space:]' < "$ADMIN_TOKEN_FILE")"
  elif [ -n "$FRESH_ENV" ]; then
    ADMIN_TOKEN="bp_admin_$(openssl rand 24 | base64 | tr '+/' '-_' | tr -d '=')"
    mkdir -p "$(dirname "$ADMIN_TOKEN_FILE")"
    chmod 700 "$(dirname "$ADMIN_TOKEN_FILE")"
    (umask 077; printf '%s\n' "$ADMIN_TOKEN" > "$ADMIN_TOKEN_FILE")
  else
    RECOVERY_MINT=1
  fi
  if [ -n "$ADMIN_TOKEN" ]; then
    export BARKPARK_SEED_ADMIN_TOKEN="$ADMIN_TOKEN"
  fi
fi

# ── 7. Build Phoenix ────────────────────────────────────────────────────────
echo ">> Building Phoenix API..."
cd "$APP_DIR/api"
export MIX_ENV=prod
mix deps.get
mix deps.compile
mix compile
mix ecto.migrate
# The clean seed prints `Admin token id: <id>` when it installs a token. Keep
# that id next to the token file. The token has no owner user, so once the
# operator allowlist is armed (BARKPARK_OPERATOR_EMAILS set) or
# BARKPARK_OPERATOR_FAIL_CLOSED is on, only BARKPARK_OPERATOR_TOKEN_IDS lets it
# reach the operator routes. Add the id there before the first start, so the
# install cannot lock its own admin token out of `bp org`.
SEED_LOG="$(mktemp)"
mix run priv/repo/seeds.exs | tee "$SEED_LOG"
ADMIN_TOKEN_ID="$(sed -n 's/^Admin token id: *\([A-Za-z0-9-]*\).*/\1/p' "$SEED_LOG" | tail -n1)"
rm -f "$SEED_LOG"
# A re-run with no token file: the seed kept the existing admin token, whose
# value is gone. Mint a new one with the recovery command. It prints only the id
# and the path. A failure leaves the box running and says what to run by hand.
if [ -n "$RECOVERY_MINT" ] && [ -z "$ADMIN_TOKEN_ID" ] && [ ! -e "$ADMIN_TOKEN_FILE" ]; then
  echo ">> No admin token file at $ADMIN_TOKEN_FILE. Minting a new admin token."
  if _mint_out="$(mix barkpark.admin_token --label "admin (deploy.sh re-run)" --file "$ADMIN_TOKEN_FILE")"; then
    printf '%s\n' "$_mint_out"
    ADMIN_TOKEN_ID="$(printf '%s\n' "$_mint_out" | sed -n 's/^Admin token id: *\([A-Za-z0-9-]*\).*/\1/p' | tail -n1)"
    ADMIN_TOKEN="$(tr -d '[:space:]' < "$ADMIN_TOKEN_FILE")"
  else
    echo "!! Admin token mint failed. Run it by hand: sudo $APP_DIR/api/start.sh admin-token --label admin" >&2
  fi
fi
ADMIN_TOKEN_ID_FILE="$ADMIN_TOKEN_FILE.id"
if [ -n "$ADMIN_TOKEN_ID" ]; then
  mkdir -p "$(dirname "$ADMIN_TOKEN_ID_FILE")"
  (umask 077; printf '%s\n' "$ADMIN_TOKEN_ID" > "$ADMIN_TOKEN_ID_FILE")
  _fail_closed="$(sed -n 's/^BARKPARK_OPERATOR_FAIL_CLOSED=//p' "$APP_DIR/.env" | tail -n1 | tr -d '[:space:]"'"'" | tr '[:upper:]' '[:lower:]')"
  _op_emails="$(sed -n 's/^BARKPARK_OPERATOR_EMAILS=//p' "$APP_DIR/.env" | tail -n1 | tr -d '[:space:]"'"',")"
  case "$_fail_closed" in 1 | true | yes | on) _armed=1 ;; *) _armed="" ;; esac
  [ -n "$_op_emails" ] && _armed=1
  if [ -n "$_armed" ]; then
    _ids="$(sed -n 's/^BARKPARK_OPERATOR_TOKEN_IDS=//p' "$APP_DIR/.env" | tail -n1 | tr -d '[:space:]"'"'")"
    case ",$_ids," in
      *",$ADMIN_TOKEN_ID,"*) : ;;
      *)
        _ids="${_ids:+$_ids,}$ADMIN_TOKEN_ID"
        if grep -q "^BARKPARK_OPERATOR_TOKEN_IDS=" "$APP_DIR/.env"; then
          sed -i "s|^BARKPARK_OPERATOR_TOKEN_IDS=.*|BARKPARK_OPERATOR_TOKEN_IDS=$_ids|" "$APP_DIR/.env"
        else
          echo "BARKPARK_OPERATOR_TOKEN_IDS=$_ids" >> "$APP_DIR/.env"
        fi
        echo ">> Added admin token id $ADMIN_TOKEN_ID to BARKPARK_OPERATOR_TOKEN_IDS in .env"
        ;;
    esac
  fi
fi
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
# SIGTERM to the BEAM only. It stops its own port programs (memsup, disksup,
# cpu_sup) in order; signalling the whole cgroup killed them first and logged
# three errors on every clean stop. Leftovers get SIGKILL after the BEAM exits.
KillMode=mixed
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
# ---- 429 backoff, INLINED (task-4526610517915589) ---------------------------
# WHY THE SHARED HELPER scripts/lib/bp-curl.sh IS NOT SOURCED HERE.
# BOTH copies of this file — the repo-root deploy.sh and the byte-identical
# go:embedded copy at internal/cli/setup/assets/deploy.sh that the `bp` binary
# streams into `ssh <host> '<env> bash -s'` (internal/cli/setup/deploy.go, fed
# from assets.DeployScript) — arrive on the REMOTE over STDIN. The root copy's
# own documented usage is `ssh root@VPS 'bash -s' < deploy.sh` (line 10). So in
# both cases $0 is `bash`, BASH_SOURCE names no file, and there is no sibling
# path to lib/ to source from. The only bp-curl.sh that can exist on the box is
# whichever one step 1's clone of $REPO happened to bring — a version neither
# this script nor the binary shipping it ever chose — and a bare `.` on a
# missing file under `set -euo pipefail` would abort a PROVISIONING run at step
# 11, a far worse outcome than an unhandled 429 on a localhost boot probe. So
# the bounded loop is inlined here instead, keeping bp_curl_body's two
# load-bearing properties: the status is captured BEFORE any branch, and the
# wait comes FROM THE RESPONSE rather than a hardcoded sleep.
#
# SUPERSEDES the guarded `. "$APP_DIR/scripts/lib/bp-curl.sh"` + no-backoff
# `bp_curl_body() { curl -fsS "$@"; }` degrade shim that PR 17592
# (task-90059c5c680f6665) put in the ROOT copy only. That arm is deliberately
# NOT carried forward: its fallback silently ran the probe with NO backoff at
# all, and it could only ever have reached the shared helper on a box whose
# $REPO clone happened to carry it. The inline loop is unconditional and has
# no external dependency, so the two copies can be byte-identical — which is
# what `make cli-assets-check` and scripts/doctor.sh require. scripts/lib/bp-curl.sh
# remains canonical for scripts that genuinely run FROM a checkout.
HEALTH_429_ATTEMPTS="${HEALTH_429_ATTEMPTS:-4}"       # tries within ONE probe, first included
HEALTH_429_MAX_WAIT_S="${HEALTH_429_MAX_WAIT_S:-5}"   # a longer ask is a quota, not a blip

# bp_health_probe <url> — one health measurement, with 429 backed off INSIDE it
# so backpressure is never counted as one of the $HEALTH_ATTEMPTS failed probes.
# Exit semantics are `curl -fs`'s, so the caller below converts 1:1: 0 only on a
# 2xx, 22 on any other status, curl's own rc on a transport failure, and nothing
# on stdout. That -f semantics is the point of the probe — a booting or crashed
# endpoint answering 500 is NOT read as healthy; the measurement is a good
# answer, not merely an open socket.
bp_health_probe() {
  local url="$1" hdr attempt=1 code rc wait
  hdr="$(mktemp "${TMPDIR:-/tmp}/bp-health.XXXXXX")" || return 1
  while :; do
    rc=0
    # -w/-D, not -f: -f collapses every status into exit 22, which would make a
    # 429 branch unreachable. Capture first, branch second.
    code="$(curl -sS -D "$hdr" -w '%{http_code}' -o /dev/null "$url" 2>/dev/null)" || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$hdr"; return "$rc"; fi
    case "$code" in
      429) : ;;
      2??) rm -f "$hdr"; return 0 ;;
      *)   rm -f "$hdr"; return 22 ;;
    esac
    # Retry-After as the server sent it; absent or unparseable falls back to 1s.
    # (Header only — this probe discards the body, so the envelope's nested
    # error.details.retry_after that bp-curl.sh also reads is not available.)
    wait="$(awk 'tolower($1)=="retry-after:"{x=$2;gsub(/\r/,"",x);v=x} END{if(v!="")print v}' "$hdr" 2>/dev/null)"
    case "$wait" in ''|*[!0-9]*) wait=1 ;; esac
    if [ "$wait" -gt "$HEALTH_429_MAX_WAIT_S" ]; then
      echo "   rate limited (429): the server asked for ${wait}s, longer than this probe will ever wait (${HEALTH_429_MAX_WAIT_S}s) — reported unslept" >&2
      rm -f "$hdr"; return 22
    fi
    if [ "$attempt" -ge "$HEALTH_429_ATTEMPTS" ]; then
      echo "   rate limited (429): the ${HEALTH_429_ATTEMPTS}-attempt cap for one probe is spent" >&2
      rm -f "$hdr"; return 22
    fi
    echo "   rate limited (429) — BACKPRESSURE, not a fault; waiting ${wait}s and retrying (attempt ${attempt} of ${HEALTH_429_ATTEMPTS})" >&2
    sleep "$wait"
    attempt=$((attempt + 1))
  done
}

echo ">> Waiting for API on localhost:$APP_PORT..."
HEALTHY=0
for i in $(seq 1 "$HEALTH_ATTEMPTS"); do
  # No 2>&1 here: the 429 backoff lines above are the only stderr this can
  # produce, and swallowing them is how a rate limit became invisible.
  #
  # /status.json, NOT /api/schemas: the legacy route is mounted through
  # BarkparkWeb.Plugs.LegacyDeprecation and carries a published
  # `sunset: Wed, 31 Dec 2026 23:59:59 GMT`, and this loop gates on the STATUS
  # CODE, so on removal day a healthy box would report "INSTALLED but NOT
  # ANSWERING" at the end of every provisioning run. /status.json is
  # `pipe_through(:api)` only, needs no token, and is strictly stronger:
  # Status.health/0 runs a bare Repo.all/1, so a dead DB is a 500, not a 200.
  # The repo-root deploy.sh and the VENDORED copy bp ships to every provisioned
  # box are byte-identical, so this retarget (PR 17819) is live in both.
  if bp_health_probe "http://localhost:$APP_PORT/status.json" > /dev/null; then
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
    install_caddy_pkg || { echo "!! TLS: Caddy install failed (apt repo AND pinned release); see above" >&2; exit 1; }
    cat > /etc/caddy/Caddyfile <<CADDYEOF
$DOMAIN {
	reverse_proxy localhost:$APP_PORT
	handle_errors 502 503 504 {
		header Retry-After "15"
		header Content-Type "text/html; charset=utf-8"
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

# Caddy gets its certificate about 40 seconds after it starts. Wait until
# https://$DOMAIN/readyz answers 200 with a certificate this box trusts, so the
# printed login command works the moment the script returns. --resolve sends
# the request to this box, so the wait does not depend on hairpin NAT.
TLS_WAIT_S="${TLS_WAIT_S:-180}"
HTTPS_OK=""
if [ -n "$TLS_READY" ] && [ "$HEALTHY" = "1" ]; then
  echo ">> TLS: waiting up to ${TLS_WAIT_S}s for https://$DOMAIN/readyz with a valid certificate..."
  _t0=$(date +%s)
  while :; do
    if curl -fsS --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/readyz" > /dev/null 2>&1; then
      HTTPS_OK=1
      echo "   HTTPS ready after $(( $(date +%s) - _t0 ))s"
      break
    fi
    if [ $(( $(date +%s) - _t0 )) -ge "$TLS_WAIT_S" ]; then
      echo "!! TLS: https://$DOMAIN/readyz gave no valid answer within ${TLS_WAIT_S}s." >&2
      echo "   Check that DNS for $DOMAIN points at this server, then run: systemctl status caddy" >&2
      break
    fi
    sleep 5
  done
fi

# ── 13. bp and the full instance check ───────────────────────────────────────
# Install bp for root with the same installer an operator uses, into
# /usr/local/bin, which is on sudo's PATH. Then run the full check against the
# real .env, with the database, media and URL probes. Problems are reported in
# the banner; they do not fail the deploy, because the server already runs.
secure_env
CHECK_STATUS="not run: bp was not installed (see the install-cli lines above)"
CHECK_LINES=""
echo ">> Installing bp into /usr/local/bin..."
if _cli_out="$(BARKPARK_BIN_DIR=/usr/local/bin sh "$APP_DIR/scripts/install-cli.sh" </dev/null 2>&1)"; then
  printf '%s\n' "$_cli_out" | grep -E '^install-cli: installed|WARNING' | sed 's/^/   /' || true
  echo ">> Running bp instance check --target vm --env-file $APP_DIR/.env..."
  _check_rc=0
  _check_out="$(/usr/local/bin/bp instance check --target vm --env-file "$APP_DIR/.env" -o table </dev/null 2>&1)" || _check_rc=$?
  printf '%s\n' "$_check_out" | sed 's/^/   /'
  CHECK_LINES="$(printf '%s\n' "$_check_out" | grep -vE '^(  |settings in effect|$)' || true)"
  if [ "$_check_rc" = 0 ]; then
    CHECK_STATUS="ok"
  else
    CHECK_STATUS="FAILED (exit $_check_rc)"
  fi
else
  printf '%s\n' "$_cli_out" | sed 's/^/   /' >&2
fi

# ── Done ─────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
# Azure and other clouds put a private address on the NIC (10.0.0.4) and NAT
# the public one. Print the public address: ask the cloud metadata service
# first (Azure IMDS), then a public echo service, and keep the NIC address only
# when both fail. Each call is bounded to 3 seconds.
case "$IP" in
  10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*)
    _pub="$(curl -fsS --max-time 3 -H Metadata:true \
      'http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text' 2>/dev/null || true)"
    [ -n "$_pub" ] || _pub="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    case "$_pub" in
      *[!0-9.]* | '') : ;;
      *) IP="$_pub" ;;
    esac
    ;;
esac
# Name the DNS step only when DOMAIN does not already resolve to this host.
DNS_NOTE="   (after DNS for $DOMAIN points at $IP)"
if getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -qxF "$IP"; then
  DNS_NOTE=""
fi
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
  echo "  The API never answered http://localhost:$APP_PORT/status.json —"
  echo "  $HEALTH_ATTEMPTS probes over ~$((HEALTH_ATTEMPTS * HEALTH_INTERVAL))s, every one failed."
  echo "  Packages, database, secrets and the systemd unit ARE installed; the"
  echo "  URLs below are where Barkpark will answer once the service comes up."
  echo ""
  echo "  Diagnose on this box:"
  echo "    journalctl -u barkpark -n 200 --no-pager"
  echo "    systemctl status barkpark"
  echo "    curl -v http://localhost:$APP_PORT/status.json"
  echo ""
  echo "  Port checked: $APP_PORT (from PORT= in $APP_DIR/.env)"
  echo ""
fi
if [ -n "$TLS_READY" ] && [ "$HEALTHY" = "1" ] && [ -z "${HTTPS_OK:-}" ]; then
  echo "  HTTPS is NOT READY: https://$DOMAIN/readyz gave no valid answer within ${TLS_WAIT_S:-180}s."
  echo "  The login command below fails until it does. Check DNS and run: systemctl status caddy"
  echo ""
fi
if [ -n "$TLS_READY" ]; then
  echo "  Live:   https://$DOMAIN/studio$DNS_NOTE"
  echo "  API:    https://$DOMAIN/api/schemas"
else
  echo "  Studio: http://$IP:$APP_PORT/studio"
  echo "  API:    http://$IP:$APP_PORT/api/documents/post"
fi
echo ""
SSH_LOGIN="${SUDO_USER:-root}@$IP"
if [ -n "$ADMIN_TOKEN" ]; then
  echo "  Admin token: saved to $ADMIN_TOKEN_FILE (root only, mode 0600)."
  if [ -s "${ADMIN_TOKEN_ID_FILE:-}" ]; then
    echo "  Admin token id: $(cat "$ADMIN_TOKEN_ID_FILE") (also in $ADMIN_TOKEN_ID_FILE)."
    echo "    It is on BARKPARK_OPERATOR_TOKEN_IDS only when the operator allowlist or"
    echo "    BARKPARK_OPERATOR_FAIL_CLOSED is set in $APP_DIR/.env."
  fi
  echo ""
  echo "  Log in from your machine:"
  if [ -n "$TLS_READY" ]; then
    _server="https://$DOMAIN"
  else
    _server="http://$IP:$APP_PORT"
  fi
  echo "    bp setup --target connect --server $_server --token \"\$(ssh $SSH_LOGIN sudo cat $ADMIN_TOKEN_FILE)\""
  echo ""
fi
echo "  For a separate Studio, a workspace owner or admin gets its BARKPARK_TOKEN line with:"
echo "    bp instance studio-token --workspace default"
echo ""
echo "  SSH workflow:"
echo "    ssh $SSH_LOGIN"
echo "    sudo -i"
echo "    cd $APP_DIR"
echo "    make rebuild   # after code changes"
echo "    make logs      # tail logs"
echo "    make status    # service health"
echo ""
echo "  Instance check (bp instance check --target vm --env-file $APP_DIR/.env): ${CHECK_STATUS:-not run}"
if [ -n "${CHECK_LINES:-}" ]; then
  printf '%s\n' "$CHECK_LINES" | sed 's/^/    /'
fi
echo "  Run it again with: sudo bp instance check --target vm --env-file $APP_DIR/.env"
echo ""
echo "  Update (a post-merge hook rebuilds and restarts):"
echo "    sudo git -C $APP_DIR pull"
echo "    See https://github.com/FRIKKern/barkpark/blob/main/docs/setup/SELF-HOST-UPDATES.md#update-and-roll-back-a-single-vm"
echo ""

# The exit code descends from the measurement too. The failure path still
# prints where the admin token is saved first, and only then refuses. A deploy
# that leaves the API dead is a failed deploy; `bash -s < deploy.sh` in a
# provisioning script must be able to see that.
if [ "$HEALTHY" != "1" ]; then
  echo "  Deploy FAILED: the API is not answering on port $APP_PORT (see diagnostics above)." >&2
  exit 1
fi

# ── End of body ──────────────────────────────────────────────────────────────
exit 0
}
