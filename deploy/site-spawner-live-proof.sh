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
#   bash deploy/site-spawner-live-proof.sh --prebuilt --slug <site> [--dist <dir>]
#                                                       # the off-box build lane, ssh-free
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
#   39 CREATE_MINT_REFUSED         — the BOX refused the control plane's read-token mint
#                                    (a CP↔box credential fault, not a caller fault)
#   40 CREATE_FAILED                — `bp cloud site create` did not return a site
#   41 CREATE_NOT_CONTENT_BOUND     — the ghost 201: no read token stored, no dataset binding
#   42 PREBUILT_NOT_ENABLED         — the site has not opted in to prebuilt uploads
#   43 PREBUILT_NO_DIST             — there is no local build output to ship
#   44 PREBUILT_MINT_NOT_NAMED      — the mint did not name a deployment id + build id to build against
#   45 PREBUILT_SHIP_NOT_LIVE       — the uploaded bytes never reached live
#   46 PREBUILT_BUILD_NOT_SKIPPED   — the two runs AGREE about BUILD: the box built the prebuilt deploy too
#   47 PREBUILT_BUILD_NOT_FASTER    — BUILD did not differ by an order of magnitude between the two runs
#   48 PREBUILT_BYTES_NOT_LIVE      — the served page is not the build we uploaded
#   49 PREBUILT_BASE_BROKEN         — served bp-site-base != /sites/<slug>/ (every asset href is dead; HEALTH cannot see it)
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

# CONTENT REALITY [charter D31/D35]: there is NO `post` type on guerrilla, and an
# undefined type answers 200 with count:0 — NOT 404. The Astro starter's default
# doc type `post` therefore builds a silently EMPTY page. `paper` is public +
# published + real (100 docs). The type is now bound at CREATE via the
# `--doc-type` flag (D35: it becomes `sites.doc_type`, injected into the build's
# BARKPARK_DOC_TYPE by deploy_payload) — the old `BARKPARK_DOC_TYPE=… bp cloud
# site create` env prefix is INERT (the CLI swallowed it; BUILD_ALLOW dropped it).
# DOC_ID is only an example the preflight surfaces to PROVE published content
# exists — create binds a TYPE, and the build picks the featured doc itself, so
# the live check asserts bp-doc-id is NON-EMPTY, never equal to a pinned id.
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

# The repo root, so the prebuilt journey can build the SHIPPED starter no matter
# where it was invoked from.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

# ---- Named failures ----------------------------------------------------------

E_NO_BP=30
E_NO_SESSION=31
E_NO_BARKPARK=32
E_NO_CONTENT=33
E_CREATE_MINT_REFUSED=39
E_CREATE_FAILED=40
E_CREATE_NOT_BOUND=41
E_PB_NOT_ENABLED=42
E_PB_NO_DIST=43
E_PB_MINT_NOT_NAMED=44
E_PB_SHIP_NOT_LIVE=45
E_PB_BUILD_NOT_SKIPPED=46
E_PB_BUILD_NOT_FASTER=47
E_PB_BYTES_NOT_LIVE=48
E_PB_BASE_BROKEN=49
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
    "$E_CREATE_MINT_REFUSED") echo "CREATE_MINT_REFUSED" ;;
    "$E_CREATE_FAILED") echo "CREATE_FAILED" ;;
    "$E_CREATE_NOT_BOUND") echo "CREATE_NOT_CONTENT_BOUND" ;;
    "$E_PB_NOT_ENABLED") echo "PREBUILT_NOT_ENABLED" ;;
    "$E_PB_NO_DIST") echo "PREBUILT_NO_DIST" ;;
    "$E_PB_MINT_NOT_NAMED") echo "PREBUILT_MINT_NOT_NAMED" ;;
    "$E_PB_SHIP_NOT_LIVE") echo "PREBUILT_SHIP_NOT_LIVE" ;;
    "$E_PB_BUILD_NOT_SKIPPED") echo "PREBUILT_BUILD_NOT_SKIPPED" ;;
    "$E_PB_BUILD_NOT_FASTER") echo "PREBUILT_BUILD_NOT_FASTER" ;;
    "$E_PB_BYTES_NOT_LIVE") echo "PREBUILT_BYTES_NOT_LIVE" ;;
    "$E_PB_BASE_BROKEN") echo "PREBUILT_BASE_BROKEN" ;;
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

# cli_err <stdout-file> <stderr-file> — the REASON a `bp … -o json` call failed.
#
# WHY THIS EXISTS. In `-o json` mode the CLI writes its error ENVELOPE to
# STDOUT ({"ok":false,"error":{"code":…,"message":…}}) and leaves stderr EMPTY.
# Every call site here quoted stderr, so a fully-diagnosed control-plane refusal
# ("guerrilla refused to mint the site's read token (HTTP 403): forbidden —
# caller is not a member of this workspace") printed as a BLANK — the operator
# saw `exited 8:` and nothing else, and the script's whole promise is that a red
# names its reason. Reads the envelope first, falls back to stderr, and says so
# explicitly when there is genuinely no output rather than printing emptiness.
cli_err() {
  local msg
  msg="$(jget "$1" error.message)"
  [ -n "$msg" ] || msg="$(jget "$1" error.code)"
  [ -n "$msg" ] || msg="$(head -c 400 "${2:-/dev/null}" 2>/dev/null)"
  [ -n "$msg" ] || msg="(the CLI produced no error envelope and no stderr)"
  printf '%s' "$msg"
}

# cli_err_code <stdout-file> — the envelope's machine `error.code`, or "".
cli_err_code() { jget "$1" error.code; }

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
CREATED_BROKEN=""
# cleanup — tear down every site THIS RUN created, unless --keep.
#
# ssw8: this used to refuse to delete and told the operator "there is no DELETE
# /v1/sites/:id route yet". That claim went STALE — the route landed (cloud
# router `delete "/v1/sites/:id"`) together with the CLI verb (`bp cloud site
# delete <site> --yes`), and it is the teardown that ALSO revokes the site's
# minted read token by label. While the script kept repeating the old sentence,
# every green run leaked a sites row, a releases dir, a Caddy block AND a live
# read credential — the exact orphan the proof is supposed to prove away.
#
# A failed delete is REPORTED, never swallowed: the operator gets the manual
# steps. Cleanup never changes the run's verdict — it runs from the EXIT trap,
# so `exit "$code"` in fail() has already fixed the exit status.
# CLEANUP RUNS AT MOST ONCE. `fail()` calls cleanup and then exits, which fires
# the EXIT trap and would call it a SECOND time — and now that cleanup performs a
# real DELETE rather than printing a note, the second pass is not harmless: the
# first pass already removed $TMP, so the delete cannot even write its receipt,
# and the run ends by telling the operator "DELETE FAILED … The site's read token
# is STILL LIVE" about a site it had just successfully deleted. A measured run
# printed exactly that. Deleting each slug is also latched, so a re-entry can
# never re-delete a name another run may since have taken.
CLEANED=0
cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ "$KEEP" -eq 0 ]; then
    local s dx
    for s in "$CREATED_SITE" "$CREATED_BROKEN"; do
      [ -n "$s" ] || continue
      say ""
      note "cleanup: deleting the demo site '$s' (this also revokes its minted read token)…"
      dx=0
      "$BP" cloud site delete "$s" --yes >"${TMP:-/tmp}/del-$s.json" 2>"${TMP:-/tmp}/del-$s.err" || dx=$?
      if [ "$dx" -eq 0 ]; then
        case "$s" in
          "$CREATED_SITE") CREATED_SITE="" ;;
          "$CREATED_BROKEN") CREATED_BROKEN="" ;;
        esac
        ok "cleanup: '$s' deleted from the control plane"
      else
        note "cleanup: DELETE FAILED for '$s' (exit $dx): $(cli_err "${TMP:-/tmp}/del-$s.json" "${TMP:-/tmp}/del-$s.err")"
        note "         Remove by hand: \`$BP cloud site delete $s --yes\`, or on $LIVE_HOST →"
        note "         rm -rf /opt/barkpark/sites/$s and drop the '# barkpark-site:$s' guarded"
        note "         handle_path block from /etc/caddy/Caddyfile. The site's read token is STILL LIVE."
      fi
    done
  else
    local k
    for k in "$CREATED_SITE" "$CREATED_BROKEN"; do
      [ -n "$k" ] || continue
      note "cleanup: --keep — '$k' is LEFT IN PLACE (its read token stays live)."
    done
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

