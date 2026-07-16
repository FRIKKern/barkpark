#!/usr/bin/env bash
# shellcheck disable=SC2329  # several fns run indirectly (with_caddy_lock "$@") or only in --self-test; shellcheck 0.11 can't trace that
# Deploy a content-bound NODE-SLOT SSR site (Next.js adapter × node-slot SSR
# target) next to Phoenix on a Barkpark content box (e.g. guerrilla).
# Site-Spawner W7 — the SECOND runtime target the founding architecture named:
# "ONE deploy state machine, TWO runtime targets: static-symlink-swap OR
# node-slot SSR". This is the node-slot backend. [charter D61–D70]
#
# It is the SIBLING of deploy/site-deploy.sh — the SAME six-stage state machine,
# but the artifact is a running PROCESS with a port + lifecycle, not a directory
# of files served by Caddy directly:
#
#   PLAN   build_id is passed in by the caller; if the process on the ACTIVE
#          Caddy-upstream slot already serves this build_id, exit 0 no-op (the
#          on-box mirror of the sites(site_id,build_id) unique index).
#   BUILD  npm ci && npm run build in the site source dir under
#          `systemd-run --scope -p MemoryMax -p CPUQuota` + a SCRUBBED env (only
#          the injected BARKPARK_* build vars — D7). Next's `output:'standalone'`
#          emits .next/standalone (a traced node_modules + server.js), NOT a
#          static dist/.
#   STAGE  (D64) three-piece copy into an IMMUTABLE releases/<build_id>/: the
#          standalone dir IS the release root (server.js at its top), then
#          .next/static -> <release>/.next/static, then public/ -> <release>/public.
#   HEALTH (D65) boot the REAL idle slot (systemctl start barkpark-site@<slug>__<slot>),
#          poll ITS port to a >=10s deadline (a running process, not a static
#          file — do not trust Next's "Ready" log line, boot-to-first-200 lags),
#          assert HTTP 200 AND bp-build-id == BUILD_ID + bp-content-rev / bp-doc-id
#          non-empty BY VALUE (meta_value, D26). On failure: stop the just-booted
#          slot, NEVER touch the live slot or Caddy, exit 14 (fail closed).
#   SWITCH (D66) marker-anchored per-site reverse_proxy PORT re-flip — replace the
#          `reverse_proxy localhost:<port>` inside THIS site's Caddy marker block
#          in place (NOT instance-deploy.sh's whole-file global sed, which was
#          RUN-proven to corrupt a second site sharing a port literal), under the
#          shared Caddyfile lock -> backup -> caddy validate -> reload -> revert.
#          Blue/green: the new slot was already booted + health-gated; the flip is
#          the atomic cutover.
#   RETIRE (D67) keep the current slot + 1 WARM previous slot running (for <1s
#          rollback); stop/disable any slot beyond that; keep the newest N release
#          dirs on disk (never the ones the two live slots point at).
#
# ROLLBACK (D67): a WARM previous slot (still running) = a pure Caddy port-flip
# back (<1s, no reboot, no re-gate). A COLD older release = reboot the idle slot
# onto it + health-gate + flip. Fail-closed throughout: a slot that will not boot
# or fails its health probe NEVER takes the Caddy upstream — the last-good slot
# keeps serving.
#
# The KEY difference from the static engine: the artifact is a long-running
# process. It is capped (MemoryMax/CPUQuota on the slot unit), health-gated by an
# HTTP probe to the process, and Caddy reverse-proxies to its port. Density
# tradeoff vs static: deploy/README.md §"Static vs node density".
#
# MACHINE STAGE PROTOCOL (D25) — identical wire contract to the static engine
# (emit() is shared via lib/site-deploy-common.sh):
#   BPSTAGE name=<PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE> status=<started|ok|skipped|noop|failed> build_id=<id> [detail="…"]
#
# --self-test  fixture releases + a FAKE systemctl (maps start/stop/is-active to
#              throwaway python http.server processes) + fake caddy/flock/npm PROVE
#              the marker-value HEALTH boot-in-place gate, the marker-anchored port
#              flip, retire, and the warm-rollback flip — offline, anywhere.
# --rollback / --rollback-preflight  as above.
#
# TYPED EXIT CODES:
#    0 success / no-op        11 missing required input
#    2 usage                  12 BUILD failed
#   10 missing site dir       13 STAGE failed (no standalone/)
#   14 HEALTH failed          15 gave up waiting for lock
#   16 SWITCH failed          21 rollback: no_previous
#   22 rollback: not_supported  23 rollback: lock held (deploy running)
#   24 rollback failed
#
# Env inputs (a caller — bp cloud site deploy — injects these):
#   SITE_SLUG          required. Names releases root, the /sites/<slug>/ route,
#                      and the systemd slot instance (<slug>__<slot>).
#   BUILD_ID           required (deploy). hash(code_rev+content_rev+config).
#   SITE_SRC           source dir to build. Default <site-root>/src
#   SITE_PORT_A / SITE_PORT_B  the site's two slot ports. A real caller allocates
#                      a UNIQUE pair per site (the central allocator is charter
#                      D12 backlog); default = a deterministic per-slug pair.
#   BARKPARK_SITES_DIR base dir for site roots. Default /opt/barkpark/sites
#   BARKPARK_SLOT_ENV_DIR  systemd EnvironmentFile dir. Default /opt/barkpark/.slots
#   BARKPARK_API_URL / BARKPARK_TOKEN / BARKPARK_DATASET / BARKPARK_WORKSPACE /
#   BARKPARK_PROJECT / BARKPARK_DOC_TYPE   passed to BUILD *and* baked into the
#                      slot env (SSR fetches content per request at RUNTIME too).
#   CONTENT_REV        dataset revision read at build (baked as bp-content-rev).
#   BARKPARK_CADDYFILE Caddyfile to arm/flip. Default /etc/caddy/Caddyfile
#   BARKPARK_NODE_LINK stable node symlink. Default /usr/local/bin/barkpark-node
#   BARKPARK_SITE_BASEPATH  set to 1 for a site whose framework BAKES a basePath
#                      of `/sites/<slug>` at build (multi-route Next apps — the
#                      search-starter — whose links/RSC fetches are root-absolute
#                      and would 404 if the prefix were stripped; charter D6).
#                      Two effects: Caddy arms a NON-stripping `handle` (keeps the
#                      prefix the app expects) instead of the default stripping
#                      `handle_path`, AND the HEALTH probe defaults to
#                      `/sites/<slug>/` (the app serves there even on the raw port).
#                      Default 0: a single-page next-starter sets no basePath and
#                      keeps the stripping handle_path + root probe.
#   BARKPARK_SITE_HEALTH_PATH  path to probe on the RAW node port (the probe hits
#                      127.0.0.1:<port> directly, bypassing Caddy). For a default
#                      (non-basePath) site Caddy's `handle_path /sites/<slug>/*`
#                      STRIPS the prefix and the app serves the marker page at
#                      ROOT, so the default is "/"; a basePath site
#                      (BARKPARK_SITE_BASEPATH=1) defaults to `/sites/<slug>/`.
#                      Set explicitly to override either default.
#   BARKPARK_HEALTH_HOST  live FQDN (for logging). Default guerrilla.barkpark.cloud
set -uo pipefail

SELF="${BASH_SOURCE[0]}"   # --self-test re-executes THIS script as the subject
BP_LOG_TAG="site-deploy-node"

# Shared primitives (charter D61): emit/BPSTAGE, valid_slug/valid_build_id,
# meta_value, BUILD_ALLOW, setup_caddy_lock/with_caddy_lock, log. site-deploy.sh
# sources the SAME file — the two engines cannot drift on the wire protocol, the
# marker reader, or the one shared Caddyfile lock.
# shellcheck source=deploy/lib/site-deploy-common.sh
. "$(cd "$(dirname "$SELF")" && pwd)/lib/site-deploy-common.sh"

# ---- Config ----------------------------------------------------------------
SITES_DIR="${BARKPARK_SITES_DIR:-/opt/barkpark/sites}"
SLOT_ENV_DIR="${BARKPARK_SLOT_ENV_DIR:-/opt/barkpark/.slots}"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
HEALTH_HOST="${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}"
NODE_LINK="${BARKPARK_NODE_LINK:-/usr/local/bin/barkpark-node}"
RETAIN="${BARKPARK_SITE_RETAIN:-5}"
HEALTH_FAIL_MARK=".bp-health-failed"
# basePath mode (charter D6): a framework that bakes basePath=/sites/<slug> serves
# EVERY route under that prefix, including on the raw node port — so Caddy must
# NOT strip the prefix (arm a `handle`, not `handle_path`) and the health probe
# hits the sub-path. Default OFF (the single-page next-starter sets no basePath).
SITE_BASEPATH="${BARKPARK_SITE_BASEPATH:-0}"
# The runtime env the SSR slot process needs (it fetches content per request).
# The per-site read token rides here, so slot env files are written 0600.
RUNTIME_ALLOW=(BARKPARK_API_URL BARKPARK_TOKEN BARKPARK_DATASET BARKPARK_WORKSPACE \
               BARKPARK_PROJECT BARKPARK_DOC_TYPE)

