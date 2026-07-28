#!/usr/bin/env bash
#
# pds-scratch-target.sh — boot and tear down a FULLY ISOLATED personal-local
# Barkpark (the PDS pull TARGET) on this host, from any checkout or worktree.
#
#   scripts/pds-scratch-target.sh up          boot a scratch instance, mint an
#                                             admin token, write scratch.env
#   scripts/pds-scratch-target.sh up --verify boot, then run the verify suite
#   scripts/pds-scratch-target.sh verify      prove the isolation is REAL
#   scripts/pds-scratch-target.sh status      where is it, is it up
#   scripts/pds-scratch-target.sh env         print the sourceable scratch.env
#   scripts/pds-scratch-target.sh teardown    stop everything, assert both ports
#                                             released and zero orphan postgres,
#                                             THEN remove the tree — a failed
#                                             assert leaves the root standing so
#                                             the leak is still diagnosable
#
# Every guard below exists because a verification run HIT the failure. Read the
# TRAP comments before "simplifying" any of them away.
#
# The instance it stands up is disposable and self-contained:
#   $BARKPARK_HOME          scratch root (Postgres data dir, socket, logs, .env)
#   $BARKPARK_PG_PORT       free port, never 5432/5433
#   $PORT                   free port, never 4000
#   $BARKPARK_MEDIA_DIR     scratch media root — NOT any checkout's api/uploads
#
# It never touches the dev database, the shared ~/.barkpark install, the running
# tree's api/uploads, or anything on a remote. bin/barkpark and bin/barkpark-pg
# are used AS-IS and are never modified.
#
# COST — there are THREE regimes, and the one-line discriminator most readers
# reach for is COARSE enough to put you in the wrong one. Read this before you
# budget a timed window (PDS-D241).
#
# The coarse test — what this header used to call the only switch:
#
#   [ -n "$(ls -A api/_build 2>/dev/null)" ] && echo warm || echo COLD
#
# It answers "has ANY MIX_ENV ever compiled in this checkout?", so it flips to
# WARM the moment api/_build/dev or api/_build/test exists. But `up` boots the
# server under MIX_ENV=prod, so the thing that actually decides your cost is
# whether api/_build/prod exists. `ls -A api/_build` reports WARM on a worktree
# that has never compiled prod, and that worktree pays a full prod compile.
# The honest discriminator:
#
#   [ -d api/_build/prod ] && echo warm || echo COLD-PROD
#
#   COLD (api/_build absent or empty): TWO full compiles — ensure_secrets runs
#     MIX_ENV=dev, the server boots MIX_ENV=prod. >10 minutes is realistic.
#     (Inherited figure, never re-measured.)
#   COLD-PROD (dev and/or test present, api/_build/prod ABSENT — exactly the
#     case `ls -A api/_build` mislabels as WARM): ONE full MIX_ENV=prod compile.
#     Measured 2026-07-21 on a worktree whose dev+test _build already existed
#     from sibling activity while prod did not:
#       up --verify   2:35.72 — 155.72s wall, 134.47s user + 30.44s system,
#                     105% CPU
#     Boot, verify (all isolation controls incl. the negative control) and
#     teardown all PASSED — the instrument is HEALTHY, it just costs 4.75x the
#     WARM first-`up` figure below. It is CPU-bound compilation: NOT I/O and NOT
#     dependency resolution (`mix deps.get` returned in 0.228s, every dep
#     Unchanged).
#   WARM (api/_build/prod present — _build measured at 290 MB across 71 deps):
#     first `up` of a session   32.742s  (~20s of that is `mix deps.get`
#                                        RESOLVING deps, not compiling)
#     later `up` in the session  9.830s  (deps already resolved)
#     teardown                   8.068s
#     teardown + up (one cycle) 20.240s
#
# PRE-WARM BEFORE ANY TIMED WINDOW OPENS. On a worktree that has not compiled
# prod, pay that compile off the clock:
#
#   cd api && CC=/usr/bin/clang MIX_ENV=prod mix compile   # or a throwaway cycle
#
# CC=/usr/bin/clang IS NOT OPTIONAL HERE. `cc` resolves to the Claude CLI
# wrapper, not a C compiler, and argon2_elixir dies with "unknown option '-g'".
# Without the override the pre-warm does not run slow, it FAILS — and the
# throwaway-cycle alternative hits the same trap, because it runs the same
# compile. Live-proven by the wave-13 crown-climb run, which hit exactly this.
#
# Then the run inside the window pays the ~9.8–20.2s WARM cycle instead of
# another ~156s cold-prod compile on the critical path. That same run measured
# `up --verify` at ~10s wall once pre-warmed.
#
# Every WARM figure above was measured on a real host on 2026-07-20 with
# api/_build populated; the COLD-PROD figure on 2026-07-21. The old "~90s warm"
# in this header was wrong by ~4.5x and made re-arming a target look far more
# expensive than it is; the "empty api/_build" trigger that replaced it was too
# coarse in the other direction and made a ~156s prod compile look like a 33s
# boot. Full record, incl. how to hold a pre-booted SPARE target (drives the
# miss cost to ~0): scripts/pds-scratch-target-cost-2026-07-20.md.
#
# NAMED RESIDUE: the runtime preflight warning in `cmd_up` (search
# "api/_build is empty") still branches on the coarse `ls -A api/_build` test,
# so it stays SILENT in the COLD-PROD case. Deliberately not fixed here — this
# slice is docs-and-comments only (PDS-D241) and changing that branch would
# change a verb's output. Filed as a follow-up task.

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
API_DIR="$REPO_ROOT/api"
# Overridable ONLY so pds-scratch-target_test.sh can drive the real verbs
# against a stub instead of stopping a real server. Nothing in normal use sets
# it; `up`'s executability check still runs against whatever it resolves to.
BARKPARK_BIN="${PDS_SCRATCH_BARKPARK_BIN:-$REPO_ROOT/bin/barkpark}"
PG_BIN_SCRIPT="$REPO_ROOT/bin/barkpark-pg"