# judge_create_failure <envelope-error-code> — classify a FAILED create.
#
# `read_token_mint_failed` is not a caller fault and must not wear the same name
# as one. The control plane relays the site's read-token mint to the box with
# ITS OWN stored admin credential (Registry.mint_public_read_token/5 →
# relay_admin → POST /w/:ws/p/:proj/v1/tokens); when the box answers 403
# `not_a_member`, the caller's own session can be perfectly valid — and it IS,
# because PREFLIGHT just proved the team owns the box. Nothing the operator does
# to their own login fixes it: the remedy is re-seating the CONTROL PLANE's
# admin token for that instance. Naming it CREATE_FAILED sends them to `bp
# login`, which is the one thing that cannot help.
judge_create_failure() {
  case "$1" in
    read_token_mint_failed) return "$E_CREATE_MINT_REFUSED" ;;
    *) return "$E_CREATE_FAILED" ;;
  esac
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

# judge_live <http_code> <served_build_id> <expected_build_id> <content_rev> <doc_id> <doc_title> <site_base>
# Assert by VALUE, not by reachability, over ALL FIVE markers Base.astro bakes.
# A build with bp-build-id=TOTALLY-WRONG went live on this box a day ago and a
# reachability check called it green — hence the equality on bp-build-id, and
# hence the non-empty bp-content-rev/bp-doc-id/bp-doc-title/bp-site-base (a page
# that rendered with NO content still returns a cheerful 200). The four
# content-truth markers are asserted TOGETHER: any one empty is a vacuous green.
judge_live() {
  local code="$1" served="$2" expect="$3" rev="$4" doc="$5" title="$6" base="$7"
  [ "$code" = "200" ] || return "$E_LIVE_NOT_200"
  [ -n "$expect" ] || return "$E_LIVE_BUILD_MISMATCH"
  [ "$served" = "$expect" ] || return "$E_LIVE_BUILD_MISMATCH"
  [ -n "$rev" ] && [ -n "$doc" ] && [ -n "$title" ] && [ -n "$base" ] || return "$E_LIVE_CONTENT_EMPTY"
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

# ---- the prebuilt lane's judges (charter D85/D103) ---------------------------
#
# THE ORACLE PROBLEM, AND WHY THESE ARE THE ANSWER. The claim under test is "the
# SERVING BOX ran no npm for this deploy". The human walk proved it with `ps` over
# ssh. A harness a stranger can run has no shell on that box, so the oracle here
# is THE ENGINE'S OWN WORDS: the SAME site is deployed twice, once with
# `--prebuilt` and once from source, and the two runs must DISAGREE about BUILD —
# skipped versus a real build, and a BUILD duration an ORDER OF MAGNITUDE apart,
# taken from the engine's own per-stage started_at/finished_at. A box that
# secretly ran npm on the prebuilt deploy cannot produce that pair.

# judge_prebuilt_mint <deployment_id> <build_id> <content_rev>
# The mint is the only place a client can learn the build id its bytes must carry
# (HEALTH asserts that marker by value) — and the deployment id to resume against,
# because the mint is NONCED and a plain re-run can never converge on the same id.
#
# CONTENT_REV IS JUDGED HERE, NOT SHRUGGED AT. This used to be optional
# (`[ -n "$mint_crev" ] && ok …`) and a measured live run walked straight past an
# EMPTY one — the CLI only prints the export when the control plane actually
# minted a content rev, so an absent line is silence, not a default. The journey
# then fed that empty string to build #2, which baked `bp-content-rev=""`, which
# `deploy/site-deploy.sh` HEALTH refuses by name ("bp-content-rev marker is empty
# — the build lost its content link"). The operator would read a HEALTH failure
# blaming their BUILD three steps after the real cause: a mint receipt that never
# carried the value. Failing at the mint keeps the red where the fault is.
judge_prebuilt_mint() {
  local dep="$1" build="$2" crev="${3-}"
  [ -n "$dep" ] && [ -n "$build" ] || return "$E_PB_MINT_NOT_NAMED"
  [ -n "$crev" ] || return "$E_PB_MINT_NOT_NAMED"
  return 0
}

# judge_prebuilt_ship <deployment_status>
judge_prebuilt_ship() {
  [ "$1" = "live" ] || return "$E_PB_SHIP_NOT_LIVE"
  return 0
}

# judge_build_disagree <prebuilt_build_status> <source_build_status>
# The prebuilt run must report BUILD skipped and the source run must report a real
# BUILD. AGREEMENT is the red: two skips would mean the source deploy did not
# build either (so the comparison proves nothing), and a done/ok on the prebuilt
# side means the box built the uploaded bytes' site anyway.
judge_build_disagree() {
  local pb="$1" src="$2"
  [ "$pb" = "skipped" ] || return "$E_PB_BUILD_NOT_SKIPPED"
  case "$src" in
    done | ok) ;;
    *) return "$E_PB_BUILD_NOT_SKIPPED" ;;
  esac
  return 0
}

# judge_build_orders <prebuilt_build_ms> <source_build_ms> [factor]
# An order of magnitude, with a FLOOR on the source side: a "source build" that
# took 40ms did not run npm either, so the ratio would be a comparison between two
# no-ops. A real Astro build on this fleet is tens of seconds; 1000ms is the
# generous line under which we refuse to call it a build at all.
judge_build_orders() {
  local pb="$1" src="$2" factor="${3:-10}"
  [ "$pb" -ge 0 ] 2>/dev/null || return "$E_PB_BUILD_NOT_FASTER"
  [ "$src" -ge 1000 ] 2>/dev/null || return "$E_PB_BUILD_NOT_FASTER"
  [ "$src" -ge $(( (pb + 1) * factor )) ] || return "$E_PB_BUILD_NOT_FASTER"
  return 0
}

# judge_prebuilt_live <http_code> <served_build_id> <minted_build_id>
# "The uploaded bytes are what is live": the page the public gets must carry the
# build id the mint handed out, which is the one stamped into the bytes we packed.
judge_prebuilt_live() {
  local code="$1" served="$2" expect="$3"
  [ "$code" = "200" ] || return "$E_PB_BYTES_NOT_LIVE"
  [ -n "$expect" ] || return "$E_PB_BYTES_NOT_LIVE"
  [ "$served" = "$expect" ] || return "$E_PB_BYTES_NOT_LIVE"
  return 0
}

