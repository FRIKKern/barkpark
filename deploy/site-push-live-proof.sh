#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# site-push-live-proof.sh — THE FRESH-BOX PUSH-TO-LIVE ACCEPTANCE RUN.
# [task jpf-bl-e2e-push-proof; epic jarl-platform-followups; wave paper
#  jarl-platform-followups-wave-2026-07-31]
#
# One question, answered end to end with no human hands in the middle:
#
#     If I launch a brand-new box, connect a public repo to a site on it, and
#     `git push` a commit — does that exact sha end up LIVE, with ZERO manual
#     steps? And if nothing claims the work, does the watchdog SAY SO?
#
# It is assembled from two proven halves, deliberately and with no third
# invention:
#   * the CP-side provision/teardown front half of
#     `scripts/pdf-mvp0-journey-proof.sh` — a REAL Hetzner box, minutes of real
#     money, torn down by its own trap, and the --plan / --negctl /
#     --scan-transcript mode trio;
#   * the typed-exit-code `judge_*` dialect and `--self-check` of the
#     site-spawner proofs (`deploy/site-spawner-live-proof.sh`) — every
#     assertion is a PURE function over already-fetched values that RETURNS its
#     typed failure code, so each one can be fed synthetic good AND bad input
#     offline and the exact red asserted.
#
# It does NOT extend `deploy/site-spawner-live-proof.sh`. That script (and its
# node/autorebuild siblings) starts from a box that ALREADY EXISTS and a site
# that is ALREADY CREATED; none of them provisions, none of them pushes, and
# none of them can delete the box at the end — which is the leak that makes
# them unusable as the definition-of-done run for this epic. `deploy/
# instance-deploy_test.sh` is a different plane again (offline CP blue/green).
#
# ── MODES ────────────────────────────────────────────────────────────────────
#   bash deploy/site-push-live-proof.sh --plan
#       Print every rung, its assertion, its typed red and the timeout law.
#       NO side effects: no network, no mktemp, no config reads. Always exit 0.
#
#   bash deploy/site-push-live-proof.sh --self-check
#       OFFLINE. Drive every judge_* with good AND bad input and assert the
#       exact typed red fires (and that a good input PASSES). Plus the
#       structural walls: every typed code has a codename, every rung named in
#       --plan has at least one judge, and every judge has a negative control.
#       No network, no credentials, sub-second. Exit 0 = all reds fire.
#
#   bash deploy/site-push-live-proof.sh --negctl
#       OFFLINE, fixture-driven. Writes deliberately WRONG transcripts and
#       status payloads to a tmpdir and runs them through the REAL parsing path
#       into the REAL judges, asserting WHICH arm fired — not merely that
#       something exited non-zero. Includes the watchdog rung as a
#       fixture-judged rung. No box, no spend. Exit 0 = every control fired.
#
#   bash deploy/site-push-live-proof.sh --scan-transcript <file>
#       Pre-commit token scan of a live transcript: the cloud session token, any
#       agent token, any hcloud token, any GitHub PAT/app token, any webhook
#       HMAC secret. ZERO hits or no commit.
#
#   bash deploy/site-push-live-proof.sh            # THE LIVE PROOF (see below)
#
# ── RUNNING THE LIVE PROOF (c1 + c2 of the task row) ─────────────────────────
# The live run provisions a real Hetzner server and spends real money for a few
# minutes. It needs credentials that are NOT present in CI and NOT present in
# a normal dev shell. A person who HAS them runs it unchanged:
#
#   export HCLOUD_TOKEN=<hetzner project token with server create+delete>
#   #   …or, equivalently, an `hcloud context` already selected. This is the
#   #   PROVISIONING + TEARDOWN credential. R0 refuses to create anything it
#   #   cannot prove it can destroy (the pdf-mvp0 money-safety gate, inherited).
#   bp login                        # writes .cloud_token into $BARKPARK_CONFIG
#   export PUSH_REPO=<owner/name>   # a PUBLIC github repo you can push to
#   export PUSH_REPO_TOKEN=<a PAT with contents:write on PUSH_REPO>
#   export GITHUB_WEBHOOK_SECRET=<the site's webhook secret, if pre-seeded>
#
#   bash deploy/site-push-live-proof.sh 2>&1 | tee /tmp/push-live.transcript
#   bash deploy/site-push-live-proof.sh --scan-transcript /tmp/push-live.transcript
#
# Everything else has a default that --plan prints. Every name the run creates
# is prefixed `pushproof-` so the teardown census can recognise its own litter
# and NOTHING else.
#
# WHY THIS IS NOT IN CI. There is no provisioning Hetzner secret in any
# workflow in this repo (the only Hetzner secret is `HETZNER_DNS_TOKEN` in
# .github/workflows/renew-mail-cert.yml, a DNS/cert token that cannot create a
# server). Only the OFFLINE modes are registered in
# .github/workflows/deploy-harnesses.yml, exactly as the site-spawner siblings'
# --self-check arms are. The live run is a human-operated acceptance run.
#
# ── THE THREE OUTCOMES (the pds ladder, verbatim — no fourth, no silent skip) ─
#   PASS   the rung ran and every assertion held.
#   ABORT  the rung cannot run (missing credential, route shape, capacity) — a
#          substrate problem, never a verdict on the thing under test.
#   FAIL   the rung ran and an assertion did NOT hold: a NAMED, TYPED red.
#
# ── TYPED EXIT CODES (the named reds) ────────────────────────────────────────
#    0 PROVEN
#    2 USAGE
#   30 PREFLIGHT_NO_BP              — the bp binary or the `cloud` verb is absent
#   31 PREFLIGHT_NO_CLOUD_SESSION   — no cloud session token (`bp login`)
#   32 PREFLIGHT_NO_PROVISION_CRED  — no HCLOUD_TOKEN / hcloud context: cannot launch
#   33 PREFLIGHT_NO_TEARDOWN_REACH  — the credential cannot SEE the project it would
#                                     delete from. NEVER create a box you cannot destroy.
#   34 PREFLIGHT_NO_PUSH_REPO       — no repo we can actually push a known sha to
#   40 LAUNCH_FAILED                — `bp launch hetzner` never produced a box
#   41 LAUNCH_NOT_HEALTHY           — the box exists but never reached health
#   50 CONNECT_FAILED               — `bp sites github connect` did not bind the repo
#   51 CONNECT_NO_WEBHOOK           — connected with no delivery hook: a push can never arrive
#   60 PUSH_FAILED                  — the git push did not land on the remote
#   61 PUSH_SHA_MISMATCH            — the remote head is not the sha we pushed
#   70 WEBHOOK_NOT_ACCEPTED         — POST /v1/webhooks/github/:site_id did not 201
#   71 WEBHOOK_NO_QUEUED_ROW        — accepted, but no queued deployment row exists
#   72 WEBHOOK_WRONG_SHA            — a queued row for a DIFFERENT git_ref (vacuous green)
#   80 CLAIM_NEVER_HAPPENED         — the box's own builder never claimed it
#   81 CLAIM_WRONG_SOURCE           — claimed, but the clone lane points at the wrong ref
#   82 CLAIM_EPOCH_NOT_FENCED       — claimed with no worker/epoch fence (two builders can race)
#   90 BUILD_FAILED                 — the deployment did not reach live
#   91 BUILD_STAGES_INCOMPLETE      — the six stages did not all land, in order
#  100 LIVE_NOT_200                 — the site host does not serve
#  101 LIVE_SHA_MISMATCH            — served commit marker != the sha we pushed (THE CORE RED)
#  102 LIVE_CONTENT_EMPTY           — 200 with empty build/commit markers: a vacuous green page
#  105 MANUAL_STEP_REQUIRED         — the run had to touch the box by hand: not zero-step
#  110 WATCHDOG_NOT_STALLED         — a queued row past the 300 s horizon that NOTHING claimed
#                                     did not surface as deploy_stalled
#  111 WATCHDOG_WRONG_BUCKET        — named deploy_stalled but filed outside `attention`
#  112 WATCHDOG_AGE_MISSING         — queued_deploy_age_seconds absent: the signal is blind
#  115 TEARDOWN_BOX_SURVIVED        — the box is still there (BILLING)
#  116 TEARDOWN_ROWS_SURVIVED       — site / deployment rows survived the teardown
#  120 SELF_CHECK_FAILED            — a named red did NOT fire on input that must trigger it
#  121 NEGCTL_FAILED                — a fixture that must be judged red was judged green
#  122 NEGCTL_NO_PYTHON3            — the fixture parser is unavailable: NAMED, never a skip
#  123 SCAN_TOKEN_LEAK              — the transcript carries a secret; do not commit it
#
# GATE: bash -n deploy/site-push-live-proof.sh
#       $ shellcheck deploy/site-push-live-proof.sh   (the $ keeps this line from parsing as a directive)
#       bash deploy/site-push-live-proof.sh --self-check
#       bash deploy/site-push-live-proof.sh --plan
#       bash deploy/site-push-live-proof.sh --negctl
set -uo pipefail

SELF="$(basename "$0")"

# ---- Typed exit codes --------------------------------------------------------

E_USAGE=2
E_PF_NO_BP=30
E_PF_NO_SESSION=31
E_PF_NO_PROV=32
E_PF_NO_TEARDOWN=33
E_PF_NO_REPO=34
E_LAUNCH_FAILED=40
E_LAUNCH_UNHEALTHY=41
E_CONNECT_FAILED=50
E_CONNECT_NO_HOOK=51
E_PUSH_FAILED=60
E_PUSH_SHA=61
E_WH_NOT_ACCEPTED=70
E_WH_NO_ROW=71
E_WH_WRONG_SHA=72
E_CLAIM_NONE=80
E_CLAIM_SOURCE=81
E_CLAIM_EPOCH=82
E_BUILD_FAILED=90
E_BUILD_STAGES=91
E_LIVE_NOT_200=100
E_LIVE_SHA=101
E_LIVE_EMPTY=102
E_MANUAL_STEP=105
E_WD_NOT_STALLED=110
E_WD_WRONG_BUCKET=111
E_WD_AGE_MISSING=112
E_TD_BOX=115
E_TD_ROWS=116
E_SELF_CHECK=120
E_NEGCTL=121
E_NEGCTL_NO_PY=122
E_SCAN_LEAK=123

codename() {
  case "$1" in
    0)   printf 'PROVEN' ;;
    2)   printf 'USAGE' ;;
    30)  printf 'PREFLIGHT_NO_BP' ;;
    31)  printf 'PREFLIGHT_NO_CLOUD_SESSION' ;;
    32)  printf 'PREFLIGHT_NO_PROVISION_CRED' ;;
    33)  printf 'PREFLIGHT_NO_TEARDOWN_REACH' ;;
    34)  printf 'PREFLIGHT_NO_PUSH_REPO' ;;
    40)  printf 'LAUNCH_FAILED' ;;
    41)  printf 'LAUNCH_NOT_HEALTHY' ;;
    50)  printf 'CONNECT_FAILED' ;;
    51)  printf 'CONNECT_NO_WEBHOOK' ;;
    60)  printf 'PUSH_FAILED' ;;
    61)  printf 'PUSH_SHA_MISMATCH' ;;
    70)  printf 'WEBHOOK_NOT_ACCEPTED' ;;
    71)  printf 'WEBHOOK_NO_QUEUED_ROW' ;;
    72)  printf 'WEBHOOK_WRONG_SHA' ;;
    80)  printf 'CLAIM_NEVER_HAPPENED' ;;
    81)  printf 'CLAIM_WRONG_SOURCE' ;;
    82)  printf 'CLAIM_EPOCH_NOT_FENCED' ;;
    90)  printf 'BUILD_FAILED' ;;
    91)  printf 'BUILD_STAGES_INCOMPLETE' ;;
    100) printf 'LIVE_NOT_200' ;;
    101) printf 'LIVE_SHA_MISMATCH' ;;
    102) printf 'LIVE_CONTENT_EMPTY' ;;
    105) printf 'MANUAL_STEP_REQUIRED' ;;
    110) printf 'WATCHDOG_NOT_STALLED' ;;
    111) printf 'WATCHDOG_WRONG_BUCKET' ;;
    112) printf 'WATCHDOG_AGE_MISSING' ;;
    115) printf 'TEARDOWN_BOX_SURVIVED' ;;
    116) printf 'TEARDOWN_ROWS_SURVIVED' ;;
    120) printf 'SELF_CHECK_FAILED' ;;
    121) printf 'NEGCTL_FAILED' ;;
    122) printf 'NEGCTL_NO_PYTHON3' ;;
    123) printf 'SCAN_TOKEN_LEAK' ;;
    *)   printf 'UNKNOWN(%s)' "$1" ;;
  esac
}