# Pointer to the most recent scratch root, so `verify`/`teardown`/`env` work in
# a later shell without the caller having to remember the mktemp path.
#
# CONCURRENT TARGETS (the spare-target recipe — two proven coexisting live on
# 2026-07-20, disjoint HTTP ports :22940/:30540 and disjoint Postgres :41596/
# :20104, with the host dev server on :4000 untouched across BOTH teardowns,
# because free_port() probes before binding).
#
# THE POINTER USED TO BE THE ONLY MAP, AND IT LOST TARGETS (PDS-D318).
# Reproduced end to end: `up` writes this ONE global path UNCONDITIONALLY, so a
# second `up` CLOBBERS it; `teardown` then resolves the SECOND root, destroys
# it, prints `---- teardown: PASS`, and clears the pointer — after which all
# four read verbs die with "no scratch target known" while the FIRST root is
# still standing, fully live, with a Postgres nobody can now find. The clear was
# never the bug (it is guarded to fire only on its own root); the CLOBBER was,
# and clearing the last remaining slot is what turned it into a strand.
#
# So the pointer is no longer the map. It is kept as a "most recent" hint for
# roots booted before this change; the REGISTRY below is the truth.
POINTER_FILE="${PDS_SCRATCH_POINTER:-/tmp/pds-scratch-target.last}"

# ── the live-target REGISTRY (PDS-D318) ──────────────────────────────────────
#
# One file per live root: filename is a derived key, CONTENT is the canonical
# root path. `up` adds an entry, `teardown` removes ONLY its own, and
# resolve_home REFUSES WITH A LIST when more than one survives rather than
# guessing (guessing is what the single pointer did).
#
# Derived from POINTER_FILE on purpose: the crown launcher already exports a
# PER-RUN PDS_SCRATCH_POINTER (pds-crown-launch.sh fire_detached), so a pinned
# pointer keeps getting its own private registry and stays isolated from the
# default one — the existing spare-target recipe keeps working unchanged.
REGISTRY_DIR="${PDS_SCRATCH_REGISTRY:-$POINTER_FILE.d}"

# Entries are matched BY CONTENT, never by filename, so the key scheme can
# change (or a caller can seed an entry by hand) without orphaning rows.
registry_add() {
  local key
  mkdir -p "$REGISTRY_DIR"
  key="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s\n' "$1" > "$REGISTRY_DIR/$key"
}

