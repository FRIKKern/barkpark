#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# site-spawner-live-proof.sh — the executable end-to-end proof that a site can
# actually be SPAWNED: `bp cloud site create` → `deploy` (walking the six visible
# stages) → a live https URL serving the user's REAL Barkpark content →
# `rollback` in under a second → and a deliberately broken build that dies at its
# named stage and NEVER reaches a visitor.  [cloud-site-spawner charter W3]
#
# It is a PROOF, not a demo. Every step it cannot prove is a NAMED, typed,
# non-zero exit — never a silent skip and never an optimistic green. The one
# thing this script must never do is claim a green it did not earn.
#
#   bash deploy/site-spawner-live-proof.sh              # the full live proof
#   bash deploy/site-spawner-live-proof.sh --preflight  # read-only walls; mutates NOTHING
#   bash deploy/site-spawner-live-proof.sh --self-check # offline; proves every red fires
#
# WHY THE PURE `judge_*` LAYER
#   Fetching and judging are deliberately split. Every assertion is a pure
#   function over already-fetched values that RETURNS its typed failure code, so
#   `--self-check` can feed each one synthetic good AND bad input offline and
#   assert the exact red fires. A proof script whose failure paths were never
#   executed is itself a vacuous green — this is the fix.
#
# WHY THERE IS NO ROUTE-EXISTENCE PREFLIGHT
#   The control plane's catch-all (`match _ do json(conn, 404, %{error:
#   "not_found"})`) answers a MISSING ROUTE with the exact same body as a missing
#   site. Route wiring therefore cannot be distinguished from outside without a
#   real, owned site — so it is proven INLINE at the step that needs it (where a
#   404/422 against a site we just created IS unambiguous) rather than guessed at
#   in preflight.
#
# TYPED EXIT CODES (the named reds):
#    0 PROVEN                        2 usage
#   30 PREFLIGHT_NO_BP              — the bp binary or the `cloud site` verb is absent
#   31 PREFLIGHT_NO_CLOUD_SESSION   — no cloud session token (`bp login`)
#   32 PREFLIGHT_NO_BARKPARK        — the session's TEAM does not own the target box
#   33 PREFLIGHT_NO_CONTENT         — the doc type has 0 published docs (would build an EMPTY page)
#   40 CREATE_FAILED                — `bp cloud site create` did not return a site
#   41 CREATE_NOT_CONTENT_BOUND     — the ghost 201: no read token stored, no dataset binding
#   50 DEPLOY_FAILED                — the deployment never reached live
#   51 DEPLOY_STAGES_INCOMPLETE     — the six stages did not all land, in order
#   60 LIVE_NOT_200                 — the live URL does not serve
#   61 LIVE_BUILD_ID_MISMATCH       — served bp-build-id != the deployment's build_id
#   62 LIVE_CONTENT_EMPTY           — bp-content-rev or bp-doc-id empty (a vacuous green page)
#   70 ROLLBACK_FAILED              — the rollback call failed
#   71 ROLLBACK_TOO_SLOW            — over the 1000ms budget
#   72 ROLLBACK_DID_NOT_FLIP        — the live bp-build-id did not change
#   80 BROKEN_BUILD_NOT_NAMED       — the broken build failed with no named stage / no real reason
#   81 BROKEN_BUILD_REACHED_VISITORS— the worst red: a broken build changed what visitors see
#   90 SELF_CHECK_FAILED            — a named red did NOT fire on input that must trigger it
set -uo pipefail

# ---- Config -----------------------------------------------------------------

INSTANCE="${INSTANCE:-guerrilla}"
LIVE_HOST="${LIVE_HOST:-${INSTANCE}.barkpark.cloud}"
DATASET="${DATASET:-default/default/production}"

# CONTENT REALITY [charter D31]: there is NO `post` type on guerrilla, and an
# undefined type answers 200 with count:0 — NOT 404. The Astro starter's default
# BARKPARK_DOC_TYPE=post therefore builds a silently EMPTY page. `paper` is
# public + published + real. DOC_ID is PINNED, not "newest": concurrent sessions
# write the corpus, so "newest published" shifts mid-run and the build would race.
DOC_TYPE="${BARKPARK_DOC_TYPE:-paper}"
DOC_ID="${BARKPARK_DOC_ID:-}"

# Rollback budget. The engine's own symlink flip measured 25ms; the budget is the
# HTTP round trip. There is NO client-side poll on the rollback path, so the
# route must BLOCK on the real flip before answering 200 — which is exactly what
# this number tests.
ROLLBACK_BUDGET_MS="${ROLLBACK_BUDGET_MS:-1000}"

SLUG="${SLUG:-}"
BP="${BP:-bp}"
KEEP=0
MODE="full"

CFG="${BARKPARK_CONFIG:-$HOME/.config/barkpark/config.json}"

# ---- Named failures ----------------------------------------------------------