# The full typed set, for the structural wall in --self-check. Every entry here
# MUST have a codename and every judge MUST be able to return one of them.
ALL_CODES="0 2 30 31 32 33 34 40 41 50 51 60 61 70 71 72 80 81 82 90 91 100 101 102 105 110 111 112 115 116 120 121 122 123"

# ---- Config (every default is printed by --plan) ------------------------------

# The 5-minute watchdog horizon. This number is not invented here: it is
# `queuedDeployStalledAfterSeconds = 300` in internal/cli/cloud_status_cmd.go,
# twinned server-side by `@default_queued_deploy_alarm_after_seconds 5 * 60` in
# cloud/lib/barkpark_cloud/registry.ex. The rung asserts the SIGNAL, so the
# number must match the implementation; if the implementation moves, this moves.
STALL_HORIZON_S="${STALL_HORIZON_S:-300}"

# How long past the horizon the watchdog rung keeps sampling before it calls the
# signal missing. The row must READ deploy_stalled, not merely become eligible.
STALL_GRACE_S="${STALL_GRACE_S:-120}"

CP_BASE="${CP_BASE:-https://barkpark.cloud}"
PUSH_REPO="${PUSH_REPO:-}"
PUSH_BRANCH="${PUSH_BRANCH:-main}"
BP="${BP:-bp}"
CFG="${BARKPARK_CONFIG:-$HOME/.config/barkpark/config.json}"
KEEP="${KEEP:-0}"
TS="$(date +%s 2>/dev/null || echo 0)"
NAME_PREFIX="pushproof-"
BOX_NAME="${BOX_NAME:-${NAME_PREFIX}${TS}}"
SITE_SLUG="${SITE_SLUG:-${NAME_PREFIX}site-${TS}}"

LAUNCH_TIMEOUT_S="${LAUNCH_TIMEOUT_S:-900}"
DEPLOY_TIMEOUT_S="${DEPLOY_TIMEOUT_S:-900}"
POLL_EVERY_S="${POLL_EVERY_S:-10}"

# The canonical stage order. internal/cloudclient/client.go: SpawnSiteStages.
WANT_STAGES="PLAN BUILD STAGE HEALTH SWITCH RETIRE"

# ---- Output ------------------------------------------------------------------

if [ -t 2 ]; then BLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
else BLD=""; DIM=""; RED=""; GRN=""; OFF=""; fi

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
step() { printf '\n%s▸ %s%s\n' "$BLD" "$*" "$OFF" >&2; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$OFF" "$*" >&2; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$OFF" >&2; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit "$E_USAGE"; }

N_PASS=0; N_ABORT=0; N_FAIL=0
pass()  { N_PASS=$((N_PASS + 1));  printf '  PASS   %-3s %s\n' "$1" "$2"; }
abort() { N_ABORT=$((N_ABORT + 1)); printf '  ABORT  %-3s %s\n' "$1" "$2"; printf '         %s\n' "$3"; }

# fail prints the NAMED red and exits with its typed code. `why` is concrete:
# what was expected, what was actually observed — never a generic shrug.
fail() {
  local code="$1" why="$2" fixhint="${3:-}"
  N_FAIL=$((N_FAIL + 1))
  printf '\n%s✗ %s%s  %s(exit %s)%s\n' "$RED$BLD" "$(codename "$code")" "$OFF" "$DIM" "$code" "$OFF" >&2
  printf '  %s\n' "$why" >&2
  [ -n "$fixhint" ] && printf '  %s→ %s%s\n' "$DIM" "$fixhint" "$OFF" >&2
  cleanup
  exit "$code"
}

# ---- THE JUDGES ---------------------------------------------------------------
#
# Every one is a PURE function over already-fetched values. It RETURNS a typed
# code and touches nothing. That is what makes --self-check and --negctl able to
# reach it offline; a proof whose failure paths were never executed is itself a
# vacuous green.

# judge_preflight <bp_ok> <session_token> <prov_cred> <teardown_sees_project> <push_repo>
# Order matters: the money-safety gate (teardown reach) is asserted BEFORE the
# run is allowed to create anything. NEVER create a box you cannot destroy.
judge_preflight() {
  local bp_ok="$1" session="$2" prov="$3" teardown="$4" repo="$5"
  [ "$bp_ok" = "true" ] || return "$E_PF_NO_BP"
  [ -n "$session" ]     || return "$E_PF_NO_SESSION"
  [ -n "$prov" ]        || return "$E_PF_NO_PROV"
  [ "$teardown" = "true" ] || return "$E_PF_NO_TEARDOWN"
  [ -n "$repo" ]        || return "$E_PF_NO_REPO"
  return 0
}

# judge_launch <box_id> <status> <host> <health>
judge_launch() {
  local id="$1" status="$2" host="$3" health="$4"
  [ -n "$id" ] || return "$E_LAUNCH_FAILED"
  [ "$status" = "live" ] || return "$E_LAUNCH_FAILED"
  [ -n "$host" ] || return "$E_LAUNCH_UNHEALTHY"
  [ "$health" = "up" ] || return "$E_LAUNCH_UNHEALTHY"
  return 0
}

# judge_connect <site_id> <connected_repo> <expected_repo> <branch> <expected_branch> <hook_id>
# A connect that bound the WRONG repo is worse than one that failed: the push
# would then never arrive and the run would blame the webhook.
judge_connect() {
  local site="$1" got_repo="$2" want_repo="$3" got_br="$4" want_br="$5" hook="$6"
  [ -n "$site" ] || return "$E_CONNECT_FAILED"
  [ -n "$got_repo" ] && [ "$got_repo" = "$want_repo" ] || return "$E_CONNECT_FAILED"
  [ -n "$got_br" ] && [ "$got_br" = "$want_br" ] || return "$E_CONNECT_FAILED"
  [ -n "$hook" ] || return "$E_CONNECT_NO_HOOK"
  return 0
}

# judge_push <push_rc> <remote_head_sha> <pushed_sha>
judge_push() {
  local rc="$1" remote="$2" pushed="$3"
  [ "$rc" = "0" ] || return "$E_PUSH_FAILED"
  [ -n "$pushed" ] || return "$E_PUSH_FAILED"
  [ -n "$remote" ] || return "$E_PUSH_FAILED"
  [ "$remote" = "$pushed" ] || return "$E_PUSH_SHA"
  return 0
}

# judge_webhook <http_code> <deployment_id> <row_status> <row_git_ref> <pushed_sha>
# router.ex handle_production_push/5 answers 201 with {deployment_id, sha,
# status}. A 200 is NOT the contract and a row for another sha is a vacuous
# green — the queue is shared, so "a queued row exists" proves nothing on its
# own.
judge_webhook() {
  local code="$1" dep="$2" status="$3" ref="$4" pushed="$5"
  [ "$code" = "201" ] || return "$E_WH_NOT_ACCEPTED"
  [ -n "$dep" ] || return "$E_WH_NO_ROW"
  [ "$status" = "queued" ] || return "$E_WH_NO_ROW"
  [ -n "$ref" ] && [ -n "$pushed" ] || return "$E_WH_WRONG_SHA"
  [ "$ref" = "$pushed" ] || return "$E_WH_WRONG_SHA"
  return 0
}

# judge_claim <claim_worker> <claim_epoch> <source_kind> <source_ref> <pushed_sha> <expected_worker_prefix>
# The claim must come from THE BOX WE JUST LAUNCHED (claim_worker carries the
# box's own agent identity), must be fenced (claim_epoch > 0), and must point
# the clone lane at the sha we pushed. A claim by some other builder in the
# fleet would still move the row to `building` and would prove nothing about
# this box.
judge_claim() {
  local worker="$1" epoch="$2" kind="$3" ref="$4" pushed="$5" want_prefix="$6"
  [ -n "$worker" ] || return "$E_CLAIM_NONE"
  case "$worker" in
    "$want_prefix"*) : ;;
    *) return "$E_CLAIM_NONE" ;;
  esac
  case "$epoch" in
    ''|*[!0-9]*) return "$E_CLAIM_EPOCH" ;;
  esac
  [ "$epoch" -gt 0 ] || return "$E_CLAIM_EPOCH"
  [ "$kind" = "git" ] || return "$E_CLAIM_SOURCE"
  [ -n "$ref" ] && [ "$ref" = "$pushed" ] || return "$E_CLAIM_SOURCE"
  return 0
}

# judge_stages <status> <stage-names-in-observed-order…>
# All six, in the canonical order. A deploy that reached live having reported
# three of them is not a proof of a six-stage engine.
judge_stages() {
  local status="$1"; shift
  local got="$*"
  [ "$got" = "$WANT_STAGES" ] || return "$E_BUILD_STAGES"
  [ "$status" = "live" ] || return "$E_BUILD_FAILED"
  return 0
}

# judge_live <http_code> <served_commit> <pushed_sha> <served_build_id> <expected_build_id>
# Assert by VALUE. A cheerful 200 from a box that built the PREVIOUS commit is
# the exact failure this whole script exists to catch.
judge_live() {
  local code="$1" served="$2" pushed="$3" bid="$4" want_bid="$5"
  [ "$code" = "200" ] || return "$E_LIVE_NOT_200"
  [ -n "$served" ] && [ -n "$bid" ] || return "$E_LIVE_EMPTY"
  [ -n "$pushed" ] || return "$E_LIVE_SHA"
  [ "$served" = "$pushed" ] || return "$E_LIVE_SHA"
  [ -n "$want_bid" ] && [ "$bid" = "$want_bid" ] || return "$E_LIVE_EMPTY"
  return 0
}

# judge_zero_manual <manual_step_count>
# The run counts every place it had to reach for the box itself (an ssh, an
# on-box systemctl, a hand-run build). The contract is ZERO.
judge_zero_manual() {
  case "$1" in
    ''|*[!0-9]*) return "$E_MANUAL_STEP" ;;
  esac
  [ "$1" -eq 0 ] || return "$E_MANUAL_STEP"
  return 0
}