registry_remove() {
  local f
  [ -d "$REGISTRY_DIR" ] || return 0
  for f in "$REGISTRY_DIR"/*; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null || true)" = "$1" ]; then rm -f "$f"; fi
  done
  return 0
}

# Every registered root whose tree still EXISTS, one per line. An entry whose
# root is gone (removed by hand, or by a teardown that died before its own
# removal) is pruned here rather than left to make the map lie.
registry_live() {
  local f root
  [ -d "$REGISTRY_DIR" ] || return 0
  for f in "$REGISTRY_DIR"/*; do
    [ -f "$f" ] || continue
    root="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$root" ] && [ -d "$root" ]; then
      printf '%s\n' "$root"
    else
      rm -f "$f"
    fi
  done
  return 0
}

registry_count() { registry_live | grep -c . || true; }

# Read one exported value out of a root's scratch.env WITHOUT sourcing it —
# sourcing here would overwrite the caller's own PORT/BARKPARK_HOME mid-verb.
env_field() { # $1 = root · $2 = var name
  local f v
  f="$(scratch_env_file "$1")"
  [ -f "$f" ] || { printf '?\n'; return 0; }
  v="$(sed -n "s/^export $2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$f" | tail -1)"
  printf '%s\n' "${v:-?}"
}

# The human-readable map: root, HTTP port, Postgres port. Ports come from each
# root's OWN scratch.env, which is also what teardown needs to stop it safely.
registry_lines() {
  local root
  registry_live | while IFS= read -r root; do
    [ -n "$root" ] || continue
    printf '  %s  PORT=%s  BARKPARK_PG_PORT=%s\n' \
      "$root" "$(env_field "$root" PORT)" "$(env_field "$root" BARKPARK_PG_PORT)"
  done
}

# Postgres caps a unix-socket path at 103 bytes (see TRAP 3). barkpark-pg puts
# the socket at $BARKPARK_HOME/.s.PGSQL.<port> — that suffix is up to 18 bytes,
# so the root itself must stay comfortably short.
MAX_HOME_LEN=85

log()  { printf 'pds-scratch: %s\n' "$*"; }
warn() { printf 'pds-scratch: WARNING %s\n' "$*" >&2; }
die()  { printf 'pds-scratch: %s\n' "$*" >&2; exit 1; }
hr()   { printf -- '---- %s\n' "$*"; }

# ── TRAP 2 — the `cc` on PATH may not be a C compiler ────────────────────────
#
# ~/.local/bin/cc on this host is literally `exec claude --dangerously-skip-
# permissions "$@"`, and it precedes /usr/bin/cc on PATH for /bin/sh too, so
# `make` picks it up when building the argon2_elixir NIF. The build then dies
# with `error: unknown option '-g'`, which Mix mistranslates into the wholly
# misleading "You need to have gcc and make installed". Pin the real compiler.
export_real_cc() {
  if [ -x /usr/bin/clang ]; then
    export CC=/usr/bin/clang
    log "CC=/usr/bin/clang (TRAP 2: a shim 'cc' on PATH breaks the argon2 NIF build)"
  else
    warn "/usr/bin/clang not found — leaving CC=${CC:-unset}; if a NIF build fails with \"You need to have gcc and make installed\", check \`command -v cc\`"
  fi
}

# ── TRAP 7 — free ports, chosen loudly ───────────────────────────────────────
#
# bin/barkpark refuses to boot when $PORT is taken (good — fail loud), and a
# scratch Postgres must never land on 5432 (system) or 5433 (the shared managed
# instance under ~/.barkpark).
port_in_use() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

free_port() {
  local p _i
  for _i in $(seq 1 200); do
    p=$(( 20000 + RANDOM % 30000 ))
    case "$p" in 4000|5432|5433) continue ;; esac
    if ! port_in_use "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  die "could not find a free TCP port after 200 tries"
}

# ── scratch root resolution + TRAP 3 ─────────────────────────────────────────
#
# TRAP 3: barkpark-pg starts Postgres with `-k $BARKPARK_HOME`, so the unix
# socket lives at $BARKPARK_HOME/.s.PGSQL.<port>. Postgres caps that path at 103
# bytes. A 109-byte agent scratchpad path fails with
#   FATAL:  could not create any Unix-domain sockets
# which is visible ONLY in $BARKPARK_HOME/postgres.log — `bin/barkpark up`
# surfaces nothing but the generic `pg_ctl: could not start server`. Hence the
# hard assert AND the /tmp default (never $TMPDIR, which on this host resolves
# under a per-agent scratch directory).
assert_short_home() {
  local home="$1"
  if [ "${#home}" -ge "$MAX_HOME_LEN" ]; then
    printf 'pds-scratch: BARKPARK_HOME is %s bytes, which is too long (limit %s).\n' \
      "${#home}" "$MAX_HOME_LEN" >&2
    printf '  %s\n' "$home" >&2
    cat >&2 <<'EOF'
  WHY: barkpark-pg puts the Postgres unix socket at $BARKPARK_HOME/.s.PGSQL.<port>
  and Postgres caps that path at 103 bytes. Over the cap, the server dies with
    FATAL:  could not create any Unix-domain sockets
  logged ONLY to $BARKPARK_HOME/postgres.log — `barkpark up` just prints
  "pg_ctl: could not start server", so the real cause is invisible.
  FIX: use a short root, e.g. BARKPARK_HOME=$(mktemp -d /tmp/pds.XXXX).
EOF
    exit 1
  fi
}

# ── TRAP 7 — /tmp is a symlink, so one root has two spellings ────────────────
#
# On macOS /tmp -> /private/tmp. `up` canonicalises with `cd -P` before writing
# the pointer, so the pointer holds the PHYSICAL path — but resolve_home used to
# hand back BARKPARK_HOME verbatim, so teardown's exact-string pointer compare
# could NEVER match a caller who spelled the root /tmp/... The root was removed,
# teardown printed PASS, and the pointer was left naming a path that no longer
# exists; the next pointer-trusting call died with "scratch root ... does not
# exist (already torn down?)". Both spellings must resolve identically (PDS-D107).
#
# Must work on an ALREADY-DELETED path — teardown compares the pointer AFTER the
# root is gone — so resolve the deepest EXISTING ancestor and re-append the tail
# rather than requiring the whole path to be there.
canonicalize_path() {
  local p="${1:-}" tail=""
  [ -n "$p" ] || return 0
  while [ ! -d "$p" ]; do
    case "$p" in
      /|.|..|"") break ;;
    esac
    tail="/$(basename -- "$p")$tail"
    p="$(dirname -- "$p")"
  done
  [ ! -d "$p" ] || p="$(cd -P -- "$p" && pwd)"
  # `${p%/}` strips the trailing slash so "/a" + "/b" never becomes "/a//b" — but
  # for the root itself that leaves the EMPTY string, and "" does not match the
  # `case "$home" in /) die` interlock guarding the rm -rf below. Keep "/" as "/"
  # so that guard still fires on the one input it exists to refuse.
  local out="${p%/}$tail"
  [ -n "$out" ] || out="/"
  printf '%s\n' "$out"
}

new_scratch_home() {
  local home
  if [ -n "${BARKPARK_HOME:-}" ]; then
    home="$BARKPARK_HOME"
    mkdir -p "$home"
  else
    home="$(mktemp -d /tmp/pds.XXXX)"
  fi
  home="$(canonicalize_path "$home")"
  assert_short_home "$home"
  printf '%s\n' "$home"
}

scratch_env_file() { printf '%s/scratch.env\n' "$1"; }

# Resolve an EXISTING scratch root for verify/status/teardown/env.
#
# THREE sources, in this order (PDS-D318):
#   1. $BARKPARK_HOME — an explicit caller always wins.
#   2. the REGISTRY — exactly one live entry resolves; TWO OR MORE REFUSE with
#      the list, because picking one is the guess that stranded the other.
#   3. the legacy pointer — only when the registry knows nothing, so a root
#      booted before this change is still reachable.
resolve_home() {
  local home="${BARKPARK_HOME:-}" n
  if [ -z "$home" ]; then
    n="$(registry_count)"
    if [ "${n:-0}" -gt 1 ]; then
      die "$n scratch targets are live — REFUSING to guess which one you mean.
$(registry_lines)
  Name one explicitly:
    BARKPARK_HOME=<root> $0 <verb>
  (The single pointer this replaced would have silently picked the most recent
  one and stranded the rest.)"
    elif [ "${n:-0}" -eq 1 ]; then
      home="$(registry_live | head -1)"
    elif [ -f "$POINTER_FILE" ]; then
      home="$(cat "$POINTER_FILE")"
    fi
  fi
  [ -n "$home" ] || die "no scratch target known — set BARKPARK_HOME=... or run \`$0 up\` first"
  [ -d "$home" ] || die "scratch root $home does not exist (already torn down?)"
  # Same canonicalisation `up` applied before writing the pointer (TRAP 7) — a
  # caller spelling the root /tmp/... and a pointer holding /private/tmp/... are
  # the same target, and teardown's pointer compare depends on saying so.
  canonicalize_path "$home"
}

load_scratch_env() {
  local home envf
  home="$(resolve_home)"
  envf="$(scratch_env_file "$home")"
  [ -f "$envf" ] || die "$envf missing — that root was never booted by this script"
  set -a
  # shellcheck disable=SC1090
  . "$envf"
  set +a
}

# ── TRAP 6 — mint an admin token ─────────────────────────────────────────────
#
# A fresh box 401s the blob-push route and there is NO mix task that mints a
# token (33 tasks, none auth). api_tokens stores only sha256(raw) hex
# (Barkpark.Auth.ApiToken.hash_token/1), and BarkparkWeb.Plugs.RequireAdmin
# demands the "admin" permission, so insert the row directly and print the raw
# token. kind='api' is what Auth.verify_token/1 filters on.
mint_admin_token() {
  local raw hash
  raw="pds-scratch-$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 40)"
  hash="$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')"

  "$PG_BIN_SCRIPT" psql --quiet --tuples-only --no-align --command \
    "INSERT INTO api_tokens (id, token_hash, label, name, dataset, permissions, kind, inserted_at, updated_at)
     VALUES (gen_random_uuid(), '$hash', 'pds-scratch', 'pds-scratch admin', 'production',
             ARRAY['read','write','admin'], 'api', now(), now())" >/dev/null

  printf '%s\n' "$raw"
}

# ── up ───────────────────────────────────────────────────────────────────────

cmd_up() {
  local run_verify="${1:-}"

  command -v mix >/dev/null 2>&1   || die "mix not found on PATH — install Elixir"
  command -v curl >/dev/null 2>&1  || die "curl not found on PATH"
  command -v shasum >/dev/null 2>&1 || die "shasum not found on PATH"
  [ -x "$BARKPARK_BIN" ] || die "$BARKPARK_BIN not found or not executable"

  local home port pg_port media_dir boot_log envf token pg_conninfo
  home="$(new_scratch_home)"
  media_dir="${BARKPARK_MEDIA_DIR:-$home/media}"
  port="${PORT:-$(free_port)}"
  pg_port="${BARKPARK_PG_PORT:-$(free_port)}"
  boot_log="$home/up.log"
  envf="$(scratch_env_file "$home")"

  mkdir -p "$media_dir"

  # TRAP 4 — bin/barkpark NEVER sets BARKPARK_MEDIA_DIR (zero occurrences) and
  # the compiled default is Path.expand("../uploads", __DIR__) = the RUNNING
  # TREE's api/uploads. A harness that forgets this writes pulled blobs into the
  # shared dev checkout. Always set it, explicitly, before anything boots.
  export BARKPARK_HOME="$home"
  export BARKPARK_MEDIA_DIR="$media_dir"
  export BARKPARK_PG_PORT="$pg_port"
  export PORT="$port"
  export PHX_HOST="${PHX_HOST:-localhost}"

  export_real_cc

  log "scratch root   $home  (${#home} bytes, limit $MAX_HOME_LEN)"
  log "http port      $port"
  log "postgres port  $pg_port"
  log "media dir      $media_dir"
  log "tree           $REPO_ROOT"

  if [ ! -d "$API_DIR/_build" ] || [ -z "$(ls -A "$API_DIR/_build" 2>/dev/null)" ]; then
    warn "api/_build is empty — COLD tree: two full compiles (MIX_ENV=dev for secrets, MIX_ENV=prod for the server), expect >10 minutes. WARM (populated api/_build) is a different regime entirely: 32.7s first boot of a session, 9.8s after, 20.2s for a full teardown+respawn cycle — measured 2026-07-20, see scripts/pds-scratch-target-cost-2026-07-20.md."
  fi

  # TRAP 1 — bin/barkpark cmd_up only checks `command -v mix`; on a fresh
  # worktree the very first thing it runs (ensure_secrets) compiles, and the
  # compile dies on missing deps. Fetch them first, ourselves.
  log "mix deps.get (TRAP 1: bin/barkpark only checks for mix, not for deps)"
  ( cd "$API_DIR" && mix deps.get )

  # TRAP 5 — NEVER pipe `bin/barkpark up` into a pager/tail. On a FIRST boot the
  # spawned postgres and the nohup'd BEAM inherit the pipe's write end, so the
  # reader never sees EOF and the command hangs forever (measured: 9 minutes,
  # ended only by SIGTERM). Redirect to a file and read the file afterwards.
  log "booting (log: $boot_log) — not piped, see TRAP 5"
  if ! "$BARKPARK_BIN" up >"$boot_log" 2>&1; then
    hr "tail $boot_log"
    tail -40 "$boot_log" >&2 || true
    if [ -f "$home/postgres.log" ]; then
      hr "tail $home/postgres.log (TRAP 3 lives here — socket-path failures are invisible upstream)"
      tail -20 "$home/postgres.log" >&2 || true
    fi
    die "boot failed — see $boot_log"
  fi
  tail -5 "$boot_log"

  log "minting admin token (TRAP 6: a fresh box 401s the blob-push route)"
  token="$(mint_admin_token)"

  # barkpark-pg's own defaults (bin/barkpark-pg: PG_HOST=127.0.0.1, PG_DB and
  # PG_USER default to "barkpark", overridable via BARKPARK_PG_DB/_USER). Mirror
  # the overrides rather than hardcoding, so scratch.env stays true if a caller
  # sets them.
  pg_conninfo="host=127.0.0.1 port=$pg_port dbname=${BARKPARK_PG_DB:-barkpark} user=${BARKPARK_PG_USER:-barkpark}"

  cat >"$envf" <<EOF
# sourceable handle on this scratch personal-local target
export BARKPARK_HOME="$home"
export BARKPARK_MEDIA_DIR="$media_dir"
export BARKPARK_PG_PORT="$pg_port"
export PORT="$port"
export PHX_HOST="$PHX_HOST"
export PDS_SCRATCH_BASE="http://$PHX_HOST:$port"
export PDS_SCRATCH_TOKEN="$token"
export PDS_SCRATCH_TREE="$REPO_ROOT"
# A libpq conninfo for the scratch database, so the crown proof can hand the
# TARGET DB straight to \`pds-secret-scan.sh --db\` (step 4 scores the imported
# rows, not only the bundle bytes) without re-deriving barkpark-pg's defaults.
export PDS_SCRATCH_DB="$pg_conninfo"
EOF
  # The pointer stays a "most recent" hint (and stays clobberable — that is all
  # it ever was). The REGISTRY is the map: this root gets its own entry, so a
  # second `up` ADDS rather than REPLACES (PDS-D318).
  printf '%s\n' "$home" >"$POINTER_FILE"
  registry_add "$home"

  hr "ready"
  printf 'base:  http://%s:%s\n' "$PHX_HOST" "$port"
  printf 'token: %s\n' "$token"
  printf 'env:   source %s\n' "$envf"
  printf 'down:  %s teardown\n' "$0"

  if [ "$run_verify" = "--verify" ] || [ "$run_verify" = "verify" ]; then
    cmd_verify
  fi
}

# ── verify — the negative control is the point ───────────────────────────────
#
# Distrust vacuous green (PDS charter — the crown proof pulls a live dataset into
# a scratch target, so the target's isolation must itself be proven). Asserting only that the media dir IS the
# scratch path is worthless from a worktree: the UN-isolated blast target
# follows the tree you run from, so a `find` against the PRIMARY checkout's
# uploads would pass green while this worktree's own api/uploads got polluted.
# So we print Barkpark.Media.upload_dir() TWICE — with BARKPARK_MEDIA_DIR set
# and with it stripped by `env -u` — and assert the second one is exactly this
# tree's api/uploads. The un-isolated path is shown FIRING.
upload_dir_probe() {
  # MIX_ENV=dev on purpose: runtime.exs's prod branch RAISES on missing
  # SECRET_KEY_BASE/DATABASE_URL, and the BARKPARK_MEDIA_DIR block sits OUTSIDE
  # that guard, so dev reads the same key. --no-start: no supervision tree.
  ( cd "$API_DIR" && MIX_ENV=dev mix run --no-start -e 'IO.puts(Barkpark.Media.upload_dir())' \
      2>/dev/null | tail -1 )
}

cmd_verify() {
  load_scratch_env

  local fails=0
  ok()  { printf '  PASS  %s\n' "$*"; }
  bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

  hr "1. negative control — Barkpark.Media.upload_dir(), isolated vs NOT"
  local isolated unisolated expected_unisolated
  # `|| true` on BOTH probes on purpose: a probe that fails to run must show up
  # as a FAIL line below (with the empty value printed), never as `set -e`
  # killing verify mid-section with no output — a silent exit reads exactly like
  # "nothing to report", which is the one thing a control may never look like.
  isolated="$(upload_dir_probe || true)"   # BARKPARK_MEDIA_DIR is exported by scratch.env
  unisolated="$(env -u BARKPARK_MEDIA_DIR bash -c "cd '$API_DIR' && MIX_ENV=dev mix run --no-start -e 'IO.puts(Barkpark.Media.upload_dir())'" 2>/dev/null | tail -1 || true)"
  expected_unisolated="$API_DIR/uploads"

  printf '  WITH  BARKPARK_MEDIA_DIR -> %s\n' "$isolated"
  printf '  env -u BARKPARK_MEDIA_DIR -> %s\n' "$unisolated"

  if [ "$isolated" = "$BARKPARK_MEDIA_DIR" ]; then
    ok "isolated upload_dir is the scratch path"
  else
    bad "isolated upload_dir is '$isolated', expected '$BARKPARK_MEDIA_DIR'"
  fi
  if [ "$unisolated" = "$expected_unisolated" ]; then
    ok "un-isolated upload_dir is the RUNNING TREE's api/uploads — the blast target is real, so the green above is not free"
  else
    bad "un-isolated upload_dir is '$unisolated', expected '$expected_unisolated' (negative control did not fire — do not trust the positive half)"
  fi

  hr "2. the scratch server answers, and it is not on 4000"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$PDS_SCRATCH_BASE/api/schemas" || true)"
  if [ "$code" = "200" ]; then
    ok "GET $PDS_SCRATCH_BASE/api/schemas -> 200"
  else
    bad "GET $PDS_SCRATCH_BASE/api/schemas -> $code"
  fi
  # Report what (if anything) holds 4000 — someone else's dev server is fine,
  # OURS would mean the scratch target is not isolated at all.
  local pid_4000 our_pid
  pid_4000="$(lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  our_pid="$(cat "$BARKPARK_HOME/server.pid" 2>/dev/null || true)"
  printf '  port 4000 listener: %s | scratch server pid: %s\n' "${pid_4000:-none}" "${our_pid:-unknown}"
  if [ "$PORT" != "4000" ] && { [ -z "$pid_4000" ] || [ "$pid_4000" != "$our_pid" ]; }; then
    ok "scratch PORT=$PORT, PG=$BARKPARK_PG_PORT — nothing of OURS listens on 4000"
  else
    bad "the scratch instance is on 4000 (PORT=$PORT, listener $pid_4000) — not isolated from a normal dev server"
  fi

  hr "3. admin token + blob push land in the scratch media dir"
  local blob_path tmp_png resp
  blob_path="pds-scratch/2026/07/probe-$$.png"
  tmp_png="$BARKPARK_HOME/probe.png"
  printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
    | base64 -d >"$tmp_png" 2>/dev/null || printf 'PDS-SCRATCH-PROBE' >"$tmp_png"

  resp="$(curl -s -w '\n%{http_code}' -X PUT \
    "$PDS_SCRATCH_BASE/api/workspaces/default/media/blob/$blob_path" \
    -H "Authorization: Bearer $PDS_SCRATCH_TOKEN" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$tmp_png" || true)"
  code="$(printf '%s' "$resp" | tail -1)"
  printf '  PUT /api/workspaces/default/media/blob/%s -> %s %s\n' \
    "$blob_path" "$code" "$(printf '%s' "$resp" | sed '$d')"
  if [ "$code" = "200" ]; then
    ok "blob push accepted with the minted admin token"
  else
    bad "blob push returned $code (expected 200)"
  fi

  if [ -f "$BARKPARK_MEDIA_DIR/$blob_path" ]; then
    ok "bytes landed at \$BARKPARK_MEDIA_DIR/$blob_path"
  else
    bad "bytes did NOT land at \$BARKPARK_MEDIA_DIR/$blob_path"
  fi

  # The blast target is THIS tree (see the negative control above), so search it.
  local strays
  strays="$(find "$API_DIR/uploads" -name "probe-$$.png" 2>/dev/null | head -5 || true)"
  if [ -z "$strays" ]; then
    ok "no copy under $API_DIR/uploads — the checkout stayed clean"
  else
    bad "blob leaked into the running tree: $strays"
  fi

  hr "verify: $([ "$fails" -eq 0 ] && echo PASS || echo "FAIL ($fails)")"
  [ "$fails" -eq 0 ]
}

# ── status / env ─────────────────────────────────────────────────────────────

cmd_status() {
  load_scratch_env
  printf 'root:  %s\n' "$BARKPARK_HOME"
  printf 'base:  %s\n' "$PDS_SCRATCH_BASE"
  printf 'media: %s\n' "$BARKPARK_MEDIA_DIR"
  "$BARKPARK_BIN" status || true
}

cmd_env() {
  local home
  home="$(resolve_home)"
  cat "$(scratch_env_file "$home")"
}

# ── teardown ─────────────────────────────────────────────────────────────────

# What is still standing after this teardown, and how to reach it.
#
# TWO COUNTS, AND THEY MEASURE DIFFERENT THINGS — say which:
#   * the REGISTRY count is exact for roots THIS registry knows (i.e. booted
#     with this PDS_SCRATCH_POINTER / PDS_SCRATCH_REGISTRY).
#   * the GLOB count sees only roots matching the DEFAULT mktemp pattern
#     /tmp/pds.*; a root booted with a pinned BARKPARK_HOME somewhere else is
#     invisible to it. So it is reported as "N under the default pattern",
#     NEVER as "all" — the glob cannot back the word "all".
report_survivors() {
  local n glob_n
  n="$(registry_count)"
  if [ "${n:-0}" -eq 0 ]; then
    log "no other scratch target is registered live in $REGISTRY_DIR"
  else
    log "$n other scratch target(s) still registered LIVE — reach one with BARKPARK_HOME=<root>:"
    registry_lines
  fi
  glob_n="$(ls -d /tmp/pds.*/scratch.env 2>/dev/null | grep -c . || true)"
  log "$glob_n root(s) carry a scratch.env under the default /tmp/pds.* pattern (that glob sees ONLY default-pattern roots — a root booted with a pinned BARKPARK_HOME elsewhere is not counted)"
}

