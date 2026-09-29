#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# site-spawner-first-run.sh — THE STRANGER'S FIRST RUN.
#
# Every other proof in deploy/ proves the MACHINE: site-spawner-live-proof.sh
# proves create -> deploy -> rollback, site-spawner-autorebuild-proof.sh proves
# the content webhook, site-spawner-node-live-proof.sh proves SSR. None of them
# proves the PERSON. They all start from knowledge a first-time operator does
# not have — a dataset triple typed from memory, an instance name someone told
# them, an ssh session on the box for the parts the CLI cannot reach.
#
# This script starts from ZERO:
#   * no ssh, ever — every step is a `bp` verb or an HTTPS fetch;
#   * no lead-only fixture — nothing is pre-seeded, nothing is passed in that a
#     stranger could not have DISCOVERED from `-h` and the CLI's own output;
#   * every input the journey needs must be REACHABLE from a command the
#     stranger can find, and a step whose input is only reachable by reading Go
#     source is a NAMED RED, not a shrug.
#
# It walks DISCOVER -> CREATE -> DEPLOY -> VISIT -> UNDO and at every step it
# either proceeds or names the EXACT fix at the EXACT step (see `fixhint`, which
# prints a runnable command, not advice).
#
#   bash deploy/site-spawner-first-run.sh              # the full live walk
#   bash deploy/site-spawner-first-run.sh --discover   # read-only; mutates NOTHING
#   bash deploy/site-spawner-first-run.sh --self-check # offline; proves every red fires
#
# WHY THE PURE `judge_*` LAYER (inherited, deliberately, from
# site-spawner-live-proof.sh). Fetching and judging are split: every assertion is
# a pure function over already-fetched values that RETURNS its typed failure
# code, so `--self-check` can feed each one synthetic good AND bad input offline
# and assert the exact red fires. A journey whose failure paths were never
# executed is itself a vacuous green.
#
# WHAT IS DIFFERENT HERE, AND WHY IT MATTERS. The live proofs judge the ENGINE'S
# OUTPUT. This one also judges the CLI'S SURFACE: `judge_verb_discoverable` reds
# when a verb the journey depends on is dispatched in Go but absent from `-h`,
# and `judge_undo_marker` reds when a cleanup note tells the operator to remove a
# marker the deploy engine never writes. Both are reds a stranger HITS and an
# insider never does, because an insider reads the source. They are the reason
# this file exists as well as its siblings.
#
# TYPED EXIT CODES (the named reds):
#    0 WALKED                        2 usage
#   20 DISCOVER_NO_BP               — no `bp` on PATH, or it has no `cloud site` verb
#   21 DISCOVER_NO_SESSION          — no verified cloud session
#   22 DISCOVER_NO_INSTANCE         — the session names no instance to spawn on
#   23 DISCOVER_NO_DATASET_ROUTE    — the ws/proj/ds triple is NOT discoverable from the CLI
#   24 DISCOVER_VERB_HIDDEN         — a verb the journey needs is dispatched but absent from -h
#   25 DISCOVER_NO_CONTENT          — the chosen doc type has 0 published docs (an EMPTY page)
#   30 CREATE_REFUSED               — `bp cloud site create` did not return a site
#   31 CREATE_NOT_CONTENT_BOUND     — the ghost 201: no read token, no dataset binding
#   32 CREATE_KIND_DIVERGED         — the CLI built a kind the console would not have derived
#   40 DEPLOY_FAILED                — the deployment never reached live
#   41 DEPLOY_STAGES_INCOMPLETE     — the six stages did not all land, in order
#   50 VISIT_NOT_200                — the live URL does not serve
#   51 VISIT_EMPTY                  — 200, but the content markers are empty (a vacuous page)
#   60 UNDO_UNREACHABLE             — a documented teardown names a marker the engine never writes
#   61 UNDO_FAILED                  — `bp cloud site delete` did not tear the site down
#   90 SELF_CHECK_FAILED            — a named red did NOT fire on input that must trigger it
set -uo pipefail

# ---- Config -----------------------------------------------------------------

INSTANCE="${INSTANCE:-}"
DATASET="${DATASET:-}"
# CONTENT REALITY (charter D31/D35, and the same value site-spawner-live-proof.sh
# defends): there is NO `post` type on guerrilla, and an undefined type answers
# 200 with count:0 — NOT 404 — so the Astro starter's default doc type builds a
# silently EMPTY page. The type is bound at CREATE via --doc-type.
DOC_TYPE="${BARKPARK_DOC_TYPE:-paper}"
BP="${BP:-bp}"
SLUG="${SLUG:-}"
KEEP="${KEEP:-0}"
MODE="full"

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

# ---- Named failures ----------------------------------------------------------

E_NO_BP=20
E_NO_SESSION=21
E_NO_INSTANCE=22
E_NO_DATASET_ROUTE=23
E_VERB_HIDDEN=24
E_NO_CONTENT=25
E_CREATE_REFUSED=30
E_CREATE_NOT_BOUND=31
E_CREATE_KIND_DIVERGED=32
E_DEPLOY_FAILED=40
E_DEPLOY_STAGES=41
E_VISIT_NOT_200=50
E_VISIT_EMPTY=51
E_UNDO_UNREACHABLE=60
E_UNDO_FAILED=61
E_SELF_CHECK=90