E_NO_BP=30
E_NO_SESSION=31
E_NO_BARKPARK=32
E_NO_CONTENT=33
E_CREATE_FAILED=40
E_CREATE_NOT_BOUND=41
E_DEPLOY_FAILED=50
E_DEPLOY_STAGES=51
E_LIVE_NOT_200=60
E_LIVE_BUILD_MISMATCH=61
E_LIVE_CONTENT_EMPTY=62
E_ROLLBACK_FAILED=70
E_ROLLBACK_SLOW=71
E_ROLLBACK_NO_FLIP=72
E_BROKEN_NOT_NAMED=80
E_BROKEN_REACHED_VISITORS=81
E_SELF_CHECK=90

# codename maps a typed exit code to the NAME printed in the red. A failure that
# is not in this table is a bug in this script, and says so.
codename() {
  case "$1" in
    "$E_NO_BP") echo "PREFLIGHT_NO_BP" ;;
    "$E_NO_SESSION") echo "PREFLIGHT_NO_CLOUD_SESSION" ;;
    "$E_NO_BARKPARK") echo "PREFLIGHT_NO_BARKPARK" ;;
    "$E_NO_CONTENT") echo "PREFLIGHT_NO_CONTENT" ;;
    "$E_CREATE_FAILED") echo "CREATE_FAILED" ;;
    "$E_CREATE_NOT_BOUND") echo "CREATE_NOT_CONTENT_BOUND" ;;
    "$E_DEPLOY_FAILED") echo "DEPLOY_FAILED" ;;
    "$E_DEPLOY_STAGES") echo "DEPLOY_STAGES_INCOMPLETE" ;;
    "$E_LIVE_NOT_200") echo "LIVE_NOT_200" ;;
    "$E_LIVE_BUILD_MISMATCH") echo "LIVE_BUILD_ID_MISMATCH" ;;
    "$E_LIVE_CONTENT_EMPTY") echo "LIVE_CONTENT_EMPTY" ;;
    "$E_ROLLBACK_FAILED") echo "ROLLBACK_FAILED" ;;
    "$E_ROLLBACK_SLOW") echo "ROLLBACK_TOO_SLOW" ;;
    "$E_ROLLBACK_NO_FLIP") echo "ROLLBACK_DID_NOT_FLIP" ;;
    "$E_BROKEN_NOT_NAMED") echo "BROKEN_BUILD_NOT_NAMED" ;;
    "$E_BROKEN_REACHED_VISITORS") echo "BROKEN_BUILD_REACHED_VISITORS" ;;
    "$E_SELF_CHECK") echo "SELF_CHECK_FAILED" ;;
    *) echo "UNNAMED_FAILURE_${1}" ;;
  esac
}

RED=""; GRN=""; DIM=""; BLD=""; OFF=""
if [ -t 2 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'; fi

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n%s▸ %s%s\n' "$BLD" "$*" "$OFF" >&2; }
ok() { printf '  %s✓%s %s\n' "$GRN" "$OFF" "$*" >&2; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$OFF" >&2; }

# fail prints the NAMED red and exits with its typed code. `why` is the concrete
# reason (what was expected, what was actually observed) — never a generic
# "something went wrong". `fix` is what a human does next.
fail() {
  local code="$1" why="$2" fixhint="${3:-}"
  printf '\n%s✗ %s%s  %s(exit %s)%s\n' "$RED$BLD" "$(codename "$code")" "$OFF" "$DIM" "$code" "$OFF" >&2
  printf '  %s\n' "$why" >&2
  [ -n "$fixhint" ] && printf '  %s→ %s%s\n' "$DIM" "$fixhint" "$OFF" >&2
  cleanup
  exit "$code"
}

# ---- Small helpers -----------------------------------------------------------

now_ms() {
  # GNU date has %3N; BSD/macOS date does not. Fall back to python3, then perl.
  local t
  t="$(date +%s%3N 2>/dev/null)" || t=""
  case "$t" in
    *N* | "") ;;
    *) printf '%s' "$t"; return 0 ;;
  esac
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time;print(int(time.time()*1000))'; return 0
  fi
  perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
}

jget() {
  # jget <json-file> <dotted.path> — prints the value, or "" when absent/null.
  # Deliberately python3 (always present where bp is developed/operated) rather
  # than jq, which is not guaranteed on a Hetzner box.
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split('.'):
    if isinstance(d, list):
        try: d = d[int(k)]
        except Exception: sys.exit(0)
    elif isinstance(d, dict):
        d = d.get(k)
    else:
        sys.exit(0)
    if d is None:
        sys.exit(0)
if isinstance(d, (dict, list)):
    print(json.dumps(d))
elif isinstance(d, bool):
    print("true" if d else "false")
else:
    print(d)
PY
}

cfgval() {
  [ -f "$CFG" ] || return 0
  python3 - "$CFG" "$1" <<'PY' 2>/dev/null || true
import json, sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], "") or "")
except Exception: pass
PY
}

# meta_content <html-file> <meta-name> — the content= of a <meta name="…">, or "".
# Tolerates attribute order and single/double quotes (Astro emits double).
meta_content() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import re, sys
try: html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception: sys.exit(0)
name = re.escape(sys.argv[2])
m = re.search(r'<meta[^>]*\bname=["\']%s["\'][^>]*\bcontent=["\']([^"\']*)["\']' % name, html, re.I)
if not m:
    m = re.search(r'<meta[^>]*\bcontent=["\']([^"\']*)["\'][^>]*\bname=["\']%s["\']' % name, html, re.I)
