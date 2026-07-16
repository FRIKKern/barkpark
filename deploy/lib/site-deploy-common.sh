# shellcheck shell=bash
# Shared primitives for the Site-Spawner deploy engines (charter D61).
#
# BOTH deploy/site-deploy.sh (static symlink-swap target) and
# deploy/site-deploy-node.sh (node-slot SSR target) source this file — one source
# line each — so the pieces that MUST NOT drift between the two engines live in
# exactly one place:
#
#   * emit() / the BPSTAGE machine protocol — the wire contract the control plane
#     parses by regex (api/lib/barkpark/sites/deploy_runner.ex @stage_re). A drift
#     here silently degrades every streamed failure to a canned "the build failed".
#   * with_caddy_lock() / setup_caddy_lock() — the ONE shared Caddyfile leaf lock
#     (fd 8). A THIRD writer of /etc/caddy/Caddyfile (the node engine's per-site
#     port flip) must JOIN this lock, never copy it, or a lost update reloads Caddy
#     onto a slot that is about to be stopped (a reproduced hard 502).
#   * valid_slug() / valid_build_id() — the identity validators (a slug names a
#     filesystem dir AND a Caddy path matcher; a build_id names releases/<id>/).
#   * meta_value() — the content-truth marker reader HEALTH rests on: it reads the
#     VALUE of a <meta name=…> tag, so a gate can assert bp-build-id == the build
#     it ships, never merely that the marker is present (D26).
#   * BUILD_ALLOW — the env allow-list a build may see (the Vite process.env-
#     precedence scrub, D7): only these BARKPARK_* vars cross into npm.
#
# This file is a LIBRARY: it defines functions + arrays and sets no traps, parses
# no args, and runs nothing on source. `set -uo pipefail` is the caller's job.