codename() {
  case "$1" in
    0) echo "WALKED" ;;
    2) echo "USAGE" ;;
    "$E_NO_BP") echo "DISCOVER_NO_BP" ;;
    "$E_NO_SESSION") echo "DISCOVER_NO_SESSION" ;;
    "$E_NO_INSTANCE") echo "DISCOVER_NO_INSTANCE" ;;
    "$E_NO_DATASET_ROUTE") echo "DISCOVER_NO_DATASET_ROUTE" ;;
    "$E_VERB_HIDDEN") echo "DISCOVER_VERB_HIDDEN" ;;
    "$E_NO_CONTENT") echo "DISCOVER_NO_CONTENT" ;;
    "$E_CREATE_REFUSED") echo "CREATE_REFUSED" ;;
    "$E_CREATE_NOT_BOUND") echo "CREATE_NOT_CONTENT_BOUND" ;;
    "$E_CREATE_KIND_DIVERGED") echo "CREATE_KIND_DIVERGED" ;;
    "$E_DEPLOY_FAILED") echo "DEPLOY_FAILED" ;;
    "$E_DEPLOY_STAGES") echo "DEPLOY_STAGES_INCOMPLETE" ;;
    "$E_VISIT_NOT_200") echo "VISIT_NOT_200" ;;
    "$E_VISIT_EMPTY") echo "VISIT_EMPTY" ;;
    "$E_UNDO_UNREACHABLE") echo "UNDO_UNREACHABLE" ;;
    "$E_UNDO_FAILED") echo "UNDO_FAILED" ;;
    "$E_SELF_CHECK") echo "SELF_CHECK_FAILED" ;;
    *) echo "UNNAMED_FAILURE_${1}" ;;
  esac
}

# fixhint <code> — THE EXACT FIX AT THE EXACT STEP. This is the half of the row
# that separates a journey from a test: a stranger who hits a red must be able to
# read a runnable next command, not a diagnosis. Every typed red has an entry,
# and `--self-check` asserts that (an unhinted red is a dead end).
fixhint() {
  case "$1" in
    "$E_NO_BP") echo "install the CLI: curl -fsSL https://barkpark.cloud/install.sh | sh   (then: bp cloud site -h)" ;;
    "$E_NO_SESSION") echo "bp login          # then re-run; 'bp whoami' must show cloud.session=verified" ;;
    "$E_NO_INSTANCE") echo "bp cloud status   # lists the instances your team owns; a site is spawned ON one" ;;
    "$E_NO_DATASET_ROUTE") echo "pass it explicitly for now: DATASET=<ws>/<proj>/<ds> bash \$0   (see 'bp whoami' for the current triple)" ;;
    "$E_VERB_HIDDEN") echo "the verb works — it is the HELP that is wrong; fix the USAGE block in internal/cli/cloud_site_cmd.go" ;;
    "$E_NO_CONTENT") echo "bp schema ls    # then re-run with --doc-type <a type that has documents>" ;;
    "$E_CREATE_REFUSED") echo "read the printed envelope's error.code; 'bp cloud status' proves the instance is live and yours" ;;
    "$E_CREATE_NOT_BOUND") echo "bp cloud site delete <slug> --yes && re-run: a site with no read token can never build your content" ;;
    "$E_CREATE_KIND_DIVERGED") echo "pass --kind explicitly, and fix siteKindForFramework in internal/cli/cloud_site_cmd.go to match cloud/priv/static/app.js" ;;
    "$E_DEPLOY_FAILED") echo "bp cloud site status <slug>   # names the stage that died and its reason" ;;
    "$E_DEPLOY_STAGES") echo "bp cloud site status <slug>   # a deploy that went live without all six stages is an engine bug, not yours" ;;
    "$E_VISIT_NOT_200") echo "bp cloud site status <slug>   # if it says live, the Caddy route did not arm — that is a box-side ROUTE failure" ;;
    "$E_VISIT_EMPTY") echo "bp cloud site settings <slug> --doc-type <a type with published docs> && bp cloud site deploy <slug>" ;;
    "$E_UNDO_UNREACHABLE") echo "fix the cleanup note to name the marker deploy/site-deploy.sh actually writes: BARKPARK_SITE_ROUTE:<slug>" ;;
    "$E_UNDO_FAILED") echo "bp cloud site delete <slug> --yes   # if it still refuses, 'bp cloud site status <slug>' names why" ;;
    "$E_SELF_CHECK") echo "a judge stopped discriminating — fix the judge before trusting any green from this script" ;;
    *) echo "" ;;
  esac
}