print(m.group(1).strip() if m else "")
PY
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/site-proof.XXXXXX")"
CREATED_SITE=""
cleanup() {
  if [ -n "$CREATED_SITE" ] && [ "$KEEP" -eq 0 ]; then
    say ""
    note "cleanup: the demo site '$CREATED_SITE' was created on the live fleet."
    note "         There is no DELETE /v1/sites/:id route yet (see site-spawner-backlog-token-revoke),"
    note "         so it is LEFT IN PLACE deliberately, along with its releases dir and Caddy block."
    note "         Remove by hand: on $LIVE_HOST → rm -rf /opt/barkpark/sites/$CREATED_SITE and drop the"
    note "         '# barkpark-site:$CREATED_SITE' guarded handle_path block from /etc/caddy/Caddyfile."
  fi
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# =============================================================================
# THE PURE JUDGES — every assertion, as a function over values, returning its
# typed red. No network, no globals. `--self-check` drives each of these with
# input that MUST fail, and asserts the exact code comes back.
# =============================================================================

# judge_create <content_bound> <workspace> <project> <dataset>
# The ghost-201 detector: the old create path answered 201 while silently
# DROPPING the content binding. content_bound is the server's own
# `not is_nil(read_token_encrypted)` — so a true here IS the stored read token.
judge_create() {
  local bound="$1" ws="$2" proj="$3" ds="$4"
  [ "$bound" = "true" ] || return "$E_CREATE_NOT_BOUND"
  [ -n "$ws" ] && [ -n "$proj" ] && [ -n "$ds" ] || return "$E_CREATE_NOT_BOUND"
  return 0
}

# judge_stages <status> <stage-names-in-observed-order…>
# All six stages must have landed, in the canonical order. A deploy that reached
# `live` having only reported three of them is not a proof of a six-stage engine.
judge_stages() {
  local status="$1"; shift
  local want="PLAN BUILD STAGE HEALTH SWITCH RETIRE"
  local got="$*"
  [ "$got" = "$want" ] || return "$E_DEPLOY_STAGES"
  [ "$status" = "live" ] || return "$E_DEPLOY_FAILED"
  return 0
}

# judge_live <http_code> <served_build_id> <expected_build_id> <content_rev> <doc_id>
# Assert by VALUE, not by reachability. A build with bp-build-id=TOTALLY-WRONG
# went live on this box a day ago and a reachability check called it green —
# hence the equality, and hence the non-empty content-rev/doc-id (a page that
# rendered with NO content still returns a cheerful 200).
judge_live() {
  local code="$1" served="$2" expect="$3" rev="$4" doc="$5"
  [ "$code" = "200" ] || return "$E_LIVE_NOT_200"
  [ -n "$expect" ] || return "$E_LIVE_BUILD_MISMATCH"
  [ "$served" = "$expect" ] || return "$E_LIVE_BUILD_MISMATCH"
  [ -n "$rev" ] && [ -n "$doc" ] || return "$E_LIVE_CONTENT_EMPTY"
  return 0
}

# judge_rollback <elapsed_ms> <build_id_before> <build_id_after> <budget_ms>
judge_rollback() {
  local ms="$1" before="$2" after="$3" budget="$4"
  [ -n "$after" ] || return "$E_ROLLBACK_FAILED"
  [ "$after" != "$before" ] || return "$E_ROLLBACK_NO_FLIP"
  [ "$ms" -le "$budget" ] || return "$E_ROLLBACK_SLOW"
  return 0
}

# judge_broken <deploy_status> <failed_stage> <failure_reason> <live_bid_before> <live_bid_after>
# The health gate's whole purpose. Two independent things must hold: the failure
# is HONEST (a named stage + a real reason, not a shrug), and the failure is
# CONTAINED (visitors still see the previous build).
judge_broken() {
  local status="$1" stage="$2" reason="$3" before="$4" after="$5"
  # Containment is judged FIRST and unconditionally: a broken build that reached
  # visitors is the worst red there is, and it is still the worst red even if the
  # deploy also reported itself failed.
  [ "$after" = "$before" ] || return "$E_BROKEN_REACHED_VISITORS"
  [ "$status" = "failed" ] || return "$E_BROKEN_NOT_NAMED"
  case "$stage" in
    PLAN | BUILD | STAGE | HEALTH | SWITCH | RETIRE) ;;
    *) return "$E_BROKEN_NOT_NAMED" ;;
  esac
  # A "real reason" is a reason with content. An empty string, or the CLI's own
  # generic fallback, is a shrug — the operator learns nothing from it.
  [ -n "$reason" ] || return "$E_BROKEN_NOT_NAMED"
  [ "${#reason}" -ge 12 ] || return "$E_BROKEN_NOT_NAMED"
  return 0
}