# ---- Mode dispatch ---------------------------------------------------------
MODE=deploy
case "${1:-}" in
  --rollback)           MODE=rollback ;;
  --rollback-preflight) MODE=preflight ;;
  --self-test)          MODE=selftest ;;
  "")                   MODE=deploy ;;
  *) log "unknown flag '${1}' (supported: --rollback, --rollback-preflight, --self-test)"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Slot primitives. Two slots per site — 'a' and 'b' — each a systemd instance
# barkpark-site@<slug>__<slot> driven by its EnvironmentFile
# <SLOT_ENV_DIR>/<slug>__<slot>.env (PORT + RELEASE_DIR). The ACTIVE slot is
# whichever port THIS site's Caddy marker block currently proxies to; a deploy
# targets the OTHER slot (blue/green), health-gates it, then flips Caddy.
#
# These operate on globals so --self-test exercises the SAME code the deploy runs
# (no fixture fork). systemctl/caddy do not exist on macOS: the self-test stubs
# them on PATH, so every call below stays a plain external command.
# ---------------------------------------------------------------------------
slot_inst()  { printf '%s__%s' "$SITE_SLUG" "$1"; }              # <slot> -> instance token
slot_port()  { [ "$1" = a ] && printf '%s' "$PORT_A" || printf '%s' "$PORT_B"; }
other_slot() { [ "$1" = a ] && printf b || printf a; }
slot_env()   { printf '%s/%s.env' "$SLOT_ENV_DIR" "$(slot_inst "$1")"; }

# The build_id a slot is configured for = basename of RELEASE_DIR in its env file.
read_slot_build() { # <slot> -> build_id or ""
  local f; f="$(slot_env "$1")"
  [ -f "$f" ] || return 0
  local rd; rd="$(grep -E '^RELEASE_DIR=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)"
  [ -n "$rd" ] && basename "$rd" || true
}

# Write (0600 — it holds the read token) a slot's EnvironmentFile: PORT + HOSTNAME
# so Next binds loopback, RELEASE_DIR so the unit's ExecStart/${RELEASE_DIR} finds
# server.js, plus the RUNTIME_ALLOW vars SSR needs per request.
write_slot_env() { # <slot> <build_id>
  local slot="$1" bid="$2" f v
  f="$(slot_env "$slot")"
  mkdir -p "$SLOT_ENV_DIR" 2>/dev/null || true
  {
    printf 'PORT=%s\n' "$(slot_port "$slot")"
    printf 'HOSTNAME=127.0.0.1\n'
    printf 'NODE_ENV=production\n'
    printf 'RELEASE_DIR=%s/%s\n' "$RELEASES" "$bid"
    printf 'BARKPARK_SITE_BASE=/sites/%s/\n' "$SITE_SLUG"
    [ -n "${CONTENT_REV:-}" ] && printf 'BARKPARK_CONTENT_REV=%s\n' "$CONTENT_REV"
    printf 'BARKPARK_BUILD_ID=%s\n' "$bid"
    for v in "${RUNTIME_ALLOW[@]}"; do
      [ -n "${!v:-}" ] && printf '%s=%s\n' "$v" "${!v}"
    done
  } > "$f"
  chmod 600 "$f" 2>/dev/null || true
}

# restart, NOT start: the target slot may be the warm-previous slot still running
# an OLD build — `systemctl start` is a no-op on an already-active unit and would
# leave it serving the old release with the new env unread, so HEALTH would read
# stale markers. restart forces it onto the freshly-written env + release. The
# target is always the IDLE (non-Caddy-active) slot, so this never touches live.
start_slot()   { systemctl restart "barkpark-site@$(slot_inst "$1")" 2>/dev/null; }
stop_slot()    { systemctl disable --now "barkpark-site@$(slot_inst "$1")" 2>/dev/null || \
                 systemctl stop "barkpark-site@$(slot_inst "$1")" 2>/dev/null || true; }
