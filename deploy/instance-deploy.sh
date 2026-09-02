#!/usr/bin/env bash
# Refresh a Barkpark CONTENT instance (e.g. guerrilla) to origin/main.
#
# Run on the box as root (the CD workflow scps this script + executes it).
# Idempotent, ASDF-aware, SERIALIZED (flock), ZERO-DOWNTIME blue/green.
#
# Blue/green (extends the 2026-07-01 build-aside fix): the app runs as systemd
# template units barkpark-slot@{blue,green} out of per-slot build roots of the
# SAME checkout (blue = api/_build_blue on :4000, green = api/_build_green on
# :4001); host Caddy proxies the public hostname to the active slot's port. A
# deploy clean-builds the IDLE slot's root (MIX_BUILD_ROOT) while the active
# slot keeps serving its own untouched root, migrates, boots the idle slot,
# health-gates it, then flips Caddy's upstream (graceful reload — no dropped
# connections) and retires the old slot. An unhealthy new slot is simply
# stopped again — the active slot is never touched, so a bad deploy costs no
# downtime. Consequence: migrations must be backward-compatible
# (expand/contract) for the minute both slots overlap.
#
# TWO CHANNELS, ONE SCRIPT — the git step is channel-gated on a $APP/.staging
# marker (fail-closed: absent => production channel):
#   * production (no .staging): `fetch origin main` then `reset --hard
#     FETCH_HEAD`, LOCKED to origin/main. A non-main DEPLOY_REF or non-origin
#     DEPLOY_REMOTE is REFUSED (exit 11) BEFORE the git step — a prod content box
#     can never be pushed to a branch, a PR, or a foreign remote. A content box
#     is a MIRROR of origin/main, never a source of truth, so it hard-resets
#     (converging even from a DIVERGENT HEAD — a stray commit made on the box, or
#     main rewritten under it) rather than `pull --ff-only`, which ABORTS on
#     divergence and silently jams the box off the deploy train. Divergence is
#     logged, not swallowed. The hard reset also discards committed build
#     artifacts (go.sum/bin churn), subsuming the old `git checkout -- .`.
#   * staging (.staging present): deploy ANY ref — DEPLOY_REF (default main),
#     DEPLOY_REMOTE (default origin) — via `fetch $DEPLOY_REMOTE $DEPLOY_REF`
#     then `reset --hard FETCH_HEAD`. This is the pre-merge proving path: try a
#     branch or a PR (DEPLOY_REF=pull/<n>/head) BEFORE it rides the auto-deploy
#     merge train.
# EVERY git path suppresses the repo's post-merge hook (core.hooksPath=.githooks
# on the box): that hook nukes the live _build and restarts the legacy `barkpark`
# unit — exactly the outage this script exists to prevent.
#
# ROLLBACK MODES (W6) — the same script owns the reverse flip:
#   --rollback-preflight  read-only: is a rollback possible right now? Typed
#                         exits (21 no_previous_slot, 22 not_supported, 23 lock
#                         held); exit 0 prints TARGET_SLOT=/TARGET_SHA= lines
#                         (machine-parsed by the instance controller).
#   --rollback            flip+reset to the IDLE slot at its RECORDED sha
#                         (.slots/<slot>.sha): git reset --hard <stamp>, reboot
#                         the slot, health-gate it on its OWN port, flip Caddy
#                         only on green, rewrite deploy STATE. Unhealthy = fail
#                         closed (slot re-disabled, Caddy untouched, checkout
#                         reset back, exit 24).
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-instance-deploy.lock}"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
HEALTH_HOST="${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}"
BLUE_PORT="${BARKPARK_PORT_BLUE:-4000}"
GREEN_PORT="${BARKPARK_PORT_GREEN:-4001}"
# Remote MCP endpoint (viable-everywhere D19). MUST stay outside the blue/green
# slot ports: the port-flip sed rewrites localhost:<slot> globally on every
# deploy, and the ACTIVE_PORT greps match slot ports exactly.
MCP_PORT="${BARKPARK_PORT_MCP:-4010}"
MCP_ENV_FILE="${BARKPARK_MCP_ENV_FILE:-/etc/barkpark/mcp.env}"
# Connectors bridge (connectors charter D34/D46) — the persistent Node process
# behind the /connectors PATH route. Same rule as :4010: OUTSIDE the slot ports.
CONNECTORS_PORT="${BARKPARK_PORT_CONNECTORS:-4020}"
CONNECTORS_PATH_PREFIX="${BARKPARK_CONNECTORS_PATH_PREFIX:-/connectors}"
CONNECTORS_ENV_FILE="${BARKPARK_CONNECTORS_ENV_FILE:-/etc/barkpark/connectors.env}"
# Stable node path the committed unit's ExecStart points at (systemd cannot
# expand a variable in the executable position, and asdf's node lives under a
# versioned dir). The deploy symlinks this at the resolved node.
NODE_LINK="${BARKPARK_NODE_LINK:-/usr/local/bin/barkpark-node}"
# Where the deploy installs the Cloud sandbox runner (connectors charter D265).
# ClaudeChat resolves the BARE name "cloud-sandbox-runner" off the live BEAM PATH
# (/usr/local/bin is on it, /proc-proven), so the WRAPPER basename must be exactly
# that and :sandbox_runner config stays UNSET. Overridable ONLY so the offline
# harness can redirect both writes into its temp dir — production keeps the
# absolute /usr/local/bin paths the wrapper CONTENT hardcodes.
SANDBOX_RUNNER_BIN="${BARKPARK_SANDBOX_RUNNER_BIN:-/usr/local/bin/cloud-sandbox-runner}"
SANDBOX_RUNNER_MJS="${BARKPARK_SANDBOX_RUNNER_MJS:-/usr/local/bin/cloud-sandbox-runner.mjs}"
log() { echo "[instance-deploy $(date -u +%H:%M:%S)] $*"; }

# ---- ONE shared Caddyfile lock (site-spawner D27) --------------------------
# $CADDYFILE has a SECOND writer: deploy/site-deploy.sh arms a `handle_path
# /sites/<slug>/*` block into the same file. Both scripts do read -> backup ->
# rewrite -> mv, and an interleave silently DISCARDS one of them. A lost update
# is syntactically VALID, so the backup + `caddy validate` + revert discipline
# both scripts already have is structurally BLIND to it. Reproduced: site-deploy's
# losing write dropped this script's blue/green port flip and then reloaded Caddy
# onto the slot we were about to `systemctl disable --now` — a hard 502 on the
# content API that does not self-heal until the next deploy.
#
# So EVERY Caddyfile read-modify-write in this script (three route armings + two
# flip regions) runs under this leaf lock on fd 8, and site-deploy.sh takes the
# SAME lock around its whole arming function. Acquire order is identical in both
# (own lock fd 9 -> caddy lock fd 8) and the caddy lock is a leaf neither holds
# while waiting on the other's, so they cannot deadlock. It is deliberately NOT
# this script's own lock (fd 9): that one is held for the whole multi-minute run
# and would stall a site deploy for ten minutes.
CADDY_LOCK="${BARKPARK_CADDYFILE_LOCK:-/var/lock/barkpark-caddyfile.lock}"
if ! ( : > "$CADDY_LOCK" ) 2>/dev/null; then
  # Unwritable /var/lock (dev box, unprivileged CI) — still serialize, in TMPDIR.
  CADDY_LOCK="${TMPDIR:-/tmp}/barkpark-caddyfile.lock"
  # LOUD, because the failure mode is silent: the two writers only exclude each
  # other if they resolve the SAME path. Both run as root on the box and both get
  # /var/lock; if one falls back and the other does not, they serialize against
  # nothing. Pin BARKPARK_CADDYFILE_LOCK identically on both.
  log "WARN: /var/lock is not writable — Caddyfile lock falls back to $CADDY_LOCK; site-deploy.sh MUST resolve the same path (set BARKPARK_CADDYFILE_LOCK) or the two Caddyfile writers do not serialize"
fi
with_caddy_lock() { # <fn> [args…] — run a whole Caddyfile read-modify-write serialized
  exec 8>"$CADDY_LOCK" || { log "cannot open the Caddyfile lock $CADDY_LOCK — leaving Caddy untouched"; return 1; }
  if ! flock -w 120 8; then
    log "gave up waiting for the Caddyfile lock ($CADDY_LOCK) — leaving Caddy untouched"
    exec 8>&-
    return 1
  fi
  "$@"
  local rc=$?
  exec 8>&-
  return "$rc"
}

MODE=deploy
case "${1:-}" in
  --rollback)           MODE=rollback ;;
  --rollback-preflight) MODE=preflight ;;
  "") ;;
  *) log "unknown flag '${1}' (supported: --rollback, --rollback-preflight)"; exit 2 ;;
esac