cmd_teardown() {
  local home envf port pg_port fails=0
  home="$(resolve_home)"
  envf="$(scratch_env_file "$home")"
  if [ -f "$envf" ]; then
    # shellcheck disable=SC1090
    . "$envf"
  fi
  port="${PORT:-}"
  pg_port="${BARKPARK_PG_PORT:-}"

  export BARKPARK_HOME="$home"
  # `if`, not `[ … ] && export` — under `set -e` a false test as a bare command
  # aborts teardown right here, and a root whose scratch.env is missing or
  # truncated is EXACTLY when you most need the stop + the asserts to run.
  # THE PORT IS NOT OPTIONAL HERE. `bin/barkpark stop` → stop_server falls back
  # to `listener_pid` when its pidfile is stale or missing, and listener_pid
  # reads $PORT, which DEFAULTS TO 4000. So a teardown that does not know this
  # root's own port does not tear down nothing — it kills whatever holds port
  # 4000, i.e. the host's shared dev server, the one thing this script's header
  # promises never to touch. (Reproduced during review: a scratch root with a
  # truncated scratch.env killed the dev server on 4000 and still printed PASS.)
  # Refuse instead, and say what to do.
  if [ -z "$port" ] || [ -z "$pg_port" ]; then
    die "refusing to tear down $home — its scratch.env does not name both ports (PORT='${port:-}', BARKPARK_PG_PORT='${pg_port:-}').
  Without this root's OWN port, \`barkpark stop\` falls back to whatever listens
  on the default 4000 and would kill the host's dev server.
  FIX: re-run with the real values, e.g.
    PORT=<this root's http port> BARKPARK_PG_PORT=<its pg port> $0 teardown
  or remove the root by hand once you have confirmed nothing is using it."
  fi
  export PORT="$port"
  export BARKPARK_PG_PORT="$pg_port"

  log "stopping server + postgres under $home (PORT=$port, PG=$pg_port)"
  "$BARKPARK_BIN" stop || warn "barkpark stop reported an error — continuing to the asserts"

  local p
  for p in $port $pg_port; do
    if port_in_use "$p"; then
      printf 'pds-scratch: FAIL port %s still has a listener:\n' "$p" >&2
      lsof -nP -iTCP:"$p" -sTCP:LISTEN >&2 || true
      fails=$((fails + 1))
    else
      log "port $p released"
    fi
  done

  # Orphan check BEFORE the tree goes away — a postgres still holding this data
  # dir is exactly the leak we are looking for.
  #
  # FIXED-STRING, not `pgrep -f "postgres.*$home"`: pgrep's pattern is a regex,
  # so a caller-supplied BARKPARK_HOME containing `.`/`+`/`(` would quietly match
  # the wrong set (or nothing) and report a clean teardown over a live orphan.
  #
  # TRAP 8 — THE CHECK USED TO MATCH ITSELF. The previous form was
  #   ps -Ao pid=,command= | grep -F "$home" | grep -F postgres
  # which scores ANY process whose argv merely NAMES both the scratch root and
  # the substring "postgres" — including this script's own invocation, the
  # wrapper that launched it, and Homebrew's postgresql@17 TOOL paths
  # (…/postgresql@17/bin/pg_ctl -D $home …). Reproduced with Postgres fully down
  # ("database system is shut down", no postmaster.pid): an identical root FAILED
  # teardown twice from a command line that named it — "orphan postgres processes
  # for /private/tmp/pds.v4: 38130", roots left standing, exit 1 — and PASSED from
  # a wrapper whose argv did not. A teardown that fails because of how it was
  # typed is worse than no check: it trains the operator to ignore the one assert
  # that catches a real leak.
  #
  # Two independent defences, both required:
  #   1. PID EXCLUSION — never score this shell ($$), its parent ($PPID), or a
  #      direct child of this shell (the pipeline members, e.g. the awk whose own
  #      argv carries $home via -v).
  #   2. SERVER-BINARY ANCHOR — argv[0]'s BASENAME must be the postgres server
  #      itself (`postgres`, its argv-rewritten background workers `postgres:`,
  #      or `postmaster`). pg_ctl/psql/initdb name the data dir but do not HOLD
  #      it, and they are not what a leak looks like.
  # $home is passed to awk via -v, never interpolated into the program text, so a
  # root containing awk-special characters cannot alter the match either.
  local orphans
  # shellcheck disable=SC2009  # deliberate: pgrep -f is a REGEX, see above
  orphans="$(ps -Ao pid=,ppid=,command= 2>/dev/null |
    awk -v home="$home" -v self="$$" -v parent="$PPID" '
      {
        pid = $1; ppid = $2
        if (pid == self || pid == parent || ppid == self) next
        cmd = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", cmd)
        if (index(cmd, home) == 0) next
        argv0 = cmd
        sub(/[[:space:]].*$/, "", argv0)
        n = split(argv0, parts, "/")
        base = parts[n]
        if (base == "postgres" || base == "postgres:" || base == "postmaster") print pid
      }' | tr '\n' ' ' | sed 's/ *$//' || true)"
  if [ -n "$orphans" ]; then
    printf 'pds-scratch: FAIL orphan postgres processes for %s: %s\n' "$home" "$orphans" >&2
    fails=$((fails + 1))
  else
    log "zero orphan postgres for this scratch root"
  fi

  # A still-listening port or a live orphan postgres means something is STILL
  # USING this data dir. Yanking the tree out from under it turns a diagnosable
  # leak into a corrupted process with no evidence left to look at, so stop here
  # and leave the root standing — the operator re-runs teardown after killing it,
  # or removes it by hand. Nothing is silently swallowed: the FAIL lines above
  # already named the offending listener/pid, and the exit stays non-zero.
  if [ "$fails" -gt 0 ]; then
    warn "NOT removing $home — $fails assert(s) failed above and something may still be holding this data dir. Kill the offender and re-run: $0 teardown"
    hr "teardown: FAIL ($fails) — scratch root left at $home"
    return 1
  fi

  # Refuse to rm -rf anything that is not a scratch root we created/were given.
  case "$home" in
    /|"$HOME"|"$REPO_ROOT"*) die "refusing to remove $home — that is not a scratch root" ;;
  esac
  rm -rf "$home"
  if [ -d "$home" ]; then
    printf 'pds-scratch: FAIL %s still exists\n' "$home" >&2
    fails=$((fails + 1))
  else
    log "removed $home"
  fi

  # Deregister THIS root and nothing else (PDS-D318). Matching is by content, so
  # a concurrent session's entry cannot be removed by accident.
  registry_remove "$home"

  # Clear the pointer ONLY if it names the root we just removed. Both sides are
  # canonicalised (TRAP 7) so the two spellings of one root match; a pointer
  # naming a DIFFERENT root is another concurrent session's live target and is
  # left strictly alone.
  if [ -f "$POINTER_FILE" ] && [ "$(canonicalize_path "$(cat "$POINTER_FILE")")" = "$home" ]; then
    rm -f "$POINTER_FILE"
    log "cleared scratch pointer $POINTER_FILE"
  fi

  # NAME THE SURVIVORS. Emptying the map silently is how the strand used to
  # happen; a teardown that removes one of two roots must say the other is still
  # there, and say how to reach it.
  report_survivors

  hr "teardown: $([ "$fails" -eq 0 ] && echo PASS || echo "FAIL ($fails)")"
  [ "$fails" -eq 0 ]
}

# ── dispatch ─────────────────────────────────────────────────────────────────

case "${1:-up}" in
  up)               shift || true; cmd_up "${1:-}" ;;
  --verify|verify)  cmd_verify ;;
  teardown|down)    cmd_teardown ;;
  status)           cmd_status ;;
  env)              cmd_env ;;
  -h|--help|help)
    sed -n '3,30p' "$0"
    ;;
  *)
    echo "usage: pds-scratch-target.sh {up [--verify]|verify|status|env|teardown}" >&2
    exit 2
    ;;
esac
