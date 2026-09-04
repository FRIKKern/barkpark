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
#          this idempotent upstream — this is the on-box mirror).  PLAN is
#          TRI-STATE (D88/D89 — the build leaves the serving box): it picks
#          PLAN_MODE=build (npm on this box), PLAN_MODE=prebuilt (bytes built
#          ELSEWHERE and uploaded — BUILD is skipped, STAGE still runs) or
#          PLAN_MODE=staged (the release dir is already there — re-gate it).
#   BUILD  npm ci && npm run build in the site source dir, wrapped in
#          `systemd-run --scope -p MemoryMax=1500M -p CPUQuota=150%` and a
#          SCRUBBED env — only the injected BARKPARK_* build vars, NOTHING
#          inherited.  Vite gives process.env precedence over .env, so an ambient
#          BARKPARK_TOKEN/URL silently shadows the per-site token (live-proven
#          failure mode) — hence the scrub.
#   STAGE  copy ONLY dist/ (12-16K) into releases/<build_id>/; node_modules
#          (~148M) stays in the ephemeral build sandbox.  In PREBUILT mode the
#          copy source is PREBUILT_DIR (the tree the box's Elixir side already
#          digest-verified and extracted) — same .partial-then-rename idiom.
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
#   * The three paths that used to be SILENT — a PLAN no-op, an already-staged
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
#   PREBUILT_DIR       optional. A tree of ALREADY-BUILT static bytes the box's
#                      Elixir side extracted from an uploaded artifact and
#                      validated (path/symlink/size refusals live there — this
#                      script never unpacks a tarball).  Set => PLAN_MODE=prebuilt:
#                      NO npm runs on this box.
#   PREBUILT_SHA256    required WITH PREBUILT_DIR. The 64-hex digest the CP
#                      verified for the uploaded artifact.  It is an IDENTITY
#                      record, not a re-hash of the tree: this script records it
#                      in releases/<build_id>/.bp-prebuilt-sha256 and compares it
#                      on a retry, so "which bytes are staged" is answerable
#                      without trusting dir-existence.
#   BARKPARK_CADDYFILE Caddyfile to arm. Default /etc/caddy/Caddyfile
#   BARKPARK_HEALTH_HOST  live FQDN (for logging). Default guerrilla.barkpark.cloud
set -uo pipefail

SELF="${BASH_SOURCE[0]}"   # --self-test re-executes THIS script as the subject

# Shared primitives (charter D61): emit/BPSTAGE, valid_slug/valid_build_id,
# meta_value, build_failure_reason, BUILD_ALLOW, setup_caddy_lock/with_caddy_lock, log. site-deploy-node.sh
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
# Dropped inside a release dir STAGED FROM UPLOADED BYTES (PLAN_MODE=prebuilt),
# carrying the digest the CP verified for that artifact.  It is the only on-box
# record of "these bytes did not come from this box's source tree", and two
# decisions read it: PLAN refuses to rebuild such a release from the provisioned
# template (that rebuild passes HEALTH on genuine markers and goes live with the
# WRONG bytes), and purge_failed_release refuses to delete it into one.
PREBUILT_MARK=".bp-prebuilt-sha256"
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
# THE ROUTE-MARKER PREDICATE (D345) — an IDENTITY, not a substring.
#
# `BARKPARK_SITE_ROUTE:<slug>` read as a bare substring is not an identity: a
# slug can be a strict PREFIX of another slug, and then every `grep -q "$marker"`
# and every awk `index($0, m)` matches the SIBLING'S block. Measured live on
# guerrilla: `search` is a prefix of `search-capstone`/`search-ember`, so the
# arm's already-armed guard kept matching the sibling and returned 0 WITHOUT
# WRITING — 208 deploys in 36h reported SWITCH ok at exit 0 while
# https://…/sites/search/ was a 404 the whole time (9 markers, 10 site dirs).
#
# `grep -qw` IS NOT THE FIX. `-w` treats `-` as a NON-word character, so
# `…ROUTE:search` still word-matches `…ROUTE:search-capstone`. What separates
# them is the DELIMITER.
#
# THE DELIMITER IS "ANY CHARACTER A SLUG CANNOT CONTAIN", NOT "WHITESPACE".
# valid_slug() is `^[a-z0-9][a-z0-9-]{0,62}$`, so a sibling slug can only ever
# continue the marker with `[a-z0-9-]` — rejecting exactly that class is what
# makes this an identity, and it is BOTH necessary and sufficient. Keying on
# whitespace alone would be sufficient for markers THIS script writes (it always
# writes `# BARKPARK_SITE_ROUTE:<slug> — …`, a space) but NOT for one a human
# hand-edited into a live Caddyfile with `:` or `#` after the slug — and there
# the failure is the DANGEROUS direction: the site reads as not-armed and gets
# re-armed, producing a DUPLICATE handle on a route that was working. This
# predicate governs the arm, the disarm and the port flip of every live site,
# so it is written to be wrong in neither direction.
#
# Safe to interpolate raw: the slug charset carries no ERE metacharacter (a `-`
# LAST in a bracket expression is literal), so the same string is a correct
# pattern for grep -E AND for awk's dynamic regex. Both engines carry this pair
# verbatim — arm, disarm, the active-port read and the port flip must all
# agree, or one of them re-opens the defect.
# ---------------------------------------------------------------------------
site_route_marker_re() { printf 'BARKPARK_SITE_ROUTE:%s([^a-z0-9-]|$)' "$SITE_SLUG"; }
has_site_route_marker() { grep -qE "$(site_route_marker_re)" "$1"; }

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

# The ONE place that decides whether a candidate rollback target is servable,
# and the ONE place that words the refusal.  --rollback and --rollback-preflight
# BOTH call it, so they can no longer disagree: preflight used to check only the
# symlink, a non-empty .previous and dir existence, so it printed TARGET_BUILD=
# and exited 0 over a release do_rollback refuses at 21 — a green preflight for a
# rollback that cannot happen.  Prebuilt releases keep their poison marker
# UNCONDITIONALLY (purge_failed_release), so that false green was the ORDINARY
# prebuilt failure path, not a corner.
# The remedy is per-arm: a box-built release can be rebuilt from source, but a
# PREBUILT one has no source on this box at all — PLAN's prebuilt path exits 11
# rather than rebuild the provisioned template, so telling the operator to
# "redeploy, PLAN will rebuild it" names a move that release does not have.
# RETURNS: 0 blocked (and logs WHY plus the actual next move), 1 servable.
rollback_target_blocked() { # <build_id>
  local prev="$1"
  [ -f "$RELEASES/$prev/$HEALTH_FAIL_MARK" ] || return 1
  if [ -f "$RELEASES/$prev/$PREBUILT_MARK" ]; then
    log "rollback: previous release '$prev' FAILED its health gate and is marked broken — refusing to serve it (no_previous). It was staged from UPLOADED prebuilt bytes and this box has no source for it: RE-UPLOAD the artifact for build '$prev' and redeploy."
  else
    log "rollback: previous release '$prev' FAILED its health gate and is marked broken — refusing to serve it (no_previous). Redeploy that build_id: PLAN will rebuild it from source."
  fi
  return 0
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
  if rollback_target_blocked "$prev"; then return 21; fi
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
  # DEEP PATH — probe ONE non-index page while the throwaway server is still up.
  # WHY: every assertion in this gate is about index.html, so a release whose
  # OTHER pages 404 (a tar that mangled an accented directory name to `caf/`, or
  # a dist whose names are NFD while its links are NFC) passed HEALTH and
  # SWITCHed live. The probe target is taken from the SERVED html's own links —
  # NEVER from a directory listing. That matters twice:
  #   * a disk-derived target is self-fulfilling (enumerate the tree, find
  #     `caf/`, ask for `caf/`, get 200 — the mangling is invisible), whereas the
  #     page's href is the INTENT a visitor's browser will actually request;
  #   * no filename is ever enumerated, so nothing depends on the shell's (or the
  #     BEAM's) filename encoding mode and nothing is word-split: python3 hands
  #     back a PERCENT-ENCODED, pure-ASCII path, and that ASCII string is the
  #     only thing this shell and curl ever touch (quoted).
  # Root-relative hrefs in a real dist carry the site base (`/sites/<slug>/`, the
  # bp-site-base marker the template bakes; the real content template emits
  # `${base}d/${doc.slug}/`), which the throwaway server — rooted at the release
  # dir — does not have: strip it, and SKIP a root-relative href that does not
  # start with it rather than manufacture a refusal. No internal link at all (a
  # single-page build) is `n/a`, never a failure.
  # RECORDED, NOT FIXED: through the real Caddy on the box EVERY miss on a static
  # site answers 503, not 404 (a plain missing ASCII path 503s too) — the cause
  # was not derived. The assertion below is "not 200", so it holds either way;
  # the 503 mystery is its own backlog row (task ssw11-bl-static-miss-503-not-404).
  # HEALTH_PY is the interpreter the two ASSERTION probes below run on — kept
  # separate from the throwaway server's python3 (which may be caddy) so a
  # broken probe interpreter cannot be mistaken for a single-page build. A
  # probe that could not run is COULD-NOT-CHECK, never OK: see deep_probe_rc.
  local HEALTH_PY="${BARKPARK_HEALTH_PY:-python3}"
  local deep="" deep_code=000 site_base="" deep_probe_rc=0
  if [ "$code" = 200 ]; then
    site_base="$(meta_value "$body" bp-site-base)"
    if ! command -v "$HEALTH_PY" >/dev/null 2>&1; then
      deep_probe_rc=127
    else
    deep="$("$HEALTH_PY" - "$body" "$site_base" <<'PY' 2>/dev/null
import re, sys, urllib.parse
html = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
base = (sys.argv[2] or "/").strip()
if not base.startswith("/"): base = "/" + base
if not base.endswith("/"): base += "/"
ATTR = r"(?:href|src)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'>]+))"
SCHEME = r"^[A-Za-z][A-Za-z0-9+.\-]*:"
cands = []
for m in re.finditer(ATTR, html, re.I):
    raw = (m.group(1) or m.group(2) or m.group(3) or "").strip()
    if not raw or raw.startswith("//"): continue
    if re.match(SCHEME, raw): continue
    p = urllib.parse.unquote(urllib.parse.urlsplit(raw).path)
    if p.startswith("./"): p = p[2:]
    if p.startswith("/"):
        if not p.startswith(base): continue
        p = p[len(base):]
    if not p or p == "index.html": continue
    if ".." in p.split("/"): continue
    cands.append(p)
if cands:
    cands.sort(key=lambda p: (p.isascii(), not (p.endswith("/") or p.endswith(".html")), len(p), p))
    print(urllib.parse.quote(cands[0], safe="/"))
PY
)" || deep_probe_rc=$?
    if [ "$deep_probe_rc" = 0 ] && [ -n "$deep" ]; then
      deep_code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/$deep" 2>/dev/null || echo 000)"
      [ -n "$deep_code" ] || deep_code=000
    fi
    fi
  fi
  kill "$srv" 2>/dev/null || true
  wait "$srv" 2>/dev/null || true
  if [ "$code" != 200 ]; then
    rm -f "$body"
    HEALTH_DETAIL="throwaway health server on :$port returned $code (want 200) after $i attempts (last: curl exit $curl_rc, ${t_total}s) — the staged bytes will not serve; check python3/caddy is installed and the built index.html is readable"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi

  # Content-truth: the markers in the SERVED html must be the ones we ship.
  local got_build got_rev got_doc got_corpus
  got_build="$(meta_value "$body" bp-build-id)"
  got_rev="$(meta_value "$body" bp-content-rev)"
  got_doc="$(meta_value "$body" bp-doc-id)"
  # bp-corpus-status (cause-truth) — the SAME marker site-deploy-node.sh reads.
  # The template emits it ONLY when it could not anchor a content document, and
  # it carries the upstream condition that stopped it ("graph 403: …",
  # "graph 401: …", "graph 200: corpus read OK but carried 0 node(s)…"). Read it
  # BEFORE the body is deleted — it is what turns the empty bp-doc-id refusal
  # below from a symptom into a diagnosis. Without it a static build could only
  # ever say "no content document", and `DeployLedger.classify/2` had nothing to
  # match but the symptom, so EVERY static corpus failure landed in the causeless
  # DOC_ID_EMPTY bucket regardless of what actually went wrong upstream.
  got_corpus="$(meta_value "$body" bp-corpus-status)"
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
    # STILL REFUSES — fail-closed on an empty bp-doc-id is correct (D72) and is
    # NOT relaxed here. What changes is legibility: when the build recorded WHY
    # it could not read its corpus, that cause rides the failure_reason, so a
    # 403 (public-read token), a 401 (no token), a wrong host and a genuinely
    # empty corpus stop collapsing into one illegible row.
    #
    # THE SENTENCE IS A CONSUMER CONTRACT. `cloud/lib/barkpark_cloud/deploy_ledger.ex`
    # reads the upstream status out of the stored failure_reason with the regex
    #   could not read a content document: graph (\d+):
    # anchored on this exact English. Reword it and every static row silently
    # degrades back to DOC_ID_EMPTY with nothing anywhere failing — so the
    # self-test asserts the anchor against these emitted bytes.
    if [ -n "$got_corpus" ]; then
      HEALTH_DETAIL="bp-doc-id marker is empty — the build could not read a content document: $got_corpus"
    else
      HEALTH_DETAIL="bp-doc-id marker is empty — the build rendered no content document (no bp-corpus-status marker: this build predates the corpus-status contract, so the upstream cause went unrecorded)"
    fi
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -z "${CONTENT_REV:-}" ]; then
    log "HEALTH: no CONTENT_REV supplied — asserting bp-content-rev is non-empty only (nothing to cross-check against)"
  fi

  # The deep-path verdict (its target was chosen above, while the server was up).
  # It is a REFUSAL, not a warning: a linked page that 404s is a 404 for visitors,
  # and switching to it ships the hole (charter D116). The reason names the link,
  # both codes, the move and the two causes — ACTION FIRST after the path, because
  # emit() clips detail= at 240 chars, so on a pathologically long path it is the
  # cause hint that degrades, never the "do not retry this artifact" move. The
  # human log line below is unclipped and always carries the whole sentence.
  #
  # The prose is kept DELIBERATELY TIGHT for that clip: at 202 fixed characters it
  # leaves 38 for the percent-encoded path, which covers a real accented slug
  # (`/d/caf%C3%A9/` is 13) — the very case this probe exists for. An earlier,
  # wordier draft cost 218 and left only 22, so the FIRST thing to truncate on the
  # BPSTAGE channel would have been the cause hint for the wave's own bug. If you
  # add words here, re-measure against emit()'s 240.
  # THREE-VALUED, not two. An empty $deep used to mean BOTH "no internal link"
  # (n/a, fine) and "the extractor never ran" (nothing was checked) — and the
  # gate printed the n/a prose for both, so a missing or crashing interpreter
  # PASSED every broken release while reading as "single-page build". A probe
  # that could not run has made no claim, and a HEALTH gate that made no claim
  # has not gated: refuse, and name the assertion that was not made.
  if [ "$deep_probe_rc" != 0 ]; then
    HEALTH_DETAIL="deep-path probe COULD-NOT-CHECK: the link extractor ($HEALTH_PY) did not run (exit $deep_probe_rc) — the deep-path assertion was NOT made, so this release is unverified, not healthy"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -n "$deep" ] && [ "$deep_code" != 200 ]; then
    HEALTH_DETAIL="index.html links to /$deep — served HTTP $deep_code, want 200. Re-pack and re-upload; do not retry this artifact. Cause: a tar dropped or mangled a non-ASCII path component, or disk names are NFD vs NFC in the href"
    log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
  fi
  if [ -n "$deep" ]; then
    log "HEALTH: deep path /$deep serves 200 from the staged tree (site base '${site_base:-/}')"
  else
    log "HEALTH: no non-index internal link in the served index.html — deep-path probe n/a (single-page build)"
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
    local seed_probe_rc=0
    if ! command -v "$HEALTH_PY" >/dev/null 2>&1; then
      seed_probe_rc=127
    else
    seed_shape="$("$HEALTH_PY" - "$seed" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("BADJSON"); raise SystemExit
s = d.get("initialSeed")
print("OK" if (s is None or isinstance(s, list)) else "BADSHAPE")
PY
)" || seed_probe_rc=$?
    fi
    # Same three-valued rule as the deep probe: an empty $seed_shape is not OK,
    # it is "the #4020 seed-shape assertion was never made".
    if [ "$seed_probe_rc" != 0 ] || [ -z "$seed_shape" ]; then
      HEALTH_DETAIL="finder seed shape COULD-NOT-CHECK: the seed probe ($HEALTH_PY) did not run (exit $seed_probe_rc) — the #4020 seed-shape assertion was NOT made on a build that ships search-seed.json"
      log "HEALTH: $HEALTH_DETAIL — refusing to switch"; return 1
    fi
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

