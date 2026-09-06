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
#          non-empty BY VALUE (meta_value, D26). An empty bp-doc-id still REFUSES;
#          the optional bp-corpus-status marker names the upstream condition that
#          emptied it (403 / 401 / wrong host / genuinely empty corpus) so the
#          recorded failure_reason is a diagnosis, not a symptom. On failure: stop
#          the just-booted slot, NEVER touch the live slot or Caddy, exit 14.
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
# Plus two REPORT-ONLY names this engine emits that are deliberately NOT in that
# whitelist (DeployRunner's @stage_names), so they can never flip a verdict:
#   BPSTAGE name=ROUTE  status=ok … detail="armed: …|already armed: …"
#   BPSTAGE name=SERVED status=ok … detail="port=<n|none> slot=<a|b|none>"
# SERVED is the slot Caddy is ACTUALLY serving after the flip — READ BACK from
# the Caddyfile marker block, never TARGET_SLOT/TARGET_PORT (which are intent).
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
#   24 rollback failed         25 teardown: route still live (disarm rejected)
#
# TEARDOWN machine contract (no BPSTAGE — a teardown is not a deploy):
#   exit 0  prints TORN_DOWN=<slug> on stdout AND appends it to
#           $BARKPARK_SITE_LOG_FILE — slots stopped, route gone, tree deleted.
#   exit 25 prints TEARDOWN_FAILED=<slug> detail="…" on the SAME two channels and
#           NEVER TORN_DOWN=: the Caddy route survived (the disarm was rejected and
#           reverted), so the release tree + slot env files are LEFT ON DISK.
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
# Read by log() in deploy/lib/site-deploy-common.sh (sourced below). Exported so
# the linter sees a use (SC2034) and any child shell carries the same tag.
export BP_LOG_TAG="site-deploy-node"

# Shared primitives (charter D61): emit/BPSTAGE, valid_slug/valid_build_id,
# meta_value, build_failure_reason, BUILD_ALLOW, setup_caddy_lock/with_caddy_lock, log. site-deploy.sh
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
  --teardown)           MODE=teardown ;;
  --self-test)          MODE=selftest ;;
  "")                   MODE=deploy ;;
  *) log "unknown flag '${1}' (supported: --rollback, --rollback-preflight, --teardown, --self-test)"; exit 2 ;;
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
# THE ROUTE-MARKER PREDICATE (D345) — an IDENTITY, not a substring. Carried
# VERBATIM from the static engine (deploy/site-deploy.sh); arm, disarm, the
# active-port read and the port flip must all agree or one of them re-opens the
# defect.
#
# `BARKPARK_SITE_ROUTE:<slug>` read as a bare substring is not an identity: a
# slug can be a strict PREFIX of another slug, and then `grep -q "$marker"` and
# awk `index($0, m)` match the SIBLING'S block. Measured live on guerrilla:
# `search` is a prefix of `search-capstone`, so active_caddy_port read the
# SIBLING's port 8506, active_slot matched neither PORT_A nor PORT_B and printed
# nothing, CUR_SLOT came back EMPTY, every run took the phantom first-deploy ARM
# branch, and the arm's already-armed guard matched the sibling and returned 0
# WITHOUT WRITING — 208 deploys reporting SWITCH ok at exit 0 over a public 404,
# with blue/green rollback silently absent (206 `for slot a`, zero slot b).
#
# `grep -qw` IS NOT THE FIX: `-w` treats `-` as a NON-word character, so
# `…ROUTE:search` still word-matches `…ROUTE:search-capstone`. Anchor the
# DELIMITER instead — and the delimiter is "any character a slug cannot
# contain", NOT "whitespace". valid_slug() is `^[a-z0-9][a-z0-9-]{0,62}$`, so a
# sibling can only ever continue the marker with `[a-z0-9-]`; rejecting exactly
# that class is necessary AND sufficient. Whitespace-only would still be right
# for markers this engine writes (always `# …:<slug> — …`) but would read a
# HAND-EDITED marker (`…:<slug>:` / `…:<slug>#`) as not-armed and re-arm a
# working route into a DUPLICATE handle — the dangerous direction. The slug
# carries no ERE metacharacter (a `-` LAST in a bracket expression is literal),
# so it interpolates literally into grep -E AND awk's dynamic regex alike.
# ---------------------------------------------------------------------------
site_route_marker_re() { printf 'BARKPARK_SITE_ROUTE:%s([^a-z0-9-]|$)' "$SITE_SLUG"; }
has_site_route_marker() { grep -qE "$(site_route_marker_re)" "$1"; }

# ---------------------------------------------------------------------------
# Marker-anchored per-site Caddy read: the ACTIVE upstream port is the one inside
# THIS site's marker block (BARKPARK_SITE_ROUTE:<slug>), never a global grep — two
# node sites can legitimately share a port literal elsewhere in the file, and the
# global sed instance-deploy.sh uses to flip its OWN slots would corrupt the wrong
# site here (RUN-proven). Empty = the route is not armed yet (first deploy).
# ---------------------------------------------------------------------------
active_caddy_port() {
  [ -f "$CADDYFILE" ] || return 0
  awk -v m="$(site_route_marker_re)" '
    $0 ~ m { inb = 1 }
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
  # DELIMITER-ANCHORED (D345): a bare-substring guard matched a prefix SIBLING's
  # marker and returned "already armed" for a site that was never armed at all.
  if has_site_route_marker "$CADDYFILE"; then
    ROUTE_DETAIL="already armed: $CADDYFILE already carries this site's own $marker block, so the arm wrote nothing (only the upstream port moves on a re-deploy)"
    return 0
  fi
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
  if commit_caddyfile "$tmp"; then
    ROUTE_DETAIL="armed: this run wrote the $marker block into $CADDYFILE and reloaded Caddy, so https://$HEALTH_HOST/sites/$SITE_SLUG/ now proxies to localhost:$port"
    return 0
  fi
  return 1
}

# Flip the reverse_proxy port INSIDE this site's marker block, in place. Replaces
# ONLY the first reverse_proxy localhost:<port> after the marker — never a global
# sed. 0 flipped, 1 rejected/reverted.
flip_caddy_node_port() { # <new-port>
  local port="$1" marker="BARKPARK_SITE_ROUTE:$SITE_SLUG" mre
  mre="$(site_route_marker_re)"
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — cannot flip /sites/$SITE_SLUG"; return 1; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — cannot flip /sites/$SITE_SLUG"; return 1; }
  # DELIMITER-ANCHORED (D345) on BOTH reads: the guard below and the awk that
  # finds the block. A bare substring would let this rewrite a prefix SIBLING's
  # upstream port — the same collision, in its most destructive direction.
  has_site_route_marker "$CADDYFILE" || { log "no $marker block in $CADDYFILE — cannot flip"; return 1; }
  local tmp; tmp="$(mktemp)"
  awk -v m="$mre" -v p="$port" '
    $0 ~ m { inb = 1 }
    inb && !done && $0 ~ /reverse_proxy[[:blank:]]+localhost:[0-9]+/ {
      sub(/localhost:[0-9]+/, "localhost:" p); inb = 0; done = 1
    }
    { print }
  ' "$CADDYFILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  if commit_caddyfile "$tmp"; then
    ROUTE_DETAIL="already armed: this site's $marker block was already in $CADDYFILE, so this run only moved its upstream to localhost:$port (no route was added)"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# HEALTH (D65) — boot the target slot IN PLACE and gate on the RUNNING process.
# Writes the slot env for build $2, starts the slot, polls its port to a >=10s
# deadline (a process needs ~1.5s to first-200; the Next "Ready" log lies), then
# asserts the served bytes carry THIS build's markers by value. On any failure it
# stops the just-booted slot and NEVER touches the live slot or Caddy. Sets
# HEALTH_DETAIL either way (rides the BPSTAGE line).
#
# SLOW IS NOT BROKEN (D27). The probe budget below is TWO-PHASE, because a single
# per-attempt ceiling made the gate report the same thing for a site that renders
# in 48s as for a site that never renders at all. Under an 8s ceiling curl aborts
# mid-render and reports the last COMPLETED hop — a 308 — so a merely-slow site
# burned all 20 attempts and exited 14 with "returned 308 (want 200)", which is a
# false diagnosis: the site was serving, just not inside the ceiling.
#
# MEASURED, and the CONTROL is what carries the claim (never the seconds alone —
# the absolute figure was first taken at load average 13.45, so it is a reading of
# the box under wave load as much as of the site): on ONE box, SECONDS APART, the
# sibling node slots first-200 in ~1.3s while search-capstone takes ~48s — a ~37x
# within-host ratio. The LIVE, previously-GREEN capstone release behaves the same
# (308/8.4s, 308/8.0s, 308/8.0s under the ceiling; 200/48.1s without it), so the
# latency is site-specific and PRE-EXISTING; the provisioning repair EXPOSES it,
# it did not cause it.
#
# So: FAST attempts at the tight ceiling (a healthy slot passes on the first
# sub-second one), then ONE PATIENT attempt whose ceiling is ~2x the worst render
# actually observed. A 200 that only lands on the patient attempt is a DIFFERENT,
# honest outcome — the gate PASSES it (the bytes are there and the markers are
# still asserted by value) and says SLOW, with the measured seconds and the
# multiple of the fast ceiling in the detail, so a slow site is VISIBLE instead of
# either silently failing or silently passing. Never-200 stays exit 14 and now
# says never-200 in those words. The TOTAL budget does not grow: worst case
# 8*(8+0.5) + 90 = 158s, under the 170s the flat 20-attempt loop already spent.
# ---------------------------------------------------------------------------
# Dev/self-test knobs ONLY (same contract as BUILD_GATE_*): DeployRunner writes an
# explicit env allowlist into the transient unit, so nothing ambient can reach the
# engine on the real path. To change the box's behaviour, change the defaults.
HEALTH_FAST_ATTEMPTS="${BARKPARK_SITE_HEALTH_ATTEMPTS:-8}"
HEALTH_FAST_MAX="${BARKPARK_SITE_HEALTH_FAST_MAX:-8}"       # ~6x a healthy 1.3s first render
HEALTH_PATIENT_MAX="${BARKPARK_SITE_HEALTH_PATIENT_MAX:-90}" # ~2x the worst (48s) observed live
HEALTH_DETAIL=""
HEALTH_SLOW=0        # 1 = served 200, but only past the fast ceiling
HEALTH_SECONDS=""    # curl %{time_total} of the attempt that answered
# A 200 IS ONLY A 200 IF THE TRANSFER FINISHED. Both halves of that sentence in
# ONE predicate, on purpose: the probe reads BOTH numbers off the same curl call
# (`-w %{http_code}` and `$?`) and every decision below asks THIS, so there is one
# place to get it wrong and one place to mutate. Dropping `$2` here — which is
# exactly what `[ "$code" = 200 ] && break` used to do — makes an http_code=200
# with curl exit 28 (the ceiling cut the body mid-stream) indistinguishable from
# a document read to its last byte, and the SSR marker assertions downstream then
# read a TRUNCATED page as a statement about the site's CONTENT. The self-test's
# truncation mutation proof is anchored on this function for that reason.
clean_200() { # <http_code> <curl_rc> -> 0 when the body was read to the end
  [ "$1" = 200 ] && [ "$2" = 0 ]
}
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

  local body code=000 i curl_rc=0 t_total="" out fast_code=000 fast_trunc=0
  HEALTH_SLOW=0; HEALTH_SECONDS=""
  body="$(mktemp "${TMPDIR:-/tmp}/site-node-health.XXXXXX")"
  # PHASE 1 — the fast poll. A force-dynamic SSR page fetches content per request,
  # so the ceiling is generous by static standards (D65 raised it from 2s, which
  # made EVERY probe abort mid-render and read as an eternal 308: search-capstone
  # b-…-stw1d "308 within 12s" while the slot rendered 200 in ~1s unthrottled).
  # A healthy slot answers on the first sub-second attempt.
  for i in $(seq 1 "$HEALTH_FAST_ATTEMPTS"); do
    # -L --max-redirs 2: canonicalization is framework-owned. Next with a baked
    # basePath 308s `${basePath}/` -> `${basePath}` (proven live: search-capstone
    # b-…-stw1c HEALTH read 308 at /sites/<slug>/), while a plain static server
    # 301s bare -> slashed. Follow up to 2 loopback hops and gate on the FINAL
    # code — the marker-by-value assertion below still proves the served bytes.
    out="$(curl -sL --max-redirs 2 -o "$body" -w '%{http_code} %{time_total}' --connect-timeout 2 --max-time "$HEALTH_FAST_MAX" "http://127.0.0.1:$port$path" 2>/dev/null)"; curl_rc=$?
    code="${out%% *}"; t_total="${out##* }"; [ -n "$code" ] || code=000
    # A 200 WHOSE TRANSFER DID NOT FINISH IS NOT A CLEAN 200. `curl_rc` is
    # captured on the line above and, until this guard existed, thrown away right
    # here: `[ "$code" = 200 ] && break` accepted http_code=200 + curl exit 28
    # (the ceiling cut the body mid-stream) and handed the marker assertions a
    # TRUNCATED document. That is not neutral, because the markers are not
    # symmetrically placed: bp-build-id and bp-content-rev are literal <head>
    # children and flush in the shell, while bp-doc-id is emitted from the page
    # component later in the stream — so truncated bytes PASS the first two and
    # FAIL the third, and the empty-bp-doc-id branch below then reports an
    # UNFINISHED READ as a CONTENT FACT ("the SSR rendered no content document").
    # Consulting curl_rc is what keeps those two sentences different.
    if [ "$code" = 200 ] && ! clean_200 "$code" "$curl_rc"; then
      fast_trunc=1
      log "HEALTH: attempt $i answered 200 but curl exited $curl_rc — the body was cut at the ${HEALTH_FAST_MAX}s ceiling, so it is a TRUNCATED read, not a clean 200; the markers are NOT asserted on partial bytes"
    fi
    clean_200 "$code" "$curl_rc" && break
    sleep 0.5
  done
  HEALTH_SECONDS="$t_total"
  # PHASE 2 — the patient attempt. The fast poll never saw a CLEAN 200; that is
  # the state where SLOW and BROKEN are indistinguishable, so ASK ONCE MORE
  # without the tight ceiling instead of guessing. Whatever this returns is a
  # fact about the site, not about the ceiling. A fast poll that only ever
  # truncated lands here too, and that is exactly what this phase is for: the
  # patient ceiling is the headroom a slow-but-complete render needs.
  if ! clean_200 "$code" "$curl_rc"; then
    fast_code="$code"
    [ "$fast_trunc" = 1 ] && [ "$code" = 200 ] && fast_code="200-but-TRUNCATED"
    log "HEALTH: no clean 200 in $HEALTH_FAST_ATTEMPTS attempts at the ${HEALTH_FAST_MAX}s ceiling (last: $fast_code) — one patient probe at ${HEALTH_PATIENT_MAX}s to tell a SLOW site from a BROKEN one"
    out="$(curl -sL --max-redirs 2 -o "$body" -w '%{http_code} %{time_total}' --connect-timeout 2 --max-time "$HEALTH_PATIENT_MAX" "http://127.0.0.1:$port$path" 2>/dev/null)"; curl_rc=$?
    code="${out%% *}"; t_total="${out##* }"; [ -n "$code" ] || code=000
    HEALTH_SECONDS="$t_total"
    i=$((i + 1))
    clean_200 "$code" "$curl_rc" && HEALTH_SLOW=1
  fi
  # THE READ NEVER FINISHED, even at the patient ceiling. Refuse — but refuse in
  # the engine's OWN words about the READ, never in the content branch's words
  # about the site. The distinction the ledger needs is that this sentence
  # carries no "bp-doc-id marker is empty", so `DeployLedger.classify/2` cannot
  # reach its DOC_ID_EMPTY arm (whose meaning is "the marker was empty and
  # NOTHING RECORDED WHY", agency :ambiguous) on bytes that were merely unread;
  # it falls to the `HEALTH failed` prefix arm — HEALTH_GATE_FAILED, agency :box
  # — the same honest class the never-200 refusal below already lands in.
  if [ "$code" = 200 ] && ! clean_200 "$code" "$curl_rc"; then
    rm -f "$body"; stop_slot "$slot"
    HEALTH_DETAIL="slot $slot on :$port answered 200 at $path but the body was TRUNCATED after ${HEALTH_SECONDS}s (curl exit $curl_rc) — cut at the patient ${HEALTH_PATIENT_MAX}s ceiling after $HEALTH_FAST_ATTEMPTS attempts at the ${HEALTH_FAST_MAX}s fast ceiling (last $fast_code). The SSR markers were never read to the end, so this run states NOTHING about the site's content — it is an unfinished READ, not an empty document; live slot untouched"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ "$code" != 200 ]; then
    rm -f "$body"; stop_slot "$slot"
    HEALTH_DETAIL="slot $slot on :$port returned $code (want 200) at $path — NEVER served 200: $HEALTH_FAST_ATTEMPTS attempts at the ${HEALTH_FAST_MAX}s ceiling (last $fast_code) AND a patient ${HEALTH_PATIENT_MAX}s probe (${HEALTH_SECONDS}s, curl exit $curl_rc) — BROKEN, not slow; live slot untouched"
    log "HEALTH: $HEALTH_DETAIL"; return 1
  fi
  if [ "$HEALTH_SLOW" = 1 ]; then
    # It SERVES. It is just slow — and that is a site defect (a cold SSR render
    # this far past its siblings on the same box), not a boot failure. Say so
    # loudly on both channels; the markers below are still asserted by value.
    log "HEALTH: SLOW — slot $slot on :$port served 200 only on the patient probe, after ${HEALTH_SECONDS}s (past the ${HEALTH_FAST_MAX}s per-attempt ceiling; a healthy slot on this box first-200s in ~1.3s). Gating it as healthy: it renders, and refusing it would be a false 'boot failed'."
  fi

  local got_build got_rev got_doc got_corpus
  got_build="$(meta_value "$body" bp-build-id)"
  got_rev="$(meta_value "$body" bp-content-rev)"
  got_doc="$(meta_value "$body" bp-doc-id)"
  # bp-corpus-status (cause-truth): the template emits it ONLY when it could not
  # anchor a content document, carrying the upstream condition that stopped it
  # ("graph 403: …", "graph 401: …", "graph 200: corpus read OK but carried 0
  # node(s)…"). Read it BEFORE the body is deleted — it is what turns the empty
  # bp-doc-id refusal below from a symptom into a diagnosis.
  got_corpus="$(meta_value "$body" bp-corpus-status)"
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
    # STILL REFUSES — fail-closed on an empty bp-doc-id is correct (D72) and is
    # NOT relaxed here. What changes is legibility: when the build recorded WHY
    # it could not read its corpus, that cause rides the failure_reason, so a
    # 403 (public-read token), a 401 (no token), a wrong host and a genuinely
    # empty corpus stop collapsing into one illegible row.
    if [ -n "$got_corpus" ]; then
      HEALTH_DETAIL="bp-doc-id marker is empty — the SSR could not read a content document: $got_corpus"
    else
      HEALTH_DETAIL="bp-doc-id marker is empty — the SSR rendered no content document (no bp-corpus-status marker: this build predates the corpus-status contract, so the upstream cause went unrecorded)"
    fi
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  # The observed latency ALWAYS rides the detail — a stdout-only caller cannot
  # ask the box afterwards, and "how long did it take to render" is the one
  # number that separates a site that is degrading from one that is fine.
  if [ "$HEALTH_SLOW" = 1 ]; then
    HEALTH_DETAIL="200 in ${HEALTH_SECONDS}s — SLOW: no 200 inside the ${HEALTH_FAST_MAX}s per-attempt ceiling, only on the patient ${HEALTH_PATIENT_MAX}s probe (a healthy slot on this box first-200s in ~1.3s) — serving, not broken + bp-build-id=$got_build bp-content-rev=$got_rev bp-doc-id=$got_doc (slot $slot :$port)"
  else
    HEALTH_DETAIL="200 in ${HEALTH_SECONDS}s + bp-build-id=$got_build bp-content-rev=$got_rev bp-doc-id=$got_doc (slot $slot :$port)"
  fi
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
  # This is the OUTERMOST skip in the file, and it used to be the only one that
  # claimed success on the way out: `[selftest] PASS`, exit 0, with every check
  # below it — the HEALTH gate, the blue/green flip, the purge, teardown, the
  # whole engine — never run. Two consumers read that as a green:
  #
  #   * CI (.github/workflows/deploy-harnesses.yml) sets
  #     BARKPARK_SELFTEST_REQUIRE_E2E=1 on this exact step, expressly so a block
  #     that skips itself cannot still print PASS. Two INNER blocks honour that
  #     flag; this outer one never consulted it, so the flag it was set for was
  #     bypassed by the largest skip in the file.
  #   * `bp cloud site preflight` (internal/cli/cloud_site_preflight.go)
  #     parses this output. Its gate is documented as "strict AND non-vacuous —
  #     an unparseable run is a FAIL, not a silent pass", and it is: a bare
  #     `[selftest] PASS` with no `N/M checks passed` count sets Terminal=PASS,
  #     Fails=0 and clears the engine floor on zero evidence.
  #
  # So: where the run is REQUIRED (CI sets the flag; CI also sets CI=true, which
  # makes this self-defending under any workflow that forgets the flag) a missing
  # toolchain is a hard, terminal FAILED — emitted in the `FAILED (k)` shape the
  # CLI parser recognises as terminal. Elsewhere it stays an honest local skip,
  # but it no longer claims PASS: a run that proved nothing must not print the
  # word, and the preflight's own no-summary branch then reports it truthfully.
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ] || [ "${CI:-}" = "true" ]; then
      echo "[selftest] FAILED (1) - the Node engine self-test is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1 or CI=true) but python3 and/or curl are missing from PATH — install them on this runner; without them the fake slot http server cannot start and NOT ONE check below runs, and a harness that ran nothing must not report PASS"
      exit 1
    fi
    echo "[selftest] SKIP — needs python3 + curl (the fake slot http server); nothing was proven, so this run reports no verdict"
    exit 0
  fi

  # -------------------------------------------------------------------------
  # SELF-TEST FLOOR — two LITERAL, COMMITTED constants (task-7843c92e00b0a13a).
  #
  # Same defect and same remedy as the static engine's floor: the verdict below
  # was `[ "$FAILS" -eq 0 ]` alone, so a run that executed a handful of checks
  # and a run that executed 334 both printed `[selftest] PASS`. Two blocks below
  # drop out on a condition (a real flock(1) for the fleet admission gate,
  # api/lib/barkpark/sites/deploy_runner.ex for the DeployRunner doctrine row) —
  # both already hard-fail under BARKPARK_SELFTEST_REQUIRE_E2E=1; the floor
  # catches a block vanishing for a reason nobody guarded. The outer python3/curl
  # skip above never reaches here (it exits before TESTS exists).
  #
  # LITERALS, never derived from the run. Measured 2026-09-03 at origin/main
  # 0cb244bfb:
  #
  #   MIN  = 326  no flock and no api/ in the tree (the two optional blocks skip)
  #   FULL = 343  all blocks run — this is what CI gets
  #
  # 2026-09-04: +9 (317->326, 334->343) for the rejecting-caddy-through-SWITCH
  # block — the exit-16 fail-closed arm that no fixture had ever driven. It sits
  # outside both optional blocks, so BOTH floors move by the same 9.
  #
  # FULL applies under BARKPARK_SELFTEST_REQUIRE_E2E=1, the venue
  # .github/workflows/deploy-harnesses.yml runs ("Site deploy engine (Node)
  # self-test", env BARKPARK_SELFTEST_REQUIRE_E2E: "1", ubuntu-latest).
  # ADD rows -> raise the literal in the SAME commit.
  SELFTEST_FLOOR_MIN=342
  SELFTEST_FLOOR_FULL=359
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
  T_PORT_G="$(free_port)"; T_PORT_H="$(free_port)"   # prefix-collision: the LONGER sibling
  T_PORT_I="$(free_port)"; T_PORT_J="$(free_port)"   # prefix-collision: the PREFIX slug

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
    # A slot that is SLOW or BROKEN on purpose (the SLOW-vs-BROKEN health cases)
    # ships a sentinel INSIDE its release: .slow-serve holds a per-request delay
    # in seconds, .broken-serve an HTTP status it always answers with. Everything
    # else gets the plain fast file server, byte-identical to before.
    # .truncate-serve holds a STALL in seconds taken MID-BODY: the <head> markers
    # flush, then the stream hangs before bp-doc-id. That is the shape a probe
    # ceiling turns into http_code=200 + curl exit 28 + a partial document.
    if [ -f "\$rel/.truncate-serve" ]; then
      python3 "$TD/trunc-server.py" "\$port" "\$rel" "\$(cat "\$rel/.truncate-serve")" >/dev/null 2>&1 &
    elif [ -f "\$rel/.slow-serve" ] || [ -f "\$rel/.broken-serve" ]; then
      delay=0; status=200
      [ -f "\$rel/.slow-serve" ]   && delay="\$(cat "\$rel/.slow-serve")"
      [ -f "\$rel/.broken-serve" ] && status="\$(cat "\$rel/.broken-serve")"
      python3 "$TD/probe-server.py" "\$port" "\$rel" "\$delay" "\$status" >/dev/null 2>&1 &
    else
      python3 -m http.server "\$port" --bind 127.0.0.1 --directory "\$rel" >/dev/null 2>&1 &
    fi
    echo \$! > "\$pidf"; exit 0;;
  stop)
    [ -f "\$pidf" ] && { kill "\$(cat "\$pidf")" 2>/dev/null; rm -f "\$pidf"; }; exit 0;;
  is-active)
    [ -f "\$pidf" ] && kill -0 "\$(cat "\$pidf")" 2>/dev/null && exit 0; exit 1;;