# ---------------------------------------------------------------------------
# log — one human line, tagged by engine. BP_LOG_TAG lets site-deploy.sh keep its
# exact "[site-deploy …]" prefix (zero output drift) while the node engine tags
# "[site-deploy-node …]". Defaults to site-deploy.
# ---------------------------------------------------------------------------
log() { echo "[${BP_LOG_TAG:-site-deploy} $(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# emit — the machine stage protocol (D25). ONE line per stage boundary on STDOUT,
# next to (never instead of) the human prose, so an orchestrator renders honest
# stages by regexing `^BPSTAGE `. detail= is free text (quotes normalised to
# spaces, one line, clipped to 240 chars) — it carries the REASON on a failed line
# so a stdout-only caller can always say WHY. build_id rides the line from the
# BUILD_ID global (empty is legal — a PLAN that has not resolved one yet).
# ---------------------------------------------------------------------------
emit() { # <PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE> <started|ok|skipped|noop|failed> [detail…]
  local name="$1" status="$2"; shift 2
  local detail="$*"
  if [ -n "$detail" ]; then
    detail="$(printf '%s' "$detail" | tr '\n\r\t"' '   '"'" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//' | cut -c1-240)"
    printf 'BPSTAGE name=%s status=%s build_id=%s detail="%s"\n' "$name" "$status" "${BUILD_ID:-}" "$detail"
  else
    printf 'BPSTAGE name=%s status=%s build_id=%s\n' "$name" "$status" "${BUILD_ID:-}"
  fi
}

# ---------------------------------------------------------------------------
# disk_free — a one-line free-space summary for the filesystem that holds <path>,
# for a STAGE copy/rename failure detail. cp(1)/mv(1) give no forensic of their
# own, and "copy failed" with no disk read is the single most common dead-end on a
# real box (a full /opt is invisible to a stdout-only caller). Prints
# "12G free (85% used)" or "" when df is unavailable or the path is gone. -P =
# portable single-line columns (Avail=$4, Capacity=$5), -h = human sizes; both are
# in macOS + GNU df (the self-test runs on stock macOS bash 3.2). Call it on a dir
# that still exists at the failure point (the release parent), never on the
# .partial dir a cleanup may already have removed.
# ---------------------------------------------------------------------------
disk_free() { # <path>
  df -Ph "$1" 2>/dev/null | awk 'NR==2 {print $4" free ("$5" used)"}'
}

# ---------------------------------------------------------------------------
# Identity validators. A slug names a filesystem dir under SITES_DIR AND a Caddy
# `/sites/<slug>/*` path matcher AND a systemd instance token; a build_id names
# releases/<id>/. Pure predicates — the caller logs + exits with its typed code.
# ---------------------------------------------------------------------------
valid_slug()     { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$'; }
valid_build_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; }

# ---------------------------------------------------------------------------
# meta_value — read the VALUE of a <meta name="…" content="…"> marker out of an
# HTML document. Prints "" when the tag is absent OR its content is empty — the
# caller asserts on the VALUE and never on presence, which is the whole point
# (D26): a name-only grep let a build whose bp-build-id said TOTALLY-WRONG and
# whose bp-content-rev was the EMPTY STRING sail through and go live. Tolerates
# attribute order, single/double/unquoted values and minified HTML (one tag per
# line via awk RS='>', never `tr` — tr maps chars 1:1 and cannot insert a newline,
# so a minified <meta a><meta b> would stay one line and the greedy content= match
# would read the LAST tag's value for EVERY marker).
# ---------------------------------------------------------------------------
meta_value() { # <html-file> <marker-name>
  local f="$1" n="$2"
  [ -f "$f" ] || return 0
  awk 'BEGIN { RS = ">" } { print $0 ">" }' "$f" 2>/dev/null \
    | grep -Ei "<meta[^>]*name=[\"']?${n}[\"'[:space:]/>]" \
    | head -1 \
    | sed -E -e 's/.*content="([^"]*)".*/\1/' -e t \
             -e "s/.*content='([^']*)'.*/\1/" -e t \
             -e "s/.*content=([^\"'[:space:]/>]+).*/\1/" -e t \
             -e 's/.*//'
}

# ---------------------------------------------------------------------------
# BUILD_ALLOW — the ONLY env vars a build may see (Vite process.env-precedence
# scrub, D7). BUILD_ID + base path + content rev are exported under their
# BARKPARK_ build-var names so the adapter can bake the bp-build-id / bp-content-
# rev markers HEALTH asserts on. An ambient BARKPARK_TOKEN must NEVER reach npm —
# it would shadow the per-site token (a live-proven failure mode).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # consumed by the sourcing engines (site-deploy*.sh), not here
BUILD_ALLOW=(BARKPARK_API_URL BARKPARK_TOKEN BARKPARK_DATASET BARKPARK_WORKSPACE \
             BARKPARK_PROJECT BARKPARK_BUILD_ID BARKPARK_CONTENT_REV BARKPARK_SITE_BASE \
             BARKPARK_DOC_TYPE BARKPARK_THEME)

# ---------------------------------------------------------------------------
# The ONE shared Caddyfile leaf lock (D27). /etc/caddy/Caddyfile has THREE
# read-modify-write writers now: instance-deploy.sh's blue/green port flip, the
# static engine's `/sites/<slug>/*` file_server arming, and the node engine's
# per-site reverse_proxy PORT flip. An interleave silently DISCARDS one of them,
# and a lost update is syntactically VALID — so the backup + `caddy validate` +
# revert discipline every writer already has is structurally blind to it.
#
# setup_caddy_lock resolves CADDY_LOCK (a global the caller reads); with_caddy_lock
# runs a Caddyfile read-modify-write serialized on fd 8. It is deliberately NOT
# instance-deploy's own whole-run lock (that one is held for its multi-minute run
# and would stall a site deploy for ten minutes) — a LEAF: taken, used, released,
# never held across a build.
# ---------------------------------------------------------------------------
setup_caddy_lock() {
  CADDY_LOCK="${BARKPARK_CADDYFILE_LOCK:-/var/lock/barkpark-caddyfile.lock}"
  if ! ( : > "$CADDY_LOCK" ) 2>/dev/null; then
    # Unwritable /var/lock (dev box, unprivileged CI) — fall back to a tmp lock so
    # we still serialize with anyone else on the box.
    CADDY_LOCK="${TMPDIR:-/tmp}/barkpark-caddyfile.lock"
    # LOUD, because the failure mode is silent: two writers only exclude each other
    # if they resolve the SAME path. On the real box every writer runs as root and
    # gets /var/lock; if one falls back and another does not, they serialize
    # against nothing. Pin BARKPARK_CADDYFILE_LOCK identically on every writer.
    log "WARN: /var/lock is not writable — Caddyfile lock falls back to $CADDY_LOCK; instance-deploy.sh AND the other site engine MUST resolve the same path (set BARKPARK_CADDYFILE_LOCK) or the Caddyfile writers do not serialize"
  fi
}
with_caddy_lock() { # <fn> [args…] — run a Caddyfile read-modify-write serialized
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