# ---- Serialize: overlapping runs (back-to-back merges, manual + CD) queue
# here. Each run pulls AFTER taking the lock, so a queued run deploys the
# latest HEAD; if its commits were already shipped by the run ahead of it,
# the coalesce check below turns it into a no-op. Rollback modes NEVER queue:
# racing a deploy would flip to a slot mid-rebuild, so a held lock is a typed
# refusal (23 = already_running) the caller surfaces honestly.
exec 9>"$LOCK"
if ! flock -n 9; then
  if [ "$MODE" != "deploy" ]; then
    log "deploy lock held — refusing to $MODE while a deploy runs (already_running)"
    exit 23
  fi
  log "another deploy holds the lock — queueing (max 30 min)"
  flock -w 1800 9 || { log "gave up waiting for the deploy lock"; exit 15; }
fi

export PATH="$HOME/.asdf/shims:/usr/local/go/bin:$PATH"
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

cd "$APP" || { log "no $APP"; exit 10; }
STATE="$APP/.instance-deploy-last"   # commit of the last HEALTHY deploy
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

# ---- Rollback modes (W6). Flip+reset, never flip-only: both slots share ONE
# checkout, so a bare Caddy flip + slot restart would `mix phx.server`-recompile
# NEW source into the old slot's stale build root (proven by the mix-staleness
# probe). `git reset --hard <stamp>` — this script's own failure-path idiom —
# restores the old code byte-identically. Schema stays FORWARD: rolling back
# code does NOT undo the schema; write a compensating migration (PROD_OPS law).
# The health gate proves boot + a shallow endpoint, NOT schema compatibility.
if [ "$MODE" != "deploy" ]; then
  # Preflight checks (shared by both modes; --rollback-preflight is read-only).
  if [ ! -d "$APP/.slots" ]; then
    log "no $APP/.slots — this box predates per-slot stamps (not_supported)"
    exit 22
  fi
  # Slot ports ONLY (never 40[0-9]{2}): the Caddyfile also carries the /mcp
  # route's localhost:4010 and the /connectors route's localhost:4020, which a
  # loose grep + head -1 would misread as the active slot.
  ACTIVE_PORT="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" 2>/dev/null | head -1 | cut -d: -f2)"
  ACTIVE_PORT="${ACTIVE_PORT:-$BLUE_PORT}"
  if [ "$ACTIVE_PORT" = "$BLUE_PORT" ]; then
    LIVE=blue; TARGET_SLOT=green; TARGET_PORT="$GREEN_PORT"
  else
    LIVE=green; TARGET_SLOT=blue; TARGET_PORT="$BLUE_PORT"
  fi
  TARGET_SHA="$(cat "$APP/.slots/$TARGET_SLOT.sha" 2>/dev/null || true)"
  if [ -z "$TARGET_SHA" ]; then
    log "idle slot '$TARGET_SLOT' has no recorded sha (.slots/$TARGET_SLOT.sha) — no_previous_slot"
    exit 21
  fi
  if [ ! -d "$APP/api/_build_$TARGET_SLOT/prod" ]; then
    log "idle slot '$TARGET_SLOT' has no complete build root (api/_build_$TARGET_SLOT/prod) — no_previous_slot"
    exit 21
  fi
  if [ "$MODE" = "preflight" ]; then
    log "rollback possible: would flip :$ACTIVE_PORT ($LIVE) -> :$TARGET_PORT ($TARGET_SLOT) at $TARGET_SHA"
    echo "TARGET_SLOT=$TARGET_SLOT"
    echo "TARGET_SHA=$TARGET_SHA"
    exit 0
  fi

  # --rollback: mutate. $OLD (the live checkout's HEAD) is what every failure
  # path resets back to, keeping sources in step with the still-serving slot.
  log "ROLLBACK: flip :$ACTIVE_PORT ($LIVE) -> :$TARGET_PORT ($TARGET_SLOT) at $TARGET_SHA"
  if ! git reset --hard "$TARGET_SHA"; then
    log "git reset --hard $TARGET_SHA failed — checkout unchanged, Caddy untouched, no flip"
    exit 24
  fi

  # Rebuild the pdrender wasm at the OLD sha (same non-fatal contract as the
  # forward path: a failed build only degrades the reader's TUI view to its
  # fallback). priv/static is ONE shared dir, so this is healing, not snapshot.
  log "building pdrender wasm at rolled-back sha (non-fatal)"
  if command -v go >/dev/null 2>&1; then
    if make wasm; then log "pdrender wasm built"; else log "WARN: pdrender wasm build failed — reader TUI view degrades to its fallback"; fi
  else
    log "go not found — skipping pdrender wasm build"
  fi

  log "boot barkpark-slot@$TARGET_SLOT on :$TARGET_PORT"
  systemctl restart "barkpark-slot@$TARGET_SLOT"
  ok=0
  for _ in $(seq 1 40); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${TARGET_PORT}/api/schemas" || true)"
    if [ "$code" = "200" ]; then ok=1; log "slot $TARGET_SLOT healthy ($code)"; break; fi
    sleep 5
  done
  if [ "$ok" != "1" ]; then
    log "slot $TARGET_SLOT UNHEALTHY at $TARGET_SHA — fail closed: slot re-disabled, Caddy untouched, checkout back to live sha"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"
    exit 24
  fi

  # Hot swap back (mirrors the forward flip; the post-flip public curl below
  # is LOG-ONLY and must never gate — the pre-flip own-port loop above is the gate).
  # UNDER THE SHARED CADDYFILE LOCK (fd 8, D27): site-deploy.sh rewrites this same
  # file. Bracketed inline rather than wrapped in a function because every failure
  # path below EXITS — and an exit releases fd 8 with the process.
  exec 8>"$CADDY_LOCK"
  if ! flock -w 120 8; then
    log "gave up waiting for the Caddyfile lock ($CADDY_LOCK) — no flip, fail closed"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  # Re-read the live upstream INSIDE the lock: ACTIVE_PORT was read before the
  # slot reboot + health gate, and the flip must rewrite what is in the file NOW
  # (that read was the time-of-check half of the race).
  FLIP_FROM="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" 2>/dev/null | head -1 | cut -d: -f2)"
  FLIP_FROM="${FLIP_FROM:-$ACTIVE_PORT}"
  cp -a "$CADDYFILE" "$CADDYFILE.pre-rollback"
  sed -i "s/localhost:${FLIP_FROM}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
  # Same landed-check as the forward flip, and MORE load-bearing here: this
  # path's post-flip curl is deliberately log-only, so without this a rollback
  # whose sed matched nothing would log "ROLLED BACK", rewrite STATE, exit 0 —
  # and then disable the slot Caddy is still pointing at.
  if grep -q "localhost:${FLIP_FROM}" "$CADDYFILE" || ! grep -q "localhost:${TARGET_PORT}" "$CADDYFILE"; then
    log "FLIP DID NOT LAND: after the rollback rewrite $CADDYFILE still carries :$FLIP_FROM (or never gained :$TARGET_PORT) — restoring, no flip, fail closed"
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
    log "Caddyfile invalid after rollback flip — restoring, fail closed"
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  if ! systemctl reload caddy; then
    log "caddy reload failed during rollback — restoring, fail closed"
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"; systemctl reload caddy || true
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  exec 8>&-   # leaf lock: released the moment the file is written + reloaded
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${HEALTH_HOST}:443:127.0.0.1" "https://${HEALTH_HOST}/api/schemas" || true)"
  log "Caddy now -> :$TARGET_PORT (https://${HEALTH_HOST}/api/schemas = $code)"

  # Drain, retire the rolled-away slot, and rewrite STATE to the rolled-back
  # sha (W6 D21) — keeps coalesce, the agent's git_commit, and the next
  # deploy's OLD baseline truthful. The retired slot's stamp + build root stay:
  # a second --rollback legitimately flips forward again.
  sleep 5
  systemctl enable "barkpark-slot@$TARGET_SLOT" >/dev/null 2>&1 || true
  systemctl disable --now "barkpark-slot@$LIVE" >/dev/null 2>&1 || true
  echo "$TARGET_SHA" > "$STATE"
  log "ROLLED BACK — slot $TARGET_SLOT live at $TARGET_SHA"
  exit 0
fi

# ---- Channel-gated git step (see header). Fail-closed on the $APP/.staging
# marker: absent => production (strict ff-only main, non-main ref REFUSED);
# present => staging (fetch + hard-reset ANY ref, incl. a PR pull/<n>/head).
DEPLOY_REF="${DEPLOY_REF:-main}"
DEPLOY_REMOTE="${DEPLOY_REMOTE:-origin}"
if [ -f "$APP/.staging" ]; then
  log "staging channel: deploying ref '$DEPLOY_REF' from '$DEPLOY_REMOTE' (post-merge hook suppressed)"
  git -c core.hooksPath=/dev/null fetch "$DEPLOY_REMOTE" "$DEPLOY_REF" || { log "fetch $DEPLOY_REMOTE $DEPLOY_REF failed"; exit 11; }
  # Hard reset to the fetched ref — also discards committed build artifacts,
  # subsuming the prod path's `git checkout -- .`.
  git -c core.hooksPath=/dev/null reset --hard FETCH_HEAD || { log "reset --hard FETCH_HEAD failed"; exit 11; }