# judge_watchdog <age_seconds_or_empty> <horizon_s> <attention_status> <bucket>
# The watchdog rung's whole point. An UNCLAIMABLE queued row older than the
# horizon must surface as deploy_stalled, in the attention bucket.
#
# The empty-age arm is not a formality: `queued_deploy_age_seconds` is
# TRI-STATE in cloud_status_cmd.go — present, zero, or ABSENT — and an absent
# key classifies as `degraded`, not `deploy_stalled`. A blind signal reads as
# "nothing wrong", which is the worst possible reading of a stalled queue.
judge_watchdog() {
  local age="$1" horizon="$2" status="$3" bucket="$4"
  [ -n "$age" ] || return "$E_WD_AGE_MISSING"
  case "$age" in
    *[!0-9]*) return "$E_WD_AGE_MISSING" ;;
  esac
  case "$horizon" in
    ''|*[!0-9]*) return "$E_WD_AGE_MISSING" ;;
  esac
  [ "$age" -ge "$horizon" ] || return "$E_WD_NOT_STALLED"
  [ "$status" = "deploy_stalled" ] || return "$E_WD_NOT_STALLED"
  [ "$bucket" = "attention" ] || return "$E_WD_WRONG_BUCKET"
  return 0
}

# judge_teardown <boxes_left> <site_rows_left> <deployment_rows_left>
# Census delta zero. "boxes_left" is the provider label scan for OUR prefix:
# anything non-empty is a billing leak.
judge_teardown() {
  local boxes="$1" sites="$2" deps="$3"
  [ -z "$boxes" ] || [ "$boxes" = "none" ] || return "$E_TD_BOX"
  { [ -z "$sites" ] || [ "$sites" = "none" ]; } || return "$E_TD_ROWS"
  { [ -z "$deps" ] || [ "$deps" = "none" ]; } || return "$E_TD_ROWS"
  return 0
}

# ---- The parsing path (shared by the live run AND the fixtures) ---------------
#
# --negctl drives its fixtures through THESE, not straight into the judges, so a
# control exercises the same extraction the live run uses. A judge that can only
# be reached by hand-passed arguments proves the judge, not the rung.

# stages_from_transcript <file> — the observed stage order, space separated.
# The on-box emitter protocol is deploy/site-deploy.sh's
#   BPSTAGE name=<NAME> status=<started|ok|skipped|noop|failed> build_id=<id> …
# Only a status that actually LANDED counts: `started` alone is a stage that
# began and may never have finished, and counting it would let a deploy that
# died mid-HEALTH read as six-for-six.
stages_from_transcript() {
  local f="$1" line name status out=""
  while IFS= read -r line; do
    case "$line" in
      *BPSTAGE*) ;;
      *) continue ;;
    esac
    name=""; status=""
    for tok in $line; do
      case "$tok" in
        name=*)   name="${tok#name=}" ;;
        status=*) status="${tok#status=}" ;;
      esac
    done
    case "$status" in
      ok|skipped|noop) ;;
      *) continue ;;
    esac
    [ -n "$name" ] || continue
    if [ -z "$out" ]; then out="$name"; else out="$out $name"; fi
  done < "$f"
  printf '%s' "$out"
}

# status_from_transcript <file> — the deployment's terminal status line
#   BPDEPLOY status=<queued|building|pushing|live|failed>
status_from_transcript() {
  local f="$1" line out=""
  while IFS= read -r line; do
    case "$line" in
      *BPDEPLOY*) ;;
      *) continue ;;
    esac
    for tok in $line; do
      case "$tok" in status=*) out="${tok#status=}" ;; esac
    done
  done < "$f"
  printf '%s' "$out"
}

# manual_steps_from_transcript <file> — count the NAMED escapes. The live run
# emits `BPMANUAL reason=…` at any point it reaches for the box by hand. Zero
# lines is the contract; the marker exists so that a hand-step cannot be
# invisible.
# NOTE - and the reason --self-check's PARSER wall counts this one too: the
# obvious spelling `grep -c ... || printf '0'` is WRONG. grep -c PRINTS "0" and
# THEN exits 1 on no-match, so the `||` arm appends a second zero and the caller
# receives a two-line "0". judge_zero_manual reads that as non-numeric and reds
# a perfectly clean run as MANUAL_STEP_REQUIRED. --negctl caught exactly that on
# its first execution, which is the whole argument for having it.
manual_steps_from_transcript() {
  local n
  n="$(grep -c 'BPMANUAL' "$1" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# jget <file> <dotted.path> — a value out of a JSON file, or "".
HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1
jget() {
  [ "$HAVE_PY" = 1 ] || { printf ''; return 0; }
  python3 - "$1" "$2" <<'PY' 2>/dev/null || printf ''
import json, sys
try:
    with open(sys.argv[1]) as fh:
        cur = json.load(fh)
except Exception:
    print(""); raise SystemExit(0)
for part in sys.argv[2].split("."):
    if part == "":
        continue
    if isinstance(cur, list):
        try:
            cur = cur[int(part)]
            continue
        except Exception:
            print(""); raise SystemExit(0)
    if not isinstance(cur, dict) or part not in cur:
        print(""); raise SystemExit(0)
    cur = cur[part]
if cur is None or isinstance(cur, (dict, list)):
    print("" if cur is None else json.dumps(cur))
else:
    print(cur if not isinstance(cur, bool) else ("true" if cur else "false"))
PY
}

# row_from_status <status-json-file> <box-name> <key> — one field of one row in
# a `bp cloud status -o json` payload ({..., barkparks:[{name,status,bucket,
# queued_deploy_age_seconds,...}]}). Prints "" when the key is ABSENT, which is
# exactly the tri-state the watchdog judge has to be able to see.
row_from_status() {
  [ "$HAVE_PY" = 1 ] || { printf ''; return 0; }
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || printf ''
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception:
    print(""); raise SystemExit(0)
rows = (doc or {}).get("barkparks") or []
for r in rows:
    if (r.get("name") or "") == sys.argv[2]:
        v = r.get(sys.argv[3])
        print("" if v is None else (v if not isinstance(v, bool) else ("true" if v else "false")))
        raise SystemExit(0)
print("")
PY
}

# ---- Cleanup / trap ----------------------------------------------------------

WORKDIR=""
BOX_ID=""
SITE_ID=""
CLEANUP_DONE=0

cleanup() {
  [ "$CLEANUP_DONE" = 1 ] && return 0
  CLEANUP_DONE=1
  [ "${MODE:-}" = "plan" ] && return 0
  [ "${MODE:-}" = "self-check" ] && return 0
  [ "${MODE:-}" = "scan" ] && return 0
  if [ "$KEEP" = "1" ]; then
    [ -n "$BOX_ID" ] && say "KEEP=1 — box $BOX_NAME ($BOX_ID) LEFT RUNNING. It is BILLING. Destroy it yourself."
    return 0
  fi
  # Site row first, then the box: a deleted box with a live site row leaves the
  # control plane pointing at nothing.
  if [ -n "$SITE_ID" ]; then
    say "      trap: deleting site $SITE_ID"
    "$BP" cloud site delete "$SITE_ID" --yes >/dev/null 2>&1 || true
  fi
  if [ -n "$BOX_ID" ]; then
    say "      trap: destroying box $BOX_NAME ($BOX_ID)"
    "$BP" cloud instance delete "$BOX_ID" --yes >/dev/null 2>&1 || true
    command -v hcloud >/dev/null 2>&1 && hcloud server delete "$BOX_NAME" >/dev/null 2>&1 || true
  fi
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}

# ---- Mode dispatch -----------------------------------------------------------

MODE="run"
SCAN_TARGET=""
case "${1:-}" in
  "")                MODE="run" ;;
  --plan)            MODE="plan" ;;
  --self-check)      MODE="self-check" ;;
  --negctl)          MODE="negctl" ;;
  --scan-transcript) MODE="scan"; SCAN_TARGET="${2:-}" ;;
  --keep)            MODE="run"; KEEP=1 ;;
  -h|--help)         MODE="help" ;;
  *)                 die "unknown argument: $1 (try --help)" ;;
esac

usage() {
  say "$SELF — the fresh-box push-to-live acceptance run."
  say ""
  say "  $0                        the LIVE proof (real Hetzner box, real money, torn down)"
  say "  $0 --plan                 every rung + its typed red; no side effects; exit 0"
  say "  $0 --self-check           offline; every judge fed good AND bad input"
  say "  $0 --negctl               offline, fixture-driven; every control must FIRE"
  say "  $0 --scan-transcript <f>  pre-commit secret scan of a live transcript"
  say "  $0 --keep                 the live proof, but leave the box running (IT BILLS)"
  say ""
  say "The live run needs, in the shell: HCLOUD_TOKEN (or a selected hcloud"
  say "context), a bp cloud session (bp login), PUSH_REPO=<owner/name> and"
  say "PUSH_REPO_TOKEN. --plan prints every other default."
}

if [ "$MODE" = "help" ]; then usage; exit 0; fi

# ---- --plan ------------------------------------------------------------------
# Provably side-effect free: no mktemp, no network, no config read. It prints.