RED=""; GRN=""; DIM=""; BLD=""; OFF=""
if [ -t 2 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'; fi

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n%s▸ %s%s\n' "$BLD" "$*" "$OFF" >&2; }
ok() { printf '  %s✓%s %s\n' "$GRN" "$OFF" "$*" >&2; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$OFF" >&2; }

fail() {
  local code="$1" why="$2" hint="${3:-}"
  [ -n "$hint" ] || hint="$(fixhint "$code")"
  printf '\n%s✗ %s%s  %s(exit %s)%s\n' "$RED$BLD" "$(codename "$code")" "$OFF" "$DIM" "$code" "$OFF" >&2
  printf '  %s\n' "$why" >&2
  [ -n "$hint" ] && printf '  %s→ %s%s\n' "$DIM" "$hint" "$OFF" >&2
  cleanup
  exit "$code"
}

# ---- Small helpers -----------------------------------------------------------

jget() {
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

cli_err() {
  local msg
  msg="$(jget "$1" error.message)"
  [ -n "$msg" ] || msg="$(jget "$1" error.code)"
  [ -n "$msg" ] || msg="$(head -c 400 "${2:-/dev/null}" 2>/dev/null)"
  [ -n "$msg" ] || msg="(the CLI produced no error envelope and no stderr)"
  printf '%s' "$msg"
}

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/first-run.XXXXXX")"
CREATED_SITE=""

cleanup() {
  if [ -n "$CREATED_SITE" ] && [ "$KEEP" != "1" ]; then
    note "cleanup: tearing down '$CREATED_SITE'"
    "$BP" cloud site delete "$CREATED_SITE" --yes >/dev/null 2>&1 \
      || note "cleanup: 'bp cloud site delete $CREATED_SITE --yes' FAILED — the site is still up, and so is its read token."
  elif [ -n "$CREATED_SITE" ]; then
    note "cleanup: --keep — '$CREATED_SITE' is LEFT IN PLACE (its read token stays live)."
  fi
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# =============================================================================
# THE PURE JUDGES — every assertion, as a function over values, returning its
# typed red. No network, no globals. `--self-check` drives each of these with
# input that MUST fail, and asserts the exact code comes back.
# =============================================================================

# judge_bp <bp_on_path:true|false> <cloud_site_verb_present:true|false>
# A `bp` that exists but predates the `cloud site` family is the SAME dead end as
# no bp at all — and is the likelier one, because an old bp is already installed.
judge_bp() {
  [ "$1" = "true" ] || return "$E_NO_BP"
  [ "$2" = "true" ] || return "$E_NO_BP"
  return 0
}

# judge_session <logged_in> <session_state>
# `logged_in:true` with an UNVERIFIED session is the trap: the token file exists,
# so every "am I logged in" check a stranger can think of says yes, and the first
# real call 401s three steps later. Verified, or it is not a session.
judge_session() {
  [ "$1" = "true" ] || return "$E_NO_SESSION"
  [ "$2" = "verified" ] || return "$E_NO_SESSION"
  return 0
}

# judge_instance <name>
# A site is spawned ON a box. No box, no site — and the CLI's own required-flag
# error names `bp cloud status`, which is the good counter-example this whole
# script measures the other inputs against.
judge_instance() {
  [ -n "$1" ] || return "$E_NO_INSTANCE"
  return 0
}

# judge_dataset_route <lister_verb:true|false> <ws> <proj> <ds>
# THE GAP THIS ROW WAS FILED FOR. `--dataset <ws/proj/ds>` is the single most
# typo-prone input in the create call and there is NO lister verb on either
# surface — not `bp cloud workspace list`, not `bp datasets`, nothing (verified
# on origin/main: cloud_workspace_cmd.go dispatches export/import/help ONLY).
#
# A triple read out of `bp whoami` — which is what this journey falls back to —
# is a WORKAROUND, not a route: whoami reports the ONE dataset the local config
# is pointed at, so a stranger with two projects cannot discover the second, and
# a stranger with a typo'd config discovers a triple that does not exist. So the
# judge takes BOTH facts: a usable triple keeps the walk moving, but the missing
# lister is reported by name either way, and with NO triple at all it is fatal.
judge_dataset_route() {
  local lister="$1" ws="$2" proj="$3" ds="$4"
  [ -n "$ws" ] && [ -n "$proj" ] && [ -n "$ds" ] || return "$E_NO_DATASET_ROUTE"
  # A present lister is the real close; its absence is survivable ONLY because
  # the fallback produced a triple, which the line above just proved.
  [ "$lister" = "true" ] || return 0
  return 0
}

# judge_verb_discoverable <verb> <help-text>
# THE STRANGER'S RED, and the one an insider structurally cannot hit. A verb that
# `runCloudSite` dispatches but `bp cloud site -h` never prints is reachable only
# by reading Go. `delete` was exactly this for the whole of wave 8: dispatched,
# undocumented, so the UNDO verb was unreachable by anyone who could not read the
# source — a stranger could create sites and never learn how to remove them.
judge_verb_discoverable() {
  local verb="$1" help="$2"
  case "$help" in
    *"bp cloud site $verb"*) return 0 ;;
    *) return "$E_VERB_HIDDEN" ;;
  esac
}

# judge_content <published-count>
# An undefined doc type answers 200 with count:0, NOT 404 — so a wrong --doc-type
# builds a cheerful, EMPTY site and every downstream check passes. Refuse here,
# where the fix is one flag, rather than at VISIT, where it looks like a bug.
judge_content() {
  local n="$1"
  case "$n" in
    ''|*[!0-9]*) return "$E_NO_CONTENT" ;;
  esac
  [ "$n" -gt 0 ] || return "$E_NO_CONTENT"
  return 0
}

# judge_create_returned <slug-the-server-sent-back>
# CREATE's own refusal. Split from judge_create deliberately: "the call failed"
# and "the call succeeded but bound nothing" are different reds with different
# fixes (read the envelope vs. delete and re-run), and folding them would send an
# operator whose instance is not live to the wrong one. Pure, so it fires offline.
judge_create_returned() {
  [ -n "$1" ] || return "$E_CREATE_REFUSED"
  return 0
}

# judge_create <content_bound> <workspace> <project> <dataset>
# The ghost-201 detector: the create path once answered 201 while silently
# DROPPING the content binding. `bound` is the server's own
# `not is_nil(read_token_encrypted)`.
judge_create() {
  local bound="$1" ws="$2" proj="$3" ds="$4"
  [ "$bound" = "true" ] || return "$E_CREATE_NOT_BOUND"
  [ -n "$ws" ] && [ -n "$proj" ] && [ -n "$ds" ] || return "$E_CREATE_NOT_BOUND"
  return 0
}

# judge_kind <framework> <kind_requested> <kind_stored>
# THE DIVERGENCE, judged from OUTSIDE the CLI. The console's create form derives
# kind from framework (cloud/priv/static/app.js siteKindFor: astro -> static,
# every container framework -> node). The CLI used to hard-default "static", so
# `--framework nextjs` alone built a static site from the terminal and a node
# site from the browser — the same intent, two different products, and the
# console cannot even EXPRESS the mistake. siteKindForFramework now mirrors the
# console rule; this judge is the guard that it keeps mirroring it, asserted
# against what the SERVER stored, not against the CLI's own belief.
judge_kind() {
  local fw="$1" want="$2" got="$3"
  local derived="node"
  [ "$fw" = "astro" ] && derived="static"
  # An explicit request always wins — the flag is not advisory.
  [ -n "$want" ] && derived="$want"
  [ -n "$got" ] || return "$E_CREATE_KIND_DIVERGED"
  # The server calls a node site "container"; the CLI's user-facing verb is "node".
  case "$derived:$got" in
    node:container | node:node | static:static) return 0 ;;
    *) return "$E_CREATE_KIND_DIVERGED" ;;
  esac
}