else
  if [ "$DEPLOY_REF" != "main" ]; then
    log "refusing DEPLOY_REF '$DEPLOY_REF' on a production box (no $APP/.staging marker) — prod only mirrors origin/main"
    exit 11
  fi
  if [ "$DEPLOY_REMOTE" != "origin" ]; then
    log "refusing DEPLOY_REMOTE '$DEPLOY_REMOTE' on a production box (no $APP/.staging marker) — prod only pulls origin; ignoring it silently would deploy the wrong remote"
    exit 11
  fi
  # A content box is a MIRROR of origin/main — never a source of truth. Fetch +
  # hard-reset (the same idiom the staging path uses, origin/main-locked) instead
  # of `pull --ff-only`: a divergent HEAD (a stray commit made directly on the box,
  # or origin/main rewritten under it) makes --ff-only ABORT ("Not possible to
  # fast-forward") → exit 11 → the box silently stops auto-deploying while every
  # run reports "failure". Reset always converges to origin/main; any local commit
  # is drift to discard, and this also subsumes the old `git checkout -- .` for
  # committed build artifacts. Divergence is surfaced (logged), not swallowed.
  log "git fetch origin main + reset --hard (post-merge hook suppressed — this script IS the deploy)"
  git -c core.hooksPath=/dev/null fetch origin main || { log "fetch origin main failed"; exit 11; }
  if ! git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
    log "WARNING: box HEAD $(git rev-parse --short HEAD) has DIVERGED from origin/main (a commit was made on the box, or main was rewritten) — discarding local divergence and converging to origin/main"
  fi
  git -c core.hooksPath=/dev/null reset --hard FETCH_HEAD || { log "reset --hard FETCH_HEAD failed"; exit 11; }
fi
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Coalesce: the run ahead of us already deployed this exact commit healthily.
if [ "$NEW" = "$OLD" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$NEW" ]; then
  log "HEAD $NEW already deployed healthy — nothing to do"
  exit 0
fi

# Backfill the prod-required secret keys if absent (each RAISES at boot).
for v in BARKPARK_KEK BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_RELEASE_CAPTURE_HMAC_SECRET; do
  if ! grep -q "^${v}=" .env 2>/dev/null; then
    echo "${v}=$(openssl rand -base64 32)" >> .env
    log "added missing ${v} to .env"
  fi
done

# This instance is managed by the barkpark.cloud control plane — the pointer
# puts "Log in with Barkpark Cloud" on /login (login-brand-ux). Not a secret.
if ! grep -q '^BARKPARK_CLOUD_URL=' .env 2>/dev/null; then
  echo 'BARKPARK_CLOUD_URL=https://barkpark.cloud' >> .env
  log "added BARKPARK_CLOUD_URL to .env"
fi

# ---- The x-forwarded-for trust boundary (BARKPARK_TRUSTED_PROXIES) ----------
# Barkpark.RateLimiter.client_ip believes x-forwarded-for ONLY from loopback or a
# peer LISTED here, and walks the chain right-to-left skipping listed hops. On a
# cloud-managed box the chain on a proxied revoke is "<phone>, <control plane
# egress>" — so until the control plane's egress address is listed, the rightmost
# non-listed hop IS that egress address and every proxied revoke keys on ONE
# bucket (the whole team shares 10/minute). Not a forgery and not a 5xx: a SILENT
# loss of the per-phone bucketing.
#
# The address is CONFIGURATION, never a literal in this script: it comes from
# $BARKPARK_CLOUD_EGRESS_IPS, which the CD workflow fills from the SAME `CP_HOST`
# secret it SSHes the control plane with (deploy/README.md), and which the
# provisioner reads from its own worker env for freshly-provisioned boxes. One
# authored value, two readers.
#
# NEVER overwrites an existing line: provisioning already wrote the right value on
# a managed box, and a self-hosted operator may legitimately trust a different
# front. Absent value + absent line ⇒ a commented placeholder + a LOUD log, so the
# gap is visible on the box instead of silently costing per-caller buckets.
#
# The shape is VALIDATED before writing, because runtime.exs RAISES on a malformed
# entry — writing an unvalidated value here would not degrade a bucket key, it
# would refuse to boot the app at the slot restart later in this very run.
egress_ips_ok() { # $1=comma-separated candidate; true only if EVERY entry is a bare IP literal
  printf '%s' "$1" | awk -F, '
    function ipv4(s,   p, i) {
      if (s !~ /^[0-9]+(\.[0-9]+){3}$/) return 0
      split(s, p, ".")
      for (i = 1; i <= 4; i++) if (p[i] + 0 > 255) return 0
      return 1
    }
    function ipv6(s) { return (s ~ /^[0-9a-fA-F:]+$/ && s ~ /:/ && s !~ /:::/) }
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        if ($i == "") continue
        if (!ipv4($i) && !ipv6($i)) exit 1
        n++
      }
    }
    END { if (n == 0) exit 1 }
  '
}
if grep -q '^BARKPARK_TRUSTED_PROXIES=' .env 2>/dev/null; then
  log "BARKPARK_TRUSTED_PROXIES already set in .env — left untouched"
elif [ -n "${BARKPARK_CLOUD_EGRESS_IPS:-}" ]; then
  if egress_ips_ok "${BARKPARK_CLOUD_EGRESS_IPS}"; then
    echo "BARKPARK_TRUSTED_PROXIES=${BARKPARK_CLOUD_EGRESS_IPS}" >> .env
    log "added BARKPARK_TRUSTED_PROXIES=${BARKPARK_CLOUD_EGRESS_IPS} to .env (the control plane's relayed caller address is now believed)"
  else
    log "WARN: BARKPARK_CLOUD_EGRESS_IPS='${BARKPARK_CLOUD_EGRESS_IPS}' is not a comma-separated list of bare IP addresses (CIDR ranges are REFUSED — trusting a range lets any host in it forge every client's bucket key) — NOT written; runtime.exs would raise at boot on it"
  fi
else
  # The placeholder is written ONCE (guarded on its own commented marker) — an
  # unguarded append would grow .env by five lines on every single deploy. The WARN
  # fires either way: the gap must stay visible in every deploy log, not only the
  # first one.
  if ! grep -q '^# BARKPARK_TRUSTED_PROXIES=' .env 2>/dev/null; then
    {
      echo '# BARKPARK_TRUSTED_PROXIES: individual IPs of every front whose x-forwarded-for'
      echo '# this box should believe (comma-separated, NO CIDR ranges). On a barkpark.cloud-'
      echo '# managed instance this is the control plane EGRESS address; unset, proxied'
      echo '# requests all share ONE rate-limit bucket per team instead of one per caller.'
      echo '# BARKPARK_TRUSTED_PROXIES=203.0.113.7'
    } >> .env
  fi
  log "WARN: no BARKPARK_CLOUD_EGRESS_IPS in the deploy env and no BARKPARK_TRUSTED_PROXIES in .env — see the commented placeholder in .env; proxied requests will key on ONE bucket per team until an operator fills it in (deploy/README.md)"
fi

# The Connectors bridge ciphers each install's per-workspace credentials with
# this key (the KEK — every row is sealed under an HKDF-derived per-workspace
# subkey, never the KEK directly). It is backfilled ONCE into .env and only
# COPIED into /etc/barkpark/connectors.env on each deploy, so it stays STABLE
# across deploys rather than being regenerated under live installs.
#
# KEY CUSTODY — where it lives, how to rotate, what breaks if lost:
#   · BACKED UP: /opt/barkpark/.env (mode 0600), the box's durable secret store,
#     the SAME mechanism as BARKPARK_KEK above. It is NOT escrowed off-box by
#     this script — an operator who wants disaster recovery must copy this line
#     out of .env to a secret manager. Losing the box loses the key.
#   · ROTATE DELIBERATELY (this is safe, NOT a flag day): put the OLD key in
#     CONNECTORS_CREDENTIAL_KEY_PREVIOUS and a fresh one in
#     CONNECTORS_CREDENTIAL_KEY, deploy, then run `npm run rewrap` in
#     /opt/barkpark/connectors (re-seals every row under the new key). Once it
#     reports raced=0 / no unopenable rows, delete the _PREVIOUS line — the old
#     key is now retired. The cipher opens rows under EITHER key in the meantime,
#     so nothing goes dark during the window. See docs/ops/connectors-deploy.md.
#   · IF THE KEY IS LOST with no _PREVIOUS and no backup: stored blobs can no
#     longer be opened, so every install must be RE-CONNECTED (re-paste the
#     provider token). That is the ONLY thing a lost key breaks — routing rows
#     survive; the secrets they point at do not.
if ! grep -q '^CONNECTORS_CREDENTIAL_KEY=' .env 2>/dev/null; then
  echo "CONNECTORS_CREDENTIAL_KEY=$(openssl rand -base64 32)" >> .env
  log "added CONNECTORS_CREDENTIAL_KEY to .env (connectors bridge credential cipher)"
fi

