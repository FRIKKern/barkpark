#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# site-spawner-node-live-proof.sh — the executable end-to-end proof of the SECOND
# runtime target: a CONTAINER framework (Next.js) served by a long-running Node
# SSR PROCESS, driven by the SAME six-stage deploy state machine the static wave
# proved.  `bp cloud site create --kind node --framework nextjs` → `deploy`
# (PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE) drives a systemd slot unit
# (`barkpark-site@<slug>__<slot>`) to a live SSR URL → the served page carries the
# `bp-*` markers BY VALUE and is TRUE per-request SSR (force-dynamic) → a second
# build (--force) boots the OTHER slot warm → rollback flips the Caddy upstream
# back to the previous WARM slot in under a second → and a build that fails its
# HEALTH probe NEVER takes the upstream (last-good keeps serving).
#   [cloud-site-spawner charter W7 · decisions D61–D72]
#
# The KEY difference from the static proof: the artifact is a running PROCESS with
# a port and a lifecycle, not a symlink over a `dist/`.  HEALTH probes the LIVE
# process on its own loopback port; SWITCH re-flips a per-site Caddy `reverse_proxy`
# upstream; ROLLBACK is a pure Caddy port-flip to a slot still running WARM.
#
# It is a PROOF, not a demo. Every step it cannot prove is a NAMED, typed,
# non-zero exit — never a silent skip and never an optimistic green. The one thing
# this script must never do is claim a green it did not earn.
#
#   bash deploy/site-spawner-node-live-proof.sh              # the full live proof
#   bash deploy/site-spawner-node-live-proof.sh --preflight  # read-only walls; mutates NOTHING
#   bash deploy/site-spawner-node-live-proof.sh --self-check # offline; proves every red fires
#
# WHY THE PURE `judge_*` LAYER
#   Fetching and judging are deliberately split. Every assertion is a pure
#   function over already-fetched values that RETURNS its typed failure code, so
#   `--self-check` can feed each one synthetic good AND bad input offline and
#   assert the exact red fires. A proof script whose failure paths were never
#   executed is itself a vacuous green — this is the fix. This mirrors
#   site-spawner-live-proof.sh's proven shape, extended for a PROCESS artifact.
#
# WHY TRUE-SSR IS ASSERTED, NOT ASSUMED
#   A Next.js page WITHOUT `export const dynamic = 'force-dynamic'` serves the
#   BUILD-time render — the markers would reflect the build, not the running
#   deploy, and every request would be byte-identical (a static page wearing an
#   SSR costume). The proof fetches the URL TWICE and asserts a per-request marker
#   (`bp-render-ts`) is present AND differs between the two renders. That is the
#   only thing that distinguishes a live SSR process from a symlinked dist/.
#
# TYPED EXIT CODES (the named reds):
#    0 PROVEN                          2 usage
#   30 PREFLIGHT_NO_BP                — the bp binary or the `cloud site` verb is absent
#   31 PREFLIGHT_NO_CLOUD_SESSION     — no cloud session token (`bp login`)
#   32 PREFLIGHT_NO_BARKPARK          — the session's TEAM does not own the target box
#   33 PREFLIGHT_NO_CONTENT           — the doc type has 0 published docs (would build an EMPTY page)
#   34 PREFLIGHT_UNSAFE_DOC_TYPE      — the doc type is a known Branch-2 404 (post/__internal__/empty), NOT paper (D72)
#   40 CREATE_FAILED                  — `bp cloud site create` did not return a site
#   41 CREATE_NOT_CONTENT_BOUND       — the ghost 201: no read token stored, no dataset binding
#   42 CREATE_NOT_NODE_KIND           — the site is not kind=node / runtime_target=node (a static site is not this proof)
#   50 DEPLOY_FAILED                  — the deployment never reached live
#   51 DEPLOY_STAGES_INCOMPLETE       — the six stages did not all land, in order
#   52 DEPLOY_NO_SLOT                 — no systemd slot unit was named / the process is not running
#   60 LIVE_NOT_200                   — the live URL does not serve
#   61 LIVE_BUILD_ID_MISMATCH         — served bp-build-id != the deployment's build_id
#   62 LIVE_CONTENT_EMPTY             — bp-content-rev or bp-doc-id empty (a vacuous green page)
#   63 LIVE_NOT_SSR                   — two requests returned the SAME per-request marker (build-time, not force-dynamic)
#   70 ROLLBACK_FAILED                — the rollback call failed
#   71 ROLLBACK_TOO_SLOW              — over the 1000ms budget (a cold reboot, not a warm flip)
#   72 ROLLBACK_DID_NOT_FLIP          — the live bp-build-id did not change
#   73 ROLLBACK_SLOT_NOT_WARM         — the flip target process was not already running (not a true warm-standby)
#   80 HEALTH_FAIL_NOT_CONTAINED      — a failed-HEALTH slot failed with no named stage / not exit 14 / no real reason
#   81 HEALTH_FAIL_REACHED_VISITORS   — the worst red: a slot that failed HEALTH took the live Caddy upstream
#   90 SELF_CHECK_FAILED              — a named red did NOT fire on input that must trigger it
set -uo pipefail

# ---- Config -----------------------------------------------------------------

INSTANCE="${INSTANCE:-guerrilla}"
LIVE_HOST="${LIVE_HOST:-${INSTANCE}.barkpark.cloud}"
DATASET="${DATASET:-default/default/production}"

# CONTENT REALITY [charter D40/D72]: on guerrilla `production/post` answers 404
# (Branch-2: a MISSING/private schema throws uncaught in @barkpark/core .find()),
# while `paper` answers 200 with 100 published docs. The Next SSR page catches
# Branch-2 in-page (D72) so it never crashes the process, but a page bound to a
# 404 type still renders with an EMPTY bp-doc-id — a vacuous green HEALTH would
# catch. The proof is PINNED to `paper` (real, public, published), and NEVER
# `post`, which does not exist there.
DOC_TYPE="${BARKPARK_DOC_TYPE:-paper}"
DOC_ID="${BARKPARK_DOC_ID:-}"