# judge_stages <status> <stage-names-in-observed-order…>
judge_stages() {
  local status="$1"; shift
  local want="PLAN BUILD STAGE HEALTH SWITCH RETIRE"
  local got="$*"
  [ "$got" = "$want" ] || return "$E_DEPLOY_STAGES"
  [ "$status" = "live" ] || return "$E_DEPLOY_FAILED"
  return 0
}

# judge_visit <http_code> <served_build_id> <expected_build_id> <content_rev> <doc_id> <doc_title>
# Assert by VALUE. A build with the WRONG bp-build-id went live on this box once
# and a reachability check called it green; and a page that rendered with NO
# content still returns a cheerful 200. The three content markers are asserted
# TOGETHER — any one empty is a vacuous green.
judge_visit() {
  local code="$1" served="$2" expect="$3" rev="$4" doc="$5" title="$6"
  [ "$code" = "200" ] || return "$E_VISIT_NOT_200"
  [ -n "$expect" ] || return "$E_VISIT_NOT_200"
  [ "$served" = "$expect" ] || return "$E_VISIT_NOT_200"
  [ -n "$rev" ] && [ -n "$doc" ] && [ -n "$title" ] || return "$E_VISIT_EMPTY"
  return 0
}

# judge_undo_marker <marker-named-in-the-note> <marker-the-engine-writes>
# THE DOCUMENTED-RECOVERY RED. Three sibling proof scripts told the operator, in
# their cleanup notes, to drop a `# barkpark-site:<slug>` block from the
# Caddyfile. The engine writes `BARKPARK_SITE_ROUTE:<slug>`
# (deploy/site-deploy.sh site_route_marker_re, deploy/site-deploy-node.sh:249),
# and `grep -c 'barkpark-site:'` on the live Caddyfile returns 0. The documented
# manual recovery could not work as written: a stranger following OUR OWN scripts
# greps for a string nothing writes, finds nothing, and concludes the route is
# already gone while it is still serving.
#
# The judge is a string identity, so `--self-check` can drive it — and the run
# also drives it over the REAL cleanup notes in deploy/*.sh (see
# scan_undo_markers), which is what turns this finding into a check with a
# trigger instead of a paragraph someone has to remember.
judge_undo_marker() {
  [ -n "$2" ] || return "$E_UNDO_UNREACHABLE"
  [ "$1" = "$2" ] || return "$E_UNDO_UNREACHABLE"
  return 0
}

# judge_undo <delete_ok> <status_after>
# The teardown is only done when the site is GONE. A 200 from delete followed by
# a site that still resolves is the failure this catches.
judge_undo() {
  local okflag="$1" after="$2"
  [ "$okflag" = "true" ] || return "$E_UNDO_FAILED"
  case "$after" in
    "" | not_found | deleted) return 0 ;;
    *) return "$E_UNDO_FAILED" ;;
  esac
}

# =============================================================================
# THE REAL-CORPUS ARM — the judges above are pure, which is what makes them
# testable; this is what keeps them from being tested only against fiction.
# =============================================================================

# scan_undo_markers — read EVERY cleanup note in deploy/*.sh and assert that the
# Caddy marker it tells an operator to remove is the one the engine writes.
#
# THE PREDICATE, NOT A LIST. The original finding named three files. A list of
# three files goes stale the moment a fourth script copies the note; the rule is
# "no deploy script may instruct an operator to grep for a Caddy marker the
# engine does not write", so that is what is enforced. Any `barkpark-site:<...>`
# occurrence in deploy/*.sh is a red, wherever it appears and however new.
#
# Prints the offending "file:line" lines on stdout and returns non-zero when any
# exist. Silent + 0 when clean.
# THE ONE EXCLUSION, AND WHY IT IS NOT A SKIP LIST. This file is excluded from
# its own scan, by basename, because a guard MUST be able to quote the string it
# forbids — the rule's own prose, its judge fixtures and this grep pattern all
# contain `barkpark-site:` and always will. Excluding the guard is the same shape
# as a retraction that quotes what it retracts. It is exactly ONE file, chosen by
# the structural reason "it is the enforcer", not by "it was inconvenient": every
# other deploy script, present or future, is scanned.
scan_undo_markers() {
  local dir="${1:-$ROOT/deploy}"
  local self
  self="$(basename -- "${BASH_SOURCE[0]}")"
  local hits
  hits="$(grep -n 'barkpark-site:' "$dir"/*.sh 2>/dev/null | grep -v "/$self:" || true)"
  [ -n "$hits" ] || return 0
  printf '%s\n' "$hits"
  return 1
}

# =============================================================================
# --self-check — every named red must fire on input that must trigger it.
# =============================================================================

SC_FAILED=0
SC_RUN=0
# The typed codes an expect_code arm actually asserted this run. ALL_REDS is the
# roster; this is the attendance sheet, and the two are compared below — a red
# that is merely DEFINED has not been proven to fire.
SC_FIRED=""

expect_code() {
  local want="$1" desc="$2"; shift 2
  local got=0
  SC_RUN=$((SC_RUN + 1))
  SC_FIRED="$SC_FIRED $want"

  "$@" || got=$?
  if [ "$got" = "$want" ]; then
    ok "$(printf '%-28s' "$(codename "$want")") $desc"
  else
    printf '  %s✗%s %s: expected %s (%s), got %s (%s)\n' \
      "$RED" "$OFF" "$desc" "$want" "$(codename "$want")" "$got" "$(codename "$got")" >&2
    SC_FAILED=1
  fi
}

expect_pass() {
  local desc="$1"; shift
  local got=0
  SC_RUN=$((SC_RUN + 1))
  "$@" || got=$?
  if [ "$got" = 0 ]; then
    ok "$(printf '%-28s' "PASS") $desc"
  else
    printf '  %s✗%s %s: expected a PASS, got %s (%s)\n' "$RED" "$OFF" "$desc" "$got" "$(codename "$got")" >&2
    SC_FAILED=1
  fi
}