# The CONNECT seam's shared HMAC secret (connectors D50). BOTH sides read it:
# the BEAM (Barkpark.Connectors, via runtime.exs) signs a connect ticket, and the
# bridge verifies it — same value, same box, loopback only. Backfilled ONCE (a
# regenerated secret would 401 every connect until both processes restart) and
# COPIED into /etc/barkpark/connectors.env below.
#
# ABSENT is a supported state, not an error: no secret ⇒ the bridge does not
# mount its connect routes and Studio's Connectors catalog renders read-only with
# a banner. That is what removes the merge-order hazard between the bridge slice
# and this step.
if ! grep -q '^CONNECTORS_CONNECT_SECRET=' .env 2>/dev/null; then
  echo "CONNECTORS_CONNECT_SECRET=$(openssl rand -base64 32)" >> .env
  log "added CONNECTORS_CONNECT_SECRET to .env (Studio -> bridge connect tickets)"
fi
set -a; . ./.env; set +a

# ---- Arm the Caddy maintenance page (branded 503 + Retry-After) so ANY window
# where the app is unreachable — a crash/restart outside deploys; blue/green
# deploys themselves don't drop the upstream — shows "back in a moment", not a
# raw 502. Idempotent, backed up, `caddy validate`d, auto-reverting; NEVER fails
# the deploy. Reconciled with the blue/green machinery: the injected block
# contains no slot-port token, so the ACTIVE_PORT grep below still hits
# the site upstream first and the port-flip sed passes over it untouched. The
# renderers in internal/caddyfile + internal/cli/setup bake the same block into
# every provisioned instance; this arms an already-running box on deploy.
# Reference copy: deploy/caddy/barkpark-maintenance.caddy.
arm_caddy_maintenance() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping maintenance page"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping maintenance page"; return 0; }
  if grep -q 'BARKPARK_MAINTENANCE' "$CADDYFILE"; then log "caddy maintenance page already armed"; return 0; fi
  # Slot ports ONLY: the /mcp route (if armed first) carries its own
  # `reverse_proxy localhost:4010` line, which must never become the
  # insertion anchor.
  if ! grep -qE "reverse_proxy[[:space:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:space:]]|\$)" "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (arm manually: deploy/caddy/barkpark-maintenance.caddy)"
    return 0
  fi
  local block; block="$(cat <<'MAINT'
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
MAINT
)"
  local bak; bak="${CADDYFILE}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert the block right after the FIRST slot `reverse_proxy localhost:<port>`
  # line (whichever slot port is live), so it lands inside that site block.
  # Slot ports only — never the /mcp route's :4010 line.
  BP_BLOCK="$block" BP_SLOT_RE="reverse_proxy[[:blank:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:blank:]]|\$)" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"]; re=ENVIRON["BP_SLOT_RE"] }
    { print }
    !ins && $0 ~ re { print blk; ins=1 }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — the caddy user must still be
  # able to read its own config or `systemctl reload caddy` fails with
  # "permission denied" (bit the first live blue/green flip on guerrilla).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed Caddy maintenance page"; else log "caddy reload failed (config valid) — armed on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the injected block — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
with_caddy_lock arm_caddy_maintenance