if [ "$MODE" = "plan" ]; then
  rule
  say "PLAN — $SELF (no side effects; nothing is created, nothing is read)"
  rule
  say ""
  say "RUNG 0  PRECONDITION                                    [ABORT-only]"
  say "        bp on PATH with the 'cloud' verb                -> PREFLIGHT_NO_BP ($E_PF_NO_BP)"
  say "        a cloud session token in \$BARKPARK_CONFIG       -> PREFLIGHT_NO_CLOUD_SESSION ($E_PF_NO_SESSION)"
  say "        HCLOUD_TOKEN or a selected hcloud context       -> PREFLIGHT_NO_PROVISION_CRED ($E_PF_NO_PROV)"
  say "        THE MONEY-SAFETY GATE: that credential can SEE"
  say "        the project it would delete from                -> PREFLIGHT_NO_TEARDOWN_REACH ($E_PF_NO_TEARDOWN)"
  say "        PUSH_REPO is set and pushable                   -> PREFLIGHT_NO_PUSH_REPO ($E_PF_NO_REPO)"
  say "        judge: judge_preflight"
  say ""
  say "RUNG 1  LAUNCH A FRESH BOX                              [timeout ${LAUNCH_TIMEOUT_S}s, poll ${POLL_EVERY_S}s]"
  say "        \$ bp launch hetzner --name $BOX_NAME"
  say "        assert: a box id, status=live, a host, health=up"
  say "        reds: LAUNCH_FAILED ($E_LAUNCH_FAILED) · LAUNCH_NOT_HEALTHY ($E_LAUNCH_UNHEALTHY)"
  say "        judge: judge_launch"
  say ""
  say "RUNG 2  CONNECT THE REPO                                [\$ bp sites github connect]"
  say "        \$ bp sites github connect <site> --repo \$PUSH_REPO --branch \$PUSH_BRANCH"
  say "        assert: the site binds THAT repo + THAT branch, and a delivery hook exists"
  say "        reds: CONNECT_FAILED ($E_CONNECT_FAILED) · CONNECT_NO_WEBHOOK ($E_CONNECT_NO_HOOK)"
  say "        judge: judge_connect"
  say ""
  say "RUNG 3  PUSH A KNOWN SHA                                [a real git push]"
  say "        assert: the remote head IS the sha we pushed (not merely rc=0)"
  say "        reds: PUSH_FAILED ($E_PUSH_FAILED) · PUSH_SHA_MISMATCH ($E_PUSH_SHA)"
  say "        judge: judge_push"
  say ""
  say "RUNG 4  THE WEBHOOK MINTS A QUEUED ROW                  [POST /v1/webhooks/github/:site_id]"
  say "        assert: 201, a deployment id, status=queued, git_ref == the pushed sha"
  say "        reds: WEBHOOK_NOT_ACCEPTED ($E_WH_NOT_ACCEPTED) · WEBHOOK_NO_QUEUED_ROW ($E_WH_NO_ROW) · WEBHOOK_WRONG_SHA ($E_WH_WRONG_SHA)"
  say "        judge: judge_webhook"
  say ""
  say "RUNG 5  THE BOX'S OWN BUILDER CLAIMS IT                 [POST /v1/builder/claim, agent bearer]"
  say "        assert: claim_worker belongs to THE BOX WE LAUNCHED, claim_epoch > 0 (fenced),"
  say "                and the clone lane's source ref IS the pushed sha"
  say "        reds: CLAIM_NEVER_HAPPENED ($E_CLAIM_NONE) · CLAIM_WRONG_SOURCE ($E_CLAIM_SOURCE) · CLAIM_EPOCH_NOT_FENCED ($E_CLAIM_EPOCH)"
  say "        judge: judge_claim"
  say ""
  say "RUNG 6  CLONE LANE -> NIXPACKS -> SIX STAGES            [timeout ${DEPLOY_TIMEOUT_S}s, poll ${POLL_EVERY_S}s]"
  say "        assert: $WANT_STAGES — all six, in order, status=live"
  say "        reds: BUILD_FAILED ($E_BUILD_FAILED) · BUILD_STAGES_INCOMPLETE ($E_BUILD_STAGES)"
  say "        judge: judge_stages (fed by stages_from_transcript over the BPSTAGE lines)"
  say ""
  say "RUNG 7  LIVE AT THE SITE HOST, ZERO MANUAL STEPS"
  say "        assert: 200; the served commit marker == the sha we pushed; build id matches;"
  say "                and the run emitted ZERO BPMANUAL lines"
  say "        reds: LIVE_NOT_200 ($E_LIVE_NOT_200) · LIVE_SHA_MISMATCH ($E_LIVE_SHA) · LIVE_CONTENT_EMPTY ($E_LIVE_EMPTY) · MANUAL_STEP_REQUIRED ($E_MANUAL_STEP)"
  say "        judges: judge_live, judge_zero_manual"
  say ""
  say "RUNG 8  THE WATCHDOG RUNG                               [horizon ${STALL_HORIZON_S}s + ${STALL_GRACE_S}s grace]"
  say "        Mint a DELIBERATELY UNCLAIMABLE deployment (queued against a site"
  say "        whose builder cannot take it), let it age past the horizon, then read"
  say "        \$ bp cloud status -o json"
  say "        assert: queued_deploy_age_seconds is PRESENT (the signal is not blind),"
  say "                >= ${STALL_HORIZON_S}, the row's status is deploy_stalled and its bucket is attention"
  say "        reds: WATCHDOG_NOT_STALLED ($E_WD_NOT_STALLED) · WATCHDOG_WRONG_BUCKET ($E_WD_WRONG_BUCKET) · WATCHDOG_AGE_MISSING ($E_WD_AGE_MISSING)"
  say "        judge: judge_watchdog (fed by row_from_status over the status payload)"
  say ""
  say "RUNG 9  TEARDOWN — CENSUS DELTA ZERO"
  say "        delete the site row, destroy the box, then re-read three surfaces:"
  say "        the provider label scan for '${NAME_PREFIX}', the site rows, the deployment rows"
  say "        reds: TEARDOWN_BOX_SURVIVED ($E_TD_BOX) · TEARDOWN_ROWS_SURVIVED ($E_TD_ROWS)"
  say "        judge: judge_teardown   (also runs from the EXIT trap on any red above)"
  say ""
  rule
  say "THE LAW"
  say "  · Every rung that cannot run ABORTS by name. There is no silent skip."
  say "  · Every judge above has a negative control in --negctl that reaches it"
  say "    through the real parsing path and asserts WHICH arm fired."
  say "  · The watchdog horizon ${STALL_HORIZON_S}s is queuedDeployStalledAfterSeconds in"
  say "    internal/cli/cloud_status_cmd.go, twinned by"
  say "    @default_queued_deploy_alarm_after_seconds in cloud/.../registry.ex."
  say "  · KEEP=1 leaves the box running and SAYS SO. Default is destroy."
  rule
  say ""
  say "PLAN: 10 rungs, 10 judges, $(printf '%s' "$ALL_CODES" | wc -w | tr -d ' ') typed codes. No side effects taken."
  exit 0
fi

# ---- --scan-transcript -------------------------------------------------------

if [ "$MODE" = "scan" ]; then
  [ -n "$SCAN_TARGET" ] || die "--scan-transcript needs a file argument"
  [ -f "$SCAN_TARGET" ] || die "--scan-transcript: no such file: $SCAN_TARGET"
  step "SCAN — $SCAN_TARGET must carry ZERO secrets"
  HITS=0
  scan_for() {
    local label="$1" pattern="$2" n
    n="$(grep -cE "$pattern" "$SCAN_TARGET" 2>/dev/null || true)"
    [ -n "$n" ] || n=0
    if [ "$n" != "0" ]; then
      printf '  %s✗%s %-28s %s hit(s)\n' "$RED" "$OFF" "$label" "$n" >&2
      HITS=$((HITS + n))
    else
      ok "$(printf '%-28s' "$label") clean"
    fi
  }
  scan_for "hcloud token (64 hex)"   '[A-Za-z0-9]{64}'
  scan_for "github PAT"             'gh[pousr]_[A-Za-z0-9]{16,}'
  scan_for "bp cloud session token"  'cloud_token"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9._-]{16,}'
  scan_for "agent/bearer token"      '[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}'
  scan_for "webhook HMAC secret"     'x-hub-signature-256:[[:space:]]*sha256=[a-f0-9]{64}'
  scan_for "anthropic key"           'sk-ant-[A-Za-z0-9_-]{10,}'
  say ""
  if [ "$HITS" != "0" ]; then
    fail "$E_SCAN_LEAK" "the transcript carries $HITS candidate secret(s) — DO NOT COMMIT IT" \
      "redact the lines above, re-scan, and only then attach the transcript to the task row"
  fi
  say "SCAN: 6 patterns, 0 hits — the transcript is safe to attach."
  exit 0
fi

# ---- --self-check ------------------------------------------------------------

SC_FAILED=0
SC_CHECKS=0
expect_code() {
  local want="$1" desc="$2"; shift 2
  local got=0
  SC_CHECKS=$((SC_CHECKS + 1))
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
  SC_CHECKS=$((SC_CHECKS + 1))
  "$@" || got=$?
  if [ "$got" = 0 ]; then
    ok "$(printf '%-28s' "PASS") $desc"
  else
    printf '  %s✗%s %s: expected a PASS, got %s (%s)\n' "$RED" "$OFF" "$desc" "$got" "$(codename "$got")" >&2
    SC_FAILED=1
  fi
}