# Every typed red this script can exit with. The self-check asserts each one is
# NAMED and HINTED, and — the point of the list — that each one FIRED below.
ALL_REDS="$E_NO_BP $E_NO_SESSION $E_NO_INSTANCE $E_NO_DATASET_ROUTE $E_VERB_HIDDEN $E_NO_CONTENT $E_CREATE_REFUSED $E_CREATE_NOT_BOUND $E_CREATE_KIND_DIVERGED $E_DEPLOY_FAILED $E_DEPLOY_STAGES $E_VISIT_NOT_200 $E_VISIT_EMPTY $E_UNDO_UNREACHABLE $E_UNDO_FAILED"

self_check() {
  step "SELF-CHECK — every named red must fire on input that must trigger it"

  note "DISCOVER — the bp binary"
  expect_pass "a bp with the cloud site family" judge_bp true true
  expect_code "$E_NO_BP" "no bp on PATH at all"                     judge_bp false false
  expect_code "$E_NO_BP" "a bp too old to know 'cloud site'"        judge_bp true false

  note "DISCOVER — the session"
  expect_pass "logged in and verified" judge_session true verified
  expect_code "$E_NO_SESSION" "never logged in"                     judge_session false ""
  expect_code "$E_NO_SESSION" "THE TRAP: a token file exists but the session is UNVERIFIED" \
    judge_session true unverified

  note "DISCOVER — the instance (a site is spawned ON a box)"
  expect_pass "an instance was named" judge_instance guerrilla
  expect_code "$E_NO_INSTANCE" "the session names no instance"      judge_instance ""

  note "DISCOVER — the ws/proj/ds triple (the row's headline gap)"
  expect_pass "a lister exists AND the triple resolves"             judge_dataset_route true default default production
  expect_pass "no lister, but the whoami fallback produced a triple" judge_dataset_route false default default production
  expect_code "$E_NO_DATASET_ROUTE" "no lister and no triple — the stranger is stuck" \
    judge_dataset_route false "" "" ""
  expect_code "$E_NO_DATASET_ROUTE" "a triple missing its dataset segment" \
    judge_dataset_route true default default ""

  note "DISCOVER — a verb the journey needs must be in -h, not only in the switch"
  expect_pass "delete is documented" judge_verb_discoverable delete \
    "USAGE
  bp cloud site delete    <site> [--yes]   tear the site down  (alias: rm)"
  expect_code "$E_VERB_HIDDEN" "THE STRANGER'S RED: delete is dispatched but absent from -h" \
    judge_verb_discoverable delete "USAGE
  bp cloud site create --name <n>
  bp cloud site deploy <site>"
  expect_code "$E_VERB_HIDDEN" "ls is absent from -h (nothing to enumerate before deleting)" \
    judge_verb_discoverable ls "USAGE
  bp cloud site create --name <n>"

  note "DISCOVER — published content (an undefined type answers 200 with count:0)"
  expect_pass "100 published docs" judge_content 100
  expect_code "$E_NO_CONTENT" "0 docs — the build would produce an EMPTY page" judge_content 0
  expect_code "$E_NO_CONTENT" "the count endpoint answered with no number at all" judge_content ""
  expect_code "$E_NO_CONTENT" "a non-numeric count"                              judge_content "many"

  note "CREATE"
  expect_pass "the server sent a slug back" judge_create_returned first-run-1757000000
  expect_code "$E_CREATE_REFUSED" "create returned no site at all (the instance is not live, or not yours)" \
    judge_create_returned ""
  expect_pass "a content-bound site" judge_create true default default production
  expect_code "$E_CREATE_NOT_BOUND" "the ghost 201 (no read token stored)"  judge_create false default default production
  expect_code "$E_CREATE_NOT_BOUND" "201 with the dataset binding dropped"  judge_create true "" "" ""

  note "CREATE — the CLI's kind must be the kind the CONSOLE would derive"
  expect_pass "astro, kind omitted -> static"          judge_kind astro "" static
  expect_pass "nextjs, kind omitted -> node"           judge_kind nextjs "" container
  expect_pass "an explicit --kind still wins"          judge_kind nextjs static static
  expect_code "$E_CREATE_KIND_DIVERGED" "THE DIVERGENCE: --framework nextjs alone built a STATIC site" \
    judge_kind nextjs "" static
  expect_code "$E_CREATE_KIND_DIVERGED" "astro somehow became a node site"  judge_kind astro "" container
  expect_code "$E_CREATE_KIND_DIVERGED" "the server stored no kind at all"  judge_kind nextjs "" ""

  note "DEPLOY"
  expect_pass "six stages, in order, live" judge_stages live PLAN BUILD STAGE HEALTH SWITCH RETIRE
  expect_code "$E_DEPLOY_STAGES" "only three stages ever landed"       judge_stages live PLAN BUILD STAGE
  expect_code "$E_DEPLOY_STAGES" "six stages but OUT of order"         judge_stages live PLAN BUILD HEALTH STAGE SWITCH RETIRE
  expect_code "$E_DEPLOY_FAILED" "all six stages, but never went live" judge_stages queued PLAN BUILD STAGE HEALTH SWITCH RETIRE

  note "VISIT — by VALUE, never by reachability"
  expect_pass "200, the build id matches, all three content markers present" \
    judge_visit 200 b-abc b-abc rev-1 doc-1 title-1
  expect_code "$E_VISIT_NOT_200" "the URL 404s"                             judge_visit 404 b-abc b-abc rev-1 doc-1 title-1
  expect_code "$E_VISIT_NOT_200" "200, but an older build is still served"  judge_visit 200 b-old b-abc rev-1 doc-1 title-1
  expect_code "$E_VISIT_NOT_200" "the deploy named no build id to expect"   judge_visit 200 b-abc "" rev-1 doc-1 title-1
  expect_code "$E_VISIT_EMPTY"   "200 but bp-doc-id is empty (an empty page)" judge_visit 200 b-abc b-abc rev-1 "" title-1
  expect_code "$E_VISIT_EMPTY"   "200 but bp-content-rev is empty"          judge_visit 200 b-abc b-abc "" doc-1 title-1
  expect_code "$E_VISIT_EMPTY"   "200 but bp-doc-title is empty"            judge_visit 200 b-abc b-abc rev-1 doc-1 ""

  note "UNDO — the documented recovery must name a marker the engine WRITES"
  expect_pass "the note names BARKPARK_SITE_ROUTE, which is what site-deploy.sh writes" \
    judge_undo_marker "BARKPARK_SITE_ROUTE:demo" "BARKPARK_SITE_ROUTE:demo"
  expect_code "$E_UNDO_UNREACHABLE" "THE DEAD RECOVERY: the note says '# barkpark-site:demo' and nothing writes it" \
    judge_undo_marker "barkpark-site:demo" "BARKPARK_SITE_ROUTE:demo"
  expect_code "$E_UNDO_UNREACHABLE" "the engine writes no marker at all — nothing to grep for" \
    judge_undo_marker "BARKPARK_SITE_ROUTE:demo" ""

  note "UNDO — the site must actually be gone"
  expect_pass "delete succeeded and the site no longer resolves" judge_undo true not_found
  expect_code "$E_UNDO_FAILED" "delete refused"                  judge_undo false ""
  expect_code "$E_UNDO_FAILED" "delete said 200 and the site is STILL live" judge_undo true live

  # ---- the real-corpus arm ---------------------------------------------------
  #
  # Everything above is judged against fiction, which is the only way to drive a
  # failure path offline — and is exactly why it can be 100% green over a repo
  # that ships the bug. This block runs judge_undo_marker's rule over the ACTUAL
  # cleanup notes in deploy/*.sh. It is the arm that would have caught the
  # original finding, and it is the arm that reds if anyone re-introduces it.
  note "the real corpus: no deploy/*.sh cleanup note may name a marker the engine never writes"
  local scan_out=""
  if scan_out="$(scan_undo_markers "$ROOT/deploy")"; then
    ok "$(printf '%-28s' "CORPUS") every Caddy marker in deploy/*.sh is one deploy/site-deploy.sh writes"
  else
    printf '  %s✗%s a deploy script tells the operator to grep for a marker nothing writes:\n' "$RED" "$OFF" >&2
    printf '%s\n' "$scan_out" | sed 's/^/      /' >&2
    printf '      %s→ %s%s\n' "$DIM" "$(fixhint "$E_UNDO_UNREACHABLE")" "$OFF" >&2
    SC_FAILED=1
  fi
  # …and prove that scan CAN red, on a corpus that contains the defect. Without
  # this the clean green above is indistinguishable from a grep that stopped
  # matching (a moved directory, a renamed marker, an empty deploy/).
  local ctl="$TMP/ctl-corpus"
  mkdir -p "$ctl"
  printf '#!/usr/bin/env bash\n# drop the %s block from the Caddyfile\n' "'# barkpark-site:planted'" >"$ctl/planted.sh"
  if scan_undo_markers "$ctl" >/dev/null; then
    printf '  %s✗%s the corpus scan did NOT red on a planted bad marker — it is not discriminating\n' "$RED" "$OFF" >&2
    SC_FAILED=1
  else
    ok "$(printf '%-28s' "CONTROL") a planted '# barkpark-site:' note reds the corpus scan"
  fi

  # ---- every red is named, hinted, and was exercised --------------------------
  note "every typed red is NAMED and carries a runnable fix"
  local code bad=0
  for code in $ALL_REDS; do
    case "$(codename "$code")" in
      UNNAMED_FAILURE_*) printf '  %s✗%s exit %s has no name\n' "$RED" "$OFF" "$code" >&2; bad=1 ;;
    esac
    [ -n "$(fixhint "$code")" ] || { printf '  %s✗%s %s has no fix hint — a red with no next command is a dead end\n' "$RED" "$OFF" "$(codename "$code")" >&2; bad=1; }
  done
  for code in $ALL_REDS; do
    case " $SC_FIRED " in
      *" $code "*) ;;
      *) printf '  %s✗%s %s (exit %s) is DEFINED but no self-check arm ever made it fire — it is dead code\n' \
           "$RED" "$OFF" "$(codename "$code")" "$code" >&2; bad=1 ;;
    esac
  done
  if [ "$bad" = 0 ]; then
    ok "$(printf '%-28s' "NAMED+HINTED") all $(printf '%s' "$ALL_REDS" | wc -w | tr -d ' ') typed reds NAMED, HINTED and FIRED"
  else
    SC_FAILED=1
  fi
  if [ "$(codename 255)" = "UNNAMED_FAILURE_255" ]; then
    ok "$(printf '%-28s' "NAMED") an unmapped code reports as unnamed, never as a pass"
  else
    printf '  %s✗%s codename() invented a name for an unmapped code\n' "$RED" "$OFF" >&2
    SC_FAILED=1
  fi

  # A FLOOR on the number of assertions. A zero-findings self-check looks
  # identical whether it ran 60 judges or 3; this is the one number that gives a
  # silently-shrunken run away. Lower it DELIBERATELY, never by accident.
  local floor=47
  if [ "$SC_RUN" -lt "$floor" ]; then
    printf '  %s✗%s only %s judge assertions ran; the committed floor is %s. The self-check lost a block.\n' \
      "$RED" "$OFF" "$SC_RUN" "$floor" >&2
    SC_FAILED=1
  fi

  say ""
  if [ "$SC_FAILED" -ne 0 ]; then
    fail "$E_SELF_CHECK" "a named red did NOT fire on input that must trigger it (see above)" \
      "the journey's failure paths are dead code — fix them before trusting any green"
  fi
  printf '%s✓ SELF-CHECK PASSED%s — %s judge assertions, %s typed reds, every one fires by name.\n' \
    "$GRN$BLD" "$OFF" "$SC_RUN" "$(printf '%s' "$ALL_REDS" | wc -w | tr -d ' ')" >&2
  return 0
}