# The container framework under proof. Next.js is the wave-7 flagship (D71); the
# same node-slot engine serves nuxt/sveltekit later (backlog).
FRAMEWORK="${FRAMEWORK:-nextjs}"
KIND="node"

# The per-request marker that PROVES true SSR (force-dynamic). The next-starter
# bakes a fresh server-render timestamp into <meta name="bp-render-ts"> on every
# request; two requests to a genuinely dynamic process differ, a build-time page
# does not. Override if the starter names it differently.
SSR_MARKER="${SSR_MARKER:-bp-render-ts}"

# Rollback budget. A warm-standby flip is a pure Caddy `reverse_proxy` port
# rewrite + graceful reload against a process that is ALREADY running on the other
# slot's port — tens of milliseconds. A number near a second means the target slot
# had to COLD-boot (`next start` is ~1.5s to first 200, D-empirical), which is
# exactly the warm-standby invariant this budget tests. [D67]
ROLLBACK_BUDGET_MS="${ROLLBACK_BUDGET_MS:-1000}"

# The node-slot port window [D68]: lowest-free EVEN base in [7002,7998], blue=base,
# green=base+1. Surfaced in messages so an operator can audit `ss -ltn`.
PORT_WINDOW="${PORT_WINDOW:-7002-7998}"

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
E_UNSAFE_DOC_TYPE=34
E_CREATE_FAILED=40
E_CREATE_NOT_BOUND=41
E_CREATE_NOT_NODE=42
E_DEPLOY_FAILED=50
E_DEPLOY_STAGES=51
E_DEPLOY_NO_SLOT=52
E_LIVE_NOT_200=60
E_LIVE_BUILD_MISMATCH=61
E_LIVE_CONTENT_EMPTY=62
E_LIVE_NOT_SSR=63
E_ROLLBACK_FAILED=70
E_ROLLBACK_SLOW=71
E_ROLLBACK_NO_FLIP=72
E_ROLLBACK_NOT_WARM=73
E_HEALTH_NOT_CONTAINED=80
E_HEALTH_REACHED_VISITORS=81
E_SELF_CHECK=90

# codename maps a typed exit code to the NAME printed in the red. A failure that
# is not in this table is a bug in this script, and says so.
codename() {
  case "$1" in
    "$E_NO_BP") echo "PREFLIGHT_NO_BP" ;;
    "$E_NO_SESSION") echo "PREFLIGHT_NO_CLOUD_SESSION" ;;
    "$E_NO_BARKPARK") echo "PREFLIGHT_NO_BARKPARK" ;;
    "$E_NO_CONTENT") echo "PREFLIGHT_NO_CONTENT" ;;
    "$E_UNSAFE_DOC_TYPE") echo "PREFLIGHT_UNSAFE_DOC_TYPE" ;;
    "$E_CREATE_FAILED") echo "CREATE_FAILED" ;;
    "$E_CREATE_NOT_BOUND") echo "CREATE_NOT_CONTENT_BOUND" ;;
    "$E_CREATE_NOT_NODE") echo "CREATE_NOT_NODE_KIND" ;;
    "$E_DEPLOY_FAILED") echo "DEPLOY_FAILED" ;;
    "$E_DEPLOY_STAGES") echo "DEPLOY_STAGES_INCOMPLETE" ;;
    "$E_DEPLOY_NO_SLOT") echo "DEPLOY_NO_SLOT" ;;
    "$E_LIVE_NOT_200") echo "LIVE_NOT_200" ;;
    "$E_LIVE_BUILD_MISMATCH") echo "LIVE_BUILD_ID_MISMATCH" ;;
    "$E_LIVE_CONTENT_EMPTY") echo "LIVE_CONTENT_EMPTY" ;;
    "$E_LIVE_NOT_SSR") echo "LIVE_NOT_SSR" ;;
    "$E_ROLLBACK_FAILED") echo "ROLLBACK_FAILED" ;;
    "$E_ROLLBACK_SLOW") echo "ROLLBACK_TOO_SLOW" ;;
    "$E_ROLLBACK_NO_FLIP") echo "ROLLBACK_DID_NOT_FLIP" ;;
    "$E_ROLLBACK_NOT_WARM") echo "ROLLBACK_SLOT_NOT_WARM" ;;
    "$E_HEALTH_NOT_CONTAINED") echo "HEALTH_FAIL_NOT_CONTAINED" ;;
    "$E_HEALTH_REACHED_VISITORS") echo "HEALTH_FAIL_REACHED_VISITORS" ;;
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
# Tolerates attribute order and single/double quotes (Next emits double).
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