# A HEALTH-failed release must NEVER stay staged (D26).  PLAN's already-staged
# test is "the dir exists and has an index.html" — which a broken release satisfies —
# so leaving it behind POISONED the build_id: every retry re-gated the same
# broken bytes and failed 14 forever, with no way back short of a manual rm.
# Purge it.  The one exception is a release that is ALSO the live or the
# .previous rollback target (a re-gate of an already-staged build): deleting
# those bytes would destroy the rollback path, so we keep them and drop a poison
# marker PLAN refuses instead.  Either way the next deploy of this build_id
# REBUILDS from source.
purge_failed_release() {
  local livecur="" prev=""
  # A PREBUILT release has NO source on this box.  Purging it would drop it into
  # the `else` arm of PLAN — a rebuild from the PROVISIONED TEMPLATE, which bakes
  # genuine bp-build-id/bp-content-rev markers, passes HEALTH and goes live with
  # bytes that are not the ones anybody uploaded.  Fail closed: keep the tree
  # (marker and all) and say what the operator actually has to do.
  if [ -f "$RELDIR/$PREBUILT_MARK" ]; then
    : > "$RELDIR/$HEALTH_FAIL_MARK" 2>/dev/null || true
    log "HEALTH: release $BUILD_ID was staged from UPLOADED prebuilt bytes — this box has no source to rebuild it from, so its bytes are KEPT and marked health-failed: re-upload required (a template rebuild would pass HEALTH on genuine markers and go live with the WRONG bytes)"
    return 0
  fi
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

# STAGE's one copy idiom, shared by the two arms that produce bytes (a local
# build's dist/, and an uploaded prebuilt tree).  Stage into a .partial dir, then
# swap it in, so a crash mid-copy never leaves a half-populated
# releases/<build_id>/ that a later PLAN mistakes for staged — and so a FAILED
# copy never destroys the release that was already there (see the body).  cp/mv carry no forensic of their own —
# capture the exit code + a disk read (the copy that fails on a real box almost
# always fails on a full /opt) so the detail names the next move instead of a
# bare "copy failed".  Exits 13 (STAGE failed) on either failure, after emitting.
stage_dir_into_release() { # <srcdir> <what> [prebuilt_sha256]
  local src="$1" what="$2" sha="${3:-}" cp_rc mv_rc disk aside="" aside_rc
  # NEVER delete releases/<build_id> before the new bytes exist.  That dir can be
  # the LIVE release or the .previous rollback target — a re-upload with
  # --deployment <id> takes PLAN's prebuilt arm and lands right here — so an
  # up-front `rm -rf` followed by a cp that fails (exit 13, ordinary on a full
  # /opt) destroyed the very release a rollback would flip to: .previous pointed
  # at a missing dir and do_rollback returned 21.  A FAILED DEPLOY MUST NEVER
  # COST THE ROLLBACK TARGET.
  # So: copy into a fresh .partial, then SWAP — move the old dir ASIDE, rename
  # the partial in, and remove the aside copy only once the rename has landed.
  # Every failure path before that last step leaves the existing release, and
  # therefore the rollback path, byte-for-byte intact.
  rm -rf "$RELDIR.partial" "$RELDIR.aside"
  mkdir -p "$RELDIR.partial"
  cp -a "$src/." "$RELDIR.partial/"; cp_rc=$?
  if [ "$cp_rc" -ne 0 ]; then
    disk="$(disk_free "$RELEASES")"; rm -rf "$RELDIR.partial"
    DETAIL="copy of $what into releases/$BUILD_ID failed (cp exit $cp_rc; disk ${disk:-?}) — out of space or perms on the releases mount; check df and the dir ownership. The previously staged releases/$BUILD_ID (if any) is UNTOUCHED, so any rollback target it held is still there"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  # The provenance marker rides INSIDE the atomic rename — a release dir never
  # exists without it, so no reader can see prebuilt bytes as locally built.
  [ -n "$sha" ] && printf '%s\n' "$sha" > "$RELDIR.partial/$PREBUILT_MARK"
  if [ -e "$RELDIR" ]; then
    mv "$RELDIR" "$RELDIR.aside"; aside_rc=$?
    if [ "$aside_rc" -ne 0 ]; then
      rm -rf "$RELDIR.partial"
      DETAIL="could not move the existing releases/$BUILD_ID aside before the swap (mv exit $aside_rc) — the staged tree was discarded and the existing release is untouched; check ownership of the releases dir"
      log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
    fi
    aside="$RELDIR.aside"
  fi
  mv "$RELDIR.partial" "$RELDIR"; mv_rc=$?
  if [ "$mv_rc" -ne 0 ]; then
    # Put the old release BACK.  The swap is only a swap if it is reversible.
    [ -n "$aside" ] && mv "$aside" "$RELDIR" 2>/dev/null
    rm -rf "$RELDIR.partial"
    DETAIL="rename into releases/$BUILD_ID failed (mv exit $mv_rc) — expected an atomic move within the releases dir; check the target isn't a non-empty dir or a mountpoint, and its ownership. Any previously staged tree was restored"
    log "STAGE: $DETAIL"; emit STAGE failed "$DETAIL"; exit 13
  fi
  [ -n "$aside" ] && rm -rf "$aside"
  return 0
}

# ---------------------------------------------------------------------------
# SELF-TEST — fixtures in a tmpdir; proves the real primitives, no npm/caddy.
# ---------------------------------------------------------------------------
if [ "$MODE" = selftest ]; then
  # -------------------------------------------------------------------------
  # SELF-TEST FLOOR — two LITERAL, COMMITTED constants (task-7843c92e00b0a13a).
  #
  # The verdict below used to be `[ "$FAILS" -eq 0 ]` and nothing else, so a run
  # that executed three checks and a run that executed 391 both printed
  # `[selftest] PASS`. Three blocks in this file drop out on a toolchain/tree
  # condition (python3+curl for the HEALTH probes and the engine e2e, a real
  # flock(1) for the fleet admission gate, api/lib/barkpark/sites/deploy_runner.ex
  # for the DeployRunner doctrine rows). Each one is already a HARD failure when
  # BARKPARK_SELFTEST_REQUIRE_E2E=1 — but a block can also vanish for a reason
  # nobody wrote a guard for (a refactor drops an `if`, a fixture stops being
  # created, an `exit 0` lands mid-suite). The floor catches THAT class: a suite
  # that stopped running rows must not report PASS.
  #
  # The numbers are LITERALS, never derived from the run — a floor computed from
  # the same run is exactly the vacuity it is meant to catch. Measured
  # 2026-09-03 at origin/main 0cb244bfb:
  #
  #   MIN  =  76  every optional block skipped (no python3/curl, no flock, no api/)
  #   FULL = 458  all blocks run — this is what CI gets (430 + the 10 rows of
  #                the static-miss 404 block + the 18 rows of the already-armed
  #                hide-UPGRADE block, both of which need a real caddy(1))
  #
  # 2026-09-04: +25 (67->76, 433->458) for the three failure arms that had no row
  # at all — the disarm's awk/mv revert (9, unconditional, so BOTH floors move),
  # the arm's lock-never-taken branch (8) and the arm's awk/mv revert (8), the
  # last two inside the python3/curl e2e block so they land on FULL only.
  #
  # FULL applies when BARKPARK_SELFTEST_REQUIRE_E2E=1, which is exactly the venue
  # .github/workflows/deploy-harnesses.yml runs ("Site deploy engine self-test",
  # env BARKPARK_SELFTEST_REQUIRE_E2E: "1", ubuntu-latest: python3, curl and
  # util-linux flock all present, api/ checked out). There is no platform branch
  # inside this self-test, so under that flag the row count is deterministic.
  # MIN applies to a bare laptop run, where the SKIPs are honest.
  #
  # ADD rows -> raise the literal in the SAME commit. Remove rows -> lower it in
  # the same commit. A red here is either a missing block or an unraised floor.
  SELFTEST_FLOOR_MIN=76
  SELFTEST_FLOOR_FULL=458
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
  # build_failure_reason — the ONE shared extractor (it used to be duplicated in
  # both engines), pinned against a RECORDED REAL producer, never a hand-written
  # fixture: deploy/testdata/capstone-turbopack-build-fail.txt is the literal
  # 30,993 bytes of a live search-capstone Turbopack failure, captured off
  # guerrilla (.txt, not .log, only because .gitignore drops *.log — the bytes
  # are the raw log, unedited, md5 6fc6a06b39b0d6b5b46d933c9dbb6579). The tier counts below are MEASUREMENTS of those bytes — they are
  # what says a fifth grep tier would be a guess, and they red the moment someone
  # "improves" the predicates against a log nobody recorded.
  # -------------------------------------------------------------------------
  echo "[selftest] build_failure_reason picks the right line out of a RECORDED real Turbopack failure"
  FIXLOG="$(cd "$(dirname "$SELF")" && pwd)/testdata/capstone-turbopack-build-fail.txt"
  check "the recorded producer is committed (not hand-written)" [ -f "$FIXLOG" ]
  if [ -f "$FIXLOG" ]; then
    check "it is the captured 30,993 bytes, unedited" \
      [ "$(wc -c < "$FIXLOG" | tr -d ' ')" = 30993 ]
    check "tier 1 (FATAL) does not fire — a Turbopack failure carries none" \
      [ "$(grep -ac 'FATAL' "$FIXLOG" 2>/dev/null || true)" = 0 ]
    check "tier 2 matches EXACTLY ONE line in 30,993 bytes (not a tail -1 accident)" \
      [ "$(grep -aE 'npm ERR!|[Ee]rror:' "$FIXLOG" | grep -av 'complete log of this run' | wc -l | tr -d ' ')" = 1 ]
    # THE REGRESSION THIS FILE EXISTS FOR. The header alone names a COUNT and no
    # CAUSE: `search-capstone` failed 25 times and every durable record was
    # "Turbopack build failed with 29 errors:" — 29 errors printed, none named.
    # The reason must now carry the FIRST REAL ERROR out of the block below it.
    check "the extractor names a CAUSE, not just the count" \
      [ "$(build_failure_reason "$FIXLOG")" = "Error: Turbopack build failed with 29 errors: ./sites/search-capstone/src/app/(finder)/page.tsx:1:1 Module not found: Can't resolve '@/components/desktop-only'" ]
    # Stated as their own arms so a future change that keeps the header but drops
    # the body reds HERE, naming what was lost, instead of only failing the
    # whole-string compare above. (Via a file, not `sh -c` — build_failure_reason
    # is a shell FUNCTION and a subshell cannot see it.)
    FIXREASON="$TD/fix-reason.txt"
    build_failure_reason "$FIXLOG" > "$FIXREASON"
    check "an individual error — the file:line — survives into the reason" \
      grep -q 'page.tsx:1:1' "$FIXREASON"
    check "an individual error — the MESSAGE — survives into the reason" \
      grep -q "Can't resolve" "$FIXREASON"
    # The channel is `emit`, which flattens to one line and cut -c1-240, so a
    # reason that overflows is silently beheaded. This is the budget check.
    check "the reason fits the 240-char detail budget the emitter enforces" \
      [ "$(wc -c < "$FIXREASON" | tr -d ' ')" -le 240 ]
    check "and it stays ONE line — the emitter cannot carry a block" \
      [ "$(wc -l < "$FIXREASON" | tr -d ' ')" = 0 ]
    # The tier BELOW it would have been strictly worse: a stack frame with no
    # subject. This is the check that says the ORDER is load-bearing.
    check "tier 3 (last non-blank) would have been strictly worse" \
      [ "$(grep -av '^[[:space:]]*$' "$FIXLOG" | tail -1)" != "Error: Turbopack build failed with 29 errors:" ]
  fi
  EMPTYLOG="$TD/empty-build.log"; : > "$EMPTYLOG"
  check "a build that printed NOTHING falls through to the honest fallback (never empty)" \
    [ "$(build_failure_reason "$EMPTYLOG")" = "npm ci / npm run build failed with no output" ]
  check "a missing log file is the same honest fallback, not a shell error" \
    [ "$(build_failure_reason "$TD/no-such-build.log")" = "npm ci / npm run build failed with no output" ]
  # TOTALITY OF THE APPEND. A summary header is only ever ENRICHED, never
  # replaced, and a header with nothing under it degrades to the header — never
  # to an empty reason, and never to a shell error.
  HDRONLY="$TD/hdr-only-build.log"
  printf 'noise\nError: Turbopack build failed with 3 errors:\n' > "$HDRONLY"
  check "a header with NO body below it degrades to the header, not to empty" \
    [ "$(build_failure_reason "$HDRONLY")" = "Error: Turbopack build failed with 3 errors:" ]
  NOTHDR="$TD/npm-err-build.log"
  printf 'npm ERR! code ELIFECYCLE\nnpm ERR! errno 1\n' > "$NOTHDR"
  check "a reason that is ALREADY a cause is left exactly as it was" \
    [ "$(build_failure_reason "$NOTHDR")" = "npm ERR! errno 1" ]

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
  # TEARDOWN, THE REWRITE ITSELF FAILED (D77) — the THIRD way disarm_caddy_site_route
  # returns 2, and the only one no fixture reached. The two blocks above both
  # drive the `caddy validate` revert; the awk/mv arm
  # (`awk … > "$tmp" && mv "$tmp" "$CADDYFILE" || { … mv "$bak" … ; return 2; }`)
  # fires when the Caddyfile could not be REWRITTEN at all — a full /tmp, a
  # read-only filesystem, an ENOSPC — and on origin/main nothing asserted that it
  # too refuses TORN_DOWN=, restores the backup and keeps the tree.
  #
  # THE FIXTURE: a bare `mktemp` (no arguments) is called by exactly the two
  # Caddyfile rewriters in this engine — the arm and the disarm. Every OTHER
  # mktemp caller passes an explicit template (the health body, the build log,
  # this self-test's own scratch dir), so a stub that only redirects the ZERO-ARG
  # form and execs the real binary otherwise arms this one branch and nothing
  # else. Pointed at a path under a directory that does not exist, the
  # `awk … > "$tmp"` redirect fails, the `&&` chain short-circuits and the revert
  # arm runs — the same state an ENOSPC produces, without needing a full disk or
  # a root-owned mount (a chmod-based fixture would be a no-op under a root CI).
  # -------------------------------------------------------------------------
  echo "[selftest] --teardown REFUSES to claim TORN_DOWN when the Caddyfile REWRITE itself fails (D77)"
  TM="$TD/teardown-mv"; mkdir -p "$TM/bin" "$TM/sites/stuck/releases/b1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TM/bin/caddy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TM/bin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TM/bin/flock"
  printf '#!/usr/bin/env bash\nif [ "$#" = 0 ]; then echo "%s/no-such-dir/tmp"; exit 0; fi\nif [ -x /usr/bin/mktemp ]; then exec /usr/bin/mktemp "$@"; fi\nexec /bin/mktemp "$@"\n' "$TM" > "$TM/bin/mktemp"
  chmod +x "$TM/bin/"*
  ln -sfn releases/b1 "$TM/sites/stuck/current"
  cp "$TL/Caddyfile" "$TM/Caddyfile"
  cp "$TM/Caddyfile" "$TM/Caddyfile.orig"
  env PATH="$TM/bin:$PATH" SITE_SLUG=stuck BARKPARK_SITES_DIR="$TM/sites" \
    BARKPARK_CADDYFILE="$TM/Caddyfile" BARKPARK_SITE_DEPLOY_LOCK="$TM/lock" \
    BARKPARK_CADDYFILE_LOCK="$TM/cflock" BARKPARK_SITE_LOG_FILE="$TM/log" \
    bash "$SELF" --teardown > "$TM/out" 2>&1; tdrc5=$?
  check "un-rewritable teardown exits 25 (not 0)"   [ "$tdrc5" = 25 ]
  check "un-rewritable teardown names the REWRITE as what failed (not caddy validate)" \
    grep -q 'could not rewrite .* for the /sites/stuck disarm — restoring the backup' "$TM/out"
  check "un-rewritable teardown printed NO TORN_DOWN= on stdout" absent 'TORN_DOWN=' "$TM/out"
  check "un-rewritable teardown logged NO TORN_DOWN= to the durable log" absent 'TORN_DOWN=' "$TM/log"
  check "un-rewritable teardown printed the typed failure" \
    grep -q '^TEARDOWN_FAILED=stuck detail="' "$TM/out"
  check "un-rewritable teardown claims a MEASURED still-live route (the disarm DID run)" \
    grep -q 'STILL LIVE' "$TM/out"
  check "un-rewritable teardown KEPT the release tree (recoverable)" \
    [ -d "$TM/sites/stuck/releases/b1" ]
  check "un-rewritable teardown left the Caddyfile byte-identical (the backup was restored)" \
    cmp -s "$TM/Caddyfile" "$TM/Caddyfile.orig"
  check "un-rewritable teardown left no .bak.teardown turd beside the Caddyfile" \
    sh -c "! ls '$TM'/Caddyfile.bak.teardown.* >/dev/null 2>&1"

  # -------------------------------------------------------------------------
  # HEALTH finder integrity — the gate must refuse a finder build whose seed is
  # corrupt (the #4020 class) or whose island lost its error boundary (#4047),
  # while leaving plain (seedless) templates untouched. Drives the REAL
  # health_gate against hand-built release dirs (needs the throwaway server).
  # -------------------------------------------------------------------------
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    # A SKIP is honest on a laptop and a VACUOUS GREEN in CI. The deep-path probe
    # below is worse than the finder rows in that respect: without python3 the
    # extractor yields an empty target, health_gate logs 'n/a' and PASSES — the
    # guard is OFF and the suite still prints PASS. CI sets
    # BARKPARK_SELFTEST_REQUIRE_E2E=1 (.github/workflows/deploy-harnesses.yml), so
    # a runner missing python3/curl fails LOUDLY here instead.
    if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
      echo "[selftest] FAIL - the HEALTH gate proofs (finder integrity + the deep-path probe) are REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but python3 and/or curl are missing from PATH — install them on this runner; without python3 the deep-path probe silently degrades to 'n/a' and PASSES every broken release, and a skipped block must not report PASS"
      exit 1
    fi
    echo "[selftest] SKIP HEALTH finder integrity + deep-path probe — needs python3 + curl"
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

    # -----------------------------------------------------------------------
    # HEALTH deep path — the gate must certify a page the SERVED html LINKS TO,
    # not only /index.html. Before this block the gate fetched exactly one
    # hardcoded url, so a release with a perfect index.html and a LINKED page
    # that 404s passed and SWITCHed live: the mangled-accented-dir, NFD-on-disk
    # and missing-page fixtures below were all measured PASSING on main.
    # The one choice these rows exist to pin: the probe target comes from the
    # HTML'S OWN href, never from a directory listing — h_deep_mangled has the
    # mangled dir PRESENT on disk, so a disk-derived probe would ask for `caf/`,
    # get 200, and certify the hole.
    # -----------------------------------------------------------------------
    echo "[selftest] HEALTH probes a page the SERVED html links to (deep path), base-aware, n/a for single-page builds"
    mkidx() { # <dir> <base|none> <body-html>
      local d="$1" base="$2"; mkdir -p "$d"
      { printf '<!doctype html><html><head>'
        printf '<meta name="bp-build-id" content="fb"><meta name="bp-content-rev" content="fr"><meta name="bp-doc-id" content="fd">'
        [ "$base" != none ] && printf '<meta name="bp-site-base" content="%s">' "$base"
        printf '</head><body>%s</body></html>' "$3"
      } > "$d/index.html"
      return 0
    }
    mkpage() { mkdir -p "$1"; printf '<html><body>deep</body></html>' > "$1/index.html"; }
    # Same subject as gate(), but keeps the gate's own prose for assertions — the
    # log is one of the two channels the refusal must ride.
    gate_log() { RELDIR="$1"; BUILD_ID=fb; CONTENT_REV=fr; health_gate > "$2" 2>&1; }
    ACC="$(printf 'caf\xc3\xa9')"                 # NFC "café" — the href's bytes
    NFD="$(printf 'cafe\xcc\x81')"                # the same grapheme, decomposed

    mkidx "$TD/hd_ok" none '<a href="d/hello/">hello</a>'
    mkpage "$TD/hd_ok/d/hello"
    check "a linked deep page that SERVES passes"        gate_log "$TD/hd_ok" "$TD/hd_ok.log"
    check "the pass names the probed path (not index.html)" \
      grep -q 'deep path /d/hello/ serves 200' "$TD/hd_ok.log"

    mkidx "$TD/hd_mangled" none "<a href=\"d/$ACC/\">kaffe</a>"
    mkpage "$TD/hd_mangled/d/caf"                 # THE MANGLING: accented name lost
    check "the mangled dir IS on disk (a disk-derived probe would have passed it)" \
      [ -f "$TD/hd_mangled/d/caf/index.html" ]
    check "a MANGLED accented deep page FAILS"           not gate_log "$TD/hd_mangled" "$TD/hd_mangled.log"
    check "the refusal names the HREF's path, percent-encoded" \
      grep -q 'links to /d/caf%C3%A9/' "$TD/hd_mangled.log"
    check "the refusal does NOT name the mangled on-disk path" \
      absent 'links to /d/caf/' "$TD/hd_mangled.log"
    check "the refusal carries got, want, both causes and the do-not-retry move" \
      grep -q 'served HTTP 404, want 200\. Re-pack and re-upload; do not retry this artifact\. Cause: a tar dropped or mangled a non-ASCII path component, or disk names are NFD vs NFC in the href' \
      "$TD/hd_mangled.log"

    mkidx "$TD/hd_missing" none '<a href="about.html">about</a>'
    check "a plain MISSING ASCII linked page FAILS too"  not gate_log "$TD/hd_missing" "$TD/hd_missing.log"
    check "that refusal names /about.html"               grep -q 'links to /about.html' "$TD/hd_missing.log"

    # Base-awareness. The real content template emits ${base}d/${doc.slug}/ —
    # root-relative AND base-prefixed — while the throwaway server is rooted at
    # the release dir, so an un-stripped href would 404 on EVERY healthy site.
    mkidx "$TD/hd_base" /sites/blog/ '<a href="/sites/blog/d/x/">x</a>'
    mkpage "$TD/hd_base/d/x"
    check "a base-prefixed root-relative href is stripped and PASSES" gate_log "$TD/hd_base" "$TD/hd_base.log"
    check "it was fetched at the base-stripped path"      grep -q 'deep path /d/x/ serves 200' "$TD/hd_base.log"
    check "the pass names the base it stripped"           grep -q "site base '/sites/blog/'" "$TD/hd_base.log"

    mkidx "$TD/hd_outside" /sites/blog/ '<a href="/elsewhere/other.html">off-base</a>'
    check "a root-relative href OUTSIDE the base is SKIPPED, not refused" gate_log "$TD/hd_outside" "$TD/hd_outside.log"
    check "and it says the probe was n/a"                 grep -q 'deep-path probe n/a' "$TD/hd_outside.log"

    # The real shape end to end: base + accented slug + trailing-slash dir url.
    mkidx "$TD/hd_real" /sites/blog/ "<a href=\"/sites/blog/d/$ACC/\">kaffe</a>"
    mkpage "$TD/hd_real/d/$ACC"
    check "base + ACCENTED slug + directory url PASSES when the page is there" gate_log "$TD/hd_real" "$TD/hd_real.log"
    check "and the log proves it was fetched percent-encoded" \
      grep -q 'deep path /d/caf%C3%A9/ serves 200' "$TD/hd_real.log"

    mkidx "$TD/hd_single" none '<h1>hello</h1>'
    check "a single-page build passes (deep-path probe n/a)" gate_log "$TD/hd_single" "$TD/hd_single.log"
    check "and says so"                                   grep -q 'deep-path probe n/a (single-page build)' "$TD/hd_single.log"
    mkidx "$TD/hd_ext" none '<a href="https://example.com/a/b/">out</a><a href="mailto:a@b.c">mail</a><a href="#top">top</a>'
    check "external / mailto / fragment hrefs are not internal links (n/a, no refusal)" gate_log "$TD/hd_ext" "$TD/hd_ext.log"
    check "and that says n/a too"                         grep -q 'deep-path probe n/a' "$TD/hd_ext.log"

    # ── COULD-NOT-CHECK is not OK ──────────────────────────────────────────
    # The hole these rows close: both HEALTH assertion probes ran python3 with
    # `2>/dev/null || true`, so an interpreter that was missing or that crashed
    # produced an EMPTY result — and empty was read as "no internal link" /
    # "seed fine". The gate then logged `deep-path probe n/a (single-page
    # build)` and `finder integrity OK` and PASSED, on a release where nothing
    # was checked at all. The suite's own SKIP note above (:~860) already knew
    # this; the GATE did not. BARKPARK_HEALTH_PY names the probe interpreter
    # (the throwaway server keeps its own python3), so these rows break exactly
    # the thing the probe needs and nothing else.
    cnc_before=$TESTS
    mkidx "$TD/hd_cnc" none '<a href="d/hello/">hello</a>'
    mkpage "$TD/hd_cnc/d/hello"
    check "control: with a working probe the deep path is CERTIFIED" \
      gate_log "$TD/hd_cnc" "$TD/hd_cnc.log"
    check "control names the probed path" grep -q 'deep path /d/hello/ serves 200' "$TD/hd_cnc.log"
    ( BARKPARK_HEALTH_PY="$TD/no-such-python"; export BARKPARK_HEALTH_PY
      gate_log "$TD/hd_cnc" "$TD/hd_cnc_broken.log" ) && cnc_rc=0 || cnc_rc=1
    check "a probe that COULD NOT RUN makes HEALTH REFUSE (was: silent pass)" [ "$cnc_rc" = 1 ]
    check "and the refusal says COULD-NOT-CHECK, naming the unmade assertion" \
      grep -q 'deep-path probe COULD-NOT-CHECK' "$TD/hd_cnc_broken.log"
    check "and it does NOT claim the release is a single-page build" \
      absent 'deep-path probe n/a' "$TD/hd_cnc_broken.log"

    # the seed probe, same disease, same rule
    mkidx "$TD/hd_cnc_seed" none '<h1>hello</h1>'
    printf '{"initialSeed":[]}' > "$TD/hd_cnc_seed/search-seed.json"
    check "control: a good seed with a working probe passes" \
      gate_log "$TD/hd_cnc_seed" "$TD/hd_cnc_seed.log"
    check "control says finder integrity OK" grep -q 'finder integrity OK' "$TD/hd_cnc_seed.log"
    ( BARKPARK_HEALTH_PY="$TD/no-such-python"; export BARKPARK_HEALTH_PY
      gate_log "$TD/hd_cnc_seed" "$TD/hd_cnc_seed_broken.log" ) && scnc_rc=0 || scnc_rc=1
    check "a seed probe that COULD NOT RUN makes HEALTH REFUSE (was: 'integrity OK')" \
      [ "$scnc_rc" = 1 ]
    check "and it does NOT print 'finder integrity OK' over an unread seed" \
      absent 'finder integrity OK' "$TD/hd_cnc_seed_broken.log"

    # NON-VACUITY. Every row above lives behind a fixture that could fail to
    # build and behind an `if` that could stop selecting this branch; a block
    # that silently stops running is the exact defect these rows exist to
    # catch, so the block asserts its OWN executed count instead of trusting
    # an empty result.
    cnc_ran=$((TESTS - cnc_before))
    check "the COULD-NOT-CHECK block ran all 9 of its rows (got $cnc_ran)" \
      [ "$cnc_ran" -eq 9 ]

    # NFC vs NFD. The VERDICT is deliberately not asserted: APFS is
    # normalization-INSENSITIVE (measured — a dir created with NFD bytes answers
    # for the NFC name), so a "refusal" row here would pass on Linux and pass on
    # macOS for the OPPOSITE reason. What IS provable anywhere, and is the whole
    # point, is that the probe requests the HREF's bytes (NFC) and never the
    # disk's (NFD) — a disk-derived probe would ask for the decomposed name and
    # certify itself. The 404 is a box-only proof and belongs to the crown walk.
    mkidx "$TD/hd_nfd" none "<a href=\"d/$ACC/\">kaffe</a>"
    mkpage "$TD/hd_nfd/d/$NFD"
    gate_log "$TD/hd_nfd" "$TD/hd_nfd.log" || true
    check "NFD-on-disk: the probe requests the HREF's NFC bytes (%C3%A9), not the disk's" \
      grep -q '/d/caf%C3%A9/' "$TD/hd_nfd.log"
    check "NFD-on-disk: it never requests a decomposed path (%CC%81)" \
      absent '%CC%81' "$TD/hd_nfd.log"
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
    # A SKIP here is honest on a laptop and DANGEROUS in CI: everything this
    # block proves — the stage protocol, the content-truth gate, "the box ran no
    # npm" — would silently not run while the self-test still printed PASS and
    # exited 0.  CI sets BARKPARK_SELFTEST_REQUIRE_E2E=1 so a runner without
    # python3/curl is a HARD failure instead of a green vacuum.
    if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
      echo "[selftest] FAIL - engine e2e is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but python3 and/or curl are missing from PATH — install them on this runner; a skipped e2e block proves NOTHING and must not report PASS"
      exit 1
    fi
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
bid="${BARKPARK_BUILD_ID:-}"; rev="${BARKPARK_CONTENT_REV:-}"; doc="doc-42"; corpus=""
# The exact build that WENT LIVE on guerrilla: a wrong build id and an EMPTY
# content rev, both of which the old name-only gate waved through.
[ -f ./.lie ] && { bid=TOTALLY-WRONG; rev=""; }
# A STATIC build that could NOT read its corpus: empty bp-doc-id (the gate must
# still refuse) PLUS the bp-corpus-status marker naming the upstream condition.
[ -f ./.no-corpus ] && { doc=""; corpus="graph 403: public-read tokens may only read published public documents"; }
# The legacy shape: empty bp-doc-id and NO status marker (a template built before
# the corpus-status contract) — the gate must refuse AND say the cause is unknown.
[ -f ./.no-corpus-legacy ] && { doc=""; corpus=""; }
mkdir -p dist
{
  printf '<!doctype html><html><head>\n'
  printf '<meta name="bp-build-id" content="%s">\n' "$bid"
  printf '<meta name="bp-content-rev" content="%s">\n' "$rev"
  printf '<meta name="bp-doc-id" content="%s">\n' "$doc"
  # Emitted ONLY when there is something to record — same conditional the
  # template uses (a healthy build carries no bp-corpus-status at all).
  [ -n "$corpus" ] && printf '<meta name="bp-corpus-status" content="%s">\n' "$corpus"
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
    # A NEGATIVE log assertion needs its own helper: `check` runs its arguments
    # as a command, so a bare `!` cannot be passed through.
    no_log_match() { ! grep -Eq "$1" "$E2E/out.log"; }
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

    echo "[selftest] e2e: an UNREADABLE CORPUS fails HEALTH and the reason NAMES the upstream condition (403), not just the empty marker"
    : > "$SRC/.no-corpus"
    rc="$(E2E_REV=rev-3b e2e_deploy e3b)"
    rm -f "$SRC/.no-corpus"
    check "unreadable-corpus build exit 14"    [ "$rc" = 14 ]
    check "HEALTH failed"                      saw HEALTH failed e3b
    check "the reason names the UPSTREAM 403, read out of bp-corpus-status" \
      grep -q 'bp-doc-id marker is empty .* graph 403: public-read tokens may only read published public documents' "$E2E/out.log"
    # Dual-channel, same contract as the lying build: the cause must ride the
    # plain human log too, because the run-level reason_tail is the copy the
    # user actually sees at the verdict line.
    check "the cause ALSO rides the plain human log (dual-channel)" \
      grep -q '\[site-deploy .*HEALTH: bp-doc-id marker is empty .* graph 403: ' "$E2E/out.log"
    # THE CLASSIFIER'S ANCHOR, asserted by the PRODUCER.
    # `cloud/lib/barkpark_cloud/deploy_ledger.ex` reads the upstream status out
    # of the stored failure_reason with the regex
    #   could not read a content document: graph (\d+):
    # and routes it to CONTENT_API_403 / _500 / _503 / _UNREACHABLE. Reword the
    # English a few hundred lines above and every static row silently degrades
    # back to the causeless DOC_ID_EMPTY bucket with nothing anywhere failing.
    # So the producer asserts the consumer's anchor against its own bytes: a
    # reflow reds HERE, on the shell side, at edit time.
    check "the emitted reason still matches the CLASSIFIER's anchor (cloud deploy_ledger.ex)" \
      grep -Eq 'could not read a content document: graph [0-9]+:' "$E2E/out.log"
    check "no SWITCH stage line at all"        nosaw SWITCH
    check "current did NOT move (the gate STILL fails closed)" [ "$(livenow)" = releases/e1 ]
    check "the corpus-less release is purged"  [ ! -d "$E2E_SITE/releases/e3b" ]

    echo "[selftest] e2e: an empty bp-doc-id with NO status marker still refuses, and SAYS the cause went unrecorded"
    : > "$SRC/.no-corpus-legacy"
    rc="$(E2E_REV=rev-3c e2e_deploy e3c)"
    rm -f "$SRC/.no-corpus-legacy"
    check "legacy empty-marker build exit 14"  [ "$rc" = 14 ]
    check "HEALTH failed"                      saw HEALTH failed e3c
    check "the reason admits the cause is UNRECORDED (never invents one)" \
      grep -q 'no bp-corpus-status marker: this build predates the corpus-status contract' "$E2E/out.log"
    check "it does NOT claim a 403"            no_log_match 'graph 403'
    check "no SWITCH stage line at all"        nosaw SWITCH
    check "current did NOT move (still e1)"    [ "$(livenow)" = releases/e1 ]

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

    # -----------------------------------------------------------------------
    # PREBUILT — THE BUILD LEAVES THE SERVING BOX (D88/D89).  Its own slug, its
    # own source dir and therefore its OWN .npm-calls sentinel: sharing the
    # skip-build slot above would let a regression in one mask the other.
    # Exit 0, HEALTH ok and SWITCH ok ALL SURVIVE deleting the prebuilt branch
    # (the fallback rebuild produces genuine markers), so the only assertions
    # that discriminate are the two facts below: the box ran NO npm, and the
    # bytes that went live are the ones that were uploaded.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: a PREBUILT deploy STAGEs uploaded bytes with NO npm on this box"
    PSRC="$E2E/psrc"; PB="$E2E/prebuilt"; PB_SITE="$E2E/sites/prebuilt"
    mkdir -p "$PSRC" "$PB"
    printf '{"name":"selftest-prebuilt","private":true}\n' > "$PSRC/package.json"
    # Opaque 64-hex identities (the CP verifies the real digest; this engine
    # RECORDS and COMPARES it — it never re-hashes the tree, and must not claim to).
    SHA_A="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    SHA_B="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    SHA_C="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    pb_livenow() { readlink "$PB_SITE/current" 2>/dev/null || true; }
    pb_deploy() { # <build_id> [prebuilt_dir] [sha256] -> exit code; stdout at $E2E/pb.out
      env PATH="$FAKEBIN:$PATH" \
        SITE_SLUG=prebuilt BUILD_ID="$1" CONTENT_REV=rev-1 SITE_SRC="$PSRC" \
        PREBUILT_DIR="${2:-}" PREBUILT_SHA256="${3:-}" \
        BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$E2E/prebuilt.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$E2E/pb.out" 2> "$E2E/pb.err"
      echo $?
    }
    pb_saw() { grep -q "^BPSTAGE name=$1 status=$2 build_id=$3" "$E2E/pb.out"; }
    pb_grep() { grep -q "$1" "$E2E/pb.out"; }
    pb_absent() { ! grep -q "$1" "$E2E/pb.out"; }
    # Every stage NAME and STATUS on the wire must be one the control plane's
    # closed whitelists accept (@stage_names/@stage_statuses in deploy_runner.ex):
    # an invented word is silently DROPPED, and an unknown status renders as
    # 'pending' — a stage bar stuck forever with the deploy long finished.
    # ROUTE is the ONE deliberate exception (D346): it is outside @stage_names ON
    # PURPOSE so the route report can never enter `stages` or reach
    # stage_exit_code/1, i.e. never flip a verdict. It is excluded here and
    # asserted separately (see the ROUTE block below).
    pb_wire_whitelisted() {
      ! grep '^BPSTAGE ' "$E2E/pb.out" | grep -v '^BPSTAGE name=ROUTE ' \
        | grep -qvE '^BPSTAGE name=(PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE) status=(started|ok|skipped|noop|failed) build_id=[A-Za-z0-9._-]+( |$)'
    }
    mk_prebuilt() { # <dir> <build_id> <body-marker>
      rm -rf "$1"; mkdir -p "$1"
      { printf '<!doctype html><html><head>\n'
        printf '<meta name="bp-build-id" content="%s">\n' "$2"
        printf '<meta name="bp-content-rev" content="rev-1">\n'
        printf '<meta name="bp-doc-id" content="doc-42">\n'
        printf '</head><body><h1>%s</h1></body></html>\n' "$3"
      } > "$1/index.html"
    }

    # POSITIVE CONTROL — this sentinel CAN fire.  Without it, "no npm ran" is
    # indistinguishable from "the sentinel was never wired up".
    rm -f "$PSRC/.npm-calls"
    rc="$(pb_deploy pb0)"
    check "positive control: a source deploy on this slug exits 0"  [ "$rc" = 0 ]
    check "positive control: the prebuilt slug's OWN npm sentinel FIRES" [ -s "$PSRC/.npm-calls" ]

    mk_prebuilt "$PB" pb1 "UPLOADED-BYTES-pb1-v1"
    : > "$PSRC/.npm-calls"
    rc="$(pb_deploy pb1 "$PB" "$SHA_A")"
    check "prebuilt deploy exit 0"                    [ "$rc" = 0 ]
    check "PLAN ok"                                   pb_saw PLAN ok pb1
    check "BUILD skipped SAYS prebuilt and NAMES the digest" \
      grep -qE '^BPSTAGE name=BUILD status=skipped build_id=pb1 detail="prebuilt bytes \(.*, sha256 0123456789ab\) - no build ran on this box"' "$E2E/pb.out"
    check "STAGE genuinely RAN (started)"             pb_saw STAGE started pb1
    check "STAGE ok names the prebuilt digest" \
      grep -qE '^BPSTAGE name=STAGE status=ok build_id=pb1 detail="prebuilt bytes -> releases/pb1 \(.*sha256 0123456789ab\)"' "$E2E/pb.out"
    check "HEALTH ok"                                 pb_saw HEALTH ok pb1
    check "SWITCH ok"                                 pb_saw SWITCH ok pb1
    check "current -> releases/pb1"                   [ "$(pb_livenow)" = releases/pb1 ]
    check "THE BOX RAN NO NPM (its own sentinel is empty)" [ ! -s "$PSRC/.npm-calls" ]
    check "THE UPLOADED BYTES ARE WHAT IS LIVE" \
      grep -q 'UPLOADED-BYTES-pb1-v1' "$PB_SITE/current/index.html"
    check "the release records WHICH bytes it carries (.bp-prebuilt-sha256)" \
      [ "$(cat "$PB_SITE/releases/pb1/.bp-prebuilt-sha256" 2>/dev/null)" = "$SHA_A" ]
    check "every BPSTAGE name+status on the wire is whitelisted" pb_wire_whitelisted

    echo "[selftest] e2e: a RE-UPLOAD over an existing release dir stages the NEW bytes"
    # pb1's dir now exists and has an index.html — exactly what the already-staged
    # arm accepts.  Tested below the PREBUILT arm, this run would re-gate the STALE
    # tree, exit 0, and serve v1 while the operator watched a v2 upload succeed.
    mk_prebuilt "$E2E/prebuilt2" pb2 "UPLOADED-BYTES-pb2"
    rc="$(pb_deploy pb2 "$E2E/prebuilt2" "$SHA_B")"
    check "second prebuilt build goes live"           [ "$rc" = 0 ]
    mk_prebuilt "$PB" pb1 "UPLOADED-BYTES-pb1-v2"
    : > "$PSRC/.npm-calls"
    rc="$(pb_deploy pb1 "$PB" "$SHA_C")"
    check "re-upload exit 0"                          [ "$rc" = 0 ]
    check "re-upload did NOT take the already-staged arm" \
      pb_absent 'status=skipped build_id=pb1 detail="release pb1 is already staged"'
    check "re-upload RE-STAGED (STAGE ran, not skipped)" pb_saw STAGE ok pb1
    check "re-upload log names the digest MISMATCH it replaced" \
      pb_grep 'REPLACING the staged tree'
    check "the NEW uploaded bytes are live"           grep -q 'UPLOADED-BYTES-pb1-v2' "$PB_SITE/current/index.html"
    check "the STALE bytes are gone"                  sh -c "! grep -q 'UPLOADED-BYTES-pb1-v1' '$PB_SITE/current/index.html'"
    check "the marker now records the NEW digest" \
      [ "$(cat "$PB_SITE/releases/pb1/.bp-prebuilt-sha256" 2>/dev/null)" = "$SHA_C" ]
    check "the re-upload still ran no npm"            [ ! -s "$PSRC/.npm-calls" ]

    echo "[selftest] e2e: a HEALTH-failed PREBUILT release FAILS CLOSED (never a template rebuild)"
    mk_prebuilt "$E2E/prebuilt3" TOTALLY-WRONG "UPLOADED-BYTES-pb3"
    : > "$PSRC/.npm-calls"
    rc="$(pb_deploy pb3 "$E2E/prebuilt3" "$SHA_B")"
    check "lying prebuilt bytes exit 14"              [ "$rc" = 14 ]
    check "HEALTH failed"                             pb_saw HEALTH failed pb3
    check "its bytes are KEPT, not purged into a rebuild" [ -d "$PB_SITE/releases/pb3" ]
    check "it is marked health-failed"                [ -f "$PB_SITE/releases/pb3/.bp-health-failed" ]
    check "it KEEPS its prebuilt marker (the only record it was uploaded)" \
      [ -f "$PB_SITE/releases/pb3/.bp-prebuilt-sha256" ]
    check "the log says re-upload required"           pb_grep 're-upload required'
    check "the log does NOT promise a rebuild from source" pb_absent 'rebuilds from source'
    check "current unmoved (still pb1)"               [ "$(pb_livenow)" = releases/pb1 ]
    # And the redeploy WITHOUT an artifact refuses instead of rebuilding the
    # provisioned template — that rebuild passes HEALTH on genuine markers and
    # would put bytes nobody uploaded in front of users.
    : > "$PSRC/.npm-calls"
    rc="$(pb_deploy pb3)"
    check "redeploy with no artifact exits 11"        [ "$rc" = 11 ]
    check "PLAN failed (fail closed)"                 pb_saw PLAN failed pb3
    check "it names the RE-UPLOAD as the next move"   pb_grep 'RE-UPLOAD the artifact'
    check "the refusal ran no npm"                    [ ! -s "$PSRC/.npm-calls" ]
    check "current STILL unmoved (still pb1)"         [ "$(pb_livenow)" = releases/pb1 ]

    echo "[selftest] e2e: prebuilt bytes this box cannot NAME are refused"
    : > "$PSRC/.npm-calls"
    rc="$(pb_deploy pb4 "$PB" "not-a-digest")"
    check "a malformed PREBUILT_SHA256 exits 11"      [ "$rc" = 11 ]
    check "PLAN failed"                               pb_saw PLAN failed pb4
    check "no release dir left behind"                [ ! -d "$PB_SITE/releases/pb4" ]
    check "a missing PREBUILT_DIR tree exits 11" \
      sh -c "[ \"\$(env PATH='$FAKEBIN:$PATH' SITE_SLUG=prebuilt BUILD_ID=pb5 CONTENT_REV=rev-1 SITE_SRC='$PSRC' PREBUILT_DIR='$E2E/absent-prebuilt' PREBUILT_SHA256='$SHA_A' BARKPARK_SITES_DIR='$E2E/sites' BARKPARK_CADDYFILE='$E2E/absent-caddyfile' BARKPARK_SITE_DEPLOY_LOCK='$E2E/prebuilt.lock' BARKPARK_CADDYFILE_LOCK='$E2E/caddyfile.lock' BARKPARK_SITE_NO_CAP=1 bash '$SELF' >/dev/null 2>&1; echo \$?)\" = 11 ]"
    check "current unmoved after both refusals"       [ "$(pb_livenow)" = releases/pb1 ]

    echo "[selftest] e2e: the already-live no-op is DIGEST-AWARE for prebuilt bytes"
    # pb1 is live carrying SHA_C.  The build_id no-op is keyed on build_id, and
    # build_id does NOT determine prebuilt bytes — so a same-id upload of a
    # DIFFERENT digest must not exit 0 reporting "already live".
    mk_prebuilt "$E2E/prebuilt6" pb1 "UPLOADED-BYTES-pb1-v3"
    : > "$PSRC/.npm-calls"
    rc="$(pb_deploy pb1 "$E2E/prebuilt6" "$SHA_B")"
    check "a same-build_id upload of DIFFERENT bytes is refused (exit 11)" [ "$rc" = 11 ]
    check "PLAN failed, not noop"                     pb_saw PLAN failed pb1
    check "the refusal names a NEW deployment as the move" pb_grep 'mint a NEW deployment'
    check "the LIVE bytes are untouched"              grep -q 'UPLOADED-BYTES-pb1-v2' "$PB_SITE/current/index.html"
    check "the live release keeps its own digest" \
      [ "$(cat "$PB_SITE/releases/pb1/.bp-prebuilt-sha256" 2>/dev/null)" = "$SHA_C" ]
    check "the refusal ran no npm"                    [ ! -s "$PSRC/.npm-calls" ]
    # And re-uploading the SAME digest for the live build IS still a clean no-op.
    rc="$(pb_deploy pb1 "$PB" "$SHA_C")"
    check "a same-digest redeploy of the live build is a no-op (exit 0)" [ "$rc" = 0 ]
    check "PLAN noop"                                 pb_saw PLAN noop pb1

    # -----------------------------------------------------------------------
    # PREBUILT ROLLBACK.  The whole PREBUILT e2e above contains no occurrence of
    # rollback, RETIRE or .previous — the lane that CANNOT rebuild from source is
    # exactly the lane whose rollback nobody tested.  Three facts below, each
    # driven through the real verbs (--rollback / --rollback-preflight), never
    # read off the source.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: a PREBUILT release rolls BACK and FORWARD again, re-staging nothing"
    PRSRC="$E2E/prsrc"; PR_SITE="$E2E/sites/pbroll"
    mkdir -p "$PRSRC"
    printf '{"name":"selftest-pbroll","private":true}\n' > "$PRSRC/package.json"
    pr_deploy() { # <build_id> <prebuilt_dir> <sha256> -> exit code; stdout $E2E/pr.out
      env PATH="$FAKEBIN:$PATH" \
        SITE_SLUG=pbroll BUILD_ID="$1" CONTENT_REV=rev-1 SITE_SRC="$PRSRC" \
        PREBUILT_DIR="$2" PREBUILT_SHA256="$3" \
        BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$E2E/pbroll.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$E2E/pr.out" 2>&1
      echo $?
    }
    pr_verb() { # <--rollback|--rollback-preflight> <outfile> -> exit code
      env PATH="$FAKEBIN:$PATH" \
        SITE_SLUG=pbroll BARKPARK_SITES_DIR="$E2E/sites" \
        BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$E2E/pbroll.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" "$1" > "$2" 2>&1
      echo $?
    }
    pr_live() { readlink "$PR_SITE/current" 2>/dev/null || true; }

    mk_prebuilt "$E2E/pbroll1" pr1 "UPLOADED-pr1"
    mk_prebuilt "$E2E/pbroll2" pr2 "UPLOADED-pr2"
    rc="$(pr_deploy pr1 "$E2E/pbroll1" "$SHA_A")"
    check "pr1 (prebuilt) goes live"                  [ "$rc" = 0 ]
    rc="$(pr_deploy pr2 "$E2E/pbroll2" "$SHA_B")"
    check "pr2 (prebuilt) goes live"                  [ "$rc" = 0 ]
    check "live is pr2"                               [ "$(pr_live)" = releases/pr2 ]
    check "the prebuilt pr1 is now the rollback target" [ "$(cat "$PR_SITE/.previous")" = pr1 ]
    : > "$PRSRC/.npm-calls"
    rc="$(pr_verb --rollback "$E2E/pr.rb1")"
    check "rollback ONTO a prebuilt release exits 0"   [ "$rc" = 0 ]
    check "…and the uploaded pr1 bytes are what is served" \
      grep -q 'UPLOADED-pr1' "$PR_SITE/current/index.html"
    check "…and it names the target on the machine channel" grep -qx 'TARGET_BUILD=pr1' "$E2E/pr.rb1"
    check "A ROLLBACK RE-STAGES NOTHING (no STAGE stage on the wire at all)" \
      absent '^BPSTAGE name=STAGE' "$E2E/pr.rb1"
    check "…and ran no npm (a prebuilt box has no source to run)" [ ! -s "$PRSRC/.npm-calls" ]
    check "…and pr1 still carries the digest it was uploaded with" \
      [ "$(cat "$PR_SITE/releases/pr1/$PREBUILT_MARK" 2>/dev/null)" = "$SHA_A" ]
    check "…and .previous now points FORWARD at pr2"  [ "$(cat "$PR_SITE/.previous")" = pr2 ]
    rc="$(pr_verb --rollback "$E2E/pr.rb2")"
    check "rollback FROM a prebuilt release flips forward again" [ "$rc" = 0 ]
    check "…serving pr2's uploaded bytes"             grep -q 'UPLOADED-pr2' "$PR_SITE/current/index.html"
    check "…still no re-stage"                        absent '^BPSTAGE name=STAGE' "$E2E/pr.rb2"

    echo "[selftest] e2e: a health-failed PREBUILT target names RE-UPLOAD, and preflight AGREES with --rollback"
    # current=pr2, .previous=pr1.  Poison pr1 exactly as purge_failed_release
    # does for a prebuilt release — which it does UNCONDITIONALLY, so this is the
    # ORDINARY prebuilt failure state, not a corner.
    : > "$PR_SITE/releases/pr1/$HEALTH_FAIL_MARK"
    rc="$(pr_verb --rollback-preflight "$E2E/pr.pf1")"
    check "preflight REFUSES a poisoned target (21)"  [ "$rc" = 21 ]
    check "preflight prints NO TARGET_BUILD for a rollback that cannot happen" \
      absent '^TARGET_BUILD=' "$E2E/pr.pf1"
    rc="$(pr_verb --rollback "$E2E/pr.rb3")"
    check "the real rollback refuses it too (21) — the two verbs AGREE" [ "$rc" = 21 ]
    check "the refusal names RE-UPLOAD, the only move a prebuilt release has" \
      grep -q "RE-UPLOAD the artifact for build 'pr1'" "$E2E/pr.rb3"
    check "the PREBUILT arm never promises PLAN will rebuild it from source" \
      absent 'PLAN will rebuild it from source' "$E2E/pr.rb3"
    check "current unmoved by the refusal"            [ "$(pr_live)" = releases/pr2 ]
    # NEGATIVE CONTROL — the same poisoned target WITHOUT the prebuilt marker
    # still gets the rebuild remedy.  Without this row, "never says rebuild"
    # would also pass if the branch simply never fired.
    mv "$PR_SITE/releases/pr1/$PREBUILT_MARK" "$PR_SITE/releases/pr1/.stashed-mark"
    rc="$(pr_verb --rollback "$E2E/pr.rb4")"
    check "control: a BOX-BUILT poisoned target also exits 21" [ "$rc" = 21 ]
    check "control: and it DOES name the rebuild remedy (the branch discriminates)" \
      grep -q 'PLAN will rebuild it from source' "$E2E/pr.rb4"
    mv "$PR_SITE/releases/pr1/.stashed-mark" "$PR_SITE/releases/pr1/$PREBUILT_MARK"
    # AGREEMENT IN THE OTHER DIRECTION: a clean target must green on BOTH.
    rm -f "$PR_SITE/releases/pr1/$HEALTH_FAIL_MARK"
    rc="$(pr_verb --rollback-preflight "$E2E/pr.pf2")"
    check "preflight greens once the target is clean" [ "$rc" = 0 ]
    check "…and names pr1"                            grep -qx 'TARGET_BUILD=pr1' "$E2E/pr.pf2"
    rc="$(pr_verb --rollback "$E2E/pr.rb5")"
    check "and the real rollback then SUCCEEDS (agreement both ways)" [ "$rc" = 0 ]
    check "…now serving pr1"                          [ "$(pr_live)" = releases/pr1 ]

    # -----------------------------------------------------------------------
    # MUTATION TEST — a failed re-upload must not cost the rollback target.
    # The scenario is wave 9's own resume half: prebuilt pm1 live, pm2 live so
    # .previous = pm1, then the operator re-uploads --deployment pm1.  PLAN takes
    # the prebuilt arm, STAGE lands on releases/pm1 — and the copy fails.
    # Driven TWICE against IDENTICAL fixtures: once against a mutant that carries
    # the pre-fix `rm -rf "$RELDIR"` first line verbatim, once against this
    # script.  A one-sided run would prove nothing.
    # The copy fails for a REAL reason and genuinely runs: a `cp` ahead on PATH
    # copies real bytes into .partial and then exits 1 (an ENOSPC mid-copy on a
    # full /opt — the failure the exit-13 STAGE path exists for).  It is armed
    # only by BP_CP_FAIL_LOG and only for a `cp -a <src>/. <dst>.partial/`, and
    # it leaves a sentinel both arms assert on, so "the copy failed" can never be
    # "the copy never ran".
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: MUTATION — the pre-fix STAGE loses the rollback target, this one keeps it"
    MB="$E2E/mutbin"; mkdir -p "$MB"
    cat > "$MB/cp" <<'FAKECP'
#!/usr/bin/env bash
if [ -n "${BP_CP_FAIL_LOG:-}" ] && [ "$#" -eq 3 ] && [ "$1" = "-a" ]; then
  case "$3" in
    *.partial/)
      src="${2%/.}"
      /bin/cp -a "$src/index.html" "$3" 2>/dev/null
      printf 'fake cp ran: %s -> %s\n' "$src" "$3" >> "$BP_CP_FAIL_LOG"
      exit 1 ;;
  esac
fi
exec /bin/cp "$@"
FAKECP
    chmod +x "$MB/cp"

    MUT="$E2E/mutant/site-deploy.sh"
    # A mutant engine copy must find the shared lib it sources by its OWN dirname.
    mkdir -p "$E2E/mutant/lib"
    cp "$(cd "$(dirname "$SELF")" && pwd)/lib/site-deploy-common.sh" "$E2E/mutant/lib/"
    MUT_OLD='  rm -rf "$RELDIR" "$RELDIR.partial"'
    MUT_NEW='  rm -rf "$RELDIR.partial" "$RELDIR.aside"'
    # The mutation must APPLY, exactly once — awk exits 1 unless it replaced one
    # line, and the diff is asserted non-empty.  A silent no-op mutation produces
    # a green that means nothing.
    awk -v old="$MUT_NEW" -v new="$MUT_OLD" \
      '$0 == old { print new; n++; next } { print } END { if (n != 1) exit 1 }' \
      "$SELF" > "$MUT"; mut_rc=$?
    check "the mutation applied to EXACTLY ONE line"  [ "$mut_rc" = 0 ]
    check "the mutant genuinely differs from the script" sh -c "! cmp -s '$SELF' '$MUT'"
    check "the mutant carries the PRE-FIX destructive line" grep -qxF "$MUT_OLD" "$MUT"
    check "the mutant no longer carries the guarded line"   sh -c "! grep -qxF '$MUT_NEW' '$MUT'"

    MSRC="$E2E/mutsrc"; mkdir -p "$MSRC"
    printf '{"name":"selftest-mutsite","private":true}\n' > "$MSRC/package.json"
    mk_prebuilt "$E2E/mut-pm1" pm1 "UPLOADED-pm1-ORIGINAL"
    mk_prebuilt "$E2E/mut-pm2" pm2 "UPLOADED-pm2"
    mk_prebuilt "$E2E/mut-pm1b" pm1 "UPLOADED-pm1-REUPLOAD"
    mut_deploy() { # <script> <sitesdir> <build_id> <prebuilt_dir> <sha> [cp_fail_log]
      env PATH="$MB:$FAKEBIN:$PATH" \
        SITE_SLUG=mutsite BUILD_ID="$3" CONTENT_REV=rev-1 SITE_SRC="$MSRC" \
        PREBUILT_DIR="$4" PREBUILT_SHA256="$5" BP_CP_FAIL_LOG="${6:-}" \
        BARKPARK_SITES_DIR="$2" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$2/deploy.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$1" > "$2/out.log" 2>&1
      echo $?
    }
    mut_rollback() { # <script> <sitesdir> -> exit code
      env PATH="$MB:$FAKEBIN:$PATH" \
        SITE_SLUG=mutsite BARKPARK_SITES_DIR="$2" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$2/deploy.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$1" --rollback > "$2/rb.log" 2>&1
      echo $?
    }
    mut_scenario() { # <script> <sitesdir> -> echoes the FAILING re-upload's exit code
      mkdir -p "$2"
      mut_deploy "$1" "$2" pm1 "$E2E/mut-pm1" "$SHA_A" >/dev/null
      mut_deploy "$1" "$2" pm2 "$E2E/mut-pm2" "$SHA_B" >/dev/null
      # current=pm2, .previous=pm1.  Now the re-upload of pm1, with a copy that fails.
      mut_deploy "$1" "$2" pm1 "$E2E/mut-pm1b" "$SHA_C" "$2/cp.log"
    }

    OLDS="$E2E/mut-old"; NEWS="$E2E/mut-new"
    old_rc="$(mut_scenario "$MUT" "$OLDS")"
    new_rc="$(mut_scenario "$SELF" "$NEWS")"
    # Both arms reached the SAME failing line — otherwise the comparison below is
    # between two different experiments.
    check "mutant: the fixture set pm1 as the rollback target" [ "$(cat "$OLDS/mutsite/.previous")" = pm1 ]
    check "fixed:  the fixture set pm1 as the rollback target" [ "$(cat "$NEWS/mutsite/.previous")" = pm1 ]
    check "mutant: the failing re-upload exits 13 (STAGE failed)" [ "$old_rc" = 13 ]
    check "fixed:  the failing re-upload exits 13 too (same failure)" [ "$new_rc" = 13 ]
    check "mutant: the copy REALLY RAN and wrote bytes before failing" [ -s "$OLDS/cp.log" ]
    check "fixed:  the copy REALLY RAN and wrote bytes before failing" [ -s "$NEWS/cp.log" ]
    check "mutant: STAGE failed on the machine channel" \
      grep -q '^BPSTAGE name=STAGE status=failed build_id=pm1' "$OLDS/out.log"
    check "fixed:  STAGE failed on the machine channel" \
      grep -q '^BPSTAGE name=STAGE status=failed build_id=pm1' "$NEWS/out.log"
    # THE DEFECT, reproduced.
    check "MUTANT LOSES IT: releases/pm1 is GONE after the failed deploy" \
      [ ! -d "$OLDS/mutsite/releases/pm1" ]
    check "MUTANT LOSES IT: .previous still names the release it deleted" \
      [ "$(cat "$OLDS/mutsite/.previous")" = pm1 ]
    check "MUTANT LOSES IT: the rollback is now IMPOSSIBLE (21 no_previous)" \
      [ "$(mut_rollback "$MUT" "$OLDS")" = 21 ]
    # THE FIX, on the identical fixture.
    check "FIX KEEPS IT: releases/pm1 survived the failed deploy" \
      [ -d "$NEWS/mutsite/releases/pm1" ]
    check "FIX KEEPS IT: with its ORIGINAL uploaded bytes, not the failed upload's" \
      grep -q 'UPLOADED-pm1-ORIGINAL' "$NEWS/mutsite/releases/pm1/index.html"
    check "FIX KEEPS IT: and its ORIGINAL digest" \
      [ "$(cat "$NEWS/mutsite/releases/pm1/$PREBUILT_MARK" 2>/dev/null)" = "$SHA_A" ]
    check "FIX KEEPS IT: no .partial residue"     [ ! -e "$NEWS/mutsite/releases/pm1.partial" ]
    check "FIX KEEPS IT: no .aside residue"       [ ! -e "$NEWS/mutsite/releases/pm1.aside" ]
    check "FIX KEEPS IT: the rollback still WORKS (exit 0)" \
      [ "$(mut_rollback "$SELF" "$NEWS")" = 0 ]
    check "FIX KEEPS IT: and it serves the ORIGINAL pm1 bytes" \
      grep -q 'UPLOADED-pm1-ORIGINAL' "$NEWS/mutsite/current/index.html"
    check "the STAGE failure detail says the existing release is untouched" \
      grep -q 'is UNTOUCHED' "$NEWS/out.log"

    # -----------------------------------------------------------------------
    # DEEP PATH, THROUGH THE WHOLE ENGINE — the fixtures above drive health_gate
    # directly; this arm proves the probe is WIRED: a real uploaded dist whose
    # index.html links to an ACCENTED deep page goes live (exit 0, zero npm),
    # and then the SAME staged tree, with ONLY that directory's name mangled,
    # is refused at exit 14 with no SWITCH and the live symlink unmoved.
    # Its own slug and its own npm sentinel, so a regression here cannot be
    # masked by (or mask) the prebuilt slug's rows.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: a release whose LINKED accented deep page is missing is REFUSED (14), never switched"
    DPSRC="$E2E/dpsrc"; DP_SITE="$E2E/sites/deeppath"
    mkdir -p "$DPSRC"
    printf '{"name":"selftest-deeppath","private":true}\n' > "$DPSRC/package.json"
    dp_deploy() { # <build_id> [prebuilt_dir] [sha256] -> exit code; stdout at $E2E/dp.out
      env PATH="$FAKEBIN:$PATH" \
        SITE_SLUG=deeppath BUILD_ID="$1" CONTENT_REV=rev-1 SITE_SRC="$DPSRC" \
        PREBUILT_DIR="${2:-}" PREBUILT_SHA256="${3:-}" \
        BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$E2E/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$E2E/deeppath.lock" BARKPARK_CADDYFILE_LOCK="$E2E/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$E2E/dp.out" 2> "$E2E/dp.err"
      echo $?
    }
    dp_saw() { grep -q "^BPSTAGE name=$1 status=$2 build_id=$3" "$E2E/dp.out"; }
    dp_livenow() { readlink "$DP_SITE/current" 2>/dev/null || true; }
    # The artifact: the real content template's shape — base-prefixed,
    # root-relative, trailing-slash directory url, accented slug.
    ACC="$(printf 'caf\xc3\xa9')"                     # NFC "café", the href's bytes
    DPA="$E2E/dp-artifact"; rm -rf "$DPA"; mkdir -p "$DPA/d/$ACC"
    { printf '<!doctype html><html><head>'
      printf '<meta name="bp-build-id" content="dp1">'
      printf '<meta name="bp-content-rev" content="rev-1">'
      printf '<meta name="bp-doc-id" content="doc-42">'
      printf '<meta name="bp-site-base" content="/sites/deeppath/">'
      printf '</head><body><a href="/sites/deeppath/d/%s/">kaffe</a></body></html>' "$ACC"
    } > "$DPA/index.html"
    printf '<html><body>UPLOADED-DEEP-dp1</body></html>' > "$DPA/d/$ACC/index.html"
    : > "$DPSRC/.npm-calls"
    rc="$(dp_deploy dp1 "$DPA" "$SHA_A")"
    check "accented deep page present: deploy exit 0"   [ "$rc" = 0 ]
    check "HEALTH ok"                                   dp_saw HEALTH ok dp1
    check "SWITCH ok"                                   dp_saw SWITCH ok dp1
    check "current -> releases/dp1"                     [ "$(dp_livenow)" = releases/dp1 ]
    check "the box ran NO npm for it"                   [ ! -s "$DPSRC/.npm-calls" ]
    check "the log proves the DEEP page was fetched, percent-encoded" \
      grep -q 'deep path /d/caf%C3%A9/ serves 200' "$E2E/dp.out"
    # Park a second build live so dp1 is re-gateable (PLAN's staged arm), then
    # MUTATE ONLY the staged directory's name — the exact shape of a tar that
    # dropped the accented component. Nothing else about dp1 changes.
    mk_prebuilt "$E2E/dp-artifact2" dp2 "UPLOADED-dp2"
    rc="$(dp_deploy dp2 "$E2E/dp-artifact2" "$SHA_B")"
    check "a second build goes live so dp1 is no longer live" [ "$(dp_livenow)" = releases/dp2 ]
    mv "$DP_SITE/releases/dp1/d/$ACC" "$DP_SITE/releases/dp1/d/caf"
    : > "$DPSRC/.npm-calls"
    rc="$(dp_deploy dp1)"
    check "the mangled release exits 14"                [ "$rc" = 14 ]
    check "HEALTH failed"                               dp_saw HEALTH failed dp1
    check "no SWITCH stage line at all"                 sh -c "! grep -q '^BPSTAGE name=SWITCH ' '$E2E/dp.out'"
    check "current did NOT move (still dp2)"            [ "$(dp_livenow)" = releases/dp2 ]
    check "it was the DEEP page that failed, not index.html" \
      grep -q '\[site-deploy .*HEALTH: index.html links to /d/caf%C3%A9/' "$E2E/dp.out"
    check "index.html's own markers were FINE (no marker complaint)" \
      sh -c "! grep -q 'marker is' '$E2E/dp.out'"
    check "the refusal rides the BPSTAGE detail too (dual-channel)" \
      grep -qE '^BPSTAGE name=HEALTH status=failed build_id=dp1 detail="index.html links to /d/caf%C3%A9/ .* served HTTP [0-9]+, want 200\. Re-pack and re-upload; do not retry this artifact\. Cause: a tar dropped' "$E2E/dp.out"
    check "the re-gate ran no npm (it re-gated the STAGED bytes)" [ ! -s "$DPSRC/.npm-calls" ]
    check "every BPSTAGE name+status on the wire is still whitelisted (ROUTE excepted by design)" \
      sh -c "! grep '^BPSTAGE ' '$E2E/dp.out' | grep -v '^BPSTAGE name=ROUTE ' | grep -qvE '^BPSTAGE name=(PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE) status=(started|ok|skipped|noop|failed) build_id=[A-Za-z0-9._-]+( |\$)'"

    # -----------------------------------------------------------------------
    # ROUTE ARMING CAN REPORT FAILURE (engine-D77 applied to the arm direction).
    # Every case above runs with BARKPARK_CADDYFILE pointed at a file that does
    # not exist, so arm_caddy_site_route returns 0 out of its first guard and the
    # arm path has NEVER been exercised here. These two runs are the same site,
    # same bytes, differing ONLY in whether `caddy validate` accepts:
    #   accepting -> route armed, sign-off NAMES https://<host>/sites/<slug>/
    #   rejecting -> Caddyfile reverted, ROUTE failed on the machine channel, and
    #                the sign-off claims NO URL — still exit 0 (charter-D327).
    # On origin/main the rejecting run is indistinguishable from the accepting
    # one: `|| true` swallowed a return the function never made non-zero anyway.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: a REJECTED route arm reports ROUTE failed and stops advertising the URL (engine-D77)"
    RF="$E2E/routefail"; RFSRC="$RF/src"
    mkdir -p "$RF/okbin" "$RF/nobin" "$RFSRC"
    printf '{"name":"selftest-routefail","private":true}\n' > "$RFSRC/package.json"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$RF/okbin/caddy"
    printf '#!/usr/bin/env bash\ncase "$1" in validate) exit 1;; *) exit 0;; esac\n' > "$RF/nobin/caddy"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$RF/okbin/systemctl"
    cp "$RF/okbin/systemctl" "$RF/nobin/systemctl"
    chmod +x "$RF/okbin/"* "$RF/nobin/"*
    rf_caddyfile() { # <path> — a live FQDN block with the slot anchor, no marker
      { printf 'example.com {\n'
        printf '\treverse_proxy localhost:4000\n'
        printf '}\n'; } > "$1"
    }
    rf_deploy() { # <bindir> <build_id> <caddyfile> <outfile> -> exit code
      env PATH="$1:$FAKEBIN:$PATH" \
        SITE_SLUG=routefail BUILD_ID="$2" CONTENT_REV=rev-1 SITE_SRC="$RFSRC" \
        BARKPARK_HEALTH_HOST=sites.example.com \
        BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$3" \
        BARKPARK_SITE_DEPLOY_LOCK="$RF/deploy.lock" BARKPARK_CADDYFILE_LOCK="$RF/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$4" 2> "$4.err"
      echo $?
    }
    # (a) the CONTROL: caddy accepts, so the route really is armed.
    rf_caddyfile "$RF/Caddyfile.ok"
    rc="$(rf_deploy "$RF/okbin" rf1 "$RF/Caddyfile.ok" "$RF/ok.out")"
    check "armed run exits 0"                            [ "$rc" = 0 ]
    check "armed run really wrote the marker into the Caddyfile" \
      grep -q 'BARKPARK_SITE_ROUTE:routefail' "$RF/Caddyfile.ok"
    # The engine's own release-root markers live INSIDE the served tree, so an
    # un-hidden file_server discloses the artifact digest and — worse — that the
    # LIVE release is one this engine already knows failed its health gate.
    check "the armed file_server HIDES the prebuilt digest marker" \
      grep -qE 'hide .*\.bp-prebuilt-sha256' "$RF/Caddyfile.ok"
    check "the armed file_server HIDES the health-failed marker" \
      grep -qE 'hide .*\.bp-health-failed' "$RF/Caddyfile.ok"
    check "the hide rides INSIDE a file_server block, not loose in the site" \
      grep -qE 'file_server \{' "$RF/Caddyfile.ok"
    check "the armed Caddyfile is still brace-balanced with the nested block" \
      bash -c "[ \$(grep -c '{' '$RF/Caddyfile.ok') = \$(grep -c '}' '$RF/Caddyfile.ok') ]"
    check "armed run emits NO ROUTE failure"             absent '^BPSTAGE name=ROUTE status=failed' "$RF/ok.out"
    # D346: the SUCCESS path speaks on the durable channel too. Before this, an
    # arm outcome only ever reached the operator through log() — stdout, which
    # nothing persists — so `route already armed` appeared ZERO times across
    # 1,178 durable .log files on guerrilla although it MUST fire on every
    # re-deploy of an already-armed site (astro-search alone: 244). The zero was
    # vacuous, not healthy.
    check "armed run emits ROUTE ok on the DURABLE machine channel (not just stdout)" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=rf1 detail="armed: ' "$RF/ok.out"
    check "…and that detail names WHICH outcome and where it wrote" \
      grep -qE '^BPSTAGE name=ROUTE status=ok build_id=rf1 detail="armed: this run wrote the BARKPARK_SITE_ROUTE:routefail handle into .*Caddyfile\.ok' "$RF/ok.out"
    # THE RE-DEPLOY: the marker is now in the file, so this run takes the
    # already-armed branch — the branch that fired 244 times and said nothing.
    rc="$(rf_deploy "$RF/okbin" rf1b "$RF/Caddyfile.ok" "$RF/ok2.out")"
    check "a RE-deploy over an armed route exits 0"      [ "$rc" = 0 ]
    check "the already-armed branch is now VISIBLE on the durable channel" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=rf1b detail="already armed: ' "$RF/ok2.out"
    check "…and it says the deploy left Caddy untouched" \
      grep -q 'left Caddy untouched' "$RF/ok2.out"
    check "the re-deploy still advertises the public URL (the route really is armed)" \
      grep -q "HEALTHY — 'routefail' live at build rf1b (https://sites.example.com/sites/routefail/)" "$RF/ok2.out"
    check "armed run DOES advertise the public URL" \
      grep -q "HEALTHY — 'routefail' live at build rf1 (https://sites.example.com/sites/routefail/)" "$RF/ok.out"
    # (b) THE CASE: same engine, same bytes, a caddy that rejects. The marker
    #     guard makes arming a FIRST-deploy-only step, so this needs a fresh
    #     Caddyfile — which is exactly the real shape (a first deploy into a
    #     Caddyfile another writer left invalid).
    rf_caddyfile "$RF/Caddyfile.bad"
    cp "$RF/Caddyfile.bad" "$RF/Caddyfile.bad.orig"
    rc="$(rf_deploy "$RF/nobin" rf2 "$RF/Caddyfile.bad" "$RF/bad.out")"
    check "rejected arm STILL exits 0 (charter-D327: report, do not fail a healthy build)" \
      [ "$rc" = 0 ]
    check "rejected arm left the Caddyfile byte-identical (reverted)" \
      cmp -s "$RF/Caddyfile.bad" "$RF/Caddyfile.bad.orig"
    check "rejected arm speaks a ROUTE failure on the machine channel" \
      grep -q '^BPSTAGE name=ROUTE status=failed build_id=rf2 detail="' "$RF/bad.out"
    check "the ROUTE failure ALSO rides the plain human log (dual-channel)" \
      grep -q '\[site-deploy .*ROUTE: the caddy /sites/routefail route is NOT ARMED' "$RF/bad.out"
    check "it names the URL that would 404 and the file to fix" \
      grep -q 'https://sites.example.com/sites/routefail/ will 404' "$RF/bad.out"
    check "rejected arm STOPS advertising the public URL in the sign-off" \
      absent "live at build rf2 (https://" "$RF/bad.out"
    check "the sign-off says the bytes are live on disk but the route is not armed" \
      grep -q "HEALTHY ON DISK — 'routefail' build rf2 is the current release, but its public route is NOT ARMED" "$RF/bad.out"
    check "the release still went live on disk (the flip is independent of Caddy)" \
      [ "$(readlink "$E2E/sites/routefail/current" 2>/dev/null)" = releases/rf2 ]
    check "SWITCH still ok"                              grep -q '^BPSTAGE name=SWITCH status=ok build_id=rf2' "$RF/bad.out"

    # -----------------------------------------------------------------------
    # (c) THE ARM'S LOCK-NEVER-TAKEN BRANCH. `with_caddy_lock` returns 1 out of
    #     its OWN guard, so arm_caddy_site_route is never entered and the route's
    #     state is UNKNOWN to this run — a DIFFERENT claim from (b)'s "tried, was
    #     rejected, reverted". The teardown direction has had this row since D77
    #     ("lock-starved teardown says the route was NEVER CHECKED"); the arm
    #     direction inherited the MESSAGE at the flip site but never the test, so
    #     collapsing the arm's two non-zero details into one string was invisible.
    #     Same fixture as the teardown's: a flock that grants the non-blocking
    #     DEPLOY lock (`flock -n 9`, whose refusal is the separate exit 23) and
    #     refuses the WAITING Caddyfile lock (`flock -w 120 8`).
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: an arm whose Caddyfile lock is NEVER TAKEN says UNKNOWN, not NOT ARMED (engine-D77, arm direction)"
    mkdir -p "$RF/lockbin"
    cp "$RF/okbin/caddy" "$RF/okbin/systemctl" "$RF/lockbin/"
    printf '#!/usr/bin/env bash\ncase "$1" in -w) exit 1;; *) exit 0;; esac\n' > "$RF/lockbin/flock"
    chmod +x "$RF/lockbin/"*
    # NB: NOT `Caddyfile.lock` — rf_deploy pins BARKPARK_CADDYFILE_LOCK to
    # "$RF/caddyfile.lock", and on a case-INSENSITIVE filesystem (macOS APFS by
    # default) that is the SAME inode: `exec 8>"$CADDY_LOCK"` would truncate the
    # fixture Caddyfile, and this block would red on a platform difference
    # instead of on the branch it exists to pin.
    rf_caddyfile "$RF/Caddyfile.locked"
    cp "$RF/Caddyfile.locked" "$RF/Caddyfile.locked.orig"
    rc="$(rf_deploy "$RF/lockbin" rf3 "$RF/Caddyfile.locked" "$RF/lock.out")"
    check "lock-starved arm STILL exits 0 (a lock we could not take must not fail a healthy build)" \
      [ "$rc" = 0 ]
    check "lock-starved arm speaks a ROUTE failure on the machine channel" \
      grep -q '^BPSTAGE name=ROUTE status=failed build_id=rf3 detail="' "$RF/lock.out"
    check "lock-starved arm says the route was NEVER CHECKED" \
      grep -q 'NEVER CHECKED' "$RF/lock.out"
    check "lock-starved arm does NOT claim it tried and was rejected (it never read the file)" \
      absent 'this run tried to add it' "$RF/lock.out"
    check "lock-starved arm left the Caddyfile byte-identical (never opened)" \
      cmp -s "$RF/Caddyfile.locked" "$RF/Caddyfile.locked.orig"
    check "lock-starved arm wrote NO route marker" \
      absent 'BARKPARK_SITE_ROUTE:routefail' "$RF/Caddyfile.locked"
    check "lock-starved arm STOPS advertising the public URL in the sign-off" \
      absent "live at build rf3 (https://" "$RF/lock.out"
    check "lock-starved arm still switched the release live on disk" \
      grep -q '^BPSTAGE name=SWITCH status=ok build_id=rf3' "$RF/lock.out"

    # -----------------------------------------------------------------------
    # (d) THE ARM'S AWK/MV REVERT ARM. (b) drives the `caddy validate` revert;
    #     this drives the OTHER one — the Caddyfile could not be REWRITTEN at all
    #     (full /tmp, read-only fs, ENOSPC), so the `awk … > "$tmp" && mv` chain
    #     short-circuits, the backup goes back and the function returns 2 WITHOUT
    #     caddy ever being consulted. Both arms end in the same NOT ARMED detail,
    #     which is why the distinguishing assertion is the log line only this arm
    #     writes. Fixture: the zero-arg `mktemp` stub (see the teardown block
    #     above for why that targets exactly the two Caddyfile rewriters).
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: an arm whose Caddyfile REWRITE fails reverts, reports NOT ARMED, and never consults caddy"
    mkdir -p "$RF/mvbin"
    cp "$RF/okbin/caddy" "$RF/okbin/systemctl" "$RF/mvbin/"
    printf '#!/usr/bin/env bash\nif [ "$#" = 0 ]; then echo "%s/no-such-dir/tmp"; exit 0; fi\nif [ -x /usr/bin/mktemp ]; then exec /usr/bin/mktemp "$@"; fi\nexec /bin/mktemp "$@"\n' "$RF" > "$RF/mvbin/mktemp"
    chmod +x "$RF/mvbin/"*
    rf_caddyfile "$RF/Caddyfile.mv"
    cp "$RF/Caddyfile.mv" "$RF/Caddyfile.mv.orig"
    rc="$(rf_deploy "$RF/mvbin" rf4 "$RF/Caddyfile.mv" "$RF/mv.out")"
    check "un-rewritable arm STILL exits 0 (charter-D327: report, do not fail a healthy build)" \
      [ "$rc" = 0 ]
    check "un-rewritable arm names the REWRITE as what failed, not caddy validate" \
      grep -q 'could not rewrite .* for the /sites/routefail arm — restoring the backup' "$RF/mv.out"
    check "un-rewritable arm reports ROUTE failed on the machine channel" \
      grep -q '^BPSTAGE name=ROUTE status=failed build_id=rf4 detail="' "$RF/mv.out"
    check "un-rewritable arm left the Caddyfile byte-identical (the backup was restored)" \
      cmp -s "$RF/Caddyfile.mv" "$RF/Caddyfile.mv.orig"
    check "un-rewritable arm left no .bak.site turd beside the Caddyfile" \
      sh -c "! ls '$RF'/Caddyfile.mv.bak.site.* >/dev/null 2>&1"
    check "un-rewritable arm wrote NO route marker" \
      absent 'BARKPARK_SITE_ROUTE:routefail' "$RF/Caddyfile.mv"
    check "un-rewritable arm STOPS advertising the public URL in the sign-off" \
      absent "live at build rf4 (https://" "$RF/mv.out"
    check "un-rewritable arm still switched the release live on disk" \
      grep -q '^BPSTAGE name=SWITCH status=ok build_id=rf4' "$RF/mv.out"
    # The ROUTE line is deliberately OUTSIDE DeployRunner's @stage_names
    # whitelist (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE): parse_stage_line/2 skips
    # it, so it can never reach stage_exit_code/1 and flip a green run to -1.
    # That is what keeps this a REPORT and not a verdict change.
    RUNNER_EX="$(cd "$(dirname "$SELF")/.." && pwd)/api/lib/barkpark/sites/deploy_runner.ex"
    if [ ! -f "$RUNNER_EX" ]; then
      # Same reasoning as the e2e/flock skips: this block is the ONLY thing in
      # either engine asserting that the CONSUMER of the wire (DeployRunner)
      # still refuses to fold ROUTE into a verdict. Extract deploy/ alone — the
      # `git archive origin/main deploy | tar -x` recipe does exactly this — and
      # the rows vanish and the suite still prints PASS at a LOWER total, which
      # is how a 322/322 run gets misread as "three rows were removed". Say so.
      if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
        echo "[selftest] FAIL - the DeployRunner @stage_names proofs are REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but $RUNNER_EX is missing — this engine was extracted without api/, so the only assertion that ROUTE stays OUTSIDE the runner's whitelist did not run; a skipped doctrine proof must not report PASS"
        exit 1
      fi
      echo "[selftest] SKIP DeployRunner @stage_names doctrine (ROUTE stays a report) — needs api/lib/barkpark/sites/deploy_runner.ex in the tree"
    else
      check "DeployRunner's @stage_names still has no ROUTE arm (the report cannot flip a verdict)" \
        sh -c "! grep -q '^  @stage_names .*ROUTE' '$RUNNER_EX'"
      check "…and that whitelist is still the six this engine folds" \
        grep -q '^  @stage_names ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)' "$RUNNER_EX"
    fi
    check "every OTHER BPSTAGE name+status on the wire is still whitelisted" \
      sh -c "! grep '^BPSTAGE ' '$RF/bad.out' | grep -v '^BPSTAGE name=ROUTE ' | grep -qvE '^BPSTAGE name=(PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE) status=(started|ok|skipped|noop|failed) build_id=[A-Za-z0-9._-]+( |\$)'"

    # -----------------------------------------------------------------------
    # A MISS ON A SPAWNED STATIC SITE IS A 404, NOT THE MAINTENANCE 503
    # (ssw11-bl-static-miss-503-not-404). Measured on guerrilla from outside:
    # /sites/<slug>/nope-missing/ answered 503, an accented miss answered 503,
    # and the NFC form of an NFD-stored directory answered 503 — so the Unicode
    # seam this epic cares about was INDISTINGUISHABLE from every other miss.
    #
    # THE CAUSE, read off the box's own Caddyfile rather than inferred from the
    # status code: the FQDN site block ends with the maintenance handler
    # deploy/instance-deploy.sh arms —
    #
    #     reverse_proxy localhost:4001
    #     handle_errors {
    #         header Retry-After "15"
    #         respond 503 { body <<BARKPARK_MAINTENANCE … }
    #     }
    #
    # `handle_errors` with NO status list catches EVERY error raised anywhere in
    # the site, and a `file_server` miss inside this engine's own armed
    # `handle_path /sites/<slug>/*` raises 404 AS AN ERROR. So the branded "Back
    # in a moment" page ate the entire 4xx surface of every static site on the
    # box. The block's header comment asserted the opposite — "fires ONLY on
    # errors Caddy itself raises (dial failure / gateway timeout)" — which is
    # true and irrelevant: a file_server 404 IS an error Caddy itself raises.
    #
    # The fix is `handle_errors 502 503 504` in instance-deploy.sh. This block
    # is the REGRESSION PIN, and it pins the SEAM rather than either half: it
    # takes the site route THIS engine generated (Caddyfile.ok, written by the
    # real arm above), splices in the maintenance handler INSTANCE-DEPLOY.SH
    # ITSELF arms (extracted from that file, never re-typed here), and drives the
    # result through a REAL caddy on a real port with real requests. Re-widen
    # either side and rows 4/5/6 go red.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: a miss on a spawned static site 404s through REAL caddy (the maintenance 503 no longer eats it)"
    MS="$E2E/misscode"; mkdir -p "$MS/bin" "$MS/root"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MS/bin/systemctl"; chmod +x "$MS/bin/systemctl"
    printf '<!doctype html><title>index</title>\n' > "$MS/root/index.html"
    MS_INSTANCE="$(cd "$(dirname "$SELF")" && pwd)/instance-deploy.sh"
    if ! command -v caddy >/dev/null 2>&1 || [ ! -f "$MS_INSTANCE" ]; then
      if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
        echo "[selftest] FAIL - the static-miss 404 proof is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but a real caddy binary and deploy/instance-deploy.sh are both needed and one is missing — the only rows that drive a real Caddy did not run"
        exit 1
      fi
      echo "[selftest] SKIP static-miss 404 through real caddy — needs a real caddy(1) and deploy/instance-deploy.sh in the tree"
    else
      # The maintenance handler EXACTLY as instance-deploy.sh arms it: the
      # heredoc body between `<<'MAINT'` and the closing MAINT sentinel.
      awk "/<<'MAINT'/{f=1;next} /^MAINT\$/{f=0} f" "$MS_INSTANCE" > "$MS/maint.caddy"
      check "the maintenance handler instance-deploy.sh arms was extracted (non-empty)" \
        [ -s "$MS/maint.caddy" ]
      check "…and it is STATUS-SCOPED, so a file_server 404 is not one of its errors" \
        grep -qE '^[[:space:]]*handle_errors[[:space:]]+502[[:space:]]+503[[:space:]]+504[[:space:]]*\{' "$MS/maint.caddy"
      check "the reference copy deploy/caddy/barkpark-maintenance.caddy carries the same scoping" \
        sh -c "[ ! -f '$(cd "$(dirname "$SELF")" && pwd)/caddy/barkpark-maintenance.caddy' ] || grep -qE '^handle_errors +502 +503 +504 *\{' '$(cd "$(dirname "$SELF")" && pwd)/caddy/barkpark-maintenance.caddy'"
      # Build the BOX SHAPE: global opts, this engine's real armed handle_path
      # (root repointed at a fixture tree), a DEAD app fallback, then the
      # maintenance handler — the exact nesting /etc/caddy/Caddyfile has.
      MS_PORT=0; MS_PID=""
      for MS_TRY in 39211 39307 39419 39523 39631; do
        {
          printf '{\n\tadmin off\n\tauto_https off\n}\n'
          printf ':%s {\n' "$MS_TRY"
          sed -n '/BARKPARK_SITE_ROUTE:routefail/,/^\t}$/p' "$RF/Caddyfile.ok" \
            | sed "s|root \* .*|root * $MS/root|"
          printf '\treverse_proxy localhost:1 {\n\t\tlb_try_duration 1s\n\t}\n'
          cat "$MS/maint.caddy"
          printf '}\n'
        } > "$MS/Caddyfile"
        caddy run --config "$MS/Caddyfile" --adapter caddyfile >"$MS/caddy.log" 2>&1 &
        MS_PID=$!
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          if [ "$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$MS_TRY/sites/routefail/" 2>/dev/null)" = 200 ]; then
            MS_PORT="$MS_TRY"; break
          fi
          sleep 0.25
        done
        [ "$MS_PORT" != 0 ] && break
        kill "$MS_PID" 2>/dev/null; wait "$MS_PID" 2>/dev/null; MS_PID=""
      done
      ms_code() { curl -s -o "$MS/body.out" --max-time 5 -w '%{http_code}' "http://127.0.0.1:$MS_PORT$1"; }
      check "the box-shaped fixture (engine site route + armed maintenance handler) came up on a real caddy" \
        [ "$MS_PORT" != 0 ]
      check "real caddy: the static site index serves 200" \
        [ "$(ms_code /sites/routefail/)" = 200 ]
      check "real caddy: a MISSING ASCII path is 404, NOT the maintenance 503" \
        [ "$(ms_code /sites/routefail/nope-missing/)" = 404 ]
      check "real caddy: a MISSING ACCENTED path is 404, NOT the maintenance 503" \
        [ "$(ms_code /sites/routefail/bl%C3%A5b%C3%A6r/)" = 404 ]
      ms_code /sites/routefail/nope-missing/ >/dev/null
      check "real caddy: the miss body is not the branded maintenance page" \
        sh -c "! grep -q 'Back in a moment' '$MS/body.out'"
      check "real caddy: a DEAD app upstream STILL gets the maintenance 503 (the scoping did not disarm it)" \
        [ "$(ms_code /anything-the-app-owns)" = 503 ]
      check "…and THAT body really is the branded maintenance page" \
        grep -q 'Back in a moment' "$MS/body.out"
      [ -n "$MS_PID" ] && { kill "$MS_PID" 2>/dev/null; wait "$MS_PID" 2>/dev/null; }
    fi

    # -----------------------------------------------------------------------
    # THE PREFIX COLLISION (D345) — the case NO test in either engine could see.
    #
    # LIVE SHAPE, reproduced: `search` is a strict PREFIX of `search-capstone`.
    # On origin/main the arm's already-armed guard is a BARE substring grep, so
    # the SECOND site here matches the FIRST site's marker, logs "route already
    # armed", returns 0 WITHOUT WRITING, and the run signs off SWITCH ok + exit 0
    # + a public URL over a 404. That is 208 real deploys of one live site.
    #
    # BOTH DIRECTIONS ARE ASSERTED, because this predicate governs the arm, the
    # disarm and the port flip of EVERY live site's public route — a predicate
    # that is too strict silently UN-ARMS the nine sites that work today:
    #   (a) the prefix slug arms ITS OWN block despite the sibling's marker
    #   (b) the exact slug still matches its own marker on a re-deploy
    #   (c) the sibling's block is untouched (this is an ADD, not a rewrite)
    # `grep -qw` passes NONE of these: `-w` treats `-` as a non-word character,
    # so `…:pfx` still word-matches `…:pfx-capstone`.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: a slug that is a strict PREFIX of an armed slug arms its OWN route (D345)"
    PX="$E2E/prefix"; PXSRC="$PX/src"
    mkdir -p "$PX/bin" "$PXSRC"
    printf '{"name":"selftest-prefix","private":true}\n' > "$PXSRC/package.json"
    cp "$RF/okbin/caddy" "$RF/okbin/systemctl" "$PX/bin/"
    chmod +x "$PX/bin/"*
    rf_caddyfile "$PX/Caddyfile"
    px_deploy() { # <slug> <build_id> <outfile> -> exit code
      env PATH="$PX/bin:$FAKEBIN:$PATH" \
        SITE_SLUG="$1" BUILD_ID="$2" CONTENT_REV=rev-1 SITE_SRC="$PXSRC" \
        BARKPARK_HEALTH_HOST=sites.example.com \
        BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$PX/Caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$PX/deploy.lock" BARKPARK_CADDYFILE_LOCK="$PX/caddyfile.lock" \
        BARKPARK_SITE_STATUS_FILE="$PX/$2.status" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$3" 2> "$3.err"
      echo $?
    }
    px_markers() { grep -c 'BARKPARK_SITE_ROUTE:' "$PX/Caddyfile" | tr -d ' '; }
    # (1) the LONGER slug arms first — this is the sibling that swallowed the
    #     prefix site's identity on the live box.
    rc="$(px_deploy pfx-capstone px1 "$PX/long.out")"
    check "prefix: the LONGER sibling arms first (exit 0)"   [ "$rc" = 0 ]
    check "prefix: one marker in the Caddyfile so far"       [ "$(px_markers)" = 1 ]
    # (2) THE CASE. The prefix slug deploys into a Caddyfile that already carries
    #     the sibling's marker. On the unpatched predicate this run REDS every
    #     assertion below: no marker is written, ROUTE says already-armed, and
    #     https://…/sites/pfx/ is a 404 the engine advertises anyway.
    rc="$(px_deploy pfx px2 "$PX/short.out")"
    check "prefix: the PREFIX slug's deploy exits 0"         [ "$rc" = 0 ]
    check "prefix: it ARMED ITS OWN route (a SECOND marker exists)" \
      [ "$(px_markers)" = 2 ]
    check "prefix: the Caddyfile really carries the prefix slug's own marker" \
      grep -qE 'BARKPARK_SITE_ROUTE:pfx([[:space:]]|$)' "$PX/Caddyfile"
    check "prefix: ROUTE reports ARMED, not already-armed (the durable channel)" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=px2 detail="armed: ' "$PX/short.out"
    # DURABILITY, asserted where it actually matters (D346). stdout is NOT the
    # record: on a real box the .log holds raw npm child output and the .status
    # fold holds BPSTAGE lines — which is exactly why `route already armed`
    # appeared ZERO times in 1,178 durable .log files while firing hundreds of
    # times. The ROUTE line must survive INTO the status fold, or this whole
    # report is invisible again the moment the process exits.
    check "prefix: the ROUTE line lands in the DURABLE .status fold, not just stdout" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=px2 detail="armed: ' "$PX/px2.status"
    check "prefix: it did NOT claim the sibling's route was already its own" \
      sh -c "! grep -q 'already armed' '$PX/short.out'"
    check "prefix: its handle points at ITS OWN release tree, not the sibling's" \
      grep -q "root \* $E2E/sites/pfx/current" "$PX/Caddyfile"
    check "prefix: the sibling's own handle is untouched (an ADD, not a rewrite)" \
      grep -q "root \* $E2E/sites/pfx-capstone/current" "$PX/Caddyfile"
    check "prefix: the run advertises the URL it actually armed" \
      grep -q "HEALTHY — 'pfx' live at build px2 (https://sites.example.com/sites/pfx/)" "$PX/short.out"
    # (3) THE REVERSE DIRECTION — the blast-radius guard. A predicate strict
    #     enough to reject a sibling must still match a site's OWN marker, or it
    #     silently re-arms (duplicating) every already-working site.
    rc="$(px_deploy pfx px3 "$PX/short2.out")"
    check "prefix/reverse: an EXACT re-deploy still matches its own marker"  [ "$rc" = 0 ]
    check "prefix/reverse: no THIRD marker was written (no duplicate route)" \
      [ "$(px_markers)" = 2 ]
    check "prefix/reverse: ROUTE says already-armed for the exact slug" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=px3 detail="already armed: ' "$PX/short2.out"
    check "prefix/reverse: the already-armed decision is DURABLE too (.status fold)" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=px3 detail="already armed: ' "$PX/px3.status"
    rc="$(px_deploy pfx-capstone px4 "$PX/long2.out")"
    check "prefix/reverse: the LONGER slug also still matches its own marker" \
      grep -q '^BPSTAGE name=ROUTE status=ok build_id=px4 detail="already armed: ' "$PX/long2.out"
    check "prefix/reverse: still exactly two markers after four deploys" \
      [ "$(px_markers)" = 2 ]
    # (3b) THE DELIMITER CLASS ITSELF, asserted directly on the predicate rather
    #      than through a deploy — because the dangerous direction is a marker
    #      this script did NOT write. Everything arm_caddy_site_route emits has a
    #      SPACE after the slug, so a whitespace-only predicate would look green
    #      forever here while reading a HAND-EDITED `…:<slug>:` marker in a live
    #      Caddyfile as NOT ARMED and re-arming a working route into a duplicate
    #      handle. The delimiter is therefore "any character a slug cannot
    #      contain" ([^a-z0-9-]), which is what makes it right in BOTH
    #      directions: it accepts every real delimiter and still rejects the only
    #      thing a sibling slug can continue with.
    echo "[selftest] the marker delimiter is 'not a slug character', not merely whitespace (D345)"
    mrk() { # <slug> <line> -> 0 if the predicate says "this line is that slug's marker"
      # ${SITE_SLUG:-}: the selftest runs with `set -u` and no slug of its own —
      # the deploy path is what sets this global.
      local __save="${SITE_SLUG:-}" __rc=0
      printf '%s\n' "$2" > "$PX/mrk.txt"
      SITE_SLUG="$1"; has_site_route_marker "$PX/mrk.txt" || __rc=$?
      SITE_SLUG="$__save"; return "$__rc"
    }
    check "delimiter: a space after the slug matches (what this script writes)" \
      mrk search '# BARKPARK_SITE_ROUTE:search — static site'
    check "delimiter: end-of-line matches" \
      mrk search '# BARKPARK_SITE_ROUTE:search'
    check "delimiter: a hand-edited ':' after the slug STILL reads as armed (no duplicate re-arm)" \
      mrk search '# BARKPARK_SITE_ROUTE:search: static site'
    check "delimiter: a hand-edited '#' after the slug STILL reads as armed" \
      mrk search '# BARKPARK_SITE_ROUTE:search#1'
    if mrk search '# BARKPARK_SITE_ROUTE:search-capstone — static site'; then
      check "delimiter: a PREFIX sibling ('-') is REJECTED" false
    else
      check "delimiter: a PREFIX sibling ('-') is REJECTED" true
    fi
    if mrk search '# BARKPARK_SITE_ROUTE:search2 — static site'; then
      check "delimiter: an alnum-extended sibling is REJECTED" false
    else
      check "delimiter: an alnum-extended sibling is REJECTED" true
    fi
    # (4) DISARM is the same predicate, in its most destructive direction: a bare
    #     substring would excise the SIBLING's live block on this site's teardown.
    env PATH="$PX/bin:$FAKEBIN:$PATH" \
      SITE_SLUG=pfx BARKPARK_SITES_DIR="$E2E/sites" BARKPARK_CADDYFILE="$PX/Caddyfile" \
      BARKPARK_SITE_DEPLOY_LOCK="$PX/deploy.lock" BARKPARK_CADDYFILE_LOCK="$PX/caddyfile.lock" \
      BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" --teardown > "$PX/down.out" 2>&1
    check "prefix/disarm: the prefix slug's own block is gone" \
      sh -c "! grep -qE 'BARKPARK_SITE_ROUTE:pfx([[:space:]]|\$)' '$PX/Caddyfile'"
    check "prefix/disarm: the SIBLING's block SURVIVED the prefix teardown" \
      grep -qE 'BARKPARK_SITE_ROUTE:pfx-capstone([[:space:]]|$)' "$PX/Caddyfile"
    check "prefix/disarm: the sibling still proxies its own release tree" \
      grep -q "root \* $E2E/sites/pfx-capstone/current" "$PX/Caddyfile"

    # -----------------------------------------------------------------------
    # AN ALREADY-ARMED BLOCK IS UPGRADED TO HIDE THE RELEASE MARKERS
    # (task-5d7bb5b283ac27d0). The three "the armed file_server HIDES …" rows
    # above pin what a FRESH arm emits — and that is ALL they pin. The arm is
    # marker-guarded, so a block armed BEFORE the hide landed keeps its bare
    # `file_server` on every subsequent deploy, forever. Measured read-only on
    # guerrilla 157.180.90.121 (2026-09-03, `cat /etc/caddy/Caddyfile`): all FOUR
    # armed STATIC blocks (the other six site routes are node reverse_proxy
    # blocks, no file_server) are that pre-hide shape, so .bp-prebuilt-sha256 and
    # .bp-health-failed are fetchable over HTTPS on every live static site.
    #
    # This block is the REGRESSION PIN for the in-place UPGRADE branch, and it
    # pins the OUTCOME, not the text: a pre-hide Caddyfile (marker present, bare
    # file_server) plus a real release tree carrying both markers is driven
    # through the REAL engine and then through a REAL caddy on a real port with
    # real requests. Remove the upgrade branch and rows "…is upgraded in place",
    # "…returns 404" and "…returns 404 too" go red BY NAME while the index row
    # stays green — the marker guard alone cannot tell the two shapes apart.
    # -----------------------------------------------------------------------
    echo "[selftest] e2e: an already-armed PRE-HIDE static block is upgraded in place and its markers stop being fetchable (REAL caddy)"
    HU="$E2E/hideup"; HUSRC="$HU/src"
    mkdir -p "$HU/bin" "$HUSRC"
    printf '{"name":"selftest-hideup","private":true}\n' > "$HUSRC/package.json"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HU/bin/systemctl"
    chmod +x "$HU/bin/systemctl"
    if ! command -v caddy >/dev/null 2>&1; then
      if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
        echo "[selftest] FAIL - the already-armed hide UPGRADE proof is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but there is no real caddy(1) on PATH — a fake caddy validates nothing and serves nothing, so the only rows that prove the markers actually stop being fetchable did not run"
        exit 1
      fi
      echo "[selftest] SKIP already-armed hide upgrade — needs a REAL caddy(1) on PATH"
    else
      HUROOT="$HU/sites/hideup/current"
      # THE PRE-HIDE SHAPE, byte for byte as guerrilla carries it: this engine's
      # own marker comment, the handle_path, the root, and a BARE file_server.
      { printf 'example.com {\n'
        printf "\t# BARKPARK_SITE_ROUTE:hideup — static site 'hideup' served from its immutable current release.\n"
        printf '\t# handle_path strips the /sites/hideup prefix; root follows the symlink.\n'
        printf '\thandle_path /sites/hideup/* {\n'
        printf '\t\troot * %s\n' "$HUROOT"
        printf '\t\tfile_server\n'
        printf '\t}\n'
        printf '\treverse_proxy localhost:4000\n'
        printf '}\n'; } > "$HU/Caddyfile"
      check "the pre-hide fixture really is the un-hidden shape (no hide anywhere)" \
        sh -c "! grep -q 'hide ' '$HU/Caddyfile'"
      check "the pre-hide fixture validates on a REAL caddy (it is a shape the box runs)" \
        caddy validate --adapter caddyfile --config "$HU/Caddyfile"
      # A deploy of the SAME slug: the marker is present, so this run takes the
      # already-armed branch — the one that said nothing and rewrote nothing.
      hu_rc="$(env PATH="$HU/bin:$FAKEBIN:$PATH" \
        SITE_SLUG=hideup BUILD_ID=hu1 CONTENT_REV=rev-1 SITE_SRC="$HUSRC" \
        BARKPARK_HEALTH_HOST=sites.example.com \
        BARKPARK_SITES_DIR="$HU/sites" BARKPARK_CADDYFILE="$HU/Caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$HU/deploy.lock" BARKPARK_CADDYFILE_LOCK="$HU/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$HU/up.out" 2> "$HU/up.err"; echo $?)"
      check "the re-deploy over the pre-hide block still exits 0 (never fatal)" \
        [ "$hu_rc" = 0 ]
      check "the pre-hide block is upgraded in place: the file_server now HIDES the prebuilt digest marker" \
        grep -qE 'hide .*\.bp-prebuilt-sha256' "$HU/Caddyfile"
      check "…and the health-failed marker" \
        grep -qE 'hide .*\.bp-health-failed' "$HU/Caddyfile"
      check "…INSIDE a file_server block, not loose in the site" \
        grep -qE 'file_server \{' "$HU/Caddyfile"
      check "…and NOT by re-arming: this site's marker still appears exactly once" \
        sh -c "[ \"\$(grep -c 'BARKPARK_SITE_ROUTE:hideup' '$HU/Caddyfile')\" = 1 ]"
      check "…and the handle_path is still there exactly once (no duplicate route)" \
        sh -c "[ \"\$(grep -c 'handle_path /sites/hideup/\\*' '$HU/Caddyfile')\" = 1 ]"
      check "the upgraded Caddyfile is brace-balanced and REAL-caddy valid" \
        caddy validate --adapter caddyfile --config "$HU/Caddyfile"
      check "the upgrade is announced on the DURABLE machine channel, naming the outcome" \
        grep -q '^BPSTAGE name=ROUTE status=ok build_id=hu1 detail="already armed, UPGRADED: ' "$HU/up.out"
      check "the upgrade left no backup file behind on the happy path" \
        sh -c "! ls '$HU'/Caddyfile.bak.* >/dev/null 2>&1"
      # A SECOND re-deploy: the block now has the hide, so nothing is rewritten
      # and the detail goes back to the plain already-armed line (idempotent).
      cp "$HU/Caddyfile" "$HU/Caddyfile.after1"
      env PATH="$HU/bin:$FAKEBIN:$PATH" \
        SITE_SLUG=hideup BUILD_ID=hu2 CONTENT_REV=rev-1 SITE_SRC="$HUSRC" \
        BARKPARK_HEALTH_HOST=sites.example.com \
        BARKPARK_SITES_DIR="$HU/sites" BARKPARK_CADDYFILE="$HU/Caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$HU/deploy.lock" BARKPARK_CADDYFILE_LOCK="$HU/caddyfile.lock" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "$SELF" > "$HU/up2.out" 2> "$HU/up2.err" || true
      check "a SECOND re-deploy rewrites nothing (the upgrade is idempotent)" \
        cmp -s "$HU/Caddyfile.after1" "$HU/Caddyfile"
      check "…and it reports the plain already-armed detail, not another upgrade" \
        grep -q '^BPSTAGE name=ROUTE status=ok build_id=hu2 detail="already armed: ' "$HU/up2.out"
      # ---- THE OUTCOME, through a real caddy on a real port -----------------
      # The engine's own markers live INSIDE the served tree. .bp-prebuilt-sha256
      # is written by the prebuilt path; .bp-health-failed by a failed gate. Put
      # both in the LIVE release the way the box has them, then ask for them.
      printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$HUROOT/.bp-prebuilt-sha256"
      printf 'hu1\n' > "$HUROOT/.bp-health-failed"
      check "both release markers really are inside the served tree (the fixture is non-vacuous)" \
        sh -c "[ -f '$HUROOT/.bp-prebuilt-sha256' ] && [ -f '$HUROOT/.bp-health-failed' ] && [ -f '$HUROOT/index.html' ]"
      HU_PORT=0; HU_PID=""
      for HU_TRY in 38211 38307 38419 38523 38631; do
        { printf '{\n\tadmin off\n\tauto_https off\n}\n'
          printf ':%s {\n' "$HU_TRY"
          sed -n '/BARKPARK_SITE_ROUTE:hideup/,/^\t}$/p' "$HU/Caddyfile"
          printf '}\n'; } > "$HU/serve.caddy"
        caddy run --config "$HU/serve.caddy" --adapter caddyfile >"$HU/caddy.log" 2>&1 &
        HU_PID=$!
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          if [ "$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$HU_TRY/sites/hideup/" 2>/dev/null)" = 200 ]; then
            HU_PORT="$HU_TRY"; break
          fi
          sleep 0.25
        done
        [ "$HU_PORT" != 0 ] && break
        kill "$HU_PID" 2>/dev/null; wait "$HU_PID" 2>/dev/null; HU_PID=""
      done
      hu_code() { curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$HU_PORT$1"; }
      # A false 200/404 off a port a PEER holds is the trap here: assert the
      # fixture itself came up before believing any status code below.
      check "the upgraded block came up on a REAL caddy (this suite owns the port)" \
        [ "$HU_PORT" != 0 ]
      check "real caddy: the site index still serves 200 (the upgrade did not break the route)" \
        [ "$(hu_code /sites/hideup/)" = 200 ]
      check "real caddy: .bp-prebuilt-sha256 returns 404 — the artifact digest is no longer fetchable" \
        [ "$(hu_code /sites/hideup/.bp-prebuilt-sha256)" = 404 ]
      check "real caddy: .bp-health-failed returns 404 too — the failed-gate state is no longer disclosed" \
        [ "$(hu_code /sites/hideup/.bp-health-failed)" = 404 ]
      [ -n "$HU_PID" ] && { kill "$HU_PID" 2>/dev/null; wait "$HU_PID" 2>/dev/null; }
    fi
  fi

  # -------------------------------------------------------------------------
  # THE FLEET BUILD ADMISSION GATE — one box, one build (D95/D104).
  #
  # The per-slug deploy lock makes D7's "queue depth 1" true PER SITE and false
  # FLEET-WIDE, so N sites build concurrently on 2 cores BY CONSTRUCTION. These
  # cases drive the REAL script, concurrently, for DIFFERENT slugs, against a
  # REAL flock(1) — the FAKEBIN stub above is a flock that unconditionally exits
  # 0, and a gate proven against that stub proves the stub, not the gate.
  #
  # The build windows are measured with a SHARED LEDGER both builds append to
  # (START <slug> / END <slug>): max nesting depth 1 means the box compiled one
  # site at a time. Each oracle is shown non-vacuous by MUTATING the engine —
  # deleting the acquire (depth goes to 2) and deleting the refusal's emit (the
  # anti-hang assertion, and only it, reds).
  # -------------------------------------------------------------------------
  if ! command -v flock >/dev/null 2>&1; then
    # Same reasoning as the e2e skip above, one notch sharper: this block is the
    # ONLY proof that the box builds one site at a time, and it is worthless
    # against a stubbed lock. Skip honestly on a laptop; NEVER in CI.
    if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
      echo "[selftest] FAIL - the fleet build admission gate proof is REQUIRED here (BARKPARK_SELFTEST_REQUIRE_E2E=1) but flock(1) is missing from PATH — install util-linux on this runner; a gate proven against the e2e's exit-0 flock stub proves the stub, and a skipped gate proof must not report PASS"
      exit 1
    fi
    echo "[selftest] SKIP fleet build admission gate — needs a REAL flock(1) (stock macOS ships none; brew install flock)"
  else
    G="$TD/gate"; GBIN="$G/bin"; GLIB="$G/lib"
    mkdir -p "$GBIN" "$GLIB" "$G/sites"
    ENGINE_DIR="$(cd "$(dirname "$SELF")" && pwd)"
    # A mutant engine copy must find the shared lib it sources by its OWN dirname.
    cp "$ENGINE_DIR/lib/site-deploy-common.sh" "$GLIB/"
    g_not() { ! "$@"; }
    # GBIN carries npm ONLY — no flock stub. The gate npm BRACKETS its build
    # window in a shared ledger, and barriers on the OTHER site's START so the
    # interleave a broken gate produces is deterministic instead of a timing race.
    cat > "$GBIN/npm" <<'GATENPM'
#!/usr/bin/env bash
echo "npm $*" >> ./.npm-calls
[ "${1:-}" = ci ] && exit 0
led="${BP_GATE_LEDGER:-/dev/null}"
printf 'START %s\n' "${SITE_SLUG:-?}" >> "$led"
if [ "${BP_GATE_HANG:-0}" = 1 ]; then
  # Stay in flight until SIGKILLed (hard cap ~30s so a botched test cannot wedge
  # CI): the caller kills this subtree to prove the fd lock is what frees the slot.
  n=0; while [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  exit 0
fi
# Bounded barrier on a SECOND site's build appearing in the ledger. With the gate
# in place it never can — that is the point, and it makes the mutant's overlap
# deterministic rather than dependent on process start-up skew.
n=0
while [ "$(grep -c '^START' "$led" 2>/dev/null || echo 0)" -lt 2 ] && [ "$n" -lt 30 ]; do
  sleep 0.1; n=$((n + 1))
done
printf 'END %s\n' "${SITE_SLUG:-?}" >> "$led"
mkdir -p dist
{
  printf '<!doctype html><html><head>\n'
  printf '<meta name="bp-build-id" content="%s">\n' "${BARKPARK_BUILD_ID:-}"
  printf '<meta name="bp-content-rev" content="%s">\n' "${BARKPARK_CONTENT_REV:-}"
  printf '<meta name="bp-doc-id" content="doc-42">\n'
  printf '</head><body><h1>hello</h1></body></html>\n'
} > dist/index.html
exit 0
GATENPM
    chmod +x "$GBIN/npm"

    g_deploy() { # <slug> <build_id> [VAR=value…] — rc lands in $G/<slug>.rc, log in $G/<slug>.log
      local slug="$1" bid="$2"; shift 2
      mkdir -p "$G/src-$slug"
      printf '{"name":"gate-%s","private":true}\n' "$slug" > "$G/src-$slug/package.json"
      env PATH="$GBIN:$PATH" "$@" \
        SITE_SLUG="$slug" BUILD_ID="$bid" CONTENT_REV=rev-1 \
        SITE_SRC="$G/src-$slug" \
        BARKPARK_SITES_DIR="$G/sites" \
        BARKPARK_CADDYFILE="$G/absent-caddyfile" \
        BARKPARK_SITE_DEPLOY_LOCK="$G/deploy-$slug.lock" \
        BARKPARK_CADDYFILE_LOCK="$G/caddyfile.lock" \
        BARKPARK_BUILD_GATE_LOCK="${GATE_LOCK:-$G/build.lock}" \
        BARKPARK_SITE_NO_CAP=1 \
        bash "${GATE_ENGINE:-$SELF}" ${GATE_ARGS[@]+"${GATE_ARGS[@]}"} > "$G/$slug.log" 2>&1
      echo $? > "$G/$slug.rc"
    }
    g_rc()    { cat "$G/$1.rc" 2>/dev/null; }
    g_live()  { readlink "$G/sites/$1/current" 2>/dev/null || true; }
    # Max nesting depth of the START/END ledger: 1 = the box built one site at a
    # time; 2 = two builds were genuinely in flight together.
    g_depth() { awk '/^START/ { d++; if (d > m) m = d } /^END/ { d-- } END { print m + 0 }' "$1"; }
    g_quote() { tr '\n' '|' < "$1"; }
    g_free()  { flock -n "${GATE_LOCK:-$G/build.lock}" -c true 2>/dev/null; }
    g_has()   { printf '%s' "$1" | grep -q "$2"; }   # a pipe at a check() call site
                                                    # would swallow check's own output
    # SIGKILL the whole subtree — for a deploy: the engine, the
    # `bash -c 'npm ci && npm run build'` wrapper, tee AND the npm child, every one
    # of which INHERITED fd 7 (proven with lsof; killing only the top leaves the
    # lock held). For the pin: flock(1) execs its command as a CHILD, so the child
    # is the holder — kill the parent alone and `sleep` keeps the slot forever.
    g_kill_tree() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do g_kill_tree "$c"; done
      kill -9 "$p" 2>/dev/null || true; }
    # Hold the ONE slot with a FOREIGN holder (plain flock(1), no engine). It exits
    # on a sentinel rather than a signal: a killed holder would print job-control
    # noise over the suite's output, and this fixture is not what SIGKILL proves.
    # Hard cap ~60s so a botched test cannot wedge CI.
    g_pin()   { : > "$G/pinned"
      flock "$G/build.lock" -c "n=0; while [ -f '$G/pinned' ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done" &
      local n=0
      while g_free && [ "$n" -lt 60 ]; do sleep 0.1; n=$((n + 1)); done
    }
    g_unpin() { rm -f "$G/pinned"; local n=0
      while ! g_free && [ "$n" -lt 60 ]; do sleep 0.1; n=$((n + 1)); done; }
    GATE_ARGS=()

    echo "[selftest] gate: two concurrent deploys of DIFFERENT slugs SERIALIZE their build windows"
    GLED="$G/ledger-healthy"; : > "$GLED"
    export BP_GATE_LEDGER="$GLED"
    g_deploy alpha ga1 & gp1=$!
    g_deploy beta  gb1 & gp2=$!
    wait "$gp1" "$gp2"
    check "alpha reached SWITCH (exit 0)"        [ "$(g_rc alpha)" = 0 ]
    check "beta reached SWITCH (exit 0)"         [ "$(g_rc beta)" = 0 ]
    check "alpha's current MOVED"                [ "$(g_live alpha)" = releases/ga1 ]
    check "beta's current MOVED"                 [ "$(g_live beta)" = releases/gb1 ]
    check "BOTH really built (2 START rows)"     [ "$(grep -c '^START' "$GLED")" = 2 ]
    check "build windows are DISJOINT (ledger nesting depth 1)" [ "$(g_depth "$GLED")" = 1 ]
    echo "  ledger (gate ON):  $(g_quote "$GLED")   depth=$(g_depth "$GLED")"
    check "the slot is free again afterwards"     g_free

    echo "[selftest] gate: MUTATION PROOF — with the acquire deleted the SAME ledger interleaves"
    GMUT="$G/mutant-noacquire.sh"
    # Exactly one line changes: the admission decision. The release call stays.
    sed 's/^  if ! build_gate_acquire; then$/  if false; then/' "$SELF" > "$GMUT"
    check "the mutant differs from the engine in exactly ONE line" \
      [ "$(diff "$SELF" "$GMUT" | grep -c '^[<>]')" = 2 ]
    GMLED="$G/ledger-mutant"; : > "$GMLED"
    rm -rf "$G/sites/alpha" "$G/sites/beta" "$G/src-alpha" "$G/src-beta"
    export BP_GATE_LEDGER="$GMLED"
    GATE_ENGINE="$GMUT" g_deploy alpha ga1 & gp1=$!
    GATE_ENGINE="$GMUT" g_deploy beta  gb1 & gp2=$!
    wait "$gp1" "$gp2"
    check "the mutant still deploys alpha (the mutation is ONLY the gate)" [ "$(g_rc alpha)" = 0 ]
    check "the mutant still deploys beta"                                 [ "$(g_rc beta)" = 0 ]
    check "MUTANT: the two builds are genuinely INTERLEAVED (depth 2)" \
      [ "$(g_depth "$GMLED")" = 2 ]
    echo "  ledger (gate OFF): $(g_quote "$GMLED")   depth=$(g_depth "$GMLED")"
    unset BP_GATE_LEDGER

    echo "[selftest] gate: a lapsed wait budget SPEAKS on the stage protocol, then exits the typed 15"
    g_pin 60
    check "the foreign holder really pinned the only slot"  g_not g_free
    g_deploy gamma gg1 BARKPARK_BUILD_GATE_WAIT=1
    check "refused with the typed 15"            [ "$(g_rc gamma)" = 15 ]
    check "emitted BUILD failed BEFORE exiting (the anti-hang contract)" \
      grep -q '^BPSTAGE name=BUILD status=failed' "$G/gamma.log"
    check "the detail names the FLEET BUILD SLOT" grep -q 'FLEET BUILD SLOT' "$G/gamma.log"
    check "the detail names the lock file"        grep -q "$G/build.lock" "$G/gamma.log"
    check "ran NO npm"                            [ ! -f "$G/src-gamma/.npm-calls" ]
    check "staged NOTHING"                        [ ! -d "$G/sites/gamma/releases/gg1" ]
    check "never switched"                        [ ! -L "$G/sites/gamma/current" ]

    echo "[selftest] gate: MUTATION PROOF — deleting only the refusal's emit reds ONLY the anti-hang check"
    GMUT2="$G/mutant-noemit.sh"
    awk '{ if ($0 == "    emit BUILD failed \"$DETAIL\"") next; print }' "$SELF" > "$GMUT2"
    check "the no-emit mutant differs by exactly ONE deleted line" \
      [ "$(diff "$SELF" "$GMUT2" | grep -c '^[<>]')" = 1 ]
    GATE_ENGINE="$GMUT2" g_deploy delta gd1 BARKPARK_BUILD_GATE_WAIT=1
    check "MUTANT: still the typed 15 (that assertion does NOT move)" [ "$(g_rc delta)" = 15 ]
    check "MUTANT: no BUILD line at all — exactly the anti-hang check reds" \
      g_not grep -q '^BPSTAGE name=BUILD status=failed' "$G/delta.log"
    check "MUTANT: everything else still holds — nothing staged" [ ! -d "$G/sites/delta/releases/gd1" ]

    echo "[selftest] gate: what COMPILES NOTHING is never admission-controlled (slot still pinned)"
    # A rollback, a prebuilt STAGE, an already-staged re-gate and a preflight run
    # no npm — gating them would be pure harm: they are the moves an operator
    # reaches for WHILE the box is busy.
    g_unpin
    g_deploy zeta gz1; check "zeta gz1 deployed (setup)" [ "$(g_rc zeta)" = 0 ]
    g_deploy zeta gz2; check "zeta gz2 deployed (setup)" [ "$(g_rc zeta)" = 0 ]
    g_pin 60
    check "the slot is pinned again"              g_not g_free
    GATE_SECONDS_START=$SECONDS
    GATE_ARGS=(--rollback); g_deploy zeta ignored; GATE_ARGS=()
    check "ROLLBACK exits 0 with the slot pinned" [ "$(g_rc zeta)" = 0 ]
    check "ROLLBACK actually flipped current to gz1" [ "$(g_live zeta)" = releases/gz1 ]
    check "ROLLBACK did not queue (under 5s)"     [ "$((SECONDS - GATE_SECONDS_START))" -lt 5 ]
    check "ROLLBACK never touched the gate"       g_not grep -q 'fleet build slot' "$G/zeta.log"
    GATE_ARGS=(--rollback-preflight); g_deploy zeta ignored; GATE_ARGS=()
    check "ROLLBACK PREFLIGHT exits 0 with the slot pinned" [ "$(g_rc zeta)" = 0 ]
    g_deploy zeta gz2 BARKPARK_BUILD_GATE_WAIT=1
    check "an ALREADY-STAGED re-gate exits 0 with the slot pinned" [ "$(g_rc zeta)" = 0 ]
    check "the re-gate compiled nothing"          grep -q '^BPSTAGE name=BUILD status=skipped' "$G/zeta.log"
    GPRE="$G/prebuilt"; mkdir -p "$GPRE"
    {
      printf '<!doctype html><html><head>\n'
      printf '<meta name="bp-build-id" content="gp1">\n'
      printf '<meta name="bp-content-rev" content="rev-1">\n'
      printf '<meta name="bp-doc-id" content="doc-42">\n'
      printf '</head><body><h1>uploaded</h1></body></html>\n'
    } > "$GPRE/index.html"
    g_deploy eta gp1 BARKPARK_BUILD_GATE_WAIT=1 PREBUILT_DIR="$GPRE" \
      PREBUILT_SHA256=1111111111111111111111111111111111111111111111111111111111111111
    check "a PREBUILT STAGE exits 0 with the slot pinned" [ "$(g_rc eta)" = 0 ]
    check "the prebuilt deploy went live"         [ "$(g_live eta)" = releases/gp1 ]
    check "the prebuilt deploy ran no npm"        [ ! -f "$G/src-eta/.npm-calls" ]
    # THE CONTROL: the one thing that DOES compile is still refused.
    g_deploy theta gt1 BARKPARK_BUILD_GATE_WAIT=1
    check "CONTROL: a build-mode deploy IS still refused (15)" [ "$(g_rc theta)" = 15 ]
    g_unpin

    echo "[selftest] gate: SIGKILL frees the slot — the fd IS the release (no EXIT trap, no reaper)"
    check "no script-level EXIT trap exists to release it" \
      [ "$(grep -c '^trap ' "$SELF")" = 0 ]
    # NON-VACUITY: the next check is worthless unless the slot is free right now.
    check "the slot is free BEFORE the doomed build starts" g_free
    env PATH="$GBIN:$PATH" BP_GATE_HANG=1 \
      SITE_SLUG=iota BUILD_ID=gi1 CONTENT_REV=rev-1 \
      SITE_SRC="$G/src-iota" BARKPARK_SITES_DIR="$G/sites" \
      BARKPARK_CADDYFILE="$G/absent-caddyfile" \
      BARKPARK_SITE_DEPLOY_LOCK="$G/deploy-iota.lock" \
      BARKPARK_CADDYFILE_LOCK="$G/caddyfile.lock" \
      BARKPARK_BUILD_GATE_LOCK="$G/build.lock" BARKPARK_SITE_NO_CAP=1 \
      bash "$SELF" > "$G/iota.log" 2>&1 &
    gpid=$!
    mkdir -p "$G/src-iota"; printf '{"name":"gate-iota","private":true}\n' > "$G/src-iota/package.json"
    gn=0; while g_free && [ "$gn" -lt 100 ]; do sleep 0.1; gn=$((gn + 1)); done
    check "the in-flight build holds the slot"     g_not g_free
    g_kill_tree "$gpid"
    wait "$gpid" 2>/dev/null || true
    gn=0; while ! g_free && [ "$gn" -lt 60 ]; do sleep 0.1; gn=$((gn + 1)); done
    check "the SIGKILLed build's slot was freed BY THE KERNEL" g_free
    g_deploy kappa gk1 BARKPARK_BUILD_GATE_WAIT=1
    check "the NEXT deploy is ADMITTED (exit 0) on a 1s budget" [ "$(g_rc kappa)" = 0 ]

    echo "[selftest] gate: it FAILS OPEN, loudly, when it cannot lock"
    # (a) no flock(1) at all — asserted on the FUNCTION, because an engine with no
    #     flock cannot take its per-slug lock either and would never reach BUILD.
    # "$BASH" by ABSOLUTE path: with PATH emptied, a bare `bash` cannot be found
    # either, and the probe would prove nothing but its own typo.
    gfo="$(PATH=/nonexistent-for-the-gate-proof "$BASH" -c \
      ". \"$GLIB/site-deploy-common.sh\"; build_gate_acquire; echo GATE_RC=\$?" 2>&1)"
    check "no flock: ADMITS the build (rc 0)"      g_has "$gfo" 'GATE_RC=0'
    check "no flock: says so LOUDLY (WARN + OPEN)" g_has "$gfo" 'WARN.*gate is OPEN'
    # (b) an unopenable lock path (here: a directory) — a full e2e, because this
    #     one CAN happen on a real box (a root-owned /var/lock and a non-root run).
    GATE_LOCK="$G" g_deploy lambda gl1
    check "unopenable lock: the deploy still SUCCEEDS (fail open)" [ "$(g_rc lambda)" = 0 ]
    check "unopenable lock: WARNs that the gate is OPEN" grep -q 'admission gate is OPEN' "$G/lambda.log"
    check "unopenable lock: the build really ran"  grep -q 'npm run build' "$G/src-lambda/.npm-calls"

    echo "[selftest] gate: N and the wait budget are NAMED CONSTANTS with their derivation in the script"
    check "BUILD_GATE_SLOTS=1 is named"           grep -q '^BUILD_GATE_SLOTS=1' "$GLIB/site-deploy-common.sh"
    check "the wait budget is named"              grep -q '^BUILD_GATE_WAIT_DEFAULT=900' "$GLIB/site-deploy-common.sh"
    check "N's derivation is written down"        grep -q 'floor(2 cores \* 100% / 150%)' "$GLIB/site-deploy-common.sh"
    check "the write_env_file/4 allowlist is stated" grep -q 'write_env_file/4' "$GLIB/site-deploy-common.sh"
  fi

  echo ""
  echo "[selftest] $((TESTS - FAILS))/$TESTS checks passed"
  # The floor (see SELFTEST_FLOOR_* at the top of this block). `FAILED (1)` is
  # the shape internal/cli/cloud_site_preflight.go recognises as terminal.
  if [ "${BARKPARK_SELFTEST_REQUIRE_E2E:-0}" = 1 ]; then
    SELFTEST_FLOOR="$SELFTEST_FLOOR_FULL"
    SELFTEST_FLOOR_NAME="SELFTEST_FLOOR_FULL (BARKPARK_SELFTEST_REQUIRE_E2E=1: every block is required here)"
  else
    SELFTEST_FLOOR="$SELFTEST_FLOOR_MIN"
    SELFTEST_FLOOR_NAME="SELFTEST_FLOOR_MIN (bare run: the optional blocks may skip honestly)"
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
  # Same predicate --rollback uses: a preflight that ignores the poison marker
  # reports a rollback the real verb refuses.
  if rollback_target_blocked "$prev"; then exit 21; fi
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
  local marker; marker="$(site_route_marker_re)"
  has_site_route_marker "$CADDYFILE" || { log "caddy /sites/$SITE_SLUG route not armed — nothing to disarm"; return 0; }
  local bak; bak="${CADDYFILE}.bak.teardown.${SITE_SLUG}.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # brace-counted block excision, anchored on the marker (never a global grep) —
  # and the marker is the DELIMITER-ANCHORED regex, so a prefix sibling's block
  # is never the one excised (D345).
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
RELDIR="$RELEASES/$BUILD_ID"
PREBUILT_DIR="${PREBUILT_DIR:-}"
PREBUILT_SHA256="${PREBUILT_SHA256:-}"
PREBUILT_SHORT=""
PREBUILT_SIZE=""
if [ "$(live_build)" = "$BUILD_ID" ]; then
  # The no-op is keyed on build_id, and for a PREBUILT deploy build_id does not
  # determine the bytes: two different `dist/` uploads for the same
  # site+content+config mint the SAME id (the control plane nonces the mint
  # precisely because of this, D87).  So a prebuilt run whose digest disagrees
  # with what the live release records is NOT a no-op — exiting 0 there would
  # report success while serving bytes nobody uploaded, the same hazard the
  # PREBUILT arm's ordering closes, one gate earlier.  It is refused rather than
  # re-staged: RELDIR is the LIVE tree here, and tearing it down to replace it
  # would 404 the site mid-deploy.  A fresh mint (the normal path) has a fresh
  # build_id and never reaches this line.
  staged_sha="$(cat "$RELDIR/$PREBUILT_MARK" 2>/dev/null || true)"
  if [ -n "$PREBUILT_DIR" ] && [ "$staged_sha" != "$PREBUILT_SHA256" ]; then
    DETAIL="build $BUILD_ID is already LIVE carrying prebuilt '${staged_sha:-<none>}', but this upload declares ${PREBUILT_SHA256:0:12} — refusing to report a no-op over bytes that are not the ones uploaded; mint a NEW deployment for this artifact (a prebuilt mint is nonced for exactly this reason) and redeploy"
    log "PLAN: $DETAIL"; emit PLAN failed "$DETAIL"; exit 11
  fi
  log "PLAN: build_id $BUILD_ID is already live for '$SITE_SLUG' — nothing to do"
  emit PLAN noop "build $BUILD_ID is already live"
  for s in BUILD STAGE HEALTH SWITCH RETIRE; do emit "$s" skipped "build $BUILD_ID is already live"; done
  exit 0
fi
# PLAN is tri-state (D88/D89).  ORDER IS LOAD-BEARING: the PREBUILT arm is tested
# FIRST — before the already-staged arm and before the health-failed arm.  Below
# the already-staged gate, a RE-UPLOAD of a build_id whose release dir happens to
# exist would exit 0 having re-gated and switched to the STALE tree, i.e. the box
# would serve bytes nobody uploaded and report success.  "Rebuild from source" is
# not a move a prebuilt site has, so neither of the two arms below it can be
# allowed to claim this run.
if [ -n "$PREBUILT_DIR" ]; then
  PLAN_MODE=prebuilt
  if ! printf '%s' "$PREBUILT_SHA256" | grep -qE '^[0-9a-f]{64}$'; then
    DETAIL="PREBUILT_DIR is set but PREBUILT_SHA256 is '${PREBUILT_SHA256:-<missing>}' (want 64 lowercase hex) — refusing to stage bytes this box cannot name; the caller must pass the digest it verified for the artifact"
    log "PLAN: $DETAIL"; emit PLAN failed "$DETAIL"; exit 11
  fi
  if [ ! -d "$PREBUILT_DIR" ] || [ ! -f "$PREBUILT_DIR/index.html" ]; then
    DETAIL="PREBUILT_DIR '$PREBUILT_DIR' is not a directory with an index.html — expected the VALIDATED tree the box extracted from the uploaded artifact; check the ingest step ran and named this dir"
    log "PLAN: $DETAIL"; emit PLAN failed "$DETAIL"; exit 11
  fi
  PREBUILT_SHORT="${PREBUILT_SHA256:0:12}"
  PREBUILT_SIZE="$(du -sh "$PREBUILT_DIR" 2>/dev/null | cut -f1 || echo '?')"
  # RE-VERIFY on a retry instead of leaning on dir-existence (D77's shape): a dir
  # that is there says NOTHING about WHICH bytes are in it.  The staged marker is
  # compared to the digest this run was handed, and either way the tree is
  # RE-STAGED — a mismatch must never be re-gated as if it were this upload.
  if [ -f "$RELDIR/$PREBUILT_MARK" ]; then
    staged_sha="$(cat "$RELDIR/$PREBUILT_MARK" 2>/dev/null || true)"
    if [ "$staged_sha" = "$PREBUILT_SHA256" ]; then
      log "PLAN: releases/$BUILD_ID already carries prebuilt $PREBUILT_SHORT — re-staging the uploaded bytes anyway (dir-existence is not a proof of which bytes are staged)"
    else
      log "PLAN: releases/$BUILD_ID carries prebuilt '${staged_sha:-<none>}' but this upload is $PREBUILT_SHORT — REPLACING the staged tree (never re-gating the stale one)"
    fi
  fi
  log "PLAN: release $BUILD_ID ships UPLOADED prebuilt bytes ($PREBUILT_SIZE, sha256 $PREBUILT_SHORT) — no build will run on this box"
elif [ -f "$RELDIR/$PREBUILT_MARK" ] && [ -f "$RELDIR/$HEALTH_FAIL_MARK" ]; then
  # Prebuilt bytes that failed HEALTH, and no artifact on THIS run.  The other
  # arms would rebuild from the provisioned template: genuine markers, HEALTH
  # green, WRONG bytes live.  Fail closed — the only real fix is another upload.
  DETAIL="release $BUILD_ID was staged from UPLOADED prebuilt bytes and FAILED health — this box has no source for it, and a rebuild from the provisioned template would pass HEALTH on genuine markers and go live with the WRONG bytes; RE-UPLOAD the artifact for this build_id and redeploy"
  log "PLAN: $DETAIL"; emit PLAN failed "$DETAIL"; exit 11
elif [ -f "$RELDIR/$HEALTH_FAIL_MARK" ]; then
  # A release we could not delete (it is the live/rollback target) but whose
  # bytes FAILED health.  Never re-gate poison — rebuild it.
  log "PLAN: release $BUILD_ID is marked health-failed — rebuilding from source (never re-gating broken bytes)"
  PLAN_MODE=build
elif [ -d "$RELDIR" ] && [ -f "$RELDIR/index.html" ]; then
  # A previously-staged but not-live build (e.g. a rollback target): skip the
  # rebuild, re-health-gate + switch straight to it.
  log "PLAN: release $BUILD_ID already staged — re-gating, skipping BUILD/STAGE"
  PLAN_MODE=staged
else
  PLAN_MODE=build
fi
log "PLAN: deploy '$SITE_SLUG' build $BUILD_ID (live now: $(live_build))"
case "$PLAN_MODE" in
  staged)   emit PLAN ok "release $BUILD_ID is already staged — BUILD and STAGE will be skipped" ;;
  prebuilt) emit PLAN ok "staging uploaded prebuilt bytes for build $BUILD_ID (sha256 $PREBUILT_SHORT) — BUILD will be skipped, STAGE will run" ;;
  *)        emit PLAN ok "building '$SITE_SLUG' build $BUILD_ID from source" ;;