esac
exit 0
SYSCTL
  # The deliberately-slow / deliberately-broken slot server. A real SSR page that
  # takes 48s to render and a slot that never answers 200 are INDISTINGUISHABLE to
  # a probe with one ceiling — this is how both are driven offline, in seconds.
  cat > "$TD/probe-server.py" <<'PROBESRV'
import http.server, sys, time
port, root, delay, status = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=root, **kw)
    def log_message(self, *a):
        pass
    def do_GET(self):
        if delay:
            time.sleep(delay)
        if status != 200:
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PROBESRV
  # THE TRUNCATING SLOT SERVER — a render that STREAMS. It answers 200
  # immediately, flushes everything up to (but not including) the bp-doc-id
  # marker, then stalls. That is the real asymmetry the template has:
  # bp-build-id/bp-content-rev are literal <head> children and arrive in the
  # first flush, bp-doc-id comes from the page component further down the
  # stream. A probe ceiling that lands inside the stall therefore reads
  # http_code=200, curl exit 28, and a document that carries two of the three
  # markers. Threaded on purpose: each probe attempt must be answered on its own
  # timeline, not queued behind the previous attempt's stall.
  cat > "$TD/trunc-server.py" <<'TRUNCSRV'
import http.server, socketserver, sys, time
port, root, stall = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
with open(root + "/index.html", "rb") as f:
    DOC = f.read()
CUT = DOC.index(b'<meta name="bp-doc-id"')
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # close-delimited: no Content-Length to betray the cut
    def log_message(self, *a):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(DOC[:CUT])
        self.wfile.flush()
        time.sleep(stall)
        try:
            self.wfile.write(DOC[CUT:])
            self.wfile.flush()
        except Exception:
            pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
S(("127.0.0.1", port), H).serve_forever()
TRUNCSRV
  # Fake npm: `ci` no-ops; `run build` emits a Next standalone layout carrying the
  # markers the health gate asserts. Lie/fail switches ride in FILES in the source
  # dir (cwd is the one channel the env scrub cannot close).
  cat > "$FAKEBIN/npm" <<'FAKENPM'