# ---- Arm the /mcp Caddy route for the remote MCP endpoint (viable-everywhere
# charter D19): path-based on the EXISTING public site — never a new subdomain —
# proxying to 127.0.0.1:$MCP_PORT where barkpark-mcp.service listens
# (`bp mcp serve --http`, guarded install below). :4010 sits OUTSIDE the
# blue/green slot ports {4000,4001} ON PURPOSE: the ACTIVE_PORT greps and the
# port-flip sed match slot ports exactly, so they pass over this route
# untouched. Same contract as the maintenance arming: idempotent (marker),
# backed up, `caddy validate`d, auto-reverting, NEVER fails the deploy. Until
# the unit is enabled, /mcp requests hit a dead upstream and land on the
# maintenance 503 — never a raw 502.
arm_caddy_mcp_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping /mcp route"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping /mcp route"; return 0; }
  if grep -q 'BARKPARK_MCP_ROUTE' "$CADDYFILE"; then log "caddy /mcp route already armed"; return 0; fi
  if [ "$MCP_PORT" = "$BLUE_PORT" ] || [ "$MCP_PORT" = "$GREEN_PORT" ]; then
    log "refusing /mcp route on a blue/green slot port (:$MCP_PORT) — the port-flip sed would rewrite it"
    return 0
  fi
  if ! grep -qE "reverse_proxy[[:space:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:space:]]|\$)" "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (/mcp route not armed)"
    return 0
  fi
  local block; block="$(cat <<MCPROUTE
	# BARKPARK_MCP_ROUTE — remote MCP endpoint (barkpark-mcp.service,
	# bp mcp serve --http). Matcher covers the bare /mcp AND /mcp/* —
	# Streamable-HTTP clients POST the bare path.
	@barkpark_mcp path /mcp /mcp/*
	handle @barkpark_mcp {
		reverse_proxy localhost:${MCP_PORT}
	}
MCPROUTE
)"
  local bak; bak="${CADDYFILE}.bak.mcp.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert the block right BEFORE the first slot `reverse_proxy localhost:<port>`
  # line, so the handle sits inside that site block ahead of the bare fallback
  # proxy (requests matching /mcp terminate in the handle; everything else
  # falls through to the site upstream). Slot ports only — a re-run must never
  # anchor on this block's own :4010 line (the marker guard above already
  # prevents that; the tight regex is belt-and-braces).
  BP_BLOCK="$block" BP_SLOT_RE="reverse_proxy[[:blank:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:blank:]]|\$)" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"]; re=ENVIRON["BP_SLOT_RE"] }
    !ins && $0 ~ re { print blk; ins=1 }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — keep the file readable for
  # the caddy user (same lesson as the maintenance arming).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed caddy /mcp route -> localhost:$MCP_PORT"; else log "caddy reload failed (config valid) — /mcp route live on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the /mcp route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
with_caddy_lock arm_caddy_mcp_route

# ---- Arm the /connectors Caddy route for the Connectors bridge (connectors
# charter D34/D46): path-based on the EXISTING public site — never a new
# subdomain (barkpark.cloud has NO wildcard DNS; a subdomain would re-arm the
# separate Hetzner DNS-token human gate for nothing) — proxying to
# 127.0.0.1:$CONNECTORS_PORT where barkpark-connectors.service listens (guarded
# install below). :4020, like the MCP route's :4010, sits OUTSIDE the blue/green
# slot ports {4000,4001} ON PURPOSE: the ACTIVE_PORT greps and the port-flip sed
# match slot ports exactly, so they pass over this route untouched. Same contract
# as the maintenance + /mcp arming: idempotent (marker), backed up, `caddy
# validate`d, auto-reverting, NEVER fails the deploy. Until the unit is up,
# /connectors requests hit a dead upstream and land on the maintenance 503 —
# never a raw 502. THAT is the ordering hazard docs/ops/connectors-deploy.md
# names: bring the unit UP before registering a provider webhook URL, because a
# provider disables a webhook after repeated non-2xx.
arm_caddy_connectors_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping $CONNECTORS_PATH_PREFIX route"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping $CONNECTORS_PATH_PREFIX route"; return 0; }
  if grep -q 'BARKPARK_CONNECTORS_ROUTE' "$CADDYFILE"; then log "caddy $CONNECTORS_PATH_PREFIX route already armed"; return 0; fi
  if [ "$CONNECTORS_PORT" = "$BLUE_PORT" ] || [ "$CONNECTORS_PORT" = "$GREEN_PORT" ]; then
    log "refusing $CONNECTORS_PATH_PREFIX route on a blue/green slot port (:$CONNECTORS_PORT) — the port-flip sed would rewrite it"
    return 0
  fi
  if [ "$CONNECTORS_PORT" = "$MCP_PORT" ]; then
    log "refusing $CONNECTORS_PATH_PREFIX route on the MCP port (:$CONNECTORS_PORT) — two units cannot bind one port"
    return 0
  fi
  if ! grep -qE "reverse_proxy[[:space:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:space:]]|\$)" "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched ($CONNECTORS_PATH_PREFIX route not armed)"
    return 0
  fi
  local block; block="$(cat <<CONNROUTE
	# BARKPARK_CONNECTORS_ROUTE — the Connectors bridge
	# (barkpark-connectors.service). Matcher covers the bare prefix AND its
	# subtree — provider webhooks POST ${CONNECTORS_PATH_PREFIX}/<provider>.
	@barkpark_connectors path ${CONNECTORS_PATH_PREFIX} ${CONNECTORS_PATH_PREFIX}/*
	handle @barkpark_connectors {
		reverse_proxy localhost:${CONNECTORS_PORT}
	}
CONNROUTE
)"
  local bak; bak="${CADDYFILE}.bak.connectors.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert right BEFORE the first slot `reverse_proxy localhost:<port>` line, so
  # the handle sits inside that site block ahead of the bare fallback proxy.
  # SLOT PORTS ONLY: the anchor regex must never match the /mcp block's own
  # `localhost:4010` line (nor this block's :4020 on a re-run) — that trap is
  # documented on arm_caddy_mcp_route. The marker guard above is the first line
  # of defence; the tight regex is belt-and-braces.
  BP_BLOCK="$block" BP_SLOT_RE="reverse_proxy[[:blank:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:blank:]]|\$)" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"]; re=ENVIRON["BP_SLOT_RE"] }
    !ins && $0 ~ re { print blk; ins=1 }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — keep the file readable for the
  # caddy user (same lesson as the maintenance + /mcp arming).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed caddy $CONNECTORS_PATH_PREFIX route -> localhost:$CONNECTORS_PORT"; else log "caddy reload failed (config valid) — $CONNECTORS_PATH_PREFIX route live on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the $CONNECTORS_PATH_PREFIX route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
with_caddy_lock arm_caddy_connectors_route

# ---- Which slot serves now? Caddy's upstream port is the source of truth
# (on the pre-blue/green layout it reads 4000, which maps to legacy-as-blue).
# Slot ports ONLY (never 40[0-9]{2}): the /mcp and /connectors routes above put
# localhost:4010 / localhost:4020 lines in the Caddyfile ahead of the site
# upstream — a loose grep + head -1 would misread one as the active slot and the
# flip sed would then destroy the route.
ACTIVE_PORT="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" | head -1 | cut -d: -f2)"
ACTIVE_PORT="${ACTIVE_PORT:-$BLUE_PORT}"
if [ "$ACTIVE_PORT" = "$BLUE_PORT" ]; then
  TARGET=green; TARGET_PORT="$GREEN_PORT"; OTHER=blue
else
  TARGET=blue; TARGET_PORT="$BLUE_PORT"; OTHER=green
fi
log "active upstream :$ACTIVE_PORT -> deploying slot '$TARGET' on :$TARGET_PORT"

# ---- Install/refresh the slot units + per-slot env (idempotent). The env files
# are truncate-regenerated every deploy, so any operator-set
# BARKPARK_SITE_DEPLOY_APPLY=1 — the site-deploy seam-enable flag, read at BEAM
# boot from .slots/%i.env via the unit's EnvironmentFile — must be CARRIED
# FORWARD or a redeploy silently drops it and the site-deploy admin route
# reverts to 503, re-breaking the finish line (D38). Mirror the backfill
# discipline used for the $APP/.env durable flags above: preserve what the prior
# file held, never hardcode the flag on (absent stays absent — fail-closed).
install -m 0644 "$APP/deploy/systemd/barkpark-slot@.service" /etc/systemd/system/barkpark-slot@.service
# The node-slot SSR template unit (site-spawner W7): site-deploy-node.sh drives
# `systemctl start barkpark-site@<slug>__<slot>` for container-framework (kind=node)
# sites, but that unit template must be INSTALLED on the box first — without it a
# node deploy dies at HEALTH ("the node process would not boot"). Install it here
# alongside barkpark-slot@ so every box that can deploy can serve a node site.
[ -f "$APP/deploy/systemd/barkpark-site@.service" ] && \
  install -m 0644 "$APP/deploy/systemd/barkpark-site@.service" /etc/systemd/system/barkpark-site@.service
mkdir -p "$APP/.slots"
write_slot_env() { # $1=slot  $2=port  $3=build_root
  local f="$APP/.slots/$1.env" apply=""
  [ -f "$f" ] && apply="$(grep -E '^BARKPARK_SITE_DEPLOY_APPLY=' "$f" 2>/dev/null | tail -1)"
  {
    printf 'BARKPARK_PORT_OVERRIDE=%s\nMIX_BUILD_ROOT=%s\n' "$2" "$3"
    [ -n "$apply" ] && printf '%s\n' "$apply"
  } > "$f"
}
write_slot_env blue  "$BLUE_PORT"  "$APP/api/_build_blue"
write_slot_env green "$GREEN_PORT" "$APP/api/_build_green"
# Per-slot version stamp (W6 D12): record what THIS deploy puts into the target
# slot, so --rollback knows what the idle slot holds after the next flip. STATE
# is one global sha and the env files carry only port+build-root — without the
# stamp a box has slot amnesia and rollback would flip to an unknown build.
#
# ORDERING (D291): the stamp is DEFINED here but WRITTEN only after the health
# gate. It used to be written right here — before deps.get/deps.compile/compile/
# ecto.migrate — and no exit-12/13 path reverted it, so a deploy that never
# built left `.slots/<slot>.sha` claiming a build the slot does not hold, and
# `--rollback` reads exactly that file (see the preflight above) to pick its
# target. Same discipline as $STATE, which is written only after health + flip.
SLOT_SHA_FILE="$APP/.slots/$TARGET.sha"
PREV_SLOT_SHA="$(cat "$SLOT_SHA_FILE" 2>/dev/null || true)"
stamp_slot_sha() { echo "$NEW" > "$SLOT_SHA_FILE"; }
restore_slot_sha() { # any post-stamp failure path: the slot is being retired
  if [ -n "$PREV_SLOT_SHA" ]; then printf '%s\n' "$PREV_SLOT_SHA" > "$SLOT_SHA_FILE"
  else rm -f "$SLOT_SHA_FILE"; fi
}
systemctl daemon-reload

# ---- Clean-build the idle slot's root while the active slot keeps serving
# its own untouched root. A build failure = zero downtime. The golden rules
# still hold: from-scratch build (fresh HEEx), deps.compile --force.
cd "$APP/api" || { log "no $APP/api"; exit 10; }
build() { MIX_ENV=prod MIX_BUILD_ROOT="_build_$TARGET" mix "$@"; }
log "clean build into _build_$TARGET (deps.get; deps.compile --force; compile)"
rm -rf "_build_$TARGET"
if ! build deps.get;             then log "deps.get failed";     git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! build deps.compile --force; then log "deps.compile failed"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! build compile;              then log "compile failed";      git -C "$APP" reset --hard "$OLD"; exit 12; fi
if [ ! -d "_build_$TARGET/prod" ]; then log "build produced no _build_$TARGET/prod — abort, live slot untouched"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
log "migrate (new code, active slot still serving)"
if ! build ecto.migrate;         then log "migrate failed";      git -C "$APP" reset --hard "$OLD"; exit 13; fi

# ---- Boot the idle slot and gate on it. The active slot is never touched;
# every failure path from here on is zero-downtime.
cd "$APP" || { log "no $APP"; exit 10; }

# ---- pdrender→TUI wasm the reader lazy-loads (api/priv/static/assets/
# bp-pdrender.wasm.gz, served by Plug.Static). This build path is SEPARATE from
# scripts/deploy-rebuild.sh (which builds the wasm and REFUSES slot boxes), so
# the slot deployer must build it itself. BEFORE the slot boots + health-gates +
# Caddy swaps, so the new slot serves the freshly-built blob — never a blob-less
# cutover. #1361 dropped the committed blob, so build-at-deploy is what keeps the
# reader whole. priv/static is shared source symlinked into both slots, so one
# build serves whichever slot is live. Non-fatal (mirrors deploy-rebuild): a
# failed build only degrades the reader's TUI view to its fallback, never aborts
# a zero-downtime deploy. `make wasm` runs from the repo root ($APP) and pins its
# own Go toolchain via GOTOOLCHAIN.
log "building pdrender wasm (non-fatal)"
if command -v go >/dev/null 2>&1; then
  if make wasm; then log "pdrender wasm built"; else log "WARN: pdrender wasm build failed — reader TUI view degrades to its fallback"; fi
else
  log "go not found — skipping pdrender wasm build"
fi

log "boot barkpark-slot@$TARGET on :$TARGET_PORT"
systemctl restart "barkpark-slot@$TARGET"

ok=0
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${TARGET_PORT}/api/schemas" || true)"
  if [ "$code" = "200" ]; then ok=1; log "slot $TARGET healthy ($code)"; break; fi
  sleep 5
done
if [ "$ok" != "1" ]; then
  log "slot $TARGET UNHEALTHY — stopping it; :$ACTIVE_PORT was never touched (no downtime)"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  git reset --hard "$OLD"   # keep sources in step with the still-serving old build
  exit 14
fi
# The slot booted and answered — only NOW may it claim this sha as a rollback
# target (D291). Every earlier failure (exit 12/13) leaves the previous stamp,
# and the flip failures below restore it.
stamp_slot_sha

# ---- Hot swap: point Caddy at the new slot (graceful reload, no drops).
# UNDER THE SHARED CADDYFILE LOCK (fd 8, D27): site-deploy.sh rewrites this same
# file, and a concurrent arm-vs-flip interleave DISCARDS this flip while Caddy is
# reloaded onto the slot we retire below (a reproduced hard 502 — and `caddy
# validate` passes in BOTH processes, because a lost update is valid config).
# Bracketed inline, not wrapped in a function: every failure path below EXITS,
# and an exit releases fd 8 with the process.
exec 8>"$CADDY_LOCK"
if ! flock -w 120 8; then
  log "gave up waiting for the Caddyfile lock ($CADDY_LOCK) — no swap; slot $TARGET stopped, :$ACTIVE_PORT still serving (no downtime)"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
# Re-read the live upstream INSIDE the lock. ACTIVE_PORT was read BEFORE a
# multi-minute build — that read was the time-of-check half of the race, and the
# flip must rewrite whatever the file actually holds now.
FLIP_FROM="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" 2>/dev/null | head -1 | cut -d: -f2)"
FLIP_FROM="${FLIP_FROM:-$ACTIVE_PORT}"
cp -a "$CADDYFILE" "$CADDYFILE.pre-deploy"
sed -i "s/localhost:${FLIP_FROM}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
# Did the rewrite actually MOVE the upstream? The post-flip PUBLIC gate below
# claims to catch "a sed that missed the live upstream line". It cannot: BOTH
# slots serve /api/schemas, so when the flip is a no-op the OLD slot answers
# that probe 200 through the UNCHANGED Caddyfile, the gate passes, and the
# script then disables the old slot — leaving Caddy proxying a dead port, exit
# 0, "healthy" in every log line. A Caddyfile whose upstream is written some
# other way (127.0.0.1:<port>, a hand-edit) is invisible to the ACTIVE_PORT
# grep, to the FLIP_FROM re-read above AND to this sed, so all three fall back
# in agreement and nothing downstream can tell. Only the file can. Fail closed
# here, while the old slot is still serving and still enabled.
if grep -q "localhost:${FLIP_FROM}" "$CADDYFILE" || ! grep -q "localhost:${TARGET_PORT}" "$CADDYFILE"; then
  log "FLIP DID NOT LAND: after the rewrite $CADDYFILE still carries :$FLIP_FROM (or never gained :$TARGET_PORT) — the upstream is not written as 'localhost:<slot port>'; restoring, no swap, :$FLIP_FROM still serving"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  log "Caddyfile invalid after port flip — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
if ! systemctl reload caddy; then
  log "caddy reload failed — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; systemctl reload caddy || true
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
exec 8>&-   # leaf lock: released the moment the flip is written + reloaded, so
            # the long non-Caddy tail below (go builds, npm ci) never holds it
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${HEALTH_HOST}:443:127.0.0.1" "https://${HEALTH_HOST}/api/schemas" || true)"
log "Caddy now -> :$TARGET_PORT (https://${HEALTH_HOST}/api/schemas = $code)"
# GATE, not just log (pds-bl-w49): the pre-flip loop above only proves the app
# boots on its OWN port (localhost:$TARGET_PORT) — it cannot catch a flip that
# landed wrong (a sed that missed the live upstream line, a Caddy reload that
# "succeeded" onto a stale worker, TLS/SNI misrouting on the PUBLIC host). This
# curl is the first proof the public hostname actually reaches the new slot,
# and it used to be captured into $code, logged, and then ignored — a broken
# flip still exited 0 and the deploy reported success. The old slot is still
# running and NOT yet retired (that happens below), so failing here can still
# flip Caddy back and walk away clean instead of shipping a silently-broken
# deploy.
if [ "$code" != "200" ]; then
  log "post-flip public health check FAILED (https://${HEALTH_HOST}/api/schemas = $code) — flipping back to :$ACTIVE_PORT; it was never retired"
  revert_post_flip_health_fail() {
    cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
    if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
      log "WARN: pre-deploy Caddyfile backup failed to validate on revert — Caddy left as-is, fix by hand"
      return 1
    fi
    systemctl reload caddy || log "WARN: caddy reload failed while reverting the flip — Caddyfile restored on disk, reload manually"
  }
  with_caddy_lock revert_post_flip_health_fail
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"
  exit 14
fi

# ---- Drain, then retire the old slot AND the pre-blue/green legacy unit.
# Exactly one slot stays enabled (survives reboot). Rollback is NOT a bare
# Caddyfile flip — a slot restart recompiles NEW source from the ONE shared
# checkout into the old slot's stale build root. Run `instance-deploy.sh
# --rollback`: it resets the checkout to the idle slot's recorded sha
# (.slots/<slot>.sha), health-gates that slot on its own port, and flips
# Caddy only on green (see the rollback block above).
sleep 5
systemctl enable "barkpark-slot@$TARGET" >/dev/null 2>&1 || true
systemctl disable --now "barkpark-slot@$OTHER" >/dev/null 2>&1 || true
systemctl disable --now barkpark >/dev/null 2>&1 || true

# ---- Refresh the on-box monitoring agent (charter Decision 33), best-effort.
# Only touch boxes the provisioner ARMED with the agent (its token file exists);
# a plain/legacy box is left untouched. Rebuild barkpark-agent from the just-
# deployed code, re-install the COMMITTED unit, and enable + RESTART it so a
# self-update never drops the beat and never strands the old binary. The
# control/health URLs persist in /etc/barkpark/agent.env
# (written at provision time), so this step needs no knowledge of them. NON-FATAL:
# a monitoring hiccup must never fail a zero-downtime deploy — the app is already
# live on the new slot at this point.
if [ -f /etc/barkpark/agent.token ]; then
  log "refreshing barkpark-agent (monitoring beat)"
  if command -v go >/dev/null 2>&1 && go build -o /usr/local/bin/barkpark-agent ./cmd/barkpark-agent; then
    install -m 0644 "$APP/deploy/systemd/barkpark-agent.service" /etc/systemd/system/barkpark-agent.service
    systemctl daemon-reload
    # restart (not just enable --now): `--now` is `start`, a NO-OP on an
    # already-active unit, so systemd never re-execs it and the running agent
    # keeps serving the deleted inode of the previous binary (measured: 29h
    # stale on guerrilla). Same shape as barkpark-mcp below.
    if systemctl enable barkpark-agent >/dev/null 2>&1 && systemctl restart barkpark-agent; then
      log "barkpark-agent enabled + restarted"
    else
      log "WARN: barkpark-agent enable/restart failed — beat down until next deploy"
    fi
    # SAY whether this box is metered. The unit now names
    # --health-token-file /etc/barkpark/agent.health.token; the file is written at
    # PROVISION time (internal/cli/cloud.agentInstallStep) and a self-update has no
    # admin bearer to mint one with, so a box provisioned before that step exists
    # keeps reporting -1 for req_per_s / p95_ms / err_5xx_per_s. That is survivable
    # — but it must not be SILENT, which is exactly how the whole fleet stayed
    # unmetered while one hand-patched box looked fine.
    if [ -s /etc/barkpark/agent.health.token ]; then
      log "barkpark-agent health token present — req/s, p95 and 5xx are metered"
    else
      log "WARN: no /etc/barkpark/agent.health.token — req/s, p95 and 5xx stay UNMETERED on this box (written at provision time; see deploy/systemd/README.md to backfill)"
    fi
  else
    log "WARN: barkpark-agent rebuild skipped/failed — keeping the running agent"
  fi
fi

# ---- Refresh the remote MCP endpoint (viable-everywhere D18/D19), best-effort
# + GUARDED. barkpark-mcp.service runs the just-built bp binary as
# `mcp serve --http 127.0.0.1:$MCP_PORT` behind the /mcp Caddy route armed
# above. FORWARD-THROUGH design (D18): the unit and its env file hold NO API
# token — each caller's own bearer rides through to the downstream API; a
# missing/bogus bearer fails closed with the downstream 401. The downstream URL
# is the STABLE public front (https://$HEALTH_HOST), never a raw slot port —
# the blue/green flip would strand a pinned port (cp-deploy control-url
# precedent). GUARD: install+enable ONLY when the built binary advertises
# --http in its `mcp serve --help`, so this deploy step ships independently of
# the bearer transport slice without crash-looping the box on an unknown flag.
# NON-FATAL throughout — the app is already live on the new slot.
if command -v go >/dev/null 2>&1; then
  MCP_TMPD="$(mktemp -d)"
  if CGO_ENABLED=0 go build -o "$MCP_TMPD/bp" ./cmd/barkpark \
     && "$MCP_TMPD/bp" mcp serve --help 2>/dev/null | grep -q -- '--http'; then
    log "refreshing barkpark-mcp (remote MCP endpoint on 127.0.0.1:$MCP_PORT)"
    # `install` (not cp) — it unlinks first, so a running barkpark-mcp never
    # ETXTBSY-blocks its own refresh.
    install -m 0755 "$MCP_TMPD/bp" /usr/local/bin/barkpark-mcp
    mkdir -p "$(dirname "$MCP_ENV_FILE")"
    printf 'BARKPARK_API_URL=https://%s\nBARKPARK_MCP_HTTP_ADDR=127.0.0.1:%s\n' "$HEALTH_HOST" "$MCP_PORT" > "$MCP_ENV_FILE"
    install -m 0644 "$APP/deploy/systemd/barkpark-mcp.service" /etc/systemd/system/barkpark-mcp.service
    systemctl daemon-reload
    # restart (not just enable --now): an already-running unit must pick up the
    # freshly-installed binary.
    if systemctl enable barkpark-mcp >/dev/null 2>&1 && systemctl restart barkpark-mcp; then
      # `systemctl restart` of a Type=simple unit returns the moment the process
      # is forked — it says NOTHING about whether the serve survived its startup
      # manifest fetch. task-1a641b21d19595d3: this line read "enabled" on
      # guerrilla while the unit crash-looped 2,464 times (anonymous manifest,
      # no task noun, default --tools tasks fails fast). Settle, then read the
      # unit's OWN state and say what it is; a dead endpoint is named in the
      # deploy log, still non-fatal (the app slot is already live).
      sleep "${MCP_SETTLE_SECS:-15}"
      MCP_STATE="$(systemctl is-active barkpark-mcp 2>/dev/null || true)"
      MCP_RESTARTS="$(systemctl show barkpark-mcp -p NRestarts --value 2>/dev/null || true)"
      if [ "$MCP_STATE" = "active" ]; then
        log "barkpark-mcp active after ${MCP_SETTLE_SECS:-15}s (restarts=${MCP_RESTARTS:-?}; https://$HEALTH_HOST/mcp -> 127.0.0.1:$MCP_PORT)"
      else
        log "WARN: barkpark-mcp is NOT active after ${MCP_SETTLE_SECS:-15}s (state=${MCP_STATE:-unknown} restarts=${MCP_RESTARTS:-?}) — remote MCP /mcp is DOWN; journal tail:"
        journalctl -u barkpark-mcp -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
      fi
    else
      log "WARN: barkpark-mcp enable/restart failed — remote MCP down until next deploy"
    fi
  else
    log "bp binary does not advertise 'mcp serve --http' — skipping barkpark-mcp install (bearer transport slice not merged yet)"
  fi
  rm -rf "$MCP_TMPD"
fi

# ---- Refresh the Connectors bridge (connectors charter D34/D46), best-effort
# + GUARDED. barkpark-connectors.service runs the standalone Node/TS bridge in
# $APP/connectors behind the /connectors Caddy route armed above, on the
# loopback :$CONNECTORS_PORT. NON-FATAL throughout — the app is already live on
# the new slot, and a bridge hiccup must never brick a good deploy.
#
# node is NOT on this box's PATH (bare `node -v` => command not found): asdf
# manages it, and systemd cannot expand a variable in the ExecStart executable
# position. So resolve node HERE and point a stable /usr/local/bin/barkpark-node
# symlink at it (same shape as /usr/local/bin/barkpark-mcp) — the committed unit
# never carries a version.
resolve_node_bin() {
  local d b
  if command -v asdf >/dev/null 2>&1; then
    d="$(asdf where nodejs 2>/dev/null || true)"
    if [ -n "$d" ] && [ -x "$d/bin/node" ]; then printf '%s\n' "$d/bin/node"; return 0; fi
  fi
  # Newest asdf install, for a box where no version is pinned for this dir.
  b="$(ls -1d "$HOME"/.asdf/installs/nodejs/*/bin/node 2>/dev/null | sort -V | tail -1)"
  if [ -n "$b" ] && [ -x "$b" ]; then printf '%s\n' "$b"; return 0; fi
  # A REAL node on PATH — never a bare shim: an asdf shim with no version set
  # exits non-zero, and installing a unit that points at it would crash-loop.
  b="$(command -v node 2>/dev/null || true)"
  if [ -n "$b" ] && "$b" -v >/dev/null 2>&1; then printf '%s\n' "$b"; return 0; fi
  return 1
}