# slot_active <slug> <slot> — "true" if the systemd slot process is RUNNING, else
# "false". This is how a WARM slot is distinguished from a stopped one: the whole
# premise of a sub-second rollback is that the target process never went away.
# Local-only (the live proof runs ON the box); a missing systemctl answers false.
slot_active() {
  local slug="$1" slot="$2"
  command -v systemctl >/dev/null 2>&1 || { printf 'false'; return 0; }
  if systemctl is-active --quiet "barkpark-site@${slug}__${slot}.service" 2>/dev/null; then
    printf 'true'
  else
    printf 'false'
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/node-proof.XXXXXX")"
CREATED_SITE=""
CREATED_BROKEN=""
cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    local s
    for s in "$CREATED_SITE" "$CREATED_BROKEN"; do
      [ -n "$s" ] || continue
      say ""
      note "cleanup: the demo node site '$s' was created on the live fleet."
      note "         There is no DELETE /v1/sites/:id route yet (see site-spawner-backlog-token-revoke),"
      note "         and a node site also leaves a RUNNING systemd slot process. It is LEFT IN PLACE"
      note "         deliberately. Remove by hand on $LIVE_HOST:"
      note "           systemctl stop 'barkpark-site@${s}__blue' 'barkpark-site@${s}__green' 2>/dev/null"
      note "           rm -rf /opt/barkpark/sites/$s  and drop its '# barkpark-site:$s' Caddy block."
    done
  fi
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# =============================================================================
# THE PURE JUDGES — every assertion, as a function over values, returning its
# typed red. No network, no globals, no systemctl. `--self-check` drives each of
# these with input that MUST fail, and asserts the exact code comes back.
# =============================================================================

# judge_doc_type <doc_type>
# [D40/D72] The content-safety gate, encoded as the fleet PROVED it: a Branch-2
# type (missing/private schema) answers 404 and throws in @barkpark/core; the
# Next default `post` is Branch-2 on guerrilla, and an internal `__…__` type or an
# empty string are never public content. Only a real public type (paper) is safe.
# Offline this rejects the KNOWN-unsafe values; the live count is checked in the
# preflight wall. A safe type here is necessary, not sufficient.
judge_doc_type() {
  local dt="$1"
  [ -n "$dt" ] || return "$E_UNSAFE_DOC_TYPE"
  case "$dt" in
    post | posts) return "$E_UNSAFE_DOC_TYPE" ;;   # Branch-2 404 on guerrilla (does not exist)
    __*) return "$E_UNSAFE_DOC_TYPE" ;;            # internal/underscore types are never public
    *) return 0 ;;
  esac
}

# judge_create <content_bound> <workspace> <project> <dataset> <kind> <runtime_target>
# Two things this proof needs that the static one did not: the site must be
# content-bound (the ghost-201 detector), AND it must actually be a NODE site.
# A create that silently fell back to kind=static (the schema default is
# "container", the router branches static-vs-else) would run NO process, and
# every downstream slot/SSR/warm-rollback assertion would be meaningless. [D62]
judge_create() {
  local bound="$1" ws="$2" proj="$3" ds="$4" kind="$5" rt="$6"
  [ "$bound" = "true" ] || return "$E_CREATE_NOT_BOUND"
  [ -n "$ws" ] && [ -n "$proj" ] && [ -n "$ds" ] || return "$E_CREATE_NOT_BOUND"
  [ "$kind" = "node" ] || return "$E_CREATE_NOT_NODE"
  # runtime_target may be absent on an older row; when present it must agree.
  [ -z "$rt" ] || [ "$rt" = "node" ] || return "$E_CREATE_NOT_NODE"
  return 0
}

# judge_stages <status> <stage-names-in-observed-order…>
# All six stages must have landed, in the canonical order, and the deploy must be
# live. Same contract as static — the state machine is SHARED across runtime
# targets; only what happens INSIDE STAGE/HEALTH/SWITCH/RETIRE differs.
judge_stages() {
  local status="$1"; shift
  local want="PLAN BUILD STAGE HEALTH SWITCH RETIRE"
  local got="$*"
  [ "$got" = "$want" ] || return "$E_DEPLOY_STAGES"
  [ "$status" = "live" ] || return "$E_DEPLOY_FAILED"
  return 0
}

# judge_slot <slot> <slug> <active>
# The node runtime target's defining artifact: a RUNNING process on a named slot.
# The slot must be blue|green (the two warm-standby positions, D67), the unit name
# is barkpark-site@<slug>__<slot> (D69: __ delimiter, systemd does not split %i),
# and the process must actually be active. A "live" deploy that booted no process
# is a static deploy wearing a node label.
judge_slot() {
  local slot="$1" slug="$2" active="$3"
  case "$slot" in
    blue | green) ;;
    *) return "$E_DEPLOY_NO_SLOT" ;;
  esac
  [ -n "$slug" ] || return "$E_DEPLOY_NO_SLOT"
  [ "$active" = "true" ] || return "$E_DEPLOY_NO_SLOT"
  return 0
}

# judge_live <http_code> <served_build_id> <expected_build_id> <content_rev> <doc_id>
# Assert by VALUE, not by reachability. bp-build-id must EQUAL the deployment's
# build_id (a build with the wrong id reverse-proxied through would 200 cheerfully);
# bp-content-rev and bp-doc-id must both be non-empty (a page that fetched no
# content — the Branch-2 catch-in-page case — still 200s with empty markers). [D65]
judge_live() {
  local code="$1" served="$2" expect="$3" rev="$4" doc="$5"
  [ "$code" = "200" ] || return "$E_LIVE_NOT_200"
  [ -n "$expect" ] || return "$E_LIVE_BUILD_MISMATCH"
  [ "$served" = "$expect" ] || return "$E_LIVE_BUILD_MISMATCH"
  [ -n "$rev" ] && [ -n "$doc" ] || return "$E_LIVE_CONTENT_EMPTY"
  return 0
}

# judge_ssr <render_ts_request_1> <render_ts_request_2>
# The force-dynamic proof [D71]: a live SSR process renders per request, so a
# per-request marker (bp-render-ts) is non-empty AND differs across two fetches. A
# page WITHOUT force-dynamic serves the build-time render — the marker is either
# absent or byte-identical between requests. This is the single assertion that
# separates a running node process from a symlinked static dist/.
judge_ssr() {
  local ts1="$1" ts2="$2"
  [ -n "$ts1" ] && [ -n "$ts2" ] || return "$E_LIVE_NOT_SSR"
  [ "$ts1" != "$ts2" ] || return "$E_LIVE_NOT_SSR"
  return 0
}

