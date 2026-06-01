#!/usr/bin/env bash
#
# Barkpark + Indx — one-command installer (SCAFFOLD)
# =================================================================
#
# Open-source, native-default, provided AS-IS with NO WARRANTY.
#
# This is a THIN ORCHESTRATOR. It does NOT reimplement the heavy
# provisioning in deploy.sh (Erlang/Elixir/Go/PostgreSQL/systemd) —
# it DELEGATES to it. Its own job is the glue deploy.sh leaves out:
#
#   1. The two secrets deploy.sh never writes, which the Phoenix
#      runtime RAISES on in :prod (verified against
#      api/config/runtime.exs):
#        - BARKPARK_CLOAK_KEY      (runtime.exs:27 → raise if unset)
#        - PREVIEW_JWT_SECRET      (runtime.exs:250 → raise if unset)
#      Without these a fresh deploy.sh box boot-crashes. We generate
#      them here, write-only-if-missing, independent of each other and
#      of SECRET_KEY_BASE.
#      We DO NOT generate MEDIA_SIGNING_SECRET — runtime.exs:79-92
#      auto-derives it from SECRET_KEY_BASE.
#
#   2. The optional Indx engine. Indx is FETCHED from NuGet under the
#      operator's accepted free Bionic license at build time — it is
#      NEVER bundled in this repo. Installing it requires accepting that
#      license (see INDX_ACCEPT_LICENSE / indx_license_gate).
#
#   3. Caddy reverse proxy in front of Phoenix (:4000) and Indx (:5001).
#
# Steps that can only run on the target box (apt, systemd, caddy
# reload, dotnet publish, live curl health checks) are marked
# "# server-pending" and are intentionally NOT executed in a way that
# can fake success off-box. The verifiable-now logic (arg parsing,
# secret generation into .env, Caddyfile rendering, the dry-run plan)
# is complete and `bash -n` clean.
#
# Docker remains an OPTIONAL path — see docker_note().
#
set -euo pipefail

# ── exit codes ───────────────────────────────────────────────────
#   1  generic failure (default)
#   2  not root
#   3  Indx license declined / non-interactive license gate
trap 'rollback $?' ERR

# ── logging ──────────────────────────────────────────────────────
log()  { printf '>> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# die [code] message...   (default code 1)
die() {
  local code=1
  case "$1" in
    ''|*[!0-9]*) : ;;          # first arg not numeric → keep default
    *) code="$1"; shift ;;
  esac
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

rollback() {
  local rc="$1"
  [ "$rc" -eq 0 ] && return 0
  warn "install aborted (exit $rc)."
  if [ -n "${ENV_BACKUP:-}" ] && [ -f "$ENV_BACKUP" ]; then
    warn "a backup of the prior .env is at $ENV_BACKUP — secrets were not lost."
  fi
}

# ── globals ──────────────────────────────────────────────────────
# REPO_ROOT = parent of this scripts/ dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="/opt/barkpark"
INDX_DIR="/opt/indx"
ENV_FILE="$APP_DIR/.env"
ENV_BACKUP=""

# ── arg / env parsing ────────────────────────────────────────────
parse_args_and_env() {
  DOMAIN="${DOMAIN:-}"
  PHX_SCHEME="${PHX_SCHEME:-https}"
  BARKPARK_INSTALL_MODE="${BARKPARK_INSTALL_MODE:-native}"
  WITH_INDX="${WITH_INDX:-1}"
  INDX_ACCEPT_LICENSE="${INDX_ACCEPT_LICENSE:-0}"
  ADMIN_EMAIL="${ADMIN_EMAIL:-}"
  DRY_RUN="${DRY_RUN:-0}"
  ACTION="install"

  while [ $# -gt 0 ]; do
    case "$1" in
      --native)    BARKPARK_INSTALL_MODE="native" ;;
      --docker)    BARKPARK_INSTALL_MODE="docker" ;;
      --dry-run)   DRY_RUN=1 ;;
      --uninstall) ACTION="uninstall" ;;
      --reset)     ACTION="reset" ;;
      --no-indx)   WITH_INDX=0 ;;
      --domain=*)  DOMAIN="${1#--domain=}" ;;
      --domain)    shift; DOMAIN="${1:-}" ;;
      *) die "unknown argument: $1 (try --native|--docker|--dry-run|--uninstall|--reset|--no-indx|--domain=HOST)" ;;
    esac
    shift
  done
}