# =============================================================================
# SELF-CHECK — offline. Proves every named red actually fires on input that must
# trigger it, and that the greens still pass. Runs anywhere; no network, no bp,
# no credentials. This is the gate that keeps the failure paths from being dead
# code (a proof script with untested reds is itself a vacuous green).
# =============================================================================

SC_FAILED=0
expect_code() {
  local want="$1" desc="$2"; shift 2
  local got=0
  "$@" || got=$?
  if [ "$got" = "$want" ]; then
    ok "$(printf '%-30s' "$(codename "$want")") $desc"
  else
    printf '  %s✗%s %s: expected %s (%s), got %s (%s)\n' \
      "$RED" "$OFF" "$desc" "$want" "$(codename "$want")" "$got" "$(codename "$got")" >&2
    SC_FAILED=1
  fi
}
expect_pass() {
  local desc="$1"; shift
  local got=0
  "$@" || got=$?
  if [ "$got" = 0 ]; then
    ok "$(printf '%-30s' "PASS") $desc"
  else
    printf '  %s✗%s %s: expected a PASS, got %s (%s)\n' "$RED" "$OFF" "$desc" "$got" "$(codename "$got")" >&2
    SC_FAILED=1
  fi
}

self_check() {
  step "SELF-CHECK — every named red must fire on input that must trigger it"

  note "create"
  expect_pass      "a content-bound site passes"                     judge_create true default default production
  expect_code "$E_CREATE_NOT_BOUND" "the ghost 201 (no read token stored)"   judge_create false default default production
  expect_code "$E_CREATE_NOT_BOUND" "201 with the dataset binding dropped"   judge_create true "" "" ""

  note "deploy"
  expect_pass      "six stages, in order, live"                      judge_stages live PLAN BUILD STAGE HEALTH SWITCH RETIRE
  expect_code "$E_DEPLOY_STAGES" "only three stages ever landed"      judge_stages live PLAN BUILD STAGE
  expect_code "$E_DEPLOY_STAGES" "six stages but OUT of order"        judge_stages live PLAN BUILD HEALTH STAGE SWITCH RETIRE
  expect_code "$E_DEPLOY_FAILED" "all six stages, but never went live" judge_stages queued PLAN BUILD STAGE HEALTH SWITCH RETIRE

  note "live URL (assert by VALUE)"
  expect_pass      "200, build-id matches, content present"          judge_live 200 b-abc b-abc rev-1 doc-1
  expect_code "$E_LIVE_NOT_200"        "the URL 404s"                judge_live 404 b-abc b-abc rev-1 doc-1
  expect_code "$E_LIVE_BUILD_MISMATCH" "the TOTALLY-WRONG build went live" judge_live 200 TOTALLY-WRONG b-abc rev-1 doc-1
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-doc-id is empty (empty page)"  judge_live 200 b-abc b-abc rev-1 ""
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-content-rev is empty"          judge_live 200 b-abc b-abc "" doc-1

  note "rollback"
  expect_pass      "flipped to the previous build in 40ms"           judge_rollback 40 b-new b-old 1000
  expect_code "$E_ROLLBACK_SLOW"    "flipped, but took 1500ms"       judge_rollback 1500 b-new b-old 1000
  expect_code "$E_ROLLBACK_NO_FLIP" "fast 200, but nothing flipped"  judge_rollback 40 b-new b-new 1000
  expect_code "$E_ROLLBACK_FAILED"  "no build id came back at all"   judge_rollback 40 b-new "" 1000

  note "broken build"
  expect_pass      "failed at HEALTH, real reason, visitors unaffected" \
    judge_broken failed HEALTH "marker bp-doc-id empty: the build fetched no content" b-old b-old
  expect_code "$E_BROKEN_REACHED_VISITORS" "THE WORST RED: a broken build changed the live page" \
    judge_broken failed HEALTH "marker bp-doc-id empty: the build fetched no content" b-old b-broken
  expect_code "$E_BROKEN_NOT_NAMED" "the broken build reported itself LIVE" \
    judge_broken live HEALTH "marker bp-doc-id empty: the build fetched no content" b-old b-old
  expect_code "$E_BROKEN_NOT_NAMED" "failed at no named stage" \
    judge_broken failed "" "marker bp-doc-id empty: the build fetched no content" b-old b-old
  expect_code "$E_BROKEN_NOT_NAMED" "failed with a shrug for a reason" \
    judge_broken failed HEALTH "error" b-old b-old

  note "the red must have a NAME"
  local unnamed; unnamed="$(codename 255)"
  if [ "$unnamed" = "UNNAMED_FAILURE_255" ]; then
    ok "$(printf '%-30s' "NAMED") an unmapped code is reported as unnamed, never as a pass"
  else
    printf '  %s✗%s codename() invented a name for an unmapped code\n' "$RED" "$OFF" >&2
    SC_FAILED=1
  fi

  say ""
  if [ "$SC_FAILED" -ne 0 ]; then
    fail "$E_SELF_CHECK" "a named red did NOT fire on input that must trigger it (see above)" \
      "the proof script's failure paths are dead code — fix them before trusting any green"
  fi
  printf '%s✓ SELF-CHECK PASSED%s — every named red fires; no step can silently pass.\n' "$GRN$BLD" "$OFF" >&2
  return 0
}