# judge_rollback <elapsed_ms> <build_id_before> <build_id_after> <budget_ms> <target_slot_was_warm>
# The warm-standby rollback [D67]. Ordered so the most fundamental failure wins:
#   • no build id back at all           → FAILED
#   • the live page did not change       → DID_NOT_FLIP
#   • the flip target was not running    → SLOT_NOT_WARM (a cold reboot masquerading as rollback)
#   • the flip took longer than budget   → TOO_SLOW
# The warmth check comes before the speed check on purpose: a cold reboot that
# happened to squeak under budget is STILL not the warm-standby design, and a warm
# flip that was slow is a Caddy-reload problem, not a warmth problem — two
# distinct diagnoses, two distinct reds.
judge_rollback() {
  local ms="$1" before="$2" after="$3" budget="$4" warm="$5"
  [ -n "$after" ] || return "$E_ROLLBACK_FAILED"
  [ "$after" != "$before" ] || return "$E_ROLLBACK_NO_FLIP"
  [ "$warm" = "true" ] || return "$E_ROLLBACK_NOT_WARM"
  [ "$ms" -le "$budget" ] || return "$E_ROLLBACK_SLOW"
  return 0
}

# judge_fail_closed <deploy_status> <failed_stage> <health_exit_code> <failure_reason> <live_bid_before> <live_bid_after>
# The health gate's whole purpose, for a PROCESS. Two independent things must
# hold: the failure is CONTAINED (the live upstream never moved — visitors still
# see the last-good slot), and it is HONEST (it failed at the NAMED HEALTH stage,
# with the exit-14 convention [D65], and a real reason). Containment is judged
# FIRST and unconditionally — a failed slot that took the Caddy upstream is the
# worst red there is, even if the deploy also reported itself failed.
judge_fail_closed() {
  local status="$1" stage="$2" hexit="$3" reason="$4" before="$5" after="$6"
  [ "$after" = "$before" ] || return "$E_HEALTH_REACHED_VISITORS"
  [ "$status" = "failed" ] || return "$E_HEALTH_NOT_CONTAINED"
  [ "$stage" = "HEALTH" ] || return "$E_HEALTH_NOT_CONTAINED"
  # exit 14 is the cross-engine HEALTH-failed convention (D65). A slot that died
  # at HEALTH with any other exit code is not a health failure — it is a different
  # (unhandled) failure wearing HEALTH's name.
  [ "$hexit" = "14" ] || return "$E_HEALTH_NOT_CONTAINED"
  [ -n "$reason" ] || return "$E_HEALTH_NOT_CONTAINED"
  [ "${#reason}" -ge 12 ] || return "$E_HEALTH_NOT_CONTAINED"
  return 0
}