# ── preflight ────────────────────────────────────────────────────
preflight() {
  log "preflight checks..."

  # root
  [ "$(id -u)" -eq 0 ] || die 2 "must run as root (got uid $(id -u))."

  # arch gate
  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) die "unsupported arch: $(uname -m) (need x86_64 or aarch64/arm64)." ;;
  esac

  # RAM — warn only
  if command -v free >/dev/null 2>&1; then
    local mb
    mb="$(free -m | awk '/^Mem:/ {print $2}')"
    if [ -n "$mb" ] && [ "$mb" -lt 2048 ]; then
      warn "only ${mb}MB RAM detected (<2048MB). Erlang build + BEAM may struggle; add swap."
    fi
  else
    warn "'free' not found — skipping RAM check."
  fi

  # disk gate — need >=20G free on /
  if command -v df >/dev/null 2>&1; then
    local gb
    gb="$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
    if [ -n "$gb" ] && [ "$gb" -lt 20 ]; then
      die "only ${gb}G free on / (need >=20G)."
    fi
  else
    warn "'df' not found — skipping disk check."
  fi

  # port gate — 80/443/4000 should be free. Indx on 5001 is loopback-only,
  # never exposed, so it is intentionally NOT preflighted here.
  if command -v ss >/dev/null 2>&1; then
    local p
    for p in 80 443 4000; do
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$"; then
        warn "port ${p} already in use — install may collide."
      fi
    done
  else
    warn "'ss' not found — skipping port check."
  fi
}

# ── policy gates ─────────────────────────────────────────────────
policy_gates() {
  log "policy gates..."

  [ -n "$DOMAIN" ] || die "DOMAIN is required (set DOMAIN=host or pass --domain=host)."

  # Reject a literal IPv4 DOMAIN unless the operator explicitly chose http.
  # Mirrors runtime.exs:208 — https + IP host = 403 on /live/websocket.
  if printf '%s' "$DOMAIN" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    if [ "$PHX_SCHEME" != "http" ]; then
      die "DOMAIN '$DOMAIN' is a literal IPv4 but PHX_SCHEME=$PHX_SCHEME. Use a DNS hostname, or set PHX_SCHEME=http for an IP-only dev box."
    fi
  fi

  # An ACME-issued cert needs a contact email; require it for https.
  if [ "$PHX_SCHEME" = "https" ] && [ -z "$ADMIN_EMAIL" ]; then
    die "ADMIN_EMAIL is required when PHX_SCHEME=https (Caddy/ACME needs a contact address)."
  fi

  indx_license_gate
}

# Indx is fetched from NuGet under the operator's accepted free Bionic
# license; it is never bundled. The operator must accept that license.
indx_license_gate() {
  [ "$WITH_INDX" = "1" ] || return 0
  [ "$INDX_ACCEPT_LICENSE" = "1" ] && { record_indx_consent; return 0; }

  local url="https://indx.co/license"
  if [ -t 0 ]; then
    printf 'Indx engine is fetched from NuGet under its free Bionic license:\n  %s\n' "$url"
    printf 'Accept the license and install Indx? [y/N] '
    local ans
    read -r ans
    case "$ans" in
      y|Y|yes|YES) record_indx_consent ;;
      *) die 3 "Indx license declined. Re-run with --no-indx to skip Indx, or INDX_ACCEPT_LICENSE=1 to accept non-interactively." ;;
    esac
  else
    printf 'Indx requires accepting the free Bionic license (non-interactive run):\n  %s\n' "$url" >&2
    printf 'Re-run with INDX_ACCEPT_LICENSE=1 to accept, or --no-indx to skip Indx.\n' >&2
    exit 3
  fi
}