CONNECTORS_DIR="$APP/connectors"
if [ ! -d "$CONNECTORS_DIR" ]; then
  log "no $CONNECTORS_DIR in this checkout — skipping barkpark-connectors"
elif ! NODE_BIN="$(resolve_node_bin)"; then
  log "WARN: no usable node (asdf nodejs not installed and none on PATH) — barkpark-connectors NOT installed; $CONNECTORS_PATH_PREFIX stays on the maintenance 503"
elif [ -z "${DATABASE_URL:-}" ]; then
  log "WARN: no DATABASE_URL in $APP/.env — barkpark-connectors NOT installed (the bridge owns the chat_bridge schema and cannot boot without it)"
else
  NODE_DIR="$(dirname "$NODE_BIN")"
  log "refreshing barkpark-connectors (node $("$NODE_BIN" -v 2>/dev/null || echo '?') at $NODE_BIN)"
  # COPY, never symlink (the #3374 place_node recipe): asdf's node lives under
  # /root, and every barkpark-site@ slot unit runs ProtectHome=yes — a symlink
  # into /root 203/EXECs those slots on their next restart. This line was the
  # SECOND writer of $NODE_LINK and kept silently re-breaking the fix on every
  # instance deploy (live-caught twice on 2026-07-16: capstone crashloop x74).
  # Copy only when content differs; atomic tmp+mv so a reader never sees a
  # half-written binary.
  if ! cmp -s "$NODE_BIN" "$NODE_LINK" 2>/dev/null; then
    cp "$NODE_BIN" "$NODE_LINK.new" && chmod 755 "$NODE_LINK.new" && mv "$NODE_LINK.new" "$NODE_LINK"
    log "placed node COPY at $NODE_LINK (ProtectHome-safe)"
  fi
  # FULL install (not --omit=dev) ON PURPOSE: the bridge has no build step yet —
  # its entrypoint is `tsx src/index.ts`, and tsx is a devDependency. When
  # connectors/ grows a real `build` (tsc -> dist/), switch this to
  # `npm ci --omit=dev` and point the unit at `node dist/index.js`.
  # npm's own shebang is `#!/usr/bin/env node`, which cannot work on a box with
  # no node on PATH — so prepend the resolved node dir for this call only.
  if ( cd "$CONNECTORS_DIR" && PATH="$NODE_DIR:$PATH" "$NODE_DIR/npm" ci --no-audit --no-fund ); then
    if [ ! -f "$CONNECTORS_DIR/node_modules/tsx/dist/cli.mjs" ]; then
      log "WARN: connectors deps installed but no tsx runner (node_modules/tsx/dist/cli.mjs) — barkpark-connectors NOT enabled"
    else
      # 0600 — this file holds DATABASE_URL and the credential cipher key. (mcp.env
      # is 0644 because it deliberately holds NO secret; that is the exception.)
      # There is deliberately NO BARKPARK_CHAT_TOKEN line: one ambient operator
      # token would serve EVERY tenant — the exact multi-tenant hole this wave
      # closes. Each install authenticates with its own workspace-bound token,
      # ciphered at rest under CONNECTORS_CREDENTIAL_KEY.
      mkdir -p "$(dirname "$CONNECTORS_ENV_FILE")"
      ( umask 077; : > "$CONNECTORS_ENV_FILE" )
      chmod 0600 "$CONNECTORS_ENV_FILE"
      {
        printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
        printf 'BARKPARK_API_URL=https://%s\n' "$HEALTH_HOST"
        printf 'CONNECTORS_HTTP_ADDR=127.0.0.1:%s\n' "$CONNECTORS_PORT"
        printf 'CONNECTORS_PATH_PREFIX=%s\n' "$CONNECTORS_PATH_PREFIX"
        printf 'CONNECTORS_CREDENTIAL_KEY=%s\n' "${CONNECTORS_CREDENTIAL_KEY:-}"
        # The SAME value Barkpark.Connectors signs tickets with (D50). If these
        # two ever disagree, every connect 401s and nothing else would catch it.
        printf 'CONNECTORS_CONNECT_SECRET=%s\n' "${CONNECTORS_CONNECT_SECRET:-}"
      } > "$CONNECTORS_ENV_FILE"
      install -m 0644 "$APP/deploy/systemd/barkpark-connectors.service" /etc/systemd/system/barkpark-connectors.service
      systemctl daemon-reload
      if systemctl enable barkpark-connectors >/dev/null 2>&1 && systemctl restart barkpark-connectors; then
        # Health gate: a bridge that cannot boot (missing config, bad DB) exits
        # and Restart=on-failure would crash-loop it forever. Give it a moment,
        # then demand systemd still calls it active; otherwise DISABLE it again
        # and say so. Fail closed, stay non-fatal.
        sleep 5
        if [ "$(systemctl is-active barkpark-connectors 2>/dev/null)" = "active" ]; then
          log "barkpark-connectors up (https://$HEALTH_HOST$CONNECTORS_PATH_PREFIX -> 127.0.0.1:$CONNECTORS_PORT)"
          # LOG-ONLY probe (never a gate — a polling-only bridge legitimately
          # serves no HTTP): does the path route actually reach the bridge?
          code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${CONNECTORS_PORT}${CONNECTORS_PATH_PREFIX}/health" || true)"
          log "connectors health probe: 127.0.0.1:${CONNECTORS_PORT}${CONNECTORS_PATH_PREFIX}/health = ${code:-000} (000 = no HTTP surface yet; provider webhooks would land on the maintenance 503 — see docs/ops/connectors-deploy.md)"

          # INSURANCE, NOT A GATE (connectors D54). The BRIDGE creates chat_bridge
          # at its own boot, so whoever it connects as OWNS the schema — and on
          # every path we actually run (prod, CI, local) that is the same role the
          # BEAM reads with, which makes this a strict no-op. It exists for the day
          # a second, non-owning Postgres role appears: without USAGE+SELECT, the
          # Studio Connectors catalog dies on `permission denied for schema
          # chat_bridge`. It runs AFTER the health gate (the schema does not exist
          # until the bridge has booted at least once) and it is GUARDED and
          # NON-FATAL — a missing psql, a role we cannot name, or a permission error
          # logs a warning and the deploy continues. A GRANT must never take an
          # instance down.
          if command -v psql >/dev/null 2>&1 && [ -n "${DATABASE_URL:-}" ]; then
            db_role="$(psql "$DATABASE_URL" -tAc 'SELECT current_user' 2>/dev/null || true)"
            if [ -n "$db_role" ]; then
              if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
                   -c "GRANT USAGE ON SCHEMA chat_bridge TO \"$db_role\"" \
                   -c "GRANT SELECT ON chat_bridge.connector_installs TO \"$db_role\"" >/dev/null 2>&1; then
                log "connectors: GRANT USAGE/SELECT on chat_bridge to $db_role (no-op for the schema owner)"
              else
                log "WARN: could not GRANT on chat_bridge to $db_role (schema may not exist yet, or we are not its owner) — continuing"
              fi
            fi
          fi
        else
          log "WARN: barkpark-connectors did not stay active — disabling it (no crash-loop); $CONNECTORS_PATH_PREFIX stays on the maintenance 503. Check: journalctl -u barkpark-connectors"
          systemctl disable --now barkpark-connectors >/dev/null 2>&1 || true
        fi
      else
        log "WARN: barkpark-connectors enable/restart failed — bridge down until next deploy"
      fi
    fi
  else
    log "WARN: npm ci failed in $CONNECTORS_DIR — barkpark-connectors NOT (re)installed; the running unit (if any) keeps its old deps"
  fi