#!/usr/bin/env bash
echo "npm $*" >> ./.npm-calls
[ "${1:-}" = ci ] && exit 0
# Slow-build fixture (the re-attach case): emit RAW output the durable log must
# capture, record THIS process's own pid ($$ is correct here — a real subprocess,
# not a backgrounded function), then exec into a long sleep so the build is still
# in flight when the caller kills the top-level engine.
if [ -f ./.slow-build ]; then
  echo "building the site (slow-build fixture)"
  echo "compiling next standalone bundle..."
  echo $$ > ./.slow-build-pid
  # Stay in flight until the caller removes the sentinel — leak-proof, no reliance
  # on a signal reaching this (soon orphaned) process. Hard cap ~30s so a botched
  # test can never wedge CI.
  n=0; while [ -f ./.slow-build ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  exit 0
fi
if [ -f ./.fail-build ]; then
  echo "npm ERR! code ELIFECYCLE" >&2
  echo "FATAL: 401 Unauthorized from https://guerrilla.barkpark.cloud/w/acme/p/blog — the site read token is invalid" >&2
  exit 1
fi
bid="${BARKPARK_BUILD_ID:-}"; rev="${BARKPARK_CONTENT_REV:-}"; doc="doc-42"; corpus=""
[ -f ./.lie ] && { bid=TOTALLY-WRONG; rev=""; }
# An SSR that could NOT read its corpus: empty bp-doc-id (the gate must still
# refuse) PLUS the bp-corpus-status marker naming the upstream condition — the
# exact bytes templates/search-starter emits via lib/graph.corpusStatusMarker.
[ -f ./.no-corpus ] && { doc=""; corpus="graph 403: public-read tokens may only read published public documents"; }
# The legacy shape: empty bp-doc-id and NO status marker (a template built before
# the corpus-status contract) — the gate must refuse AND say the cause is unknown.
[ -f ./.no-corpus-legacy ] && { doc=""; corpus=""; }
mkdir -p .next/standalone .next/static public
printf '// fake next standalone server\n' > .next/standalone/server.js
{
  printf '<!doctype html><html><head>\n'
  printf '<meta name="bp-build-id" content="%s">\n' "$bid"
  printf '<meta name="bp-content-rev" content="%s">\n' "$rev"
  printf '<meta name="bp-doc-id" content="%s">\n' "$doc"
  # Emitted ONLY when there is something to record — same conditional the
  # template uses (a healthy render carries no bp-corpus-status at all).
  [ -n "$corpus" ] && printf '<meta name="bp-corpus-status" content="%s">\n' "$corpus"
  printf '</head><body><h1>SSR</h1></body></html>\n'
} > .next/standalone/index.html
printf 'chunk\n' > .next/static/chunk.js
printf 'robots\n' > public/robots.txt
# Carry the slot-behaviour sentinels INTO the release (STAGE's `cp -a src/.`
# copies dotfiles), so the fake systemctl can boot a slot that is slow, or one
# that never answers 200, without touching the engine's own code path.
rm -f .next/standalone/.slow-serve .next/standalone/.broken-serve .next/standalone/.truncate-serve
[ -f ./.slow-serve ]   && cp ./.slow-serve   .next/standalone/.slow-serve
[ -f ./.broken-serve ] && cp ./.broken-serve .next/standalone/.broken-serve
[ -f ./.truncate-serve ] && cp ./.truncate-serve .next/standalone/.truncate-serve
true
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
    : > "$TD/rblog"   # BARKPARK_SITE_LOG_FILE — the durable log the runner finalizes from
    env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=selftest SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
      BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_SITE_HEALTH_PATH=/ BARKPARK_NODE_LINK="$TD/barkpark-node" \
      BARKPARK_SITE_NO_CAP=1 BARKPARK_SITE_LOG_FILE="$TD/rblog" \
      bash "$SELF" --rollback > "$TD/out.log" 2> "$TD/err.log"
    echo $?
  }
  saw()   { grep -q "^BPSTAGE name=$1 status=$2 build_id=$3" "$TD/out.log"; }
  nosaw() { ! grep -q "^BPSTAGE name=$1 " "$TD/out.log"; }
  # "this run's log says nothing of the kind" — the negative half of a reason
  # assertion (a diagnosis must not be invented when nothing was recorded).
  no_log_match() { ! grep -q "$1" "$TD/out.log"; }
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
  # D346 — the arm decision on the DURABLE channel. This engine spoke SWITCH
  # only, so `arm` vs `flip` (first deploy vs blue/green) was unrecoverable
  # after the fact: log() writes stdout, which nothing persists.
  check "ROUTE ok says ARMED on the durable machine channel (D346)" \
    grep -q '^BPSTAGE name=ROUTE status=ok build_id=n1 detail="armed: ' "$TD/out.log"
  check "…and the ROUTE detail names the port it armed" \
    grep -q "proxies to localhost:$T_PORT_A" "$TD/out.log"
  # ROUTE must stay OUTSIDE DeployRunner's @stage_names, or this report becomes a
  # verdict: parse_stage_line/2 would fold it into `stages` and stage_exit_code/1
  # could turn a green deploy red. Report, never verdict (charter D327).
  RUNNER_EX="$(cd "$(dirname "$SELF")/.." && pwd)/api/lib/barkpark/sites/deploy_runner.ex"
  if [ ! -f "$RUNNER_EX" ]; then
    # A silent skip here is the same vacuum as the flock skip below: extracted
    # without api/, this row disappears and the suite still prints PASS at a
    # lower total. Skip honestly on a partial checkout; NEVER in CI.
    if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
      echo "[selftest] FAIL - the DeployRunner @stage_names proof is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but $RUNNER_EX is missing — this engine was extracted without api/, so the only assertion that ROUTE stays OUTSIDE the runner's whitelist did not run; a skipped doctrine proof must not report PASS"
      exit 1
    fi
    echo "[selftest] SKIP DeployRunner @stage_names doctrine (ROUTE stays a report) — needs api/lib/barkpark/sites/deploy_runner.ex in the tree"
  else
    check "DeployRunner's @stage_names still has no ROUTE arm (the node report cannot flip a verdict)" \
      sh -c "! grep -q '^  @stage_names .*ROUTE' '$RUNNER_EX'"
  fi

  # -------------------------------------------------------------------------
  # THE MARKER DELIMITER CLASS (D345), asserted DIRECTLY on the predicate.
  #
  # #10607's fix landed in BOTH engines, but only the static engine could SEE
  # it: every marker THIS script writes has a space after the slug, so reverting
  # site_route_marker_re to a whitespace-only ([[:space:]]|$) predicate left this
  # suite at 177/177 PASS while the same mutation red the static engine's two
  # hand-edited-delimiter rows. The hardening in the file that governs every live
  # Node site's public route was mutation-INVISIBLE — an L4 claim in an L1 suit.
  #
  # The dangerous direction is a marker this script did NOT write: a hand-edited
  # `…:<slug>:` in a live Caddyfile reads as NOT ARMED under a whitespace-only
  # predicate, and the arm re-writes a working route into a duplicate handle.
  # So the delimiter is "any character a slug cannot contain" ([^a-z0-9-]),
  # which is right in BOTH directions — it accepts every real delimiter and
  # still rejects the only thing a sibling slug can continue with.
  # -------------------------------------------------------------------------
  echo "[selftest] the marker delimiter is 'not a slug character', not merely whitespace (D345)"
  mrk() { # <slug> <line> -> 0 if the predicate says "this line is that slug's marker"
    # ${SITE_SLUG:-}: the selftest runs with `set -u` and no slug of its own —
    # the deploy path is what sets this global.
    local __save="${SITE_SLUG:-}" __rc=0
    printf '%s\n' "$2" > "$TD/mrk.txt"
    SITE_SLUG="$1"; has_site_route_marker "$TD/mrk.txt" || __rc=$?
    SITE_SLUG="$__save"; return "$__rc"
  }
  check "delimiter: a space after the slug matches (what this script writes)" \
    mrk search '# BARKPARK_SITE_ROUTE:search — node site'
  check "delimiter: end-of-line matches" \
    mrk search '# BARKPARK_SITE_ROUTE:search'
  check "delimiter: a hand-edited ':' after the slug STILL reads as armed (no duplicate re-arm)" \
    mrk search '# BARKPARK_SITE_ROUTE:search: node site'
  check "delimiter: a hand-edited '#' after the slug STILL reads as armed" \
    mrk search '# BARKPARK_SITE_ROUTE:search#1'
  if mrk search '# BARKPARK_SITE_ROUTE:search-capstone — node site'; then
    check "delimiter: a PREFIX sibling ('-') is REJECTED" false
  else
    check "delimiter: a PREFIX sibling ('-') is REJECTED" true
  fi
  if mrk search '# BARKPARK_SITE_ROUTE:search2 — node site'; then
    check "delimiter: an alnum-extended sibling is REJECTED" false
  else
    check "delimiter: an alnum-extended sibling is REJECTED" true
  fi
  check "slot a env RELEASE_DIR=n1"      grep -q "RELEASE_DIR=$N_SITE/releases/n1" "$SENV/selftest__a.env"
  # GNU stat first (-c; on Linux `stat -f` SUCCEEDS with filesystem info, so a
  # BSD-first fallback never fires and the check reads garbage on CI runners),
  # BSD (-f '%Lp') second for macOS where -c errors.
  check "slot a env is 0600"             [ "$(stat -c '%a' "$SENV/selftest__a.env" 2>/dev/null || stat -f '%Lp' "$SENV/selftest__a.env")" = 600 ]
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
  check "ROUTE ok says ALREADY-ARMED on a flip, not armed (D346)" \
    grep -q '^BPSTAGE name=ROUTE status=ok build_id=n2 detail="already armed: ' "$TD/out.log"
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
  # systemd-mode DeployRunner finalizes a rollback from BARKPARK_SITE_LOG_FILE (no
  # exit code; no BPSTAGE). A rollback that leaves that log empty is the "died
  # abnormally" bug — assert the flip's markers land where the runner reads them.
  check "rollback wrote ROLLED BACK to the durable log"   grep -q 'ROLLED BACK' "$TD/rblog"
  check "rollback wrote TARGET_BUILD=n1 to the durable log" grep -qx 'TARGET_BUILD=n1' "$TD/rblog"

  echo "[selftest] e2e: a LYING build fails HEALTH (14), never flips, is PURGED, live slot untouched"
  before_port="$(cf_port)"
  : > "$SRC/.lie"
  rc="$(e2e_deploy n3)"
  rm -f "$SRC/.lie"
  check "lying build exit 14"            [ "$rc" = 14 ]
  check "HEALTH failed"                  saw HEALTH failed n3
  check "reason names the wrong marker"  grep -q "bp-build-id marker is .TOTALLY-WRONG" "$TD/out.log"
  # Dual-channel: the reason must ride the plain human log too, not only the
  # BPSTAGE detail=. On a terminal failure the run-level reason_tail (last 3 log
  # lines) wins over stage.detail at the verdict line, so the log line is the copy
  # that survives to the user.
  check "the HEALTH reason ALSO rides the plain human log (dual-channel)" \
    grep -q '\[site-deploy-node .*HEALTH: bp-build-id marker is .TOTALLY-WRONG' "$TD/out.log"
  check "no SWITCH stage line at all"    nosaw SWITCH
  check "Caddy upstream did NOT move"    [ "$(cf_port)" = "$before_port" ]
  check "the poisoned release is purged" [ ! -d "$N_SITE/releases/n3" ]
  # shellcheck disable=SC2016  # $PATH must expand inside sh -c at run time, not now
  check "the just-booted bad slot is stopped" \
    sh -c '! env PATH="'"$FAKEBIN"':$PATH" systemctl is-active --quiet barkpark-site@selftest__b'

  echo "[selftest] e2e: an UNREADABLE CORPUS fails HEALTH and the reason NAMES the upstream condition (403), not just the empty marker"
  before_port="$(cf_port)"
  : > "$SRC/.no-corpus"
  rc="$(E2E_REV=rev-3b e2e_deploy n3b)"
  rm -f "$SRC/.no-corpus"
  check "unreadable-corpus build exit 14"  [ "$rc" = 14 ]
  check "HEALTH failed"                    saw HEALTH failed n3b
  check "the reason names the UPSTREAM 403, read out of bp-corpus-status" \
    grep -q 'bp-doc-id marker is empty .* graph 403: public-read tokens may only read published public documents' "$TD/out.log"
  # Dual-channel, same contract as the lying build: the cause must ride the plain
  # human log too, because the run-level reason_tail is the copy the user sees.
  check "the cause ALSO rides the plain human log (dual-channel)" \
    grep -q '\[site-deploy-node .*HEALTH: bp-doc-id marker is empty .* graph 403: ' "$TD/out.log"
  check "no SWITCH stage line at all"      nosaw SWITCH
  check "Caddy upstream did NOT move (the gate STILL fails closed)" [ "$(cf_port)" = "$before_port" ]
  check "the corpus-less release is purged" [ ! -d "$N_SITE/releases/n3b" ]
  # THE CLASSIFIER'S ANCHOR, asserted by the PRODUCER (deploy-reliability dr-w8
  # S1). `cloud/lib/barkpark_cloud/deploy_ledger.ex` reads the upstream status
  # out of the stored failure_reason with the regex
  #   could not read a content document: graph (\d+):
  # anchored on THIS sentence — the one written a few lines above, in the empty
  # bp-doc-id branch. Reword that English and every one of those rows silently
  # degrades back to the causeless DOC_ID_EMPTY bucket with nothing anywhere
  # failing. So the producer asserts the consumer's anchor against its own
  # emitted bytes: a reflow reds HERE, on the shell side, at edit time.
  check "the emitted marker still matches the CLASSIFIER's anchor (cloud deploy_ledger.ex)" \
    grep -Eq 'could not read a content document: graph [0-9]+:' "$TD/out.log"

  echo "[selftest] e2e: an empty bp-doc-id with NO status marker still refuses, and SAYS the cause went unrecorded"
  before_port="$(cf_port)"
  : > "$SRC/.no-corpus-legacy"
  rc="$(E2E_REV=rev-3c e2e_deploy n3c)"
  rm -f "$SRC/.no-corpus-legacy"
  check "legacy empty-marker build exit 14" [ "$rc" = 14 ]
  check "HEALTH failed"                     saw HEALTH failed n3c
  check "the reason admits the cause is UNRECORDED (never invents one)" \
    grep -q 'no bp-corpus-status marker: this build predates the corpus-status contract' "$TD/out.log"
  check "it does NOT claim a 403"           no_log_match 'graph 403'
  check "no SWITCH stage line at all"       nosaw SWITCH
  check "Caddy upstream did NOT move"       [ "$(cf_port)" = "$before_port" ]

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

  echo "[selftest] e2e: a missing package.json names the next move on BOTH channels (dual-channel hint)"
  NOPKG="$TD/nopkg"; mkdir -p "$NOPKG"
  before_port="$(cf_port)"
  rc="$(env PATH="$FAKEBIN:$PATH" SITE_SLUG=selftest BUILD_ID=np1 CONTENT_REV=rev-1 \
    SITE_SRC="$NOPKG" SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
    BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
    BARKPARK_SITE_DEPLOY_LOCK="$TD/deploy.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    bash "$SELF" > "$TD/out.log" 2> "$TD/err.log"; echo $?)"
  check "no-package.json exit 11"        [ "$rc" = 11 ]
  check "BUILD failed"                   saw BUILD failed np1
  check "the BPSTAGE detail names the check-this-next move" \
    grep -q '^BPSTAGE name=BUILD status=failed .*check the payload points at the app dir' "$TD/out.log"
  check "the SAME hint rides the plain human log (dual-channel, not detail-only)" \
    grep -q '\[site-deploy-node .*has no package.json .* check the payload' "$TD/out.log"
  check "no release dir left behind"     [ ! -d "$N_SITE/releases/np1" ]
  check "Caddy upstream did NOT move"    [ "$(cf_port)" = "$before_port" ]

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

  # -------------------------------------------------------------------------
  # SLOW IS NOT BROKEN (D27). Both halves are DRIVEN here, on their own slug and
  # ports, with the ceilings scaled down (a 2s "slow" render against a 1s fast
  # ceiling is the same shape as a 48s render against 8s) so the proof costs
  # seconds, not minutes. What must differ is the OUTCOME, not the wording alone:
  # one deploys, one refuses.
  # -------------------------------------------------------------------------
  sl_deploy() { # <slug> <build_id> <lock> <port-a> <port-b> [patient-max] -> exit code
    env PATH="$FAKEBIN:$PATH" SITE_SLUG="$1" BUILD_ID="$2" CONTENT_REV=sl-rev \
      SITE_SRC="$SRC" SITE_PORT_A="$4" SITE_PORT_B="$5" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/$3.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      BARKPARK_SITE_HEALTH_ATTEMPTS=2 BARKPARK_SITE_HEALTH_FAST_MAX=1 \
      BARKPARK_SITE_HEALTH_PATIENT_MAX="${6:-20}" \
      bash "${SL_ENGINE:-$SELF}" > "$TD/out.log" 2> "$TD/err.log"; echo $?
  }

  echo "[selftest] e2e: a SLOW site (serves 200, past the per-attempt ceiling) is gated HEALTHY and SAYS it is slow"
  printf '2\n' > "$SRC/.slow-serve"
  rc="$(sl_deploy slowsite sl1 slowsite "$(free_port)" "$(free_port)")"
  rm -f "$SRC/.slow-serve"
  check "slow deploy exit 0 (it renders — refusing it would be a false 'boot failed')" [ "$rc" = 0 ]
  check "HEALTH ok"                            saw HEALTH ok sl1
  check "SWITCH ok (a slow site still goes live)" saw SWITCH ok sl1
  check "the stage detail SAYS SLOW"           grep -q '^BPSTAGE name=HEALTH status=ok .*SLOW:' "$TD/out.log"
  check "the stage detail carries the OBSERVED latency in seconds" \
    grep -qE '^BPSTAGE name=HEALTH status=ok build_id=sl1 detail="200 in [0-9]+\.[0-9]+s' "$TD/out.log"
  check "it names the ceiling it exceeded, not just 'slow'" \
    grep -q 'no 200 inside the 1s per-attempt ceiling' "$TD/out.log"
  check "the SLOW verdict ALSO rides the plain human log (dual-channel)" \
    grep -q '\[site-deploy-node .*HEALTH: SLOW —' "$TD/out.log"
  check "it did NOT report the site as never-serving"  no_log_match 'NEVER served 200'

  echo "[selftest] e2e: a BROKEN site (never 200, even unthrottled) is refused — a DIFFERENT outcome, in different words"
  printf '503\n' > "$SRC/.broken-serve"
  rc="$(sl_deploy brokesite br1 brokesite "$(free_port)" "$(free_port)")"
  rm -f "$SRC/.broken-serve"
  check "broken deploy exit 14 (HEALTH refused)"  [ "$rc" = 14 ]
  check "HEALTH failed"                           saw HEALTH failed br1
  check "the detail says NEVER served 200"        grep -q 'NEVER served 200' "$TD/out.log"
  check "the detail calls it BROKEN, not slow"    grep -q 'BROKEN, not slow' "$TD/out.log"
  check "it records the patient probe's own reading too" \
    grep -q 'AND a patient 20s probe' "$TD/out.log"
  check "it did NOT claim the site was merely slow" \
    sh -c "! grep -q 'HEALTH: SLOW —' '$TD/out.log'"
  check "no SWITCH stage line at all"             nosaw SWITCH
  check "the broken release is purged"            [ ! -d "$TD/sites/brokesite/releases/br1" ]

  echo "[selftest] e2e: MUTATION PROOF — take the patient headroom away and the SAME slow site is misdiagnosed as broken"
  # This is the bug, reproduced on demand: with the patient ceiling collapsed to
  # the fast one (1s — what a single-ceiling gate is), the site that just deployed
  # green is refused, and refused with the BROKEN wording. The distinction is
  # therefore load-bearing, not decorative.
  printf '2\n' > "$SRC/.slow-serve"
  rc="$(sl_deploy slowsite2 sl2 slowsite2 "$(free_port)" "$(free_port)" 1)"
  rm -f "$SRC/.slow-serve"
  check "MUTANT: no headroom -> the identical slow site exits 14"  [ "$rc" = 14 ]
  check "MUTANT: and it is called BROKEN, which is the false diagnosis being fixed" \
    grep -q 'BROKEN, not slow' "$TD/out.log"

  # -------------------------------------------------------------------------
  # A TRUNCATED 200 IS NOT A CONTENT FACT (task-60ee738ee0555798).
  #
  # THE SHAPE, and why it is not caught by the SLOW/BROKEN pair above: an SSR
  # that STREAMS past the per-attempt ceiling answers http_code=200 (the status
  # line arrived) with curl exit 28 (the body was cut mid-stream). The old
  # `[ "$code" = 200 ] && break` read only the first number, so the gate walked
  # on to the marker assertions holding a PARTIAL document — and the markers are
  # asymmetrically placed: bp-build-id and bp-content-rev are literal <head>
  # children (templates/search-starter/app/layout.tsx) and arrive in the first
  # flush, bp-doc-id comes from the page component (app/(finder)/page.tsx) later
  # in the stream. Truncated bytes therefore PASS two assertions and FAIL the
  # third, landing in the empty-bp-doc-id branch, which — finding no
  # bp-corpus-status marker in bytes it never finished reading — states "the SSR
  # rendered no content document (no bp-corpus-status marker: this build predates
  # the corpus-status contract…)". Every clause of that is false about a current
  # build: it DID emit the marker and it DID render a document; the probe stopped
  # reading. The row then lands as DOC_ID_EMPTY (:ambiguous) and the
  # misattribution survives into the census.
  #
  # The `.no-corpus-legacy` case above pins that SAME sentence as HONEST for the
  # build that genuinely emits no marker. Both cases reach one branch, so the
  # branch was simultaneously proven honest and reachable dishonestly — which is
  # exactly why the fix is upstream of it, in what counts as a 200 at all.
  #
  # Fixture: `.truncate-serve` holds a mid-body stall in seconds. Two ceilings,
  # two outcomes, because the ceiling is the whole variable:
  #   RECOVERABLE   stall 2s vs fast 1s / patient 20s — the fast poll truncates,
  #                 the patient probe reads the document whole: deploy GREEN, SLOW.
  #   UNRECOVERABLE stall 8s vs fast 1s / patient 3s  — even the patient probe is
  #                 cut: refuse, naming the TRUNCATION, never the content.
  # -------------------------------------------------------------------------
  echo "[selftest] e2e: a TRUNCATED fast read is NOT accepted as a 200 — the patient probe reads the document whole and the site deploys"
  printf '2\n' > "$SRC/.truncate-serve"
  rc="$(sl_deploy truncsite tr1 truncsite "$(free_port)" "$(free_port)" 20)"
  rm -f "$SRC/.truncate-serve"
  check "truncating-then-complete deploy exit 0"   [ "$rc" = 0 ]
  check "HEALTH ok"                                saw HEALTH ok tr1
  check "SWITCH ok (the document WAS readable — just not inside the fast ceiling)" \
    saw SWITCH ok tr1
  check "the fast loop REFUSED the truncated 200 instead of breaking on it" \
    grep -q 'answered 200 but curl exited 28 — the body was cut at the 1s ceiling' "$TD/out.log"
  check "and it fell through to the patient probe, naming the truncated fast read" \
    grep -q 'no clean 200 in 2 attempts at the 1s ceiling (last: 200-but-TRUNCATED)' "$TD/out.log"
  check "the bp-doc-id it reports is the one from the COMPLETE read" \
    grep -q 'bp-doc-id=doc-42' "$TD/out.log"
  # THE FABRICATION, named. This is the sentence the truncated bytes used to
  # produce, and it must not appear on a run whose document was readable.
  check "it never claims the SSR rendered no content document" \
    no_log_match 'the SSR rendered no content document'
  check "it never claims the build predates the corpus-status contract" \
    no_log_match 'predates the corpus-status contract'

  echo "[selftest] e2e: a read TRUNCATED even at the patient ceiling refuses by naming the TRUNCATION — never as a fact about the content"
  printf '8\n' > "$SRC/.truncate-serve"
  rc="$(sl_deploy truncsite2 tr2 truncsite2 "$(free_port)" "$(free_port)" 3)"
  rm -f "$SRC/.truncate-serve"
  check "unreadable-within-the-ceiling deploy exit 14" [ "$rc" = 14 ]
  check "HEALTH failed"                            saw HEALTH failed tr2
  check "the detail says the body was TRUNCATED, with the seconds and the curl exit" \
    grep -qE 'the body was TRUNCATED after [0-9]+\.[0-9]+s \(curl exit 28\)' "$TD/out.log"
  check "it names the patient ceiling the read was cut at" \
    grep -q 'cut at the patient 3s ceiling after 2 attempts at the 1s fast ceiling' "$TD/out.log"
  check "it says the run states NOTHING about the site's content" \
    grep -q "an unfinished READ, not an empty document" "$TD/out.log"
  check "the TRUNCATION verdict ALSO rides the plain human log (dual-channel)" \
    grep -q '\[site-deploy-node .*HEALTH: slot .* the body was TRUNCATED' "$TD/out.log"
  # THE CLASSIFIER, asserted by the PRODUCER (same contract as the graph-code
  # anchor above). `DeployLedger.classify/2` reaches DOC_ID_EMPTY on
  # `stage == "HEALTH" and reason =~ "bp-doc-id marker is empty"`, and that class
  # MEANS "the marker was empty and nothing recorded why" (agency :ambiguous).
  # A truncated read is not that fact, so the detail must not carry the phrase —
  # `Sites.Deploy.stage_failure_copy/1` prefixes it "HEALTH failed — ", which
  # routes it to `health_gate?/1` instead: HEALTH_GATE_FAILED, agency :box, the
  # same class the never-200 refusal already lands in. NO cloud-side change: put
  # the phrase back into this sentence and the ledger silently re-acquires the
  # fabricated class, so the anchor is asserted HERE, at edit time.
  check "the detail carries NO 'bp-doc-id marker is empty' (would re-class it DOC_ID_EMPTY)" \
    no_log_match 'bp-doc-id marker is empty'
  check "and no invented corpus cause"             no_log_match 'predates the corpus-status contract'
  check "it did NOT report the site as never-serving (it DID serve 200)" \
    no_log_match 'NEVER served 200'
  check "no SWITCH stage line at all"              nosaw SWITCH
  check "Caddy never got a route for the refused site" \
    sh -c "! grep -q 'BARKPARK_SITE_ROUTE:truncsite2' '$CF'"
  check "the unreadable release is purged"         [ ! -d "$TD/sites/truncsite2/releases/tr2" ]

  echo "[selftest] e2e: MUTATION PROOF — throw curl_rc away and the readable site is refused with the FABRICATED content diagnosis"
  # ONE LINE, and it is the row's title verbatim: `clean_200` stops consulting
  # its second argument, which is what `[ "$code" = 200 ] && break` did. With it,
  # the fast poll breaks on the truncated 200, the patient probe never runs, the
  # truncation refusal is unreachable, and the marker assertions read partial
  # bytes — reproducing the fabricated sentence on a site that renders fine.
  TRMUT="$TD/mutant-drops-curl-rc.sh"; TRMUTLIB="$TD/lib"
  mkdir -p "$TRMUTLIB"
  cp "$(cd "$(dirname "$SELF")" && pwd)/lib/site-deploy-common.sh" "$TRMUTLIB/"  # a mutant sources by its OWN dirname
  awk '{ if ($0 == "  [ \"$1\" = 200 ] && [ \"$2\" = 0 ]") print "  [ \"$1\" = 200 ]"; else print }' \
    "$SELF" > "$TRMUT"
  check "the mutant differs by exactly ONE line (the mutation APPLIED)" \
    [ "$(diff "$SELF" "$TRMUT" | grep -c '^[<>]')" = 2 ]
  printf '2\n' > "$SRC/.truncate-serve"
  mrc="$(SL_ENGINE="$TRMUT" sl_deploy truncsite3 tr3 truncsite3 "$(free_port)" "$(free_port)" 20)"
  rm -f "$SRC/.truncate-serve"
  check "MUTANT: the identical readable site is REFUSED (exit 14)"  [ "$mrc" = 14 ]
  check "MUTANT: and the reason is the FABRICATED content diagnosis" \
    grep -q 'the SSR rendered no content document (no bp-corpus-status marker: this build predates the corpus-status contract' "$TD/out.log"
  check "MUTANT: which would land as DOC_ID_EMPTY — the classifier's own anchor" \
    grep -q 'bp-doc-id marker is empty' "$TD/out.log"
  check "MUTANT: and the truncation was never named at all" \
    no_log_match 'the body was TRUNCATED'
  echo "  mutation proof: with clean_200 reduced to '[ \"\$1\" = 200 ]', a site whose document IS readable at the patient ceiling exits 14 and reports 'the SSR rendered no content document … predates the corpus-status contract' — the three checks above (fast loop refused the truncated 200 / fell through to the patient probe / never claims no content document) all red"

  echo "[selftest] build_failure_reason resolves from the SHARED lib in THIS engine too"
  # The lift's whole point: one copy, both engines. If it ever gets re-forked into
  # an engine, the Console harness reds; if it goes MISSING from the lib, this
  # does. Pinned against the same RECORDED 30,993-byte Turbopack failure.
  N_FIXLOG="$(cd "$(dirname "$SELF")" && pwd)/testdata/capstone-turbopack-build-fail.txt"
  check "the recorded producer is committed"     [ -f "$N_FIXLOG" ]
  has_fn() { type "$1" >/dev/null 2>&1; }
  check "the node engine can call the shared extractor" has_fn build_failure_reason
  if [ -f "$N_FIXLOG" ]; then
    check "it yields the SAME line the static engine yields (no per-engine drift)" \
      [ "$(build_failure_reason "$N_FIXLOG")" = "Error: Turbopack build failed with 29 errors: ./sites/search-capstone/src/app/(finder)/page.tsx:1:1 Module not found: Can't resolve '@/components/desktop-only'" ]
    build_failure_reason "$N_FIXLOG" > "$TD/n-fix-reason.txt"
    check "the CAUSE — not merely the count — crosses the engine boundary too" \
      grep -q "Can't resolve" "$TD/n-fix-reason.txt"
  fi

  echo "[selftest] rollback preflight is read-only + typed"
  # Fresh site with no previous -> not_supported / no_previous.
  rc="$(env PATH="$FAKEBIN:$PATH" SITE_SLUG=fresh SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
        BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
        BARKPARK_SITE_DEPLOY_LOCK="$TD/fresh.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
        bash "$SELF" --rollback-preflight >/dev/null 2>&1; echo $?)"
  check "preflight on a never-deployed site refuses (22)" [ "$rc" = 22 ]

  echo "[selftest] e2e: an ORPHANED build survives a mid-build kill (durable file contract)"
  # The re-attach contract: DeployRunner names a persistent status fold + a raw
  # build log; emit() appends every BPSTAGE line to the fold, and BUILD tees the
  # child's RAW stdout/stderr to the log. When barkpark.service restarts, the BEAM
  # parent dies but the build (in the outer transient unit) keeps running. Model it:
  # run the engine in the BACKGROUND with the two files set, wait until the build is
  # mid-flight, then kill ONLY the top-level engine pid — captured via the caller's
  # $! (never $$ inside a backgrounded function, which is the parent shell's pid on
  # bash 3.2). Assert the on-disk fold is a truthful PARTIAL and the raw log
  # survived, readable with zero live process.
  R_STATUS="$TD/reattach.status"; R_LOG="$TD/reattach.rawlog"
  rm -f "$R_STATUS" "$R_LOG" "$SRC/.slow-build-pid"
  : > "$SRC/.slow-build"
  env PATH="$FAKEBIN:$PATH" \
    SITE_SLUG=reattach BUILD_ID=re1 CONTENT_REV=rev-1 SITE_SRC="$SRC" \
    SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
    BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
    BARKPARK_SITE_DEPLOY_LOCK="$TD/reattach.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    BARKPARK_SITE_STATUS_FILE="$R_STATUS" BARKPARK_SITE_LOG_FILE="$R_LOG" \
    bash "$SELF" > "$TD/reattach.out" 2>&1 &
  R_ENGINE_PID=$!
  for _i in $(seq 1 100); do [ -f "$SRC/.slow-build-pid" ] && break; sleep 0.1; done
  kill -9 "$R_ENGINE_PID" 2>/dev/null || true
  wait "$R_ENGINE_PID" 2>/dev/null || true
  # Signal the orphaned build to exit (leak-proof — the reparented loop notices the
  # sentinel is gone within 0.1s), best-effort kill its pid too, then let the now
  # EOF'd tee flush the raw log to disk before we assert on it.
  rm -f "$SRC/.slow-build"
  [ -f "$SRC/.slow-build-pid" ] && kill -9 "$(cat "$SRC/.slow-build-pid")" 2>/dev/null
  for _i in $(seq 1 50); do [ -s "$R_LOG" ] && break; sleep 0.1; done
  rm -f "$SRC/.slow-build-pid"
  check "reattach: status fold recorded BUILD started (durable, survived the kill)" \
    grep -q '^BPSTAGE name=BUILD status=started' "$R_STATUS"
  check "reattach: the fold is a truthful PARTIAL (no SWITCH stage reached)" \
    sh -c "! grep -q '^BPSTAGE name=SWITCH' '$R_STATUS'"
  check "reattach: raw build log persisted (NOT deleted), readable with no live process" \
    test -s "$R_LOG"
  check "reattach: the log carries RAW child output, not BPSTAGE lines" \
    sh -c "grep -q 'building the site' '$R_LOG' && ! grep -q '^BPSTAGE' '$R_LOG'"

  # -------------------------------------------------------------------------
  # THE PREFIX COLLISION (D345) — the whole corrupted-read chain, end to end.
  #
  # LIVE SHAPE: `search` is a strict PREFIX of `search-capstone`. With a
  # bare-substring marker read, active_caddy_port returns the SIBLING'S port,
  # active_slot compares it to this site's PORT_A/PORT_B, matches NEITHER and
  # prints nothing, CUR_SLOT comes back EMPTY — so EVERY deploy takes the
  # phantom first-deploy ARM branch, the arm's already-armed guard matches the
  # sibling and returns 0 WITHOUT WRITING, and the run emits SWITCH ok at exit 0
  # over a public 404. Measured: 208 deploys in 36h, 206 of them "for slot a",
  # ZERO slot b, no .previous file — i.e. blue/green rollback silently absent too.
  #
  # BOTH DIRECTIONS, because a too-strict predicate silently un-arms every site
  # that works today: the prefix slug must arm and then FLIP on its own ports,
  # and the sibling's upstream must never move when the prefix site deploys.
  # -------------------------------------------------------------------------
  echo "[selftest] e2e: a PREFIX slug gets its own route, its own slots and a real blue/green flip (D345)"
  px_port() { # <slug> — the upstream port inside THAT slug's marker block, anchored
    awk -v m="BARKPARK_SITE_ROUTE:$1([[:space:]]|\$)" \
      '$0 ~ m {i=1} i&&match($0,/localhost:[0-9]+/){print substr($0,RSTART+10,RLENGTH-10);exit}' "$CF"
  }
  px_deploy() { # <slug> <build_id> <port_a> <port_b>
    env PATH="$FAKEBIN:$PATH" SITE_SLUG="$1" BUILD_ID="$2" CONTENT_REV="rev-$2" \
      SITE_SRC="$SRC" SITE_PORT_A="$3" SITE_PORT_B="$4" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" BARKPARK_CADDYFILE="$CF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/px-$1.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_SITE_HEALTH_PATH=/ BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" > "$TD/px-$2.out" 2>&1; echo $?
  }
  # (1) the LONGER sibling arms, then flips onto its OWN second slot.
  rc="$(px_deploy pfxn-capstone q1 "$T_PORT_G" "$T_PORT_H")"
  check "prefix/node: the LONGER sibling's first deploy exits 0"   [ "$rc" = 0 ]
  rc="$(px_deploy pfxn-capstone q2 "$T_PORT_G" "$T_PORT_H")"
  check "prefix/node: the sibling flipped onto its second slot"    [ "$(px_port pfxn-capstone)" = "$T_PORT_H" ]
  # (2) THE CASE — the prefix slug deploys with the sibling's marker already in
  #     the file. Every assertion below REDS on a bare-substring predicate.
  rc="$(px_deploy pfxn q3 "$T_PORT_I" "$T_PORT_J")"
  check "prefix/node: the PREFIX slug's first deploy exits 0"      [ "$rc" = 0 ]
  check "prefix/node: it ARMED ITS OWN marker block" \
    grep -qE 'BARKPARK_SITE_ROUTE:pfxn([[:space:]]|$)' "$CF"
  check "prefix/node: its upstream is ITS OWN slot-a port, not the sibling's" \
    [ "$(px_port pfxn)" = "$T_PORT_I" ]
  check "prefix/node: ROUTE reports ARMED on the durable channel" \
    grep -q '^BPSTAGE name=ROUTE status=ok build_id=q3 detail="armed: ' "$TD/px-q3.out"
  check "prefix/node: the sibling's upstream did NOT move"         [ "$(px_port pfxn-capstone)" = "$T_PORT_H" ]
  # (3) THE CHAIN IS BROKEN: active_caddy_port -> active_slot -> CUR_SLOT is no
  #     longer empty, so the SECOND deploy is a real blue/green FLIP and not
  #     another phantom first deploy (208 of which happened live).
  rc="$(px_deploy pfxn q4 "$T_PORT_I" "$T_PORT_J")"
  check "prefix/node: the prefix slug's SECOND deploy exits 0"     [ "$rc" = 0 ]
  check "prefix/node: it FLIPPED to slot b (CUR_SLOT was read, not empty)" \
    [ "$(px_port pfxn)" = "$T_PORT_J" ]
  check "prefix/node: ROUTE says already-armed, i.e. NOT a phantom first deploy" \
    grep -q '^BPSTAGE name=ROUTE status=ok build_id=q4 detail="already armed: ' "$TD/px-q4.out"
  check "prefix/node: .previous now exists (blue/green rollback is possible at all)" \
    [ -s "$TD/sites/pfxn/.previous" ]
  check "prefix/node: exactly ONE marker for the prefix slug (never re-armed)" \
    [ "$(grep -cE 'BARKPARK_SITE_ROUTE:pfxn([[:space:]]|$)' "$CF" | tr -d ' ')" = 1 ]
  # (4) THE REVERSE DIRECTION — the blast-radius guard. The stricter predicate
  #     must still match a site's OWN marker, or it un-arms the sites that work.
  rc="$(px_deploy pfxn-capstone q5 "$T_PORT_G" "$T_PORT_H")"
  check "prefix/node/reverse: the LONGER slug still finds its own block"  [ "$rc" = 0 ]
  check "prefix/node/reverse: and flips back onto its own slot a"   [ "$(px_port pfxn-capstone)" = "$T_PORT_G" ]
  check "prefix/node/reverse: the PREFIX site's upstream was untouched"   [ "$(px_port pfxn)" = "$T_PORT_J" ]

  echo "[selftest] e2e: --teardown stops BOTH slots, disarms the Caddy route, deletes the tree"
  # selftest was armed into $CF with two slot units; tear the whole site down. The
  # 'warm' site's route must survive (single-site excision), and its slots too.
  env PATH="$FAKEBIN:$PATH" \
    SITE_SLUG=selftest SITE_PORT_A="$T_PORT_A" SITE_PORT_B="$T_PORT_B" \
    BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
    BARKPARK_CADDYFILE="$CF" BARKPARK_SITE_DEPLOY_LOCK="$TD/deploy.lock" \
    BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    bash "$SELF" --teardown > "$TD/td.out" 2>&1; tdrc=$?
  check "node teardown exit 0"                     [ "$tdrc" = 0 ]
  check "node teardown printed TORN_DOWN=selftest" grep -q '^TORN_DOWN=selftest' "$TD/td.out"
  check "node teardown deleted the release tree"   [ ! -d "$N_SITE" ]
  check "node teardown removed the selftest route" \
    sh -c '! grep -q "BARKPARK_SITE_ROUTE:selftest" "'"$CF"'"'
  check "node teardown stopped slot a" \
    sh -c '! env PATH="'"$FAKEBIN"':$PATH" systemctl is-active --quiet barkpark-site@selftest__a'
  check "node teardown stopped slot b" \
    sh -c '! env PATH="'"$FAKEBIN"':$PATH" systemctl is-active --quiet barkpark-site@selftest__b'
  check "node teardown SPARED the neighbour 'warm' route" \
    grep -q 'BARKPARK_SITE_ROUTE:warm' "$CF"
  check "node teardown SPARED the neighbour warm slot a" \
    env PATH="$FAKEBIN:$PATH" systemctl is-active --quiet barkpark-site@warm__a
  check "node teardown is idempotent (second run exit 0)" \
    sh -c 'env PATH="'"$FAKEBIN"':$PATH" SITE_SLUG=selftest BARKPARK_SITES_DIR="'"$TD"'/sites" BARKPARK_SLOT_ENV_DIR="'"$SENV"'" BARKPARK_CADDYFILE="'"$CF"'" BARKPARK_SITE_DEPLOY_LOCK="'"$TD"'/deploy.lock" BARKPARK_CADDYFILE_LOCK="'"$TD"'/caddyfile.lock" BARKPARK_SITE_NO_CAP=1 bash "'"$SELF"'" --teardown >/dev/null 2>&1'

  echo "[selftest] --teardown REFUSES to claim TORN_DOWN when caddy validate rejects the disarm (D77)"
  # The ONE case $FAKEBIN/caddy (validate always exits 0) structurally cannot
  # reach: a REJECTING validate makes commit_caddyfile revert, so the 'warm' route
  # keeps serving. The engine must not print TORN_DOWN= (the only marker the CP
  # reads — its presence alone is exit 0), must exit 25, and must keep the release
  # tree AND the slot env files. On origin/main every one of these fails.
  REJBIN="$TD/bin-reject"; mkdir -p "$REJBIN"
  printf '#!/usr/bin/env bash\ncase "$1" in validate) exit 1;; *) exit 0;; esac\n' > "$REJBIN/caddy"
  chmod +x "$REJBIN/caddy"   # everything else still resolves from $FAKEBIN
  env PATH="$REJBIN:$FAKEBIN:$PATH" \
    SITE_SLUG=warm SITE_PORT_A="$T_PORT_C" SITE_PORT_B="$T_PORT_D" \
    BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
    BARKPARK_CADDYFILE="$CF" BARKPARK_SITE_DEPLOY_LOCK="$TD/warm.lock" \
    BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" BARKPARK_SITE_LOG_FILE="$TD/td-reject.log" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    bash "$SELF" --teardown > "$TD/td-reject.out" 2>&1; tdrc3=$?
  check "node rejected teardown exits 25 (not 0)"   [ "$tdrc3" = 25 ]
  check "node rejected teardown printed NO TORN_DOWN= on stdout" \
    sh -c "! grep -q 'TORN_DOWN=' '$TD/td-reject.out'"
  check "node rejected teardown logged NO TORN_DOWN= durably" \
    sh -c "! grep -q 'TORN_DOWN=' '$TD/td-reject.log'"
  check "node rejected teardown printed the typed failure on stdout" \
    grep -q '^TEARDOWN_FAILED=warm detail="' "$TD/td-reject.out"
  check "node rejected teardown logged the typed failure durably" \
    grep -q '^TEARDOWN_FAILED=warm detail="' "$TD/td-reject.log"
  check "node rejected teardown KEPT the release tree (recoverable)" [ -d "$TD/sites/warm/releases/w3" ]
  check "node rejected teardown KEPT both slot env files (slots restartable)" \
    sh -c "[ -f '$SENV/warm__a.env' ] && [ -f '$SENV/warm__b.env' ]"
  check "node rejected teardown KEPT the live route (reverted, still serving)" \
    grep -q 'BARKPARK_SITE_ROUTE:warm' "$CF"
  check "node rejected teardown claims a MEASURED still-live route" \
    grep -q 'STILL LIVE' "$TD/td-reject.out"
  check "node rejected teardown does NOT hedge — it made the measurement" \
    sh -c "! grep -q 'NEVER CHECKED' '$TD/td-reject.out'"

  echo "[selftest] --teardown says UNKNOWN, not 'still live', when the Caddyfile lock was never taken (D77)"
  # The OTHER non-zero from with_caddy_lock, and a DIFFERENT claim: nothing read
  # the Caddyfile, so "still live" would be a measurement this run never made. The
  # fake grants the non-blocking DEPLOY lock (`flock -n 9`) and denies only the
  # WAITING Caddyfile lock (`flock -w 120 8`).
  LOCKBIN="$TD/bin-lock"; mkdir -p "$LOCKBIN"
  printf '#!/usr/bin/env bash\ncase "$1" in -w) exit 1;; *) exit 0;; esac\n' > "$LOCKBIN/flock"
  chmod +x "$LOCKBIN/flock"
  cp "$CF" "$TD/cf-before-lockstarve"
  env PATH="$LOCKBIN:$FAKEBIN:$PATH" \
    SITE_SLUG=warm SITE_PORT_A="$T_PORT_C" SITE_PORT_B="$T_PORT_D" \
    BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
    BARKPARK_CADDYFILE="$CF" BARKPARK_SITE_DEPLOY_LOCK="$TD/warm.lock" \
    BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" BARKPARK_SITE_LOG_FILE="$TD/td-lock.log" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    bash "$SELF" --teardown > "$TD/td-lock.out" 2>&1; tdrc4=$?
  check "node lock-starved teardown exits 25 (not 0)" [ "$tdrc4" = 25 ]
  check "node lock-starved teardown printed NO TORN_DOWN=" \
    sh -c "! grep -q 'TORN_DOWN=' '$TD/td-lock.out'"
  check "node lock-starved teardown printed the typed failure" \
    grep -q '^TEARDOWN_FAILED=warm detail="' "$TD/td-lock.out"
  check "node lock-starved teardown says the route was NEVER CHECKED" \
    grep -q 'NEVER CHECKED' "$TD/td-lock.out"
  check "node lock-starved teardown does NOT claim a route it never read" \
    sh -c "! grep -q 'STILL LIVE' '$TD/td-lock.out'"
  check "node lock-starved teardown KEPT the release tree" [ -d "$TD/sites/warm/releases/w3" ]
  check "node lock-starved teardown left the Caddyfile byte-identical" \
    cmp -s "$TD/cf-before-lockstarve" "$CF"

  # -------------------------------------------------------------------------
  # THE FLEET BUILD ADMISSION GATE — one box, one build (D95/D104), node side.
  #
  # THE HAZARD THIS EXISTS FOR: fd 7 is inherited by children, and THIS engine's
  # HEALTH stage BOOTS THE SLOT PROCESS, which outlives the run by design (it is
  # what serves the site). Hold the slot past BUILD ok and that process inherits
  # the box's only build slot and keeps it for the LIFETIME OF THE SITE — one
  # deploy permanently denies every other site's build, fleet-wide, and no reaper
  # exists to notice. The probe is the real semantic, not fd introspection: after
  # a completed deploy, can anyone else still TAKE the slot?
  #
  # Needs a REAL flock(1) — the FAKEBIN above stubs it to `exit 0`, and a gate
  # proven against that stub proves the stub.
  # -------------------------------------------------------------------------
  if ! command -v flock >/dev/null 2>&1; then
    if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
      echo "[selftest] FAIL - the fleet build admission gate proof is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but flock(1) is missing from PATH — install util-linux on this runner; a gate proven against the fake exit-0 flock proves the stub, and a skipped gate proof must not report PASS"
      exit 1
    fi
    echo "[selftest] SKIP fleet build admission gate — needs a REAL flock(1) (stock macOS ships none; brew install flock)"
  else
    NG="$TD/gate"; GBIN="$NG/bin"; GSRC="$NG/src"; GLIB="$NG/lib"
    mkdir -p "$NG" "$GBIN" "$GSRC" "$GLIB"
    ENGINE_DIR="$(cd "$(dirname "$SELF")" && pwd)"
    cp "$ENGINE_DIR/lib/site-deploy-common.sh" "$GLIB/"      # a mutant sources by its OWN dirname
    # GBIN is FAKEBIN MINUS the flock stub: same fake npm/caddy/systemctl, real flock.
    for gf in "$FAKEBIN"/*; do
      case "$(basename "$gf")" in flock) ;; *) ln -sf "$gf" "$GBIN/" ;; esac
    done
    printf '{"name":"selftest-gate-site","private":true}\n' > "$GSRC/package.json"
    g_free() { flock -n "$NG/build.lock" -c true 2>/dev/null; }
    g_kill_tree() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do g_kill_tree "$c"; done
      kill -9 "$p" 2>/dev/null || true; }
    # ONE SLUG PER CASE, deliberately. With the flock STUB every other e2e case
    # above can redeploy a slug freely; with the REAL flock this block needs, the
    # HARNESS's fake systemctl launches the slot process as a DIRECT CHILD of the
    # engine, so that process inherits fd 9 — the PER-SLUG deploy lock — and the
    # next deploy of the SAME slug queues on it for 1200s. That is an artifact of
    # the fake (on a real box `systemctl restart` hands the spawn to PID 1, which
    # inherits nothing), but it is a 20-minute hang if you reuse a slug here.
    ng_deploy() { # <slug> <build_id> [VAR=value…] -> exit code; log at $NG/out.log
      local slug="$1" bid="$2" pa pb; shift 2
      pa="$(free_port)"; pb="$(free_port)"
      env PATH="$GBIN:$PATH" "$@" \
        SITE_SLUG="$slug" BUILD_ID="$bid" CONTENT_REV=rev-1 \
        SITE_SRC="$GSRC" SITE_PORT_A="$pa" SITE_PORT_B="$pb" \
        BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
        BARKPARK_CADDYFILE="$CF" \
        BARKPARK_SITE_DEPLOY_LOCK="$NG/deploy-$slug.lock" \
        BARKPARK_CADDYFILE_LOCK="$NG/caddyfile.lock" \
        BARKPARK_BUILD_GATE_LOCK="$NG/build.lock" \
        BARKPARK_NODE_LINK="$TD/barkpark-node" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "${GATE_ENGINE:-$SELF}" > "$NG/out.log" 2>&1
      echo $?
    }
    ng_saw() { grep -q "^BPSTAGE name=$1 status=$2 " "$NG/out.log"; }

    echo "[selftest] gate: the booted slot process must NOT inherit the box's build slot"
    check "the slot is free before the deploy"      g_free
    rc="$(ng_deploy gatesite ng1)"
    check "node deploy exit 0"                      [ "$rc" = 0 ]
    check "the deploy really built"                 grep -q 'npm run build' "$GSRC/.npm-calls"
    check "the slot process is RUNNING (it outlives the run)" \
      sh -c "[ -f '$SLOTPIDS/gatesite__a' ] && kill -0 \"\$(cat '$SLOTPIDS/gatesite__a')\" 2>/dev/null"
    check "THE SLOT IS FREE with that process still alive (fd 7 was released)" g_free

    echo "[selftest] gate: MUTATION PROOF — delete build_gate_release and the slot leaks into that process"
    NGMUT="$NG/mutant-norelease.sh"
    awk '{ if ($0 == "  build_gate_release") next; print }' "$SELF" > "$NGMUT"
    check "the mutant differs by exactly ONE deleted line" \
      [ "$(diff "$SELF" "$NGMUT" | grep -c '^[<>]')" = 1 ]
    mrc="$(GATE_ENGINE="$NGMUT" ng_deploy gatesite2 ng2)"
    check "MUTANT: the deploy itself still succeeds (the leak is SILENT)" [ "$mrc" = 0 ]
    if g_free; then ng_leak=0; else ng_leak=1; fi
    check "MUTANT: the slot is STILL HELD after the run — a fleet-wide deny with no reaper" \
      [ "$ng_leak" = 1 ]
    echo "  mutation proof: with 'build_gate_release' deleted, 'flock -n $NG/build.lock -c true' is REFUSED after a SUCCESSFUL deploy — the healthy check above (THE SLOT IS FREE with that process still alive) reds, and nothing on the box ever frees it"
    # Free it again: only the booted slot process holds it now.
    ng_slotpid="$(cat "$SLOTPIDS/gatesite2__a" 2>/dev/null || true)"
    [ -n "$ng_slotpid" ] && g_kill_tree "$ng_slotpid"
    ngn=0; while ! g_free && [ "$ngn" -lt 60 ]; do sleep 0.1; ngn=$((ngn + 1)); done
    check "killing the leaking slot process is the only way back" g_free

    echo "[selftest] gate: a lapsed budget refuses on the stage protocol (SKIP_BUILD-keyed, set -u safe)"
    # The foreign holder exits on a sentinel, not a signal: a killed holder prints
    # job-control noise over the suite's output, and this fixture is not what the
    # SIGKILL case (static engine) proves. Hard cap ~60s so it cannot wedge CI.
    : > "$NG/pinned"
    flock "$NG/build.lock" -c "n=0; while [ -f '$NG/pinned' ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done" &
    ngn=0; while g_free && [ "$ngn" -lt 60 ]; do sleep 0.1; ngn=$((ngn + 1)); done
    check "a foreign holder pinned the only slot"   sh -c "! flock -n '$NG/build.lock' -c true 2>/dev/null"
    : > "$GSRC/.npm-calls"
    rc="$(ng_deploy gatesite3 ng3 BARKPARK_BUILD_GATE_WAIT=1)"
    check "refused with the typed 15"               [ "$rc" = 15 ]
    check "emitted BUILD failed BEFORE exiting"     ng_saw BUILD failed
    check "the detail names the FLEET BUILD SLOT"   grep -q 'FLEET BUILD SLOT' "$NG/out.log"
    check "ran NO npm"                              [ ! -s "$GSRC/.npm-calls" ]
    check "no unbound-variable abort (this engine has NO PLAN_MODE)" \
      sh -c "! grep -q 'unbound variable' '$NG/out.log'"
    check "the release was never staged"            [ ! -d "$TD/sites/gatesite3/releases/ng3" ]
    rm -f "$NG/pinned"
    ngn=0; while ! g_free && [ "$ngn" -lt 60 ]; do sleep 0.1; ngn=$((ngn + 1)); done

  fi

  # ---- the shipped unit template records a deliberate stop as SUCCESS ---------
  # stop_slot() above is on the NORMAL deploy paths (RETIRE's cold slot, D67; the
  # HEALTH-gate unwind, exit 14). A Next.js standalone server traps SIGTERM and
  # returns 143, which systemd calls a failure unless the unit says otherwise — so
  # without SuccessExitStatus=143 every successful deploy leaves `failed` units
  # behind and an operator reading `systemctl list-units 'barkpark-site@*'` cannot
  # separate a retired slot from a crashed one. This is a STATIC check of the file
  # instance-deploy.sh installs, because nothing else in this suite reads it: a
  # fake systemctl cannot observe a real unit's exit-status policy.
  # =========================================================================
  # STAGE MUST NOT DESTROY A LIVE-OR-PREVIOUS RELEASE.
  # purge_failed_release_node deliberately KEEPS the bytes of a release a live or
  # warm-previous slot still points at ("keeping its bytes, marking it
  # health-failed") precisely so the <1s rollback path survives.  PLAN then routes
  # a redeploy of that build into its health-failed arm (SKIP_BUILD=0) — which is
  # the ONLY path on this engine that runs STAGE against an already-existing
  # release dir, and therefore the only path the up-front `rm -rf "$RELDIR"`
  # could ever reach.  It reached it: one function preserved the rollback target
  # and the next one deleted it, and a copy that then failed (exit 13, ordinary on
  # a full mount) left .previous naming a directory that no longer existed.
  # Driven through the REAL verbs below, with a REAL mid-STAGE copy failure —
  # never read off the source.
  # =========================================================================
  echo "[selftest] e2e: MUTATION — the pre-fix STAGE loses the rollback target, this one keeps it"

  # A cp that copies genuine bytes and THEN reports failure (the ENOSPC shape).
  # Armed only by BP_CP_FAIL_LOG and only for the staging copy (destination ends
  # in `.partial/`), so every other cp in this suite is the real one, and the log
  # it appends to is the non-vacuity sentinel: an empty cp.log means the copy the
  # whole proof rests on never ran.
  RBBIN="$TD/rb-bin"; mkdir -p "$RBBIN"
  cat > "$RBBIN/cp" <<'FAKECP'
#!/usr/bin/env bash
real=/bin/cp; [ -x "$real" ] || real=/usr/bin/cp
"$real" "$@"; rc=$?
[ "$rc" -ne 0 ] && exit "$rc"
dest=""; for a in "$@"; do dest="$a"; done
if [ -n "${BP_CP_FAIL_LOG:-}" ]; then
  case "$dest" in *.partial/) printf '%s\n' "$dest" >> "$BP_CP_FAIL_LOG"; exit 1;; esac
fi
exit 0
FAKECP
  chmod +x "$RBBIN/cp"

  # An mv that REFUSES the recovery rename without touching a byte (the EPERM /
  # cross-device shape) — the case where STAGE cannot put the interrupted swap
  # back.  Armed only by BP_MV_ASIDE_FAIL_LOG and only for a SOURCE ending in
  # `.aside` (the recovery direction), so the swap's own `mv <rel> <rel>.aside`
  # and every other mv in this suite are the real one.  Same non-vacuity contract
  # as the cp shim: the log it appends to is the sentinel — an empty mv.log means
  # the rename the whole proof rests on never ran.
  cat > "$RBBIN/mv" <<'FAKEMV'
#!/usr/bin/env bash
real=/bin/mv; [ -x "$real" ] || real=/usr/bin/mv
if [ -n "${BP_MV_ASIDE_FAIL_LOG:-}" ]; then
  src=""
  for a in "$@"; do case "$a" in -*) ;; *) [ -z "$src" ] && src="$a";; esac; done
  case "$src" in *.aside) printf '%s\n' "$src" >> "$BP_MV_ASIDE_FAIL_LOG"; exit 1;; esac
fi
exec "$real" "$@"
FAKEMV
  chmod +x "$RBBIN/mv"

  # The mutant: restore the pre-fix line, nothing else.  A mutation that did not
  # apply is not a catch, so the swap is asserted three ways below (exactly one
  # changed line, the pre-fix line present, the guarded line absent).
  RBMUTD="$TD/rb-mutant"; RBMUT="$RBMUTD/site-deploy-node.sh"
  mkdir -p "$RBMUTD/lib"
  cp "$(cd "$(dirname "$SELF")" && pwd)/lib/site-deploy-common.sh" "$RBMUTD/lib/"  # a mutant sources by its OWN dirname
  awk '{ if ($0 == "  rm -rf \"$RELDIR.partial\" \"$RELDIR.aside\"") print "  rm -rf \"$RELDIR\" \"$RELDIR.partial\""; else print }' \
    "$SELF" > "$RBMUT"
  check "the mutant differs by exactly ONE line (the mutation APPLIED)" \
    [ "$(diff "$SELF" "$RBMUT" | grep -c '^[<>]')" = 2 ]
  check "the mutant carries the PRE-FIX line"      grep -qF 'rm -rf "$RELDIR" "$RELDIR.partial"' "$RBMUT"
  # Counted, not merely absent: this file mentions the guarded text in its OWN
  # assertions, so "the mutant does not contain it" would be false for a reason
  # that has nothing to do with STAGE.  The mutant must carry EXACTLY ONE FEWER
  # occurrence than this engine, and this engine must carry at least one.
  rb_guard_n() { grep -cF 'rm -rf "$RELDIR.partial" "$RELDIR.aside"' "$1" || true; }
  check "this engine carries the guarded STAGE line" \
    [ "$(rb_guard_n "$SELF")" -ge 1 ]
  check "the mutant lost EXACTLY ONE occurrence of it (the STAGE line)" \
    [ "$(( $(rb_guard_n "$SELF") - $(rb_guard_n "$RBMUT") ))" = 1 ]

  RBSRC="$TD/rbsrc"; mkdir -p "$RBSRC"
  printf '{"name":"selftest-rbguard","private":true}\n' > "$RBSRC/package.json"

  # ONE fixture, run twice — the arms differ ONLY by which engine binary runs.
  rb_arm() { # <engine> <slug> -> populates $TD/rb-<slug>/, echoes the STAGE-failure exit code
    local eng="$1" slug="$2" base="$TD/rb-$2" pa pb
    pa="$(free_port)"; pb="$(free_port)"
    mkdir -p "$base/sites"
    rb_deploy() { # <build_id>
      env PATH="$RBBIN:$FAKEBIN:$PATH" \
        SITE_SLUG="$slug" BUILD_ID="$1" CONTENT_REV=rb-rev SITE_SRC="$RBSRC" \
        SITE_PORT_A="$pa" SITE_PORT_B="$pb" \
        BARKPARK_SITES_DIR="$base/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
        BARKPARK_CADDYFILE="$CF" \
        BARKPARK_SITE_DEPLOY_LOCK="$base/deploy.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
        BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
        BP_CP_FAIL_LOG="${RB_CP_FAIL:-}" \
        bash "$eng" > "$base/out.$1.log" 2>&1
      echo $?
    }
    RB_CP_FAIL="" rb_deploy rb1 > "$base/rc1"                 # slot a goes live on rb1
    printf 'ORIGINAL-%s\n' "$slug" > "$base/sites/$slug/releases/rb1/.rb-origin"
    RB_CP_FAIL="" rb_deploy rb2 > "$base/rc2"                 # slot b goes live; .previous -> rb1
    # Poison rb1 EXACTLY as purge_failed_release_node does for a live/previous
    # release: keep every byte, drop the marker.  Same constant, so a rename of
    # the marker cannot leave this fixture testing a file nothing reads.
    : > "$base/sites/$slug/releases/rb1/$HEALTH_FAIL_MARK"
    : > "$base/cp.log"
    RB_CP_FAIL="$base/cp.log" rb_deploy rb1 > "$base/rc3"     # the re-deploy that must not cost rb1
    rb_rollback() {
      env PATH="$RBBIN:$FAKEBIN:$PATH" \
        SITE_SLUG="$slug" SITE_PORT_A="$pa" SITE_PORT_B="$pb" \
        BARKPARK_SITES_DIR="$base/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
        BARKPARK_CADDYFILE="$CF" \
        BARKPARK_SITE_DEPLOY_LOCK="$base/deploy.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
        BARKPARK_SITE_HEALTH_PATH=/ BARKPARK_NODE_LINK="$TD/barkpark-node" \
        BARKPARK_SITE_NO_CAP=1 BP_CP_FAIL_LOG="" \
        bash "$eng" --rollback > "$base/rb.log" 2>&1
      echo $?
    }
    rb_rollback > "$base/rbrc"
    cat "$base/rc3"
  }

  # ---- FIXED arm (this engine) --------------------------------------------
  rbfix_rc="$(rb_arm "$SELF" rbfix)"; RBF="$TD/rb-rbfix"
  check "FIXED: the two setup deploys landed"      sh -c "[ \"\$(cat '$RBF/rc1')\" = 0 ] && [ \"\$(cat '$RBF/rc2')\" = 0 ]"
  check "FIXED: .previous names rb1 (rb1 IS the warm rollback target)" \
    sh -c "awk '{print \$3}' '$RBF/sites/rbfix/.previous' | grep -qx rb1"
  check "FIXED: the staging copy REALLY ran (cp.log non-empty — not a vacuous pass)" \
    [ -s "$RBF/cp.log" ]
  check "FIXED: the re-deploy failed in STAGE with the typed 13"  [ "$rbfix_rc" = 13 ]
  check "FIXED: and said so on the machine channel"  grep -q '^BPSTAGE name=STAGE status=failed build_id=rb1' "$RBF/out.rb1.log"
  check "FIXED: releases/rb1 SURVIVED the failed deploy"          [ -d "$RBF/sites/rbfix/releases/rb1" ]
  check "FIXED: …with its ORIGINAL bytes, not a half-copy"        grep -qx 'ORIGINAL-rbfix' "$RBF/sites/rbfix/releases/rb1/.rb-origin"
  check "FIXED: …and still bootable (server.js present)"          [ -f "$RBF/sites/rbfix/releases/rb1/server.js" ]
  check "FIXED: no .partial residue"                              [ ! -e "$RBF/sites/rbfix/releases/rb1.partial" ]
  check "FIXED: no .aside residue"                                [ ! -e "$RBF/sites/rbfix/releases/rb1.aside" ]
  # The failure path PROVES the target is still there instead of leaving the
  # operator to guess — the exit-13 detail says so in words.
  check "FIXED: the exit-13 detail names the surviving release"   grep -q 'is UNTOUCHED, so any rollback target it held is still there' "$RBF/out.rb1.log"
  # An interrupted swap must not be a second way to lose the release: drop the
  # bytes at <id>.aside with nothing at <id> (the kill-between-the-renames state)
  # and the next STAGE picks them back up.
  mv "$RBF/sites/rbfix/releases/rb1" "$RBF/sites/rbfix/releases/rb1.aside"
  rb_recover_rc="$(env PATH="$RBBIN:$FAKEBIN:$PATH" \
    SITE_SLUG=rbfix BUILD_ID=rb1 CONTENT_REV=rb-rev SITE_SRC="$RBSRC" \
    SITE_PORT_A="$(free_port)" SITE_PORT_B="$(free_port)" \
    BARKPARK_SITES_DIR="$RBF/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
    BARKPARK_CADDYFILE="$CF" \
    BARKPARK_SITE_DEPLOY_LOCK="$RBF/deploy.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    BP_CP_FAIL_LOG="$RBF/cp2.log" \
    bash "$SELF" > "$RBF/out.recover.log" 2>&1; echo $?)"
  check "FIXED: an INTERRUPTED swap is recovered, not deleted (.aside -> release)" \
    [ -d "$RBF/sites/rbfix/releases/rb1" ]
  check "FIXED: …with the original bytes"          grep -qx 'ORIGINAL-rbfix' "$RBF/sites/rbfix/releases/rb1/.rb-origin"
  check "FIXED: …and the recovery is on the record" grep -q 'recovered releases/rb1 from an interrupted swap' "$RBF/out.recover.log"
  check "FIXED: …and this run still failed in STAGE (the copy really ran)" \
    sh -c "[ \"$rb_recover_rc\" = 13 ] && [ -s '$RBF/cp2.log' ]"

  # …and when the recovery rename ITSELF fails, STAGE must REFUSE rather than
  # fall through to the cleanup that would delete the .aside it just failed to
  # rescue.  Silence is the actual defect here — a run that loses the only copy
  # of a live-or-previous release while printing nothing — so this asserts the
  # bytes SURVIVE, that the run SAID so on both channels, and the typed 13.
  mv "$RBF/sites/rbfix/releases/rb1" "$RBF/sites/rbfix/releases/rb1.aside"
  : > "$RBF/mv.log"
  rb_norecover_rc="$(env PATH="$RBBIN:$FAKEBIN:$PATH" \
    SITE_SLUG=rbfix BUILD_ID=rb1 CONTENT_REV=rb-rev SITE_SRC="$RBSRC" \
    SITE_PORT_A="$(free_port)" SITE_PORT_B="$(free_port)" \
    BARKPARK_SITES_DIR="$RBF/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
    BARKPARK_CADDYFILE="$CF" \
    BARKPARK_SITE_DEPLOY_LOCK="$RBF/deploy.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    BP_CP_FAIL_LOG="" BP_MV_ASIDE_FAIL_LOG="$RBF/mv.log" \
    bash "$SELF" > "$RBF/out.norecover.log" 2>&1; echo $?)"
  check "FIXED: the recovery rename REALLY was attempted (mv.log non-empty — not a vacuous pass)" \
    [ -s "$RBF/mv.log" ]
  check "FIXED: a FAILED recovery does NOT delete the .aside — the bytes SURVIVE" \
    [ -d "$RBF/sites/rbfix/releases/rb1.aside" ]
  check "FIXED: …with the original bytes still in it" \
    grep -qx 'ORIGINAL-rbfix' "$RBF/sites/rbfix/releases/rb1.aside/.rb-origin"
  check "FIXED: …and STAGE refused rather than staging over it (releases/rb1 not re-created)" \
    [ ! -e "$RBF/sites/rbfix/releases/rb1" ]
  check "FIXED: …and it SAID so in the log, naming the .aside as the surviving copy" \
    grep -q 'left releases/rb1.aside UNTOUCHED' "$RBF/out.norecover.log"
  check "FIXED: …and on the machine channel too (a silent loss is the defect)" \
    grep -q '^BPSTAGE name=STAGE status=failed build_id=rb1' "$RBF/out.norecover.log"
  check "FIXED: …with the typed 13 the other STAGE refusals speak" \
    [ "$rb_norecover_rc" = 13 ]
  # Put the fixture back the way the rest of this block expects it.
  mv "$RBF/sites/rbfix/releases/rb1.aside" "$RBF/sites/rbfix/releases/rb1"

  # =========================================================================
  # SWITCH IS FAIL-CLOSED WHEN CADDY REJECTS THE ARM (exit 16).
  #
  # Every deploy in this suite runs against a fake caddy whose `validate` ALWAYS
  # exits 0, so the two `exit 16` arms of SWITCH — `could not arm …` and
  # `could not flip …` — were asserted by nobody: no fixture had ever driven a
  # REJECTING caddy through SWITCH in this engine. That is the arm whose whole
  # job is to refuse: on a rejected arm the run must stop the slot it just
  # booted, leave NOTHING live, and exit 16 — the static engine deliberately
  # stays exit 0 here (charter-D327) because its bytes go live on a symlink flip
  # that Caddy plays no part in, while a NODE site is served ONLY through the
  # Caddy upstream, so an unarmed route means the deploy did not happen.
  #
  # Own slug, own Caddyfile, own ports, so it cannot disturb the selftest site.
  # =========================================================================
  echo "[selftest] e2e: a REJECTING caddy through SWITCH fails CLOSED with exit 16 (the arm nobody drove)"
  SFB="$TD/switchfail-bin"; mkdir -p "$SFB"
  # shellcheck disable=SC2016  # $1 is the fake script's own arg — must NOT expand here
  printf '#!/usr/bin/env bash\ncase "$1" in validate) exit 1;; *) exit 0;; esac\n' > "$SFB/caddy"
  chmod +x "$SFB/caddy"
  SFCF="$TD/Caddyfile.switchfail"
  printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$SFCF"
  cp "$SFCF" "$SFCF.orig"
  SF_PORT_A="$(free_port)"; SF_PORT_B="$(free_port)"
  sf_rc="$(env PATH="$SFB:$FAKEBIN:$PATH" \
    SITE_SLUG=switchfail BUILD_ID=sf1 CONTENT_REV=sf-rev SITE_SRC="$SRC" \
    SITE_PORT_A="$SF_PORT_A" SITE_PORT_B="$SF_PORT_B" \
    BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
    BARKPARK_CADDYFILE="$SFCF" \
    BARKPARK_SITE_DEPLOY_LOCK="$TD/switchfail.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
    BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
    bash "$SELF" > "$TD/sf.out" 2> "$TD/sf.err"; echo $?)"
  check "rejected arm fails the deploy CLOSED with the typed 16"  [ "$sf_rc" = 16 ]
  check "…and HEALTH had already passed (the refusal is SWITCH's, not the gate's)" \
    grep -q '^BPSTAGE name=HEALTH status=ok build_id=sf1' "$TD/sf.out"
  check "…SWITCH failed on the machine channel"  grep -q '^BPSTAGE name=SWITCH status=failed build_id=sf1' "$TD/sf.out"
  check "…and the detail says the new slot was stopped and nothing is live" \
    grep -q 'new slot stopped, nothing live' "$TD/sf.out"
  check "…caddy validate's refusal is on the record (the revert really ran)" \
    grep -q 'caddy validate rejected the /sites/switchfail change — reverting' "$TD/sf.out"
  check "…the Caddyfile is byte-identical (the arm reverted its write)" \
    cmp -s "$SFCF" "$SFCF.orig"
  check "…no route marker was left behind" \
    sh -c "! grep -q 'BARKPARK_SITE_ROUTE:switchfail' '$SFCF'"
  check "…and NO ROUTE ok claims an armed route the box does not have" \
    sh -c "! grep -q '^BPSTAGE name=ROUTE status=ok build_id=sf1' '$TD/sf.out'"
  check "…and RETIRE never ran (the run stopped AT the failed switch)" \
    sh -c "! grep -q '^BPSTAGE name=RETIRE' '$TD/sf.out'"

  # =========================================================================
  # THE OTHER exit 16: A REJECTED **RE-DEPLOY** FLIP (the second arm).
  #
  # `grep -n 'exit 16' deploy/site-deploy-node.sh` finds TWO sites, and they are
  # NOT the same experiment. The block above drives the FIRST — `arm_caddy_node_
  # route` on a site with no route yet, reached only when $CUR_SLOT is empty. The
  # `else` branch — `flip_caddy_node_port` on a site that IS already live — is
  # the one every ordinary deploy after the first one takes, and no fixture had
  # ever driven a REJECTING caddy through it. The arm fixture structurally
  # cannot reach it: with no CUR_SLOT the engine never enters the else.
  #
  # And the two arms have DIFFERENT things to lose. A rejected ARM leaves
  # nothing live, so "did the revert work" is a question about a file. A rejected
  # FLIP happens while a slot is SERVING TRAFFIC, so the property is stronger:
  # the run must stop only the slot it just booted, leave the Caddyfile
  # byte-identical, and leave the PREVIOUS slot still routed and still up. A
  # flip that half-applied — marker rewritten to the new port, new slot then
  # stopped — points production's upstream at a dead port while every stage
  # reports a clean refusal. So the fixture arms with an ACCEPTING caddy first,
  # snapshots the Caddyfile it produced, and re-deploys the SAME slug against a
  # REJECTING one.
  #
  # Own slug, own Caddyfile, own ports, own lock — it cannot disturb the site
  # above or the selftest site.
  # =========================================================================
  echo "[selftest] e2e: a REJECTED RE-DEPLOY flip fails CLOSED with exit 16 and leaves the LIVE slot routed"
  FLCF="$TD/Caddyfile.flipfail"
  printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$FLCF"
  FL_PORT_A="$(free_port)"; FL_PORT_B="$(free_port)"
  fl_deploy() { # <build_id> <extra-PATH-prefix> -> exit code, logs $TD/fl.<id>.out
    env PATH="${2}$FAKEBIN:$PATH" \
      SITE_SLUG=flipfail BUILD_ID="$1" CONTENT_REV="fl-$1" SITE_SRC="$SRC" \
      SITE_PORT_A="$FL_PORT_A" SITE_PORT_B="$FL_PORT_B" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
      BARKPARK_CADDYFILE="$FLCF" \
      BARKPARK_SITE_DEPLOY_LOCK="$TD/flipfail.lock" BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" > "$TD/fl.$1.out" 2> "$TD/fl.$1.err"
    echo $?
  }
  # ---- 1. ARM, with the ACCEPTING caddy: this is the state under test --------
  fl1_rc="$(fl_deploy fl1 '')"
  check "the arm deploy landed (accepting caddy) — the fixture really is live" [ "$fl1_rc" = 0 ]
  check "…and it armed the route (this is a FLIP fixture, not a second arm)" \
    grep -q "BARKPARK_SITE_ROUTE:flipfail" "$FLCF"
  fl_port() { awk 'index($0,"BARKPARK_SITE_ROUTE:flipfail"){i=1} i&&match($0,/localhost:[0-9]+/){print substr($0,RSTART+10,RLENGTH-10); exit}' "$FLCF"; }
  check "…serving slot a :$FL_PORT_A"                 [ "$(fl_port)" = "$FL_PORT_A" ]
  cp "$FLCF" "$FLCF.armed"
  # ---- 2. RE-DEPLOY the same slug, now against the REJECTING caddy -----------
  # $SFB holds the `validate) exit 1` stub built for the arm block above.
  fl2_rc="$(fl_deploy fl2 "$SFB:")"
  check "rejected FLIP fails the re-deploy CLOSED with the typed 16"  [ "$fl2_rc" = 16 ]
  check "…and HEALTH had already passed on the new slot (SWITCH's refusal, not the gate's)" \
    grep -q '^BPSTAGE name=HEALTH status=ok build_id=fl2' "$TD/fl.fl2.out"
  check "…SWITCH failed on the machine channel"  grep -q '^BPSTAGE name=SWITCH status=failed build_id=fl2' "$TD/fl.fl2.out"
  check "…and the detail names the LIVE slot as still serving (the flip wording, not the arm's)" \
    grep -q 'live slot a still serving' "$TD/fl.fl2.out"
  check "…caddy validate's refusal is on the record (the revert really ran)" \
    grep -q 'caddy validate rejected the /sites/flipfail change — reverting' "$TD/fl.fl2.out"
  check "…the Caddyfile is BYTE-IDENTICAL to the armed one (the flip reverted its write)" \
    cmp -s "$FLCF" "$FLCF.armed"
  check "…and the PREVIOUS slot is still the routed upstream (:A, never the dead :B)" \
    [ "$(fl_port)" = "$FL_PORT_A" ]
  check "…the new port never reached the marker block" \
    sh -c "! grep -q 'localhost:$FL_PORT_B' '$FLCF'"
  check "…the live slot a is still UP (a fail-closed flip must not stop the server)" \
    env PATH="$FAKEBIN:$PATH" systemctl is-active --quiet barkpark-site@flipfail__a
  check "…and the slot it just booted was stopped (nothing is left half-live)" \
    sh -c "! env PATH='$FAKEBIN:$PATH' systemctl is-active --quiet barkpark-site@flipfail__b"
  check "…and NO ROUTE ok claims a flip the Caddyfile does not carry" \
    sh -c "! grep -q '^BPSTAGE name=ROUTE status=ok build_id=fl2' '$TD/fl.fl2.out'"
  check "…and RETIRE never ran (the run stopped AT the failed flip)" \
    sh -c "! grep -q '^BPSTAGE name=RETIRE' '$TD/fl.fl2.out'"
  check "…and .previous was NOT rewritten to a build that never went live" \
    sh -c "! grep -q 'fl2' '$TD/sites/flipfail/.previous' 2>/dev/null"

  check "FIXED: --rollback refuses on the HEALTH MARKER (the target exists)" \
    sh -c "[ \"\$(cat '$RBF/rbrc')\" = 21 ] && grep -q \"previous release 'rb1' is marked health-failed\" '$RBF/rb.log'"
  check "FIXED: …and NEVER reports the target as gone"            sh -c "! grep -q \"previous release 'rb1' is gone\" '$RBF/rb.log'"

  # ---- MUTANT arm (pre-fix line restored), IDENTICAL fixture ---------------
  rbmut_rc="$(rb_arm "$RBMUT" rbmut)"; RBM="$TD/rb-rbmut"
  check "MUTANT: the two setup deploys landed the same way"       sh -c "[ \"\$(cat '$RBM/rc1')\" = 0 ] && [ \"\$(cat '$RBM/rc2')\" = 0 ]"
  check "MUTANT: the staging copy REALLY ran here too"            [ -s "$RBM/cp.log" ]
  check "MUTANT: the re-deploy failed in STAGE with the same 13"  [ "$rbmut_rc" = 13 ]
  check "MUTANT: releases/rb1 is GONE — the failed deploy destroyed the rollback target" \
    [ ! -d "$RBM/sites/rbmut/releases/rb1" ]
  check "MUTANT: .previous still names rb1 (a pointer to nothing)" \
    sh -c "awk '{print \$3}' '$RBM/sites/rbmut/.previous' | grep -qx rb1"
  check "MUTANT: --rollback reports the target GONE"              sh -c "[ \"\$(cat '$RBM/rbrc')\" = 21 ] && grep -q \"previous release 'rb1' is gone\" '$RBM/rb.log'"
  echo "  mutation proof: with the one line back to 'rm -rf \"\$RELDIR\" \"\$RELDIR.partial\"', the SAME fixture (rb1 warm-previous + health-failed, re-deployed, staging cp fails at exit 13) leaves releases/rb1 DELETED and --rollback saying the previous release is gone; with the guard, rb1 keeps its original bytes and the refusal is the honest one (marked health-failed)"

  # =========================================================================
  # …AND ON ALL FOUR EXIT-13 ARMS, not just the standalone copy.
  # The arm above arms its fake cp on the DESTINATION (`*.partial/`).  Only ONE
  # of STAGE's three copies has a destination that ends there — the standalone
  # one.  The other two land in `<id>.partial/.next/static/` and
  # `<id>.partial/public/`, and the fourth exit-13 arm is not a copy at all but
  # the `.partial` -> release rename, for which there was no shim.  So three of
  # the four arms could never be induced to fail, and a regression that put the
  # up-front delete back on the public/ arm alone would have sailed through
  # green.  (Credit: lead-platform-2's builder found the gap and wrote the
  # four-arm harness this block is ported from.)
  #
  # The fix is to arm on the SOURCE — argument 2, where `*/.next/standalone/.`,
  # `*/.next/static/.` and `*/public/.` are cleanly distinguishable — plus an mv
  # armed on a `.partial` FIRST ARGUMENT, which is the rename and NOT the
  # move-aside (whose first argument is the release dir itself).  Getting that
  # predicate wrong relocates the proof to a different, already-correct call
  # site and produces a green that means nothing, so every arm asserts WHICH
  # call site the shim fired on, and that it fired exactly once.
  #
  # Each arm restores a byte-identical snapshot and runs it through BOTH the
  # mutant (pre-fix line) and this engine, so the four arms and the two engines
  # are the same experiment.
  # =========================================================================
  echo "[selftest] e2e: MUTATION — all FOUR exit-13 arms of STAGE, mutant vs fixed"
  SWP="$TD/swpstage"; mkdir -p "$SWP"
  SWPSRC="$SWP/src"; mkdir -p "$SWPSRC"
  printf '{"name":"selftest-swpstage","private":true}\n' > "$SWPSRC/package.json"

  # The shims.  Both do REAL work (or none) and then fail, both are armed ONLY
  # by BP_SWP_FAIL — so the fixture deploys that BUILD the rollback target use
  # the real binaries — and both append the exact call site they intercepted to
  # BP_SWP_LOG, which is what the per-arm assertions read.
  SWPBIN="$SWP/bin"; mkdir -p "$SWPBIN"
  cat > "$SWPBIN/cp" <<'SWPCP'
#!/usr/bin/env bash
real=/bin/cp; [ -x "$real" ] || real=/usr/bin/cp
if [ -n "${BP_SWP_FAIL:-}" ] && [ "$#" -eq 3 ] && [ "$1" = "-a" ]; then
  hit=""
  case "$BP_SWP_FAIL:$2" in
    standalone:*/.next/standalone/.) hit=1 ;;
    static:*/.next/static/.)         hit=1 ;;
    public:*/public/.)               hit=1 ;;
  esac
  if [ -n "$hit" ]; then
    src="${2%/.}"
    /bin/mkdir -p "$3" 2>/dev/null
    # Land ONE real entry first, so the failure has the shape of an ENOSPC
    # part-way through a copy rather than a copy that never started.
    for f in "$src"/*; do [ -e "$f" ] && { "$real" -a "$f" "$3" 2>/dev/null; break; }; done
    printf 'cp %s -> %s\n' "$2" "$3" >> "${BP_SWP_LOG:-/dev/null}"
    exit 1
  fi
fi
exec "$real" "$@"
SWPCP
  cat > "$SWPBIN/mv" <<'SWPMV'
#!/usr/bin/env bash
real=/bin/mv; [ -x "$real" ] || real=/usr/bin/mv
# Fails ONLY the partial -> release rename.  The move-aside (`mv <rel>
# <rel>.aside`) and the recovery (`mv <rel>.aside <rel>`) have a first argument
# that is NOT the .partial, so they run for real — if this predicate matched
# them the proof would silently move to a different call site.
if [ "${BP_SWP_FAIL:-}" = mv ] && [ "$#" -eq 2 ]; then
  case "$1" in
    *.partial)
      printf 'mv %s -> %s\n' "$1" "$2" >> "${BP_SWP_LOG:-/dev/null}"
      exit 1 ;;
  esac