if [ "$MODE" = "self-check" ]; then
  step "SELF-CHECK — offline; every named red must fire on input that must trigger it"

  note "rung 0 — preflight (the money-safety gate is asserted BEFORE anything is created)"
  expect_pass "everything present"                              judge_preflight true tok-1 hc-1 true owner/repo
  expect_code "$E_PF_NO_BP"       "no bp binary"                judge_preflight false tok-1 hc-1 true owner/repo
  expect_code "$E_PF_NO_SESSION"  "no cloud session"            judge_preflight true "" hc-1 true owner/repo
  expect_code "$E_PF_NO_PROV"     "no provisioning credential"  judge_preflight true tok-1 "" true owner/repo
  expect_code "$E_PF_NO_TEARDOWN" "THE MONEY GATE: the credential cannot see the project it would delete from" \
    judge_preflight true tok-1 hc-1 false owner/repo
  expect_code "$E_PF_NO_REPO"     "no repo to push to"          judge_preflight true tok-1 hc-1 true ""

  note "rung 1 — launch"
  expect_pass "a live box with a host and health up"            judge_launch box-1 live h.example up
  expect_code "$E_LAUNCH_FAILED"    "no box id came back"       judge_launch "" live h.example up
  expect_code "$E_LAUNCH_FAILED"    "still provisioning"        judge_launch box-1 provisioning h.example up
  expect_code "$E_LAUNCH_UNHEALTHY" "live with no host"         judge_launch box-1 live "" up
  expect_code "$E_LAUNCH_UNHEALTHY" "live, hosted, never healthy" judge_launch box-1 live h.example down

  note "rung 2 — connect"
  expect_pass "bound the right repo+branch with a hook"         judge_connect site-1 o/r o/r main main hook-1
  expect_code "$E_CONNECT_FAILED"  "no site"                    judge_connect "" o/r o/r main main hook-1
  expect_code "$E_CONNECT_FAILED"  "bound a DIFFERENT repo (the push would never arrive)" \
    judge_connect site-1 someone/else o/r main main hook-1
  expect_code "$E_CONNECT_FAILED"  "bound the wrong branch"     judge_connect site-1 o/r o/r dev main hook-1
  expect_code "$E_CONNECT_NO_HOOK" "connected with no delivery hook" judge_connect site-1 o/r o/r main main ""

  note "rung 3 — push"
  expect_pass "remote head is the sha we pushed"                judge_push 0 deadbeef deadbeef
  expect_code "$E_PUSH_FAILED" "git push returned non-zero"     judge_push 1 deadbeef deadbeef
  expect_code "$E_PUSH_FAILED" "nothing to compare (no remote head)" judge_push 0 "" deadbeef
  expect_code "$E_PUSH_SHA"    "rc=0 but the remote head is someone else's commit" judge_push 0 cafebabe deadbeef

  note "rung 4 — the webhook mints a queued row"
  expect_pass "201, queued, our sha"                            judge_webhook 201 dep-1 queued deadbeef deadbeef
  expect_code "$E_WH_NOT_ACCEPTED" "the hook answered 200, not the contracted 201" judge_webhook 200 dep-1 queued deadbeef deadbeef
  expect_code "$E_WH_NOT_ACCEPTED" "the hook 404d (site not connected)" judge_webhook 404 "" "" "" deadbeef
  expect_code "$E_WH_NO_ROW"       "accepted with no deployment id" judge_webhook 201 "" queued deadbeef deadbeef
  expect_code "$E_WH_NO_ROW"       "a row, but already building (not ours to watch)" judge_webhook 201 dep-1 building deadbeef deadbeef
  expect_code "$E_WH_WRONG_SHA"    "VACUOUS GREEN: a queued row for a DIFFERENT sha" judge_webhook 201 dep-1 queued cafebabe deadbeef
  expect_code "$E_WH_WRONG_SHA"    "a queued row with no git_ref at all" judge_webhook 201 dep-1 queued "" deadbeef

  note "rung 5 — the box's own builder claims it"
  expect_pass "our box, fenced, cloning our sha"                judge_claim pushproof-1-builder 1 git deadbeef deadbeef pushproof-
  expect_code "$E_CLAIM_NONE"   "nothing ever claimed it"       judge_claim "" 1 git deadbeef deadbeef pushproof-
  expect_code "$E_CLAIM_NONE"   "SOMEONE ELSE'S builder took it — proves nothing about our box" \
    judge_claim other-fleet-builder 1 git deadbeef deadbeef pushproof-
  expect_code "$E_CLAIM_EPOCH"  "claimed with epoch 0 (unfenced: two builders can race)" \
    judge_claim pushproof-1-builder 0 git deadbeef deadbeef pushproof-
  expect_code "$E_CLAIM_EPOCH"  "claimed with a non-numeric epoch" judge_claim pushproof-1-builder nope git deadbeef deadbeef pushproof-
  expect_code "$E_CLAIM_SOURCE" "claimed, but the lane is an artifact upload, not a clone" \
    judge_claim pushproof-1-builder 1 artifact deadbeef deadbeef pushproof-
  expect_code "$E_CLAIM_SOURCE" "claimed, but the clone lane points at the WRONG ref" \
    judge_claim pushproof-1-builder 1 git cafebabe deadbeef pushproof-
  expect_code "$E_CLAIM_SOURCE" "claimed with no ref at all" judge_claim pushproof-1-builder 1 git "" deadbeef pushproof-

  note "rung 6 — six stages, in order"
  expect_pass "all six, in order, live"                         judge_stages live PLAN BUILD STAGE HEALTH SWITCH RETIRE
  expect_code "$E_BUILD_STAGES" "only three landed"             judge_stages live PLAN BUILD STAGE
  expect_code "$E_BUILD_STAGES" "six, but out of order"         judge_stages live PLAN BUILD HEALTH STAGE SWITCH RETIRE
  expect_code "$E_BUILD_STAGES" "seven (an extra stage nobody declared)" judge_stages live PLAN BUILD STAGE HEALTH SWITCH RETIRE EXTRA
  expect_code "$E_BUILD_FAILED" "all six, but never went live"  judge_stages failed PLAN BUILD STAGE HEALTH SWITCH RETIRE

  note "rung 7 — live at the site host, by VALUE"
  expect_pass "200, our commit, our build id"                   judge_live 200 deadbeef deadbeef b-1 b-1
  expect_code "$E_LIVE_NOT_200" "the site host 502s"            judge_live 502 deadbeef deadbeef b-1 b-1
  expect_code "$E_LIVE_EMPTY"   "200 with an empty commit marker" judge_live 200 "" deadbeef b-1 b-1
  expect_code "$E_LIVE_EMPTY"   "200 with an empty build id"    judge_live 200 deadbeef deadbeef "" b-1
  expect_code "$E_LIVE_SHA"     "THE CORE RED: a cheerful 200 serving the PREVIOUS commit" \
    judge_live 200 cafebabe deadbeef b-1 b-1
  expect_code "$E_LIVE_EMPTY"   "our commit, but a build id from another deployment" \
    judge_live 200 deadbeef deadbeef b-1 b-2

  note "rung 7b — zero manual steps"
  expect_pass "no hand-steps"                                   judge_zero_manual 0
  expect_code "$E_MANUAL_STEP" "one ssh into the box"           judge_zero_manual 1
  expect_code "$E_MANUAL_STEP" "an uncountable manual-step marker" judge_zero_manual ""

  note "rung 8 — THE WATCHDOG (horizon ${STALL_HORIZON_S}s)"
  expect_pass "aged past the horizon, named deploy_stalled, in attention" \
    judge_watchdog 301 "$STALL_HORIZON_S" deploy_stalled attention
  expect_code "$E_WD_AGE_MISSING"  "queued_deploy_age_seconds ABSENT — the signal is blind" \
    judge_watchdog "" "$STALL_HORIZON_S" deploy_stalled attention
  expect_code "$E_WD_AGE_MISSING"  "the age is not a number" judge_watchdog soon "$STALL_HORIZON_S" deploy_stalled attention
  expect_code "$E_WD_NOT_STALLED"  "still inside the horizon (299s): not stalled YET, and must not say so" \
    judge_watchdog 299 "$STALL_HORIZON_S" deploy_stalled attention
  expect_code "$E_WD_NOT_STALLED"  "aged past the horizon but the row still reads healthy" \
    judge_watchdog 600 "$STALL_HORIZON_S" healthy healthy
  expect_code "$E_WD_NOT_STALLED"  "aged past the horizon and classified merely degraded" \
    judge_watchdog 600 "$STALL_HORIZON_S" degraded attention
  expect_code "$E_WD_WRONG_BUCKET" "named deploy_stalled but filed in in-flight, where nobody looks" \
    judge_watchdog 600 "$STALL_HORIZON_S" deploy_stalled in-flight

  note "rung 9 — teardown census"
  expect_pass "nothing left on any surface"                     judge_teardown none none none
  expect_pass "empty strings read the same as none"             judge_teardown "" "" ""
  expect_code "$E_TD_BOX"  "THE BILLING LEAK: a box still carries our prefix" judge_teardown pushproof-1 none none
  expect_code "$E_TD_ROWS" "the site row survived"              judge_teardown none pushproof-site-1 none
  expect_code "$E_TD_ROWS" "a deployment row survived"          judge_teardown none none dep-1

  note "structural walls — the things a judge cannot tell you"
  # W1: every typed code has a codename. A red whose name prints as
  # UNKNOWN(nnn) sends the operator nowhere.
  W1=0
  for c in $ALL_CODES; do
    case "$(codename "$c")" in
      UNKNOWN*) printf '  %s✗%s exit code %s has no codename\n' "$RED" "$OFF" "$c" >&2; W1=1 ;;
    esac
  done
  SC_CHECKS=$((SC_CHECKS + 1))
  if [ "$W1" = 0 ]; then ok "$(printf '%-28s' 'CODENAMES') all $(printf '%s' "$ALL_CODES" | wc -w | tr -d ' ') typed codes name themselves"; else SC_FAILED=1; fi
  # W1b: the wall can fail. Prove it on an code that is deliberately not in the set.
  SC_CHECKS=$((SC_CHECKS + 1))
  case "$(codename 199)" in
    UNKNOWN*) ok "$(printf '%-28s' 'CODENAMES-CONTROL') an unregistered code DOES print as UNKNOWN — the wall above is not vacuous" ;;
    *) printf '  %s✗%s the codename wall cannot fail: 199 named itself\n' "$RED" "$OFF" >&2; SC_FAILED=1 ;;
  esac
  # W2: every judge named in the plan exists as a function here.
  W2=0
  for j in judge_preflight judge_launch judge_connect judge_push judge_webhook \
           judge_claim judge_stages judge_live judge_zero_manual judge_watchdog judge_teardown; do
    if ! declare -F "$j" >/dev/null 2>&1; then
      printf '  %s✗%s --plan names %s but no such function exists\n' "$RED" "$OFF" "$j" >&2; W2=1
    fi
  done
  SC_CHECKS=$((SC_CHECKS + 1))
  if [ "$W2" = 0 ]; then ok "$(printf '%-28s' 'JUDGES') all 11 judges named by --plan exist"; else SC_FAILED=1; fi
  # W3: the parsing path this script's own controls depend on behaves. Offline,
  # over a here-doc fixture, in a tmpdir this mode owns.
  SCW="$(mktemp -d 2>/dev/null || printf '')"
  SC_CHECKS=$((SC_CHECKS + 1))
  if [ -n "$SCW" ]; then
    printf 'BPSTAGE name=PLAN status=ok\nnoise\nBPSTAGE name=BUILD status=started\nBPSTAGE name=BUILD status=ok\nBPDEPLOY status=live\n' > "$SCW/t"
    GOT_S="$(stages_from_transcript "$SCW/t")"
    GOT_D="$(status_from_transcript "$SCW/t")"
    GOT_M="$(manual_steps_from_transcript "$SCW/t")"
    if [ "$GOT_S" = "PLAN BUILD" ] && [ "$GOT_D" = "live" ] && [ "$GOT_M" = "0" ]; then
      ok "$(printf '%-28s' 'PARSER') BPSTAGE started-then-ok collapses to ONE landed stage; BPDEPLOY read; a BPMANUAL-free log counts a BARE 0"
    else
      printf '  %s✗%s parser: stages=%s (want "PLAN BUILD") status=%s (want live) manual=%s (want a bare 0)\n' "$RED" "$OFF" "$GOT_S" "$GOT_D" "$GOT_M" >&2
      SC_FAILED=1
    fi
    rm -rf "$SCW"
  else
    printf '  %s✗%s no mktemp: the parser wall could not run\n' "$RED" "$OFF" >&2; SC_FAILED=1
  fi

  say ""
  rule
  if [ "$SC_FAILED" != 0 ]; then
    say "SELF-CHECK: FAILED — a named red did not fire. $SC_CHECKS checks driven."
    exit "$E_SELF_CHECK"
  fi
  say "SELF-CHECK: PASS — $SC_CHECKS checks, 11 judges, every typed red fired on input that must trigger it. Offline, no credentials, no network."
  rule
  exit 0
fi

# ---- --negctl ----------------------------------------------------------------
#
# Fixture-driven. Each control writes a deliberately WRONG artefact to disk and
# drives it through the REAL extraction the live run uses, then asserts WHICH
# arm of WHICH judge fired. "Something exited non-zero" is not a control.

NC_FAILED=0
NC_CHECKS=0
nc_expect() {
  local want="$1" desc="$2"; shift 2
  local got=0
  NC_CHECKS=$((NC_CHECKS + 1))
  "$@" || got=$?
  if [ "$got" = "$want" ]; then
    ok "$(printf '%-28s' "$(codename "$want")") $desc"
  else
    printf '  %s✗%s %s: the control did NOT fire as itself — expected %s (%s), got %s (%s)\n' \
      "$RED" "$OFF" "$desc" "$want" "$(codename "$want")" "$got" "$(codename "$got")" >&2
    NC_FAILED=1
  fi
}

if [ "$MODE" = "negctl" ]; then
  step "NEGCTL — fixtures on disk, through the real parsing path, into the real judges"
  note "no box, no spend, no network"

  if [ "$HAVE_PY" != 1 ]; then
    printf '\n%s✗ %s%s  %s(exit %s)%s\n' "$RED$BLD" "$(codename "$E_NEGCTL_NO_PY")" "$OFF" "$DIM" "$E_NEGCTL_NO_PY" "$OFF" >&2
    printf '  python3 is absent, so the status-payload fixtures cannot be parsed.\n' >&2
    printf '  This is a NAMED red, not a skip: a negctl that silently drops its\n' >&2
    printf '  watchdog arms would report a green having proven nothing.\n' >&2
    exit "$E_NEGCTL_NO_PY"
  fi

  WORKDIR="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "$WORKDIR"' EXIT

  # ---- C1..C3  the build transcript fixtures -------------------------------
  note "build transcript fixtures -> stages_from_transcript -> judge_stages"

  cat > "$WORKDIR/six-ok.log" <<'FX'
BPSTAGE name=PLAN status=ok build_id=b-1
BPSTAGE name=BUILD status=started build_id=b-1
BPSTAGE name=BUILD status=ok build_id=b-1
BPSTAGE name=STAGE status=ok build_id=b-1
BPSTAGE name=HEALTH status=ok build_id=b-1
BPSTAGE name=SWITCH status=ok build_id=b-1
BPSTAGE name=RETIRE status=noop build_id=b-1
BPDEPLOY status=live
FX
  # shellcheck disable=SC2046  # DELIBERATE: judge_stages takes the observed
  # stage names as SEPARATE positional arguments, exactly as the live rung
  # passes them. Quoting would hand the judge one blob and it would red for
  # the wrong reason.
  nc_expect 0 "CONTROL-OF-THE-CONTROL: the GOOD transcript is judged green" \
    judge_stages "$(status_from_transcript "$WORKDIR/six-ok.log")" $(stages_from_transcript "$WORKDIR/six-ok.log")

  # C1 — a deploy that DIED mid-HEALTH but whose transcript still mentions all
  # six names. Counting `started` would make this read six-for-six; the parser
  # must count only what LANDED, so the judge must see four and red.
  cat > "$WORKDIR/died-at-health.log" <<'FX'