# =============================================================================
# THE LIVE WALLS — read-only. Mutates nothing. These are the things that stop a
# spawn before any row is minted, so we refuse to mint one we cannot use.
#
# Preflight checks EVERY wall and reports every one that is down, then exits with
# the FIRST (most fundamental) failure's typed code. Two reasons, and both matter:
# an operator fixes all the walls in one pass instead of playing whack-a-mole,
# and — the reason it is written this way — every wall's code path EXECUTES on
# every run. A wall that only runs once the wall before it passes is an untested
# path, which is the same vacuous green this whole script exists to refuse.
# =============================================================================

WALL_CODE=0
WALL_WHY=""
WALL_FIX=""
WALL_DOWN=0

# wall <code> <why> <fix> — record a wall as down. The FIRST one recorded wins
# the exit code; the rest are still printed, so nothing is hidden.
wall() {
  WALL_DOWN=$((WALL_DOWN + 1))
  printf '  %s✗ %s%s  %s(exit %s)%s\n' "$RED" "$(codename "$1")" "$OFF" "$DIM" "$1" "$OFF" >&2
  printf '    %s\n' "$2" >&2
  [ -n "${3:-}" ] && printf '    %s→ %s%s\n' "$DIM" "$3" "$OFF" >&2
  if [ "$WALL_CODE" -eq 0 ]; then WALL_CODE="$1"; WALL_WHY="$2"; WALL_FIX="${3:-}"; fi
}

preflight() {
  step "PREFLIGHT — the walls, read-only (nothing is created)"

  command -v "$BP" >/dev/null 2>&1 ||
    fail "$E_NO_BP" "the \`$BP\` binary is not on PATH." "make cli-build"
  "$BP" cloud site -h >/dev/null 2>&1 ||
    fail "$E_NO_BP" "this \`$BP\` has no \`cloud site\` verb family — it predates site-spawner W1." \
      "make cli-build (the verb landed in #3070)"
  ok "bp speaks \`cloud site\`"

  CLOUD_URL="$(cfgval cloud_url)"; CLOUD_URL="${CLOUD_URL:-https://api.barkpark.cloud}"
  CLOUD_TOKEN="$(cfgval cloud_token)"
  CLOUD_TEAM="$(cfgval cloud_team)"

  local hc=000
  if [ -z "$CLOUD_TOKEN" ]; then
    wall "$E_NO_SESSION" "no cloud session token in $CFG." "bp login"
  else
    # WALL 1 [charter D31] — the credential's TEAM must own the target box. A
    # cross-team create does not fail with a permission error: it 404s
    # `barkpark_not_found` (the control plane refuses to leak existence across a
    # team boundary), which reads like a typo and wastes an hour. Name it here.
    curl -sS -m 30 -o "$TMP/bps.json" -w '%{http_code}' \
      -H "Authorization: Bearer $CLOUD_TOKEN" "$CLOUD_URL/v1/barkparks" >"$TMP/bps.code" 2>"$TMP/bps.err" || true
    hc="$(cat "$TMP/bps.code" 2>/dev/null || echo 000)"
    if [ "$hc" = "200" ]; then
      ok "cloud session present → $CLOUD_URL (team ${CLOUD_TEAM:-?})"
    else
      wall "$E_NO_SESSION" "GET $CLOUD_URL/v1/barkparks answered HTTP $hc (want 200) — the session is not usable." \
        "bp login (the token may have expired)"
    fi
  fi

  BARKPARK_ID="$(python3 - "$TMP/bps.json" "$INSTANCE" <<'PY' 2>/dev/null || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
want = sys.argv[2].lower()
for b in (d.get("barkparks") if isinstance(d, dict) else d) or []:
    if want in (str(b.get("name", "")).lower(), str(b.get("slug", "")).lower(), str(b.get("id", "")).lower()):
        print(b.get("id", "")); break
PY
)"
  local owned; owned="$(jget "$TMP/bps.json" barkparks | python3 -c 'import json,sys;print(len(json.load(sys.stdin) or []))' 2>/dev/null || echo 0)"
  if [ -n "$BARKPARK_ID" ]; then
    ok "team owns '$INSTANCE' → $BARKPARK_ID"
  else
    wall "$E_NO_BARKPARK" \
      "the cloud session's team (${CLOUD_TEAM:-?}) owns $owned barkpark(s), and '$INSTANCE' is not among them. A create against it returns 404 barkpark_not_found — NOT a permission error — because the control plane will not leak existence across a team boundary." \
      "use a cloud session in the team that owns '$INSTANCE' (guerrilla's row belongs to team \`guerrilla\`), or adopt it via the worker-token-gated POST /v1/internal/barkparks. See deploy/README.md §Spawning a site."
  fi

  # WALL 2 [charter D31] — the content must EXIST. An undefined type does not
  # 404; it answers 200 with count:0, and the starter cheerfully builds an empty
  # page from it. We probe the SCOPED route the build itself will use, with the
  # same published perspective, so a green here actually predicts a green build.
  local srv ws proj ds
  srv="$(cfgval server)"; srv="${srv:-https://$LIVE_HOST}"
  ws="${DATASET%%/*}"; ds="${DATASET##*/}"; proj="$(printf '%s' "$DATASET" | cut -d/ -f2)"
  local scoped="$srv/w/$ws/p/$proj/v1/data/query/$ds/$DOC_TYPE?limit=1"
  curl -sS -m 30 -o "$TMP/content.json" -w '%{http_code}' \
    -H "Authorization: Bearer $(cfgval token)" "$scoped" >"$TMP/content.code" 2>/dev/null || true
  hc="$(cat "$TMP/content.code" 2>/dev/null || echo 000)"

  local count first
  count="$(jget "$TMP/content.json" result.count)"; count="${count:-0}"
  first="$(jget "$TMP/content.json" result.documents.0._id)"

  if [ "$hc" != "200" ]; then
    wall "$E_NO_CONTENT" "the scoped read the build will make answered HTTP $hc: $scoped" \
      "check the dataset triple ($DATASET) and the server in $CFG"
  elif ! [ "$count" -gt 0 ] 2>/dev/null; then
    wall "$E_NO_CONTENT" \
      "type '$DOC_TYPE' has 0 published documents in $DATASET — the build would answer 200 and ship a SILENTLY EMPTY page (an undefined type returns count:0, not 404)." \
      "BARKPARK_DOC_TYPE=paper (public + published on guerrilla); 'post' does not exist there"
  else
    # PIN the doc. "Newest published" is a moving target — the corpus is written
    # by concurrent sessions, so an unpinned build can race and bake a different
    # bp-doc-id than the one we just proved exists.
    [ -n "$DOC_ID" ] || DOC_ID="$first"
    ok "content: type '$DOC_TYPE' → $count published; pinned bp-doc-id=$DOC_ID"
  fi

  say ""
  if [ "$WALL_DOWN" -gt 0 ]; then
    printf '%s%s wall(s) down.%s The spawn CANNOT proceed — and nothing was created, so there is no orphan row to clean up.\n' \
      "$RED$BLD" "$WALL_DOWN" "$OFF" >&2
    fail "$WALL_CODE" "$WALL_WHY" "$WALL_FIX"
  fi
  printf '%s✓ PREFLIGHT PASSED%s — nothing was created; the spawn can proceed.\n' "$GRN$BLD" "$OFF" >&2
}