record_indx_consent() {
  # server-pending: writes under /opt/indx, created on the target box.
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would record Indx license consent at $INDX_DIR/.license-consent"
    return 0
  fi
  mkdir -p "$INDX_DIR"
  printf 'accepted-at=%s\nlicense=https://indx.co/license\nby=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ADMIN_EMAIL:-unknown}" \
    > "$INDX_DIR/.license-consent"
  log "recorded Indx license consent at $INDX_DIR/.license-consent"
}

# ── secret generation ────────────────────────────────────────────
# Write-only-if-missing. deploy.sh owns DATABASE_URL/SECRET_KEY_BASE/
# PHX_HOST/PHX_SCHEME/PORT/MIX_ENV; we fill the gaps that make the
# Phoenix runtime stop raising. MEDIA_SIGNING_SECRET is intentionally
# NOT written — runtime.exs:79-92 derives it from SECRET_KEY_BASE.
generate_secrets() {
  log "ensuring required secrets in $ENV_FILE..."

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would ensure SECRET_KEY_BASE, PREVIEW_JWT_SECRET, BARKPARK_CLOAK_KEY, Jwt__Key, PHX_HOST, PHX_SCHEME in $ENV_FILE"
    return 0
  fi

  # server-pending: $APP_DIR exists only after deploy.sh clones the repo.
  mkdir -p "$APP_DIR"

  if [ -f "$ENV_FILE" ]; then
    ENV_BACKUP="$ENV_FILE.bak.$(date +%s)"
    cp "$ENV_FILE" "$ENV_BACKUP"
    log "backed up existing .env to $ENV_BACKUP"
  else
    : > "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"

  ensure_env SECRET_KEY_BASE    "$(gen_secret)"
  ensure_env PREVIEW_JWT_SECRET "$(gen_secret)"
  # 32-byte key; SHA256'd into the AES key in runtime.exs. Must be
  # independent of SECRET_KEY_BASE — separate gen call below.
  ensure_env BARKPARK_CLOAK_KEY "$(gen_secret 32)"
  # Indx JWT signing key (consumed by IndxCloudApi). Independent secret.
  ensure_env Jwt__Key           "$(gen_secret)"
  ensure_env PHX_HOST           "$DOMAIN"
  ensure_env PHX_SCHEME         "$PHX_SCHEME"
}

# gen_secret [bytes] — prefer mix phx.gen.secret, fall back to openssl.
gen_secret() {
  local bytes="${1:-}"
  if command -v mix >/dev/null 2>&1; then
    if [ -n "$bytes" ]; then
      mix phx.gen.secret "$bytes" 2>/dev/null && return 0
    else
      mix phx.gen.secret 2>/dev/null && return 0
    fi
  fi
  # openssl fallback. -base64 N emits roughly 4/3·N chars; pick a size
  # comfortably above the requested entropy.
  if [ "${bytes:-}" = "32" ]; then
    openssl rand -base64 32
  else
    openssl rand -base64 48
  fi
}

# ensure_env KEY VALUE — append KEY=VALUE only if KEY is absent.
ensure_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    log "  $key already set — keeping existing value"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    log "  $key written"
  fi
}