fi
exec "$real" "$@"
SWPMV
  chmod +x "$SWPBIN/cp" "$SWPBIN/mv"

  swp_deploy() { # <engine> <slug> <caddyfile> <pA> <pB> <build> [fail] [faillog] -> rc
    env PATH="$SWPBIN:$FAKEBIN:$PATH" \
      SITE_SLUG="$2" BUILD_ID="$6" CONTENT_REV=swp-rev SITE_SRC="$SWPSRC" \
      SITE_PORT_A="$4" SITE_PORT_B="$5" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
      BARKPARK_CADDYFILE="$3" \
      BARKPARK_SITE_DEPLOY_LOCK="$SWP/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_NODE_LINK="$TD/barkpark-node" BARKPARK_SITE_NO_CAP=1 \
      BP_SWP_FAIL="${7:-}" BP_SWP_LOG="${8:-/dev/null}" \
      bash "$1" > "$SWP/out.log" 2>&1
    echo $?
  }
  swp_rollback() { # <engine> <slug> <caddyfile> <pA> <pB> -> rc
    env PATH="$SWPBIN:$FAKEBIN:$PATH" \
      SITE_SLUG="$2" SITE_PORT_A="$4" SITE_PORT_B="$5" \
      BARKPARK_SITES_DIR="$TD/sites" BARKPARK_SLOT_ENV_DIR="$SENV" \
      BARKPARK_CADDYFILE="$3" \
      BARKPARK_SITE_DEPLOY_LOCK="$SWP/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$TD/caddyfile.lock" \
      BARKPARK_SITE_HEALTH_PATH=/ BARKPARK_NODE_LINK="$TD/barkpark-node" \
      BARKPARK_SITE_NO_CAP=1 \
      bash "$1" --rollback > "$SWP/rb.log" 2>&1
    echo $?
  }

  # Build each engine's fixture ONCE, then snapshot it, so every arm below
  # starts from identical bytes.  The setup deploys are ASSERTED to have
  # succeeded: a fixture that silently failed (exit 14 on the health gate is the
  # easy one) would hand every arm a "the release is gone" that proves nothing.
  swp_fixture() { # <arm> <slug> <engine> <pA> <pB>
    local arm="$1" slug="$2" eng="$3" pa="$4" pb="$5" d1 d2
    local cf="$SWP/$arm.Caddyfile"
    printf 'guerrilla.barkpark.cloud {\n\treverse_proxy localhost:4000\n}\n' > "$cf"
    d1="$(swp_deploy "$eng" "$slug" "$cf" "$pa" "$pb" n1)"
    check "fixture ($arm): the n1 deploy LANDED (exit 0, not a silent failure)" [ "$d1" = 0 ]
    d2="$(swp_deploy "$eng" "$slug" "$cf" "$pa" "$pb" n2)"
    check "fixture ($arm): the n2 deploy LANDED (exit 0, not a silent failure)" [ "$d2" = 0 ]
    # n1 is now the .previous rollback target on the still-warm slot a.  Poison
    # it exactly as purge_failed_release_node does for a live/previous release —
    # bytes KEPT, marker dropped — the state PLAN's health-failed arm sends back
    # through BUILD + STAGE.
    : > "$TD/sites/$slug/releases/n1/$HEALTH_FAIL_MARK"
    printf 'SWP-ORIGINAL-n1\n' > "$TD/sites/$slug/releases/n1/.swp-origin"
    rm -rf "$SWP/$arm-snap"; mkdir -p "$SWP/$arm-snap"
    cp -a "$TD/sites/$slug" "$SWP/$arm-snap/site"
    cp -a "$SENV/${slug}__a.env" "$SWP/$arm-snap/a.env"
    cp -a "$SENV/${slug}__b.env" "$SWP/$arm-snap/b.env"
    cp -a "$cf" "$SWP/$arm-snap/Caddyfile"
  }
  swp_restore() { # <arm> <slug>
    rm -rf "$TD/sites/$2"
    cp -a "$SWP/$1-snap/site" "$TD/sites/$2"
    cp -a "$SWP/$1-snap/a.env" "$SENV/${2}__a.env"
    cp -a "$SWP/$1-snap/b.env" "$SENV/${2}__b.env"
    cp -a "$SWP/$1-snap/Caddyfile" "$SWP/$1.Caddyfile"
  }

  SWP_PA="$(free_port)"; SWP_PB="$(free_port)"   # the FIXED arm's two slots
  SWP_PC="$(free_port)"; SWP_PD="$(free_port)"   # the MUTANT arm's two slots
  swp_fixture fixed  swpfix "$SELF"   "$SWP_PA" "$SWP_PB"
  swp_fixture mutant swpmut "$RBMUT"  "$SWP_PC" "$SWP_PD"
  check "fixture (fixed):  .previous names n1 (n1 IS the rollback target)" \
    sh -c "awk '{print \$3}' '$TD/sites/swpfix/.previous' | grep -qx n1"
  check "fixture (mutant): .previous names n1 too (the same experiment)" \
    sh -c "awk '{print \$3}' '$TD/sites/swpmut/.previous' | grep -qx n1"
  check "fixture (fixed):  n1 carries the poison marker purge would have left" \
    [ -f "$TD/sites/swpfix/releases/n1/$HEALTH_FAIL_MARK" ]

  # One variant = one exit-13 arm.  <site-regex> pins WHICH call site the shim
  # intercepted: a predicate that drifted onto the move-aside, or onto a
  # different copy, reds here instead of passing for the wrong reason.
  swp_variant() { # <BP_SWP_FAIL> <expected-call-site-regex>
    local what="$1" site="$2"
    local f_cf="$SWP/fixed.Caddyfile" m_cf="$SWP/mutant.Caddyfile"
    local f_rel="$TD/sites/swpfix/releases/n1" m_rel="$TD/sites/swpmut/releases/n1"
    local f_rc m_rc f_rb m_rb
    swp_restore fixed swpfix; swp_restore mutant swpmut
    : > "$SWP/fixed.log"; : > "$SWP/mutant.log"
    m_rc="$(swp_deploy "$RBMUT" swpmut "$m_cf" "$SWP_PC" "$SWP_PD" n1 "$what" "$SWP/mutant.log")"
    cp "$SWP/out.log" "$SWP/mutant.out"
    f_rc="$(swp_deploy "$SELF"  swpfix "$f_cf" "$SWP_PA" "$SWP_PB" n1 "$what" "$SWP/fixed.log")"
    cp "$SWP/out.log" "$SWP/fixed.out"
    # THE SHIM FIRED, ONCE, ON THE CALL SITE THIS ARM IS ABOUT.
    check "[$what] fixed:  the shim fired on the RIGHT call site" \
      grep -qE "$site" "$SWP/fixed.log"
    check "[$what] fixed:  …and on nothing else (exactly one interception)" \
      [ "$(grep -c '' "$SWP/fixed.log")" = 1 ]
    check "[$what] mutant: the shim fired on the RIGHT call site here too" \
      grep -qE "$site" "$SWP/mutant.log"
    check "[$what] mutant: …and on nothing else (exactly one interception)" \
      [ "$(grep -c '' "$SWP/mutant.log")" = 1 ]
    # BOTH engines REACHED the same failing line — else the outcomes below are
    # not comparable.
    check "[$what] mutant: the deploy exits 13 (STAGE failed)"     [ "$m_rc" = 13 ]
    check "[$what] fixed:  the deploy exits 13 too (same failure)" [ "$f_rc" = 13 ]
    check "[$what] mutant: STAGE failed on the machine channel" \
      grep -q '^BPSTAGE name=STAGE status=failed build_id=n1' "$SWP/mutant.out"
    check "[$what] fixed:  STAGE failed on the machine channel" \
      grep -q '^BPSTAGE name=STAGE status=failed build_id=n1' "$SWP/fixed.out"
    # THE DEFECT, reproduced on THIS arm.
    check "[$what] MUTANT LOSES IT: releases/n1 is GONE" [ ! -d "$m_rel" ]
    check "[$what] MUTANT LOSES IT: .previous still names the release it deleted" \
      sh -c "awk '{print \$3}' '$TD/sites/swpmut/.previous' | grep -qx n1"
    # THE FIX, on the identical fixture.
    check "[$what] FIX KEEPS IT: releases/n1 survived"   [ -d "$f_rel" ]
    check "[$what] FIX KEEPS IT: with its ORIGINAL bytes (fixture marker intact)" \
      grep -qx 'SWP-ORIGINAL-n1' "$f_rel/.swp-origin"
    check "[$what] FIX KEEPS IT: still bootable (server.js present)" [ -f "$f_rel/server.js" ]
    check "[$what] FIX KEEPS IT: no .partial residue" [ ! -e "$f_rel.partial" ]
    check "[$what] FIX KEEPS IT: no .aside residue"   [ ! -e "$f_rel.aside" ]
    check "[$what] fixed: the exit-13 detail SAYS the release survived" \
      grep -qE 'is UNTOUCHED, so any rollback target it held is still there|previously staged tree was restored' "$SWP/fixed.out"
    # THE VERDICT — the same remediation on both engines, opposite answers.
    # Clearing the poison marker is what a SUCCESSFUL restage would have done;
    # on the mutant there is nothing left to clear.
    rm -f "$m_rel/$HEALTH_FAIL_MARK" "$f_rel/$HEALTH_FAIL_MARK" 2>/dev/null
    m_rb="$(swp_rollback "$RBMUT" swpmut "$m_cf" "$SWP_PC" "$SWP_PD")"
    check "[$what] MUTANT LOSES IT: the rollback is now IMPOSSIBLE (21 no_previous)" [ "$m_rb" = 21 ]
    check "[$what] MUTANT LOSES IT: and it says the previous release is gone" \
      grep -q "previous release 'n1' is gone" "$SWP/rb.log"
    f_rb="$(swp_rollback "$SELF" swpfix "$f_cf" "$SWP_PA" "$SWP_PB")"
    check "[$what] FIX KEEPS IT: the rollback still WORKS (exit 0)" [ "$f_rb" = 0 ]
    check "[$what] FIX KEEPS IT: and it lands on n1"  grep -qx 'TARGET_BUILD=n1' "$SWP/rb.log"
  }

  swp_variant standalone '^cp .*/\.next/standalone/\. -> .*/releases/n1\.partial/$'
  swp_variant static     '^cp .*/\.next/static/\. -> .*/releases/n1\.partial/\.next/static/$'
  swp_variant public     '^cp .*/public/\. -> .*/releases/n1\.partial/public/$'
  swp_variant mv         '^mv .*/releases/n1\.partial -> .*/releases/n1$'
  echo "[selftest] the shipped unit template treats a SIGTERM exit (143) as a clean stop"
  UNIT_TMPL="$(cd "$(dirname "$SELF")" && pwd)/systemd/barkpark-site@.service"
  unit_ses_section() { awk '/^\[/{s=$0} /^SuccessExitStatus=/{print s; exit}' "$UNIT_TMPL"; }
  check "deploy/systemd/barkpark-site@.service is in the tree" [ -f "$UNIT_TMPL" ]
  check "unit declares SuccessExitStatus=143 (a stopped slot is not a failed slot)" \
    grep -qE '^SuccessExitStatus=(.* )?143( |$)' "$UNIT_TMPL"
  check "SuccessExitStatus sits in [Service] (systemd ignores it anywhere else)" \
    [ "$(unit_ses_section)" = "[Service]" ]

  echo ""
  echo "[selftest] $((TESTS - FAILS))/$TESTS checks passed"
  # The floor (see SELFTEST_FLOOR_* above). `FAILED (1)` is the shape
  # internal/cli/cloud_site_preflight.go recognises as terminal.
  if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
    SELFTEST_FLOOR="$SELFTEST_FLOOR_FULL"
    SELFTEST_FLOOR_NAME="SELFTEST_FLOOR_FULL (BARKPARK_SELFTEST_REQUIRE_E2E=1: every block is required here)"
  else
    SELFTEST_FLOOR="$SELFTEST_FLOOR_MIN"
    SELFTEST_FLOOR_NAME="SELFTEST_FLOOR_MIN (bare run: the flock/api optional blocks may skip honestly)"
  fi
  [ "$TESTS" -ge "$SELFTEST_FLOOR" ] || { echo "[selftest] FAILED (1) - only $TESTS checks ran, the floor is $SELFTEST_FLOOR from $SELFTEST_FLOOR_NAME: a block went missing, and a suite that stopped running rows must not report PASS. If rows were removed on purpose, lower the literal in the same commit."; exit 1; }
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
# ---- Queued-lock heartbeat (task-8811b4b25c529dbe) --------------------------
# A SILENT wait is what killed the CI leg, never the deploy itself. `flock -w
# <budget> 9` carries no bytes on the ssh session that started this script, and
# the GitHub runner's NAT tears an idle session down after roughly five minutes:
# ssh exits 255, the step fails, and the run is recorded as a FAILED production
# deploy for the crime of queueing. Measured on main 2026-09-05..06: ten of the
# last fourteen failed deploy.yml runs died exactly that way, every one of them
# after logging the "holds the lock" line above.
#
# So wait in heartbeat-sized STEPS instead of one long silent one. The contract
# is identical to `flock -w <budget> 9` -- return 0 the moment the lock is
# taken, non-zero once the budget is exhausted, and the TOTAL budget is
# unchanged (the steps sum to it exactly) -- but a line lands at most every
# $BARKPARK_LOCK_HEARTBEAT_SECS, so the session carries bytes AND a human
# reading the log sees a QUEUE rather than a hang.
#
# The env var exists ONLY so deploy/*_test.sh can drive this at 1 s; nothing on
# a box sets it. A non-numeric or sub-second value falls back to 60 rather than
# spinning.
queue_for_deploy_lock() {
  local budget="$1" label="${2:-the deploy lock}" beat waited=0 step
  beat="${BARKPARK_LOCK_HEARTBEAT_SECS:-60}"
  case "$beat" in ''|*[!0-9]*) beat=60 ;; esac
  [ "$beat" -lt 1 ] && beat=60
  while [ "$waited" -lt "$budget" ]; do
    step=$(( budget - waited ))
    [ "$step" -gt "$beat" ] && step="$beat"
    flock -w "$step" 9 && return 0
    waited=$(( waited + step ))
    log "still queued for $label — ${waited}s waited of ${budget}s max"
  done
  return 1
}

