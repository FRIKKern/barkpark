#!/usr/bin/env bash
# shellcheck disable=SC2329  # arm_caddy_site_route runs via with_caddy_lock "$@"; saw/nosaw only in --self-test — shellcheck 0.11 can't trace that
# Deploy a content-bound STATIC site (Astro adapter × static symlink-swap target)
# next to Phoenix on a Barkpark content box (e.g. guerrilla). Site-Spawner W1.
#
# This is a NEW state machine — deliberately NOT a parameterization of
# instance-deploy.sh (which is Phoenix-specific: mix/ecto, fixed port-pair slots,
# /api/schemas gate, git-reset rollback). It MIRRORS instance-deploy.sh's proven
# skeleton — flock serialize, typed exit codes, backup+validate+reload-or-revert
# for any Caddy mutation, fail-closed reset on any failure — over an immutable
# releases/<build_id>/ layout that a static build (no process to boot) can flip
# with an atomic symlink rename.  [charter D4/D5/D7/D8/D11]
#
# STATE MACHINE (deploy mode):
#   PLAN   build_id is passed in by the caller; if it is already the live
#          release, exit 0 no-op (the sites(site_id,build_id) unique index makes
#          this idempotent upstream — this is the on-box mirror).
#   BUILD  npm ci && npm run build in the site source dir, wrapped in
#          `systemd-run --scope -p MemoryMax=1500M -p CPUQuota=150%` and a
#          SCRUBBED env — only the injected BARKPARK_* build vars, NOTHING
#          inherited.  Vite gives process.env precedence over .env, so an ambient
#          BARKPARK_TOKEN/URL silently shadows the per-site token (live-proven
#          failure mode) — hence the scrub.
#   STAGE  copy ONLY dist/ (12-16K) into releases/<build_id>/; node_modules
#          (~148M) stays in the ephemeral build sandbox.
#   HEALTH throwaway static file server on a loopback ephemeral port rooted at
#          releases/<build_id>/: assert HTTP 200 AND that the bp-build-id /
#          bp-content-rev / bp-doc-id <meta> markers in the SERVED bytes carry
#          the VALUES this deploy intends to ship (D26 content-truth — see
#          health_gate).  Fail => the release is PURGED and NOTHING switches.
#   SWITCH atomic `current` symlink swap (rename(2)) — no Caddy reload in the flip.
#   RETIRE keep the newest N=5 release dirs, remove older (never current/previous).
# It also arms ONCE, idempotently, a marker-guarded Caddy `handle_path
# /sites/<slug>/*` block into the live FQDN block (mirrors arm_caddy_mcp_route):
# backup + caddy validate + reload-or-revert, never re-flipped per deploy — under
# the SHARED Caddyfile lock instance-deploy.sh also takes (D27, see with_caddy_lock).
#
# MACHINE STAGE PROTOCOL (D25) — alongside the human prose, stdout carries ONE
# machine line at every stage boundary:
#
#   BPSTAGE name=<PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE> status=<started|ok|skipped|noop|failed> build_id=<id> [detail="…"]
#
# The contract an orchestrator may rely on (deploy mode):
#   * A stage that RUNS emits `started`, then exactly one terminal line (`ok` or
#     `failed`).  A stage that does NOT run emits exactly one terminal line —
#     `skipped`, or `noop` for a PLAN that finds the build already live.
#   * A successful deploy emits a terminal line for ALL SIX stages, in order.
#   * A `failed` line is the LAST stage line of the run: the process then exits
#     with that stage's typed code.  The REASON rides on the line (detail="…"),
#     so a stdout-only caller can always tell the user WHY — BUILD's own output
#     (npm/Vite, e.g. `FATAL: 401 Unauthorized … the site read token is invalid`)
#     is merged onto stdout for the same reason, and its last error line becomes
#     the detail.
#   * The three paths that used to be SILENT — a PLAN no-op, a SKIP_BUILD
#     redeploy, a RETIRE that removes nothing — all speak.  Nothing hangs a
#     stage-watching orchestrator.
#
# ROLLBACK (D5 — instant, symlink repoint, NO rebuild).  Machine contract here is
# the TARGET_BUILD= line + the typed exits, NOT BPSTAGE (rollback is not a deploy):
#   --rollback-preflight  read-only: is a rollback possible right now?  Typed
#                         exits (21 no_previous, 22 not_supported, 23 lock held);
#                         exit 0 prints TARGET_BUILD= (machine-parsed by the CLI).
#   --rollback            repoint `current` to the previous release dir in
#                         sub-second; a second --rollback flips forward again.
#
# --self-test  fixture release dirs in a tmpdir PROVE the symlink flip + retire-N
#              + rollback primitives and the marker reader; then the REAL script
#              is driven end-to-end as a subprocess against a fake npm/flock,
#              proving the stage protocol, the content-truth HEALTH gate and the
#              poison purge.  No caddy/systemd/network, so the gate
#              (`bash deploy/site-deploy.sh --self-test`) runs anywhere.
#
# TYPED EXIT CODES:
#    0 success / no-op        11 missing required input
#    2 usage                  12 BUILD failed
#   10 missing site dir       13 STAGE failed (no dist/)
#   14 HEALTH failed          15 gave up waiting for lock
#   16 SWITCH failed          21 rollback: no_previous
#   22 rollback: not_supported  23 rollback: lock held (deploy running)
#   24 rollback failed         25 teardown: route still live (disarm rejected)
#
# TEARDOWN machine contract (no BPSTAGE — a teardown is not a deploy):
#   exit 0  prints TORN_DOWN=<slug> on stdout AND appends it to
#           $BARKPARK_SITE_LOG_FILE — the route is gone and the tree is deleted.
#   exit 25 prints TEARDOWN_FAILED=<slug> detail="…" on the SAME two channels and
#           NEVER TORN_DOWN=: the Caddy route survived (the disarm was rejected and
#           reverted), so the release tree is deliberately LEFT ON DISK.
#
# Env inputs (a caller — bp cloud site deploy — injects these):
#   SITE_SLUG          required. Names releases root + the /sites/<slug>/ route.
#   BUILD_ID           required (deploy). hash(code_rev+content_rev+config).
#   SITE_SRC           source dir to build (npm ci/run build → dist/).
#                      Default: <site-root>/src
#   BARKPARK_SITES_DIR base dir for site roots. Default /opt/barkpark/sites
#   BARKPARK_API_URL / BARKPARK_TOKEN / BARKPARK_DATASET /
#   BARKPARK_WORKSPACE / BARKPARK_PROJECT   the ONLY vars passed into BUILD.
#   CONTENT_REV        dataset revision read at build (baked as bp-content-rev).
#   BARKPARK_CADDYFILE Caddyfile to arm. Default /etc/caddy/Caddyfile
#   BARKPARK_HEALTH_HOST  live FQDN (for logging). Default guerrilla.barkpark.cloud
set -uo pipefail

SELF="${BASH_SOURCE[0]}"   # --self-test re-executes THIS script as the subject

# Shared primitives (charter D61): emit/BPSTAGE, valid_slug/valid_build_id,
# meta_value, BUILD_ALLOW, setup_caddy_lock/with_caddy_lock, log. site-deploy-node.sh
# sources the SAME file so neither engine drifts on the wire protocol or the lock.
# shellcheck source=deploy/lib/site-deploy-common.sh
. "$(cd "$(dirname "$SELF")" && pwd)/lib/site-deploy-common.sh"

# ---- Config ----------------------------------------------------------------
SITES_DIR="${BARKPARK_SITES_DIR:-/opt/barkpark/sites}"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
HEALTH_HOST="${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}"
RETAIN="${BARKPARK_SITE_RETAIN:-5}"
# BUILD_ALLOW (the Vite process.env-precedence scrub, D7) lives in the common lib.
# Dropped INSIDE a release dir whose bytes failed HEALTH but which we must not
# delete (it is the live or the rollback target).  PLAN refuses to re-gate a
# release carrying it — it rebuilds instead.  See purge_failed_release.
HEALTH_FAIL_MARK=".bp-health-failed"
# log() and emit() (the BPSTAGE machine protocol) live in the common lib.

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
# Portable ATOMIC symlink swap.  BSD mv (macOS) and GNU mv WITHOUT -T both
# FOLLOW a symlink-to-directory destination and move the temp link INSIDE it
# instead of replacing it (proven on darwin).  perl's rename() calls rename(2)
# directly — it renames the link itself over the destination link atomically and
# is present on every macOS/Linux box.  GNU `mv -T` is the fallback; a last-ditch
# rm+mv (BSD, sub-ms non-atomic gap) keeps the flip working on a perl-less box.
# ---------------------------------------------------------------------------
atomic_symlink_swap() { # <tmp-link> <dest-link>
  if command -v perl >/dev/null 2>&1; then
    perl -e 'rename($ARGV[0],$ARGV[1]) or die "rename: $!"' "$1" "$2"
  elif mv --version >/dev/null 2>&1; then
    mv -Tf "$1" "$2"
  else
    rm -f "$2" && mv "$1" "$2"
  fi
}

# ---------------------------------------------------------------------------
# The four pure state-machine primitives operate on globals ROOT / RELEASES /
# CURRENT / BUILD_ID so --self-test can exercise the SAME code the deploy path
# runs (no fixture fork — the test proves the real primitives).
# ---------------------------------------------------------------------------

# SWITCH: atomic current -> releases/<BUILD_ID>.  Records the build we flip away
# from in .previous so --rollback (and a forward re-rollback) is a pure pointer.
do_switch() {
  local prev=""
  [ -L "$CURRENT" ] && prev="$(basename "$(readlink "$CURRENT")")"
  ln -sfn "releases/$BUILD_ID" "$CURRENT.tmp" || return 1
  atomic_symlink_swap "$CURRENT.tmp" "$CURRENT" || { rm -f "$CURRENT.tmp"; return 1; }
  if [ -n "$prev" ] && [ "$prev" != "$BUILD_ID" ]; then echo "$prev" > "$ROOT/.previous"; fi
  return 0
}