# judge_site_base <served_bp_site_base> <want_base>
# The one marker HEALTH does NOT assert (it checks bp-build-id, bp-content-rev and
# bp-doc-id). Every asset href on the page is prefixed with this base, so a wrong
# value serves a 200 whose CSS and JS all 404 — a green deploy of a broken page.
# The value has to be the PATH `/sites/<slug>/`: astro.config.mjs prefixes a
# leading slash to anything not already leading-slashed, so a full URL here bakes
# base="/https://host/sites/slug/" and kills every asset.
judge_site_base() {
  local got="$1" want="$2"
  [ -n "$got" ] || return "$E_PB_BASE_BROKEN"
  [ "$got" = "$want" ] || return "$E_PB_BASE_BROKEN"
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

  note "create failure — the BOX's refusal must not wear the CALLER's name"
  expect_code "$E_CREATE_MINT_REFUSED" "the box refused the CP's read-token mint" judge_create_failure read_token_mint_failed
  expect_code "$E_CREATE_FAILED" "a cross-team create (caller's own fault)"       judge_create_failure barkpark_not_found
  expect_code "$E_CREATE_FAILED" "an unrecognised refusal still fails, by name"   judge_create_failure some_new_error
  expect_code "$E_CREATE_FAILED" "no envelope code at all"                        judge_create_failure ""

  note "deploy"
  expect_pass      "six stages, in order, live"                      judge_stages live PLAN BUILD STAGE HEALTH SWITCH RETIRE
  expect_code "$E_DEPLOY_STAGES" "only three stages ever landed"      judge_stages live PLAN BUILD STAGE
  expect_code "$E_DEPLOY_STAGES" "six stages but OUT of order"        judge_stages live PLAN BUILD HEALTH STAGE SWITCH RETIRE
  expect_code "$E_DEPLOY_FAILED" "all six stages, but never went live" judge_stages queued PLAN BUILD STAGE HEALTH SWITCH RETIRE

  note "live URL (assert by VALUE, all five markers)"
  expect_pass      "200, build-id matches, all four content markers present" judge_live 200 b-abc b-abc rev-1 doc-1 title-1 /sites/x/
  expect_code "$E_LIVE_NOT_200"        "the URL 404s"                judge_live 404 b-abc b-abc rev-1 doc-1 title-1 /sites/x/
  expect_code "$E_LIVE_BUILD_MISMATCH" "the TOTALLY-WRONG build went live" judge_live 200 TOTALLY-WRONG b-abc rev-1 doc-1 title-1 /sites/x/
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-doc-id is empty (empty page)"  judge_live 200 b-abc b-abc rev-1 "" title-1 /sites/x/
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-content-rev is empty"          judge_live 200 b-abc b-abc "" doc-1 title-1 /sites/x/
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-doc-title is empty"            judge_live 200 b-abc b-abc rev-1 doc-1 "" /sites/x/
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-site-base is empty"            judge_live 200 b-abc b-abc rev-1 doc-1 title-1 ""

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

  note "prebuilt lane (the off-box build, judged by the ENGINE'S OWN WORDS)"
  expect_pass      "the mint named a deployment, a build id and a content rev" judge_prebuilt_mint dep-1 b-abc rev-1
  expect_code "$E_PB_MINT_NOT_NAMED" "minted with no deployment id (nothing to resume)" judge_prebuilt_mint "" b-abc rev-1
  expect_code "$E_PB_MINT_NOT_NAMED" "minted with no build id (nothing to stamp)"       judge_prebuilt_mint dep-1 "" rev-1
  expect_code "$E_PB_MINT_NOT_NAMED" "minted with an EMPTY content rev (HEALTH would blame the build)" judge_prebuilt_mint dep-1 b-abc ""
  expect_pass      "the uploaded bytes reached live"                 judge_prebuilt_ship live
  expect_code "$E_PB_SHIP_NOT_LIVE" "the upload stalled at queued"   judge_prebuilt_ship queued
  expect_code "$E_PB_SHIP_NOT_LIVE" "the upload died"                judge_prebuilt_ship failed
  expect_pass      "prebuilt BUILD skipped, source BUILD done"       judge_build_disagree skipped "done"
  expect_code "$E_PB_BUILD_NOT_SKIPPED" "THE CORE RED: the box built the prebuilt deploy too" \
    judge_build_disagree "done" "done"
  expect_code "$E_PB_BUILD_NOT_SKIPPED" "both runs skipped — the comparison proves nothing" \
    judge_build_disagree skipped skipped
  expect_code "$E_PB_BUILD_NOT_SKIPPED" "the source run reported no BUILD stage at all" \
    judge_build_disagree skipped missing
  expect_pass      "BUILD 0ms vs 47000ms — orders apart"             judge_build_orders 0 47000
  expect_code "$E_PB_BUILD_NOT_FASTER" "42000ms vs 47000ms — the same build twice" judge_build_orders 42000 47000
  expect_code "$E_PB_BUILD_NOT_FASTER" "the 'source' BUILD took 40ms — that is not a build either" \
    judge_build_orders 0 40
  expect_pass      "the served page carries the minted build id"     judge_prebuilt_live 200 b-mint b-mint
  expect_code "$E_PB_BYTES_NOT_LIVE" "the site 404s after the upload"        judge_prebuilt_live 404 b-mint b-mint
  expect_code "$E_PB_BYTES_NOT_LIVE" "200, but an OLDER build is still live" judge_prebuilt_live 200 b-old b-mint
  expect_pass      "bp-site-base is the /sites/<slug>/ path"         judge_site_base /sites/perfect-proof/ /sites/perfect-proof/
  expect_code "$E_PB_BASE_BROKEN" "bp-site-base is a full URL — every asset href is dead" \
    judge_site_base "/https://guerrilla.barkpark.cloud/sites/perfect-proof/" /sites/perfect-proof/
  expect_code "$E_PB_BASE_BROKEN" "bp-site-base is empty"            judge_site_base "" /sites/perfect-proof/

  # The reason a red is legible at all. `bp … -o json` puts its error ENVELOPE on
  # STDOUT and leaves stderr EMPTY; quoting stderr printed a BLANK reason for a
  # fully-diagnosed refusal, which is how a 403 not_a_member reached an operator
  # as "exited 8:" and nothing more. Guarded here so it cannot regress silently.
  note "the reason must survive the -o json split (envelope on STDOUT)"
  local sc_out="$TMP/sc-env.json" sc_err="$TMP/sc-env.err"
  printf '%s' '{"ok":false,"error":{"code":"read_token_mint_failed","message":"guerrilla refused to mint the site read token (HTTP 403): forbidden"}}' >"$sc_out"
  : >"$sc_err"
  case "$(cli_err "$sc_out" "$sc_err")" in
    *"refused to mint"*) ok "$(printf '%-30s' "REASON") the envelope's message is read from STDOUT, not empty stderr" ;;
    *) printf '  %s✗%s cli_err lost the envelope message — a diagnosed refusal would print blank\n' "$RED" "$OFF" >&2; SC_FAILED=1 ;;
  esac
  printf '%s' '{"not":"an envelope"}' >"$sc_out"; printf '%s' 'stderr had it' >"$sc_err"
  case "$(cli_err "$sc_out" "$sc_err")" in
    *"stderr had it"*) ok "$(printf '%-30s' "REASON") falls back to stderr when there is no envelope" ;;
    *) printf '  %s✗%s cli_err did not fall back to stderr\n' "$RED" "$OFF" >&2; SC_FAILED=1 ;;
  esac
  : >"$sc_out"; : >"$sc_err"
  case "$(cli_err "$sc_out" "$sc_err")" in
    *"no error envelope"*) ok "$(printf '%-30s' "REASON") says so out loud when there is genuinely no output" ;;
    *) printf '  %s✗%s cli_err printed emptiness instead of naming it\n' "$RED" "$OFF" >&2; SC_FAILED=1 ;;
  esac

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
  # The claim is bounded ON PURPOSE. These walls are about the CALLER's session:
  # that it exists, that its team owns the box, and that the content it names is
  # really there. There is one wall left that NO read-only client-side check can
  # reach — the CONTROL PLANE's own stored admin credential for this instance,
  # which it uses to mint the site's read token against the box. Exercising it
  # requires the mint, and the mint is a WRITE, so it cannot be probed without
  # creating something. It is proven INLINE at CREATE instead, and it has its own
  # named red (CREATE_MINT_REFUSED) so it can never be read as a caller fault.
  # An earlier version of this line said "the spawn can proceed" and was WRONG in
  # exactly that gap: a run that passed every wall here still died at CREATE.
  printf '%s✓ PREFLIGHT PASSED%s — nothing was created. The caller-side walls are down;\n' "$GRN$BLD" "$OFF" >&2
  printf '  the control plane'"'"'s own box credential is proven at CREATE (it cannot be read-probed).\n' >&2
}