exec 9>"$LOCK"
if ! flock -n 9; then
  if [ "$MODE" != deploy ]; then
    log "deploy lock held for '$SITE_SLUG' — refusing to $MODE while a deploy runs (lock_held)"
    exit 23
  fi
  log "another deploy holds the lock for '$SITE_SLUG' — queueing (max 20 min)"
  queue_for_deploy_lock 1200 "the site deploy lock for '$SITE_SLUG'" || { log "gave up waiting for the site deploy lock"; exit 15; }
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
  # systemd-mode DeployRunner finalizes a rollback from the durable LOG FILE — it
  # has no exit code (the transient unit's is swept) and a rollback emits no
  # BPSTAGE fold. A DEPLOY fills that log via BUILD's tee; a rollback has no
  # BUILD, so record each outcome here in the exact markers
  # `DeployRunner.rollback_outcome/1` reads — a `TARGET_BUILD=`+`ROLLED BACK`
  # success pair, or a typed `(no_previous)`/`(not_supported)` refusal. Direct
  # append (not a tee) so it is on disk before the unit exits. Same contract as
  # the static engine (deploy/site-deploy.sh).
  rb_mark() { [ -n "${BARKPARK_SITE_LOG_FILE:-}" ] && printf '%s\n' "$*" >> "$BARKPARK_SITE_LOG_FILE"; return 0; }
  cur_slot="$(active_slot)"
  if [ -z "$cur_slot" ]; then log "no live route for '$SITE_SLUG' (not_supported)"; rb_mark "rollback refused: (not_supported)"; exit 22; fi
  if [ ! -f "$ROOT/.previous" ] || [ -z "$(cat "$ROOT/.previous" 2>/dev/null)" ]; then
    log "no previous slot recorded (no_previous)"; rb_mark "rollback refused: (no_previous)"; exit 21
  fi
  read -r p_slot p_port p_build < "$ROOT/.previous"
  if [ -z "$p_build" ] || [ ! -d "$RELEASES/$p_build" ]; then log "previous release '$p_build' is gone (no_previous)"; rb_mark "rollback refused: (no_previous)"; exit 21; fi
  if [ -f "$RELEASES/$p_build/$HEALTH_FAIL_MARK" ]; then
    log "previous release '$p_build' is marked health-failed — refusing to serve it (no_previous)"; rb_mark "rollback refused: (no_previous)"; exit 21
  fi
  if [ "$p_slot" = "$cur_slot" ]; then log "rollback: previous slot == current ($cur_slot) — nothing to do"; rb_mark "ROLLED BACK: $SITE_SLUG now on slot $cur_slot ($(read_slot_build "$cur_slot"))"; rb_mark "TARGET_BUILD=$(read_slot_build "$cur_slot")"; exit 0; fi

  cur_port="$(slot_port "$cur_slot")"; cur_build="$(read_slot_build "$cur_slot")"
  if slot_running "$p_slot" && [ "$(read_slot_build "$p_slot")" = "$p_build" ]; then
    # WARM: the previous slot is still up on $p_build — pure Caddy flip back (<1s).
    log "ROLLBACK (warm): flip Caddy $cur_slot :$cur_port -> $p_slot :$p_port ($p_build)"
    if ! with_caddy_lock flip_caddy_node_port "$p_port"; then
      log "rollback flip failed — Caddy untouched, still on $cur_slot (fail closed)"; rb_mark "rollback failed (exit 24)"; exit 24
    fi
  else
    # COLD: reboot the idle slot onto $p_build, gate it, then flip.
    log "ROLLBACK (cold): boot slot $p_slot on :$p_port at $p_build, gate, flip"
    ensure_node_link
    BUILD_ID="$p_build"
    if ! health_gate_node "$p_slot" "$p_build"; then
      log "rollback: slot $p_slot failed HEALTH at $p_build — Caddy untouched, still on $cur_slot (fail closed): $HEALTH_DETAIL"; rb_mark "rollback failed (exit 24)"; exit 24
    fi
    if ! with_caddy_lock flip_caddy_node_port "$p_port"; then
      stop_slot "$p_slot"
      log "rollback flip failed — Caddy untouched, still on $cur_slot (fail closed)"; rb_mark "rollback failed (exit 24)"; exit 24
    fi
  fi
  # A subsequent --rollback flips forward again — record where we came from.
  printf '%s %s %s\n' "$cur_slot" "$cur_port" "$cur_build" > "$ROOT/.previous"
  do_retire_node "$p_slot"
  # Record the outcome where the systemd-mode runner reads it, and print
  # TARGET_BUILD= on stdout for the CLI (machine contract, mirrors the preflight).
  rb_mark "ROLLED BACK: $SITE_SLUG now on slot $p_slot ($p_build)"
  rb_mark "TARGET_BUILD=$p_build"
  echo "TARGET_BUILD=$p_build"
  log "ROLLED BACK — '$SITE_SLUG' now on slot $p_slot ($p_build)"
  exit 0
