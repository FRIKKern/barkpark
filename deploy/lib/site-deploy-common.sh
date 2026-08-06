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
#   * build_failure_reason() — the ONE extractor that picks the most useful line
#     out of a failed build log for the `BUILD failed` detail. It was duplicated
#     byte-for-byte in both engines, so every repair to it had to be made twice
#     and the DEFAULT (static) target silently kept the older, narrower one.
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
# emit — the machine stage protocol (D25). ONE line per stage boundary, next to
# (never instead of) the human prose, so an orchestrator renders honest stages by
# regexing `^BPSTAGE `. detail= is free text (quotes normalised to spaces, one
# line, clipped to 240 chars) — it carries the REASON on a failed line so a
# stdout-only caller can always say WHY. build_id rides the line from the BUILD_ID
# global (empty is legal — a PLAN that has not resolved one yet).
#
# DUAL SINK (durable status fold). The line always goes to STDOUT. When the caller
# (DeployRunner) names a persistent BARKPARK_SITE_STATUS_FILE, every stage line is
# ALSO appended to it — so a build ORPHANED by a barkpark.service restart (its BEAM
# parent dies, but the outer transient unit + the build survive) leaves a truthful
# partial fold on disk that the control plane re-attaches to on the next boot.
# Unset => stdout-only, byte-for-byte the old behaviour (dev/selftest standalone).
# Append-only + best-effort (a status-file write can never fail the deploy); the
# caller owns the file's lifetime (names it fresh per run, reads it on re-attach).
# ---------------------------------------------------------------------------
emit() { # <PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE> <started|ok|skipped|noop|failed> [detail…]
  local name="$1" status="$2"; shift 2
  local detail="$*" line
  if [ -n "$detail" ]; then
    detail="$(printf '%s' "$detail" | tr '\n\r\t"' '   '"'" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//' | cut -c1-240)"
    printf -v line 'BPSTAGE name=%s status=%s build_id=%s detail="%s"' "$name" "$status" "${BUILD_ID:-}" "$detail"
  else
    printf -v line 'BPSTAGE name=%s status=%s build_id=%s' "$name" "$status" "${BUILD_ID:-}"
  fi
  printf '%s\n' "$line"
  if [ -n "${BARKPARK_SITE_STATUS_FILE:-}" ]; then
    printf '%s\n' "$line" >> "$BARKPARK_SITE_STATUS_FILE" 2>/dev/null || true
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
# build_failure_reason — the most useful ONE LINE of a failed build log, for the
# `BUILD failed` stage detail. The real reason (`FATAL: 401 Unauthorized … the
# site read token is invalid`) used to go to STDERR while the generic "BUILD
# failed" went to stdout — a stdout-only orchestrator could never tell the user
# WHY.
#
# ONE COPY, BOTH ENGINES (charter D33). This body used to exist TWICE, byte-
# identical (md5 181029d3bc98b876d99d67ae704841a4), in site-deploy.sh and
# site-deploy-node.sh. runtime_target DEFAULTS to :static
# (api/lib/barkpark/sites/deploy_request.ex), so repairing the node copy alone
# left the DEFAULT engine compressing every failed build to a line nobody had
# looked at. It lives here because THIS file is the one both engines already
# source — and because it is the file the Console harness already reads, so the
# lift buys a blocking assertion over BOTH engines for free.
#
# IT IS A SUMMARY, NOT THE RECORD, AND IT CANNOT BECOME ONE. emit() above
# collapses newlines and cuts every detail to 240 chars, and the control plane's
# @stage_re is single-line — a multi-line reason structurally cannot cross that
# wire (D24). The whole-truth channel is the build_id-keyed durable build log;
# this function's only job is to pick the line most likely to start a diagnosis.
#
# THE TIERS ARE MEASURED, NOT GUESSED, against a RECORDED REAL producer:
# deploy/testdata/capstone-turbopack-build-fail.txt (30,993 bytes, captured live
# off guerrilla from a real search-capstone Turbopack failure). On those exact
# bytes:
#   tier 1 (FATAL)                 0 matches — no FATAL in a Turbopack failure
#   tier 2 (npm ERR! | [Ee]rror:)  EXACTLY 1 match, and it is the RIGHT one:
#                                  "Error: Turbopack build failed with 29 errors:"
#                                  (not a `tail -1` accident — the 29 error
#                                  bodies carry no `Error:` token, and npm 11
#                                  prints "npm error", so that arm is dead)
#   tier 3 (last non-blank)        strictly WORSE — it yields
#                                  "at <unknown> (…/module-not-found)"
# No reordering of the predicates improves that, so there is NO fifth tier: a
# fifth grep would be a guess at a producer nobody has recorded. When a NEW
# producer shape shows up, record its log as a fixture first, then measure.
# Pinned by both engines' --self-test against that fixture.
# ---------------------------------------------------------------------------
build_failure_reason() { # <build-log>
  local f="$1" r
  r="$(grep -a 'FATAL' "$f" 2>/dev/null | tail -1)"
  [ -n "$r" ] || r="$(grep -aE 'npm ERR!|[Ee]rror:' "$f" 2>/dev/null | grep -av 'complete log of this run' | tail -1)"
  [ -n "$r" ] || r="$(grep -av '^[[:space:]]*$' "$f" 2>/dev/null | tail -1)"
  [ -n "$r" ] || r="npm ci / npm run build failed with no output"
  printf '%s' "$r"
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
# BUILD_ALLOW — the DOCUMENTED allow-list of env vars a build may see (Vite
# process.env-precedence contract, D7). It is the canonical set the Elixir
# DeployRequest + the Go `bp cloud site preflight` env-contract check mirror.
#
# The engines NO LONGER reconstruct the build env from this array with
# `env -i VAR=value` — that put BARKPARK_TOKEN=<secret> on a child argv (a ps/proc
# leak, proven live). The build now INHERITS the script's environment, which
# DeployRunner scrubs to exactly this contract before launching the engine (the
# ambient-BARKPARK_TOKEN shadow is the caller's to strip; preflight warns on it).
# BUILD_ID + base path + content rev are still exported by each engine right
# before the build so the adapter can bake the bp-build-id / bp-content-rev
# markers HEALTH asserts on. Kept here as the single machine-readable source of
# truth for the allow-list contract even though shell no longer loops over it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # the canonical allow-list contract; mirrored by Elixir/Go, not looped over in shell
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

# ---------------------------------------------------------------------------
# THE FLEET BUILD ADMISSION GATE (D95/D104) — ONE BOX, ONE BUILD.
#
# The deploy lock both engines take is PER-SLUG
# (/var/lock/barkpark-site-deploy-<slug>.lock), so D7's "serialized, queue depth
# 1" is true PER SITE and false FLEET-WIDE: N sites build concurrently BY
# CONSTRUCTION. Measured on guerrilla (2 cores / 3.8G): 20 per-slug lock files,
# four stamped inside the same minute; peak 8 concurrent BUILD windows in 7
# days; 2,432 sweep points at 3+; and 80% of astro getPathsForRoute crashes,
# 52% of 503s and 49% of unreachable fired with a FOREIGN build mid-flight. The
# box is MEMORY-bound (304-894M available of 3,819; 1.25-1.65G of 2G swap used,
# kswapd hot). So this is a SECOND lock, fleet-wide: one lock file for the whole
# box, taken ONLY by the arm that actually compiles.
#
# WHY N=1 AND NO SEMAPHORE. D95 sketched an N-file semaphore with a poller. N is
# arithmetically FORCED to 1 on BOTH axes by the caps the control plane already
# puts on every deploy's transient unit (api/lib/barkpark/sites/deploy_runner.ex
# @default_cpu_quota "150%", @default_memory_max "1500M"):
#   CPU    : floor(2 cores * 100% / 150%)        = 1
#   MEMORY : floor(894M MemAvailable / 1500M)    = 1  (0 at the low-water mark)
# At N=1 the semaphore collapses to ONE exclusive lock and the poller becomes
# dead code, so neither is shipped. Raising N means raising those caps FIRST —
# they move together or this gate lies about what the box can hold.
#
# FAIL OPEN, LOUDLY. A gate that cannot take its lock ADMITS the build: a broken
# gate that denies every deploy is worse than the contention it prevents. Both
# fail-open paths log WARN and name the fix.
#
# THE FD FORM IS MANDATORY. Neither engine sets a script-level EXIT trap (the
# only trap in either file is inside its self-test) and there is no reaper — so
# the ONLY release that survives SIGKILL is the kernel dropping the fd when the
# holder dies. `flock -w <budget> 7` against an `exec 7>` fd is exactly that.
# fd 7 is free fleet-wide: 8 is the shared Caddyfile leaf lock, 9 the per-slug
# deploy lock.
#
# ...AND SO IS THE EXPLICIT RELEASE. fd 7 is inherited by children (deliberate —
# an orphaned build keeps holding its slot honestly), and the node engine's HEALTH
# stage BOOTS THE SLOT PROCESS, which OUTLIVES the run by design. If that process
# ever inherits fd 7 it holds the box's only build slot for the LIFETIME OF THE
# SITE — one deploy denying every other site's build, fleet-wide, with no reaper
# to notice. On a systemd box today it does NOT: start_slot goes through
# `systemctl restart`, so PID 1 does the spawn and inherits nothing. That is a
# property of the LAUNCH MECHANISM, not of this gate, and it is exactly the kind
# of property a future non-systemd fallback would quietly drop — so the contract
# does not rest on it. Every caller releases right after `emit BUILD ok`, before
# staging and before anything that starts a long-lived process, and the node
# self-test pins it against a harness that DOES spawn the slot as a direct child.
#
# NOT OPERATOR-TUNABLE FROM A CONTROL-PLANE DEPLOY. BARKPARK_BUILD_GATE_LOCK and
# BARKPARK_BUILD_GATE_WAIT are dev/self-test knobs ONLY: DeployRunner's
# write_env_file/4 writes an EXPLICIT ALLOWLIST into the transient unit's
# EnvironmentFile (PATH, the D7 build vars, SITE_SLUG/BUILD_ID/CONTENT_REV, the
# prebuilt vars, the status + log files) and systemd-run boots the unit with that
# file as its environment — nothing ambient crosses, so neither var can reach the
# engine on the real path. To change the box's behaviour, change the constants
# below.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # BUILD_GATE_SLOTS documents the forced N; the code needs no loop over it
BUILD_GATE_SLOTS=1                  # forced by CPUQuota=150% and MemoryMax=1500M (above)
# 900s, bounded by the two clocks that already exist: it must be SHORTER than the
# per-slug deploy lock's own 1200s wait (else a queued redeploy dies on the outer
# lock with a vaguer message than this gate would have given) and shorter than
# DeployRunner's 1,800,000ms run deadline (else the unit is killed mid-wait and
# the operator never sees the refusal). A cold `npm ci && astro build` on
# guerrilla runs 2-4 min, so 900s absorbs a build ahead of us plus its stage.
BUILD_GATE_WAIT_DEFAULT=900
BUILD_GATE_LOCK=""                  # resolved by build_gate_acquire (callers log it)
BUILD_GATE_WAIT=""                  # resolved by build_gate_acquire (callers log it)
BUILD_GATE_HELD=0                   # 1 while THIS process holds the slot

# build_gate_holders — one line naming what is compiling on this box right now,
# for the refusal detail. "cp/mv carry no forensic of their own" is this file's
# standing lesson; a fleet refusal with no ps read is the same dead end (the
# operator cannot even tell WHICH site is holding the box). Best-effort: empty
# when ps is restricted. `ps -Ao` (never `-e`: on BSD/macOS -e means "print the
# environment", which would put the scrubbed build env on our own stdout).
build_gate_holders() {
  ps -Ao pid,etime,args 2>/dev/null \
    | grep -Ea 'npm (ci|run build)|astro build|next build|site-deploy' \
    | grep -av 'grep -Ea' \
    | head -3 \
    | awk '{ $1=$1; print }' \
    | tr '\n' ';'
}

# build_gate_acquire — 0 = ADMITTED (slot held, or the gate failed open), 1 = the
# wait budget lapsed and the caller must refuse (emit BUILD failed, then exit 15).
build_gate_acquire() {
  BUILD_GATE_WAIT="${BARKPARK_BUILD_GATE_WAIT:-$BUILD_GATE_WAIT_DEFAULT}"
  BUILD_GATE_LOCK="${BARKPARK_BUILD_GATE_LOCK:-/var/lock/barkpark-site-build.lock}"
  if ! command -v flock >/dev/null 2>&1; then
    log "WARN: no flock(1) on this box — the fleet build admission gate is OPEN and this build is NOT serialized against other sites' builds; install util-linux to restore one-box-one-build"
    return 0
  fi
  if ! mkdir -p "$(dirname "$BUILD_GATE_LOCK")" 2>/dev/null; then
    log "WARN: cannot create $(dirname "$BUILD_GATE_LOCK") — the fleet build lock falls back to ${TMPDIR:-/tmp}/barkpark-site-build.lock; every engine on this box MUST resolve the same path or the builds do not serialize"
    BUILD_GATE_LOCK="${TMPDIR:-/tmp}/barkpark-site-build.lock"
  fi
  if ! ( : > "$BUILD_GATE_LOCK" ) 2>/dev/null || ! exec 7>"$BUILD_GATE_LOCK"; then
    log "WARN: cannot open the fleet build lock $BUILD_GATE_LOCK — the build admission gate is OPEN (admitting this build unserialized); check the path's ownership/permissions"
    return 0
  fi
  if flock -n 7; then
    BUILD_GATE_HELD=1
    log "BUILD: fleet build slot acquired (1 of $BUILD_GATE_SLOTS, $BUILD_GATE_LOCK)"
    return 0
  fi
  # Held by another site's build. Say so IMMEDIATELY — a silent multi-minute
  # stall is the state an operator reads as "the deploy hung".
  log "BUILD: the box's only build slot is busy — queueing up to ${BUILD_GATE_WAIT}s (in flight: $(build_gate_holders))"
  if ! flock -w "$BUILD_GATE_WAIT" 7; then
    exec 7>&-
    return 1
  fi
  BUILD_GATE_HELD=1
  log "BUILD: fleet build slot acquired after queueing (1 of $BUILD_GATE_SLOTS, $BUILD_GATE_LOCK)"
  return 0
}

# build_gate_release — drop the slot. Idempotent, and a no-op when the gate failed
# open (nothing was ever held). Closing fd 7 releases the flock; the kernel would
# do it at process exit too, but "at exit" is TOO LATE for the node engine, whose
# booted slot process inherits the fd and outlives the run.
build_gate_release() {
  [ "$BUILD_GATE_HELD" = 1 ] || return 0
  exec 7>&-
  BUILD_GATE_HELD=0
  log "BUILD: fleet build slot released"
}