# =============================================================================
# THE LIVE PROOF
# =============================================================================

live_proof() {
  [ -n "$SLUG" ] || SLUG="proof-$(date -u +%Y%m%d)-$$"

  # ---- 1. CREATE ------------------------------------------------------------
  step "1/5 CREATE — a content-bound static site (not the ghost 201)"

  # doc_type is bound HERE (D35) via the --doc-type flag — it lands in
  # sites.doc_type and deploy_payload injects it as BARKPARK_DOC_TYPE at BUILD.
  # The old `BARKPARK_DOC_TYPE=… bp cloud site create` env prefix is INERT.
  local cx=0
  "$BP" cloud site create --name "$SLUG" --dataset "$DATASET" \
    --framework astro --kind static --instance "$INSTANCE" \
    --doc-type "$DOC_TYPE" \
    -o json >"$TMP/create.json" 2>"$TMP/create.err" || cx=$?
  if [ "$cx" -ne 0 ]; then
    local ccode chint
    ccode="$(cli_err_code "$TMP/create.json")"
    case "$ccode" in
      read_token_mint_failed)
        chint="NOT your login: the control plane mints the site's read token with ITS OWN stored admin credential for '$INSTANCE' (relay_admin → POST /w/<ws>/p/<proj>/v1/tokens). A 403 not_a_member there means THAT credential is no longer a member of the '${DATASET%%/*}' workspace — re-seat the instance's admin token in the control plane. Confirm the split by hand: your own token on the same route should answer 200." ;;
      barkpark_not_found)
        chint="the session's team does not own '$INSTANCE' (see PREFLIGHT)" ;;
      *)
        chint="if this is 404 barkpark_not_found, the session's team does not own '$INSTANCE' (see PREFLIGHT)" ;;
    esac
    judge_create_failure "$ccode" ||
      fail $? "\`bp cloud site create\` exited $cx${ccode:+ ($ccode)}: $(cli_err "$TMP/create.json" "$TMP/create.err")" "$chint"
  fi

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
    fail "$E_DEPLOY_FAILED" "\`bp cloud site deploy\` exited $dx with no deployment: $(cli_err "$TMP/deploy.json" "$TMP/deploy.stream")" \
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

  # This curl is the FIRST live exercise of the SWITCH stage's Caddy arm
  # (arm_caddy_site_route, non-fatal `|| true` in the engine). A green SWITCH
  # stage is NOT trusted — only an actual 200 from the public FQDN, carrying the
  # deployment's own build_id, proves the path-handle block armed and reloaded.
  # The live Caddyfile anchor (reverse_proxy localhost:4001) is confirmed present.
  local url="https://$LIVE_HOST/sites/$SLUG/"
  curl -sS -m 30 -o "$TMP/live.html" -w '%{http_code}' "$url" >"$TMP/live.code" 2>/dev/null || true
  hc="$(cat "$TMP/live.code" 2>/dev/null || echo 000)"

  local served rev doc title base
  served="$(meta_content "$TMP/live.html" bp-build-id)"
  rev="$(meta_content "$TMP/live.html" bp-content-rev)"
  doc="$(meta_content "$TMP/live.html" bp-doc-id)"
  title="$(meta_content "$TMP/live.html" bp-doc-title)"
  base="$(meta_content "$TMP/live.html" bp-site-base)"

  judge_live "$hc" "$served" "$build_id" "$rev" "$doc" "$title" "$base" ||
    fail $? "$url answered HTTP $hc, serving bp-build-id='$served' (want '$build_id'), bp-content-rev='$rev', bp-doc-id='$doc', bp-doc-title='$title', bp-site-base='$base'. A 200 alone proves nothing — a build with bp-build-id=TOTALLY-WRONG went live on this box, and a page that fetched NO content still returns a cheerful 200." \
      "the served build-id must EQUAL the deployment's build_id, and all four content markers (bp-content-rev/bp-doc-id/bp-doc-title/bp-site-base) must be non-empty"
  ok "$url → 200  (SWITCH's Caddy arm armed for real)"
  ok "bp-build-id   = $served  (== the deployment's build_id)"
  ok "bp-content-rev = $rev"
  ok "bp-doc-id     = $doc"
  ok "bp-doc-title  = $title  (real Barkpark content)"
  ok "bp-site-base  = $base"

  # ---- 4. ROLLBACK ----------------------------------------------------------
  step "4/5 ROLLBACK — under one second, and the live page actually flips"

  # Rollback needs a PREVIOUS build to flip back to. Cut a second one with --force
  # (D36) so the flip has somewhere to go. --force folds a fresh nonce into the
  # build_id config, minting a genuinely NEW build_id even on UNCHANGED content —
  # WITHOUT it a re-deploy of identical inputs is an idempotent PLAN no-op (it
  # returns the SAME build_id) and there would be nothing to roll back FROM.
  note "cutting a second build with --force so there is a previous release to flip back to…"
  "$BP" cloud site deploy "$SLUG" --force -o json >"$TMP/deploy2.json" 2>"$TMP/deploy2.stream" || true
  local build2; build2="$(jget "$TMP/deploy2.json" deployment.build_id)"
  [ -n "$build2" ] && [ "$build2" != "$build_id" ] ||
    fail "$E_DEPLOY_FAILED" "the second (--force) deploy did not produce a NEW build_id (got '${build2:-none}', first was '$build_id') — with no second release there is nothing to roll back FROM." \
      "--force must fold a nonce into build_id = hash(code_rev + content_rev + config + nonce); if build2 == build_id the force nonce is not being minted (see site-spawner-w4-deploy-inputs / site-spawner-deploy-force-rebuild)"
  ok "second build live — $build2"

  local before after t0 t1 elapsed rbx=0
  curl -sS -m 30 -o "$TMP/live2.html" "https://$LIVE_HOST/sites/$SLUG/" >/dev/null 2>&1 || true
  before="$(meta_content "$TMP/live2.html" bp-build-id)"

  t0="$(now_ms)"
  "$BP" cloud site rollback "$SLUG" -o json >"$TMP/rollback.json" 2>"$TMP/rollback.err" || rbx=$?
  t1="$(now_ms)"
  elapsed=$(( t1 - t0 ))

  [ "$rbx" -eq 0 ] ||
    fail "$E_ROLLBACK_FAILED" "\`bp cloud site rollback\` exited $rbx after ${elapsed}ms: $(cli_err "$TMP/rollback.json" "$TMP/rollback.err")" \
      "if this is a 404, POST /v1/sites/:id/rollback is not wired — the CLI calls it and the control plane does not answer it"

  curl -sS -m 30 -o "$TMP/live3.html" "https://$LIVE_HOST/sites/$SLUG/" >/dev/null 2>&1 || true
  after="$(meta_content "$TMP/live3.html" bp-build-id)"

  judge_rollback "$elapsed" "$before" "$after" "$ROLLBACK_BUDGET_MS" ||
    fail $? "rollback took ${elapsed}ms (budget ${ROLLBACK_BUDGET_MS}ms) and the live bp-build-id went '$before' → '$after'. There is NO client-side poll on this path, so a 200 that returns before the symlink actually moved is a lie: the route must BLOCK on the real flip." \
      "the engine's own flip measured 25ms — anything near a second is the route not blocking on it, or not doing it at all"
  ok "rollback in ${elapsed}ms (budget ${ROLLBACK_BUDGET_MS}ms)"
  ok "live bp-build-id flipped $before → $after"

  # ---- 5. A BROKEN BUILD NEVER REACHES A VISITOR ---------------------------
  local live_before; live_before="$after"

  # WHY THE POISON IS A PREBUILT UPLOAD AND NO LONGER A SECOND SITE.
  #
  # This arm used to create a SEPARATE site bound to a doc type that does not
  # exist, on the reasoning that an undefined type answers 200 with count:0 and
  # so builds a silently EMPTY page. That poison is now UNBUILDABLE, and by a
  # deliberate product change: the control plane's binding guard (W8/D73) reads
  # the binding at CREATE and refuses a site that would build from nothing —
  # measured live, `--doc-type __no_such_type__` now answers 422 with "this site
  # would build from nothing … It can read: task (7749), paper (1050), … No site
  # was created." The old arm therefore died at CREATE_FAILED without ever
  # reaching the gate it exists to test, and a proof that cannot construct its
  # own negative case is not proving containment.
  #
  # So the poison is now made the way a real broken build actually reaches a box:
  # bytes that pass every CLIENT-side check and fail the BOX's HEALTH gate. We
  # take the page that is ALREADY LIVE (a genuine build output — no npm needed
  # here, which keeps this arm's dependencies exactly `bp` and `curl`), stamp it
  # with the build id the mint hands out so the CLI will upload it, and BLANK its
  # bp-doc-id. `deploy/site-deploy.sh` HEALTH asserts that marker non-empty
  # ("bp-doc-id marker is empty — the build rendered no content document"), so
  # the deploy must die at HEALTH, must never SWITCH, and the live URL must still
  # serve the PREVIOUS build. It also keeps the whole arm on ONE site: no second
  # row to create, and none to leak.
  step "5/5 BROKEN BUILD — dies at its named stage, visitors never see it"

  local sx5=0
  "$BP" cloud site settings "$SLUG" --prebuilt-enabled true -o json \
    >"$TMP/p5-settings.json" 2>"$TMP/p5-settings.err" || sx5=$?
  [ "$sx5" -eq 0 ] ||
    fail "$E_BROKEN_NOT_NAMED" "could not opt '$SLUG' into prebuilt uploads, so the poison cannot be shipped: $(cli_err "$TMP/p5-settings.json" "$TMP/p5-settings.err")" \
      "prebuilt uploads are per-site and OFF by default; this arm needs them to ship bytes the box did not build"

  # The bytes: the page that is live right now, which is a real build output.
  local pdist="$TMP/poison"
  mkdir -p "$pdist"
  curl -sS -m 30 -o "$pdist/index.html" "https://$LIVE_HOST/sites/$SLUG/" 2>/dev/null || true
  [ -s "$pdist/index.html" ] ||
    fail "$E_BROKEN_NOT_NAMED" "could not fetch the live page to build a poison from." \
      "the live URL served nothing, so there is no real build output to corrupt"

  # Mint: the refusal names the deployment to resume and the build id the bytes
  # must carry (the mint is nonced, so this cannot be known in advance).
  "$BP" cloud site deploy "$SLUG" --prebuilt "$pdist" >"$TMP/p5-mint.out" 2>"$TMP/p5-mint.err" || true
  local p5all p5dep p5bid p5crev
  p5all="$(cat "$TMP/p5-mint.out" "$TMP/p5-mint.err" 2>/dev/null)"
  p5dep="$(printf '%s\n' "$p5all" | sed -n 's/.*--deployment \([A-Za-z0-9][A-Za-z0-9-]*\).*/\1/p' | tail -n 1)"
  p5bid="$(printf '%s\n' "$p5all" | sed -n 's/.*BARKPARK_BUILD_ID=\([^ ]*\).*/\1/p' | tail -n 1)"
  p5crev="$(printf '%s\n' "$p5all" | sed -n 's/.*BARKPARK_CONTENT_REV=\([^ ]*\).*/\1/p' | tail -n 1)"
  [ -n "$p5dep" ] && [ -n "$p5bid" ] ||
    fail "$E_BROKEN_NOT_NAMED" "the poison mint named deployment='${p5dep:-none}' build_id='${p5bid:-none}' — nothing to ship the corrupt bytes to. Output: $(printf '%s' "$p5all" | head -c 300)"

  # Stamp the id the box expects (so the CLIENT lets it through), then blank the
  # one marker HEALTH refuses to accept empty. This is the whole poison.
  restamp_markers "$pdist" "$p5bid" "$p5crev" >/dev/null
  python3 - "$pdist/index.html" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