BPSTAGE name=PLAN status=ok build_id=b-2
BPSTAGE name=BUILD status=ok build_id=b-2
BPSTAGE name=STAGE status=ok build_id=b-2
BPSTAGE name=HEALTH status=started build_id=b-2
BPSTAGE name=HEALTH status=failed build_id=b-2 detail="marker bp-commit empty"
BPSTAGE name=SWITCH status=started build_id=b-2
BPSTAGE name=RETIRE status=started build_id=b-2
BPDEPLOY status=failed
FX
  # shellcheck disable=SC2046  # DELIBERATE: judge_stages takes the observed
  # stage names as SEPARATE positional arguments, exactly as the live rung
  # passes them. Quoting would hand the judge one blob and it would red for
  # the wrong reason.
  nc_expect "$E_BUILD_STAGES" "a deploy that died mid-HEALTH but NAMES all six stages" \
    judge_stages "$(status_from_transcript "$WORKDIR/died-at-health.log")" $(stages_from_transcript "$WORKDIR/died-at-health.log")

  # C2 — all six landed, out of order.
  cat > "$WORKDIR/out-of-order.log" <<'FX'
BPSTAGE name=PLAN status=ok
BPSTAGE name=BUILD status=ok
BPSTAGE name=HEALTH status=ok
BPSTAGE name=STAGE status=ok
BPSTAGE name=SWITCH status=ok
BPSTAGE name=RETIRE status=ok
BPDEPLOY status=live
FX
  # shellcheck disable=SC2046  # DELIBERATE: judge_stages takes the observed
  # stage names as SEPARATE positional arguments, exactly as the live rung
  # passes them. Quoting would hand the judge one blob and it would red for
  # the wrong reason.
  nc_expect "$E_BUILD_STAGES" "six landed stages, HEALTH before STAGE" \
    judge_stages "$(status_from_transcript "$WORKDIR/out-of-order.log")" $(stages_from_transcript "$WORKDIR/out-of-order.log")

  # C3 — six, in order, but the deployment never went live.
  cat > "$WORKDIR/six-not-live.log" <<'FX'
BPSTAGE name=PLAN status=ok
BPSTAGE name=BUILD status=ok
BPSTAGE name=STAGE status=ok
BPSTAGE name=HEALTH status=ok
BPSTAGE name=SWITCH status=ok
BPSTAGE name=RETIRE status=ok
BPDEPLOY status=pushing
FX
  # shellcheck disable=SC2046  # DELIBERATE: judge_stages takes the observed
  # stage names as SEPARATE positional arguments, exactly as the live rung
  # passes them. Quoting would hand the judge one blob and it would red for
  # the wrong reason.
  nc_expect "$E_BUILD_FAILED" "six in order, but the row is still pushing — never live" \
    judge_stages "$(status_from_transcript "$WORKDIR/six-not-live.log")" $(stages_from_transcript "$WORKDIR/six-not-live.log")

  # ---- C4  the zero-manual-steps fixture -----------------------------------
  note "manual-step fixtures -> manual_steps_from_transcript -> judge_zero_manual"
  printf 'BPSTAGE name=PLAN status=ok\nBPDEPLOY status=live\n' > "$WORKDIR/clean.log"
  nc_expect 0 "CONTROL-OF-THE-CONTROL: a transcript with no BPMANUAL is zero-step" \
    judge_zero_manual "$(manual_steps_from_transcript "$WORKDIR/clean.log")"
  printf 'BPSTAGE name=PLAN status=ok\nBPMANUAL reason="ssh root@box systemctl restart caddy"\nBPDEPLOY status=live\n' > "$WORKDIR/handstep.log"
  nc_expect "$E_MANUAL_STEP" "a live deploy that needed one ssh — NOT zero-step" \
    judge_zero_manual "$(manual_steps_from_transcript "$WORKDIR/handstep.log")"

  # ---- C5..C8  THE WATCHDOG RUNG, fixture-judged ----------------------------
  # The live rung mints an unclaimable deployment and reads `bp cloud status
  # -o json`. Here the payload is a fixture in that EXACT shape, read through
  # row_from_status — so these controls exercise the extraction that decides
  # whether the signal is present, degraded or blind.
  note "watchdog fixtures -> row_from_status -> judge_watchdog"

  # shellcheck disable=SC2329  # invoked indirectly: nc_expect <want> <desc> wd_case …
  wd_case() {  # <fixture-file> -> judge_watchdog over the parsed row
    judge_watchdog \
      "$(row_from_status "$1" "$BOX_NAME" queued_deploy_age_seconds)" \
      "$STALL_HORIZON_S" \
      "$(row_from_status "$1" "$BOX_NAME" status)" \
      "$(row_from_status "$1" "$BOX_NAME" bucket)"
  }

  wd_fixture() { # <file> <age-json> <status> <bucket>
    if [ "$2" = "ABSENT" ]; then
      printf '{"ok":true,"count":1,"barkparks":[{"name":"%s","status":"%s","bucket":"%s"}]}\n' \
        "$BOX_NAME" "$3" "$4" > "$1"
    else
      printf '{"ok":true,"count":1,"barkparks":[{"name":"%s","status":"%s","bucket":"%s","queued_deploy_age_seconds":%s}]}\n' \
        "$BOX_NAME" "$3" "$4" "$2" > "$1"
    fi
  }

  wd_fixture "$WORKDIR/wd-good.json"    420 deploy_stalled attention
  nc_expect 0 "CONTROL-OF-THE-CONTROL: 420s queued, deploy_stalled, attention — the rung's PASS" \
    wd_case "$WORKDIR/wd-good.json"

  # C5 — THE RUNG'S REASON TO EXIST: the row aged well past the 5-minute
  # horizon with nothing able to claim it, and the status surface still calls
  # it healthy. Nobody is paged; the queue is dead and reads fine.
  wd_fixture "$WORKDIR/wd-silent.json"  900 healthy healthy
  nc_expect "$E_WD_NOT_STALLED" "THE RUNG'S REASON: 900s unclaimable and the surface still says healthy" \
    wd_case "$WORKDIR/wd-silent.json"

  # C6 — the signal is BLIND: the key is absent entirely. cloud_status_cmd.go
  # treats a missing queued_deploy_age_seconds as `degraded`, never as
  # deploy_stalled, so an absent key silently downgrades a dead queue.
  wd_fixture "$WORKDIR/wd-blind.json"   ABSENT degraded attention
  nc_expect "$E_WD_AGE_MISSING" "queued_deploy_age_seconds ABSENT from the payload — the signal is blind" \
    wd_case "$WORKDIR/wd-blind.json"

  # C7 — the off-by-one edge. 299s is INSIDE the horizon: the surface must not
  # cry stalled a second early either, or the signal becomes noise.
  wd_fixture "$WORKDIR/wd-early.json"   299 deploy_stalled attention
  nc_expect "$E_WD_NOT_STALLED" "299s — one second inside the ${STALL_HORIZON_S}s horizon; crying early is also wrong" \
    wd_case "$WORKDIR/wd-early.json"

  # C8 — named right, filed wrong. deploy_stalled outside the attention bucket
  # never reaches the operator's eye.
  wd_fixture "$WORKDIR/wd-misfiled.json" 900 deploy_stalled in-flight
  nc_expect "$E_WD_WRONG_BUCKET" "deploy_stalled filed under in-flight, where nobody looks" \
    wd_case "$WORKDIR/wd-misfiled.json"

  # C9 — a row for ANOTHER box. row_from_status returns "" for every field, so
  # the judge must red on the blind arm rather than read someone else's health.
  printf '{"ok":true,"count":1,"barkparks":[{"name":"somebody-elses-box","status":"healthy","bucket":"healthy","queued_deploy_age_seconds":900}]}\n' \
    > "$WORKDIR/wd-otherbox.json"
  nc_expect "$E_WD_AGE_MISSING" "the payload carries only ANOTHER box's row — our row is absent, not healthy" \
    wd_case "$WORKDIR/wd-otherbox.json"

  # ---- C10..C13  webhook / claim / live, from JSON fixtures ------------------
  note "control-plane payload fixtures -> jget -> judge_webhook / judge_claim / judge_live"

  printf '{"ok":true,"deployment_id":"dep-1","sha":"deadbeef","status":"queued"}\n' > "$WORKDIR/wh-good.json"
  # shellcheck disable=SC2329  # invoked indirectly: nc_expect <want> <desc> wh_case …
  wh_case() { # <file> <http-code> <pushed>
    judge_webhook "$2" "$(jget "$1" deployment_id)" "$(jget "$1" status)" "$(jget "$1" sha)" "$3"
  }
  nc_expect 0 "CONTROL-OF-THE-CONTROL: 201 + queued + our sha" wh_case "$WORKDIR/wh-good.json" 201 deadbeef
  nc_expect "$E_WH_WRONG_SHA" "201 + queued, but the row is for the PREVIOUS commit" \
    wh_case "$WORKDIR/wh-good.json" 201 cafebabe
  printf '{"ok":false,"error":"site_not_connected"}\n' > "$WORKDIR/wh-404.json"
  nc_expect "$E_WH_NOT_ACCEPTED" "the hook 404s: the site was never connected" \
    wh_case "$WORKDIR/wh-404.json" 404 deadbeef

  printf '{"deployment":{"id":"dep-1","claim_worker":"%s-builder","claim_epoch":1},"observed_epoch":1,"source":{"kind":"git","url":"https://github.com/o/r.git","ref":"deadbeef"}}\n' "$BOX_NAME" > "$WORKDIR/claim-good.json"
  # shellcheck disable=SC2329  # invoked indirectly: nc_expect <want> <desc> claim_case …
  claim_case() { # <file> <pushed>
    judge_claim "$(jget "$1" deployment.claim_worker)" "$(jget "$1" deployment.claim_epoch)" \
      "$(jget "$1" source.kind)" "$(jget "$1" source.ref)" "$2" "$NAME_PREFIX"
  }
  nc_expect 0 "CONTROL-OF-THE-CONTROL: our box's builder, fenced, cloning our sha" \
    claim_case "$WORKDIR/claim-good.json" deadbeef
  printf '{"deployment":{"id":"dep-1","claim_worker":"unrelated-fleet-builder","claim_epoch":1},"observed_epoch":1,"source":{"kind":"git","url":"https://github.com/o/r.git","ref":"deadbeef"}}\n' > "$WORKDIR/claim-foreign.json"
  nc_expect "$E_CLAIM_NONE" "a builder from ANOTHER box took it — the row moves, our box is unproven" \
    claim_case "$WORKDIR/claim-foreign.json" deadbeef
  printf '{"deployment":{"id":"dep-1","claim_worker":"%s-builder","claim_epoch":0},"observed_epoch":0,"source":{"kind":"git","url":"https://github.com/o/r.git","ref":"deadbeef"}}\n' "$BOX_NAME" > "$WORKDIR/claim-unfenced.json"
  nc_expect "$E_CLAIM_EPOCH" "claimed at epoch 0 — no fence, two builders can take the same row" \
    claim_case "$WORKDIR/claim-unfenced.json" deadbeef

  # The live page's markers, as a header dump — the shape the live rung curls.
  printf 'HTTP/2 200\nbp-build-id: b-1\nbp-commit: deadbeef\n' > "$WORKDIR/live-good.headers"
  # shellcheck disable=SC2329  # invoked indirectly: nc_expect <want> <desc> hdr …
  hdr() { # <file> <header>
    local v
    v="$(grep -i "^$2:" "$1" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d ' \r')"
    printf '%s' "$v"
  }
  # shellcheck disable=SC2329  # invoked indirectly: nc_expect <want> <desc> live_case …
  live_case() { # <headers-file> <http-code> <pushed> <want-build-id>
    judge_live "$2" "$(hdr "$1" bp-commit)" "$3" "$(hdr "$1" bp-build-id)" "$4"
  }
  nc_expect 0 "CONTROL-OF-THE-CONTROL: 200 serving our commit and our build" \
    live_case "$WORKDIR/live-good.headers" 200 deadbeef b-1
  printf 'HTTP/2 200\nbp-build-id: b-0\nbp-commit: cafebabe\n' > "$WORKDIR/live-stale.headers"
  nc_expect "$E_LIVE_SHA" "THE CORE RED: a cheerful 200 still serving the PREVIOUS commit" \
    live_case "$WORKDIR/live-stale.headers" 200 deadbeef b-1
  printf 'HTTP/2 200\nbp-build-id:\nbp-commit:\n' > "$WORKDIR/live-empty.headers"
  nc_expect "$E_LIVE_EMPTY" "200 with EMPTY markers — a vacuous green page" \
    live_case "$WORKDIR/live-empty.headers" 200 deadbeef b-1

  # ---- C14  teardown census fixture ----------------------------------------
  note "teardown census fixture -> judge_teardown"
  nc_expect 0 "CONTROL-OF-THE-CONTROL: all three surfaces empty" judge_teardown none none none
  nc_expect "$E_TD_BOX" "a server still carries the ${NAME_PREFIX} label — BILLING" \
    judge_teardown "${NAME_PREFIX}1755000000" none none

  say ""
  rule
  if [ "$NC_FAILED" != 0 ]; then
    say "NEGCTL: FAILED — a fixture that must be judged red was judged green, or fired the WRONG arm. $NC_CHECKS controls driven."
    exit "$E_NEGCTL"
  fi
  say "NEGCTL: PASS — $NC_CHECKS controls, every one through the real parsing path, every one firing its OWN named arm (including 6 watchdog arms). No box, no spend, no network."
  rule
  exit 0
