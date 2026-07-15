#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# site-spawner-autorebuild-proof.sh — the executable proof that a co-located
# site RE-DEPLOYS ITSELF when its content is PUBLISHED: a user edits in Studio,
# hits Publish on the bound workspace/project/dataset, and the site walks the
# same six-stage machine to a fresh live build carrying the new content — with
# NO manual `bp cloud site deploy`.  [cloud-site-spawner charter W5, D42–D50]
#
# This is the auto-update capstone. It is a DIFFERENT journey from the manual
# `site-spawner-live-proof.sh` (create→deploy→rollback): here the trigger is a
# content PUBLISH and the assertion is that the box NOTIFIED the control plane,
# the CP DEBOUNCED it, and a NEW deployment stamped `trigger=content-auto`
# reached a live URL whose baked content markers reflect the NEW paper — all
# within a bounded time, and WITHOUT the harness ever issuing a manual deploy.
#
# It is a PROOF, not a demo. Every step it cannot prove is a NAMED, typed,
# non-zero exit — never a silent skip, never an optimistic green. Above all it
# must never call `bp cloud site deploy` in the auto path and then claim the
# rebuild was automatic: that would be the vacuous green this whole wave forbids.
#
#   bash deploy/site-spawner-autorebuild-proof.sh              # the full live proof
#   bash deploy/site-spawner-autorebuild-proof.sh --preflight  # read-only walls; mutates NOTHING
#   bash deploy/site-spawner-autorebuild-proof.sh --self-check # offline; proves every red fires
#
# WHY THE PURE `judge_*` LAYER  (identical discipline to the manual capstone)
#   Fetching and judging are split. Every assertion is a pure function over
#   already-fetched values that RETURNS its typed failure code, so `--self-check`
#   feeds each one synthetic good AND bad input offline and asserts the exact red
#   fires. A proof whose failure paths never ran is itself a vacuous green.
#
# WHY THE AUTO-REBUILD JUDGE COUNTS MANUAL DEPLOYS
#   The single way to fake this proof is to publish AND then quietly run a manual
#   deploy, and call the resulting build "automatic". `judge_autorebuild` is
#   handed the number of manual deploys the harness issued after the baseline and
#   fails FIRST and unconditionally if it is not zero. The harness never calls
#   deploy in the auto path, so it passes 0 — the judge documents the invariant
#   and `--self-check` proves a non-zero count is a hard red.
#
# TYPED EXIT CODES (the named reds):
#    0 PROVEN                        2 usage
#   30 PREFLIGHT_NO_BP              — the bp binary or the `cloud site` verb is absent
#   31 PREFLIGHT_NO_CLOUD_SESSION   — no cloud session token (`bp login`)
#   32 PREFLIGHT_NO_BARKPARK        — the session's TEAM does not own the target box
#   33 PREFLIGHT_NO_CONTENT         — the doc type has 0 published docs (would build an EMPTY page)
#   40 CREATE_FAILED                — `bp cloud site create` did not return a site
#   41 CREATE_NOT_CONTENT_BOUND     — the ghost 201: no read token stored, no dataset binding
#   50 BASELINE_DEPLOY_FAILED       — the baseline deploy never reached live
#   51 BASELINE_NO_CONTENT          — the baseline served an empty page (no bp-doc-id) — nothing to change FROM
#   60 PUBLISH_FAILED               — could not create+publish the new paper into the bound dataset
#   70 AUTOREBUILD_MANUAL_LEAKED    — the harness issued a manual deploy in the auto path (vacuous green)
#   71 AUTOREBUILD_NO_NEW_DEPLOY    — no new deployment appeared after publish within the budget
#   72 AUTOREBUILD_NOT_CONTENT_TRIGGER — a deploy appeared but trigger != content-auto (unprovable provenance)
#   73 AUTOREBUILD_TOO_SLOW         — the auto rebuild landed, but past the bounded time
#   74 AUTOREBUILD_CONTENT_STALE    — new content-auto build, but the live page does not reflect the new paper
#   80 BURST_FANOUT                 — N rapid publishes minted ~N rebuilds (a ~10s npm build each) — NOT coalesced
#   81 BURST_NO_REBUILD             — a burst produced ZERO rebuilds — the new content never went live
#   82 BURST_NOT_A_BURST            — fewer publishes than would let coalescing be observed (a vacuous burst test)
#   90 SELF_CHECK_FAILED            — a named red did NOT fire on input that must trigger it
set -uo pipefail

# ---- Config -----------------------------------------------------------------

INSTANCE="${INSTANCE:-guerrilla}"
LIVE_HOST="${LIVE_HOST:-${INSTANCE}.barkpark.cloud}"
DATASET="${DATASET:-default/default/production}"