slot_running() { systemctl is-active --quiet "barkpark-site@$(slot_inst "$1")" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Marker-anchored per-site Caddy read: the ACTIVE upstream port is the one inside
# THIS site's marker block (BARKPARK_SITE_ROUTE:<slug>), never a global grep — two
# node sites can legitimately share a port literal elsewhere in the file, and the
# global sed instance-deploy.sh uses to flip its OWN slots would corrupt the wrong
# site here (RUN-proven). Empty = the route is not armed yet (first deploy).
# ---------------------------------------------------------------------------
active_caddy_port() {
  [ -f "$CADDYFILE" ] || return 0
  awk -v m="BARKPARK_SITE_ROUTE:$SITE_SLUG" '
    index($0, m) { inb = 1 }
    inb && match($0, /reverse_proxy[[:space:]]+localhost:[0-9]+/) {
      p = substr($0, RSTART, RLENGTH); sub(/.*localhost:/, "", p); print p; exit
    }
  ' "$CADDYFILE"
}
# Which slot (a|b) is live, from the active upstream port. Empty = none armed.
active_slot() {
  local p; p="$(active_caddy_port)"
  [ -z "$p" ] && return 0
  if [ "$p" = "$PORT_A" ]; then printf a
  elif [ "$p" = "$PORT_B" ]; then printf b
  fi
}

# Commit a rewritten Caddyfile: backup -> mv -> caddy validate -> reload, revert
# on any rejection. Runs under with_caddy_lock (the caller wraps it). 0 applied,
# 1 reverted.
commit_caddyfile() { # <tmp-newfile>
  local tmp="$1" bak
  bak="${CADDYFILE}.bak.node.${SITE_SLUG}.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  chmod --reference="$bak" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  chown --reference="$bak" "$tmp" 2>/dev/null || true
  mv "$tmp" "$CADDYFILE"
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then :; else log "caddy reload failed (config valid) — /sites/$SITE_SLUG live on next reload"; fi
    rm -f "$bak"; return 0
  fi
  log "caddy validate rejected the /sites/$SITE_SLUG change — reverting, Caddy untouched"
  mv "$bak" "$CADDYFILE"; return 1
}

# Arm the per-site node route ONCE (insert the marker block). Mirrors the static
# engine's arm_caddy_site_route anchor (before the first slot reverse_proxy, so
# the handle sits inside the live FQDN block) but proxies to a PORT, not a
# file_server. 0 armed/already-armed, 1 could-not-arm.
arm_caddy_node_route() { # <port>
  local port="$1" marker="BARKPARK_SITE_ROUTE:$SITE_SLUG"
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — cannot arm /sites/$SITE_SLUG"; return 1; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — cannot arm /sites/$SITE_SLUG"; return 1; }
  if grep -q "$marker" "$CADDYFILE"; then return 0; fi
  if ! grep -qE 'reverse_proxy[[:space:]]+localhost:(4000|4001)([[:space:]]|$)' "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — cannot arm /sites/$SITE_SLUG"
    return 1
  fi
  # A UNIQUE, alphanumeric matcher name for the bare-path redirect. Caddy matcher
  # names share the FQDN block, so derive one per slug; strip non-alnum so the
  # name is always valid (a slug hyphen is legal in a name but we normalise).
  local mname
  mname="bare_$(printf '%s' "$SITE_SLUG" | tr -cd 'A-Za-z0-9')"
  # basePath sites need a NON-stripping `handle` — Caddy keeps the /sites/<slug>
  # prefix the app's baked basePath expects on every route (charter D6). The
  # default single-page site uses the stripping `handle_path` (the app serves at
  # root). Set ONCE at arm time; a later port flip only rewrites reverse_proxy.
  local route_handle="handle_path"
  [ "$SITE_BASEPATH" = 1 ] && route_handle="handle"
  local block
  if [ "$SITE_BASEPATH" = 1 ]; then
    # basePath site: the app OWNS canonicalization (Next 308s `${basePath}/` ->
    # `${basePath}`, proven live), so Caddy must NOT arm a bare->slash redir —
    # the pair would 308 each other forever. Instead the matcher covers the bare
    # path AND the subtree, and everything proxies through un-stripped.
    block="$(cat <<SITEROUTE
	# $marker — node SSR site '$SITE_SLUG' (basePath), reverse-proxied un-stripped.
	# No bare-path redir: the baked basePath canonicalizes slash -> bare itself;
	# a Caddy bare -> slash redir would form a 308 loop with it. (NB: heredoc
	# comments must not carry unpaired apostrophes; bash 3.2 mis-scans them
	# inside command substitution.)
	@$mname path /sites/$SITE_SLUG /sites/$SITE_SLUG/*
	handle @$mname {
		reverse_proxy localhost:$port
	}
SITEROUTE
)"
  else
    block="$(cat <<SITEROUTE
	# $marker — node SSR site '$SITE_SLUG', reverse-proxied to its active slot.
	# The bare path (no trailing slash) does NOT match the handle, so redirect it
	# to the canonical slashed form via an EXACT 'path' matcher (never a prefix, so
	# it can never swallow the asset requests the handle serves).
	@$mname path /sites/$SITE_SLUG
	redir @$mname /sites/$SITE_SLUG/ 308
	$route_handle /sites/$SITE_SLUG/* {
		reverse_proxy localhost:$port
	}
SITEROUTE
)"
  fi
  local tmp; tmp="$(mktemp)"
  BP_BLOCK="$block" awk '
    BEGIN { blk = ENVIRON["BP_BLOCK"] }
    !ins && $0 ~ /reverse_proxy[[:blank:]]+localhost:(4000|4001)([[:blank:]]|$)/ { print blk; ins = 1 }
    { print }
  ' "$CADDYFILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  commit_caddyfile "$tmp"
}

# Flip the reverse_proxy port INSIDE this site's marker block, in place. Replaces
# ONLY the first reverse_proxy localhost:<port> after the marker — never a global
# sed. 0 flipped, 1 rejected/reverted.
flip_caddy_node_port() { # <new-port>
  local port="$1" marker="BARKPARK_SITE_ROUTE:$SITE_SLUG"
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — cannot flip /sites/$SITE_SLUG"; return 1; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — cannot flip /sites/$SITE_SLUG"; return 1; }
  grep -q "$marker" "$CADDYFILE" || { log "no $marker block in $CADDYFILE — cannot flip"; return 1; }
  local tmp; tmp="$(mktemp)"
  awk -v m="$marker" -v p="$port" '
    index($0, m) { inb = 1 }
    inb && !done && $0 ~ /reverse_proxy[[:blank:]]+localhost:[0-9]+/ {
      sub(/localhost:[0-9]+/, "localhost:" p); inb = 0; done = 1
    }
    { print }
  ' "$CADDYFILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  commit_caddyfile "$tmp"
}

# ---------------------------------------------------------------------------
# HEALTH (D65) — boot the target slot IN PLACE and gate on the RUNNING process.
# Writes the slot env for build $2, starts the slot, polls its port to a >=10s
# deadline (a process needs ~1.5s to first-200; the Next "Ready" log lies), then
# asserts the served bytes carry THIS build's markers by value. On any failure it
# stops the just-booted slot and NEVER touches the live slot or Caddy. Sets
# HEALTH_DETAIL either way (rides the BPSTAGE line).
# ---------------------------------------------------------------------------
HEALTH_DETAIL=""
health_gate_node() { # <slot> <build_id> -> 0 healthy, 1 not
  HEALTH_DETAIL=""
  local slot="$1" bid="$2" port inst path
  port="$(slot_port "$slot")"; inst="$(slot_inst "$slot")"
  # The probe hits the raw node port directly (below), bypassing Caddy. For a
  # default (non-basePath) site Caddy's `handle_path /sites/<slug>/*` strips the
  # prefix and the app serves the marker page at ROOT — probe "/". A basePath
  # site (SITE_BASEPATH=1) bakes basePath=/sites/<slug>, so the app serves there
  # even on the raw port — probe the sub-path. BARKPARK_SITE_HEALTH_PATH overrides
  # either default explicitly.
  if [ -n "${BARKPARK_SITE_HEALTH_PATH:-}" ]; then
    path="$BARKPARK_SITE_HEALTH_PATH"
  elif [ "$SITE_BASEPATH" = 1 ]; then
    path="/sites/$SITE_SLUG/"
  else
    path="/"
  fi
  [ "${path#/}" = "$path" ] && path="/$path"

  if [ ! -f "$RELEASES/$bid/server.js" ]; then
    HEALTH_DETAIL="releases/$bid has no server.js — not a node standalone release"
    log "HEALTH: $HEALTH_DETAIL — refusing to boot"; return 1
  fi

  write_slot_env "$slot" "$bid"
  if ! start_slot "$slot"; then
    stop_slot "$slot"
    HEALTH_DETAIL="systemctl start barkpark-site@$inst failed — the node process would not boot"
    log "HEALTH: $HEALTH_DETAIL"; return 1
  fi

  local body code=000 i curl_rc=0 t_total=""
  body="$(mktemp "${TMPDIR:-/tmp}/site-node-health.XXXXXX")"
  # 20 attempts, 8s ceiling each, >=20s wall minimum (D65 raised for SSR): a
  # force-dynamic SSR page fetches content per request, and a 2s per-attempt
  # ceiling made EVERY probe abort mid-render — curl then reports the last
  # COMPLETED hop, so a basePath site read as an eternal 308 (proven live:
  # search-capstone b-…-stw1d "308 within 12s" while the slot rendered 200 in
  # ~1s when probed without the ceiling; HEALTH burned 60x2s = 131s, and the
  # "12s deadline" comment was a lie in node mode). The overall bound stays
  # finite: worst case 20*(8+0.5)s = 170s, and a healthy slot passes on the
  # first sub-second attempt.
  for i in $(seq 1 20); do
    # -L --max-redirs 2: canonicalization is framework-owned. Next with a baked
    # basePath 308s `${basePath}/` -> `${basePath}` (proven live: search-capstone
    # b-…-stw1c HEALTH read 308 at /sites/<slug>/), while a plain static server
    # 301s bare -> slashed. Follow up to 2 loopback hops and gate on the FINAL
    # code — the marker-by-value assertion below still proves the served bytes.
    out="$(curl -sL --max-redirs 2 -o "$body" -w '%{http_code} %{time_total}' --connect-timeout 2 --max-time 8 "http://127.0.0.1:$port$path" 2>/dev/null)"; curl_rc=$?
    code="${out%% *}"; t_total="${out##* }"; [ -n "$code" ] || code=000
    [ "$code" = 200 ] && break
    sleep 0.5
  done
  if [ "$code" != 200 ]; then
    rm -f "$body"; stop_slot "$slot"
    HEALTH_DETAIL="slot $slot on :$port returned $code (want 200) at $path after $i attempts (last: curl exit $curl_rc, ${t_total}s) — boot failed, live slot untouched"
    log "HEALTH: $HEALTH_DETAIL"; return 1
  fi

  local got_build got_rev got_doc
  got_build="$(meta_value "$body" bp-build-id)"
  got_rev="$(meta_value "$body" bp-content-rev)"
  got_doc="$(meta_value "$body" bp-doc-id)"
  rm -f "$body"
  if [ "$got_build" != "$bid" ]; then
    stop_slot "$slot"
    HEALTH_DETAIL="bp-build-id marker is '${got_build:-<missing>}' but this deploy ships '$bid' — the served SSR is not this build"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -z "$got_rev" ]; then
    stop_slot "$slot"
    HEALTH_DETAIL="bp-content-rev marker is empty — the build lost its content link"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -n "${CONTENT_REV:-}" ] && [ "$got_rev" != "$CONTENT_REV" ]; then
    stop_slot "$slot"
    HEALTH_DETAIL="bp-content-rev marker is '$got_rev' but this deploy ships content_rev '$CONTENT_REV'"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -z "$got_doc" ]; then
    stop_slot "$slot"
    HEALTH_DETAIL="bp-doc-id marker is empty — the SSR rendered no content document"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  HEALTH_DETAIL="200 + bp-build-id=$got_build bp-content-rev=$got_rev bp-doc-id=$got_doc (slot $slot :$port)"
  log "HEALTH: $HEALTH_DETAIL"
  return 0
}

# A HEALTH-failed release must never stay staged so PLAN accepts it forever. Purge
# it — unless it is a build a live/previous slot still points at (deleting those
# bytes would break the rollback path): keep + drop the poison marker PLAN refuses.
purge_failed_release_node() { # <build_id>
  local bid="$1" act_slot act_build="" p_build=""
  # Protect what is genuinely LIVE — the ACTIVE Caddy slot's build + the warm
  # previous — NOT the target slot's env, which the just-failed boot rewrote to
  # this build_id (that would falsely protect the poison and never purge it).
  act_slot="$(active_slot)"
  [ -n "$act_slot" ] && act_build="$(read_slot_build "$act_slot")"
  [ -f "$ROOT/.previous" ] && p_build="$(awk '{print $3}' "$ROOT/.previous" 2>/dev/null || true)"
  if [ -d "$RELEASES/$bid" ] && { [ "$bid" = "$act_build" ] || [ "$bid" = "$p_build" ]; }; then
    : > "$RELEASES/$bid/$HEALTH_FAIL_MARK" 2>/dev/null || true
    log "HEALTH: release $bid is a live/rollback target — keeping its bytes, marking it health-failed (a redeploy REBUILDS it)"
    return 0
  fi
  rm -rf "${RELEASES:?}/$bid"
  log "HEALTH: purged releases/$bid — a redeploy of this build_id rebuilds from source instead of re-gating broken bytes"
}

# RETIRE (D67): keep the current + previous slot RUNNING (warm, for <1s rollback);
# stop any other slot; prune release dirs to the newest RETAIN, never removing a
# build a live or previous slot still points at.
RETIRED=0
do_retire_node() { # <current-slot>
  RETIRED=0
  local cur="$1" prev_slot="" other keepa keepb keepp
  other="$(other_slot "$cur")"
  [ -f "$ROOT/.previous" ] && prev_slot="$(awk '{print $1}' "$ROOT/.previous" 2>/dev/null || true)"
  # Stop any slot that is neither current nor the warm previous.
  if [ "$other" != "$prev_slot" ]; then
    slot_running "$other" && { stop_slot "$other"; log "RETIRE: stopped cold slot $other (kept only current + warm previous)"; }
  fi
  # Prune release dirs — protect the builds the two live slots + .previous hold.
  [ -d "$RELEASES" ] || return 0
  keepa="$(read_slot_build a)"; keepb="$(read_slot_build b)"
  keepp=""; [ -f "$ROOT/.previous" ] && keepp="$(awk '{print $3}' "$ROOT/.previous" 2>/dev/null || true)"
  local d id i=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    id="$(basename "$d")"
    i=$((i + 1))
    [ "$i" -le "$RETAIN" ] && continue
    [ "$id" = "$keepa" ] && continue
    [ "$id" = "$keepb" ] && continue
    [ "$id" = "$keepp" ] && continue
    if rm -rf "$d"; then RETIRED=$((RETIRED + 1)); log "RETIRE: removed old release $id"; fi
  done < <(ls -1dt "$RELEASES"/*/ 2>/dev/null)
}