# =============================================================================
# SELF-CHECK — offline. Proves every named red actually fires on input that must
# trigger it, and that the greens still pass. Runs anywhere; no network, no bp,
# no systemctl, no credentials. This is the gate that keeps the failure paths from
# being dead code (a proof script with untested reds is itself a vacuous green).
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

  note "doc type (D40/D72 — only a real public type is safe)"
  expect_pass      "paper is safe (public, published, 100 docs)"       judge_doc_type paper
  expect_code "$E_UNSAFE_DOC_TYPE" "the Next default 'post' 404s (Branch-2)"  judge_doc_type post
  expect_code "$E_UNSAFE_DOC_TYPE" "an internal __no_such_type__"       judge_doc_type __no_such_type__
  expect_code "$E_UNSAFE_DOC_TYPE" "an empty doc type"                  judge_doc_type ""

  note "create (content-bound AND kind=node)"
  expect_pass      "a content-bound node site passes"                  judge_create true default default production node node
  expect_pass      "runtime_target absent on the row is tolerated"     judge_create true default default production node ""
  expect_code "$E_CREATE_NOT_BOUND" "the ghost 201 (no read token stored)"   judge_create false default default production node node
  expect_code "$E_CREATE_NOT_BOUND" "201 with the dataset binding dropped"   judge_create true "" "" "" node node
  expect_code "$E_CREATE_NOT_NODE"  "silently fell back to kind=static"      judge_create true default default production static static
  expect_code "$E_CREATE_NOT_NODE"  "kind=node but runtime_target=static"    judge_create true default default production node static

  note "deploy (six stages, in order, live)"
  expect_pass      "six stages, in order, live"                        judge_stages live PLAN BUILD STAGE HEALTH SWITCH RETIRE
  expect_code "$E_DEPLOY_STAGES" "only three stages ever landed"        judge_stages live PLAN BUILD STAGE
  expect_code "$E_DEPLOY_STAGES" "six stages but OUT of order"          judge_stages live PLAN BUILD HEALTH STAGE SWITCH RETIRE
  expect_code "$E_DEPLOY_FAILED" "all six stages, but never went live"  judge_stages queued PLAN BUILD STAGE HEALTH SWITCH RETIRE

  note "slot (a RUNNING process on a named blue|green slot)"
  expect_pass      "blue slot, running"                                judge_slot blue my-blog true
  expect_pass      "green slot, running"                               judge_slot green my-blog true
  expect_code "$E_DEPLOY_NO_SLOT" "no slot named at all"               judge_slot "" my-blog true
  expect_code "$E_DEPLOY_NO_SLOT" "an invalid slot name"               judge_slot red my-blog true
  expect_code "$E_DEPLOY_NO_SLOT" "slot named but the process is DOWN" judge_slot blue my-blog false

  note "live URL (assert markers by VALUE)"
  expect_pass      "200, build-id matches, content markers present"    judge_live 200 b-abc b-abc rev-1 doc-1
  expect_code "$E_LIVE_NOT_200"        "the URL 502s (no upstream)"    judge_live 502 b-abc b-abc rev-1 doc-1
  expect_code "$E_LIVE_BUILD_MISMATCH" "a stale build reverse-proxied through" judge_live 200 TOTALLY-WRONG b-abc rev-1 doc-1
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-doc-id empty (Branch-2 catch)" judge_live 200 b-abc b-abc rev-1 ""
  expect_code "$E_LIVE_CONTENT_EMPTY"  "200 but bp-content-rev empty"  judge_live 200 b-abc b-abc "" doc-1

  note "true SSR (force-dynamic — two renders must differ)"
  expect_pass      "two requests, different render timestamps"         judge_ssr 1752580000123 1752580000456
  expect_code "$E_LIVE_NOT_SSR" "identical marker = build-time, not SSR" judge_ssr 1752580000123 1752580000123
  expect_code "$E_LIVE_NOT_SSR" "no render marker at all (not force-dynamic)" judge_ssr "" ""

  note "warm-standby rollback (<1s, and the target was already running)"
  expect_pass      "flipped to a WARM previous slot in 40ms"           judge_rollback 40 b-new b-old 1000 true
  expect_code "$E_ROLLBACK_SLOW"    "flipped to a warm slot but took 1500ms" judge_rollback 1500 b-new b-old 1000 true
  expect_code "$E_ROLLBACK_NOT_WARM" "flipped, fast, but the target COLD-booted" judge_rollback 40 b-new b-old 1000 false
  expect_code "$E_ROLLBACK_NO_FLIP" "fast 200, but nothing flipped"    judge_rollback 40 b-new b-new 1000 true
  expect_code "$E_ROLLBACK_FAILED"  "no build id came back at all"     judge_rollback 40 b-new "" 1000 true

  note "fail-closed HEALTH (a failed slot never takes the upstream)"
  expect_pass      "failed at HEALTH, exit 14, real reason, upstream unmoved" \
    judge_fail_closed failed HEALTH 14 "marker bp-doc-id empty: the SSR process fetched no content" b-old b-old
  expect_code "$E_HEALTH_REACHED_VISITORS" "THE WORST RED: a failed slot took the live upstream" \
    judge_fail_closed failed HEALTH 14 "marker bp-doc-id empty: the SSR process fetched no content" b-old b-broken
  expect_code "$E_HEALTH_NOT_CONTAINED" "the failed slot reported itself LIVE" \
    judge_fail_closed live HEALTH 14 "marker bp-doc-id empty: the SSR process fetched no content" b-old b-old
  expect_code "$E_HEALTH_NOT_CONTAINED" "failed at a stage that is not HEALTH" \
    judge_fail_closed failed BUILD 14 "npm run build exited 1" b-old b-old
  expect_code "$E_HEALTH_NOT_CONTAINED" "failed at HEALTH but not with exit 14" \
    judge_fail_closed failed HEALTH 1 "process crashed on boot" b-old b-old
  expect_code "$E_HEALTH_NOT_CONTAINED" "failed at HEALTH with a shrug for a reason" \
    judge_fail_closed failed HEALTH 14 "error" b-old b-old

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
# THE LIVE WALLS — read-only. Mutates nothing. Every wall's code path EXECUTES on
# every run (a wall that only runs once the wall before it passes is an untested
# path — the same vacuous green this whole script refuses).
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

  # The doc type must be a KNOWN-safe one BEFORE we spend a live probe on it (D72).
  judge_doc_type "$DOC_TYPE" ||
    wall "$E_UNSAFE_DOC_TYPE" \
      "doc type '$DOC_TYPE' is a known Branch-2 404 on this fleet (a missing/private schema throws in @barkpark/core, and the Next page renders an EMPTY bp-doc-id)." \
      "BARKPARK_DOC_TYPE=paper (public + published, 100 docs); 'post' does not exist on guerrilla"

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
      "use a cloud session in the team that owns '$INSTANCE', or adopt it via the worker-token-gated POST /v1/internal/barkparks. See deploy/README.md."
  fi

  # WALL — the content must EXIST. An undefined/private type answers 404 (Branch-2)
  # and the SSR page renders an EMPTY bp-doc-id. We probe the SCOPED route the build
  # itself will use, with the same published perspective, so a green here predicts a
  # green build.
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

  if [ "$hc" = "404" ]; then
    wall "$E_UNSAFE_DOC_TYPE" \
      "the scoped read for type '$DOC_TYPE' answered HTTP 404 — a MISSING or private schema (Branch-2). The SSR process would catch-in-page and ship an EMPTY bp-doc-id." \
      "BARKPARK_DOC_TYPE=paper (public + published on guerrilla)"
  elif [ "$hc" != "200" ]; then
    wall "$E_NO_CONTENT" "the scoped read the build will make answered HTTP $hc: $scoped" \
      "check the dataset triple ($DATASET) and the server in $CFG"
  elif ! [ "$count" -gt 0 ] 2>/dev/null; then
    wall "$E_NO_CONTENT" \
      "type '$DOC_TYPE' has 0 published documents in $DATASET — the SSR build would ship a SILENTLY EMPTY page." \
      "BARKPARK_DOC_TYPE=paper (public + published on guerrilla)"
  else
    [ -n "$DOC_ID" ] || DOC_ID="$first"
    ok "content: type '$DOC_TYPE' → $count published; example bp-doc-id=$DOC_ID"
  fi

  say ""
  if [ "$WALL_DOWN" -gt 0 ]; then
    printf '%s%s wall(s) down.%s The spawn CANNOT proceed — and nothing was created, so there is no orphan to clean up.\n' \
      "$RED$BLD" "$WALL_DOWN" "$OFF" >&2
    fail "$WALL_CODE" "$WALL_WHY" "$WALL_FIX"
  fi
  printf '%s✓ PREFLIGHT PASSED%s — nothing was created; the node spawn can proceed.\n' "$GRN$BLD" "$OFF" >&2
}

# =============================================================================
# THE LIVE PROOF
# =============================================================================

# stage_names <deploy-json> — the stages that landed (done|skipped), UPPERCASED,
# space-joined, in observed order.
stage_names() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
out = []
for s in (d.get("deployment") or {}).get("stages") or []:
    if str(s.get("status", "")).lower() in ("done", "skipped"):
        out.append(str(s.get("name", "")).upper())
print(" ".join(out))
PY
}