# CONTENT REALITY [charter D31/D35]: guerrilla has no `post` type (an undefined
# type answers 200/count:0, not 404), so the site binds `paper` (public +
# published + real, 100 docs). The site fetches doc_type=paper and renders the
# NEWEST published paper (fetchFlagshipDoc, D40) — so publishing a NEW paper
# makes it the newest, and the live page's bp-doc-id must become that paper's id.
DOC_TYPE="${BARKPARK_DOC_TYPE:-paper}"

# The bounded time the wish demands: from the PUBLISH to a live content-auto
# rebuild. A ~10s npm build + the ~5s debounce window (D44) + poll slack fits
# comfortably under 60s. A rebuild that lands LATER than this is TOO_SLOW — the
# auto-update did not feel "real-time" and the proof says so.
AUTOREBUILD_BUDGET_MS="${AUTOREBUILD_BUDGET_MS:-60000}"

# The burst: publish this many papers as fast as the CLI will accept them. D44's
# single-site Oban `unique` job (with `:executing` DROPPED) must coalesce them —
# a burst that all lands BEFORE the build collapses to ONE `:scheduled` job; a
# publish that lands DURING a build mints exactly ONE trailing rebuild. So the
# ONLY acceptable outcome is 1 (coalesced) or 2 (coalesced + one trailing), never
# ~N. MAX_COALESCED is that ceiling.
BURST_N="${BURST_N:-5}"
MAX_COALESCED="${MAX_COALESCED:-2}"

# How the poll watches the CP. Deploys are effectively serial per site (D44), so
# polling the newest-first deployments list at this cadence collects every
# content-auto build that lands in the window.
POLL_INTERVAL_S="${POLL_INTERVAL_S:-2}"

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
E_BASELINE_FAILED=50
E_BASELINE_NO_CONTENT=51
E_PUBLISH_FAILED=60
E_AUTOREBUILD_MANUAL_LEAKED=70
E_AUTOREBUILD_NO_NEW_DEPLOY=71
E_AUTOREBUILD_NOT_CONTENT_TRIGGER=72
E_AUTOREBUILD_TOO_SLOW=73
E_AUTOREBUILD_CONTENT_STALE=74
E_BURST_FANOUT=80
E_BURST_NO_REBUILD=81
E_BURST_NOT_A_BURST=82
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
    "$E_BASELINE_FAILED") echo "BASELINE_DEPLOY_FAILED" ;;
    "$E_BASELINE_NO_CONTENT") echo "BASELINE_NO_CONTENT" ;;
    "$E_PUBLISH_FAILED") echo "PUBLISH_FAILED" ;;
    "$E_AUTOREBUILD_MANUAL_LEAKED") echo "AUTOREBUILD_MANUAL_LEAKED" ;;
    "$E_AUTOREBUILD_NO_NEW_DEPLOY") echo "AUTOREBUILD_NO_NEW_DEPLOY" ;;
    "$E_AUTOREBUILD_NOT_CONTENT_TRIGGER") echo "AUTOREBUILD_NOT_CONTENT_TRIGGER" ;;
    "$E_AUTOREBUILD_TOO_SLOW") echo "AUTOREBUILD_TOO_SLOW" ;;
    "$E_AUTOREBUILD_CONTENT_STALE") echo "AUTOREBUILD_CONTENT_STALE" ;;
    "$E_BURST_FANOUT") echo "BURST_FANOUT" ;;
    "$E_BURST_NO_REBUILD") echo "BURST_NO_REBUILD" ;;
    "$E_BURST_NOT_A_BURST") echo "BURST_NOT_A_BURST" ;;
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
# reason (what was expected, what was actually observed) — never a generic shrug.
# `fix` is what a human does next.
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

# count_content_auto_since <deployments-json-file> <baseline-deploy-id>
# Counts DISTINCT deployments in the newest-first list whose trigger is
# `content-auto` and that are NOT the baseline (i.e. minted by a publish). This
# is the exact burst-coalesce count: N publishes that coalesced show 1 (or 2);
# N publishes that fanned out show ~N.
count_content_auto_since() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || echo 0
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: print(0); sys.exit(0)
baseline = sys.argv[2]
deps = d.get("deployments") if isinstance(d, dict) else d
seen = set()
for dep in deps or []:
    if str(dep.get("trigger", "")).lower() != "content-auto":
        continue
    did = str(dep.get("id", ""))
    if not did or did == baseline:
        continue
    seen.add(did)
print(len(seen))
PY
}