fi

# ===========================================================================
# TEARDOWN (the inverse of a spawn, node edition): stop BOTH warm slot units,
# disarm the Caddy route, delete the slot env files + the release tree — so a
# `bp cloud site delete` leaves no process, no route, no bytes. Idempotent:
# missing units / route / dir are all fine. Mirrors the static engine's
# --teardown; the extra step is the running SSR process (a symlink site has none).
# ===========================================================================
# Remove THIS slug's marker-guarded Caddy block — the inverse of
# arm_caddy_node_route. Same brace-counted excision as the static engine (drops
# the marker comment through the close brace of the handle[_path], covering the
# @matcher/redir/reverse_proxy form) and the same commit safety (backup + caddy
# validate + reload-or-revert): a botched excision REVERTS, never breaking Caddy.
# RETURNS: 0 the route is gone (or was never armed / no caddy here), 2 the route is
# STILL LIVE and this run OBSERVED it (commit_caddyfile reverted). Unlike the static
# engine this signal was always correct — it was the CALLER that discarded it with
# `|| true` (D77). 2 and not 1 so the caller can tell it apart from
# `with_caddy_lock`'s own 1 (the lock was never taken, so the route was never
# looked at) — a distinction the operator's message depends on.
disarm_caddy_node_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping /sites/$SITE_SLUG disarm"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — nothing to disarm"; return 0; }
  local marker; marker="$(site_route_marker_re)"
  # DELIMITER-ANCHORED (D345) — a bare substring would excise a prefix SIBLING's
  # live route block on this site's teardown.
  has_site_route_marker "$CADDYFILE" || { log "caddy /sites/$SITE_SLUG route not armed — nothing to disarm"; return 0; }
  local tmp; tmp="$(mktemp)"
  BP_MARK="$marker" awk '
    BEGIN { m = ENVIRON["BP_MARK"] }
    !inb && $0 ~ m { inb = 1; depth = 0; opened = 0; next }
    inb {
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&"); depth += o - c
      if (o > 0) opened = 1
      if (opened && depth <= 0) inb = 0
      next
    }
    { print }
  ' "$CADDYFILE" > "$tmp" || { rm -f "$tmp"; return 2; }
  commit_caddyfile "$tmp" || return 2
}