# Best-effort: materialise /usr/local/bin/barkpark-node -> the asdf node (NEVER
# the shim: an asdf shim with no version set exits non-zero and would crash-loop
# the slot unit). Mirrors instance-deploy.sh resolve_node_bin. Non-fatal — if node
# cannot be resolved the slot simply fails HEALTH (fail closed).
# Place the resolved node binary AT $NODE_LINK as a real file — a COPY, never a
# symlink. asdf installs node under $HOME/.asdf (i.e. /root/.asdf for the deploy
# user), but the slot unit hardens with ProtectHome=yes, which hides /root inside
# the service's mount namespace — so a symlinked ExecStart resolves to a node
# under the now-invisible /root and dies 203/EXEC ("Failed to execute"). Node is a
# single self-contained ~150M binary (bundled ICU etc.), so a copy outside /root
# runs standalone and keeps ProtectHome=yes intact (tenant SSR code cannot read
# /root/.ssh, secrets, …). Copy only when the bytes differ, so a redeploy on an
# unchanged node version is a cheap no-op. (BindReadOnlyPaths=/root/.asdf does NOT
# help — the ProtectHome tmpfs over /root shadows the bind.)
place_node() { # <src node binary>
  local src="$1"
  [ -n "$src" ] && [ -x "$src" ] || return 1
  if [ ! -e "$NODE_LINK" ] || [ -L "$NODE_LINK" ] || ! cmp -s "$src" "$NODE_LINK"; then
    install -m 0755 "$src" "$NODE_LINK.tmp.$$" 2>/dev/null || return 1
    mv -f "$NODE_LINK.tmp.$$" "$NODE_LINK" 2>/dev/null || { rm -f "$NODE_LINK.tmp.$$"; return 1; }
  fi
  return 0
}

ensure_node_link() {
  local d b
  if command -v asdf >/dev/null 2>&1; then
    d="$(asdf where nodejs 2>/dev/null || true)"
    [ -n "$d" ] && place_node "$d/bin/node" && return 0
  fi
  # shellcheck disable=SC2012  # asdf install dirs are version strings, ls|sort -V is the right tool (mirrors instance-deploy.sh)
  b="$(ls -1d "$HOME"/.asdf/installs/nodejs/*/bin/node 2>/dev/null | sort -V | tail -1)"
  [ -n "$b" ] && place_node "$b" && return 0
  b="$(command -v node 2>/dev/null || true)"
  [ -n "$b" ] && "$b" -v >/dev/null 2>&1 && place_node "$b" && return 0
  log "WARN: no usable node (asdf nodejs not installed, none on PATH) — $NODE_LINK not refreshed; the slot will fail HEALTH if it cannot start"
  return 0
}

# ===========================================================================
# SELF-TEST — fixtures + fake systemctl/caddy/flock/npm; proves the real
# primitives (boot-in-place HEALTH, the marker-anchored flip, retire, warm
# rollback), no real systemd/caddy/network.
# ===========================================================================
if [ "$MODE" = selftest ]; then
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "[selftest] SKIP — needs python3 + curl (the fake slot http server)"; echo "[selftest] PASS"; exit 0
  fi

  TESTS=0; FAILS=0
  check() { local label="$1"; shift; TESTS=$((TESTS + 1)); if "$@"; then echo "  ok   - $label"; else echo "  FAIL - $label"; FAILS=$((FAILS + 1)); fi; }

  TD="$(mktemp -d "${TMPDIR:-/tmp}/site-deploy-node-selftest.XXXXXX")"
  # Kill any slot http servers the fake systemctl left running.
  # shellcheck disable=SC2154  # pf is the for-loop var inside the (deferred) trap body
  trap 'for pf in "$TD"/slotpids/*; do [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null; done; rm -rf "$TD"' EXIT

  # Two free loopback ports for the two slots.
  free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
  T_PORT_A="$(free_port)"; T_PORT_B="$(free_port)"; T_PORT_C="$(free_port)"; T_PORT_D="$(free_port)"
  T_PORT_E="$(free_port)"; T_PORT_F="$(free_port)"   # basePath site's two slots

  FAKEBIN="$TD/bin"; SLOTPIDS="$TD/slotpids"; SENV="$TD/slots"; SRC="$TD/src"
  mkdir -p "$FAKEBIN" "$SLOTPIDS" "$SENV" "$SRC"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/flock"
  # Fake caddy: validate always passes (a real box runs the real binary).
  # shellcheck disable=SC2016  # $1 is the fake script's own arg — must NOT expand here
  printf '#!/usr/bin/env bash\ncase "$1" in validate) exit 0;; *) exit 0;; esac\n' > "$FAKEBIN/caddy"
  # Fake systemctl: map start/stop/is-active for barkpark-site@<inst> to throwaway
  # python http.server processes rooted at the slot env's RELEASE_DIR on its PORT,
  # so the REAL health_gate_node code gates a REAL http endpoint offline.
  cat > "$FAKEBIN/systemctl" <<SYSCTL
#!/usr/bin/env bash
SENVDIR="$SENV"; PIDDIR="$SLOTPIDS"
verb="\${1:-}"
case "\$verb" in
  is-active) shift; [ "\${1:-}" = --quiet ] && shift; unit="\${1:-}";;
  reload|daemon-reload) exit 0;;
  start|restart|stop) shift; unit="\${1:-}";;
  disable) shift; [ "\${1:-}" = --now ] && shift; unit="\${1:-}"; verb=stop;;
  *) unit="\${2:-}";;
esac
inst="\${unit#barkpark-site@}"; pidf="\$PIDDIR/\$inst"
case "\$verb" in
  start|restart)
    # Model real systemd: 'start' is a NO-OP on an already-active unit (it would
    # NOT pick up a rewritten EnvironmentFile) — only 'restart' relaunches. This
    # is what makes the test PROVE start_slot must use restart on a warm slot.
    if [ "\$verb" = start ] && [ -f "\$pidf" ] && kill -0 "\$(cat "\$pidf")" 2>/dev/null; then exit 0; fi
    [ -f "\$pidf" ] && { kill "\$(cat "\$pidf")" 2>/dev/null; rm -f "\$pidf"; }
    envf="\$SENVDIR/\$inst.env"
    port="\$(grep -E '^PORT=' "\$envf" | cut -d= -f2)"
    rel="\$(grep -E '^RELEASE_DIR=' "\$envf" | cut -d= -f2-)"
    [ -n "\$port" ] && [ -d "\$rel" ] || exit 1
    python3 -m http.server "\$port" --bind 127.0.0.1 --directory "\$rel" >/dev/null 2>&1 &
    echo \$! > "\$pidf"; exit 0;;
  stop)
    [ -f "\$pidf" ] && { kill "\$(cat "\$pidf")" 2>/dev/null; rm -f "\$pidf"; }; exit 0;;
  is-active)
    [ -f "\$pidf" ] && kill -0 "\$(cat "\$pidf")" 2>/dev/null && exit 0; exit 1;;
esac
exit 0
SYSCTL
  # Fake npm: `ci` no-ops; `run build` emits a Next standalone layout carrying the
  # markers the health gate asserts. Lie/fail switches ride in FILES in the source
  # dir (cwd is the one channel the env scrub cannot close).
  cat > "$FAKEBIN/npm" <<'FAKENPM'