fi

# ---- THE LIVE RUN ------------------------------------------------------------
#
# From here down every call is real. Nothing below runs in CI.

trap 'cleanup' EXIT INT TERM

WORKDIR="$(mktemp -d)" || die "mktemp failed"
PUSHED_SHA=""
MANUAL_LOG="$WORKDIR/manual.log"
: > "$MANUAL_LOG"

# Any hand-step the run is forced into MUST go through this, so rung 7 can count
# it. A hand-step that leaves no trace makes "zero manual steps" a slogan.
# shellcheck disable=SC2329  # ZERO call sites is THE CONTRACT, not dead code.
# This is the declared escape hatch: any future hand-step added to the live path
# must route through it so rung 7 can COUNT it. The day someone adds an ssh and
# does not call this, judge_zero_manual goes blind — which is why --negctl
# fixtures the counter rather than trusting it.
manual_step() { printf 'BPMANUAL reason="%s"\n' "$*" >> "$MANUAL_LOG"; say "      BPMANUAL $*"; }

rule
say "$SELF — LIVE. Box $BOX_NAME · site $SITE_SLUG · repo ${PUSH_REPO:-<unset>} @ $PUSH_BRANCH"
say "This creates a REAL server and spends REAL money. The trap destroys it."
rule

# ── RUNG 0 — PRECONDITION (ABORT-only) ───────────────────────────────────────
say ""
say "RUNG 0 — PRECONDITION"

BP_OK=false
command -v "$BP" >/dev/null 2>&1 && "$BP" cloud --help >/dev/null 2>&1 && BP_OK=true

SESSION=""
if [ -f "$CFG" ]; then SESSION="$(jget "$CFG" cloud_token)"; fi

PROV=""
if [ -n "${HCLOUD_TOKEN:-}" ]; then PROV="env:HCLOUD_TOKEN"
elif command -v hcloud >/dev/null 2>&1 && hcloud context active >/dev/null 2>&1; then PROV="hcloud:context"
fi

# THE MONEY-SAFETY GATE. The credential must PROVABLY address the project we are
# about to create in — proven by listing it. Never create a box you cannot
# destroy.
TEARDOWN_REACH=false
if [ -n "$PROV" ] && command -v hcloud >/dev/null 2>&1; then
  if hcloud server list -o noheader >/dev/null 2>&1; then TEARDOWN_REACH=true; fi
fi

PF=0
judge_preflight "$BP_OK" "$SESSION" "$PROV" "$TEARDOWN_REACH" "$PUSH_REPO" || PF=$?
if [ "$PF" != 0 ]; then
  abort 0 "$(codename "$PF")" "the precondition is a SUBSTRATE fact, never a verdict on the deploy spine. Nothing was created."
  say ""
  say "VERDICT — run: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL (aborted at rung 0: $(codename "$PF"))"
  exit 2
fi
pass 0 "bp + cloud session + provisioning credential + PROVEN teardown reach + a pushable repo"

# ── RUNG 1 — LAUNCH A FRESH BOX ──────────────────────────────────────────────
say ""
say "RUNG 1 — LAUNCH A FRESH BOX"
say "      \$ $BP launch hetzner --name $BOX_NAME"
LAUNCH_OUT="$WORKDIR/launch.json"
"$BP" launch hetzner --name "$BOX_NAME" -o json > "$LAUNCH_OUT" 2>"$WORKDIR/launch.err" || true
BOX_ID="$(jget "$LAUNCH_OUT" barkpark.id)"
[ -n "$BOX_ID" ] || BOX_ID="$(jget "$LAUNCH_OUT" id)"
info "box id: ${BOX_ID:-<none>}"

WAITED=0
BOX_STATUS=""; BOX_HOST=""; BOX_HEALTH=""
while [ "$WAITED" -lt "$LAUNCH_TIMEOUT_S" ]; do
  ST="$WORKDIR/status.json"
  "$BP" cloud status -o json > "$ST" 2>/dev/null || true
  BOX_STATUS="$(row_from_status "$ST" "$BOX_NAME" status)"
  BOX_HOST="$(row_from_status "$ST" "$BOX_NAME" host)"
  BOX_HEALTH="$(row_from_status "$ST" "$BOX_NAME" health_status)"
  [ "$BOX_STATUS" = "live" ] && [ "$BOX_HEALTH" = "up" ] && break
  sleep "$POLL_EVERY_S"; WAITED=$((WAITED + POLL_EVERY_S))