# newest_content_auto <deployments-json-file> <baseline-deploy-id> <field>
# The <field> of the NEWEST content-auto deployment that is not the baseline, or
# "". Used to pull the auto rebuild's id / build_id / trigger / status.
newest_content_auto() {
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
baseline, field = sys.argv[2], sys.argv[3]
deps = d.get("deployments") if isinstance(d, dict) else d
for dep in deps or []:            # newest-first
    if str(dep.get("trigger", "")).lower() != "content-auto":
        continue
    if str(dep.get("id", "")) == baseline:
        continue
    v = dep.get(field)
    print("" if v is None else v)
    break
PY
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/site-autorebuild-proof.XXXXXX")"
CREATED_SITE=""
PUBLISHED_DOCS=""
cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    if [ -n "$CREATED_SITE" ]; then
      say ""
      note "cleanup: the demo site '$CREATED_SITE' was created on the live fleet."
      note "         There is no DELETE /v1/sites/:id route yet (see site-spawner-backlog-token-revoke),"
      note "         so it is LEFT IN PLACE deliberately, with its releases dir, Caddy block AND its"
      note "         content-publish webhook row on $INSTANCE. Remove by hand: on $LIVE_HOST →"
      note "         rm -rf /opt/barkpark/sites/$CREATED_SITE, drop the '# barkpark-site:$CREATED_SITE'"
      note "         handle_path block from /etc/caddy/Caddyfile, and unregister the box webhook."
    fi
    if [ -n "$PUBLISHED_DOCS" ]; then
      note "         The proof PUBLISHED papers into $DATASET (ids: $PUBLISHED_DOCS) — they are real"
      note "         content and are left in place; unpublish them by hand if this was a scratch run."
    fi
  fi
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# =============================================================================
# THE PURE JUDGES — every assertion, as a function over values, returning its
# typed red. No network, no globals. `--self-check` drives each with input that
# MUST fail and asserts the exact code comes back.
# =============================================================================

# judge_create <content_bound> <workspace> <project> <dataset>
# The ghost-201 detector: create must fold the dataset triple + a minted read
# token. content_bound is the server's own `not is_nil(read_token_encrypted)`.
# A content-publish webhook can only be registered for a site that is actually
# bound to a dataset — so an unbound site can never auto-rebuild.
judge_create() {
  local bound="$1" ws="$2" proj="$3" ds="$4"
  [ "$bound" = "true" ] || return "$E_CREATE_NOT_BOUND"
  [ -n "$ws" ] && [ -n "$proj" ] && [ -n "$ds" ] || return "$E_CREATE_NOT_BOUND"
  return 0
}

# judge_baseline <status> <build_id> <served_doc_id>
# The baseline must be LIVE with a real build_id AND serve real content — an
# auto-rebuild "reflecting the new content" is only meaningful if there was
# content to change FROM. A baseline that served an empty page (no bp-doc-id)
# would make any later non-empty page look like a win even if nothing rebuilt.
judge_baseline() {
  local status="$1" build_id="$2" doc="$3"
  [ "$status" = "live" ] || return "$E_BASELINE_FAILED"
  [ -n "$build_id" ] || return "$E_BASELINE_FAILED"
  [ -n "$doc" ] || return "$E_BASELINE_NO_CONTENT"
  return 0
}

# judge_autorebuild <manual_deploys> <baseline_build_id> <new_build_id> <trigger>
#                   <elapsed_ms> <budget_ms> <served_doc_id> <expected_doc_id> <served_rev>
# The core assertion. The checks are ordered most-fundamental first:
#   1. NO manual deploy was issued in the auto path — else the "auto" claim is a
#      lie. Judged FIRST and unconditionally: a manual-deploy leak voids the whole
#      proof even if everything else looks perfect.
#   2. A genuinely NEW build was minted (new build_id, != baseline) — else nothing
#      rebuilt.
#   3. Its provenance is `content-auto` — a deploy with any other trigger does not
#      PROVE the publish caused it.
#   4. It landed within the bounded time.
#   5. The live page reflects the NEW paper (served doc == expected, non-empty rev)
#      — content-truth, not merely a fresh build_id.
judge_autorebuild() {
  local manual="$1" base="$2" new="$3" trig="$4" ms="$5" budget="$6" served="$7" expect="$8" rev="$9"
  [ "$manual" = "0" ] || return "$E_AUTOREBUILD_MANUAL_LEAKED"
  [ -n "$new" ] && [ "$new" != "$base" ] || return "$E_AUTOREBUILD_NO_NEW_DEPLOY"
  [ "$trig" = "content-auto" ] || return "$E_AUTOREBUILD_NOT_CONTENT_TRIGGER"
  [ "$ms" -le "$budget" ] || return "$E_AUTOREBUILD_TOO_SLOW"
  [ -n "$served" ] && [ -n "$expect" ] && [ "$served" = "$expect" ] && [ -n "$rev" ] \
    || return "$E_AUTOREBUILD_CONTENT_STALE"
  return 0
}

# judge_burst <publishes> <content_auto_rebuilds> <max_coalesced>
# A burst of publishes must coalesce. The checks:
#   1. It was actually a BURST that could reveal coalescing — publishes must
#      EXCEED max_coalesced, otherwise "1 rebuild for 2 publishes" proves nothing.
#   2. The burst produced AT LEAST ONE rebuild — zero means the new content never
#      went live (a coalesce that swallowed everything is just as broken).
#   3. It produced AT MOST max_coalesced rebuilds — more than that (approaching N)
#      is fan-out: one ~10s npm build per publish, the exact cost the wish forbids.
judge_burst() {
  local pubs="$1" rebuilds="$2" maxc="$3"
  [ "$pubs" -gt "$maxc" ] 2>/dev/null || return "$E_BURST_NOT_A_BURST"
  [ "$rebuilds" -ge 1 ] 2>/dev/null || return "$E_BURST_NO_REBUILD"
  [ "$rebuilds" -le "$maxc" ] 2>/dev/null || return "$E_BURST_FANOUT"
  return 0
}

# =============================================================================
# SELF-CHECK — offline. Proves every named red fires on input that must trigger
# it, and that the greens still pass. Runs anywhere; no network, no bp, no
# credentials. This is the gate that keeps the failure paths from being dead code
# (a proof script with untested reds is itself a vacuous green).
# =============================================================================

SC_FAILED=0
expect_code() {
  local want="$1" desc="$2"; shift 2
  local got=0
  "$@" || got=$?
  if [ "$got" = "$want" ]; then
    ok "$(printf '%-32s' "$(codename "$want")") $desc"
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
    ok "$(printf '%-32s' "PASS") $desc"
  else
    printf '  %s✗%s %s: expected a PASS, got %s (%s)\n' "$RED" "$OFF" "$desc" "$got" "$(codename "$got")" >&2
    SC_FAILED=1
  fi
}

self_check() {
  step "SELF-CHECK — every named red must fire on input that must trigger it"

  note "create (content-bound — a webhook can only bind a dataset-bound site)"
  expect_pass      "a content-bound site passes"                      judge_create true default default production
  expect_code "$E_CREATE_NOT_BOUND" "the ghost 201 (no read token stored)"    judge_create false default default production
  expect_code "$E_CREATE_NOT_BOUND" "201 with the dataset binding dropped"    judge_create true "" "" ""

  note "baseline (live, with real content to change FROM)"
  expect_pass      "live baseline with a build_id and real content"   judge_baseline live b-base doc-base
  expect_code "$E_BASELINE_FAILED"     "baseline never went live"     judge_baseline failed b-base doc-base
  expect_code "$E_BASELINE_FAILED"     "live but no build_id"         judge_baseline live "" doc-base
  expect_code "$E_BASELINE_NO_CONTENT" "live build, but served an EMPTY page" judge_baseline live b-base ""

  note "auto-rebuild (the core: publish → a content-auto build reflecting it, no manual deploy)"
  expect_pass      "content-auto rebuild in 12s, page reflects the new paper" \
    judge_autorebuild 0 b-base b-new content-auto 12000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_MANUAL_LEAKED" "THE VACUOUS GREEN: the harness manually deployed" \
    judge_autorebuild 1 b-base b-new content-auto 12000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_NO_NEW_DEPLOY" "no new build after publish (build_id unchanged)" \
    judge_autorebuild 0 b-base b-base content-auto 12000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_NO_NEW_DEPLOY" "no deployment appeared at all" \
    judge_autorebuild 0 b-base "" "" 12000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_NOT_CONTENT_TRIGGER" "a build appeared, but stamped trigger=manual" \
    judge_autorebuild 0 b-base b-new manual 12000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_NOT_CONTENT_TRIGGER" "a build appeared with an empty trigger (provenance not threaded)" \
    judge_autorebuild 0 b-base b-new "" 12000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_TOO_SLOW" "content-auto rebuild, but 90s past the publish" \
    judge_autorebuild 0 b-base b-new content-auto 90000 60000 doc-new doc-new rev-new
  expect_code "$E_AUTOREBUILD_CONTENT_STALE" "new build, but the page still serves the OLD paper" \
    judge_autorebuild 0 b-base b-new content-auto 12000 60000 doc-old doc-new rev-new
  expect_code "$E_AUTOREBUILD_CONTENT_STALE" "new build, but bp-doc-id came back empty" \
    judge_autorebuild 0 b-base b-new content-auto 12000 60000 "" doc-new rev-new
  expect_code "$E_AUTOREBUILD_CONTENT_STALE" "new build, but bp-content-rev came back empty" \
    judge_autorebuild 0 b-base b-new content-auto 12000 60000 doc-new doc-new ""

  note "burst (N rapid publishes → ONE / one-trailing rebuild, never N)"
  expect_pass      "5 publishes coalesced to 1 rebuild"               judge_burst 5 1 2
  expect_pass      "5 publishes → coalesced + one trailing = 2"       judge_burst 5 2 2
  expect_code "$E_BURST_FANOUT"     "5 publishes minted 5 rebuilds (fan-out — 5 npm builds)" judge_burst 5 5 2
  expect_code "$E_BURST_FANOUT"     "5 publishes minted 3 rebuilds (over the ceiling)"       judge_burst 5 3 2
  expect_code "$E_BURST_NO_REBUILD" "the burst produced ZERO rebuilds (content never landed)" judge_burst 5 0 2
  expect_code "$E_BURST_NOT_A_BURST" "only 2 publishes — cannot reveal coalescing"           judge_burst 2 1 2
  expect_code "$E_BURST_NOT_A_BURST" "a single publish is not a burst"                        judge_burst 1 1 2

  note "the red must have a NAME"
  local unnamed; unnamed="$(codename 255)"
  if [ "$unnamed" = "UNNAMED_FAILURE_255" ]; then
    ok "$(printf '%-32s' "NAMED") an unmapped code is reported as unnamed, never as a pass"
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
# THE LIVE WALLS — read-only. Mutates nothing. Same structure as the manual
# capstone: every wall's code path executes on every run (a wall that only runs
# once the wall before it passes is an untested path).
# =============================================================================

WALL_CODE=0
WALL_WHY=""
WALL_FIX=""
WALL_DOWN=0

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
    fail "$E_NO_BP" "this \`$BP\` has no \`cloud site\` verb family — it predates site-spawner." \
      "make cli-build"
  ok "bp speaks \`cloud site\`"

  CLOUD_URL="$(cfgval cloud_url)"; CLOUD_URL="${CLOUD_URL:-https://api.barkpark.cloud}"
  CLOUD_TOKEN="$(cfgval cloud_token)"
  CLOUD_TEAM="$(cfgval cloud_team)"

  local hc=000
  if [ -z "$CLOUD_TOKEN" ]; then
    wall "$E_NO_SESSION" "no cloud session token in $CFG." "bp login"
  else
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
      "the cloud session's team (${CLOUD_TEAM:-?}) owns $owned barkpark(s), and '$INSTANCE' is not among them. A create against it returns 404 barkpark_not_found — NOT a permission error." \
      "use a cloud session in the team that owns '$INSTANCE'. See deploy/README.md §Spawning a site."
  fi

  # The content must EXIST: the site fetches doc_type=paper and the auto-rebuild
  # must show a NEW paper becoming the newest. Probe the scoped route the build
  # itself uses, with the published perspective — a green here predicts a green build.
  local srv ws proj ds
  srv="$(cfgval server)"; srv="${srv:-https://$LIVE_HOST}"
  ws="${DATASET%%/*}"; ds="${DATASET##*/}"; proj="$(printf '%s' "$DATASET" | cut -d/ -f2)"
  local scoped="$srv/w/$ws/p/$proj/v1/data/query/$ds/$DOC_TYPE?limit=1"
  curl -sS -m 30 -o "$TMP/content.json" -w '%{http_code}' \
    -H "Authorization: Bearer $(cfgval token)" "$scoped" >"$TMP/content.code" 2>/dev/null || true
  hc="$(cat "$TMP/content.code" 2>/dev/null || echo 000)"
  local count; count="$(jget "$TMP/content.json" result.count)"; count="${count:-0}"
  if [ "$hc" != "200" ]; then
    wall "$E_NO_CONTENT" "the scoped read the build will make answered HTTP $hc: $scoped" \
      "check the dataset triple ($DATASET) and the server in $CFG"
  elif ! [ "$count" -gt 0 ] 2>/dev/null; then
    wall "$E_NO_CONTENT" \
      "type '$DOC_TYPE' has 0 published documents in $DATASET — the baseline build would ship a SILENTLY EMPTY page." \
      "BARKPARK_DOC_TYPE=paper (public + published on guerrilla); 'post' does not exist there"
  else
    ok "content: type '$DOC_TYPE' → $count published (a baseline to change FROM)"
  fi

  say ""
  if [ "$WALL_DOWN" -gt 0 ]; then
    printf '%s%s wall(s) down.%s The proof CANNOT proceed — and nothing was created.\n' \
      "$RED$BLD" "$WALL_DOWN" "$OFF" >&2
    fail "$WALL_CODE" "$WALL_WHY" "$WALL_FIX"
  fi
  printf '%s✓ PREFLIGHT PASSED%s — nothing was created; the proof can proceed.\n' "$GRN$BLD" "$OFF" >&2
}

# =============================================================================
# THE LIVE PROOF
# =============================================================================

# publish_paper <slug-suffix> — creates + publishes ONE paper into the bound
# dataset and echoes its doc id. A publish is a lifecycle event on the PUBLISHED
# row (D43), which is exactly what the box's content-publish webhook fires on.
# Echoes "" on any failure so the caller can name the PUBLISH_FAILED red.
publish_paper() {
  local suffix="$1"
  local id="autorebuild-${SLUG}-${suffix}"
  local ws proj ds
  ws="${DATASET%%/*}"; ds="${DATASET##*/}"; proj="$(printf '%s' "$DATASET" | cut -d/ -f2)"
  # Papers have a publish wall (title + description + registered tags); the site's
  # render only needs a title + body, but publish requires the wall be satisfied.
  "$BP" doc create "$DOC_TYPE" --yes \
    --set "_id=$id" \
    --set "title=Auto-rebuild proof $suffix $(date -u +%H:%M:%S)" \
    --set "style=article" \
    --set "description=Published by site-spawner-autorebuild-proof to trigger a content-auto rebuild." \
    --workspace "$ws" --project "$proj" --dataset "$ds" \
    >"$TMP/doc-create-$suffix.json" 2>"$TMP/doc-create-$suffix.err" || { echo ""; return 0; }
  "$BP" doc publish "$DOC_TYPE" "$id" --yes \
    --workspace "$ws" --project "$proj" --dataset "$ds" \
    >"$TMP/doc-publish-$suffix.json" 2>"$TMP/doc-publish-$suffix.err" || { echo ""; return 0; }
  PUBLISHED_DOCS="${PUBLISHED_DOCS:+$PUBLISHED_DOCS,}$id"
  echo "$id"
}

# list_deployments — refreshes $TMP/deployments.json from the CP, newest first.
list_deployments() {
  curl -sS -m 30 -o "$TMP/deployments.json" -w '%{http_code}' \
    -H "Authorization: Bearer $CLOUD_TOKEN" \
    "$CLOUD_URL/v1/sites/$SITE_ID/deployments" >"$TMP/deployments.code" 2>/dev/null || true
}

live_proof() {
  [ -n "$SLUG" ] || SLUG="autorebuild-$(date -u +%Y%m%d)-$$"

  # We must never call `bp cloud site deploy` between the publish and the
  # observation — the whole point is that the rebuild is AUTOMATIC. This counter
  # is the invariant made explicit: the auto path never increments it, so it is 0
  # when judge_autorebuild reads it. (self-check proves a non-zero value is a red.)
  local MANUAL_DEPLOYS_IN_AUTO_PATH=0

  # ---- 1. CREATE ------------------------------------------------------------
  step "1/4 CREATE + BASELINE — a content-bound site, deployed once to a live baseline"

  local cx=0
  "$BP" cloud site create --name "$SLUG" --dataset "$DATASET" \
    --framework astro --kind static --instance "$INSTANCE" \
    --doc-type "$DOC_TYPE" \
    -o json >"$TMP/create.json" 2>"$TMP/create.err" || cx=$?
  [ "$cx" -eq 0 ] ||
    fail "$E_CREATE_FAILED" "\`bp cloud site create\` exited $cx: $(head -c 400 "$TMP/create.err")" \
      "if this is 404 barkpark_not_found, the session's team does not own '$INSTANCE' (see PREFLIGHT)"

  SITE_ID="$(jget "$TMP/create.json" site.id)"
  [ -n "$SITE_ID" ] ||
    fail "$E_CREATE_FAILED" "create returned no site id. Body: $(head -c 300 "$TMP/create.json")"
  CREATED_SITE="$SLUG"
  ok "site created — $SITE_ID"

  curl -sS -m 30 -o "$TMP/site.json" -w '%{http_code}' \
    -H "Authorization: Bearer $CLOUD_TOKEN" "$CLOUD_URL/v1/sites/$SITE_ID" >"$TMP/site.code" 2>/dev/null || true
  local hc; hc="$(cat "$TMP/site.code")"
  [ "$hc" = "200" ] ||
    fail "$E_CREATE_FAILED" "GET /v1/sites/$SITE_ID answered HTTP $hc — the site we just created is not readable."

  local bound ws proj ds
  bound="$(jget "$TMP/site.json" site.content_bound)"
  ws="$(jget "$TMP/site.json" site.bootstrap_workspace)"
  proj="$(jget "$TMP/site.json" site.bootstrap_project)"
  ds="$(jget "$TMP/site.json" site.bootstrap_dataset)"
  judge_create "$bound" "$ws" "$proj" "$ds" ||
    fail $? "the GHOST 201: create answered 201 but the site is not content-bound — content_bound=$bound, binding=$ws/$proj/$ds. An unbound site has no dataset webhook and can never auto-rebuild." \
      "POST /v1/sites must fold the dataset triple + a minted read token AND register the content-publish webhook (D42/D47)"
  ok "content_bound=true, bound to $ws/$proj/$ds (webhook registered on the box)"

  # baseline deploy — this IS a manual deploy, and that is correct: it establishes
  # the baseline. It is NOT in the auto path, so the counter stays 0.
  note "deploying the baseline (manual — this is the 'before')…"
  "$BP" cloud site deploy "$SLUG" -o json >"$TMP/deploy0.json" 2>"$TMP/deploy0.stream" || true
  local base_status base_build
  base_status="$(jget "$TMP/deploy0.json" deployment.status)"
  base_build="$(jget "$TMP/deploy0.json" deployment.build_id)"
  BASELINE_DEP_ID="$(jget "$TMP/deploy0.json" deployment.id)"

  local url="https://$LIVE_HOST/sites/$SLUG/"
  curl -sS -m 30 -o "$TMP/base-live.html" "$url" >/dev/null 2>&1 || true
  local base_doc; base_doc="$(meta_content "$TMP/base-live.html" bp-doc-id)"

  judge_baseline "$base_status" "$base_build" "$base_doc" ||
    fail $? "the baseline deploy: status=$base_status build_id='${base_build:-none}', live bp-doc-id='${base_doc:-none}'. The baseline must be LIVE with real content — there must be a 'before' to change FROM." \
      "walk the manual proof first (deploy/site-spawner-live-proof.sh) — the baseline is exactly its create→deploy→live path"
  ok "baseline live — build_id=$base_build, bp-doc-id=$base_doc"

  # ---- 2. PUBLISH -----------------------------------------------------------
  step "2/4 PUBLISH — a NEW paper into the bound dataset (NO manual deploy)"

  local new_doc; new_doc="$(publish_paper "one")"
  [ -n "$new_doc" ] ||
    fail "$E_PUBLISH_FAILED" "could not create+publish a new paper into $DATASET: $(head -c 300 "$TMP/doc-create-one.err" "$TMP/doc-publish-one.err" 2>/dev/null)" \
      "papers have a publish wall (title + description + registered tags) — satisfy it, or publish a simpler bound doc type"
  ok "published a new paper — $new_doc (this is the ONLY action; no deploy was called)"

  # ---- 3. AUTO-REBUILD ------------------------------------------------------
  step "3/4 AUTO-REBUILD — the box notified the CP, which rebuilt itself"

  note "polling $CLOUD_URL/v1/sites/$SITE_ID/deployments for a content-auto build (budget ${AUTOREBUILD_BUDGET_MS}ms)…"
  local t0 elapsed=0 new_dep_id="" new_build="" new_trigger="" new_status=""
  t0="$(now_ms)"
  while :; do
    list_deployments
    new_dep_id="$(newest_content_auto "$TMP/deployments.json" "$BASELINE_DEP_ID" id)"
    new_status="$(newest_content_auto "$TMP/deployments.json" "$BASELINE_DEP_ID" status)"
    if [ -n "$new_dep_id" ] && [ "$new_status" = "live" ]; then
      new_build="$(newest_content_auto "$TMP/deployments.json" "$BASELINE_DEP_ID" build_id)"
      new_trigger="$(newest_content_auto "$TMP/deployments.json" "$BASELINE_DEP_ID" trigger)"
      break
    fi
    elapsed=$(( $(now_ms) - t0 ))
    [ "$elapsed" -lt "$AUTOREBUILD_BUDGET_MS" ] || break
    sleep "$POLL_INTERVAL_S"
  done
  elapsed=$(( $(now_ms) - t0 ))

  # Read the live page's content markers for the auto rebuild (content-truth).
  curl -sS -m 30 -o "$TMP/auto-live.html" "$url" >/dev/null 2>&1 || true
  local served_doc served_rev
  served_doc="$(meta_content "$TMP/auto-live.html" bp-doc-id)"
  served_rev="$(meta_content "$TMP/auto-live.html" bp-content-rev)"

  judge_autorebuild "$MANUAL_DEPLOYS_IN_AUTO_PATH" "$base_build" "$new_build" "$new_trigger" \
    "$elapsed" "$AUTOREBUILD_BUDGET_MS" "$served_doc" "$new_doc" "$served_rev" ||
    fail $? "auto-rebuild: after publishing '$new_doc' (and calling NO deploy), the newest content-auto deployment was id='${new_dep_id:-none}' build_id='${new_build:-none}' trigger='${new_trigger:-none}' status='${new_status:-none}' after ${elapsed}ms; the live page serves bp-doc-id='${served_doc:-none}' (want '$new_doc'), bp-content-rev='${served_rev:-none}'. The publish must NOTIFY the box → the box's Dispatcher fires the CP webhook → the CP debounces and enqueues a content-auto deploy." \
      "check: the site's content-publish webhook is registered on the box (D42/D47); the CP receiver /v1/sites/webhooks/content-publish/:site_id is wired (D45); the Oban debounce enqueues with trigger=content-auto (D48)"
  ok "content-auto rebuild in ${elapsed}ms — build_id=$new_build (!= baseline $base_build)"
  ok "trigger = $new_trigger  (the CP stamped it — provenance is observable)"
  ok "live bp-doc-id = $served_doc  (== the newly published paper)"
  ok "live bp-content-rev = $served_rev  (the page reflects the new content)"

  # ---- 4. BURST -------------------------------------------------------------
  step "4/4 BURST — $BURST_N rapid publishes coalesce to ONE / one-trailing rebuild"

  note "publishing $BURST_N papers as fast as the CLI accepts them (NO deploy calls)…"
  local i pub_ok=0
  for i in $(seq 1 "$BURST_N"); do
    local bid; bid="$(publish_paper "burst-$i")"
    [ -n "$bid" ] && pub_ok=$(( pub_ok + 1 ))
  done
  [ "$pub_ok" -ge 2 ] ||
    fail "$E_PUBLISH_FAILED" "only $pub_ok of $BURST_N burst publishes succeeded — cannot test coalescing." \
      "the publish wall rejected the burst papers; see $TMP/doc-*-burst-*.err"
  ok "published $pub_ok papers in a burst"

  # Wait out the debounce window + one build, then count how many DISTINCT
  # content-auto rebuilds the burst produced (beyond the single-publish one above).
  note "waiting out the debounce + build window, then counting content-auto rebuilds…"
  local burst_deadline; burst_deadline=$(( $(now_ms) + AUTOREBUILD_BUDGET_MS ))
  local burst_count=0
  while [ "$(now_ms)" -lt "$burst_deadline" ]; do
    list_deployments
    # count content-auto deployments minted AFTER the single-publish rebuild
    burst_count="$(count_content_auto_since "$TMP/deployments.json" "$BASELINE_DEP_ID")"
    # once the newest content-auto build is live and the count has settled, stop
    local newest_status; newest_status="$(newest_content_auto "$TMP/deployments.json" "$BASELINE_DEP_ID" status)"
    [ "$newest_status" = "live" ] && [ "$burst_count" -ge 1 ] && break
    sleep "$POLL_INTERVAL_S"
  done

  # burst_count includes the single-publish rebuild from step 3 (1) PLUS the
  # burst's coalesced rebuild(s). Subtract the step-3 rebuild to isolate the burst.
  local burst_only=$(( burst_count - 1 ))
  [ "$burst_only" -ge 0 ] || burst_only=0

  judge_burst "$pub_ok" "$burst_only" "$MAX_COALESCED" ||
    fail $? "the burst of $pub_ok publishes produced $burst_only content-auto rebuild(s) (total content-auto builds since baseline: $burst_count, minus the single-publish rebuild). A burst must coalesce to 1 (or 1 trailing = $MAX_COALESCED), NEVER ~N — each rebuild is a ~10s npm build." \
      "the CP debounce must be an Oban unique job keyed on site_id with :executing DROPPED (D44) so a burst collapses to one scheduled + at most one trailing"
  ok "burst of $pub_ok publishes → $burst_only content-auto rebuild(s) (≤ $MAX_COALESCED — coalesced, not fanned out)"

  # ---- verdict --------------------------------------------------------------
  say ""
  printf '%s✓ PROVEN%s — publish → the bound site auto-rebuilt (content-auto) to live content in %sms; a burst coalesced.\n' \
    "$GRN$BLD" "$OFF" "$elapsed" >&2
  printf '  %s%s%s\n' "$BLD" "https://$LIVE_HOST/sites/$SLUG/" "$OFF" >&2
}

# ---- main --------------------------------------------------------------------

usage() {
  sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//' >&2
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