#!/usr/bin/env bash
echo "npm $*" >> ./.npm-calls
[ "${1:-}" = ci ] && exit 0
if [ -f ./.fail-build ]; then
  echo "npm ERR! code ELIFECYCLE" >&2
  echo "FATAL: 401 Unauthorized from https://guerrilla.barkpark.cloud/w/acme/p/blog — the site read token is invalid" >&2
  exit 1
fi
bid="${BARKPARK_BUILD_ID:-}"; rev="${BARKPARK_CONTENT_REV:-}"; doc="doc-42"
[ -f ./.lie ] && { bid=TOTALLY-WRONG; rev=""; }
mkdir -p .next/standalone .next/static public
printf '// fake next standalone server\n' > .next/standalone/server.js
{
  printf '<!doctype html><html><head>\n'
  printf '<meta name="bp-build-id" content="%s">\n' "$bid"
  printf '<meta name="bp-content-rev" content="%s">\n' "$rev"
  printf '<meta name="bp-doc-id" content="%s">\n' "$doc"
  printf '</head><body><h1>SSR</h1></body></html>\n'
} > .next/standalone/index.html
printf 'chunk\n' > .next/static/chunk.js
printf 'robots\n' > public/robots.txt
# basePath mode: an app built with basePath=/sites/<slug> serves its marker page
# UNDER that prefix even on the raw node port — so also emit the index there, so
# the real health_gate_node probing /sites/<slug>/ gets 200 + markers.
if [ -f ./.basepath ] && [ -n "${BARKPARK_SITE_BASE:-}" ]; then
  sub=".next/standalone${BARKPARK_SITE_BASE}"
  mkdir -p "$sub"
  cp .next/standalone/index.html "${sub}index.html"