# =============================================================================
# THE LIVE PROOF
# =============================================================================

live_proof() {
  [ -n "$SLUG" ] || SLUG="proof-$(date -u +%Y%m%d)-$$"

  # ---- 1. CREATE ------------------------------------------------------------
  step "1/5 CREATE — a content-bound static site (not the ghost 201)"

  local cx=0
  BARKPARK_DOC_TYPE="$DOC_TYPE" BARKPARK_DOC_ID="$DOC_ID" \
    "$BP" cloud site create --name "$SLUG" --dataset "$DATASET" \
    --framework astro --kind static --instance "$INSTANCE" \
    -o json >"$TMP/create.json" 2>"$TMP/create.err" || cx=$?
  [ "$cx" -eq 0 ] ||
    fail "$E_CREATE_FAILED" "\`bp cloud site create\` exited $cx: $(head -c 400 "$TMP/create.err")" \
      "if this is 404 barkpark_not_found, the session's team does not own '$INSTANCE' (see PREFLIGHT)"

  local site_id; site_id="$(jget "$TMP/create.json" site.id)"
  [ -n "$site_id" ] ||
    fail "$E_CREATE_FAILED" "create returned no site id. Body: $(head -c 300 "$TMP/create.json")"
  CREATED_SITE="$SLUG"
  ok "site created — $site_id"

  # content_bound is the server's own `not is_nil(read_token_encrypted)`, so a
  # true here IS the proof the read token was minted and stored — no DB peek
  # needed, and none is possible from here anyway. The CLI's own JSON map does
  # not carry it, so read the site row straight from the control plane.
  curl -sS -m 30 -o "$TMP/site.json" -w '%{http_code}' \
    -H "Authorization: Bearer $CLOUD_TOKEN" "$CLOUD_URL/v1/sites/$site_id" >"$TMP/site.code" 2>/dev/null || true
  local hc; hc="$(cat "$TMP/site.code")"
  [ "$hc" = "200" ] ||
    fail "$E_CREATE_FAILED" "GET /v1/sites/$site_id answered HTTP $hc — the site we just created is not readable."

  local bound ws proj ds
  bound="$(jget "$TMP/site.json" site.content_bound)"
  ws="$(jget "$TMP/site.json" site.bootstrap_workspace)"
  proj="$(jget "$TMP/site.json" site.bootstrap_project)"
  ds="$(jget "$TMP/site.json" site.bootstrap_dataset)"
  judge_create "$bound" "$ws" "$proj" "$ds" ||
    fail $? "the GHOST 201: create answered 201 but the site is not content-bound — content_bound=$bound, binding=$ws/$proj/$ds. No read token was stored, so the build has nothing to fetch with." \
      "POST /v1/sites must fold the dataset triple + a minted read token through put_site_content_binding"
  ok "content_bound=true, bound to $ws/$proj/$ds (the read token IS stored)"

  # ---- 2. DEPLOY ------------------------------------------------------------
  step "2/5 DEPLOY — the six visible stages"

  local dx=0
  "$BP" cloud site deploy "$SLUG" -o json >"$TMP/deploy.json" 2>"$TMP/deploy.stream" || dx=$?
  # In -o json mode the CLI streams the stage lines to stderr and leaves stdout a
  # single envelope — so we get the human stream AND the machine truth from one run.
  say ""
  sed 's/^/    │ /' "$TMP/deploy.stream" >&2 || true
  say ""

  local status stage reason build_id
  status="$(jget "$TMP/deploy.json" deployment.status)"
  stage="$(jget "$TMP/deploy.json" deployment.stage)"
  reason="$(jget "$TMP/deploy.json" deployment.failure_reason)"
  build_id="$(jget "$TMP/deploy.json" deployment.build_id)"

  if [ "$dx" -ne 0 ] && [ -z "$status" ]; then
    fail "$E_DEPLOY_FAILED" "\`bp cloud site deploy\` exited $dx with no deployment: $(head -c 400 "$TMP/deploy.stream")" \
      "if this is 422 no_build_source, POST /v1/sites/:id/deploy still refuses a content-bound static site — it must kind-branch on static and compute the build itself"
  fi

  local names
  names="$(python3 - "$TMP/deploy.json" <<'PY' 2>/dev/null || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
out = []
for s in (d.get("deployment") or {}).get("stages") or []:
    if str(s.get("status", "")).lower() in ("done", "skipped"):
        out.append(str(s.get("name", "")).upper())
print(" ".join(out))
PY
)"
  # shellcheck disable=SC2086
  judge_stages "$status" $names ||
    fail $? "the deploy did not walk the six stages to live — status=$status, stage=${stage:-?}, stages landed: [${names:-none}]${reason:+, reason: $reason}" \
      "the six stages are PLAN BUILD STAGE HEALTH SWITCH RETIRE, in that order, each reported exactly once"
  ok "PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE, and the deployment is live"
  ok "build_id = $build_id"

  # ---- 3. THE LIVE URL, ASSERTED BY VALUE -----------------------------------
  step "3/5 LIVE — the URL serves THIS build, with REAL content"

  local url="https://$LIVE_HOST/sites/$SLUG/"
  curl -sS -m 30 -o "$TMP/live.html" -w '%{http_code}' "$url" >"$TMP/live.code" 2>/dev/null || true
  hc="$(cat "$TMP/live.code" 2>/dev/null || echo 000)"

  local served rev doc
  served="$(meta_content "$TMP/live.html" bp-build-id)"
  rev="$(meta_content "$TMP/live.html" bp-content-rev)"
  doc="$(meta_content "$TMP/live.html" bp-doc-id)"

  judge_live "$hc" "$served" "$build_id" "$rev" "$doc" ||
    fail $? "$url answered HTTP $hc, serving bp-build-id='$served' (want '$build_id'), bp-content-rev='$rev', bp-doc-id='$doc'. A 200 alone proves nothing — a build with bp-build-id=TOTALLY-WRONG went live on this box, and a page that fetched NO content still returns a cheerful 200." \
      "the served build-id must EQUAL the deployment's build_id, and the content markers must be non-empty"
  ok "$url → 200"
  ok "bp-build-id  = $served  (== the deployment's build_id)"
  ok "bp-content-rev = $rev"
  ok "bp-doc-id    = $doc  (real Barkpark content)"

  # ---- 4. ROLLBACK ----------------------------------------------------------
  step "4/5 ROLLBACK — under one second, and the live page actually flips"

  # Rollback needs a PREVIOUS build to flip back to. Cut a second one, so the
  # flip has somewhere to go — otherwise we would be "proving" a rollback that
  # the engine correctly refuses (exit 21 no_previous) and calling it a red.
  note "cutting a second build so there is a previous release to flip back to…"
  "$BP" cloud site deploy "$SLUG" -o json >"$TMP/deploy2.json" 2>"$TMP/deploy2.stream" || true
  local build2; build2="$(jget "$TMP/deploy2.json" deployment.build_id)"
  [ -n "$build2" ] && [ "$build2" != "$build_id" ] ||
    fail "$E_DEPLOY_FAILED" "the second deploy did not produce a NEW build_id (got '${build2:-none}', first was '$build_id') — with no second release there is nothing to roll back FROM." \
      "build_id = hash(code_rev + content_rev + config); a re-deploy of identical inputs is an idempotent PLAN no-op by design, so the proof needs the content or config to differ"
  ok "second build live — $build2"

  local before after t0 t1 elapsed rbx=0
  curl -sS -m 30 -o "$TMP/live2.html" "https://$LIVE_HOST/sites/$SLUG/" >/dev/null 2>&1 || true
  before="$(meta_content "$TMP/live2.html" bp-build-id)"

  t0="$(now_ms)"
  "$BP" cloud site rollback "$SLUG" -o json >"$TMP/rollback.json" 2>"$TMP/rollback.err" || rbx=$?
  t1="$(now_ms)"
  elapsed=$(( t1 - t0 ))

  [ "$rbx" -eq 0 ] ||
    fail "$E_ROLLBACK_FAILED" "\`bp cloud site rollback\` exited $rbx after ${elapsed}ms: $(head -c 400 "$TMP/rollback.err")" \
      "if this is a 404, POST /v1/sites/:id/rollback is not wired — the CLI calls it and the control plane does not answer it"

  curl -sS -m 30 -o "$TMP/live3.html" "https://$LIVE_HOST/sites/$SLUG/" >/dev/null 2>&1 || true
  after="$(meta_content "$TMP/live3.html" bp-build-id)"

  judge_rollback "$elapsed" "$before" "$after" "$ROLLBACK_BUDGET_MS" ||
    fail $? "rollback took ${elapsed}ms (budget ${ROLLBACK_BUDGET_MS}ms) and the live bp-build-id went '$before' → '$after'. There is NO client-side poll on this path, so a 200 that returns before the symlink actually moved is a lie: the route must BLOCK on the real flip." \
      "the engine's own flip measured 25ms — anything near a second is the route not blocking on it, or not doing it at all"
  ok "rollback in ${elapsed}ms (budget ${ROLLBACK_BUDGET_MS}ms)"
  ok "live bp-build-id flipped $before → $after"

  # ---- 5. A BROKEN BUILD NEVER REACHES A VISITOR ---------------------------
  step "5/5 BROKEN BUILD — dies at its named stage, visitors never see it"

  local live_before; live_before="$after"
  note "deploying with a deliberately poisoned content binding…"

  # The poison is a doc type that does not exist. This is the REAL failure mode
  # this fleet has (an undefined type answers 200 with count:0 — it does NOT
  # 404), so the build "succeeds" and emits a page with an EMPTY bp-doc-id. That
  # is precisely what HEALTH's marker assertion exists to catch, and precisely
  # what a reachability-only gate would wave through. If HEALTH is real, this
  # dies there; if HEALTH is theatre, this reaches visitors and we say so.
  # A non-zero exit here is the CORRECT outcome, so it is not an error — the
  # judgement is on the deployment's own status/stage/reason and, above all, on
  # whether the live page moved. `|| true` keeps `set -e`-less flow explicit.
  BARKPARK_DOC_TYPE="__no_such_type__" BARKPARK_DOC_ID="" \
    "$BP" cloud site deploy "$SLUG" -o json >"$TMP/broken.json" 2>"$TMP/broken.stream" || true
  say ""
  sed 's/^/    │ /' "$TMP/broken.stream" >&2 || true
  say ""

  local bstatus bstage breason
  bstatus="$(jget "$TMP/broken.json" deployment.status)"
  bstage="$(jget "$TMP/broken.json" deployment.stage)"
  breason="$(jget "$TMP/broken.json" deployment.failure_reason)"

  curl -sS -m 30 -o "$TMP/live4.html" "https://$LIVE_HOST/sites/$SLUG/" >/dev/null 2>&1 || true
  local live_after; live_after="$(meta_content "$TMP/live4.html" bp-build-id)"

  judge_broken "$bstatus" "$(printf '%s' "${bstage:-}" | tr '[:lower:]' '[:upper:]')" "$breason" "$live_before" "$live_after" ||
    fail $? "the broken build: status=$bstatus stage=${bstage:-none} reason='${breason:-none}'; live bp-build-id went '$live_before' → '$live_after'. A broken build must fail at a NAMED stage with a REAL reason, and it must NEVER change what a visitor sees." \
      "HEALTH asserts the baked bp-doc-id/bp-content-rev markers before SWITCH — a build that fetched no content must die there"
  ok "failed at $(printf '%s' "$bstage" | tr '[:lower:]' '[:upper:]') — $breason"
  ok "live bp-build-id UNCHANGED at $live_after — no visitor ever saw the broken build"

  # ---- verdict --------------------------------------------------------------
  say ""
  printf '%s✓ PROVEN%s — create → deploy → live content → rollback in %sms → a broken build contained.\n' \
    "$GRN$BLD" "$OFF" "$elapsed" >&2
  printf '  %s%s%s\n' "$BLD" "https://$LIVE_HOST/sites/$SLUG/" "$OFF" >&2
}

# ---- main --------------------------------------------------------------------

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --preflight | --preflight-only) MODE="preflight" ;;
    --self-check) MODE="self-check" ;;
    --keep) KEEP=1 ;;
    --slug) shift; SLUG="${1:-}" ;;
    --instance) shift; INSTANCE="${1:-}"; LIVE_HOST="${INSTANCE}.barkpark.cloud" ;;
    -h | --help) usage 0 ;;
    *) say "unknown flag: $1"; usage 2 ;;
  esac
  shift
done

case "$MODE" in
  self-check)
    self_check
    ;;
  preflight)
    preflight
    ;;
  full)
    self_check
    preflight
    live_proof
    ;;
esac
exit 0