s = re.sub(r'(<meta[^>]*name="bp-doc-id"[^>]*content=")[^"]*(")', r'\1\2', s)
open(p, "w", encoding="utf-8").write(s)
PY
  [ -z "$(meta_content "$pdist/index.html" bp-doc-id)" ] ||
    fail "$E_BROKEN_NOT_NAMED" "could not blank bp-doc-id in the poison bytes — the negative case was never constructed, so this arm would prove nothing."
  note "poison built: build id $p5bid, bp-doc-id BLANKED (HEALTH must refuse it)"

  note "shipping the poison — it must die at HEALTH and never switch…"
  "$BP" cloud site deploy "$SLUG" --prebuilt "$pdist" --deployment "$p5dep" -o json \
    >"$TMP/broken.json" 2>"$TMP/broken.stream" || true
  say ""
  sed 's/^/    │ /' "$TMP/broken.stream" >&2 || true
  say ""

  local bstatus bstage breason
  bstatus="$(jget "$TMP/broken.json" deployment.status)"
  bstage="$(jget "$TMP/broken.json" deployment.stage)"
  breason="$(jget "$TMP/broken.json" deployment.failure_reason)"

  # Containment: the live page is UNCHANGED — a failed deploy never reaches a visitor.
  curl -sS -m 30 -o "$TMP/live4.html" "https://$LIVE_HOST/sites/$SLUG/" >/dev/null 2>&1 || true
  local live_after; live_after="$(meta_content "$TMP/live4.html" bp-build-id)"

  judge_broken "$bstatus" "$(printf '%s' "${bstage:-}" | tr '[:lower:]' '[:upper:]')" "$breason" "$live_before" "$live_after" ||
    fail $? "the broken build: status=$bstatus stage=${bstage:-none} reason='${breason:-none}'; the live bp-build-id went '$live_before' → '$live_after'. A broken build must fail at a NAMED stage with a REAL reason, and it must NEVER change what a visitor sees." \
      "HEALTH asserts the baked bp-doc-id/bp-content-rev markers before SWITCH — bytes that carry an empty bp-doc-id must die there"
  ok "failed at $(printf '%s' "$bstage" | tr '[:lower:]' '[:upper:]') — $breason"
  ok "the live bp-build-id UNCHANGED at $live_after (the poison never reached a visitor)"

  # And the served page still carries a REAL doc id — not the blank we shipped.
  local sdoc; sdoc="$(meta_content "$TMP/live4.html" bp-doc-id)"
  [ -n "$sdoc" ] ||
    fail "$E_BROKEN_REACHED_VISITORS" "the live page's bp-doc-id is EMPTY — the poisoned bytes ARE what visitors are being served. HEALTH did not gate the switch." \
      "a build that fails HEALTH must never get the \`current\` symlink"
  ok "the live page still serves real content (bp-doc-id=$sdoc)"

  # ---- verdict --------------------------------------------------------------
  say ""
  printf '%s✓ PROVEN%s — create → deploy → live content → rollback in %sms → a broken build contained.\n' \
    "$GRN$BLD" "$OFF" "$elapsed" >&2
  printf '  %s%s%s\n' "$BLD" "https://$LIVE_HOST/sites/$SLUG/" "$OFF" >&2
}