fi
exit 0
FAKENPM
  chmod +x "$FAKEBIN"/*
  printf '{"name":"selftest-node-site","private":true}\n' > "$SRC/package.json"

  # A Caddyfile with a live slot anchor (guerrilla blue/green :4000) so the node
  # route can arm inside the FQDN block.
  CF="$TD/Caddyfile"
  printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$CF"

  N_SITE="$TD/sites/selftest"
  e2e_deploy() { # <build_id> [extra-env...] -> exit code; logs at $TD/out.log/err.log
    env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=selftest BUILD_ID="$1" CONTENT_REV="${E2E_REV:-rev-1}" \
      SITE_SRC="$SRC" SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
      BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_NODE_LINK="$TD/barkpark-node" \
      BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" "${@:2}" > "$TD/out.log" 2> "$TD/err.log"
    # NB: BARKPARK_SITE_HEALTH_PATH is deliberately NOT set here — the main deploy
    # path exercises the DEFAULT ("/"), which is what a real box uses (Caddy
    # handle_path strips the /sites/<slug>/ prefix; the node process serves root).
    echo $?
  }
  e2e_rollback() {
    env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=selftest SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
      BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_SITE_HEALTH_PATH=/ BARKPARK_NODE_LINK="$TD/barkpark-node" \
      BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" --rollback > "$TD/out.log" 2> "$TD/err.log"
    echo $?
  }
  saw()   { grep -q "^BPSTAGE name=$1 status=$2 build_id=$3" "$TD/out.log"; }
  nosaw() { ! grep -q "^BPSTAGE name=$1 " "$TD/out.log"; }
  cf_port() { awk -v m="BARKPARK_SITE_ROUTE:selftest" 'index($0,m){i=1} i&&match($0,/localhost:[0-9]+/){p=substr($0,RSTART+10,RLENGTH-10);print p;exit}' "$CF"; }

  echo "[selftest] e2e: first deploy boots slot a, gates it, arms Caddy to :A, walks six stages"
  rc="$(e2e_deploy n1)"
  check "first deploy exit 0"            [ "$rc" = 0 ]
  check "PLAN ok"                        saw PLAN ok n1
  check "BUILD ok"                       saw BUILD ok n1
  check "STAGE ok"                       saw STAGE ok n1
  check "HEALTH started"                 saw HEALTH started n1
  check "HEALTH ok"                      saw HEALTH ok n1
  check "SWITCH ok"                      saw SWITCH ok n1
  check "RETIRE ok"                      saw RETIRE ok n1
  check "release has server.js"          [ -f "$N_SITE/releases/n1/server.js" ]
  check "STAGE pulled .next/static in"   [ -f "$N_SITE/releases/n1/.next/static/chunk.js" ]
  check "STAGE pulled public/ in"        [ -f "$N_SITE/releases/n1/public/robots.txt" ]
  check "Caddy armed to slot a :A"       [ "$(cf_port)" = "$T_PORT_A" ]
  check "slot a env RELEASE_DIR=n1"      grep -q "RELEASE_DIR=$N_SITE/releases/n1" "$SENV/selftest__a.env"
  check "slot a env is 0600"             [ "$(stat -f '%Lp' "$SENV/selftest__a.env" 2>/dev/null || stat -c '%a' "$SENV/selftest__a.env")" = 600 ]
  check "npm really ran"                 grep -q 'npm run build' "$SRC/.npm-calls"

  echo "[selftest] e2e: a no-op redeploy of the live build speaks on every stage"
  : > "$SRC/.npm-calls"
  rc="$(e2e_deploy n1)"
  check "no-op exit 0"                   [ "$rc" = 0 ]
  check "PLAN noop"                      saw PLAN noop n1
  check "no-op BUILD skipped"            saw BUILD skipped n1
  check "no-op built nothing"            [ ! -s "$SRC/.npm-calls" ]
  check "Caddy still :A"                 [ "$(cf_port)" = "$T_PORT_A" ]

  echo "[selftest] e2e: a second build boots slot b, gates it, FLIPS Caddy :A->:B (blue/green)"
  rc="$(E2E_REV=rev-2 e2e_deploy n2)"
  check "second deploy exit 0"           [ "$rc" = 0 ]
  check "HEALTH ok on the new slot"      saw HEALTH ok n2
  check "SWITCH ok"                      saw SWITCH ok n2
  check "Caddy flipped to slot b :B"     [ "$(cf_port)" = "$T_PORT_B" ]
  check "marker block flipped in place, single reverse_proxy inside it" \
    [ "$(awk 'index($0,"BARKPARK_SITE_ROUTE:selftest"){i=1} i&&/reverse_proxy/{c++} i&&/}/{i=0} END{print c+0}' "$CF")" = 1 ]
  check "old port :A fully gone from the marker block" \
    [ "$(awk 'index($0,"BARKPARK_SITE_ROUTE:selftest"){i=1} i&&/localhost:'"$T_PORT_A"'/{c++} i&&/}/{i=0} END{print c+0}' "$CF")" = 0 ]
  check ".previous records slot a + n1"  grep -q "^a $T_PORT_A n1$" "$N_SITE/.previous"
  check "slot a (previous) kept WARM"    env PATH="$FAKEBIN:$PATH" systemctl is-active --quiet barkpark-site@selftest__a
  check "slot b now serves n2"           grep -q "RELEASE_DIR=$N_SITE/releases/n2" "$SENV/selftest__b.env"

  echo "[selftest] e2e: WARM rollback is a pure Caddy port flip back (<1s, no reboot)"
  rc="$(e2e_rollback)"
  check "rollback exit 0"                [ "$rc" = 0 ]
  check "Caddy flipped back to :A"       [ "$(cf_port)" = "$T_PORT_A" ]
  check "rollback did NOT rebuild"       [ ! -f "$SRC/.rollback-built" ]
  check ".previous now points at slot b n2" grep -q "^b $T_PORT_B n2$" "$N_SITE/.previous"

  echo "[selftest] e2e: a LYING build fails HEALTH (14), never flips, is PURGED, live slot untouched"
  before_port="$(cf_port)"
  : > "$SRC/.lie"
  rc="$(e2e_deploy n3)"
  rm -f "$SRC/.lie"
  check "lying build exit 14"            [ "$rc" = 14 ]
  check "HEALTH failed"                  saw HEALTH failed n3
  check "reason names the wrong marker"  grep -q "bp-build-id marker is .TOTALLY-WRONG" "$TD/out.log"
  check "no SWITCH stage line at all"    nosaw SWITCH
  check "Caddy upstream did NOT move"    [ "$(cf_port)" = "$before_port" ]
  check "the poisoned release is purged" [ ! -d "$N_SITE/releases/n3" ]
  # shellcheck disable=SC2016  # $PATH must expand inside sh -c at run time, not now
  check "the just-booted bad slot is stopped" \
    sh -c '! env PATH="'"$FAKEBIN"':$PATH" systemctl is-active --quiet barkpark-site@selftest__b'

  echo "[selftest] e2e: a BUILD failure carries its 401 reason on STDOUT, exit 12, no flip"
  : > "$SRC/.fail-build"
  before_port="$(cf_port)"
  rc="$(e2e_deploy n4)"
  rm -f "$SRC/.fail-build"
  check "build failure exit 12"          [ "$rc" = 12 ]
  check "BUILD failed"                   saw BUILD failed n4
  check "401 rides the stage line"       grep -q '^BPSTAGE name=BUILD status=failed .*401 Unauthorized' "$TD/out.log"
  check "no SWITCH stage line at all"    nosaw SWITCH
  check "Caddy upstream did NOT move"    [ "$(cf_port)" = "$before_port" ]
  check "no release dir left behind"     [ ! -d "$N_SITE/releases/n4" ]

  echo "[selftest] e2e: RETIRE prunes old release dirs, protecting both live slots"
  # current live = slot a (n1) after the rollback; previous = slot b (n2). Deploy a
  # burst with RETAIN=1 and confirm neither live build's dir is ever removed.
  rc="$(BARKPARK_SITE_RETAIN=1 E2E_REV=rev-5 e2e_deploy n5)"   # boots slot b (n5), flips to it
  check "retain=1 deploy exit 0"         [ "$rc" = 0 ]
  check "n1 (slot a, now warm-previous) survives retire" [ -d "$N_SITE/releases/n1" ]
  check "n5 (slot b, current) survives retire"           [ -d "$N_SITE/releases/n5" ]

  echo "[selftest] e2e: redeploy onto a WARM previous slot serves the NEW build (restart, not start); two sites coexist in one Caddyfile (D66)"
  sel_port_before="$(cf_port)"
  w_deploy() { # <build_id> <rev>
    env PATH="$FAKEBIN:$PATH" SITE_SLUG=warm BUILD_ID="$1" CONTENT_REV="$2" \
      SITE_SRC="$SRC" SITE_PORT_A="$T_PORT_C" SITE_PORT_B="$T_PORT_D" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/warm.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_SITE_HEALTH_PATH=/ BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" >/dev/null 2>&1; echo $?
  }
  w_cf_port() { awk 'index($0,"BARKPARK_SITE_ROUTE:warm"){i=1} i&&match($0,/localhost:[0-9]+/){print substr($0,RSTART+10,RLENGTH-10);exit}' "$CF"; }
  rc="$(w_deploy w1 r1)"; check "warm w1 (slot a) exit 0" [ "$rc" = 0 ]
  rc="$(w_deploy w2 r2)"; check "warm w2 (slot b) exit 0" [ "$rc" = 0 ]
  check "warm Caddy on :D (slot b)"            [ "$(w_cf_port)" = "$T_PORT_D" ]
  check "warm slot a kept warm (running w1)"   env PATH="$FAKEBIN:$PATH" systemctl is-active --quiet barkpark-site@warm__a
  # w3 TARGETS slot a — the warm-previous slot still running w1. `systemctl start`
  # would be a no-op and HEALTH would read w1's stale markers (bp-build-id=w1!=w3);
  # only `restart` forces slot a onto w3.
  rc="$(w_deploy w3 r3)"; check "warm w3 onto the warm slot a exit 0 (restart picked up new release)" [ "$rc" = 0 ]
  check "warm Caddy flipped to :C (slot a) serving w3" [ "$(w_cf_port)" = "$T_PORT_C" ]
  check "warm slot a env now RELEASE_DIR=w3"   grep -q "RELEASE_DIR=$TD/sites/warm/releases/w3" "$SENV/warm__a.env"
  check "the OTHER site's Caddy block was NOT touched by the warm deploys (D66 per-site isolation)" \
    [ "$(cf_port)" = "$sel_port_before" ]

  echo "[selftest] e2e: a basePath site arms a NON-stripping 'handle' + health-probes the sub-path (D6)"
  # BARKPARK_SITE_BASEPATH=1 + a .basepath sentinel (so the fake npm also emits the
  # marker page under /sites/basepath/) — the health probe must default to the
  # sub-path and Caddy must arm `handle` (keeps the prefix), not `handle_path`.
  : > "$SRC/.basepath"
  bp_deploy() { # <build_id>
    env PATH="$FAKEBIN:$PATH" SITE_SLUG=basepath BUILD_ID="$1" CONTENT_REV=bp-rev \
      SITE_SRC="$SRC" SITE_PORT_A="$T_PORT_E" SITE_PORT_B="$T_PORT_F" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/basepath.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_SITE_BASEPATH=1 BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" > "$TD/out.log" 2> "$TD/err.log"; echo $?
    # NB: BARKPARK_SITE_HEALTH_PATH is deliberately NOT set — the basePath DEFAULT
    # (/sites/basepath/) is what a real basePath site relies on.
  }
  rc="$(bp_deploy bp1)"
  rm -f "$SRC/.basepath"
  check "basePath deploy exit 0"               [ "$rc" = 0 ]
  check "basePath HEALTH ok (probed the sub-path)" saw HEALTH ok bp1
  check "SWITCH ok"                            saw SWITCH ok bp1
  check "armed the two-path basePath matcher (bare + subtree)" \
    grep -qF '@bare_basepath path /sites/basepath /sites/basepath/*' "$CF"
  check "armed a NON-stripping 'handle @bare_basepath'" \
    grep -qF 'handle @bare_basepath' "$CF"
  check "did NOT arm a bare->slash redir (would 308-loop with the app's own canonicalization)" \
    sh -c "! grep -qF 'redir @bare_basepath' '$CF'"
  check "did NOT arm a stripping handle_path for basepath" \
    sh -c "! grep -qF 'handle_path /sites/basepath/*' '$CF'"

  echo "[selftest] e2e: the src-tree .basepath MARKER alone (no env) activates basePath mode (self-describing template)"
  # The real engine path: the provisioner materializes a template that SHIPS
  # .basepath; the runner passes no BARKPARK_SITE_BASEPATH env. The deploy must
  # behave exactly like the env-armed case — probe the sub-path, keep `handle`.
  : > "$SRC/.basepath"
  bpm_deploy() { # <build_id>
    env PATH="$FAKEBIN:$PATH" SITE_SLUG=basepath BUILD_ID="$1" CONTENT_REV=bpm-rev \
      SITE_SRC="$SRC" SITE_PORT_A="$T_PORT_E" SITE_PORT_B="$T_PORT_F" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/basepath.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" > "$TD/out.log" 2> "$TD/err.log"; echo $?
  }
  rc="$(bpm_deploy bpm1)"
  rm -f "$SRC/.basepath"
  check "marker-only deploy exit 0"            [ "$rc" = 0 ]
  check "marker-only HEALTH ok (probed the sub-path)" saw HEALTH ok bpm1
  check "marker-only kept the NON-stripping 'handle @bare_basepath'" \
    grep -qF 'handle @bare_basepath' "$CF"
  check "marker-only did NOT arm handle_path" \
    sh -c "! grep -qF 'handle_path /sites/basepath/*' '$CF'"

  echo "[selftest] rollback preflight is read-only + typed"
  # Fresh site with no previous -> not_supported / no_previous.
  rc="$(env PATH="$FAKEBIN:$PATH" SITE_SLUG=fresh SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
        BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
        BARKPARK_SITE_DEPLOY_LOCK="$TD/fresh.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
        bash "$SELF" --rollback-preflight >/dev/null 2>&1; echo $?)"
  check "preflight on a never-deployed site refuses (22)" [ "$rc" = 22 ]

  echo ""
  echo "[selftest] $((TESTS - FAILS))/$TESTS checks passed"
  [ "$FAILS" -eq 0 ] || { echo "[selftest] FAILED ($FAILS)"; exit 1; }
  echo "[selftest] PASS"
  exit 0
fi

# ---------------------------------------------------------------------------
# From here on: real deploy/rollback modes need SITE_SLUG + a live layout.
# ---------------------------------------------------------------------------
SITE_SLUG="${SITE_SLUG:-}"
if [ -z "$SITE_SLUG" ]; then log "SITE_SLUG is required"; exit 11; fi
if ! valid_slug "$SITE_SLUG"; then
  log "invalid SITE_SLUG '$SITE_SLUG' (want ^[a-z0-9][a-z0-9-]{0,62}\$)"; exit 11
fi

ROOT="$SITES_DIR/$SITE_SLUG"
RELEASES="$ROOT/releases"
SITE_SRC="${SITE_SRC:-$ROOT/src}"
# Self-describing basePath (search-template W1 live-proof fix): a template that
# bakes basePath ships a `.basepath` marker in its tree, so no caller-side env
# plumbing is needed — the source itself declares how it must be served (Caddy
# `handle`, no strip) and probed (HEALTH at the sub-path). An explicit
# BARKPARK_SITE_BASEPATH env always wins. Without this, a basePath app 404s the
# HEALTH probe at `/` and the deploy fail-closes (proven live: search-capstone
# b-20260716040040-stw1, HEALTH "slot a returned 404 (want 200) at /").
if [ "${BARKPARK_SITE_BASEPATH+x}" != x ] && [ -f "$SITE_SRC/.basepath" ]; then
  SITE_BASEPATH=1
fi
LOCK="${BARKPARK_SITE_DEPLOY_LOCK:-/var/lock/barkpark-site-deploy-$SITE_SLUG.lock}"

# Per-site slot ports. A real caller injects a UNIQUE pair per site; absent one,
# derive a deterministic per-slug pair (the central allocator is charter D12
# backlog) — collisions are the caller's to avoid via SITE_PORT_A/SITE_PORT_B.
if [ -z "${SITE_PORT_A:-}" ] || [ -z "${SITE_PORT_B:-}" ]; then
  _base=$(( 8300 + ( $(printf '%s' "$SITE_SLUG" | cksum | cut -d' ' -f1) % 800 ) * 2 ))
  SITE_PORT_A="${SITE_PORT_A:-$_base}"
  SITE_PORT_B="${SITE_PORT_B:-$((_base + 1))}"
fi
PORT_A="$SITE_PORT_A"; PORT_B="$SITE_PORT_B"

# ---- Serialize per-site (queue depth 1) ------------------------------------
if ! mkdir -p "$(dirname "$LOCK")" 2>/dev/null; then
  LOCK="${TMPDIR:-/tmp}/barkpark-site-deploy-$SITE_SLUG.lock"
fi
exec 9>"$LOCK"
if ! flock -n 9; then
  if [ "$MODE" != deploy ]; then
    log "deploy lock held for '$SITE_SLUG' — refusing to $MODE while a deploy runs (lock_held)"
    exit 23
  fi
  log "another deploy holds the lock for '$SITE_SLUG' — queueing (max 20 min)"
  flock -w 1200 9 || { log "gave up waiting for the site deploy lock"; exit 15; }
fi

mkdir -p "$RELEASES" "$SLOT_ENV_DIR"
setup_caddy_lock

# ---- Rollback / preflight (D67) --------------------------------------------
# .previous holds "SLOT PORT BUILD_ID" of the warm previous slot.
if [ "$MODE" = preflight ]; then
  if ! active_slot >/dev/null || [ -z "$(active_slot)" ]; then
    log "no live route for '$SITE_SLUG' (not_supported)"; exit 22
  fi
  if [ ! -f "$ROOT/.previous" ] || [ -z "$(cat "$ROOT/.previous" 2>/dev/null)" ]; then
    log "no previous slot recorded for '$SITE_SLUG' (no_previous)"; exit 21
  fi
  read -r p_slot p_port p_build < "$ROOT/.previous"
  if [ -z "$p_build" ] || [ ! -d "$RELEASES/$p_build" ]; then
    log "previous release '$p_build' is gone (no_previous)"; exit 21
  fi
  if [ -f "$RELEASES/$p_build/$HEALTH_FAIL_MARK" ]; then
    log "previous release '$p_build' is marked health-failed (no_previous)"; exit 21
  fi
  if slot_running "$p_slot"; then
    log "rollback possible (WARM): flip Caddy back to slot $p_slot :$p_port ($p_build) — sub-second, no reboot"
  else
    log "rollback possible (COLD): reboot slot $p_slot on :$p_port at $p_build, gate, flip"
  fi
  echo "TARGET_BUILD=$p_build"
  exit 0
fi

if [ "$MODE" = rollback ]; then
  cur_slot="$(active_slot)"
  if [ -z "$cur_slot" ]; then log "no live route for '$SITE_SLUG' (not_supported)"; exit 22; fi
  if [ ! -f "$ROOT/.previous" ] || [ -z "$(cat "$ROOT/.previous" 2>/dev/null)" ]; then
    log "no previous slot recorded (no_previous)"; exit 21
  fi
  read -r p_slot p_port p_build < "$ROOT/.previous"
  if [ -z "$p_build" ] || [ ! -d "$RELEASES/$p_build" ]; then log "previous release '$p_build' is gone (no_previous)"; exit 21; fi
  if [ -f "$RELEASES/$p_build/$HEALTH_FAIL_MARK" ]; then
    log "previous release '$p_build' is marked health-failed — refusing to serve it (no_previous)"; exit 21
  fi
  if [ "$p_slot" = "$cur_slot" ]; then log "rollback: previous slot == current ($cur_slot) — nothing to do"; exit 0; fi

  cur_port="$(slot_port "$cur_slot")"; cur_build="$(read_slot_build "$cur_slot")"
  if slot_running "$p_slot" && [ "$(read_slot_build "$p_slot")" = "$p_build" ]; then
    # WARM: the previous slot is still up on $p_build — pure Caddy flip back (<1s).
    log "ROLLBACK (warm): flip Caddy $cur_slot :$cur_port -> $p_slot :$p_port ($p_build)"
    if ! with_caddy_lock flip_caddy_node_port "$p_port"; then
      log "rollback flip failed — Caddy untouched, still on $cur_slot (fail closed)"; exit 24
    fi
  else
    # COLD: reboot the idle slot onto $p_build, gate it, then flip.
    log "ROLLBACK (cold): boot slot $p_slot on :$p_port at $p_build, gate, flip"
    ensure_node_link
    BUILD_ID="$p_build"
    if ! health_gate_node "$p_slot" "$p_build"; then
      log "rollback: slot $p_slot failed HEALTH at $p_build — Caddy untouched, still on $cur_slot (fail closed): $HEALTH_DETAIL"; exit 24
    fi
    if ! with_caddy_lock flip_caddy_node_port "$p_port"; then
      stop_slot "$p_slot"
      log "rollback flip failed — Caddy untouched, still on $cur_slot (fail closed)"; exit 24
    fi
  fi
  # A subsequent --rollback flips forward again — record where we came from.
  printf '%s %s %s\n' "$cur_slot" "$cur_port" "$cur_build" > "$ROOT/.previous"
  do_retire_node "$p_slot"
  log "ROLLED BACK — '$SITE_SLUG' now on slot $p_slot ($p_build)"
  exit 0
fi

# ===========================================================================
# DEPLOY: PLAN -> BUILD -> STAGE -> HEALTH -> SWITCH -> RETIRE
# ===========================================================================
BUILD_ID="${BUILD_ID:-}"
if [ -z "$BUILD_ID" ]; then log "BUILD_ID is required for a deploy"; exit 11; fi
if ! valid_build_id "$BUILD_ID"; then log "invalid BUILD_ID '$BUILD_ID'"; exit 11; fi

CUR_SLOT="$(active_slot)"                       # "" on the first deploy
if [ -n "$CUR_SLOT" ]; then TARGET_SLOT="$(other_slot "$CUR_SLOT")"; else TARGET_SLOT=a; fi
TARGET_PORT="$(slot_port "$TARGET_SLOT")"

# ---- PLAN ------------------------------------------------------------------
# Live = the process on the ACTIVE Caddy-upstream slot serves this build_id.
emit PLAN started
if [ -n "$CUR_SLOT" ] && [ "$(read_slot_build "$CUR_SLOT")" = "$BUILD_ID" ] && slot_running "$CUR_SLOT"; then
  log "PLAN: build_id $BUILD_ID already live on slot $CUR_SLOT for '$SITE_SLUG' — nothing to do"
  emit PLAN noop "build $BUILD_ID is already live on slot $CUR_SLOT"
  for s in BUILD STAGE HEALTH SWITCH RETIRE; do emit "$s" skipped "build $BUILD_ID is already live"; done
  exit 0
fi
RELDIR="$RELEASES/$BUILD_ID"
if [ -f "$RELDIR/$HEALTH_FAIL_MARK" ]; then
  log "PLAN: release $BUILD_ID is marked health-failed — rebuilding from source"
  SKIP_BUILD=0
elif [ -d "$RELDIR" ] && [ -f "$RELDIR/server.js" ]; then
  log "PLAN: release $BUILD_ID already staged — re-gating on slot $TARGET_SLOT, skipping BUILD/STAGE"
  SKIP_BUILD=1
else
  SKIP_BUILD=0
fi
log "PLAN: deploy '$SITE_SLUG' build $BUILD_ID onto slot $TARGET_SLOT :$TARGET_PORT (live now: ${CUR_SLOT:-none})"
if [ "$SKIP_BUILD" = 1 ]; then
  emit PLAN ok "release $BUILD_ID is already staged — BUILD and STAGE will be skipped"
else
  emit PLAN ok "building '$SITE_SLUG' build $BUILD_ID for slot $TARGET_SLOT"
fi

# ---- BUILD -----------------------------------------------------------------
build_failure_reason() { # <build-log>
  local f="$1" r
  r="$(grep -a 'FATAL' "$f" 2>/dev/null | tail -1)"
  [ -n "$r" ] || r="$(grep -aE 'npm ERR!|[Ee]rror:' "$f" 2>/dev/null | grep -av 'complete log of this run' | tail -1)"
  [ -n "$r" ] || r="$(grep -av '^[[:space:]]*$' "$f" 2>/dev/null | tail -1)"
  [ -n "$r" ] || r="npm ci / npm run build failed with no output"
  printf '%s' "$r"
}

if [ "$SKIP_BUILD" = 0 ]; then
  emit BUILD started
  if [ ! -d "$SITE_SRC" ]; then
    log "BUILD: no site source dir $SITE_SRC"; emit BUILD failed "no site source dir $SITE_SRC"; exit 10
  fi
  if [ ! -f "$SITE_SRC/package.json" ]; then
    log "BUILD: $SITE_SRC has no package.json"; emit BUILD failed "$SITE_SRC has no package.json"; exit 11
  fi
  export BARKPARK_BUILD_ID="$BUILD_ID"
  export BARKPARK_SITE_BASE="/sites/$SITE_SLUG/"
  [ -n "${CONTENT_REV:-}" ] && export BARKPARK_CONTENT_REV="$CONTENT_REV"
  scrub=(env -i "PATH=$PATH" "HOME=${HOME:-/root}" NODE_ENV=production CI=1)
  for v in "${BUILD_ALLOW[@]}"; do
    [ -n "${!v:-}" ] && scrub+=("$v=${!v}")
  done
  log "BUILD: npm ci && npm run build in $SITE_SRC (scrubbed env, capped)"
  cd "$SITE_SRC" || { log "BUILD: cannot cd $SITE_SRC"; emit BUILD failed "cannot cd $SITE_SRC"; exit 10; }
  if command -v systemd-run >/dev/null 2>&1 && [ "${BARKPARK_SITE_NO_CAP:-0}" != 1 ]; then
    cap=(systemd-run --scope --quiet --collect -p MemoryMax=2000M -p CPUQuota=150%)
  else
    log "BUILD: systemd-run unavailable (or capping disabled) — running uncapped, still scrubbed"
    cap=(command)
  fi
  BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/site-node-build.XXXXXX")"
  # --include=dev is LOAD-BEARING: the scrubbed env sets NODE_ENV=production, under
  # which `npm ci` OMITS devDependencies — but the BUILD needs them (typescript,
  # @types/*, and any framework build tooling live in devDependencies). Without it
  # `next build` dies "Please install typescript, @types/react, @types/node" →
  # "build worker exited with code: 1". The RUNTIME stays lean: Next's standalone
  # output bundles only what serving needs, so the release never ships devDeps.
  "${cap[@]}" "${scrub[@]}" bash -euo pipefail -c 'npm ci --no-audit --no-fund --include=dev && npm run build' 2>&1 | tee "$BUILD_LOG"
  build_rc="${PIPESTATUS[0]}"
  if [ "$build_rc" -ne 0 ]; then
    reason="$(build_failure_reason "$BUILD_LOG")"
    rm -f "$BUILD_LOG"
    log "BUILD failed (exit $build_rc) for '$SITE_SLUG' build $BUILD_ID — live slot untouched: $reason"
    emit BUILD failed "$reason"
    exit 12
  fi
  rm -f "$BUILD_LOG"
  emit BUILD ok "npm ci && npm run build (next standalone)"

  # ---- STAGE (D64) — three-piece standalone copy into an immutable release ----
  emit STAGE started
  if [ ! -d "$SITE_SRC/.next/standalone" ]; then
    log "STAGE: build produced no $SITE_SRC/.next/standalone — is next.config output:'standalone'?"
    emit STAGE failed "build produced no .next/standalone (need output:'standalone')"; exit 13
  fi
  if [ ! -f "$SITE_SRC/.next/standalone/server.js" ]; then
    log "STAGE: .next/standalone has no server.js — abort"; emit STAGE failed ".next/standalone has no server.js"; exit 13
  fi
  rm -rf "$RELDIR" "$RELDIR.partial"
  mkdir -p "$RELDIR.partial"
  # 1) standalone dir IS the release root (server.js + traced node_modules).
  if ! cp -a "$SITE_SRC/.next/standalone/." "$RELDIR.partial/"; then
    log "STAGE: copy of .next/standalone failed"; rm -rf "$RELDIR.partial"; emit STAGE failed "copy of .next/standalone failed"; exit 13
  fi
  # 2) .next/static -> <release>/.next/static (standalone omits it by design).
  if [ -d "$SITE_SRC/.next/static" ]; then
    mkdir -p "$RELDIR.partial/.next/static"
    if ! cp -a "$SITE_SRC/.next/static/." "$RELDIR.partial/.next/static/"; then
      log "STAGE: copy of .next/static failed"; rm -rf "$RELDIR.partial"; emit STAGE failed "copy of .next/static failed"; exit 13
    fi
  fi
  # 3) public/ -> <release>/public (static assets; optional).
  if [ -d "$SITE_SRC/public" ]; then
    mkdir -p "$RELDIR.partial/public"
    if ! cp -a "$SITE_SRC/public/." "$RELDIR.partial/public/"; then
      log "STAGE: copy of public/ failed"; rm -rf "$RELDIR.partial"; emit STAGE failed "copy of public/ failed"; exit 13
    fi
  fi
  mv "$RELDIR.partial" "$RELDIR" || {
    log "STAGE: rename into place failed"; rm -rf "$RELDIR.partial"; emit STAGE failed "rename into releases/$BUILD_ID failed"; exit 13
  }
  staged_size="$(du -sh "$RELDIR" 2>/dev/null | cut -f1 || echo '?')"
  log "STAGE: standalone + .next/static + public -> releases/$BUILD_ID/ ($staged_size)"
  emit STAGE ok "standalone(+static+public) -> releases/$BUILD_ID ($staged_size)"
else
  emit BUILD skipped "release $BUILD_ID is already staged"
  emit STAGE skipped "release $BUILD_ID is already staged"
fi

# ---- HEALTH (D65) — boot the target slot IN PLACE, gate on the process --------
ensure_node_link
emit HEALTH started
if ! health_gate_node "$TARGET_SLOT" "$BUILD_ID"; then
  emit HEALTH failed "$HEALTH_DETAIL"
  log "HEALTH gate FAILED for build $BUILD_ID on slot $TARGET_SLOT — live slot untouched, no flip (fail closed)"
  purge_failed_release_node "$BUILD_ID"
  exit 14
fi
emit HEALTH ok "$HEALTH_DETAIL"

# ---- SWITCH (D66) — marker-anchored per-site reverse_proxy port flip ---------
# The target slot is booted + healthy; flip Caddy's per-site upstream to its port
# (arm the block on the first deploy). Fail-closed: a rejected flip stops the new
# slot and leaves the live slot serving.
emit SWITCH started
CUR_BUILD=""; CUR_PORT=""
if [ -n "$CUR_SLOT" ]; then CUR_BUILD="$(read_slot_build "$CUR_SLOT")"; CUR_PORT="$(slot_port "$CUR_SLOT")"; fi
if [ -z "$CUR_SLOT" ]; then
  if ! with_caddy_lock arm_caddy_node_route "$TARGET_PORT"; then
    stop_slot "$TARGET_SLOT"
    log "SWITCH: could not arm Caddy /sites/$SITE_SLUG route — new slot stopped, nothing live (fail closed)"
    emit SWITCH failed "could not arm the /sites/$SITE_SLUG Caddy route"; exit 16
  fi
else
  if ! with_caddy_lock flip_caddy_node_port "$TARGET_PORT"; then
    stop_slot "$TARGET_SLOT"
    log "SWITCH: could not flip Caddy to slot $TARGET_SLOT :$TARGET_PORT — live slot $CUR_SLOT untouched, still serving (fail closed)"
    emit SWITCH failed "could not flip Caddy to slot $TARGET_SLOT :$TARGET_PORT"; exit 16
  fi
fi
# Record the slot we flipped AWAY from as the warm previous (kept running for <1s
# rollback). First deploy: no previous.
if [ -n "$CUR_SLOT" ] && [ "$CUR_SLOT" != "$TARGET_SLOT" ]; then
  printf '%s %s %s\n' "$CUR_SLOT" "$CUR_PORT" "$CUR_BUILD" > "$ROOT/.previous"
fi
log "SWITCH: '$SITE_SLUG' Caddy upstream -> slot $TARGET_SLOT :$TARGET_PORT (build $BUILD_ID)"
emit SWITCH ok "Caddy upstream -> slot $TARGET_SLOT :$TARGET_PORT"

# ---- RETIRE (D67) — keep current + 1 warm previous; prune old releases -------
emit RETIRE started
do_retire_node "$TARGET_SLOT"
emit RETIRE ok "removed $RETIRED old release(s); current slot $TARGET_SLOT + warm previous kept running"

log "HEALTHY — '$SITE_SLUG' live at build $BUILD_ID on slot $TARGET_SLOT (https://$HEALTH_HOST/sites/$SITE_SLUG/)"
exit 0