# ── dry-run plan ─────────────────────────────────────────────────
dry_run_plan() {
  [ "$DRY_RUN" = "1" ] || return 0
  cat <<PLAN
── DRY RUN — ordered plan (no changes made) ────────────────────────
  domain:        $DOMAIN ($PHX_SCHEME)
  mode:          $BARKPARK_INSTALL_MODE
  with indx:     $WITH_INDX
  admin email:   ${ADMIN_EMAIL:-<none>}

  1. preflight        (root, arch, RAM, disk, ports 80/443/4000)
  2. policy_gates     (DOMAIN, IPv4/https, ADMIN_EMAIL, Indx license)
  3. generate_secrets (SECRET_KEY_BASE, PREVIEW_JWT_SECRET,
                       BARKPARK_CLOAK_KEY, Jwt__Key, PHX_HOST, PHX_SCHEME)
  4. backend:
       native → native_barkpark (delegates to deploy.sh)
                native_indx      (if WITH_INDX=1; server-pending)
       docker → docker_note      (optional path; docker-compose.yml)
  5. install_and_configure_caddy (reverse_proxy :4000 + /indx/* → :5001)
  6. health_gate      (curl $PHX_SCHEME://$DOMAIN/api/schemas[, /indx/*])
  7. what_now_footer
────────────────────────────────────────────────────────────────────
PLAN
  exit 0
}

# ── native backend — Barkpark ────────────────────────────────────
native_barkpark() {
  log "native Barkpark — delegating to deploy.sh..."
  # server-pending: run on the target box. deploy.sh provisions
  # Erlang/Elixir/Go/PostgreSQL/systemd and clones $APP_DIR. We do NOT
  # reimplement any of it. The secrets we wrote above are picked up
  # because deploy.sh keeps an existing .env (deploy.sh:143-148).
  #
  #   DOMAIN="$DOMAIN" PHX_SCHEME="$PHX_SCHEME" bash "$REPO_ROOT/deploy.sh"
  #
  if [ ! -f "$REPO_ROOT/deploy.sh" ]; then
    die "deploy.sh not found at $REPO_ROOT/deploy.sh — cannot delegate."
  fi
  warn "native_barkpark is server-pending: invoke deploy.sh on the target box (see commented line above)."
}

# ── native backend — Indx ────────────────────────────────────────
native_indx() {
  [ "$WITH_INDX" = "1" ] || { log "Indx skipped (WITH_INDX=0)."; return 0; }
  log "native Indx..."
  install_indx_payload
}

# STUB. The real payload install is documented and runs only on-box.
install_indx_payload() {
  # server-pending — see docs guide 2026-06-01-dotnet-hetzner-setup-guide.
  # The documented on-box steps, NOT executed here:
  #   1. Install .NET 9 SDK/runtime:
  #        add-apt-repository ppa:dotnet/backports && apt-get install -y dotnet-sdk-9.0
  #   2. Clone the Indx source, strip non-engine assets, then publish the
  #      IndxCloudApi project FRAMEWORK-DEPENDENT (NuGet restore pulls the
  #      Indx engine under the operator-accepted free Bionic license):
  #        dotnet publish IndxCloudApi -c Release --no-self-contained \
  #          -o /opt/indx/app
  #   3. Write a hardened systemd unit indx.service that binds loopback
  #      only (ASPNETCORE_URLS=http://127.0.0.1:5001), runs as a non-root
  #      service user, NoNewPrivileges=yes, ProtectSystem=strict,
  #      EnvironmentFile=/opt/indx/.env (carries Jwt__Key).
  # TODO(server-pending): implement on the box per the guide above. This
  # stub does NOT fake completion.
  warn "install_indx_payload is a server-pending STUB — see 2026-06-01-dotnet-hetzner-setup-guide. Indx not actually installed."
}

# ── Caddy ────────────────────────────────────────────────────────
install_and_configure_caddy() {
  log "Caddy reverse proxy..."

  local caddyfile="/etc/caddy/Caddyfile"
  local indx_block=""
  if [ "$WITH_INDX" = "1" ]; then
    indx_block=$'\n    handle_path /indx/* {\n        reverse_proxy 127.0.0.1:5001\n    }'
  fi

  # Render the Caddyfile content (verifiable-now). For an http-only
  # IP dev box we prefix the address with http:// so Caddy does not
  # attempt ACME against a bare IP.
  local site_addr="$DOMAIN"
  [ "$PHX_SCHEME" = "http" ] && site_addr="http://$DOMAIN"

  local rendered
  rendered="$(cat <<CADDY
${site_addr} {
    encode gzip
    reverse_proxy 127.0.0.1:4000 {
        header_up X-Forwarded-Proto ${PHX_SCHEME}
    }${indx_block}
}
CADDY
)"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would write $caddyfile:"
    printf '%s\n' "$rendered"
    return 0
  fi

  # server-pending: writing /etc/caddy, validate + reload run on-box.
  mkdir -p /etc/caddy
  printf '%s\n' "$rendered" > "$caddyfile"
  log "wrote $caddyfile"

  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$caddyfile" || die "Caddyfile validation failed."
    systemctl reload caddy 2>/dev/null || warn "could not reload caddy (server-pending: start/enable caddy on-box)."
  else
    warn "caddy binary not found — install Caddy on the target box, then 'caddy validate' + 'systemctl reload caddy' (server-pending)."
  fi
}

# ── health gate ──────────────────────────────────────────────────
health_gate() {
  log "health gate..."
  local base="$PHX_SCHEME://$DOMAIN"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would curl $base/api/schemas" \
      "$([ "$WITH_INDX" = "1" ] && printf 'and %s/indx/*' "$base")"
    return 0
  fi

  # server-pending: real HTTP only succeeds once the box is up.
  curl -fsS "$base/api/schemas" >/dev/null \
    || die "health check failed: $base/api/schemas did not return 2xx."
  log "  Barkpark API healthy"

  if [ "$WITH_INDX" = "1" ]; then
    curl -fsS "$base/indx/" >/dev/null \
      || die "health check failed: $base/indx/ did not return 2xx."
    log "  Indx healthy"
  fi
}

# ── docker (optional path) ───────────────────────────────────────
docker_note() {
  cat <<DOCKER
Docker is the OPTIONAL install path. This installer's native default is
recommended (no container overhead). For the Docker path, use the
existing compose file — it is NOT reimplemented here:

    docker compose -f "$REPO_ROOT/docker-compose.yml" up -d

You must still supply the secrets this installer would otherwise write
(SECRET_KEY_BASE, PREVIEW_JWT_SECRET, BARKPARK_CLOAK_KEY) via the
compose env — runtime.exs raises in :prod without them.
DOCKER
}

# ── footer ───────────────────────────────────────────────────────
what_now_footer() {
  local base="$PHX_SCHEME://$DOMAIN"
  cat <<FOOTER

============================================
  Barkpark${WITH_INDX:+ + Indx} install complete
============================================

  Studio:   $base/studio
  API:      curl $base/v1/data/query/production/post

  Back up your secrets — they are NOT in git:
      cp $ENV_FILE ~/barkpark-env.backup
  (this installer also keeps timestamped .env.bak.* on every run)

  Upgrade later:
      cd $APP_DIR && git pull && make rebuild

FOOTER
}

# ── main ─────────────────────────────────────────────────────────
main() {
  parse_args_and_env "$@"

  case "$ACTION" in
    uninstall)
      warn "uninstall is server-pending: stop+disable barkpark.service / indx.service, remove $APP_DIR, $INDX_DIR, /etc/caddy/Caddyfile, drop the DB. Not automated in this scaffold."
      exit 0
      ;;
    reset)
      warn "reset is server-pending: re-run with a fresh .env and 'make reset-db'. Not automated in this scaffold."
      exit 0
      ;;
  esac

  preflight
  policy_gates
  generate_secrets
  dry_run_plan          # exits 0 when DRY_RUN=1

  case "$BARKPARK_INSTALL_MODE" in
    native)
      native_barkpark
      native_indx
      ;;
    docker)
      docker_note
      ;;
    *)
      die "unknown BARKPARK_INSTALL_MODE: $BARKPARK_INSTALL_MODE (native|docker)."
      ;;
  esac

  install_and_configure_caddy
  health_gate
  what_now_footer
}

main "$@"