fi

# ---- Install the bp CLI so every Studio chat session can wield Barkpark tasks
# (chat-task-hands W1). /usr/local/bin is already on the LIVE BEAM process PATH
# (/proc-proven on guerrilla), so a Port.open child resolves `bp` with zero PATH
# injection — no reliance on the stray, off-PATH /opt/barkpark/bp manual build.
# Build ONCE per deploy (this main flow runs once under flock, not per slot),
# native arch (guerrilla is ARM64), CGO off to match the barkpark-agent precedent
# above. Install ATOMICALLY: build to a tmpfile on the SAME filesystem, then
# rename over the live binary, so an in-flight `bp` invocation never sees a half-
# written file. LOUD on failure — a silent skip is exactly the silent-failure bug
# this epic exists to kill — but NON-FATAL: the app is already live on the new
# slot, and bricking a good deploy over a transient toolchain hiccup is worse than
# a logged miss that self-heals on the next deploy.
log "installing bp CLI -> /usr/local/bin/bp"
if command -v go >/dev/null 2>&1; then
  bp_tmp="$(mktemp /usr/local/bin/.bp.XXXXXX)"
  if CGO_ENABLED=0 go build -o "$bp_tmp" ./cmd/barkpark; then
    chmod 0755 "$bp_tmp"
    mv -f "$bp_tmp" /usr/local/bin/bp
    log "bp CLI installed -> /usr/local/bin/bp ($(command -v bp))"
  else
    rm -f "$bp_tmp"
    log "WARN: bp CLI build FAILED (go build ./cmd/barkpark) — Studio chat task hands unavailable until next deploy"
  fi