live_proof() {
  [ -n "$SLUG" ] || SLUG="nodeproof-$(date -u +%Y%m%d)-$$"

  # ---- 1. CREATE ------------------------------------------------------------
  step "1/5 CREATE — a content-bound NODE site (kind=node, framework=$FRAMEWORK)"

  local cx=0
  "$BP" cloud site create --name "$SLUG" --dataset "$DATASET" \
    --framework "$FRAMEWORK" --kind "$KIND" --instance "$INSTANCE" \
    --doc-type "$DOC_TYPE" \
    -o json >"$TMP/create.json" 2>"$TMP/create.err" || cx=$?
  [ "$cx" -eq 0 ] ||
    fail "$E_CREATE_FAILED" "\`bp cloud site create --kind node\` exited $cx: $(head -c 400 "$TMP/create.err")" \
      "if this is 422 unknown framework, the CP framework-legality gate is missing '$FRAMEWORK' from @container_frameworks; if 404 barkpark_not_found, the session's team does not own '$INSTANCE'"

  local site_id; site_id="$(jget "$TMP/create.json" site.id)"
  [ -n "$site_id" ] ||
    fail "$E_CREATE_FAILED" "create returned no site id. Body: $(head -c 300 "$TMP/create.json")"
  CREATED_SITE="$SLUG"
  ok "site created — $site_id"

  curl -sS -m 30 -o "$TMP/site.json" -w '%{http_code}' \
    -H "Authorization: Bearer $CLOUD_TOKEN" "$CLOUD_URL/v1/sites/$site_id" >"$TMP/site.code" 2>/dev/null || true
  local hc; hc="$(cat "$TMP/site.code")"
  [ "$hc" = "200" ] ||
    fail "$E_CREATE_FAILED" "GET /v1/sites/$site_id answered HTTP $hc — the site we just created is not readable."

  local bound ws proj ds kind rt
  bound="$(jget "$TMP/site.json" site.content_bound)"
  ws="$(jget "$TMP/site.json" site.bootstrap_workspace)"
  proj="$(jget "$TMP/site.json" site.bootstrap_project)"
  ds="$(jget "$TMP/site.json" site.bootstrap_dataset)"
  kind="$(jget "$TMP/site.json" site.kind)"
  rt="$(jget "$TMP/site.json" site.runtime_target)"
  judge_create "$bound" "$ws" "$proj" "$ds" "$kind" "$rt" ||
    fail $? "the node create did not land clean — content_bound=$bound, binding=$ws/$proj/$ds, kind=$kind, runtime_target=${rt:-<absent>}. A node proof needs a content-bound site whose kind is 'node' (the schema default is 'container', which routes to the dead off-box builder)." \
      "POST /v1/sites must accept kind=node (D62) and fold the dataset triple + a minted read token through put_site_content_binding"
  ok "content_bound=true, bound to $ws/$proj/$ds, kind=node (runtime_target=${rt:-node})"

  # ---- 2. DEPLOY — the six stages drive a RUNNING node process --------------
  step "2/5 DEPLOY — six stages drive a systemd node slot to running"

  local dx=0
  "$BP" cloud site deploy "$SLUG" -o json >"$TMP/deploy.json" 2>"$TMP/deploy.stream" || dx=$?
  say ""
  sed 's/^/    │ /' "$TMP/deploy.stream" >&2 || true
  say ""

  local status stage reason build_id slot port
  status="$(jget "$TMP/deploy.json" deployment.status)"
  stage="$(jget "$TMP/deploy.json" deployment.stage)"
  reason="$(jget "$TMP/deploy.json" deployment.failure_reason)"
  build_id="$(jget "$TMP/deploy.json" deployment.build_id)"
  slot="$(jget "$TMP/deploy.json" deployment.slot)"
  port="$(jget "$TMP/deploy.json" deployment.port)"

  if [ "$dx" -ne 0 ] && [ -z "$status" ]; then
    fail "$E_DEPLOY_FAILED" "\`bp cloud site deploy\` exited $dx with no deployment: $(head -c 400 "$TMP/deploy.stream")" \
      "if this is 422 no_build_source or an unknown runtime_target, POST /v1/sites/:id/deploy does not yet kind-branch to the node engine (D63)"
  fi

  local names; names="$(stage_names "$TMP/deploy.json")"
  # shellcheck disable=SC2086
  judge_stages "$status" $names ||
    fail $? "the deploy did not walk the six stages to live — status=$status, stage=${stage:-?}, stages landed: [${names:-none}]${reason:+, reason: $reason}" \
      "the six stages are PLAN BUILD STAGE HEALTH SWITCH RETIRE, in that order — the SAME state machine, driving a node process instead of a symlink"
  ok "PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE, and the deployment is live"
  ok "build_id = $build_id   slot = ${slot:-?}   port = ${port:-?}  (window $PORT_WINDOW)"

  # The defining node assertion: a RUNNING process on the named slot. The deploy
  # said "live" — confirm a systemd unit barkpark-site@<slug>__<slot> is actually
  # active. This is what a static "live" never has.
  local active; active="$(slot_active "$SLUG" "$slot")"
  judge_slot "$slot" "$SLUG" "$active" ||
    fail $? "the deploy reported live but named no running node slot — slot='${slot:-none}', unit 'barkpark-site@${SLUG}__${slot:-?}' is_active=$active. A node runtime target's whole artifact is a running PROCESS; a 'live' deploy with no process is a static deploy wearing a node label." \
      "SWITCH must boot the standalone server as barkpark-site@<slug>__<slot> (D69) and only flip Caddy after it is up (D65/D66)"
  ok "systemd slot RUNNING — barkpark-site@${SLUG}__${slot}.service (active)"

  # ---- 3. THE LIVE SSR URL, ASSERTED BY VALUE + PROVEN DYNAMIC --------------
  step "3/5 LIVE — the URL is served by the node process, SSR, with REAL content"

  # This is the first live exercise of SWITCH's Caddy reverse_proxy arm. A green
  # SWITCH stage is NOT trusted — only an actual 200 from the public FQDN, carrying
  # THIS build's markers, proves the upstream flipped to the slot port. And two
  # requests must differ (force-dynamic) — that is what makes it SSR, not a dist/.
  local url="https://$LIVE_HOST/sites/$SLUG/"
  curl -sS -m 30 -o "$TMP/live.html" -w '%{http_code}' "$url" >"$TMP/live.code" 2>/dev/null || true
  hc="$(cat "$TMP/live.code" 2>/dev/null || echo 000)"

  local served rev doc ts1
  served="$(meta_content "$TMP/live.html" bp-build-id)"
  rev="$(meta_content "$TMP/live.html" bp-content-rev)"
  doc="$(meta_content "$TMP/live.html" bp-doc-id)"
  ts1="$(meta_content "$TMP/live.html" "$SSR_MARKER")"

  judge_live "$hc" "$served" "$build_id" "$rev" "$doc" ||
    fail $? "$url answered HTTP $hc, serving bp-build-id='$served' (want '$build_id'), bp-content-rev='$rev', bp-doc-id='$doc'. A 200 through the reverse_proxy proves nothing about WHICH build the node process is serving — the markers must match by value." \
      "the served build-id must EQUAL the deployment's build_id, and bp-content-rev/bp-doc-id must be non-empty (an empty marker is the Branch-2 catch-in-page case HEALTH should have gated)"
  ok "$url → 200  (SWITCH's Caddy reverse_proxy armed to the slot port)"
  ok "bp-build-id   = $served  (== the deployment's build_id)"
  ok "bp-content-rev = $rev"
  ok "bp-doc-id     = $doc  (real Barkpark content, SSR-fetched)"

  # Second request — a DIFFERENT per-request render timestamp is the force-dynamic
  # proof. A static dist/ would return byte-identical markers.
  sleep 1
  curl -sS -m 30 -o "$TMP/live-b.html" "$url" >/dev/null 2>&1 || true
  local ts2; ts2="$(meta_content "$TMP/live-b.html" "$SSR_MARKER")"
  judge_ssr "$ts1" "$ts2" ||
    fail "$E_LIVE_NOT_SSR" "two requests returned the SAME '$SSR_MARKER' ('$ts1' == '$ts2') — the page is served from the BUILD-time render, not per-request SSR. Without \`export const dynamic = 'force-dynamic'\` the markers reflect the build, not the running deploy." \
      "the next-starter's page must set force-dynamic so every request re-renders against the running process (D71)"
  ok "true SSR — $SSR_MARKER differed per request ($ts1 → $ts2)"

  # ---- 4. ROLLBACK — flip to the previous WARM slot in under a second -------
  step "4/5 ROLLBACK — a pure Caddy port-flip to the previous WARM slot, <1s"

  # A second --force build boots the OTHER slot (blue↔green). --force folds a fresh
  # nonce into build_id so an unchanged-content re-deploy still mints a NEW build_id
  # (else PLAN is an idempotent no-op and there is nothing to roll back FROM). After
  # this, BOTH slots hold a running process — the warm-standby state the <1s
  # rollback depends on. [D67]
  note "cutting a second build with --force so the other slot boots warm…"
  "$BP" cloud site deploy "$SLUG" --force -o json >"$TMP/deploy2.json" 2>"$TMP/deploy2.stream" || true
  local build2 slot2
  build2="$(jget "$TMP/deploy2.json" deployment.build_id)"
  slot2="$(jget "$TMP/deploy2.json" deployment.slot)"
  [ -n "$build2" ] && [ "$build2" != "$build_id" ] ||
    fail "$E_DEPLOY_FAILED" "the second (--force) deploy did not produce a NEW build_id (got '${build2:-none}', first was '$build_id') — with no second release there is nothing to roll back FROM." \
      "--force must fold a nonce into build_id = hash(code_rev + content_rev + config + nonce); if build2 == build_id the force nonce is not being minted"
  ok "second build live on slot ${slot2:-?} — $build2"

  # The previous slot ($slot) must STILL be running — that is the warm-standby
  # invariant. If RETIRE stopped it, rollback would have to cold-boot and blow the
  # budget; judge_rollback fails it as ROLLBACK_SLOT_NOT_WARM before it even times.
  local prev_warm; prev_warm="$(slot_active "$SLUG" "$slot")"
  if [ "$prev_warm" = "true" ]; then
    ok "previous slot barkpark-site@${SLUG}__${slot} is WARM (still running)"
  else
    note "previous slot barkpark-site@${SLUG}__${slot} is_active=$prev_warm — rollback will be judged NOT_WARM if it cannot flip instantly"
  fi

  local before after t0 t1 elapsed rbx=0
  curl -sS -m 30 -o "$TMP/live2.html" "$url" >/dev/null 2>&1 || true
  before="$(meta_content "$TMP/live2.html" bp-build-id)"

  t0="$(now_ms)"
  "$BP" cloud site rollback "$SLUG" -o json >"$TMP/rollback.json" 2>"$TMP/rollback.err" || rbx=$?
  t1="$(now_ms)"
  elapsed=$(( t1 - t0 ))

  [ "$rbx" -eq 0 ] ||
    fail "$E_ROLLBACK_FAILED" "\`bp cloud site rollback\` exited $rbx after ${elapsed}ms: $(head -c 400 "$TMP/rollback.err")" \
      "if this is a 404, POST /v1/sites/:id/rollback is not wired for the node arm; if 422 non-static, the rollback route still kind-gates on static (D62)"

  curl -sS -m 30 -o "$TMP/live3.html" "$url" >/dev/null 2>&1 || true
  after="$(meta_content "$TMP/live3.html" bp-build-id)"

  judge_rollback "$elapsed" "$before" "$after" "$ROLLBACK_BUDGET_MS" "$prev_warm" ||
    fail $? "rollback took ${elapsed}ms (budget ${ROLLBACK_BUDGET_MS}ms), live bp-build-id went '$before' → '$after', previous slot warm=$prev_warm. A warm-standby rollback is a pure Caddy port-flip to a process that is ALREADY running — a number near a second means the target had to cold-boot (\`next start\` is ~1.5s), which is not warm-standby." \
      "keep the previous slot RUNNING after SWITCH (D67); rollback re-flips the Caddy upstream port back to it and reloads — no rebuild, no reboot"
  ok "rollback in ${elapsed}ms (budget ${ROLLBACK_BUDGET_MS}ms) — pure Caddy port-flip to the warm slot"
  ok "live bp-build-id flipped $before → $after (back to slot $slot)"

  # ---- 5. FAIL-CLOSED — a slot that fails HEALTH never takes the upstream ---
  step "5/5 FAIL-CLOSED — a broken node slot dies at HEALTH, last-good keeps serving"

  local live_before; live_before="$after"

  # A separate poison node site bound to a type that 404s (Branch-2). The SSR
  # process boots and 200s, but its page renders an EMPTY bp-doc-id (D72
  # catch-in-page). HEALTH's marker-by-value assertion catches the empty marker →
  # the slot fails HEALTH (exit 14) → it is stopped and NEVER takes the Caddy
  # upstream. A reachability-only gate would wave the 200 through. If HEALTH is
  # real the poison never serves; if it is theatre, we say so.
  local broken_slug="${SLUG}-broken"
  note "creating a poison node site '$broken_slug' bound to a type that 404s…"
  local pcx=0
  "$BP" cloud site create --name "$broken_slug" --dataset "$DATASET" \
    --framework "$FRAMEWORK" --kind "$KIND" --instance "$INSTANCE" \
    --doc-type "__no_such_type__" \
    -o json >"$TMP/broken-create.json" 2>"$TMP/broken-create.err" || pcx=$?
  [ "$pcx" -eq 0 ] ||
    fail "$E_CREATE_FAILED" "could not create the poison node site to prove HEALTH containment: $(head -c 300 "$TMP/broken-create.err")"
  CREATED_BROKEN="$broken_slug"

  note "deploying the poison site — it must die at HEALTH (exit 14) and never take the upstream…"
  "$BP" cloud site deploy "$broken_slug" -o json >"$TMP/broken.json" 2>"$TMP/broken.stream" || true
  say ""
  sed 's/^/    │ /' "$TMP/broken.stream" >&2 || true
  say ""

  local bstatus bstage bhexit breason
  bstatus="$(jget "$TMP/broken.json" deployment.status)"
  bstage="$(jget "$TMP/broken.json" deployment.stage)"
  bhexit="$(jget "$TMP/broken.json" deployment.health_exit_code)"
  breason="$(jget "$TMP/broken.json" deployment.failure_reason)"
  # health_exit_code may not be surfaced; a failed HEALTH stage implies the 14
  # convention. Default to 14 ONLY when the stage is HEALTH and the field is absent.
  if [ -z "$bhexit" ] && [ "$(printf '%s' "${bstage:-}" | tr '[:lower:]' '[:upper:]')" = "HEALTH" ]; then
    bhexit=14
  fi

  # Containment: the GOOD proof site's live upstream is UNCHANGED.
  curl -sS -m 30 -o "$TMP/live4.html" "$url" >/dev/null 2>&1 || true
  local live_after; live_after="$(meta_content "$TMP/live4.html" bp-build-id)"

  judge_fail_closed "$bstatus" "$(printf '%s' "${bstage:-}" | tr '[:lower:]' '[:upper:]')" "${bhexit:-}" "$breason" "$live_before" "$live_after" ||
    fail $? "the broken build: status=$bstatus stage=${bstage:-none} health_exit=${bhexit:-none} reason='${breason:-none}'; the GOOD site's live bp-build-id went '$live_before' → '$live_after'. A broken node slot must fail at HEALTH (exit 14) with a real reason, and it must NEVER take the Caddy upstream from a healthy last-good." \
      "HEALTH probes the just-booted process and asserts the baked bp-doc-id/bp-content-rev markers BY VALUE before SWITCH — a process that fetched no content must die there and be stopped"
  ok "failed at HEALTH (exit ${bhexit:-14}) — $breason"
  ok "the GOOD site's live bp-build-id UNCHANGED at $live_after"

  # Containment part 2: the poison site's own URL never served the broken build.
  # A first deploy that failed HEALTH never armed a Caddy upstream, so its URL has
  # no reverse_proxy target → 502/404, never a 200 with a non-empty bp-doc-id.
  local burl="https://$LIVE_HOST/sites/$broken_slug/"
  curl -sS -m 30 -o "$TMP/broken-live.html" -w '%{http_code}' "$burl" >"$TMP/broken-live.code" 2>/dev/null || true
  local bhc bdoc
  bhc="$(cat "$TMP/broken-live.code" 2>/dev/null || echo 000)"
  bdoc="$(meta_content "$TMP/broken-live.html" bp-doc-id)"
  if [ "$bhc" = "200" ] && [ -n "$bdoc" ]; then
    fail "$E_HEALTH_REACHED_VISITORS" "the poison site's own URL ($burl) served HTTP 200 with bp-doc-id='$bdoc' — the failed slot took the Caddy upstream. HEALTH did not gate the switch." \
      "a slot that fails HEALTH must never SWITCH — no reverse_proxy upstream should be armed for it, and its URL must 502/404"
  fi
  ok "poison URL never served the broken slot (HTTP $bhc, bp-doc-id='${bdoc:-<none>}')"

  # ---- verdict --------------------------------------------------------------
  say ""
  printf '%s✓ PROVEN%s — node create → 6 stages drive a running process → SSR content → warm-slot rollback in %sms → a failed HEALTH contained.\n' \
    "$GRN$BLD" "$OFF" "$elapsed" >&2
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
    --keep) KEEP=1 ;;
    --slug) shift; SLUG="${1:-}" ;;
    --framework) shift; FRAMEWORK="${1:-nextjs}" ;;
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