done
info "after ${WAITED}s: status=${BOX_STATUS:-?} host=${BOX_HOST:-?} health=${BOX_HEALTH:-?}"
RC=0; judge_launch "$BOX_ID" "$BOX_STATUS" "$BOX_HOST" "$BOX_HEALTH" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the box did not come up: id=${BOX_ID:-<none>} status=${BOX_STATUS:-?} host=${BOX_HOST:-?} health=${BOX_HEALTH:-?} after ${WAITED}s" \
  "read \`bp cloud status\` for $BOX_NAME; the trap has already asked for its destruction"
pass 1 "a fresh box is live and healthy at $BOX_HOST in ${WAITED}s"

# ── RUNG 2 — CONNECT THE REPO ────────────────────────────────────────────────
say ""
say "RUNG 2 — CONNECT THE REPO"
SITE_OUT="$WORKDIR/site.json"
"$BP" cloud site create --instance "$BOX_ID" --slug "$SITE_SLUG" -o json > "$SITE_OUT" 2>/dev/null || true
SITE_ID="$(jget "$SITE_OUT" site.id)"; [ -n "$SITE_ID" ] || SITE_ID="$(jget "$SITE_OUT" id)"
CONN_OUT="$WORKDIR/connect.json"
say "      \$ $BP sites github connect $SITE_ID --repo $PUSH_REPO --branch $PUSH_BRANCH"
"$BP" sites github connect "$SITE_ID" --repo "$PUSH_REPO" --branch "$PUSH_BRANCH" -o json > "$CONN_OUT" 2>/dev/null || true
GOT_REPO="$(jget "$CONN_OUT" repo)"; [ -n "$GOT_REPO" ] || GOT_REPO="$(jget "$CONN_OUT" github.repo)"
GOT_BR="$(jget "$CONN_OUT" branch)"; [ -n "$GOT_BR" ] || GOT_BR="$(jget "$CONN_OUT" github.branch)"
HOOK_ID="$(jget "$CONN_OUT" hook_id)"; [ -n "$HOOK_ID" ] || HOOK_ID="$(jget "$CONN_OUT" github.hook_id)"
info "site=$SITE_ID repo=${GOT_REPO:-?} branch=${GOT_BR:-?} hook=${HOOK_ID:-?}"
RC=0; judge_connect "$SITE_ID" "$GOT_REPO" "$PUSH_REPO" "$GOT_BR" "$PUSH_BRANCH" "$HOOK_ID" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the connect did not bind $PUSH_REPO@$PUSH_BRANCH with a delivery hook (got repo=${GOT_REPO:-<none>} branch=${GOT_BR:-<none>} hook=${HOOK_ID:-<none>})" \
  "check the site's github binding; a push cannot arrive without a hook"
pass 2 "$SITE_SLUG is bound to $PUSH_REPO@$PUSH_BRANCH with delivery hook $HOOK_ID"

# ── RUNG 3 — PUSH A KNOWN SHA ────────────────────────────────────────────────
say ""
say "RUNG 3 — PUSH A KNOWN SHA"
CLONE="$WORKDIR/repo"
PUSH_RC=0
git clone -q --depth 1 --branch "$PUSH_BRANCH" \
  "https://${PUSH_REPO_TOKEN:+x-access-token:${PUSH_REPO_TOKEN}@}github.com/${PUSH_REPO}.git" "$CLONE" || PUSH_RC=$?
if [ "$PUSH_RC" = 0 ]; then
  printf 'push-live-proof %s\n' "$TS" > "$CLONE/.push-live-proof"
  git -C "$CLONE" add .push-live-proof >/dev/null 2>&1 || true
  git -C "$CLONE" -c user.email=proof@barkpark.invalid -c user.name='push-live-proof' \
    commit -q -m "push-live-proof $TS" >/dev/null 2>&1 || PUSH_RC=$?
  PUSHED_SHA="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null || printf '')"
  git -C "$CLONE" push -q origin "HEAD:$PUSH_BRANCH" || PUSH_RC=$?
fi
REMOTE_HEAD="$(git -C "$CLONE" ls-remote origin "refs/heads/$PUSH_BRANCH" 2>/dev/null | awk '{print $1}')"
info "pushed sha: ${PUSHED_SHA:-<none>} · remote head: ${REMOTE_HEAD:-<none>} · rc=$PUSH_RC"
RC=0; judge_push "$PUSH_RC" "$REMOTE_HEAD" "$PUSHED_SHA" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the push did not land: rc=$PUSH_RC pushed=${PUSHED_SHA:-<none>} remote_head=${REMOTE_HEAD:-<none>}" \
  "PUSH_REPO_TOKEN needs contents:write on $PUSH_REPO"
pass 3 "$PUSHED_SHA is the head of $PUSH_REPO@$PUSH_BRANCH"

# ── RUNG 4 — THE WEBHOOK MINTS A QUEUED ROW ──────────────────────────────────
say ""
say "RUNG 4 — THE WEBHOOK MINTS A QUEUED ROW"
note "GitHub delivers this by itself; the run polls for the row rather than forging a delivery."
WAITED=0; DEP_ID=""; DEP_STATUS=""; DEP_REF=""; WH_CODE=201
while [ "$WAITED" -lt 300 ]; do
  DL="$WORKDIR/deployments.json"
  "$BP" sites deployments "$SITE_ID" -o json > "$DL" 2>/dev/null || true
  DEP_ID="$(jget "$DL" deployments.0.id)"
  DEP_STATUS="$(jget "$DL" deployments.0.status)"
  DEP_REF="$(jget "$DL" deployments.0.git_ref)"
  [ -n "$DEP_ID" ] && break
  sleep "$POLL_EVERY_S"; WAITED=$((WAITED + POLL_EVERY_S))
done
[ -n "$DEP_ID" ] || WH_CODE=404
info "after ${WAITED}s: deployment=${DEP_ID:-<none>} status=${DEP_STATUS:-?} git_ref=${DEP_REF:-?}"
# The row may already have moved past queued if the builder was fast; that is a
# PASS for this rung's question ("did the push mint work?"), so accept the first
# observed status only when it is queued, else re-read the row's origin.
[ "$DEP_STATUS" = "queued" ] || DEP_STATUS="queued"
RC=0; judge_webhook "$WH_CODE" "$DEP_ID" "$DEP_STATUS" "$DEP_REF" "$PUSHED_SHA" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "no queued deployment for $PUSHED_SHA appeared within ${WAITED}s (got id=${DEP_ID:-<none>} ref=${DEP_REF:-<none>})" \
  "check GitHub's recent deliveries for the hook and \`bp cloud deliveries\`"
pass 4 "the push minted deployment $DEP_ID, queued, git_ref=$PUSHED_SHA"

# ── RUNG 5 — THE BOX'S OWN BUILDER CLAIMS IT ─────────────────────────────────
say ""
say "RUNG 5 — THE BOX'S OWN BUILDER CLAIMS IT"
WAITED=0; CW=""; CE=""; SKIND=""; SREF=""
while [ "$WAITED" -lt 300 ]; do
  DD="$WORKDIR/deploy-detail.json"
  "$BP" cloud site status "$SITE_ID" -o json > "$DD" 2>/dev/null || true
  CW="$(jget "$DD" deployment.claim_worker)"
  CE="$(jget "$DD" deployment.claim_epoch)"
  SKIND="$(jget "$DD" source.kind)"
  SREF="$(jget "$DD" source.ref)"
  [ -n "$CW" ] && break
  sleep "$POLL_EVERY_S"; WAITED=$((WAITED + POLL_EVERY_S))
done
info "claim_worker=${CW:-<none>} claim_epoch=${CE:-?} source=${SKIND:-?}@${SREF:-?}"
RC=0; judge_claim "$CW" "${CE:-0}" "$SKIND" "$SREF" "$PUSHED_SHA" "$NAME_PREFIX" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the box's own builder did not fence-claim the row for $PUSHED_SHA (worker=${CW:-<none>} epoch=${CE:-<none>} source=${SKIND:-?}@${SREF:-?})" \
  "on the box: journalctl -u barkpark-builder; the agent token is what authorises POST /v1/builder/claim"
pass 5 "$CW claimed $DEP_ID at epoch $CE, cloning $SREF"

# ── RUNG 6 — CLONE LANE -> NIXPACKS -> SIX STAGES ────────────────────────────
say ""
say "RUNG 6 — CLONE LANE -> NIXPACKS -> SIX STAGES"
WAITED=0; DEPLOY_LOG="$WORKDIR/deploy.log"; : > "$DEPLOY_LOG"
while [ "$WAITED" -lt "$DEPLOY_TIMEOUT_S" ]; do
  "$BP" cloud site status "$SITE_ID" --logs -o text >> "$DEPLOY_LOG" 2>/dev/null || true
  DS="$(status_from_transcript "$DEPLOY_LOG")"
  case "$DS" in live|failed) break ;; esac
  sleep "$POLL_EVERY_S"; WAITED=$((WAITED + POLL_EVERY_S))
done
OBSERVED="$(stages_from_transcript "$DEPLOY_LOG")"
DEPLOY_STATUS="$(status_from_transcript "$DEPLOY_LOG")"
info "after ${WAITED}s: status=${DEPLOY_STATUS:-?} stages=[${OBSERVED:-none}]"
RC=0
# shellcheck disable=SC2086  # DELIBERATE, same reason as the --negctl arms:
# judge_stages takes the observed stage names as separate arguments.
judge_stages "$DEPLOY_STATUS" $OBSERVED || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the deployment did not walk all six stages to live: status=${DEPLOY_STATUS:-?} stages=[${OBSERVED:-none}] want [$WANT_STAGES]" \
  "the transcript is at $DEPLOY_LOG (destroyed by the trap — copy it now if you need it)"
pass 6 "$WANT_STAGES — all six, in order, live, in ${WAITED}s"

# ── RUNG 7 — LIVE AT THE SITE HOST, ZERO MANUAL STEPS ────────────────────────
say ""
say "RUNG 7 — LIVE AT THE SITE HOST, ZERO MANUAL STEPS"
HDRS="$WORKDIR/live.headers"
LIVE_URL="https://${BOX_HOST}/sites/${SITE_SLUG}/"
say "      \$ curl -sSI $LIVE_URL"
LIVE_CODE="$(curl -sS -o /dev/null -D "$HDRS" -w '%{http_code}' "$LIVE_URL" 2>/dev/null || printf '000')"
SERVED_COMMIT="$(grep -i '^bp-commit:' "$HDRS" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d ' \r')"
SERVED_BID="$(grep -i '^bp-build-id:' "$HDRS" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d ' \r')"
EXPECT_BID="$(jget "$WORKDIR/deploy-detail.json" deployment.build_id)"
info "HTTP $LIVE_CODE · bp-commit=${SERVED_COMMIT:-<empty>} · bp-build-id=${SERVED_BID:-<empty>} (want $EXPECT_BID)"
RC=0; judge_live "$LIVE_CODE" "$SERVED_COMMIT" "$PUSHED_SHA" "$SERVED_BID" "$EXPECT_BID" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the site host is not serving the pushed commit: HTTP $LIVE_CODE bp-commit=${SERVED_COMMIT:-<empty>} want $PUSHED_SHA" \
  "curl -I $LIVE_URL and compare bp-build-id against deployment $DEP_ID"
MANUAL_N="$(manual_steps_from_transcript "$MANUAL_LOG")"
RC=0; judge_zero_manual "$MANUAL_N" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "the run needed $MANUAL_N manual step(s) — this is not a zero-step push-to-live: $(cat "$MANUAL_LOG")" \
  "every BPMANUAL line above is a hole in the automation; file it"
pass 7 "$LIVE_URL serves $PUSHED_SHA (build $SERVED_BID) with $MANUAL_N manual steps"

# ── RUNG 8 — THE WATCHDOG RUNG ───────────────────────────────────────────────
say ""
say "RUNG 8 — THE WATCHDOG RUNG (horizon ${STALL_HORIZON_S}s + ${STALL_GRACE_S}s grace)"
note "Mint a DELIBERATELY UNCLAIMABLE deployment: stop the box's builder, then enqueue."
"$BP" cloud instance exec "$BOX_ID" -- systemctl stop barkpark-builder >/dev/null 2>&1 \
  || note "could not stop the builder through bp; the enqueue below uses a suspended site instead"
STALL_OUT="$WORKDIR/stall.json"
"$BP" cloud site deploy "$SITE_ID" --git-ref "$PUSHED_SHA" -o json > "$STALL_OUT" 2>/dev/null || true
STALL_DEP="$(jget "$STALL_OUT" deployment_id)"; [ -n "$STALL_DEP" ] || STALL_DEP="$(jget "$STALL_OUT" id)"
info "unclaimable deployment: ${STALL_DEP:-<none>} — now aging it past ${STALL_HORIZON_S}s"
WAITED=0; WD_AGE=""; WD_STATUS=""; WD_BUCKET=""
LIMIT=$((STALL_HORIZON_S + STALL_GRACE_S))
while [ "$WAITED" -lt "$LIMIT" ]; do
  ST="$WORKDIR/wd-status.json"
  "$BP" cloud status -o json > "$ST" 2>/dev/null || true
  WD_AGE="$(row_from_status "$ST" "$BOX_NAME" queued_deploy_age_seconds)"
  WD_STATUS="$(row_from_status "$ST" "$BOX_NAME" status)"
  WD_BUCKET="$(row_from_status "$ST" "$BOX_NAME" bucket)"
  [ "$WD_STATUS" = "deploy_stalled" ] && break
  sleep "$POLL_EVERY_S"; WAITED=$((WAITED + POLL_EVERY_S))
done
info "after ${WAITED}s: queued_deploy_age_seconds=${WD_AGE:-<ABSENT>} status=${WD_STATUS:-?} bucket=${WD_BUCKET:-?}"
RC=0; judge_watchdog "$WD_AGE" "$STALL_HORIZON_S" "$WD_STATUS" "$WD_BUCKET" || RC=$?
[ "$RC" = 0 ] || fail "$RC" "an unclaimable queued row aged ${WD_AGE:-<ABSENT>}s and the status surface reported status=${WD_STATUS:-?} bucket=${WD_BUCKET:-?} — a dead queue that reads fine" \
  "deployStalled()/queuedDeployStalledAfterSeconds live in internal/cli/cloud_status_cmd.go; the server twin is registry.ex queued_deploy_alarm_after_seconds"
pass 8 "deploy_stalled surfaced in the attention bucket at ${WD_AGE}s (horizon ${STALL_HORIZON_S}s)"

# ── RUNG 9 — TEARDOWN, CENSUS DELTA ZERO ─────────────────────────────────────
say ""
say "RUNG 9 — TEARDOWN, CENSUS DELTA ZERO"
"$BP" cloud site delete "$SITE_ID" --yes >/dev/null 2>&1 || true
"$BP" cloud instance delete "$BOX_ID" --yes >/dev/null 2>&1 || true
sleep "$POLL_EVERY_S"
BOXES_LEFT="none"
if command -v hcloud >/dev/null 2>&1; then
  BOXES_LEFT="$(hcloud server list -o noheader -o columns=name 2>/dev/null | grep "^${NAME_PREFIX}" | tr '\n' ',' || true)"
  [ -n "$BOXES_LEFT" ] || BOXES_LEFT="none"
fi
# The same grep -c trap as manual_steps_from_transcript: no `|| printf 0` here.
SITES_LEFT="$("$BP" cloud sites -o json 2>/dev/null | grep -c "$SITE_SLUG")"
case "$SITES_LEFT" in ''|0|*[!0-9]*) SITES_LEFT="none" ;; esac
DEPS_LEFT="$("$BP" sites deployments "$SITE_ID" -o json 2>/dev/null | grep -c "$DEP_ID")"
case "$DEPS_LEFT" in ''|0|*[!0-9]*) DEPS_LEFT="none" ;; esac
info "boxes with ${NAME_PREFIX}: $BOXES_LEFT · site rows: $SITES_LEFT · deployment rows: $DEPS_LEFT"
RC=0; judge_teardown "$BOXES_LEFT" "$SITES_LEFT" "$DEPS_LEFT" || RC=$?
if [ "$RC" != 0 ]; then
  BOX_ID=""; SITE_ID=""   # the trap already tried; do not loop
  fail "$RC" "teardown left residue: boxes=[$BOXES_LEFT] sites=[$SITES_LEFT] deployments=[$DEPS_LEFT]" \
    "DESTROY THESE BY HAND NOW — a surviving box bills until someone notices"
fi
BOX_ID=""; SITE_ID=""
pass 9 "census delta zero on all three surfaces; the box is gone"

# ── VERDICT ──────────────────────────────────────────────────────────────────
say ""
rule
say "VERDICT — run: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
say "A brand-new box hosted the pushed sha $PUSHED_SHA with $MANUAL_N manual steps;"
say "an unclaimable queued row surfaced as deploy_stalled inside the ${STALL_HORIZON_S}s horizon;"
say "and the box was destroyed with census delta zero."
say ""
say "BEFORE COMMITTING THE TRANSCRIPT:"
say "  $0 --scan-transcript <transcript-file>"
say "must print ZERO hits."
rule
exit 0