# A teardown that could NOT disarm the route must never print TORN_DOWN= (D77).
# That marker is the ONLY thing DeployRunner.teardown_outcome/1 reads, and its mere
# presence IS exit 0 to the control plane — so printing it after a reverted disarm
# certifies a site that is still routed. Speak a typed failure on the SAME two
# channels the success marker uses (stdout for the CLI, $BARKPARK_SITE_LOG_FILE for
# the systemd-mode runner, which sees no exit code), exit non-zero, and leave the
# release tree AND both slot env files on disk: the route still points at this
# site, so a re-run of --teardown (after the Caddyfile is fixed) can finish the job
# and `systemctl start barkpark-site@<slug>__<slot>` can put it back in service.
teardown_failed_node() { # <detail>
  local detail="$1" line
  log "TEARDOWN FAILED — $detail"
  printf -v line 'TEARDOWN_FAILED=%s detail="%s"' "$SITE_SLUG" "$detail"
  [ -n "${BARKPARK_SITE_LOG_FILE:-}" ] && printf '%s\n' "$line" >> "$BARKPARK_SITE_LOG_FILE"
  printf '%s\n' "$line"
  exit 25
}

if [ "$MODE" = teardown ]; then
  stop_slot a; stop_slot b
  # TWO different failures, and they are NOT the same claim (see the static engine's
  # twin). 2 = the disarm ran and the route demonstrably survived it. 1 =
  # with_caddy_lock's own guard fired, so nothing ever read the Caddyfile and the
  # route's state is UNKNOWN to this run. Both keep the tree and both slot env
  # files; only one of them is a measurement.
  disarm_rc=0
  with_caddy_lock disarm_caddy_node_route || disarm_rc=$?
  if [ "$disarm_rc" = 1 ]; then
    teardown_failed_node "the caddy /sites/$SITE_SLUG route was NEVER CHECKED — the shared Caddyfile lock could not be taken, so whether this site is still routed is UNKNOWN to this run. Both slots are stopped; the release tree at $ROOT and both slot env files are kept, so a re-run of --teardown (or \`systemctl start barkpark-site@${SITE_SLUG}__a\`) can finish or undo the job"
  elif [ "$disarm_rc" != 0 ]; then
    teardown_failed_node "the caddy /sites/$SITE_SLUG route is STILL LIVE — this run tried to remove it, the change was rejected, and the Caddyfile was reverted to the serving config. Both slots are stopped, so that route now answers 502 until you either re-run --teardown (after fixing the Caddyfile) or \`systemctl start barkpark-site@${SITE_SLUG}__a\`; the release tree at $ROOT and both slot env files are kept for exactly that"
  fi
  rm -f "$(slot_env a)" "$(slot_env b)" 2>/dev/null || true
  if [ -d "$ROOT" ]; then
    rm -rf "$ROOT" && log "TORE DOWN — stopped slots + removed release tree $ROOT"
  else
    log "teardown: no site dir at $ROOT (already gone)"
  fi
  # Record the outcome where the systemd-mode DeployRunner reads it (no exit code;
  # a teardown emits no BPSTAGE) so a CP-driven delete finalizes as exit 0.
  [ -n "${BARKPARK_SITE_LOG_FILE:-}" ] && printf 'TORN_DOWN=%s\n' "$SITE_SLUG" >> "$BARKPARK_SITE_LOG_FILE"
  echo "TORN_DOWN=$SITE_SLUG"
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
# build_failure_reason() (the `BUILD failed` detail's producer) lives in
# lib/site-deploy-common.sh, sourced above — ONE copy, shared with the static
# engine, which is the only way a repair to it reaches BOTH runtime targets.

