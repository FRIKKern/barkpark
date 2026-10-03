#!/usr/bin/env bash
# azure-base-install.sh — the from-scratch base install for a fresh AZURE box
# (charter S14 / Decision 41). Hetzner boxes boot the baked warm-image snapshot, so
# their tooling is already on disk; Azure has NO snapshot substrate, so a cold create
# (a launch OR a resurrect restoring a portable bundle) must build the whole runtime
# up from a bare Ubuntu image before Barkpark can run. This is the extraction of that
# build-up from bake-server-image.sh / instance-deploy.sh into one idempotent script
# the provisioner's `freshen` step runs on the box (cloud.AzureBaseInstallScript).
#
# What it installs, all idempotent (safe to re-run):
#   1. apt: PostgreSQL, Caddy, and the build toolchain (git, build-essential,
#      autoconf, the Erlang/OpenSSL headers, unzip, curl).
#   2. asdf + Erlang/Elixir pinned to the repo-root .tool-versions.
#   3. Go, pinned to the go.mod toolchain, under /usr/local/go.
#   4. The repo, cloned to /opt/barkpark (or fast-forwarded if already there).
#   5. A production build (mix deps.get + deps.compile --force + compile) so the box
#      is one `systemctl start` (or, for a resurrect, one pg_restore) away from live.
#
# It does NOT create a database, install secrets, or start a service — those are the
# configure/content steps the provisioner owns (a resurrect installs the bundle's
# sealed identity + restores the dump; a launch seeds an empty DB). This script only
# makes the box RUNNABLE.
#
# Env (all optional — sane defaults):
#   BARKPARK_REPO        git remote            (default https://github.com/FRIKKern/barkpark)
#   BARKPARK_APP         checkout dir          (default /opt/barkpark)
#   BARKPARK_REF         branch/tag to build   (default main)
#   ERLANG_VERSION / ELIXIR_VERSION / GO_VERSION override the pins below.
set -euo pipefail

REPO="${BARKPARK_REPO:-https://github.com/FRIKKern/barkpark}"
APP="${BARKPARK_APP:-/opt/barkpark}"
REF="${BARKPARK_REF:-main}"
# Pins mirror the repo-root .tool-versions + go.mod; override only for a deliberate bump.
ERLANG_VERSION="${ERLANG_VERSION:-27.3.4}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4-otp-27}"
GO_VERSION="${GO_VERSION:-1.26.8}"
ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"

log() { echo "[azure-base-install] $*"; }

# One base-install at a time on a box — a slow apt/compile must not overlap a retry.
exec 9>/var/lock/barkpark-azure-base-install.lock
flock -n 9 || { log "another base install is running; exiting"; exit 0; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    log "FATAL: run as root (the provisioner runs it over ssh as root on a fresh box)"
    exit 1
  fi
}
require_root

# ── 1. apt: postgres + caddy + build toolchain ───────────────────────────────
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

install_apt() {
  log "apt: base packages (postgres, caddy prereqs, build toolchain)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    git curl unzip build-essential autoconf m4 \
    libssl-dev libncurses5-dev libncursesw5-dev \
    postgresql postgresql-contrib \
    debian-keyring debian-archive-keyring apt-transport-https ca-certificates
  systemctl enable --now postgresql >/dev/null 2>&1 || log "WARN: could not enable postgresql (already running?)"

  # Caddy from its official apt repo (idempotent — skip if the binary is present).
  if ! command -v caddy >/dev/null 2>&1; then
    log "apt: installing Caddy (official apt repo, else the pinned verified release .deb)"
    install_caddy_pkg || { log "FATAL: Caddy install failed"; exit 1; }
  else
    log "caddy already installed — skipping"
  fi
}