esac

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

# The most useful line of a failed build, for the BUILD failed stage line, comes
# from build_failure_reason() — ONE copy, in lib/site-deploy-common.sh (sourced
# above), shared with the node engine. It used to be duplicated here byte for
# byte, which meant every repair to the reason had to be made twice or the
# DEFAULT (static) engine silently kept the old, narrower one.

if [ "$PLAN_MODE" = build ]; then
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
  # The lock taken above is PER-SLUG, so without this second, fleet-wide lock N
  # sites compile at once on 2 cores. Taken HERE: after BUILD started (so the
  # stage machine already speaks) and after the two cheap validations (a payload
  # that has no source or no package.json must fail on its own merits, never
  # after a 15-minute queue). Released right after BUILD ok, below.
  if ! build_gate_acquire; then
    DETAIL="waited ${BUILD_GATE_WAIT}s for the FLEET BUILD SLOT ($BUILD_GATE_LOCK) and it never freed — this box runs ONE build at a time (2 cores, MemoryMax=1500M each), so another site's build is still compiling; nothing was built, staged or switched and the live release is untouched. Retry once it drains, or run this build off-box and deploy it with --prebuilt. In flight: $(build_gate_holders)"
    log "BUILD: $DETAIL"
    # emit BEFORE the exit, ALWAYS. This refusal fires AFTER `emit PLAN ok`, so a
    # bare exit here leaves a stage-watching orchestrator waiting on a BUILD line
    # that never comes — the hang class this engine has already fixed twice.
    emit BUILD failed "$DETAIL"
    exit 15
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
  # The compile is over — hand the box's only build slot to whoever is queued.
  # STAGE/HEALTH/SWITCH are copies, a curl and a symlink: they are not what the
  # 2 cores are scarce for, and holding the slot across them would serialize the
  # cheap tail of every deploy for no gain. (The build-failure exits above drop
  # the fd by dying, which is the release that also survives a SIGKILL.)
  build_gate_release

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
  stage_dir_into_release "$SITE_SRC/dist" "dist/"
  staged_size="$(du -sh "$RELDIR" 2>/dev/null | cut -f1 || echo '?')"
  log "STAGE: dist/ -> releases/$BUILD_ID/ ($staged_size)"
  emit STAGE ok "dist/ -> releases/$BUILD_ID ($staged_size)"