else
  log "WARN: go not found — bp CLI NOT installed; Studio chat task hands unavailable until next deploy"
fi

# ---- Install the Cloud sandbox runner onto PATH (connectors charter D265).
# ClaudeChat picks a provider turn by resolving the BARE executable name
# "cloud-sandbox-runner" with System.find_executable on the LIVE BEAM PATH
# (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:… — /proc-proven
# on guerrilla, with NO node resolvable and NO Environment= override). So the
# runner's own `#!/usr/bin/env node` shebang ships as a SILENT NO-OP: the moment
# a :cloud turn starts, ClaudeChat returns {:stop, :binary_not_found}. Two files,
# re-copied EVERY deploy so they track the checkout (#3374 copy idiom):
#   (1) the runner .mjs  -> $SANDBOX_RUNNER_MJS
#   (2) a 2-line POSIX wrapper -> $SANDBOX_RUNNER_BIN whose basename matches the
#       bare name ClaudeChat defaults to, execing the already-deployed,
#       dependency-free /usr/local/bin/barkpark-node (v26.5.0 ELF, argv passthrough
#       proven) against the installed .mjs — NEVER the env-node shebang. Because
#       the basename IS the default, ClaudeChat's :sandbox_runner config stays UNSET.
# Same LOUD-but-NON-FATAL contract as the bp/connectors blocks above: the app is
# already live on the new slot, so a missing runner source or an unwritable target
# logs a WARN and the deploy continues — a :cloud turn simply stays
# :binary_not_found until the next deploy heals it. Writes are atomic (tmp on the
# SAME target dir, then rename) so a concurrent reader never sees a half-written file.
RUNNER_SRC="$APP/scripts/connectors/cloud-sandbox-runner.mjs"
log "installing cloud-sandbox-runner -> $SANDBOX_RUNNER_BIN (wrapper) + $SANDBOX_RUNNER_MJS (.mjs)"
install_sandbox_runner() { # returns non-zero (LOUD) on any failure; caller stays non-fatal
  if [ ! -f "$RUNNER_SRC" ]; then
    log "WARN: no $RUNNER_SRC in this checkout — cloud-sandbox-runner NOT installed; a :cloud turn stays :binary_not_found until next deploy"
    return 1
  fi
  # (1) the .mjs, atomic (tmp on the SAME target dir, then rename), 0644.
  if ! cp "$RUNNER_SRC" "$SANDBOX_RUNNER_MJS.new" 2>/dev/null \
     || ! chmod 0644 "$SANDBOX_RUNNER_MJS.new" \
     || ! mv -f "$SANDBOX_RUNNER_MJS.new" "$SANDBOX_RUNNER_MJS"; then
    rm -f "$SANDBOX_RUNNER_MJS.new" 2>/dev/null || true
    log "WARN: could not install $SANDBOX_RUNNER_MJS (unwritable target?) — cloud-sandbox-runner NOT installed this deploy"
    return 1
  fi
  # (2) the wrapper, atomic, 0755. FIXED production paths on purpose — the wrapper
  # runs on the box where both live under /usr/local/bin, and hardcoding
  # barkpark-node here is the whole point: never trust the .mjs env-node shebang on
  # the node-less BEAM PATH.
  {
    printf '#!/bin/sh\n'
    printf 'exec /usr/local/bin/barkpark-node /usr/local/bin/cloud-sandbox-runner.mjs "$@"\n'
  } > "$SANDBOX_RUNNER_BIN.new" 2>/dev/null || true
  if [ ! -s "$SANDBOX_RUNNER_BIN.new" ] \
     || ! chmod 0755 "$SANDBOX_RUNNER_BIN.new" \
     || ! mv -f "$SANDBOX_RUNNER_BIN.new" "$SANDBOX_RUNNER_BIN"; then
    rm -f "$SANDBOX_RUNNER_BIN.new" 2>/dev/null || true
    log "WARN: could not install the $SANDBOX_RUNNER_BIN wrapper (unwritable target?) — cloud-sandbox-runner NOT installed this deploy"
    return 1
  fi
  log "cloud-sandbox-runner installed -> $SANDBOX_RUNNER_BIN (exec barkpark-node cloud-sandbox-runner.mjs), .mjs versioned from the checkout"
  return 0
}
install_sandbox_runner || true

# ---- Post-deploy LIVE reachability smoke for the public /mcp matrix
# (connectors-mcp-live-reachability-smoke). ADVISORY, NEVER A GATE.
#
# WHAT IT ADDS. The auth fail-closed contract and the Caddy arming are already
# proven hermetically (internal/cli/mcp_http_test.go, instance-deploy_test.sh).
# Neither can prove the four PUBLIC paths answer correctly on a real box — a CI
# runner reaches no host and holds no bearer — so that proof lives here, on the
# box, after every unit above has been refreshed. Four legs, each printing the
# code it saw: POST /mcp initialize (200 + serverInfo.name=barkpark-tasks),
# GET /mcp (405), GET /connectors/mcp (404 by design), GET /connectors/health (200).
#
# WHY THE EXIT CODE IS SWALLOWED. We are past the flip: the app slot is live and
# Caddy already points at it. A stopped barkpark-mcp or a silent bridge is a real
# problem, but failing HERE would mark a healthy app deploy as failed and invite a
# rollback of code that is serving fine. The WARN + the per-leg lines above it are
# the signal; the deploy log is where an operator reads them.
#
# Against the STABLE public front ($HEALTH_HOST), never a slot port — the blue/green
# flip would strand a pinned port (the cp-deploy control-url precedent), and a slot
# port would bypass Caddy, which is exactly the hop these legs exist to prove.
MCP_SMOKE="$APP/deploy/mcp-reachability-smoke.sh"
if [ -f "$MCP_SMOKE" ]; then
  log "post-deploy /mcp reachability smoke -> https://$HEALTH_HOST (advisory, non-fatal)"
  bash "$MCP_SMOKE" "$HEALTH_HOST" || log "WARN: /mcp reachability smoke has RED leg(s) (advisory — the app deploy stands); read the mcp-smoke LEG lines above for the code each leg saw"
else
  log "WARN: no $MCP_SMOKE in this checkout — /mcp reachability smoke skipped"
fi

echo "$NEW" > "$STATE"
log "HEALTHY — slot $TARGET live at $(git rev-parse --short HEAD)"
exit 0