# =============================================================================
# THE WALK
# =============================================================================

# Values discovered in DISCOVER, consumed later.
D_WS=""; D_PROJ=""; D_DS=""; D_INSTANCE=""; D_HELP=""

discover() {
  step "DISCOVER — everything the create call needs, from commands a stranger can find"

  local has_bp=false has_family=false
  command -v "$BP" >/dev/null 2>&1 && has_bp=true
  if [ "$has_bp" = true ]; then
    D_HELP="$("$BP" cloud site -h 2>&1 || true)"
    case "$D_HELP" in *"bp cloud site create"*) has_family=true ;; esac
  fi
  judge_bp "$has_bp" "$has_family" || fail $? \
    "'$BP' is missing, or it is a build with no 'cloud site' family (\`bp cloud site -h\` printed nothing usable)."
  ok "bp is on PATH and 'bp cloud site -h' documents the family"

  # The verbs THIS journey depends on. Each must be in -h — a verb only the Go
  # switch knows about is unreachable to the person this script is written for.
  local verb
  for verb in create deploy delete ls status; do
    judge_verb_discoverable "$verb" "$D_HELP" || fail $? \
      "'bp cloud site $verb' is dispatched by the CLI but never appears in 'bp cloud site -h', so a stranger cannot find it."
    ok "'bp cloud site $verb' is discoverable from -h"
  done

  "$BP" whoami -o json >"$TMP/who.json" 2>"$TMP/who.err" || true
  local logged sess
  logged="$(jget "$TMP/who.json" cloud.logged_in)"
  sess="$(jget "$TMP/who.json" cloud.session)"
  judge_session "$logged" "$sess" || fail $? \
    "no verified cloud session (logged_in=${logged:-false}, session=${sess:-none}). A token FILE is not a session."
  ok "cloud session verified (team $(jget "$TMP/who.json" cloud.team))"

  D_INSTANCE="$INSTANCE"
  [ -n "$D_INSTANCE" ] || D_INSTANCE="$(jget "$TMP/who.json" instance.name)"
  judge_instance "$D_INSTANCE" || fail $? \
    "no instance to spawn on: neither \$INSTANCE nor 'bp whoami' named one."
  ok "instance: $D_INSTANCE"

  # THE GAP. There is no lister verb on either surface, so the only route to the
  # triple is the local config as reported by whoami — which reports ONE triple,
  # the one this machine is pointed at. Report the gap by name even when the
  # fallback works, so a green run still says out loud what a stranger cannot do.
  local lister=false
  if "$BP" cloud workspace -h 2>&1 | grep -qE 'bp cloud workspace (ls|list)'; then lister=true; fi
  if [ -n "$DATASET" ]; then
    D_WS="${DATASET%%/*}"; local restds="${DATASET#*/}"
    D_PROJ="${restds%%/*}"; D_DS="${restds##*/}"
  else
    D_WS="$(jget "$TMP/who.json" workspace)"
    D_PROJ="$(jget "$TMP/who.json" project)"
    D_DS="$(jget "$TMP/who.json" dataset)"
  fi
  judge_dataset_route "$lister" "$D_WS" "$D_PROJ" "$D_DS" || fail $? \
    "no ws/proj/ds triple, and no CLI verb lists them: 'bp cloud workspace' dispatches export/import only, and nothing in the CLI enumerates workspaces, projects or datasets."
  if [ "$lister" = true ]; then
    ok "dataset: $D_WS/$D_PROJ/$D_DS (discovered with 'bp cloud workspace ls')"
  else
    ok "dataset: $D_WS/$D_PROJ/$D_DS"
    note "OPEN GAP — there is still NO lister verb for workspaces/projects/datasets."
    note "  The triple above came from THIS MACHINE'S config via 'bp whoami', not from a"
    note "  discovery route. A stranger with two projects cannot find the second one, and"
    note "  a stranger with a typo'd config discovers a triple that does not exist."
  fi

  # Published content, judged BEFORE anything is minted.
  #
  # Counted through `bp doc ls <type> --limit 1`, which is a verb a stranger can
  # find in `bp doc -h`, NOT through a raw HTTPS fetch. The first version of this
  # wall curled the public /api/documents route and got 401/404 on every shape,
  # so the wall DEGRADED TO A NOTE on every run — a wall that never executes is
  # the untested path this whole script exists to refuse. `bp doc ls` uses the
  # session the walk has already verified, so it runs.
  #
  # AND A not_found IS A ZERO, NOT AN UNKNOWN. `bp doc ls post` on guerrilla —
  # `post` being the Astro starter's DEFAULT doc type, and the exact trap this
  # wall exists for — answers error.code=not_found, exit 4. Reading that as "the
  # count was unreadable" and skipping would let the single most likely first-run
  # mistake walk straight past the wall built to catch it. An absent or empty
  # type is a type with no content; that is a red.
  local count err
  "$BP" doc ls "$DOC_TYPE" --limit 1 -o json >"$TMP/docs.json" 2>/dev/null || true
  count="$(jget "$TMP/docs.json" count)"
  err="$(jget "$TMP/docs.json" error.code)"
  [ -n "$count" ] || [ "$err" != "not_found" ] || count=0
  if [ -z "$count" ]; then
    note "could not read a document count for type '$DOC_TYPE' ('bp doc ls $DOC_TYPE --limit 1')"
    note "  — the content wall is SKIPPED, not passed. VISIT still asserts the content"
    note "    markers by value, so an empty build is still caught, three steps later."
  else
    judge_content "$count" || fail $? \
      "doc type '$DOC_TYPE' has $count documents in $D_WS/$D_PROJ/$D_DS — the build would produce an EMPTY page, and an undefined type answers 200 with count:0, not 404."
    ok "content: 'bp doc ls $DOC_TYPE' returns documents — the build will have something to render"
  fi

  # The documented UNDO, checked against what the engine actually writes. This
  # runs on the LIVE walk too, not only in --self-check: a stranger who has just
  # created a site is exactly the person who will need the teardown note.
  local scan_out=""
  if scan_out="$(scan_undo_markers "$ROOT/deploy")"; then
    ok "every teardown note in deploy/*.sh names the marker the engine writes"
  else
    fail "$E_UNDO_UNREACHABLE" \
      "a deploy script instructs the operator to remove a Caddy marker the engine NEVER writes (the engine writes BARKPARK_SITE_ROUTE:<slug>):