# =============================================================================
# THE PREBUILT JOURNEY — the off-box build lane (charter D85/D103), walked end to
# end by a STRANGER with no shell on the serving box: `bp` and `curl`, nothing
# else. `--prebuilt --slug <site>`.
#
# WHY THERE IS NO `ps` IN HERE
#   The human walk (D103) proved "the box ran no npm" with `ps` over ssh. A
#   harness anyone can re-run cannot have a shell on that box, so this walks the
#   same claim through the engine's own reported stages instead — see the judges
#   above. Nothing in this journey shells into anything.
#
# THE NONCE TRAP, MEASURED RATHER THAN HIDDEN
#   `validatePrebuiltDir` runs BEFORE the mint (a mistyped path must never mint a
#   row), so a dist has to exist to mint at all — and the mint folds a NONCE, so
#   the build id it hands out is not knowable before it. That is a two-build dance
#   by construction: build once to have bytes, mint against them, then rebuild
#   with the exports the mint printed and ship to THAT deployment with
#   `--deployment <id>`. A plain re-run mints a NEW build id and refuses again,
#   forever — the resume half is what makes the loop terminate. Both local builds
#   are timed and both are reported.
#
# WHY THE SECOND BUILD USES THE CLI'S PRINTED EXPORTS VERBATIM
#   Because that is what a human does, and it puts the CLI's own receipt under
#   test: build #2 is driven by the BARKPARK_BUILD_ID / BARKPARK_CONTENT_REV /
#   BARKPARK_SITE_BASE the refusal printed, and the journey then asserts the
#   served bp-site-base is the `/sites/<slug>/` path. HEALTH never looks at that
#   marker, so a wrong export ships a cheerful 200 whose every asset href is dead.
# =============================================================================

DIST_IN=""
JOURNEY_FACTOR="${JOURNEY_FACTOR:-10}"
JB_SRV=""; JB_WS=""; JB_PROJ=""; JB_DS=""; JB_TOKEN=""
TMPL=""

# stage_status_ms <deploy-json> <STAGE> — prints "<status> <ms>" for that stage,
# taken from the ENGINE'S OWN started_at/finished_at. A stage the engine never
# reported prints "missing 0", which every judge treats as a red.
stage_status_ms() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || printf 'missing 0\n'
import json, sys
from datetime import datetime

def ts(v):
    if not v:
        return None
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception:
        return None

try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("missing 0"); raise SystemExit(0)
want = sys.argv[2].upper()
for s in (d.get("deployment") or {}).get("stages") or []:
    if str(s.get("name", "")).upper() == want:
        a, b = ts(s.get("started_at")), ts(s.get("finished_at"))
        ms = int((b - a).total_seconds() * 1000) if a and b else 0
        print("%s %d" % (str(s.get("status", "")).lower() or "missing", max(ms, 0)))
        break
else:
    print("missing 0")
PY
}