if [ "$SKIP_BUILD" = 0 ]; then
  emit BUILD started
  if [ ! -d "$SITE_SRC" ]; then
    DETAIL="no site source dir $SITE_SRC — expected a checked-out app there; check the deploy payload's repo+ref and that the clone/checkout step actually populated it"
    log "BUILD: $DETAIL"; emit BUILD failed "$DETAIL"; exit 10
  fi
  if [ ! -f "$SITE_SRC/package.json" ]; then
    DETAIL="$SITE_SRC has no package.json — expected a Node app root; check the payload points at the app dir, not the repo root or a monorepo parent"
    log "BUILD: $DETAIL"; emit BUILD failed "$DETAIL"; exit 11
  fi

  # ---- FLEET BUILD ADMISSION GATE — one box, one build (D95/D104) ----------
  # Identical contract to the static engine's (deploy/site-deploy.sh): the lock
  # taken above is PER-SLUG, so without this second, fleet-wide lock N sites
  # compile at once on 2 cores — and a `next build` is the heaviest of them.
  # Keyed on SKIP_BUILD (this engine has NO PLAN_MODE; naming one would be an
  # unbound expansion under the `set -u` at the top of this file). Taken after
  # BUILD started and after the two cheap validations; released right after
  # BUILD ok, BEFORE HEALTH boots the slot process — see below.
  if ! build_gate_acquire; then
    DETAIL="waited ${BUILD_GATE_WAIT}s for the FLEET BUILD SLOT ($BUILD_GATE_LOCK) and it never freed — this box runs ONE build at a time (2 cores, MemoryMax=1500M each), so another site's build is still compiling; nothing was built, staged or flipped and the live slot is untouched. Retry once it drains. In flight: $(build_gate_holders)"
    log "BUILD: $DETAIL"
    # emit BEFORE the exit, ALWAYS: this refusal fires AFTER `emit PLAN ok`, so a
    # bare exit would hang a stage-watching orchestrator on a BUILD line that
    # never comes.
    emit BUILD failed "$DETAIL"
    exit 15
  fi

  # BUILD_ID + base path + content rev are EXPORTED (inherited by the child, never
  # on its argv) so the adapter can bake the markers HEALTH asserts on. The rest of
  # the D7 BUILD_ALLOW set already rides the script's (caller-scrubbed) environment
  # and is inherited the same way — no `env -i VAR=value` reconstruction, so no
  # secret leaks onto a process argv (a ps/proc leak proven live).
  export BARKPARK_BUILD_ID="$BUILD_ID"
  export BARKPARK_SITE_BASE="/sites/$SITE_SLUG/"
  [ -n "${CONTENT_REV:-}" ] && export BARKPARK_CONTENT_REV="$CONTENT_REV"
  log "BUILD: npm ci && npm run build in $SITE_SRC (inherited scrubbed env)"
  cd "$SITE_SRC" || {
    DETAIL="cannot cd into $SITE_SRC — the dir exists but is not enterable; check its permissions/ownership (ls -ld) and that no symlink on the path is broken"
    log "BUILD: $DETAIL"; emit BUILD failed "$DETAIL"; exit 10
  }
  # No inner resource cap: the OUTER transient unit DeployRunner launches carries
  # MemoryMax/CPUQuota now (slice stw6-deployrunner-reattach). BARKPARK_SITE_NO_CAP
  # stays a documented dev/selftest knob — the inner cap is gone, so it is a no-op.
  if [ "${BARKPARK_SITE_NO_CAP:-0}" = 1 ]; then
    log "BUILD: BARKPARK_SITE_NO_CAP set — no inner cap (the outer transient unit caps in prod)"
  fi
  # The build's stdout+stderr merge onto OUR stdout AND tee to a PERSISTENT log the
  # caller (DeployRunner) names via BARKPARK_SITE_LOG_FILE, so an ORPHANED build's
  # RAW output survives its parent (reason_tail reads the last non-BPSTAGE lines on
  # re-attach). Raw child output ONLY — BPSTAGE lines ride the status fold, never
  # this file. No caller-named file (dev/selftest) => a mktemp we delete as before;
  # a caller-named log is NEVER deleted. PIPESTATUS, never $?, is the build's rc.
  if [ -n "${BARKPARK_SITE_LOG_FILE:-}" ]; then
    BUILD_LOG="$BARKPARK_SITE_LOG_FILE"; BUILD_LOG_KEEP=1
    mkdir -p "$(dirname "$BUILD_LOG")" 2>/dev/null || true
  else
    BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/site-node-build.XXXXXX")"; BUILD_LOG_KEEP=0
  fi
  # --include=dev is LOAD-BEARING: NODE_ENV=production (set on the build line below)
  # makes `npm ci` OMIT devDependencies — but the BUILD needs them (typescript,
  # @types/*, framework build tooling live in devDependencies). Without it
  # `next build` dies "Please install typescript, @types/react, @types/node" →
  # "build worker exited with code: 1". The RUNTIME stays lean: Next's standalone
  # output bundles only what serving needs, so the release never ships devDeps.
  # nice -n 19 (+ ionice idle-class when present) — same contract as the static
  # engine: a build must never starve the live API on a small box (see
  # site-deploy.sh; measured 500ms→3-5.6s search under un-niced build storms).
  BP_NICE="nice -n 19"
  command -v ionice >/dev/null 2>&1 && BP_NICE="nice -n 19 ionice -c3"
  NODE_ENV=production CI=1 $BP_NICE bash -euo pipefail -c 'npm ci --no-audit --no-fund --include=dev && npm run build' 2>&1 | tee "$BUILD_LOG"
  build_rc="${PIPESTATUS[0]}"
  if [ "$build_rc" -ne 0 ]; then
    reason="$(build_failure_reason "$BUILD_LOG")"
    [ "$BUILD_LOG_KEEP" = 1 ] || rm -f "$BUILD_LOG"
    log "BUILD failed (exit $build_rc) for '$SITE_SLUG' build $BUILD_ID — live slot untouched: $reason"
    emit BUILD failed "$reason"
    exit 12
  fi
  [ "$BUILD_LOG_KEEP" = 1 ] || rm -f "$BUILD_LOG"
  emit BUILD ok "npm ci && npm run build (next standalone)"
  # RELEASE THE SLOT HERE, AND NOWHERE LATER. fd 7 is inherited by children, and
  # HEALTH (below) BOOTS THE SLOT PROCESS, which OUTLIVES this run by design — it
  # is the thing that serves the site. Any long-lived process that inherits fd 7
  # holds the box's only build slot for the LIFETIME OF THE SITE: a fleet-wide
  # deny with no reaper to notice it. `start_slot` goes through `systemctl
  # restart` today, so PID 1 (not this script) spawns the slot and inherits
  # nothing — but that is a property of the LAUNCH MECHANISM, not of the gate, and
  # this contract must not rest on it. The self-test pins it against a harness
  # whose fake systemctl DOES spawn the slot as a direct child.
  build_gate_release

  # ---- STAGE (D64) — three-piece standalone copy into an immutable release ----
  emit STAGE started
  if [ ! -d "$SITE_SRC/.next/standalone" ]; then
    DETAIL="build produced no .next/standalone — expected a Next standalone bundle; check next.config has output:'standalone' and the build reached 'next build' (not just lint/typecheck)"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  if [ ! -f "$SITE_SRC/.next/standalone/server.js" ]; then
    DETAIL=".next/standalone has no server.js — expected the standalone entrypoint; check the Next build completed (a partial .next survives a failed build) and the app has at least one server route"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  # NEVER delete releases/<build_id> before the new bytes exist.  That dir can be
  # the LIVE release or the build .previous names as the warm-rollback target —
  # and PLAN routes a redeploy of exactly such a build straight here:
  # purge_failed_release_node KEEPS a live/previous release's bytes and only drops
  # the poison marker (precisely so the rollback path survives), after which PLAN's
  # health-failed arm sets SKIP_BUILD=0 and STAGE runs against that same dir.  An
  # up-front `rm -rf` followed by a copy that fails (exit 13, ordinary on a full
  # mount) therefore destroyed the very release a rollback would flip to: .previous
  # kept naming it while its bytes were gone, and --rollback returned 21.
  # A FAILED DEPLOY MUST NEVER COST THE ROLLBACK TARGET.
  # So: copy into a fresh .partial, then SWAP — move the old dir ASIDE, rename the
  # partial in, and remove the aside copy only once the rename has landed.  Every
  # failure path before that last step leaves the existing release, and therefore
  # the rollback path, byte-for-byte intact.  (Mirrors stage_dir_into_release in
  # the static engine, deploy/site-deploy.sh — one shape for both runtimes.)
  # The swap narrows the exposure to the gap BETWEEN the two renames (a
  # microsecond, versus the whole copy the pre-fix `rm -rf` was exposed for), and
  # even that gap is now recoverable rather than fatal: a kill in it leaves the
  # old release under .aside and nothing at $RELDIR, so pick it back up instead
  # of deleting it — it can be the only copy of a live-or-previous release left
  # on the box.  Only when $RELDIR is genuinely absent; a present $RELDIR means
  # the swap landed and the .aside is the stale half.
  # And the recovery is REFUSED-ON-FAILURE, not best-effort: the `rm -rf` three
  # lines down would otherwise delete the very bytes a failed `mv` just left in
  # place — the row's own defect shape, reappearing inside its own remedy and
  # silently (no log, no emit, no non-zero exit; an operator sees a clean deploy
  # and finds the missing rollback target only when they reach for it).  STAGE
  # cannot honestly stage over a release it could not first put back, so read the
  # return code and stop BEFORE the cleanup, leaving the .aside untouched.
  if [ ! -e "$RELDIR" ] && [ -d "$RELDIR.aside" ]; then
    mv "$RELDIR.aside" "$RELDIR"; recover_rc=$?
    if [ "$recover_rc" -ne 0 ]; then
      DETAIL="could not recover releases/$BUILD_ID from an interrupted swap (mv exit $recover_rc) — releases/$BUILD_ID.aside still holds those bytes and can be the only copy of a live-or-previous release left on this box, so STAGE refused to stage over a release it could not first put back and left releases/$BUILD_ID.aside UNTOUCHED; move it back to releases/$BUILD_ID by hand (check ownership and free space on the releases mount) and redeploy"
      log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
    fi
    log "STAGE: recovered releases/$BUILD_ID from an interrupted swap (.aside) before re-staging"
  fi
  STAGE_ASIDE=""
  rm -rf "$RELDIR.partial" "$RELDIR.aside"
  mkdir -p "$RELDIR.partial"
  # cp/mv carry no forensic of their own — capture the exit code + a disk read (a
  # copy that fails on a real box almost always fails on a full mount) so each
  # detail names the next move instead of a bare "copy failed".
  # 1) standalone dir IS the release root (server.js + traced node_modules).
  cp -a "$SITE_SRC/.next/standalone/." "$RELDIR.partial/"; cp_rc=$?
  if [ "$cp_rc" -ne 0 ]; then
    disk="$(disk_free "$RELEASES")"; rm -rf "$RELDIR.partial"
    DETAIL="copy of .next/standalone into releases/$BUILD_ID failed (cp exit $cp_rc; disk ${disk:-?}) — out of space or perms on the releases mount; check df and the dir ownership. The previously staged releases/$BUILD_ID (if any) is UNTOUCHED, so any rollback target it held is still there"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  # 2) .next/static -> <release>/.next/static (standalone omits it by design).
  if [ -d "$SITE_SRC/.next/static" ]; then
    mkdir -p "$RELDIR.partial/.next/static"
    cp -a "$SITE_SRC/.next/static/." "$RELDIR.partial/.next/static/"; cp_rc=$?
    if [ "$cp_rc" -ne 0 ]; then
      disk="$(disk_free "$RELEASES")"; rm -rf "$RELDIR.partial"
      DETAIL="copy of .next/static into releases/$BUILD_ID failed (cp exit $cp_rc; disk ${disk:-?}) — out of space or perms on the releases mount; check df and the dir ownership. The previously staged releases/$BUILD_ID (if any) is UNTOUCHED, so any rollback target it held is still there"
      log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
    fi
  fi
  # 3) public/ -> <release>/public (static assets; optional).
  if [ -d "$SITE_SRC/public" ]; then
    mkdir -p "$RELDIR.partial/public"
    cp -a "$SITE_SRC/public/." "$RELDIR.partial/public/"; cp_rc=$?
    if [ "$cp_rc" -ne 0 ]; then
      disk="$(disk_free "$RELEASES")"; rm -rf "$RELDIR.partial"
      DETAIL="copy of public/ into releases/$BUILD_ID failed (cp exit $cp_rc; disk ${disk:-?}) — out of space or perms on the releases mount; check df and the dir ownership. The previously staged releases/$BUILD_ID (if any) is UNTOUCHED, so any rollback target it held is still there"
      log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
    fi
  fi
  if [ -e "$RELDIR" ]; then
    mv "$RELDIR" "$RELDIR.aside"; aside_rc=$?
    if [ "$aside_rc" -ne 0 ]; then
      rm -rf "$RELDIR.partial"
      DETAIL="could not move the existing releases/$BUILD_ID aside before the swap (mv exit $aside_rc) — the staged tree was discarded and the existing release is UNTOUCHED, so any rollback target it held is still there; check ownership of the releases dir"
      log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
    fi
    STAGE_ASIDE="$RELDIR.aside"
  fi
  mv "$RELDIR.partial" "$RELDIR"; mv_rc=$?
  if [ "$mv_rc" -ne 0 ]; then
    # Put the old release BACK.  The swap is only a swap if it is reversible.
    [ -n "$STAGE_ASIDE" ] && mv "$STAGE_ASIDE" "$RELDIR" 2>/dev/null
    rm -rf "$RELDIR.partial"
    DETAIL="rename into releases/$BUILD_ID failed (mv exit $mv_rc) — expected an atomic move within the releases dir; check the target isn't a non-empty dir or a mountpoint, and its ownership. Any previously staged tree was restored"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  [ -n "$STAGE_ASIDE" ] && rm -rf "$STAGE_ASIDE"
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
# THE ARM DECISION GETS A DURABLE CHANNEL (D346). This engine spoke SWITCH only,
# and every route fact reached the operator through log() — i.e. stdout, which
# nothing persists (the durable .log holds raw npm child output, the durable
# .status holds BPSTAGE lines). So `arm` vs `flip` — the difference between a
# first deploy and a blue/green flip — was unmeasurable after the fact, which is
# exactly why 208 phantom first deploys went unnoticed. ROUTE is the channel: it
# is a BPSTAGE line, so it lands in the durable .status fold, and it is
# deliberately OUTSIDE DeployRunner's @stage_names whitelist
# (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE), so parse_stage_line/2 skips it and it
# can NEVER reach stage_exit_code/1 or flip a verdict. Report, not verdict —
# charter D327 stands and dr-w19-bl-arm-route-incidence-then-fatal owns the
# fatal question; this is what makes that question answerable.
ROUTE_DETAIL=""
CUR_BUILD=""; CUR_PORT=""
if [ -n "$CUR_SLOT" ]; then CUR_BUILD="$(read_slot_build "$CUR_SLOT")"; CUR_PORT="$(slot_port "$CUR_SLOT")"; fi
if [ -z "$CUR_SLOT" ]; then
  if ! with_caddy_lock arm_caddy_node_route "$TARGET_PORT"; then
    stop_slot "$TARGET_SLOT"
    DETAIL="could not arm the /sites/$SITE_SLUG Caddy route — new slot stopped, nothing live; check $CADDYFILE is writable, 'caddy validate' passes, and a slot reverse_proxy anchor exists to insert before"
    log "SWITCH: $DETAIL (fail closed)"; emit SWITCH failed "$DETAIL"; exit 16
  fi
else
  if ! with_caddy_lock flip_caddy_node_port "$TARGET_PORT"; then
    stop_slot "$TARGET_SLOT"
    DETAIL="could not flip Caddy to slot $TARGET_SLOT :$TARGET_PORT — live slot $CUR_SLOT still serving; check the Caddyfile lock and that 'caddy validate' accepts the per-site port change"
    log "SWITCH: $DETAIL (fail closed)"; emit SWITCH failed "$DETAIL"; exit 16
  fi
fi
# Record the slot we flipped AWAY from as the warm previous (kept running for <1s
# rollback). First deploy: no previous.
if [ -n "$CUR_SLOT" ] && [ "$CUR_SLOT" != "$TARGET_SLOT" ]; then
  printf '%s %s %s\n' "$CUR_SLOT" "$CUR_PORT" "$CUR_BUILD" > "$ROOT/.previous"
fi
log "ROUTE: $ROUTE_DETAIL"
emit ROUTE ok "$ROUTE_DETAIL"
log "SWITCH: '$SITE_SLUG' Caddy upstream -> slot $TARGET_SLOT :$TARGET_PORT (build $BUILD_ID)"
emit SWITCH ok "Caddy upstream -> slot $TARGET_SLOT :$TARGET_PORT"

# THE SERVED SLOT, READ BACK FROM CADDY (site-spawner: node slot truth).
# TARGET_SLOT/TARGET_PORT are what this run INTENDED to serve. What Caddy is
# ACTUALLY proxying is one awk over the marker block away (active_caddy_port),
# so intent is never what crosses the wire: the flip has committed and the
# reload has happened, and this re-READS the result. That distinction is the
# whole point — a slot field derived from intent reports intent while looking
# like state, which is the failure three deploy-truth lanes closed (a smoke
# exiting 0 over a box that never moved). It also catches the D345 prefix-
# sibling case for free: when active_slot() matches NEITHER of this site's two
# ports it prints nothing, and this says `slot=none` instead of the slot the
# run wished for.
#
# It rides a BPSTAGE line so it lands in the durable .status fold, and the name
# SERVED is deliberately OUTSIDE DeployRunner's @stage_names whitelist — exactly
# like ROUTE above, so parse_stage_line/2 skips it and it can NEVER reach
# stage_exit_code/1 or flip a verdict. Report, not verdict (charter D327).
# The detail is key=value, never prose: the reader is a regex, and a reader that
# has to parse an English sentence is one reworded clause from reading zero.
SERVED_PORT="$(active_caddy_port)"
SERVED_SLOT="$(active_slot)"
emit SERVED ok "port=${SERVED_PORT:-none} slot=${SERVED_SLOT:-none}"

# ---- RETIRE (D67) — keep current + 1 warm previous; prune old releases -------
emit RETIRE started
do_retire_node "$TARGET_SLOT"
emit RETIRE ok "removed $RETIRED old release(s); current slot $TARGET_SLOT + warm previous kept running"

log "HEALTHY — '$SITE_SLUG' live at build $BUILD_ID on slot $TARGET_SLOT (https://$HEALTH_HOST/sites/$SITE_SLUG/)"
exit 0