$(printf '%s\n' "$scan_out" | sed 's/^/    /')"
  fi
}

walk() {
  discover

  [ -n "$SLUG" ] || SLUG="first-run-$(date +%s)"

  step "CREATE — one command, from the values DISCOVER just found"
  local fw="${FRAMEWORK:-astro}" kind="${KIND:-}"
  say "  \$ bp cloud site create --name $SLUG --dataset $D_WS/$D_PROJ/$D_DS --instance $D_INSTANCE --framework $fw --doc-type $DOC_TYPE"
  local cargs=(cloud site create --name "$SLUG" --dataset "$D_WS/$D_PROJ/$D_DS"
    --instance "$D_INSTANCE" --framework "$fw" --doc-type "$DOC_TYPE" -o json)
  [ -n "$kind" ] && cargs+=(--kind "$kind")
  "$BP" "${cargs[@]}" >"$TMP/create.json" 2>"$TMP/create.err" || true
  local slug_back
  slug_back="$(jget "$TMP/create.json" site.slug)"
  [ -n "$slug_back" ] || slug_back="$(jget "$TMP/create.json" slug)"
  judge_create_returned "$slug_back" || fail $? \
    "create returned no site: $(cli_err "$TMP/create.json" "$TMP/create.err")"
  CREATED_SITE="$slug_back"
  judge_create "$(jget "$TMP/create.json" site.content_bound)" "$D_WS" "$D_PROJ" "$D_DS" || fail $? \
    "the site was created but carries NO stored read token — it can never build your content (the ghost 201)."
  ok "created '$CREATED_SITE', content-bound to $D_WS/$D_PROJ/$D_DS"
  judge_kind "$fw" "$kind" "$(jget "$TMP/create.json" site.kind)" || fail $? \
    "the CLI built kind='$(jget "$TMP/create.json" site.kind)' for --framework $fw; the console's create form would have derived a different one for the same intent."
  ok "kind matches what the console would derive for --framework $fw"

  step "DEPLOY — the six visible stages"
  "$BP" cloud site deploy "$CREATED_SITE" -o json >"$TMP/deploy.json" 2>"$TMP/deploy.err" || true
  local stages status
  status="$(jget "$TMP/deploy.json" deployment.status)"
  stages="$(python3 - "$TMP/deploy.json" <<'PY' 2>/dev/null || true
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
st=(d.get("deployment") or {}).get("stages") or d.get("stages") or []
print(" ".join((s.get("name") or "").upper() for s in st if isinstance(s,dict)))
PY
)"
  # The stage names are a deliberate word list — word splitting is the point.
  # shellcheck disable=SC2086
  judge_stages "$status" $stages || fail $? \
    "deploy ended status='$status' with stages [$stages]: $(cli_err "$TMP/deploy.json" "$TMP/deploy.err")"
  ok "six stages landed in order; deployment is live"

  step "VISIT — the live URL, judged by VALUE"
  local site_url code
  site_url="$(jget "$TMP/deploy.json" site.url)"
  [ -n "$site_url" ] || site_url="https://${D_INSTANCE}.barkpark.cloud/sites/$CREATED_SITE/"
  code="$(curl -sS -o "$TMP/live.html" -w '%{http_code}' --max-time 30 "$site_url" 2>/dev/null || echo 000)"
  judge_visit "$code" \
    "$(meta_content "$TMP/live.html" bp-build-id)" \
    "$(jget "$TMP/deploy.json" deployment.build_id)" \
    "$(meta_content "$TMP/live.html" bp-content-rev)" \
    "$(meta_content "$TMP/live.html" bp-doc-id)" \
    "$(meta_content "$TMP/live.html" bp-doc-title)" || fail $? \
    "$site_url answered $code and did not serve the build this walk just deployed with its content markers intact."
  say ""
  printf '%s✓ WALKED%s — a stranger reached a live site: %s\n' "$GRN$BLD" "$OFF" "$site_url" >&2

  step "UNDO — the verb the stranger must be able to find"
  "$BP" cloud site delete "$CREATED_SITE" --yes -o json >"$TMP/del.json" 2>"$TMP/del.err" || true
  local delok after
  delok="$(jget "$TMP/del.json" ok)"; [ -n "$delok" ] || delok=true
  "$BP" cloud site status "$CREATED_SITE" -o json >"$TMP/after.json" 2>/dev/null || true
  after="$(jget "$TMP/after.json" error.code)"
  [ -n "$after" ] || after="$(jget "$TMP/after.json" site.status)"
  judge_undo "$delok" "$after" || fail $? \
    "'bp cloud site delete $CREATED_SITE --yes' did not tear the site down (status after: ${after:-unknown}): $(cli_err "$TMP/del.json" "$TMP/del.err")"
  CREATED_SITE=""
  ok "the site is gone, and the verb that removed it was findable in -h"
  return 0
}

# ---- Entry ------------------------------------------------------------------

usage() {
  sed -n '5,40p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --self-check) MODE="self-check" ;;
    --discover | --preflight) MODE="discover" ;;
    --slug) SLUG="${2:-}"; shift ;;
    --instance) INSTANCE="${2:-}"; shift ;;
    --dataset) DATASET="${2:-}"; shift ;;
    --doc-type) DOC_TYPE="${2:-}"; shift ;;
    --keep) KEEP=1 ;;
    -h | --help) usage ;;
    *) say "unknown argument: $1"; usage ;;
  esac
  shift
done

case "$MODE" in
  self-check) self_check ;;
  discover)
    discover
    say ""
    printf '%s✓ DISCOVER PASSED%s — every input the create call needs is reachable. Nothing was mutated.\n' "$GRN$BLD" "$OFF" >&2
    ;;
  full) walk ;;
esac