# restamp_markers <dir> <build-id> <content-rev> — rewrite the deploy markers in
# an ALREADY-BUILT tree. Only used for a user-supplied --dist, which this script
# cannot rebuild; it prints how many files it touched so the reduced form of the
# dance is visible in the output rather than implied.
restamp_markers() {
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || printf '0\n'
import os, re, sys
root, bid, crev = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
for dirpath, _dirs, files in os.walk(root):
    for f in files:
        if not f.endswith(".html"):
            continue
        p = os.path.join(dirpath, f)
        try:
            s = open(p, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        out = s
        for name, val in (("bp-build-id", bid), ("bp-content-rev", crev)):
            if not val:
                continue
            pat = r'(<meta[^>]*name="%s"[^>]*content=")[^"]*(")' % re.escape(name)
            out = re.sub(pat, lambda m, v=val: m.group(1) + v + m.group(2), out)
        if out != s:
            open(p, "w", encoding="utf-8").write(out)
            n += 1
print(n)
PY
}

# local_astro_build <build-id> <content-rev> <base> — build the shipped starter
# LOCALLY (this is the laptop half of the lane) and print the elapsed ms. The env
# is the starter's documented build contract; the markers are what the box's
# HEALTH gate asserts by value.
local_astro_build() {
  local bid="$1" crev="$2" b="$3" t0 t1 log
  log="$TMP/npm-build-$(printf '%s' "$bid" | tr -c 'A-Za-z0-9._-' '_').log"
  t0="$(now_ms)"
  BARKPARK_API_URL="$JB_SRV" BARKPARK_WORKSPACE="$JB_WS" BARKPARK_PROJECT="$JB_PROJ" \
    BARKPARK_DATASET="$JB_DS" BARKPARK_TOKEN="$JB_TOKEN" BARKPARK_DOC_TYPE="$DOC_TYPE" \
    BARKPARK_BUILD_ID="$bid" BARKPARK_CONTENT_REV="$crev" BARKPARK_SITE_BASE="$b" \
    npm --prefix "$TMPL" run build >"$log" 2>&1 || {
    say ""
    tail -n 20 "$log" | sed 's/^/    │ /' >&2 || true
    return 1
  }
  t1="$(now_ms)"
  printf '%s' "$(( t1 - t0 ))"
}

prebuilt_journey() {
  local slug="${SLUG:-perfect-proof}"
  step "PREBUILT JOURNEY — the off-box lane on '$slug' (bp + curl only; nothing shells into the box)"
  note "oracle: the SAME site deployed twice must DISAGREE about BUILD — skipped vs a real build,"
  note "        and BUILD durations ${JOURNEY_FACTOR}x apart, both read from the engine's own stage timestamps."

  command -v "$BP" >/dev/null 2>&1 ||
    fail "$E_NO_BP" "the \`$BP\` binary is not on PATH." "make cli-build"
  local ctoken; ctoken="$(cfgval cloud_token)"
  [ -n "$ctoken" ] ||
    fail "$E_NO_SESSION" "no cloud session token in $CFG — this journey deploys a REAL site twice." "bp login"
  ok "bp present, cloud session present"

  JB_SRV="$(cfgval server)"; JB_SRV="${JB_SRV:-https://$LIVE_HOST}"
  JB_WS="${DATASET%%/*}"; JB_DS="${DATASET##*/}"
  JB_PROJ="$(printf '%s' "$DATASET" | cut -d/ -f2)"
  JB_TOKEN="$(cfgval token)"
  TMPL="$ROOT/templates/astro-starter"
  local base="/sites/$slug/"

  # ---- 1/6 OPT-IN -----------------------------------------------------------
  step "1/6 OPT-IN — prebuilt uploads are per-site and OFF by default"
  local sx=0
  "$BP" cloud site settings "$slug" --prebuilt-enabled true -o json \
    >"$TMP/pb-settings.json" 2>"$TMP/pb-settings.err" || sx=$?
  [ "$sx" -eq 0 ] ||
    fail "$E_PB_NOT_ENABLED" "\`bp cloud site settings $slug --prebuilt-enabled true\` exited $sx: $(cli_err "$TMP/pb-settings.json" "$TMP/pb-settings.err")" \
      "the control plane answers 422 prebuilt_not_enabled until the SITE opts in; a 404 here means this cloud session's team does not own '$slug'"
  ok "prebuilt_enabled=true on '$slug'"

  # ---- 2/6 BUILD #1 (the dance's first half) --------------------------------
  step "2/6 LOCAL BUILD #1 — a dist must EXIST before anything can be minted"
  local dist ms1=0
  if [ -n "$DIST_IN" ]; then
    dist="$DIST_IN"
    [ -f "$dist/index.html" ] ||
      fail "$E_PB_NO_DIST" "--dist '$dist' has no index.html — that is the OUTPUT directory (./dist), not the project." \
        "point --dist at the build output, or drop it and let this journey build $TMPL itself"
    note "using the supplied --dist $dist (this journey will RESTAMP it rather than rebuild it)"
  else
    command -v npm >/dev/null 2>&1 ||
      fail "$E_PB_NO_DIST" "npm is not on PATH, so this journey cannot build the starter locally." \
        "install node/npm, or build the dist yourself and pass --dist <dir>"
    [ -d "$TMPL" ] ||
      fail "$E_PB_NO_DIST" "the shipped starter is not at $TMPL." "run this from a checkout, or pass --dist <dir>"
    if [ ! -d "$TMPL/node_modules" ]; then
      note "installing the starter's deps once (npm ci)…"
      npm --prefix "$TMPL" ci >"$TMP/npm-ci.log" 2>&1 ||
        fail "$E_PB_NO_DIST" "npm ci failed in $TMPL: $(tail -n 5 "$TMP/npm-ci.log" | tr '\n' ' ')" \
          "or build the dist yourself and pass --dist <dir>"
    fi
    ms1="$(local_astro_build "pre-mint-$$" "pre-mint" "$base")" ||
      fail "$E_PB_NO_DIST" "the local Astro build failed (see the tail above) — there are no bytes to ship." \
        "the starter needs a readable dataset: BARKPARK_DOC_TYPE=$DOC_TYPE over $DATASET at $JB_SRV"
    dist="$TMPL/dist"
    [ -f "$dist/index.html" ] ||
      fail "$E_PB_NO_DIST" "the build reported success but $dist/index.html does not exist."
    ok "built locally in ${ms1}ms → $dist  (ON THE LAPTOP: this is the npm the box will not run)"
  fi

  # ---- 3/6 MINT ------------------------------------------------------------
  step "3/6 MINT — the nonced deployment, and the exports its bytes must carry"
  # This run is EXPECTED to refuse: the mint's build id cannot be in bytes that
  # were built before the mint existed. The refusal is the receipt we parse.
  "$BP" cloud site deploy "$slug" --prebuilt "$dist" >"$TMP/pb-mint.out" 2>"$TMP/pb-mint.err" || true
  local mintall; mintall="$(cat "$TMP/pb-mint.out" "$TMP/pb-mint.err" 2>/dev/null)"
  printf '%s\n' "$mintall" | sed 's/^/    │ /' >&2 || true

  local dep_id mint_bid mint_crev mint_base
  dep_id="$(printf '%s\n' "$mintall" | sed -n 's/.*--deployment \([A-Za-z0-9][A-Za-z0-9-]*\).*/\1/p' | tail -n 1)"
  mint_bid="$(printf '%s\n' "$mintall" | sed -n 's/.*BARKPARK_BUILD_ID=\([^ ]*\).*/\1/p' | tail -n 1)"
  mint_crev="$(printf '%s\n' "$mintall" | sed -n 's/.*BARKPARK_CONTENT_REV=\([^ ]*\).*/\1/p' | tail -n 1)"
  mint_base="$(printf '%s\n' "$mintall" | sed -n 's/.*BARKPARK_SITE_BASE=\([^ ]*\).*/\1/p' | tail -n 1)"
  if [ -z "$dep_id" ]; then
    # No refusal to parse: the mint either failed outright, or (only possible when
    # the bytes already carried the minted id) it shipped. Both are named, neither
    # is guessed at.
    dep_id="$(printf '%s\n' "$mintall" | sed -n 's/.*minted prebuilt deployment \([A-Za-z0-9][A-Za-z0-9-]*\).*/\1/p' | tail -n 1)"
    mint_bid="$(printf '%s\n' "$mintall" | sed -n 's/.*minted prebuilt deployment [A-Za-z0-9-]* (build \([^)]*\)).*/\1/p' | tail -n 1)"
  fi
  judge_prebuilt_mint "$dep_id" "$mint_bid" "$mint_crev" ||
    fail $? "the mint named deployment='${dep_id:-none}' build_id='${mint_bid:-none}' content_rev='${mint_crev:-none}' — the journey cannot build against a build id it was never told, cannot resume a deployment it cannot name, and must not build with an EMPTY content rev (the bytes would bake bp-content-rev=\"\" and die at HEALTH with 'the build lost its content link', blaming the build for a receipt that never carried the value). Output above." \
      "a 422 prebuilt_not_enabled here means step 1 did not take; a 404 means the team does not own '$slug'. An absent BARKPARK_CONTENT_REV line means the control plane minted NO content rev — it computes that by reading the site's content ON THE BOX, so it is usually the same relay credential failing that the deploy will fail on."
  ok "minted deployment $dep_id, build id $mint_bid"
  ok "content_rev $mint_crev  (computed ON THE BOX — no client can know it before the mint)"
  # THE EXPORT UNDER TEST (charter: this line used to be printed from the
  # deployment URL and therefore never printed at all — see criterion 6).
  [ -n "$mint_base" ] && ok "site base $mint_base"
  judge_site_base "$mint_base" "$base" ||
    fail $? "the mint printed BARKPARK_SITE_BASE='${mint_base:-<nothing>}' but the site is served at '$base'. Astro prefixes a leading slash to anything not already leading-slashed, so a full URL here bakes base=\"/https://…\" and every asset href on the page is dead — and HEALTH cannot see it (it asserts bp-build-id, bp-content-rev and bp-doc-id, never bp-site-base)." \
      "the CLI must print the PATH \`/sites/<slug>/\`, derived from the slug, unconditionally"

  # ---- 4/6 BUILD #2 (the dance's second half) ------------------------------
  step "4/6 LOCAL BUILD #2 — the bytes are stamped with the id the mint just handed out"
  local ms2=0
  if [ -n "$DIST_IN" ]; then
    local touched; touched="$(restamp_markers "$dist" "$mint_bid" "$mint_crev")"
    [ "${touched:-0}" -gt 0 ] 2>/dev/null ||
      fail "$E_PB_NO_DIST" "restamping $dist changed 0 files — the supplied dist has no bp-build-id marker to stamp, so HEALTH would reject it." \
        "build with the starter (drop --dist) so the markers are baked, or bake bp-build-id into your own template"
    ok "restamped $touched file(s) in the supplied dist (the reduced dance: no rebuild is possible here)"
  else
    ms2="$(local_astro_build "$mint_bid" "$mint_crev" "$mint_base")" ||
      fail "$E_PB_NO_DIST" "the second local build (with the minted exports) failed — see the tail above."
    ok "rebuilt locally in ${ms2}ms with the exports the CLI printed, verbatim"
  fi
  note "THE DANCE, MEASURED: build #1 ${ms1}ms (needed before the mint) + build #2 ${ms2}ms (carries the minted id)."
  note "A plain re-run of the same command would mint a NEW nonced build id and refuse again, forever —"
  note "which is exactly why the ship below passes --deployment $dep_id instead."

  # ---- 5/6 SHIP ------------------------------------------------------------
  step "5/6 SHIP — upload to THAT deployment; the box runs no npm"
  local shipx=0
  "$BP" cloud site deploy "$slug" --prebuilt "$dist" --deployment "$dep_id" -o json \
    >"$TMP/pb-ship.json" 2>"$TMP/pb-ship.stream" || shipx=$?
  say ""
  sed 's/^/    │ /' "$TMP/pb-ship.stream" >&2 || true
  say ""
  local pb_status; pb_status="$(jget "$TMP/pb-ship.json" deployment.status)"
  judge_prebuilt_ship "$pb_status" ||
    fail $? "the prebuilt deploy exited $shipx and ended status='${pb_status:-none}' (want live); stage=$(jget "$TMP/pb-ship.json" deployment.stage), reason=$(jget "$TMP/pb-ship.json" deployment.failure_reason). Stream above." \
      "a HEALTH failure here means the uploaded bytes do not carry the minted markers; a 409 means the deployment left queued"
  local pb_build pb_ms
  read -r pb_build pb_ms <<<"$(stage_status_ms "$TMP/pb-ship.json" BUILD)"
  ok "live — BUILD reported '$pb_build' in ${pb_ms}ms (the engine's own words)"

  # The uploaded bytes ARE what is live — asserted on the public page, by value.
  local url="https://$LIVE_HOST$base" hc served sbase
  curl -sS -m 30 -o "$TMP/pb-live.html" -w '%{http_code}' "$url" >"$TMP/pb-live.code" 2>/dev/null || true
  hc="$(cat "$TMP/pb-live.code" 2>/dev/null || echo 000)"
  served="$(meta_content "$TMP/pb-live.html" bp-build-id)"
  sbase="$(meta_content "$TMP/pb-live.html" bp-site-base)"
  judge_prebuilt_live "$hc" "$served" "$mint_bid" ||
    fail $? "$url answered HTTP $hc serving bp-build-id='$served' — the uploaded bytes are NOT what is live (want '$mint_bid')." \
      "if an older build is still live, SWITCH did not flip; if this 404s, Caddy never armed the path handle"
  ok "$url → 200, bp-build-id=$served (the bytes we packed on this laptop)"
  judge_site_base "$sbase" "$base" ||
    fail $? "the SERVED page carries bp-site-base='$sbase' but the site lives at '$base' — every asset href on that page is dead, and HEALTH cannot see it." \
      "the marker comes from BARKPARK_SITE_BASE at build time: it must be the PATH, never a full URL"
  ok "served bp-site-base=$sbase (the marker HEALTH does not check)"

  # ---- 6/6 THE SAME SITE, FROM SOURCE -------------------------------------
  step "6/6 THE CONTROL — the SAME site built ON THE BOX, so the two runs can be compared"
  note "--force folds a nonce so this really rebuilds instead of returning the cached deployment."
  local srcx=0
  "$BP" cloud site deploy "$slug" --force -o json \
    >"$TMP/pb-source.json" 2>"$TMP/pb-source.stream" || srcx=$?
  say ""
  sed 's/^/    │ /' "$TMP/pb-source.stream" >&2 || true
  say ""
  local src_status; src_status="$(jget "$TMP/pb-source.json" deployment.status)"
  [ "$src_status" = "live" ] ||
    fail "$E_DEPLOY_FAILED" "the source (on-box) deploy exited $srcx and ended '${src_status:-none}' — without a real box build there is nothing to compare the prebuilt run against." \
      "this is the ORDINARY deploy path; if it is broken the prebuilt comparison cannot be made at all"
  local src_build src_ms
  read -r src_build src_ms <<<"$(stage_status_ms "$TMP/pb-source.json" BUILD)"
  ok "live — BUILD reported '$src_build' in ${src_ms}ms"

  judge_build_disagree "$pb_build" "$src_build" ||
    fail $? "the two runs AGREE about BUILD: prebuilt='$pb_build', source='$src_build'. The prebuilt run must report BUILD skipped and the source run a real BUILD — agreement means the box either built both (npm ran for the upload) or built neither (the comparison proves nothing)." \
      "PLAN_MODE=prebuilt must make the engine report BUILD skipped and run no npm"
  ok "the runs DISAGREE about BUILD: prebuilt='$pb_build' vs source='$src_build'"
  judge_build_orders "$pb_ms" "$src_ms" "$JOURNEY_FACTOR" ||
    fail $? "BUILD took ${pb_ms}ms prebuilt and ${src_ms}ms from source — not the ${JOURNEY_FACTOR}x apart a skipped build must be (and a 'source' build under 1000ms is not a build either)." \
      "if these are close, the box is doing the same work on both paths"
  ok "BUILD ${pb_ms}ms vs ${src_ms}ms — orders apart, without a shell on the box"

  say ""
  printf '%s✓ PREBUILT PROVEN%s — %s: minted %s → built here → uploaded → live, BUILD skipped (%sms) against a real box build (%sms).\n' \
    "$GRN$BLD" "$OFF" "$slug" "$dep_id" "$pb_ms" "$src_ms" >&2
  printf '  %s%s%s\n' "$BLD" "$url" "$OFF" >&2
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
    --prebuilt | --prebuilt-journey) MODE="prebuilt" ;;
    --dist) shift; DIST_IN="${1:-}" ;;
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
  prebuilt)
    # The judges are proven offline FIRST — the same rule the full proof follows:
    # a journey whose reds were never executed is itself a vacuous green.
    self_check
    prebuilt_journey
    ;;
  full)
    self_check
    preflight
    live_proof
    ;;
esac
exit 0