# ── 2. asdf + Erlang/Elixir pinned to the repo-root .tool-versions ───────────
install_asdf_beam() {
  if [ ! -d "$ASDF_DIR" ]; then
    log "cloning asdf → $ASDF_DIR"
    git clone --depth 1 https://github.com/asdf-vm/asdf.git "$ASDF_DIR"
  else
    log "asdf already present at $ASDF_DIR"
  fi
  # shellcheck disable=SC1091
  export PATH="$ASDF_DIR/shims:$ASDF_DIR/bin:$PATH"
  . "$ASDF_DIR/asdf.sh" 2>/dev/null || true

  asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git 2>/dev/null || true
  asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git 2>/dev/null || true

  # Kerl build flags: a headless prod box needs no wxWidgets/observer/debugger.
  export KERL_CONFIGURE_OPTIONS="--disable-debug --without-javac --without-wx --without-observer --without-debugger --without-et"
  if ! asdf list erlang 2>/dev/null | grep -q "$ERLANG_VERSION"; then
    log "building Erlang $ERLANG_VERSION (this is the slow step on a cold box)"
    asdf install erlang "$ERLANG_VERSION"
  else
    log "Erlang $ERLANG_VERSION already installed"
  fi
  if ! asdf list elixir 2>/dev/null | grep -q "$ELIXIR_VERSION"; then
    log "installing Elixir $ELIXIR_VERSION"
    asdf install elixir "$ELIXIR_VERSION"
  else
    log "Elixir $ELIXIR_VERSION already installed"
  fi
  asdf global erlang "$ERLANG_VERSION"
  asdf global elixir "$ELIXIR_VERSION"
  # Hex/Rebar for the mix build.
  yes | mix local.hex --force >/dev/null 2>&1 || true
  yes | mix local.rebar --force >/dev/null 2>&1 || true
}

# ── 3. Go, pinned, under /usr/local/go ───────────────────────────────────────
install_go() {
  if command -v /usr/local/go/bin/go >/dev/null 2>&1 && \
     /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
    log "Go $GO_VERSION already installed"
    return 0
  fi
  local arch tarball
  case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) log "FATAL: unsupported arch $(uname -m)"; exit 2 ;;
  esac
  tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  log "installing Go $GO_VERSION ($arch)"
  curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"
  export PATH="/usr/local/go/bin:$PATH"
}

# ── 4. Clone (or fast-forward) the repo ──────────────────────────────────────
# This runs unattended on a fresh box with no tty. Without GIT_TERMINAL_PROMPT=0
# a git that decides it needs a username BLOCKS on the prompt; and the clone
# fallback below sends its first attempt to /dev/null, so the real diagnosis was
# discarded before anyone could read it. git_net_die names the git version,
# because "could not read Username" is the symptom BOTH of a credential problem
# and of the protocol-v2 refusal observed on git 2.34.x boxes (the apt git on
# Ubuntu 22.04) — see deploy/cp-deploy.sh and PR #15634.
export GIT_TERMINAL_PROMPT=0
git_net_die() {
  log "FATAL: git network operation failed: $*"
  log "  git version      : $(git --version 2>&1)"
  log "  protocol.version : $(git config --get protocol.version 2>/dev/null || echo 'unset/default')"
  log "  A 'could not read Username' here can be the WIRE protocol, not credentials."
  log "  Retry the same command with: git -c protocol.version=0 ..."
  exit 11
}

fetch_repo() {
  if [ -d "$APP/.git" ]; then
    log "repo present at $APP — fetching $REF"
    git -C "$APP" fetch --depth 1 origin "$REF" \
      || git_net_die "fetch --depth 1 origin $REF in $APP"
    git -C "$APP" checkout -q "$REF"
    git -C "$APP" reset --hard "origin/$REF" 2>/dev/null || git -C "$APP" reset --hard "$REF"
  else
    log "cloning $REPO → $APP (ref $REF)"
    mkdir -p "$(dirname "$APP")"
    git clone --depth 1 --branch "$REF" "$REPO" "$APP" 2>/dev/null \
      || git clone --depth 1 "$REPO" "$APP" \
      || git_net_die "clone --depth 1 $REPO (branch $REF, then default branch)"
  fi
}

# ── 5. Production build so the box is one start (or pg_restore) from live ─────
build_app() {
  # shellcheck disable=SC1091
  export PATH="$ASDF_DIR/shims:$ASDF_DIR/bin:/usr/local/go/bin:$PATH"
  . "$ASDF_DIR/asdf.sh" 2>/dev/null || true
  cd "$APP/api" || { log "FATAL: no $APP/api after clone"; exit 3; }
  log "mix deps.get / deps.compile --force / compile (MIX_ENV=prod)"
  MIX_ENV=prod mix deps.get
  MIX_ENV=prod mix deps.compile --force
  MIX_ENV=prod mix compile
  log "base install complete — box is runnable (start the service, or restore a bundle)"
}

install_apt
install_asdf_beam
install_go
fetch_repo
build_app