# RETIRE: keep the newest RETAIN release dirs (mtime), remove older — but NEVER
# the live target or the .previous rollback target.  RETIRED counts what it
# actually removed, so the RETIRE stage line is honest when the answer is zero
# (the common case — and the one that used to print nothing at all).
RETIRED=0
do_retire() {
  RETIRED=0
  [ -d "$RELEASES" ] || return 0
  local livecur="" prev="" d id i=0
  [ -L "$CURRENT" ] && livecur="$(basename "$(readlink "$CURRENT")")"
  [ -f "$ROOT/.previous" ] && prev="$(cat "$ROOT/.previous")"
  # ls -1dt: newest-first by mtime.  Trailing slash restricts to directories.
  # A process substitution (never a pipe) — the loop must run in THIS shell or
  # the RETIRED count would die with a subshell.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    id="$(basename "$d")"
    i=$((i + 1))
    [ "$i" -le "$RETAIN" ] && continue
    [ "$id" = "$livecur" ] && continue
    [ "$id" = "$prev" ] && continue
    if rm -rf "$d"; then RETIRED=$((RETIRED + 1)); log "RETIRE: removed old release $id"; fi
  done < <(ls -1dt "$RELEASES"/*/ 2>/dev/null)
}

# ROLLBACK: repoint current to the .previous release (sub-second, no rebuild).
# Typed returns: 21 no_previous, 22 not_supported, 24 flip failed.
do_rollback() {
  [ -L "$CURRENT" ] || { log "rollback: no live 'current' symlink (not_supported)"; return 22; }
  [ -f "$ROOT/.previous" ] || { log "rollback: no .previous release recorded (no_previous)"; return 21; }
  local prev livenow
  prev="$(cat "$ROOT/.previous")"
  [ -n "$prev" ] || { log "rollback: empty .previous (no_previous)"; return 21; }
  [ -d "$RELEASES/$prev" ] || { log "rollback: previous release '$prev' dir is gone (no_previous)"; return 21; }
  # Rollback does NOT health-gate (that is the whole point — it is a sub-second
  # pointer flip, no rebuild).  So it must at least refuse a target the engine
  # ALREADY KNOWS is broken: a release that failed HEALTH while it was the
  # live/rollback target keeps its bytes but carries the poison marker (see
  # purge_failed_release).  Flipping onto it would put a build we proved bad in
  # front of visitors — the one thing this engine promises never to do.
  if [ -f "$RELEASES/$prev/$HEALTH_FAIL_MARK" ]; then
    log "rollback: previous release '$prev' FAILED its health gate and is marked broken — refusing to serve it (no_previous). Redeploy that build_id: PLAN will rebuild it from source."
    return 21
  fi
  livenow="$(basename "$(readlink "$CURRENT")")"
  if [ "$prev" = "$livenow" ]; then log "rollback: previous == current ($prev) — nothing to do"; return 0; fi
  ln -sfn "releases/$prev" "$CURRENT.tmp" || return 24
  atomic_symlink_swap "$CURRENT.tmp" "$CURRENT" || { rm -f "$CURRENT.tmp"; return 24; }
  # A subsequent --rollback flips FORWARD again — record where we came from.
  echo "$livenow" > "$ROOT/.previous"
  log "ROLLED BACK: current -> releases/$prev (was $livenow)"
  return 0
}

# Basename of the live release, or "" if none.
live_build() { [ -L "$CURRENT" ] && basename "$(readlink "$CURRENT")" || true; }

# meta_value() — the content-truth marker reader — lives in the common lib.

# HEALTH (D11 + D26).  Serve the release exactly as a visitor would receive it —
# throwaway static server on a loopback ephemeral port — then assert on the BYTES
# WE SERVED, not on the bytes on disk:
#   * HTTP 200,
#   * bp-build-id  == the BUILD_ID this deploy ships (an artifact from another
#     build, or a marker the adapter failed to bake, is NOT this release),
#   * bp-content-rev non-empty AND == CONTENT_REV when the caller supplied one
#     (an empty content rev means the build lost its content link — it PASSED
#     the old gate and went live with it),
#   * bp-doc-id non-empty (the adapter bakes five markers; the old engine read
#     the names of two).
# Sets HEALTH_DETAIL on both paths — the reason rides the BPSTAGE line.
HEALTH_DETAIL=""
health_gate() { # 0 healthy, 1 not
  HEALTH_DETAIL=""
  local idx="$RELDIR/index.html"
  if [ ! -f "$idx" ]; then
    HEALTH_DETAIL="no index.html in releases/$BUILD_ID"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi

  local port srv=0 body code=000 i
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
  [ -n "$port" ] || port=$(( (RANDOM % 20000) + 20000 ))
  if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$RELDIR" >/dev/null 2>&1 &
    srv=$!
  elif command -v caddy >/dev/null 2>&1; then
    caddy file-server --listen "127.0.0.1:$port" --root "$RELDIR" >/dev/null 2>&1 &
    srv=$!
  else
    HEALTH_DETAIL="no python3 or caddy to run the throwaway health server — cannot gate"
    log "HEALTH: $HEALTH_DETAIL"; return 1
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/site-health.XXXXXX")"
  # Capture curl's exit + wall-time per attempt (mirrors the node engine's HEALTH
  # probe) so the non-200 detail names attempts+curl-exit+duration — the exact
  # forensic the #3518 fix added on the node side and this static branch lacked.
  local curl_rc=0 t_total="" out
  for i in $(seq 1 25); do
    out="$(curl -s -o "$body" -w '%{http_code} %{time_total}' --max-time 2 "http://127.0.0.1:$port/index.html" 2>/dev/null)"; curl_rc=$?
    code="${out%% *}"; t_total="${out##* }"; [ -n "$code" ] || code=000
    [ "$code" = 200 ] && break
    sleep 0.2
  done
  kill "$srv" 2>/dev/null || true
  wait "$srv" 2>/dev/null || true
  if [ "$code" != 200 ]; then
    rm -f "$body"
    HEALTH_DETAIL="throwaway health server on :$port returned $code (want 200) after $i attempts (last: curl exit $curl_rc, ${t_total}s) — the staged bytes will not serve; check python3/caddy is installed and the built index.html is readable"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi

  # Content-truth: the markers in the SERVED html must be the ones we ship.
  local got_build got_rev got_doc
  got_build="$(meta_value "$body" bp-build-id)"
  got_rev="$(meta_value "$body" bp-content-rev)"
  got_doc="$(meta_value "$body" bp-doc-id)"
  rm -f "$body"
  if [ "$got_build" != "$BUILD_ID" ]; then
    HEALTH_DETAIL="bp-build-id marker is '${got_build:-<missing>}' but this deploy ships '$BUILD_ID' — the served html is not this build"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -z "$got_rev" ]; then
    HEALTH_DETAIL="bp-content-rev marker is empty — the build lost its content link"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -n "${CONTENT_REV:-}" ] && [ "$got_rev" != "$CONTENT_REV" ]; then
    HEALTH_DETAIL="bp-content-rev marker is '$got_rev' but this deploy ships content_rev '$CONTENT_REV'"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -z "$got_doc" ]; then
    HEALTH_DETAIL="bp-doc-id marker is empty — the build rendered no content document"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -z "${CONTENT_REV:-}" ]; then
    log "HEALTH: no CONTENT_REV supplied — asserting bp-content-rev is non-empty only (nothing to cross-check against)"
  fi

  # Finder integrity (only when the build ships a finder — a `search-seed.json`).
  # Plain content templates have no seed and skip this entirely. Two regressions
  # that the content-truth markers above CANNOT see, but that break the finder as
  # badly as an empty corpus does, so the deploy must refuse to switch to them:
  #
  #   (a) a corrupt or wrong-shaped seed. The build bakes `initialSeed` as a
  #       ranked `SeedDoc[]` (or null when there is nothing to seed); the island
  #       turns it into its prefix index. A seed that is invalid JSON, or whose
  #       `initialSeed` is neither an array nor null, is the #4020 class — the
  #       finder throws on the first keystroke and blanks the page.
  #   (b) an island that lost its error boundary. `getDerivedStateFromError` is
  #       the React mechanism that turns a render throw into the graceful
  #       fallback instead of a blank page (#4047). It survives minification (a
  #       static method React looks up by name), so its ABSENCE means the safety
  #       net regressed — ship that and any future render throw blanks the page.
  local seed="$RELDIR/search-seed.json"
  if [ -f "$seed" ]; then
    local seed_shape
    seed_shape="$(python3 - "$seed" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("BADJSON"); raise SystemExit
s = d.get("initialSeed")
print("OK" if (s is None or isinstance(s, list)) else "BADSHAPE")
PY
)"
    if [ "$seed_shape" = BADJSON ]; then
      HEALTH_DETAIL="search-seed.json is not valid JSON — the finder seed is corrupt"
      log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
    fi
    if [ "$seed_shape" = BADSHAPE ]; then
      HEALTH_DETAIL="search-seed.json initialSeed is neither an array nor null — the finder would throw on the first keystroke (the #4020 class)"
      log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
    fi
    # shellcheck disable=SC2012  # first island bundle by name; release dir is ours
    local island
    island="$(ls "$RELDIR"/_astro/FinderIsland*.js 2>/dev/null | head -1)"
    if [ -n "$island" ] && ! grep -q 'getDerivedStateFromError' "$island"; then
      HEALTH_DETAIL="the finder island lost its error boundary — a render throw would blank the page (regressed #4047)"
      log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
    fi
    log "HEALTH: finder integrity OK — seed shape ${seed_shape:-<none>}, error boundary $([ -n "$island" ] && echo present || echo 'n/a (no island bundle)')"
  fi

  HEALTH_DETAIL="200 + bp-build-id=$got_build bp-content-rev=$got_rev bp-doc-id=$got_doc"
  log "HEALTH: $HEALTH_DETAIL (build $BUILD_ID)"
  return 0
}

# A HEALTH-failed release must NEVER stay staged (D26).  PLAN's SKIP_BUILD test
# is "the dir exists and has an index.html" — which a broken release satisfies —
# so leaving it behind POISONED the build_id: every retry re-gated the same
# broken bytes and failed 14 forever, with no way back short of a manual rm.
# Purge it.  The one exception is a release that is ALSO the live or the
# .previous rollback target (a re-gate of an already-staged build): deleting
# those bytes would destroy the rollback path, so we keep them and drop a poison
# marker PLAN refuses instead.  Either way the next deploy of this build_id
# REBUILDS from source.
purge_failed_release() {
  local livecur="" prev=""
  [ -L "$CURRENT" ] && livecur="$(basename "$(readlink "$CURRENT")")"
  [ -f "$ROOT/.previous" ] && prev="$(cat "$ROOT/.previous" 2>/dev/null || true)"
  if [ -d "$RELDIR" ] && { [ "$BUILD_ID" = "$livecur" ] || [ "$BUILD_ID" = "$prev" ]; }; then
    : > "$RELDIR/$HEALTH_FAIL_MARK" 2>/dev/null || true
    log "HEALTH: release $BUILD_ID is the live/rollback target — keeping its bytes, marking it health-failed (a redeploy REBUILDS it, never re-gates it)"
    return 0
  fi
  rm -rf "$RELDIR"
  log "HEALTH: purged releases/$BUILD_ID — a redeploy of this build_id rebuilds from source instead of re-gating broken bytes"
}

# ---------------------------------------------------------------------------
# SELF-TEST — fixtures in a tmpdir; proves the real primitives, no npm/caddy.
# ---------------------------------------------------------------------------
if [ "$MODE" = selftest ]; then
  TESTS=0; FAILS=0
  check() { # <label> <cond-cmd...>
    local label="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@"; then echo "  ok   - $label"; else echo "  FAIL - $label"; FAILS=$((FAILS + 1)); fi
  }
  TD="$(mktemp -d "${TMPDIR:-/tmp}/site-deploy-selftest.XXXXXX")"
  trap 'rm -rf "$TD"' EXIT
  ROOT="$TD/site"; RELEASES="$ROOT/releases"; CURRENT="$ROOT/current"
  mkdir -p "$RELEASES"
  # Seven fixture releases with strictly increasing mtime (b1 oldest..b7 newest).
  for n in 1 2 3 4 5 6 7; do
    mkdir -p "$RELEASES/b$n"
    printf '<meta name="bp-build-id" content="b%s">' "$n" > "$RELEASES/b$n/index.html"
    touch -t "20260713$(printf '%02d' "$n")00" "$RELEASES/b$n"
  done

  echo "[selftest] SWITCH flips the current symlink atomically"
  BUILD_ID=b1; do_switch
  check "current -> releases/b1"        [ "$(live_build)" = b1 ]
  check "current resolves to a dir"     [ -d "$CURRENT" ]
  check "current/index.html readable"   [ -f "$CURRENT/index.html" ]
  BUILD_ID=b2; do_switch
  check "current -> releases/b2"        [ "$(live_build)" = b2 ]
  check ".previous records b1"          [ "$(cat "$ROOT/.previous")" = b1 ]
  check "no current.tmp residue"        [ ! -e "$CURRENT.tmp" ]

  echo "[selftest] ROLLBACK repoints to the previous release, forward-rollable"
  do_rollback
  check "rollback: current -> b1"       [ "$(live_build)" = b1 ]
  check "rollback: .previous now b2"    [ "$(cat "$ROOT/.previous")" = b2 ]
  do_rollback
  check "re-rollback flips forward -> b2" [ "$(live_build)" = b2 ]

  echo "[selftest] RETIRE keeps newest N=5, protects current + previous"
  # Live=b2, previous=b1 (both OLD by mtime) — retire must still spare them.
  BUILD_ID=b7; do_switch          # current=b7, .previous=b2
  RETAIN=5; do_retire
  # Newest 5 by mtime = b3,b4,b5,b6,b7.  Plus protected current(b7,already in)
  # and previous(b2).  So b1 is the only removable one.
  check "retire removed b1"             [ ! -d "$RELEASES/b1" ]
  check "retire kept b2 (previous)"     [ -d "$RELEASES/b2" ]
  check "retire kept b3"                [ -d "$RELEASES/b3" ]
  check "retire kept b7 (current)"      [ -d "$RELEASES/b7" ]
  # shellcheck disable=SC2012  # counting fixture release dirs (known-clean names) in the self-test
  remaining="$(ls -1d "$RELEASES"/*/ 2>/dev/null | wc -l | tr -d ' ')"
  check "6 dirs remain (5 newest + protected previous)" [ "$remaining" = 6 ]

  echo "[selftest] no-op rollback when previous == current is safe"
  echo b7 > "$ROOT/.previous"; do_rollback
  check "current still b7 after no-op rollback" [ "$(live_build)" = b7 ]

  echo "[selftest] ROLLBACK refuses a previous release the engine KNOWS is broken"
  # Rollback never health-gates (it is a pointer flip, by design) — so it must
  # refuse a target already proven bad, or a build that failed HEALTH reaches
  # visitors through the back door.
  echo b3 > "$ROOT/.previous"
  : > "$RELEASES/b3/$HEALTH_FAIL_MARK"
  do_rollback; rb_rc=$?
  check "refuses a health-failed target (21 no_previous)" [ "$rb_rc" = 21 ]
  check "current unmoved (still b7)"    [ "$(live_build)" = b7 ]
  rm -f "$RELEASES/b3/$HEALTH_FAIL_MARK"
  do_rollback
  check "rolls back once the target is no longer marked" [ "$(live_build)" = b3 ]
  BUILD_ID=b7; do_switch   # restore: current=b7 for the checks below

  # -------------------------------------------------------------------------
  # meta_value — the marker READER the content-truth HEALTH gate rests on.  The
  # old gate grepped the marker NAME; every check here is about the VALUE.
  # -------------------------------------------------------------------------
  echo "[selftest] meta_value reads marker VALUES (the old gate only saw names)"
  MV="$TD/markers.html"
  {
    printf '<meta name="bp-build-id" content="abc123">\n'
    printf '<meta name=bp-content-rev content=r7>\n'
    printf "<meta content='d9' name='bp-doc-id'>\n"
    printf '<meta name="bp-doc-title" content="">\n'
  } > "$MV"
  check "double-quoted value"                [ "$(meta_value "$MV" bp-build-id)" = abc123 ]
  check "unquoted value"                     [ "$(meta_value "$MV" bp-content-rev)" = r7 ]
  check "single-quoted, reversed attr order" [ "$(meta_value "$MV" bp-doc-id)" = d9 ]
  check "EMPTY content reads as empty"       [ -z "$(meta_value "$MV" bp-doc-title)" ]
  check "absent marker reads as empty"       [ -z "$(meta_value "$MV" bp-site-base)" ]
  # Minified: EVERY marker must read its OWN value.  Asserting only the last tag
  # here would have missed a real bug — a character-mapping split that left the
  # tags on one line and gave every marker the LAST tag's content.
  printf '<meta name="bp-build-id" content="x1"><meta name="bp-content-rev" content="x2"><meta name="bp-doc-id" content="x3">' > "$MV"
  check "minified: first marker"             [ "$(meta_value "$MV" bp-build-id)" = x1 ]
  check "minified: middle marker"            [ "$(meta_value "$MV" bp-content-rev)" = x2 ]
  check "minified: last marker"              [ "$(meta_value "$MV" bp-doc-id)" = x3 ]

  # -------------------------------------------------------------------------
  # TEARDOWN — --teardown excises ONLY this slug's marker-guarded Caddy block
  # (leaving neighbours + the slot proxy untouched) and deletes its release tree.
  # Fake caddy/systemctl (validate + reload always OK); real disarm awk + rm.
  # -------------------------------------------------------------------------
  echo "[selftest] --teardown removes ONE site's Caddy block + release tree, spares neighbours"
  TB="$TD/teardown"; mkdir -p "$TB/bin" "$TB/sites/gone/releases/b1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TB/bin/caddy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TB/bin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TB/bin/flock"
  chmod +x "$TB/bin/"*
  ln -sfn releases/b1 "$TB/sites/gone/current"
  cat > "$TB/Caddyfile" <<'TCF'
example.com {
	# BARKPARK_SITE_ROUTE:keep — static site 'keep'.
	handle_path /sites/keep/* {
		root * /x/keep/current
		file_server
	}
	# BARKPARK_SITE_ROUTE:gone — static site 'gone'.
	handle_path /sites/gone/* {
		root * /x/gone/current
		file_server
	}
	reverse_proxy localhost:4000
}
TCF
  absent() { ! grep -q "$1" "$2"; }
  env PATH="$TB/bin:$PATH" SITE_SLUG=gone BARKPARK_SITES_DIR="$TB/sites" \
    BARKPARK_CADDYFILE="$TB/Caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$TB/lock" \
    BARKPARK_CADDYFILE_LOCK="$TB/cflock" \
    bash "$SELF" --teardown > "$TB/out" 2>&1; tdrc=$?
  check "teardown exit 0"                        [ "$tdrc" = 0 ]
  check "teardown printed TORN_DOWN=gone"        grep -q '^TORN_DOWN=gone' "$TB/out"
  check "teardown deleted the release tree"      [ ! -d "$TB/sites/gone" ]
  check "teardown removed the 'gone' Caddy block" absent 'BARKPARK_SITE_ROUTE:gone' "$TB/Caddyfile"
  check "teardown removed gone's handle_path"    absent '/sites/gone/\*' "$TB/Caddyfile"
  check "teardown KEPT the neighbour 'keep'"     grep -q 'BARKPARK_SITE_ROUTE:keep' "$TB/Caddyfile"
  check "teardown KEPT the slot reverse_proxy"   grep -q 'reverse_proxy localhost:4000' "$TB/Caddyfile"
  check "teardown left the Caddyfile brace-balanced" \
    bash -c "[ \$(grep -c '{' '$TB/Caddyfile') = \$(grep -c '}' '$TB/Caddyfile') ]"
  echo "[selftest] --teardown is idempotent (a second run finds nothing to do)"
  env PATH="$TB/bin:$PATH" SITE_SLUG=gone BARKPARK_SITES_DIR="$TB/sites" \
    BARKPARK_CADDYFILE="$TB/Caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$TB/lock" \
    BARKPARK_CADDYFILE_LOCK="$TB/cflock" \
    bash "$SELF" --teardown > "$TB/out2" 2>&1; tdrc2=$?
  check "second teardown still exit 0 (idempotent)" [ "$tdrc2" = 0 ]

  # -------------------------------------------------------------------------
  # TEARDOWN, REJECTED (D77) — the ONE case the fake caddy above (validate always
  # exits 0) structurally cannot reach. With a `caddy validate` that REJECTS, the
  # disarm reverts and the route KEEPS SERVING: the engine must NOT print
  # TORN_DOWN= (the only marker the CP reads — its presence alone is exit 0), must
  # exit 25, and must LEAVE THE RELEASE TREE ON DISK (a half-disarmed site with
  # its bytes is recoverable). On origin/main this case fails on every assertion:
  # exit 0, TORN_DOWN= on both channels, tree deleted.
  # -------------------------------------------------------------------------
  echo "[selftest] --teardown REFUSES to claim TORN_DOWN when caddy validate rejects the disarm (D77)"
  TR="$TD/teardown-reject"; mkdir -p "$TR/bin" "$TR/sites/stuck/releases/b1"
  # The rejecting fake: validate says no, everything else is fine.
  printf '#!/usr/bin/env bash\ncase "$1" in validate) exit 1;; *) exit 0;; esac\n' > "$TR/bin/caddy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/flock"
  chmod +x "$TR/bin/"*
  ln -sfn releases/b1 "$TR/sites/stuck/current"
  cat > "$TR/Caddyfile" <<'RCF'
example.com {
	# BARKPARK_SITE_ROUTE:stuck — static site 'stuck'.
	handle_path /sites/stuck/* {
		root * /x/stuck/current
		file_server
	}
	reverse_proxy localhost:4000
}
RCF
  env PATH="$TR/bin:$PATH" SITE_SLUG=stuck BARKPARK_SITES_DIR="$TR/sites" \
    BARKPARK_CADDYFILE="$TR/Caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$TR/lock" \
    BARKPARK_CADDYFILE_LOCK="$TR/cflock" BARKPARK_SITE_LOG_FILE="$TR/log" \
    bash "$SELF" --teardown > "$TR/out" 2>&1; tdrc3=$?
  check "rejected teardown exits 25 (not 0)"        [ "$tdrc3" = 25 ]
  check "rejected teardown printed NO TORN_DOWN= on stdout" \
    absent 'TORN_DOWN=' "$TR/out"
  check "rejected teardown logged NO TORN_DOWN= to the durable log" \
    absent 'TORN_DOWN=' "$TR/log"
  check "rejected teardown printed the typed failure on stdout" \
    grep -q '^TEARDOWN_FAILED=stuck detail="' "$TR/out"
  check "rejected teardown logged the typed failure durably" \
    grep -q '^TEARDOWN_FAILED=stuck detail="' "$TR/log"
  check "rejected teardown KEPT the release tree (recoverable)" [ -d "$TR/sites/stuck/releases/b1" ]
  check "rejected teardown KEPT the live route (reverted, still serving)" \
    grep -q 'BARKPARK_SITE_ROUTE:stuck' "$TR/Caddyfile"
  check "rejected teardown left the Caddyfile brace-balanced" \
    bash -c "[ \$(grep -c '{' '$TR/Caddyfile') = \$(grep -c '}' '$TR/Caddyfile') ]"
  # …and it says the route is STILL LIVE, because this run WATCHED it survive.
  check "rejected teardown claims a MEASURED still-live route" \
    grep -q 'STILL LIVE' "$TR/out"
  check "rejected teardown does NOT hedge — it made the measurement" \
    absent 'NEVER CHECKED' "$TR/out"

  # -------------------------------------------------------------------------
  # TEARDOWN, LOCK NEVER TAKEN (D77) — the OTHER non-zero from with_caddy_lock,
  # and a DIFFERENT claim. Nothing read the Caddyfile, so "the route is still
  # live" would be an assertion this run never made. Same refusal (no TORN_DOWN=,
  # exit 25, tree kept) but the operator is told the state is UNKNOWN.
  # -------------------------------------------------------------------------
  echo "[selftest] --teardown says UNKNOWN, not 'still live', when the Caddyfile lock was never taken (D77)"
  TL="$TD/teardown-lock"; mkdir -p "$TL/bin" "$TL/sites/stuck/releases/b1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TL/bin/caddy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TL/bin/systemctl"
  # THE fixture: a flock that grants the non-blocking DEPLOY lock (`flock -n 9`,
  # whose own refusal is the separate exit 23) but never the WAITING Caddyfile lock
  # (`flock -w 120 8`). with_caddy_lock then returns 1 out of its own guard and
  # disarm_caddy_site_route is never even entered — which is exactly the state in
  # which "the route is still live" would be an unmade measurement.
  printf '#!/usr/bin/env bash\ncase "$1" in -w) exit 1;; *) exit 0;; esac\n' > "$TL/bin/flock"
  chmod +x "$TL/bin/"*
  cp "$TR/Caddyfile" "$TL/Caddyfile"
  env PATH="$TL/bin:$PATH" SITE_SLUG=stuck BARKPARK_SITES_DIR="$TL/sites" \
    BARKPARK_CADDYFILE="$TL/Caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$TL/lock" \
    BARKPARK_CADDYFILE_LOCK="$TL/cflock" BARKPARK_SITE_LOG_FILE="$TL/log" \
    bash "$SELF" --teardown > "$TL/out" 2>&1; tdrc4=$?
  check "lock-starved teardown exits 25 (not 0)"    [ "$tdrc4" = 25 ]
  check "lock-starved teardown printed NO TORN_DOWN=" absent 'TORN_DOWN=' "$TL/out"
  check "lock-starved teardown logged NO TORN_DOWN=" absent 'TORN_DOWN=' "$TL/log"
  check "lock-starved teardown printed the typed failure" \
    grep -q '^TEARDOWN_FAILED=stuck detail="' "$TL/out"
  check "lock-starved teardown says the route was NEVER CHECKED" \
    grep -q 'NEVER CHECKED' "$TL/out"
  check "lock-starved teardown does NOT claim a still-live route it never read" \
    absent 'STILL LIVE' "$TL/out"
  check "lock-starved teardown KEPT the release tree" [ -d "$TL/sites/stuck/releases/b1" ]
  check "lock-starved teardown left the Caddyfile byte-identical" \
    cmp -s "$TR/Caddyfile" "$TL/Caddyfile"

  # -------------------------------------------------------------------------
  # HEALTH finder integrity — the gate must refuse a finder build whose seed is
  # corrupt (the #4020 class) or whose island lost its error boundary (#4047),
  # while leaving plain (seedless) templates untouched. Drives the REAL
  # health_gate against hand-built release dirs (needs the throwaway server).
  # -------------------------------------------------------------------------
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "[selftest] SKIP HEALTH finder integrity — needs python3 + curl"
  else
    echo "[selftest] HEALTH refuses a corrupt seed / a boundary-less island; spares seedless sites"
    mkrel() { # <dir> <seed|none> <island-js|none>
      local d="$1"; mkdir -p "$d/_astro"
      printf '<meta name="bp-build-id" content="fb"><meta name="bp-content-rev" content="fr"><meta name="bp-doc-id" content="fd">' > "$d/index.html"
      [ "$2" != none ] && printf '%s' "$2" > "$d/search-seed.json"
      [ "$3" != none ] && printf '%s' "$3" > "$d/_astro/FinderIsland.abc123.js"
      return 0
    }
    gate() { RELDIR="$1"; BUILD_ID=fb; CONTENT_REV=fr; health_gate >/dev/null 2>&1; }
    not() { ! "$@"; }
    ISL_OK='class E{static getDerivedStateFromError(e){return{error:e}}}'
    ISL_BAD='var x=1;/* no boundary here */'
    SEED_OK='{"initialData":null,"initialSeed":[{"id":"a","title":"A","slug":"a","type":"paper"}]}'
    SEED_NULL='{"initialData":null,"initialSeed":null}'
    SEED_OBJ='{"initialData":null,"initialSeed":{"index":{},"docs":[]}}'
    SEED_BADJSON='not json {'
    mkrel "$TD/h_good"    "$SEED_OK"      "$ISL_OK";  check "finder OK (array seed + boundary) passes"       gate "$TD/h_good"
    mkrel "$TD/h_null"    "$SEED_NULL"    "$ISL_OK";  check "null seed (empty corpus) passes"                gate "$TD/h_null"
    mkrel "$TD/h_obj"     "$SEED_OBJ"     "$ISL_OK";  check "object-shaped seed (the #4020 class) FAILS"     not gate "$TD/h_obj"
    mkrel "$TD/h_badjson" "$SEED_BADJSON" "$ISL_OK";  check "corrupt-JSON seed FAILS"                        not gate "$TD/h_badjson"
    mkrel "$TD/h_noeb"    "$SEED_OK"      "$ISL_BAD"; check "island without error boundary (#4047) FAILS"    not gate "$TD/h_noeb"
    mkrel "$TD/h_plain"   none            none;       check "seedless plain template passes (finder n/a)"    gate "$TD/h_plain"
  fi

  # -------------------------------------------------------------------------
  # ENGINE E2E — drive the REAL script as a subprocess against a fake npm/flock.
  # This is what proves the stage protocol, the content-truth HEALTH gate and
  # the poison purge on the paths that actually ship (the primitives above only
  # prove the flip).  flock(1) and systemd-run do not exist on macOS: the lock
  # is stubbed (serialization is not what these cases prove) and the cap is
  # disabled via the engine's own BARKPARK_SITE_NO_CAP knob.  The throwaway
  # health server needs python3; without it the block skips honestly.
  # -------------------------------------------------------------------------
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "[selftest] SKIP engine e2e — needs python3 + curl (the throwaway health server)"
  else
    E2E="$TD/e2e"; FAKEBIN="$E2E/bin"; SRC="$E2E/src"
    mkdir -p "$FAKEBIN" "$SRC"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/flock"
    # Fake npm.  It sees ONLY the scrubbed env the engine injects (that is the
    # point of the scrub), so the lie/fail switches ride in FILES in the source
    # dir — cwd is the one channel a scrub cannot close.
    cat > "$FAKEBIN/npm" <<'FAKENPM'
#!/usr/bin/env bash
echo "npm $*" >> ./.npm-calls
[ "${1:-}" = ci ] && exit 0
# Slow-build fixture (the re-attach case): emit a couple of RAW output lines the
# durable log must capture, record THIS process's own pid (correct here — a real
# subprocess, not a backgrounded function, so $$ is us), then exec into a long
# sleep so the build is still in flight when the caller kills the top-level engine.
if [ -f ./.slow-build ]; then
  echo "building the site (slow-build fixture)"
  echo "compiling modules..."
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
bid="${BARKPARK_BUILD_ID:-}"; rev="${BARKPARK_CONTENT_REV:-}"; doc="doc-42"
# The exact build that WENT LIVE on guerrilla: a wrong build id and an EMPTY
# content rev, both of which the old name-only gate waved through.
[ -f ./.lie ] && { bid=TOTALLY-WRONG; rev=""; }
mkdir -p dist
{
  printf '<!doctype html><html><head>\n'
  printf '<meta name="bp-build-id" content="%s">\n' "$bid"
  printf '<meta name="bp-content-rev" content="%s">\n' "$rev"
  printf '<meta name="bp-doc-id" content="%s">\n' "$doc"
  printf '</head><body><h1>hello</h1></body></html>\n'
} > dist/index.html
exit 0
FAKENPM
    chmod +x "$FAKEBIN"/*
    printf '{"name":"selftest-site","private":true}\n' > "$SRC/package.json"
    E2E_SITE="$E2E/sites/selftest"

    e2e_deploy() { # <build_id> -> exit code; stdout at $E2E/out.log, stderr at $E2E/err.log
      env PATH="$FAKEBIN:$PATH" \
        SITE_SLUG=selftest BUILD_ID="$1" CONTENT_REV="${E2E_REV:-rev-1}" \
        SITE_SRC="$SRC" \
        BARKPARK_SITES_DIR="$E2E/sites" \
        BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$E2E/deploy.lock" \
        BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$E2E/out.log" 2> "$E2E/err.log"
      echo $?
    }
    # The stage protocol is a STDOUT contract — assert against stdout alone.
    saw()   { grep -q "^BPSTAGE name=$1 status=$2 build_id=$3" "$E2E/out.log"; }
    nosaw() { ! grep -q "^BPSTAGE name=$1 " "$E2E/out.log"; }
    livenow() { readlink "$E2E_SITE/current" 2>/dev/null || true; }

    echo "[selftest] e2e: a full deploy walks all six stages"
    rc="$(e2e_deploy e1)"
    check "full deploy exit 0"                 [ "$rc" = 0 ]
    check "PLAN started"                       saw PLAN started e1
    check "PLAN ok"                            saw PLAN ok e1
    check "BUILD started"                      saw BUILD started e1
    check "BUILD ok"                           saw BUILD ok e1
    check "STAGE ok"                           saw STAGE ok e1
    check "HEALTH started"                     saw HEALTH started e1
    check "HEALTH ok"                          saw HEALTH ok e1
    check "SWITCH ok"                          saw SWITCH ok e1
    check "RETIRE ok (a retire that removes NOTHING still speaks)" saw RETIRE ok e1
    check "current -> releases/e1"             [ "$(livenow)" = releases/e1 ]
    check "npm really ran"                     grep -q 'npm run build' "$SRC/.npm-calls"

    echo "[selftest] e2e: a no-op redeploy of the live build speaks on every stage"
    : > "$SRC/.npm-calls"
    rc="$(e2e_deploy e1)"
    check "no-op exit 0"                       [ "$rc" = 0 ]
    check "PLAN noop"                          saw PLAN noop e1
    check "no-op: BUILD skipped"               saw BUILD skipped e1
    check "no-op: STAGE skipped"               saw STAGE skipped e1
    check "no-op: HEALTH skipped"              saw HEALTH skipped e1
    check "no-op: SWITCH skipped"              saw SWITCH skipped e1
    check "no-op: RETIRE skipped"              saw RETIRE skipped e1
    check "no-op built nothing"                [ ! -s "$SRC/.npm-calls" ]

    echo "[selftest] e2e: a SKIP_BUILD redeploy says BUILD/STAGE skipped and still HEALTH-gates"
    rc="$(e2e_deploy e2)"
    check "e2 deploy exit 0"                   [ "$rc" = 0 ]
    : > "$SRC/.npm-calls"
    rc="$(e2e_deploy e1)"                      # e1 is staged but not live
    check "skip-build exit 0"                  [ "$rc" = 0 ]
    check "BUILD skipped"                      saw BUILD skipped e1
    check "STAGE skipped"                      saw STAGE skipped e1
    check "still HEALTH-gated"                 saw HEALTH ok e1
    check "switched to the staged release"     saw SWITCH ok e1
    check "skip-build ran no npm"              [ ! -s "$SRC/.npm-calls" ]
    check "current -> releases/e1"             [ "$(livenow)" = releases/e1 ]

    echo "[selftest] e2e: a LYING build fails HEALTH (14), never switches, is PURGED"
    : > "$SRC/.lie"
    rc="$(e2e_deploy e3)"
    rm -f "$SRC/.lie"
    check "lying build exit 14"                [ "$rc" = 14 ]
    check "HEALTH failed"                      saw HEALTH failed e3
    check "the reason names the wrong marker value" grep -q 'bp-build-id marker is .TOTALLY-WRONG' "$E2E/out.log"
    # Dual-channel: the reason must ride the plain human log too, NOT only the
    # BPSTAGE detail=. On a TERMINAL failure the run-level reason_tail (last 3 log
    # lines) WINS over stage.detail at the verdict line, so a detail-only hint is
    # shadowed — the log line is the copy that survives to the user.
    check "the HEALTH reason ALSO rides the plain human log (dual-channel)" \
      grep -q '\[site-deploy .*HEALTH: bp-build-id marker is .TOTALLY-WRONG' "$E2E/out.log"
    check "no SWITCH stage line at all"        nosaw SWITCH
    check "current did NOT move (still e1)"    [ "$(livenow)" = releases/e1 ]
    check "the poisoned release is purged"     [ ! -d "$E2E_SITE/releases/e3" ]

    echo "[selftest] e2e: redeploying the SAME build_id after a health failure REBUILDS"
    : > "$SRC/.npm-calls"
    rc="$(e2e_deploy e3)"
    check "retry exit 0"                       [ "$rc" = 0 ]
    check "retry REBUILT (npm ran again)"      grep -q 'npm run build' "$SRC/.npm-calls"
    check "retry BUILD ok"                     saw BUILD ok e3
    check "retry went live"                    [ "$(livenow)" = releases/e3 ]

    echo "[selftest] e2e: a health-failed ROLLBACK TARGET keeps its bytes but is never re-gated"
    # current=e3, .previous=e1.  Corrupt e1's staged bytes: purging them would
    # destroy the rollback path, so the engine must mark, not delete.
    perl -pi -e 's/content="e1"/content="WRONG"/' "$E2E_SITE/releases/e1/index.html"
    : > "$SRC/.npm-calls"
    rc="$(e2e_deploy e1)"
    check "corrupted rollback target: exit 14" [ "$rc" = 14 ]
    check "its bytes are KEPT (rollback stays possible)" [ -d "$E2E_SITE/releases/e1" ]
    check "it is marked health-failed"         [ -f "$E2E_SITE/releases/e1/.bp-health-failed" ]
    check "current unmoved (still e3)"         [ "$(livenow)" = releases/e3 ]
    check "that run re-gated staged bytes (no npm)" [ ! -s "$SRC/.npm-calls" ]
    : > "$SRC/.npm-calls"
    rc="$(e2e_deploy e1)"
    check "the marked release REBUILDS on redeploy" grep -q 'npm run build' "$SRC/.npm-calls"
    check "rebuilt rollback target goes live"  [ "$rc" = 0 ]
    check "poison marker cleared by the rebuild" [ ! -f "$E2E_SITE/releases/e1/.bp-health-failed" ]

    echo "[selftest] e2e: a BUILD failure carries the REAL reason on STDOUT"
    : > "$SRC/.fail-build"
    rc="$(e2e_deploy e4)"
    rm -f "$SRC/.fail-build"
    check "build failure exit 12"              [ "$rc" = 12 ]
    check "BUILD failed"                       saw BUILD failed e4
    check "the 401 reason rides the stage line (stdout, not stderr)" \
      grep -q '^BPSTAGE name=BUILD status=failed .*401 Unauthorized' "$E2E/out.log"
    check "no SWITCH stage line at all"        nosaw SWITCH
    check "no release dir left behind"         [ ! -d "$E2E_SITE/releases/e4" ]
    check "current unmoved (still e1)"         [ "$(livenow)" = releases/e1 ]

    echo "[selftest] e2e: a preflight-shaped failure (no package.json) names the next move on BOTH channels"
    NOPKG="$E2E/nopkg"; mkdir -p "$NOPKG"
    rc="$(env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=selftest BUILD_ID=np1 CONTENT_REV=rev-1 SITE_SRC="$NOPKG" \
      BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
      BARKPARK_SITE_DEPLOY_LOCK="$E2E/deploy.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
      BARKPARK_SITE_NO_CAP=1 bash "$SELF" > "$E2E/out.log" 2> "$E2E/err.log"; echo $?)"
    check "no-package.json exit 11"            [ "$rc" = 11 ]
    check "BUILD failed"                       saw BUILD failed np1
    check "the BPSTAGE detail names the check-this-next move" \
      grep -q '^BPSTAGE name=BUILD status=failed .*check the payload points at the app dir' "$E2E/out.log"
    check "the SAME hint rides the plain human log (dual-channel, not detail-only)" \
      grep -q '\[site-deploy .*has no package.json .* check the payload' "$E2E/out.log"
    check "no release dir left behind"         [ ! -d "$E2E_SITE/releases/np1" ]
    check "current unmoved (still e1)"         [ "$(livenow)" = releases/e1 ]

    echo "[selftest] e2e: RETIRE reports what it actually removed"
    rc="$(BARKPARK_SITE_RETAIN=1 e2e_deploy e5)"
    check "retain=1 deploy exit 0"             [ "$rc" = 0 ]
    check "RETIRE names a real removal"        grep -qE '^BPSTAGE name=RETIRE status=ok build_id=e5 detail="removed [1-9]' "$E2E/out.log"

    echo "[selftest] e2e: a rollback records its outcome markers in the durable LOG"
    # systemd-mode DeployRunner finalizes a rollback from BARKPARK_SITE_LOG_FILE
    # (no exit code; a rollback emits no BPSTAGE). A rollback that leaves that log
    # empty is the "died abnormally" bug — the runner reads no success marker and
    # reports -1. Assert the flip lands its markers where the runner reads them.
    e2e_deploy e6 >/dev/null; e2e_deploy e7 >/dev/null   # current=e7, .previous=e6
    RB_LOG="$E2E/rollback.log"; : > "$RB_LOG"
    env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=selftest BARKPARK_SITES_DIR="$E2E/sites" \
      BARKPARK_CADDYFILE="$E2E/absent-caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$E2E/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" BARKPARK_SITE_NO_CAP=1 \
      BARKPARK_SITE_LOG_FILE="$RB_LOG" \
      bash "$SELF" --rollback > "$E2E/rb.out" 2>&1
    check "rollback flipped to e6"                    [ "$(livenow)" = releases/e6 ]
    check "rollback wrote ROLLED BACK to the log"     grep -q 'ROLLED BACK' "$RB_LOG"
    check "rollback wrote TARGET_BUILD=e6 to the log" grep -qx 'TARGET_BUILD=e6' "$RB_LOG"
    # A no_previous refusal writes its typed marker too (current now e6, .previous e7).
    rm -f "$E2E_SITE/.previous"; RB_LOG2="$E2E/rollback2.log"; : > "$RB_LOG2"
    env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=selftest BARKPARK_SITES_DIR="$E2E/sites" \
      BARKPARK_CADDYFILE="$E2E/absent-caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$E2E/deploy.lock" \
      BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" BARKPARK_SITE_NO_CAP=1 \
      BARKPARK_SITE_LOG_FILE="$RB_LOG2" \
      bash "$SELF" --rollback > "$E2E/rb2.out" 2>&1
    check "no_previous rollback wrote (no_previous) to the log" grep -q '(no_previous)' "$RB_LOG2"

    echo "[selftest] e2e: an ORPHANED build survives a mid-build kill (durable file contract)"
    # The re-attach contract: DeployRunner names a persistent status fold + a raw
    # build log; emit() appends every BPSTAGE line to the fold, and BUILD tees the
    # child's RAW stdout/stderr to the log. When barkpark.service restarts, the BEAM
    # parent dies but the build (in the outer transient unit) keeps running. Model
    # it: run the engine in the BACKGROUND with the two files set, wait until the
    # build is mid-flight, then kill ONLY the top-level engine pid — captured via
    # the caller's $! (never $$ inside a backgrounded function, which is the parent
    # shell's pid on bash 3.2). Assert the on-disk fold is a truthful PARTIAL and
    # the raw log survived, readable with zero live process.
    R_STATUS="$E2E/reattach.status"; R_LOG="$E2E/reattach.rawlog"
    rm -f "$R_STATUS" "$R_LOG" "$SRC/.slow-build-pid"
    : > "$SRC/.slow-build"
    env PATH="$FAKEBIN:$PATH" \
      SITE_SLUG=reattach BUILD_ID=re1 CONTENT_REV=rev-1 SITE_SRC="$SRC" \
      BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
      BARKPARK_SITE_DEPLOY_LOCK="$E2E/reattach.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
      BARKPARK_SITE_NO_CAP=1 \
      BARKPARK_SITE_STATUS_FILE="$R_STATUS" BARKPARK_SITE_LOG_FILE="$R_LOG" \
      bash "$SELF" > "$E2E/reattach.out" 2>&1 &
    R_ENGINE_PID=$!
    # Wait until the slow build is in flight (npm run build wrote its pid file).
    for _i in $(seq 1 100); do [ -f "$SRC/.slow-build-pid" ] && break; sleep 0.1; done
    # Kill ONLY the top-level engine (SIGKILL, not the process group) — the build
    # pipeline orphans and keeps running, exactly as under a service restart.
    kill -9 "$R_ENGINE_PID" 2>/dev/null || true
    wait "$R_ENGINE_PID" 2>/dev/null || true
    # Signal the orphaned build to exit (leak-proof — the reparented loop notices
    # the sentinel is gone within 0.1s), best-effort kill its pid too, then let the
    # now-EOF'd tee flush the raw log to disk before we assert on it.
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
  fi

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
# Slug hygiene: it names a filesystem dir AND a Caddy path matcher.
if ! valid_slug "$SITE_SLUG"; then
  log "invalid SITE_SLUG '$SITE_SLUG' (want ^[a-z0-9][a-z0-9-]{0,62}\$)"; exit 11
fi

ROOT="$SITES_DIR/$SITE_SLUG"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
SITE_SRC="${SITE_SRC:-$ROOT/src}"
LOCK="${BARKPARK_SITE_DEPLOY_LOCK:-/var/lock/barkpark-site-deploy-$SITE_SLUG.lock}"

# ---- Serialize per-site (queue depth 1).  A held lock means a deploy is in
# flight: another deploy queues behind it; a rollback REFUSES (racing a deploy
# would flip current mid-STAGE) with a typed 23.
if ! mkdir -p "$(dirname "$LOCK")" 2>/dev/null; then
  # Unwritable /var/lock (dev box) — fall back to a tmp lock so we still serialize.
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

mkdir -p "$RELEASES"

# ---- Rollback / preflight (D5) — pure pointer, no rebuild ------------------
if [ "$MODE" = preflight ]; then
  if [ ! -L "$CURRENT" ]; then log "no live release for '$SITE_SLUG' (not_supported)"; exit 22; fi
  if [ ! -f "$ROOT/.previous" ] || [ -z "$(cat "$ROOT/.previous" 2>/dev/null)" ]; then
    log "no previous release recorded for '$SITE_SLUG' (no_previous)"; exit 21
  fi
  prev="$(cat "$ROOT/.previous")"
  if [ ! -d "$RELEASES/$prev" ]; then log "previous release '$prev' dir is gone (no_previous)"; exit 21; fi
  log "rollback possible: would repoint current ($(live_build)) -> releases/$prev"
  echo "TARGET_BUILD=$prev"
  exit 0
fi

if [ "$MODE" = rollback ]; then
  do_rollback; rc=$?
  # systemd-mode DeployRunner finalizes a rollback from the durable LOG FILE — it
  # has no exit code (the transient unit's is swept) and a rollback emits no
  # BPSTAGE fold. A DEPLOY fills that log via BUILD's tee; a rollback has no
  # BUILD, so its stdout (below) never reaches the log and the runner reads an
  # EMPTY log → `-1` "died abnormally" even on success. Record the outcome here
  # in the exact markers `DeployRunner.rollback_outcome/1` reads: a `TARGET_BUILD=`
  # + `ROLLED BACK` success pair, or a typed `(no_previous)`/`(not_supported)`
  # refusal. Direct append (not a tee) so it is on disk before the unit exits.
  if [ -n "${BARKPARK_SITE_LOG_FILE:-}" ]; then
    case "$rc" in
      0)  printf 'ROLLED BACK: %s now at %s\nTARGET_BUILD=%s\n' \
            "$SITE_SLUG" "$(live_build)" "$(live_build)" >> "$BARKPARK_SITE_LOG_FILE" ;;
      21) printf 'rollback refused: (no_previous)\n'   >> "$BARKPARK_SITE_LOG_FILE" ;;
      22) printf 'rollback refused: (not_supported)\n' >> "$BARKPARK_SITE_LOG_FILE" ;;
      *)  printf 'rollback failed (exit %s)\n' "$rc"   >> "$BARKPARK_SITE_LOG_FILE" ;;
    esac
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  do_retire
  # Machine contract (see header): exit 0 prints TARGET_BUILD= so the CLI can name
  # the release now serving (the preflight already prints it; the real flip must too).
  echo "TARGET_BUILD=$(live_build)"
  log "ROLLED BACK — '$SITE_SLUG' now at $(live_build)"
  exit 0
fi

# ===========================================================================
# TEARDOWN (the inverse of a spawn): disarm the site's Caddy route, then delete
# its release tree — so a `bp cloud site delete` (and every live-proof) can leave
# NOTHING behind. Idempotent: a missing route or dir is not an error.
# ===========================================================================
# Remove THIS slug's marker-guarded Caddy block (the inverse of
# arm_caddy_site_route): drop every line from the `BARKPARK_SITE_ROUTE:<slug>`
# marker comment through the closing brace of the `handle[_path]` it introduces —
# which covers the static `file_server` form AND the node `@matcher`/`redir`/
# `reverse_proxy` form (all of it sits between the marker and that brace). Same
# safety as arm: backup + `caddy validate` + reload-or-revert, so a botched
# removal is REVERTED (the site stays) and never breaks the live FQDN block.
# Runs under with_caddy_lock (the caller wraps it) — the marker read + rewrite is
# a read-modify-write another writer must not interleave.
# RETURNS: 0 the route is gone (or was never armed / no caddy on this box), 2 the
# route is STILL LIVE and this run OBSERVED that (the excision was rejected or
# unwritable, and the Caddyfile was restored). The caller MUST branch on this
# (D77): a revert used to be the function's LAST `mv`, i.e. exit status 0, so "the
# site is still serving" was not representable at the function boundary and the
# teardown printed TORN_DOWN= over it.
# 2 and NOT 1 on purpose: `with_caddy_lock` returns 1 out of its OWN guards when
# the lock cannot be taken, and that is a different fact — the route was never
# LOOKED at. Collapsing the two would make this function's caller assert a
# measurement it never made, which is the whole defect class this change exists
# to remove.
disarm_caddy_site_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping /sites/$SITE_SLUG disarm"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — nothing to disarm"; return 0; }
  local marker="BARKPARK_SITE_ROUTE:$SITE_SLUG"
  grep -q "$marker" "$CADDYFILE" || { log "caddy /sites/$SITE_SLUG route not armed — nothing to disarm"; return 0; }
  local bak; bak="${CADDYFILE}.bak.teardown.${SITE_SLUG}.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # brace-counted block excision, anchored on the marker (never a global grep).
  BP_MARK="$marker" awk '
    BEGIN { m = ENVIRON["BP_MARK"] }
    !inb && index($0, m) { inb = 1; depth = 0; opened = 0; next }
    inb {
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&"); depth += o - c
      if (o > 0) opened = 1
      if (opened && depth <= 0) inb = 0
      next
    }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE" || {
    log "could not rewrite $CADDYFILE for the /sites/$SITE_SLUG disarm — restoring the backup, Caddy untouched"
    rm -f "$tmp"; mv "$bak" "$CADDYFILE"; return 2
  }
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "disarmed caddy /sites/$SITE_SLUG route"; else log "caddy reload failed (config valid) — /sites/$SITE_SLUG route drops on next reload"; fi
    rm -f "$bak"
    return 0
  else
    log "caddy validate rejected the /sites/$SITE_SLUG disarm — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
    return 2
  fi
}

# A teardown that could NOT disarm the route must never print TORN_DOWN= (D77).
# That marker is the ONLY thing DeployRunner.teardown_outcome/1 reads, and its mere
# presence IS exit 0 to the control plane — so printing it after a reverted disarm
# certifies a site that is still being served. Speak a typed failure on the SAME
# two channels the success marker uses (stdout for the CLI, $BARKPARK_SITE_LOG_FILE
# for the systemd-mode runner, which sees no exit code), and exit non-zero: with no
# TORN_DOWN= in the log the runner already folds this to -1, and BoxRelay's
# `exit_code == 0` gate then keeps the CP row instead of deleting it.
# The release tree is deliberately LEFT ON DISK — a half-disarmed site that still
# has its bytes is a live route over real files (recoverable by re-running
# --teardown once the Caddyfile is fixed); one without them is a live route over
# nothing, with no CP row left to name it.
teardown_failed() { # <detail>
  local detail="$1" line
  log "TEARDOWN FAILED — $detail"
  printf -v line 'TEARDOWN_FAILED=%s detail="%s"' "$SITE_SLUG" "$detail"
  [ -n "${BARKPARK_SITE_LOG_FILE:-}" ] && printf '%s\n' "$line" >> "$BARKPARK_SITE_LOG_FILE"
  printf '%s\n' "$line"
  exit 25
}

if [ "$MODE" = teardown ]; then
  setup_caddy_lock   # resolve CADDY_LOCK before with_caddy_lock (deploy does this later)
  # TWO different failures, and they are NOT the same claim. 2 = the disarm ran and
  # the route demonstrably survived it. 1 = with_caddy_lock's own guard fired, so
  # nothing ever read the Caddyfile and the route's state is UNKNOWN to this run.
  # Either way no TORN_DOWN=, exit 25, tree kept — but the operator is told which
  # one, because "still live" is a measurement and this run only made it in one case.
  disarm_rc=0
  with_caddy_lock disarm_caddy_site_route || disarm_rc=$?
  if [ "$disarm_rc" = 1 ]; then
    teardown_failed "the caddy /sites/$SITE_SLUG route was NEVER CHECKED — the shared Caddyfile lock could not be taken, so whether this site is still routed is UNKNOWN to this run. Nothing was removed (the release tree is kept at $ROOT); re-run --teardown once the lock is free"
  elif [ "$disarm_rc" != 0 ]; then
    teardown_failed "the caddy /sites/$SITE_SLUG route is STILL LIVE — this run tried to remove it, the change was rejected, and the Caddyfile was reverted to the serving config; the release tree is kept at $ROOT so the site still serves real bytes; fix the Caddyfile and re-run --teardown"
  fi
  if [ -d "$ROOT" ]; then
    rm -rf "$ROOT" && log "TORE DOWN — removed release tree $ROOT"
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
if ! valid_build_id "$BUILD_ID"; then
  log "invalid BUILD_ID '$BUILD_ID'"; exit 11
fi

# ---- PLAN ------------------------------------------------------------------
# Already live?  Idempotent no-op (mirrors the sites(site_id,build_id) unique
# index that makes a re-deploy of an unchanged code+content+config a no-op).
# This path used to print ONE prose line and exit 0 — no SWITCH, no HEALTHY, no
# stage words at all.  It now speaks for every stage: PLAN noop, the rest skipped.
emit PLAN started
if [ "$(live_build)" = "$BUILD_ID" ]; then
  log "PLAN: build_id $BUILD_ID is already live for '$SITE_SLUG' — nothing to do"
  emit PLAN noop "build $BUILD_ID is already live"
  for s in BUILD STAGE HEALTH SWITCH RETIRE; do emit "$s" skipped "build $BUILD_ID is already live"; done
  exit 0
fi
RELDIR="$RELEASES/$BUILD_ID"
if [ -f "$RELDIR/$HEALTH_FAIL_MARK" ]; then
  # A release we could not delete (it is the live/rollback target) but whose
  # bytes FAILED health.  Never re-gate poison — rebuild it.
  log "PLAN: release $BUILD_ID is marked health-failed — rebuilding from source (never re-gating broken bytes)"
  SKIP_BUILD=0
elif [ -d "$RELDIR" ] && [ -f "$RELDIR/index.html" ]; then
  # A previously-staged but not-live build (e.g. a rollback target): skip the
  # rebuild, re-health-gate + switch straight to it.
  log "PLAN: release $BUILD_ID already staged — re-gating, skipping BUILD/STAGE"
  SKIP_BUILD=1
else
  SKIP_BUILD=0
fi
log "PLAN: deploy '$SITE_SLUG' build $BUILD_ID (live now: $(live_build))"
if [ "$SKIP_BUILD" = 1 ]; then
  emit PLAN ok "release $BUILD_ID is already staged — BUILD and STAGE will be skipped"
else
  emit PLAN ok "building '$SITE_SLUG' build $BUILD_ID from source"
fi

# ---- BUILD -----------------------------------------------------------------
# Serialized (flock, above).  Resource-capped + env-scrubbed OUTSIDE this script
# now: DeployRunner launches the whole engine inside an outer transient systemd
# unit that carries MemoryMax/CPUQuota (slice stw6-deployrunner-reattach), and it
# hands the engine an ALREADY-SCRUBBED environment (the D7 BUILD_ALLOW contract,
# minus the ambient-shadow the caller strips).  So the build no longer self-caps
# with an inner `systemd-run --scope`, and it NO LONGER rebuilds its env from
# scratch with `env -i VAR=value` — that put BARKPARK_TOKEN=<secret> on the argv,
# a ps/proc leak proven live.  The build simply INHERITS the script's environment
# (cwd + the exported BARKPARK_* build vars below); NO secret rides any child
# argv.  cwd is inherited into the child, so we cd first.

# The most useful line of a failed build, for the BUILD failed stage line.  The
# real reason (`FATAL: 401 Unauthorized … the site read token is invalid`) used
# to go to STDERR while the generic "BUILD failed" went to stdout — a stdout-only
# orchestrator could never tell the user WHY.
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
    DETAIL="no site source dir $SITE_SRC — expected a checked-out app there; check the deploy payload's repo+ref and that the clone/checkout step actually populated it"
    log "BUILD: $DETAIL"; emit BUILD failed "$DETAIL"; exit 10
  fi
  if [ ! -f "$SITE_SRC/package.json" ]; then
    DETAIL="$SITE_SRC has no package.json — expected a Node app root; check the payload points at the app dir, not the repo root or a monorepo parent"
    log "BUILD: $DETAIL"; emit BUILD failed "$DETAIL"; exit 11
  fi

  # BUILD_ID + base path + content rev are EXPORTED under their BARKPARK_ build-var
  # names (inherited by the child, never on its argv) so the adapter can bake the
  # bp-build-id / bp-content-rev markers HEALTH asserts on.  The rest of the D7
  # BUILD_ALLOW set already rides the script's (caller-scrubbed) environment and is
  # inherited the same way — no `env -i VAR=value` reconstruction, so no secret
  # leaks onto a process argv.
  export BARKPARK_BUILD_ID="$BUILD_ID"
  export BARKPARK_SITE_BASE="/sites/$SITE_SLUG/"
  [ -n "${CONTENT_REV:-}" ] && export BARKPARK_CONTENT_REV="$CONTENT_REV"

  log "BUILD: npm ci && npm run build in $SITE_SRC (inherited scrubbed env)"
  cd "$SITE_SRC" || {
    DETAIL="cannot cd into $SITE_SRC — the dir exists but is not enterable; check its permissions/ownership (ls -ld) and that no symlink on the path is broken"
    log "BUILD: $DETAIL"; emit BUILD failed "$DETAIL"; exit 10
  }
  # No inner resource cap: the OUTER transient unit DeployRunner launches carries
  # MemoryMax/CPUQuota now (slice stw6-deployrunner-reattach).  BARKPARK_SITE_NO_CAP
  # is retained as a documented dev/selftest knob — the inner `systemd-run --scope`
  # cap is gone, so it is a no-op today, logged for clarity.
  if [ "${BARKPARK_SITE_NO_CAP:-0}" = 1 ]; then
    log "BUILD: BARKPARK_SITE_NO_CAP set — no inner cap (the outer transient unit caps in prod)"
  fi
  # The build's stdout AND stderr are merged onto OUR stdout AND tee'd to a
  # PERSISTENT log the caller (DeployRunner) names via BARKPARK_SITE_LOG_FILE, so
  # an orphaned build's RAW output survives its parent (reason_tail reads the last
  # non-BPSTAGE lines from it on re-attach).  Only BPSTAGE lines go to the status
  # fold; this file is raw child output ONLY.  When the caller names no file we
  # fall back to a mktemp (dev/selftest standalone) and delete it as before.  We
  # NEVER delete a caller-named log.  PIPESTATUS, never $?, is the build's own exit
  # code — tee always succeeds.
  if [ -n "${BARKPARK_SITE_LOG_FILE:-}" ]; then
    BUILD_LOG="$BARKPARK_SITE_LOG_FILE"; BUILD_LOG_KEEP=1
    mkdir -p "$(dirname "$BUILD_LOG")" 2>/dev/null || true
  else
    BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/site-build.XXXXXX")"; BUILD_LOG_KEEP=0
  fi
  # nice -n 19 (+ ionice idle-class when present): a site build must NEVER starve
  # the live API on a small box. Measured on guerrilla (2 cores): search engine
  # ms is ~500-600 calm but 3000-5600 while un-niced builds run — and every
  # content publish can storm several builds at once. Best-effort ionice: absent
  # on some boxes (and a no-op on non-CFQ schedulers); nice alone still yields
  # the CPU, which is the scarce resource here.
  BP_NICE="nice -n 19"
  command -v ionice >/dev/null 2>&1 && BP_NICE="nice -n 19 ionice -c3"
  NODE_ENV=production CI=1 $BP_NICE bash -euo pipefail -c 'npm ci --no-audit --no-fund && npm run build' 2>&1 | tee "$BUILD_LOG"
  build_rc="${PIPESTATUS[0]}"
  if [ "$build_rc" -ne 0 ]; then
    reason="$(build_failure_reason "$BUILD_LOG")"
    [ "$BUILD_LOG_KEEP" = 1 ] || rm -f "$BUILD_LOG"
    log "BUILD failed (exit $build_rc) for '$SITE_SLUG' build $BUILD_ID — live release untouched: $reason"
    emit BUILD failed "$reason"
    exit 12
  fi
  [ "$BUILD_LOG_KEEP" = 1 ] || rm -f "$BUILD_LOG"
  emit BUILD ok "npm ci && npm run build"

  # ---- STAGE — copy ONLY dist/ (D8) ---------------------------------------
  emit STAGE started
  if [ ! -d "$SITE_SRC/dist" ]; then
    DETAIL="build produced no dist/ — expected a static export at $SITE_SRC/dist after 'npm run build'; check the framework's output dir (astro/vite=dist) matches this static engine"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  if [ ! -f "$SITE_SRC/dist/index.html" ]; then
    DETAIL="dist/ has no index.html — expected a root document; check the build emitted a top-level index.html (a trailingSlash/base config can nest it under a subdir)"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  # Stage into a .partial dir then rename, so a crash mid-copy never leaves a
  # half-populated releases/<build_id>/ that a later PLAN mistakes for staged.
  rm -rf "$RELDIR" "$RELDIR.partial"
  mkdir -p "$RELDIR.partial"
  # cp/mv carry no forensic of their own — capture the exit code + a disk read
  # (the copy that fails on a real box almost always fails on a full /opt) so the
  # detail names the next move instead of a bare "copy failed".
  cp -a "$SITE_SRC/dist/." "$RELDIR.partial/"; cp_rc=$?
  if [ "$cp_rc" -ne 0 ]; then
    disk="$(disk_free "$RELEASES")"; rm -rf "$RELDIR.partial"
    DETAIL="copy of dist/ into releases/$BUILD_ID failed (cp exit $cp_rc; disk ${disk:-?}) — out of space or perms on the releases mount; check df and the dir ownership"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  mv "$RELDIR.partial" "$RELDIR"; mv_rc=$?
  if [ "$mv_rc" -ne 0 ]; then
    rm -rf "$RELDIR.partial"
    DETAIL="rename into releases/$BUILD_ID failed (mv exit $mv_rc) — expected an atomic move within the releases dir; check the target isn't a non-empty dir or a mountpoint, and its ownership"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  staged_size="$(du -sh "$RELDIR" 2>/dev/null | cut -f1 || echo '?')"
  log "STAGE: dist/ -> releases/$BUILD_ID/ ($staged_size)"
  emit STAGE ok "dist/ -> releases/$BUILD_ID ($staged_size)"
else
  # A SKIP_BUILD redeploy used to emit NEITHER a BUILD nor a STAGE line — the
  # second path that hung a stage-watching orchestrator forever.
  emit BUILD skipped "release $BUILD_ID is already staged"
  emit STAGE skipped "release $BUILD_ID is already staged"
fi

# ---- HEALTH (D11 + D26) — content-truth, not vacuous reachability ----------
# health_gate lives with the other state-machine primitives (above the
# self-test), so the gate the self-test proves IS the gate the deploy runs.
emit HEALTH started
if ! health_gate; then
  emit HEALTH failed "$HEALTH_DETAIL"
  log "HEALTH gate FAILED for build $BUILD_ID — live release untouched, no switch (fail closed)"
  # The failed bytes do NOT stay staged: PLAN would accept them forever and every
  # retry of this build_id would re-gate the same broken release (D26).
  purge_failed_release
  exit 14
fi
emit HEALTH ok "$HEALTH_DETAIL"

# ---- ONE shared Caddyfile lock (D27) ---------------------------------------
# setup_caddy_lock (common lib) resolves CADDY_LOCK — the single leaf lock (fd 8)
# every Caddyfile writer shares: this engine's route arming, instance-deploy.sh's
# blue/green port flip, and site-deploy-node.sh's per-site reverse_proxy port
# flip. An interleave silently DISCARDS one writer, and a lost update is
# syntactically VALID — so backup + `caddy validate` + revert is blind to it
# (reproduced: a stale write dropped instance-deploy's port flip and reloaded
# Caddy onto the slot it was about to disable — a hard 502). with_caddy_lock runs
# each read-modify-write serialized; it is a LEAF, never held across a build.
setup_caddy_lock

# ---- Arm the Caddy path handle ONCE (D4) -----------------------------------
# Marker-guarded `handle_path /sites/<slug>/*` into the live FQDN block, mirrors
# arm_caddy_mcp_route: backup + caddy validate + reload-or-revert, NEVER re-armed
# per deploy (the swap below is just a symlink flip Caddy already follows).
# Non-fatal — the release is served the moment `current` flips; the route just
# exposes it publicly, and a Caddy hiccup must not fail a healthy build.
# The WHOLE function runs under the shared lock (never just the mv): the marker
# `grep -q` below is a time-of-check read, and re-arming a route another writer
# just added — or rewriting the file from a snapshot taken before their write —
# is exactly the lost update.
arm_caddy_site_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping /sites/$SITE_SLUG route"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping /sites/$SITE_SLUG route"; return 0; }
  local marker="BARKPARK_SITE_ROUTE:$SITE_SLUG"
  if grep -q "$marker" "$CADDYFILE"; then log "caddy /sites/$SITE_SLUG route already armed"; return 0; fi
  # Anchor on the FIRST slot/site reverse_proxy so the handle lands INSIDE the
  # live FQDN site block (ahead of the fallback proxy).  Matches the guerrilla
  # blue/green slot ports 4000/4001 (same anchor arm_caddy_mcp_route uses).
  if ! grep -qE 'reverse_proxy[[:space:]]+localhost:(4000|4001)([[:space:]]|$)' "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (/sites/$SITE_SLUG not armed)"
    return 0
  fi
  local block; block="$(cat <<SITEROUTE
	# $marker — static site '$SITE_SLUG' served from its immutable current release.
	# handle_path strips the /sites/$SITE_SLUG prefix; root follows the symlink.
	handle_path /sites/$SITE_SLUG/* {
		root * $ROOT/current
		file_server
	}
SITEROUTE
)"
  local bak; bak="${CADDYFILE}.bak.site.${SITE_SLUG}.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert BEFORE the first slot reverse_proxy so /sites/<slug>/* terminates in
  # the handle ahead of the app fallback.  Slot ports only.
  BP_BLOCK="$block" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"] }
    !ins && $0 ~ /reverse_proxy[[:blank:]]+localhost:(4000|4001)([[:blank:]]|$)/ { print blk; ins=1 }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed caddy /sites/$SITE_SLUG route -> $ROOT/current"; else log "caddy reload failed (config valid) — /sites/$SITE_SLUG live on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the /sites/$SITE_SLUG route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
# Non-fatal by contract: a Caddy hiccup (or a lock we could not take) must never
# fail a healthy build — the release goes live on the symlink flip either way.
with_caddy_lock arm_caddy_site_route || true

# ---- SWITCH (D11) — atomic symlink flip, no Caddy reload -------------------
emit SWITCH started
if ! do_switch; then
  DETAIL="atomic swap of current -> releases/$BUILD_ID failed — healthy but couldn't go live; check $ROOT is writable and 'current' isn't a dir or an immutable file"
  log "SWITCH failed for build $BUILD_ID — live release untouched (fail closed): $DETAIL"
  emit SWITCH failed "$DETAIL"
  exit 16
fi
log "SWITCH: '$SITE_SLUG' current -> releases/$BUILD_ID (atomic)"
emit SWITCH ok "current -> releases/$BUILD_ID"

# ---- RETIRE (D8) — keep newest N=5 ----------------------------------------
# Emits even when it removes nothing — measured SILENT on 3 of 6 live deploys,
# the third path that hung a stage-watching orchestrator.
emit RETIRE started
do_retire
emit RETIRE ok "removed $RETIRED old release(s), keeping the newest $RETAIN"

log "HEALTHY — '$SITE_SLUG' live at build $BUILD_ID (https://$HEALTH_HOST/sites/$SITE_SLUG/)"
exit 0