elif [ "$PLAN_MODE" = prebuilt ]; then
  # THE BUILD LEFT THE BOX (D88).  No npm, no node_modules, no CPU contention
  # with the API that serves this site — just the shippable output, staged.
  emit BUILD skipped "prebuilt bytes ($PREBUILT_SIZE, sha256 $PREBUILT_SHORT) - no build ran on this box"
  log "BUILD: skipped — build $BUILD_ID ships uploaded prebuilt bytes ($PREBUILT_SIZE, sha256 $PREBUILT_SHORT); nothing is compiled on this box"
  emit STAGE started
  stage_dir_into_release "$PREBUILT_DIR" "prebuilt bytes" "$PREBUILT_SHA256"
  staged_size="$(du -sh "$RELDIR" 2>/dev/null | cut -f1 || echo '?')"
  log "STAGE: prebuilt bytes -> releases/$BUILD_ID/ ($staged_size, sha256 $PREBUILT_SHORT)"
  emit STAGE ok "prebuilt bytes -> releases/$BUILD_ID ($staged_size, sha256 $PREBUILT_SHORT)"
else
  # An already-staged redeploy used to emit NEITHER a BUILD nor a STAGE line — the
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
# RETURNS: 0 the route is armed (or was already armed / there is no caddy on this
# box / this Caddyfile has no slot site to hang it in), 2 this run TRIED to arm it,
# the change was rejected or the file was unwritable, and the Caddyfile was
# REVERTED — so the route is NOT armed and this run OBSERVED that. The caller MUST
# branch on it (engine-D77, which taught the disarm direction exactly this and left
# the arm direction untouched): a revert used to be the function's LAST `mv`, i.e.
# exit status 0, so "the route is not armed" was not representable at the function
# boundary and the run's final line advertised https://<host>/sites/<slug>/ over it.
# 2 and NOT 1 on purpose, mirroring disarm_caddy_site_route: `with_caddy_lock`
# returns 1 out of its OWN guards when the lock cannot be taken, and that is a
# different fact — the Caddyfile was never even read.
arm_caddy_site_route() {
  command -v caddy >/dev/null 2>&1 || { ROUTE_DETAIL="not armed: caddy is not installed on this box, so nothing publishes /sites/$SITE_SLUG — the release is live on disk only"; log "caddy not installed — skipping /sites/$SITE_SLUG route"; return 0; }
  [ -f "$CADDYFILE" ] || { ROUTE_DETAIL="not armed: there is no $CADDYFILE on this box, so nothing publishes /sites/$SITE_SLUG — the release is live on disk only"; log "no $CADDYFILE — skipping /sites/$SITE_SLUG route"; return 0; }
  local marker="BARKPARK_SITE_ROUTE:$SITE_SLUG"
  # The guard is the DELIMITER-ANCHORED predicate (D345): a bare substring read
  # matched a prefix SIBLING's marker and returned "already armed" for a site
  # that had never been armed at all.
  if has_site_route_marker "$CADDYFILE"; then
    # ---------------------------------------------------------------------
    # UPGRADE, NOT RE-ARM (the marker guard freezes the FIRST shape forever).
    #
    # The arm below emits `file_server { hide … }` and the self-test pins it —
    # but the pin only proves what a FRESH arm writes. A block armed BEFORE the
    # hide landed carries a BARE `file_server`, and the guard above returns
    # "already armed" for it on every subsequent deploy, forever. Measured
    # read-only on guerrilla 157.180.90.121 (2026-09-03, `cat /etc/caddy/Caddyfile`):
    # all FOUR armed STATIC blocks (the other six routes are node reverse_proxy
    # blocks and carry no file_server) are the pre-hide shape —
    #
    #     handle_path /sites/perfect-proof/* {
    #         root * /opt/barkpark/sites/perfect-proof/current
    #         file_server
    #     }
    #
    # so $PREBUILT_MARK and $HEALTH_FAIL_MARK are fetchable over HTTPS on every
    # one of them: the artifact digest, and the fact that the LIVE release is one
    # this engine already knows failed its health gate.
    #
    # Re-arming is not the remedy (that is the duplicate-handle defect D345
    # guards against), so upgrade THAT ONE BLOCK in place, under the same
    # contract as the arm: backup, rewrite, `caddy validate`, revert on reject,
    # reload. Scoped by the delimiter-anchored marker + brace count (the same
    # walk disarm_caddy_site_route uses), so a prefix sibling's block is never
    # the one rewritten. Non-fatal in every direction: a rejected or unwritable
    # upgrade leaves the route exactly as it was and the deploy still succeeds —
    # the site was already being served.
    # Idempotent by construction: the awk demands EXACTLY ONE bare `file_server`
    # inside this site's block, so an already-hidden block (and every node-route
    # block, which has no file_server at all) rewrites nothing.
    # ---------------------------------------------------------------------
    local upgraded=0
    local utmp; utmp="$(mktemp)"
    if BP_MARK="$(site_route_marker_re)" BP_HIDE="$PREBUILT_MARK $HEALTH_FAIL_MARK" awk '
      BEGIN { m = ENVIRON["BP_MARK"]; hide = ENVIRON["BP_HIDE"]; n = 0 }
      !inb && $0 ~ m { inb = 1; depth = 0; opened = 0; print; next }
      inb {
        if ($0 ~ /^[ \t]*file_server[ \t]*$/) {
          match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
          printf "%sfile_server {\n%s\thide %s\n%s}\n", ind, ind, hide, ind
          n++
        } else print
        o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&"); depth += o - c
        if (o > 0) opened = 1
        if (opened && depth <= 0) inb = 0
        next
      }
      { print }
      END { exit (n == 1 ? 0 : 1) }
    ' "$CADDYFILE" > "$utmp"; then
      local ubak; ubak="${CADDYFILE}.bak.hide.${SITE_SLUG}.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$CADDYFILE" "$ubak"
      if cp "$utmp" "$CADDYFILE"; then
        chmod --reference="$ubak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
        chown --reference="$ubak" "$CADDYFILE" 2>/dev/null || true
        if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
          rm -f "$ubak"
          upgraded=1
          systemctl reload caddy 2>/dev/null || true
          log "upgraded the already-armed /sites/$SITE_SLUG file_server to hide $PREBUILT_MARK $HEALTH_FAIL_MARK"
        else
          cp -a "$ubak" "$CADDYFILE" && rm -f "$ubak"
          log "caddy validate rejected the /sites/$SITE_SLUG hide upgrade — reverted, Caddy untouched"
        fi
      else
        cp -a "$ubak" "$CADDYFILE" 2>/dev/null; rm -f "$ubak"
        log "could not rewrite $CADDYFILE for the /sites/$SITE_SLUG hide upgrade — Caddy untouched"
      fi
    fi
    rm -f "$utmp"
    if [ "$upgraded" = 1 ]; then
      ROUTE_DETAIL="already armed, UPGRADED: $CADDYFILE carried this site's own $marker block with a bare file_server (armed before the hide landed), so this run rewrote that one block in place to hide $PREBUILT_MARK and $HEALTH_FAIL_MARK, validated it and reloaded Caddy — those markers are no longer fetchable over /sites/$SITE_SLUG/"
    else
      ROUTE_DETAIL="already armed: $CADDYFILE carries this site's own $marker block, so this deploy left Caddy untouched (the symlink flip is what goes live)"
    fi
    log "caddy /sites/$SITE_SLUG route already armed"
    return 0
  fi
  # Anchor on the FIRST slot/site reverse_proxy so the handle lands INSIDE the
  # live FQDN site block (ahead of the fallback proxy).  Matches the guerrilla
  # blue/green slot ports 4000/4001 (same anchor arm_caddy_mcp_route uses).
  if ! grep -qE 'reverse_proxy[[:space:]]+localhost:(4000|4001)([[:space:]]|$)' "$CADDYFILE"; then
    ROUTE_DETAIL="not armed: $CADDYFILE has no slot 'reverse_proxy localhost:4000|4001' site block to insert the handle into, so there is nowhere to hang /sites/$SITE_SLUG — Caddy left untouched and that URL will 404"
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (/sites/$SITE_SLUG not armed)"
    return 0
  fi
  local block; block="$(cat <<SITEROUTE
	# $marker — static site '$SITE_SLUG' served from its immutable current release.
	# handle_path strips the /sites/$SITE_SLUG prefix; root follows the symlink.
	handle_path /sites/$SITE_SLUG/* {
		root * $ROOT/current
		# The release-root markers ($PREBUILT_MARK / $HEALTH_FAIL_MARK) live INSIDE
		# the served tree. Un-hidden, a plain GET discloses the artifact digest
		# and — worse — that the LIVE release is one the engine already knows
		# failed its health gate. hide keeps them internal.
		file_server {
			hide $PREBUILT_MARK $HEALTH_FAIL_MARK
		}
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
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE" || {
    log "could not rewrite $CADDYFILE for the /sites/$SITE_SLUG arm — restoring the backup, Caddy untouched"
    rm -f "$tmp"; mv "$bak" "$CADDYFILE"; return 2
  }
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    ROUTE_DETAIL="armed: this run wrote the $marker handle into $CADDYFILE and reloaded Caddy, so https://$HEALTH_HOST/sites/$SITE_SLUG/ is now served from $ROOT/current"
    if systemctl reload caddy 2>/dev/null; then log "armed caddy /sites/$SITE_SLUG route -> $ROOT/current"; else ROUTE_DETAIL="armed: this run wrote the $marker handle into $CADDYFILE, but the caddy reload failed (the config validates) — https://$HEALTH_HOST/sites/$SITE_SLUG/ goes live on the next reload"; log "caddy reload failed (config valid) — /sites/$SITE_SLUG live on next reload"; fi
    rm -f "$bak"
    return 0
  else
    log "caddy validate rejected the /sites/$SITE_SLUG route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
    return 2
  fi
}
# Non-fatal by contract: a Caddy hiccup (or a lock we could not take) must never
# fail a healthy build — the release goes live on the symlink flip either way.
# But non-fatal is NOT the same as unreported, and `|| true` made them the same:
# the run then walked SWITCH ok / RETIRE ok and signed off "live at
# https://<host>/sites/<slug>/" over a URL that 404s, at exit 0.  So branch, and
# carry ROUTE_ARMED into the final line.
# The verdict deliberately STAYS exit 0 (charter-D327).  Turning a today-green
# path red converts succeeding FIRST deploys into hard failures and RAISES this
# epic's own failure numerator — the dr-w8-s2 trap.  Report first; move the
# verdict in a later wave, with the incidence measured.
# `emit ROUTE failed` is safe on the machine channel: DeployRunner's
# @stage_names whitelist is PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE, so
# parse_stage_line/2 SKIPS a ROUTE line — it never enters `stages` and cannot
# reach stage_exit_code/1.  It still rides the durable log tail the operator reads.
#
# AND THE SUCCESS PATH SPEAKS TOO (D346). Every arm outcome used to reach the
# operator through `log()` alone — i.e. through STDOUT, which nothing persists:
# the durable `.log` holds raw npm child output and the durable `.status` holds
# BPSTAGE lines only. Measured across 1,178 durable .log files on guerrilla,
# `route already armed`, `leaving Caddy untouched` and `skipping /sites/` each
# appear ZERO times — and the first MUST fire on every re-deploy of an
# already-armed site (astro-search alone re-deployed 244 times). That zero was
# VACUOUS, not healthy: route-arm incidence was structurally unmeasurable, so a
# fresh alarm would have been exactly as invisible as the old one. The ROUTE
# line is the channel that already exists and is already free, so emit it on the
# ok path as well, naming which of armed / already-armed / not-armed-and-why
# this run took.
ROUTE_ARMED=1
ROUTE_DETAIL=""
arm_rc=0
with_caddy_lock arm_caddy_site_route || arm_rc=$?
if [ "$arm_rc" = 0 ]; then
  log "ROUTE: $ROUTE_DETAIL"
  emit ROUTE ok "$ROUTE_DETAIL"
fi
if [ "$arm_rc" != 0 ]; then
  ROUTE_ARMED=0
  # TWO different failures, and they are NOT the same claim (same split the
  # teardown makes): 2 = the arm ran, was rejected, and the Caddyfile was
  # reverted. 1 = with_caddy_lock's own guard fired, so nothing read the
  # Caddyfile and the route's state is UNKNOWN to this run.
  if [ "$arm_rc" = 1 ]; then
    ROUTE_DETAIL="the caddy /sites/$SITE_SLUG route was NEVER CHECKED — the shared Caddyfile lock could not be taken, so whether this site is publicly routed is UNKNOWN to this run; the release still goes live on disk. Re-run the deploy once the lock is free"
  else
    ROUTE_DETAIL="the caddy /sites/$SITE_SLUG route is NOT ARMED — this run tried to add it, the change was rejected, and the Caddyfile was reverted to the serving config; the release still goes live on disk but https://$HEALTH_HOST/sites/$SITE_SLUG/ will 404. Fix $CADDYFILE (caddy validate names the error) and re-run the deploy"
  fi
  log "ROUTE: $ROUTE_DETAIL"
  emit ROUTE failed "$ROUTE_DETAIL"
fi

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

# The sign-off only names the public URL when THIS run has a reason to believe it
# resolves. HEALTH proves the BYTES (it gates them over a throwaway loopback
# server), never the public path — so with the route unarmed the old
# unconditional line was the engine's own advertisement for a 404.
if [ "${ROUTE_ARMED:-1}" = 1 ]; then
  log "HEALTHY — '$SITE_SLUG' live at build $BUILD_ID (https://$HEALTH_HOST/sites/$SITE_SLUG/)"
else
  log "HEALTHY ON DISK — '$SITE_SLUG' build $BUILD_ID is the current release, but its public route is NOT ARMED, so no URL is claimed for it: $ROUTE_DETAIL"
fi
exit 0
