#!/usr/bin/env bash
#
# onboarding-journey-proof.sh — THE ONBOARDING IDENTITY-TRANSACTION PROOF
# (onboarding-composition-epic, wave onboarding-composition-wave-2026-08-17;
# task onb-w4-journey-proof-rig; templated on scripts/pdf-mvp0-journey-proof.sh
# — the pds-pull-proof dialect: --plan / LIVE / --negctl / --scan-transcript,
# the PASS/ABORT/FAIL ladder, tokens never printed).
#
# THE CLAIM UNDER PROOF: onboarding is ONE identity transaction with ONE
# trustworthy receipt. This rig proves it LIVE against a LOCALLY-BOOTED cloud
# control plane (cloud/ — Bandit+Plug, NOT Phoenix; `mix phx.server` does not
# exist; the dev port is FIXED 4100 — PORT env is prod-only), driving the
# SHIPPED CLI primitives, never bespoke re-implementations:
#
#   fresh register            POST /v1/auth/register → 201 {token, team_id}
#   device start              bp login --url http://localhost:4100 --device-start
#   poll (pending)            bp login --device-poll <code> → {"status":"pending"}
#   approve (headless)        curl POST /v1/auth/device/approve, Bearer session
#   poll (token)              bp login --device-poll <code> → {ok, cloud_url, team_id}
#   replay-burn               the SAME device_code polls again → expired_or_invalid
#   re-register               the SAME email (valid password) → 409 email_taken
#   receipt                   GET /v1/me → user/team/onboarding.steps[]
#   client receipt            bp whoami -o json + bp doctor --onboarding -o json
#
# The identity leg is WALL-CLOCKED (verification measured 0.32s server-side;
# budget 300s), and the run's own transcript is token-scanned at the end: NO
# bearer (session token, cloud_token, password, device_code) may ever print.
#
# SAFETY — THE LOCALITY GUARD (fires BEFORE any side effect, negctl-proven):
# cloud/accounts.ex has NO delete_user — an account registered against
# api.barkpark.cloud (or ANY non-local host) is PERMANENT. The fresh-register
# leg therefore HARD-REFUSES every target whose host is not
# localhost/127.0.0.1/::1, and exits 3 without creating anything.
#
#   scripts/onboarding-journey-proof.sh --plan        print every rung, its
#                                                     assert and the safety law.
#                                                     NO side effects, exit 0.
#   scripts/onboarding-journey-proof.sh               the proof (LIVE): boots the
#                                                     local CP (postgres up; cd
#                                                     cloud && mix deps.get &&
#                                                     mix ecto.create && mix
#                                                     ecto.migrate && mix run
#                                                     --no-halt), runs the whole
#                                                     identity journey against
#                                                     it, tears the CP down. The
#                                                     dev DB is throwaway.
#   scripts/onboarding-journey-proof.sh --negctl      the negative control (no
#                                                     boot, no register): the
#                                                     locality guard must FIRE
#                                                     against api.barkpark.cloud
#                                                     + any raw non-local host,
#                                                     must PASS localhost (not
#                                                     vacuous), and the full LIVE
#                                                     entry pointed at prod must
#                                                     refuse before RUNG 1; the
#                                                     transcript scanner must
#                                                     flag a seeded fake bearer.
#   scripts/onboarding-journey-proof.sh --guard-probe <url>
#                                                     JUST the locality guard:
#                                                     ALLOWED (exit 0) or
#                                                     REFUSED (exit 3). Zero
#                                                     side effects.
#   scripts/onboarding-journey-proof.sh --scan-transcript <file>
#                                                     token-scan a transcript
#                                                     before it is committed:
#                                                     config bearers, raw
#                                                     Bearer-header prints,
#                                                     sk-ant — ZERO hits or no
#                                                     commit.
#   scripts/onboarding-journey-proof.sh --leg <name>  the NAMED out-of-substrate
#                                                     legs (windows |
#                                                     installer-ps1 |
#                                                     paid-instance |
#                                                     mcp-instance): each ABORTs
#                                                     naming the substrate it
#                                                     needs — never silently
#                                                     absorbed, never faked.
#   scripts/onboarding-journey-proof.sh --help
#
# THE THREE OUTCOMES (the pds-pull-proof ladder, verbatim — no fourth, no
# silent skip):
#   PASS   the rung ran and every assertion held.
#   ABORT  the rung cannot run (missing tool / postgres down / port squatted /
#          boot timeout — a substrate problem, never a verdict on the thing
#          under test). A failed local boot is an ABORT finding, not a dead rig.
#   FAIL   the rung ran and an assertion did NOT hold.
# Exit: 0 = every rung PASSed. 1 = FAIL. 2 = ABORT. 3 = usage error OR the
# locality guard's refusal (the safety exit — deliberate, loud, pre-side-effect).
#
# RUNGS (LIVE):
#   0  PRECONDITION — ABORT-only: locality guard (REFUSES non-local, exit 3,
#      before ANYTHING); curl/python3/go/mix on PATH; postgres accepting on
#      localhost:5432; cloud/mix.exs present; fresh bp builds from
#      ./cmd/barkpark. EVERY bp call runs under an ISOLATED XDG_CONFIG_HOME —
#      the operator's real ~/.config/barkpark is never read, never written.
#   1  BOOT — port 4100 free → mix deps.get + ecto.create + ecto.migrate + mix
#      run --no-halt, poll GET /v1/auth/oauth/providers until it answers JSON
#      (budget ONBJP_BOOT_BUDGET, default 240s); anon GET /v1/me must 401 (the
#      auth gate is live). Port already serving a CP → REUSE it (named in the
#      transcript; nothing to kill at teardown). Port squatted by a non-CP →
#      ABORT naming the squatter.
#   2  IDENTITY — the wall-clocked transaction: register 201 → device start →
#      poll pending → headless Bearer-session approve 200 → poll token (exit 0,
#      envelope {ok,cloud_url,team_id}; the cloud_token lands ONLY in the
#      isolated config) → replay-burn (the same device_code must answer
#      expired_or_invalid, non-zero exit) → re-register the SAME email with the
#      SAME valid password → 409 {"error":"email_taken"} (the enumeration gate
#      409s only for a VALID password — the honest signal). Wall clock printed;
#      must land under ONBJP_IDENTITY_BUDGET (default 300s).
#   3  RECEIPT — ONE trustworthy receipt, three surfaces, all agreeing:
#      GET /v1/me (CLI-minted bearer) → user.email/team.id match, onboarding
#      carries a non-empty steps[] of {key,done}; bp whoami -o json →
#      cloud.logged_in true, cloud.url + cloud.team match; bp doctor
#      --onboarding -o json → cloud_session {present:true, url, team} matches.
#   4  TRANSCRIPT-SCAN — the run scans its OWN tee'd transcript for the session
#      token, the cloud_token, the password, the device_code, and sk-ant: zero
#      hits or FAIL. (--negctl proves this scanner can fire, so its green is
#      not vacuous.)
#   5  NAMED OUT-OF-SUBSTRATE LEGS — windows / installer-ps1 (install-cli.ps1) /
#      paid-instance / mcp-instance: named here with their --leg invocations
#      and the substrate each needs. NEVER silently absorbed; run one with
#      --leg <name> and it ABORTs honestly.
#   6  TEARDOWN — kill the booted CP (process group; skipped when reused), keep
#      the transcript (path printed), remove the workdir. The dev DB is
#      throwaway (`cd cloud && mix ecto.drop` resets it; the registered
#      journey user is local-only data).
#
# GATE: sh -n scripts/onboarding-journey-proof.sh &&
#       sh scripts/onboarding-journey-proof.sh --plan   (plan is provably
#       side-effect-free: no mktemp, no network, no config reads — only prints).
#
# VERIFIED RUN (2026-08-17, tree 6ea916104c75, macOS local rig — this header
# block IS the durable record of the LIVE proof the merge carries):
#   LIVE  run 20260817T201644Z: PASS=7 ABORT=0 FAIL=0, exit 0. CP booted in
#         2.1s (mix run --no-halt, port 4100). IDENTITY LEG WALL CLOCK 1.06s
#         (budget 300s): register 201 {token, team_id} → bp login --device-start
#         → poll {"status":"pending"} exit 1 → headless Bearer-session approve
#         200 {ok:true} → poll exit 0 {ok, cloud_url, team_id} (cloud_token
#         persisted ONLY to the isolated XDG config) → replay-burn of the same
#         device_code → expired_or_invalid, non-zero exit → re-register same
#         email → 409 {error: email_taken}. RECEIPT: GET /v1/me 200 with
#         onboarding.steps[] = subscription(done)/instance/published_doc;
#         bp whoami -o json cloud{logged_in,url,team} truthful; bp doctor
#         --onboarding cloud_session{present,url,team} truthful. RUNG 4
#         self-scan: zero bearers in the transcript; the post-hoc
#         --scan-transcript of the same file: zero hits, committable.
#   NEGCTL run 2026-08-17: PASS=5 ABORT=0 FAIL=0, exit 0 — api.barkpark.cloud
#         REFUSED exit 3; guerrilla/raw-IP/internal-name REFUSED; localhost +
#         127.0.0.1 ALLOWED (not vacuous); the FULL LIVE entry pointed at prod
#         refused BEFORE RUNG 1 with zero writes; the scanner flagged a seeded
#         fake bearer (exit 1) and passed a clean file (exit 0).
#
# Environment (all optional; --plan prints the defaults):
#   ONBJP_CP_BASE           default http://localhost:4100 — the control plane
#                           under test. NON-LOCAL HOSTS ARE REFUSED (exit 3).
#   ONBJP_BOOT_BUDGET       CP boot ceiling, s (default 240)
#   ONBJP_IDENTITY_BUDGET   identity-leg wall-clock ceiling, s (default 300)
#   ONBJP_KEEP_CP=1         leave the booted CP running at teardown
#   ONBJP_TRANSCRIPT        transcript path (default $TMPDIR/onbjp-run-<ts>.transcript)
#
# POSIX-sh compatible (the gate runs it under `sh`); macOS system tools only.

set -eu
# pipefail where the shell has it (bash/zsh); plain POSIX sh proceeds without.
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi
# Job control: a backgrounded CP gets its OWN process group, so teardown can
# kill the whole beam tree with one negative-pid signal (template lineage).
set -m 2>/dev/null || true

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

# ── fixtures ─────────────────────────────────────────────────────────────────

CP_BASE="${ONBJP_CP_BASE:-http://localhost:4100}"
BOOT_BUDGET="${ONBJP_BOOT_BUDGET:-240}"
IDENTITY_BUDGET="${ONBJP_IDENTITY_BUDGET:-300}"
CONFIG_JSON="$HOME/.config/barkpark/config.json"

TS="$(date -u +%y%m%d%H%M%S)"
JOURNEY_EMAIL="onbjp-$TS@journey-proof.invalid"

MODE="run"
ARG2="${2:-}"
case "${1:-}" in
  "")                 MODE="run" ;;
  --plan)             MODE="plan" ;;
  --negctl)           MODE="negctl" ;;
  --guard-probe)      MODE="guard"; [ -n "$ARG2" ] || { printf '%s: --guard-probe needs a url\n' "$SELF" >&2; exit 3; } ;;
  --scan-transcript)  MODE="scan";  [ -n "$ARG2" ] || { printf '%s: --scan-transcript needs a file\n' "$SELF" >&2; exit 3; } ;;
  --leg)              MODE="leg";   [ -n "$ARG2" ] || { printf '%s: --leg needs a name (windows|installer-ps1|paid-instance|mcp-instance)\n' "$SELF" >&2; exit 3; } ;;
  -h|--help)          sed -n '3,161p' "$0"; exit 0 ;;
  *) printf '%s: unknown argument %s (try --help)\n' "$SELF" "${1:-}" >&2; exit 3 ;;
esac

# ── output helpers (the pds-pull-proof dialect) ──────────────────────────────

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }

N_PASS=0; N_ABORT=0; N_FAIL=0
pass()  { N_PASS=$((N_PASS + 1));  printf '  PASS   %-3s %s\n' "$1" "$2"; }
abort() { N_ABORT=$((N_ABORT + 1)); printf '  ABORT  %-3s %s\n' "$1" "$2"; printf '         %s\n' "$3"; }
fail()  { N_FAIL=$((N_FAIL + 1));  printf '  FAIL   %-3s %s\n' "$1" "$2"; }

head_rung() { printf '\n'; rule; printf 'RUNG %s — %s\n' "$1" "$2"; rule; }

R_FAILS=0
efail() { R_FAILS=$((R_FAILS + 1)); say "      ASSERT-FAIL: $*"; }
rung_seal() { # n summary — FAIL+exit if any efail fired, else PASS and reset
  if [ "$R_FAILS" -gt 0 ]; then
    fail "$1" "$2 — $R_FAILS assertion(s) failed (see the ASSERT-FAIL lines above)"
    exit 1
  fi
  pass "$1" "$2"
}

now_epoch() { python3 -c 'import time; print("%.3f" % time.time())'; }
fsub() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a - b}'; }

# ── THE LOCALITY GUARD (the safety seam — negctl-proven) ─────────────────────
#
# cloud/accounts.ex has NO delete_user: a register against a non-local host
# creates a PERMANENT account. The guard extracts the host from the target URL
# and allows ONLY localhost / 127.0.0.1 / ::1. It runs BEFORE any side effect
# (before mktemp, before the tee re-exec, before any network call) and its
# refusal is exit 3 — deliberate and loud, never a silent downgrade.

guard_host_of() { # url -> lowercased hostname (or empty on garbage)
  python3 -c '
import sys
from urllib.parse import urlsplit
try:
    h = urlsplit(sys.argv[1]).hostname or ""
except Exception:
    h = ""
print(h.lower())' "$1"
}

guard_local() { # url -> 0 iff the host is local
  case "$(guard_host_of "$1")" in
    localhost|127.0.0.1|::1) return 0 ;;
    *) return 1 ;;
  esac
}

refuse_nonlocal() { # url — print the refusal and exit 3 (never returns)
  say "REFUSED: $1 is not a local control plane (host '$(guard_host_of "$1")')."
  say "REFUSED: the fresh-register leg creates an account that CANNOT be deleted"
  say "REFUSED: (cloud/accounts.ex has no delete_user — a prod account is permanent)."
  say "REFUSED: this rig registers ONLY against localhost / 127.0.0.1 / ::1 —"
  say "REFUSED: never api.barkpark.cloud, never any remote host. Nothing was created."
  exit 3
}

# ═════════════════════════════════════════════════════════════════════════════
# --guard-probe <url> — just the guard: ALLOWED (0) or REFUSED (3). No side
# effects: no mktemp, no network, no config reads.
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "guard" ]; then
  if guard_local "$ARG2"; then
    say "ALLOWED: $ARG2 (host '$(guard_host_of "$ARG2")' is local) — the register leg may target it"
    exit 0
  fi
  refuse_nonlocal "$ARG2"
fi

# ═════════════════════════════════════════════════════════════════════════════
# --plan — every rung, its assert, the safety law. Strictly side-effect-free:
# no mktemp, no network, no config reads — this mode only prints.
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "plan" ]; then
  rule
  say "ONBOARDING IDENTITY-TRANSACTION PROOF — PLAN (no side effects: no mktemp,"
  say "no network, no config reads; this mode only prints)"
  rule
  say "tree:      $REPO_ROOT"
  say "target:    $CP_BASE (the LOCALLY-BOOTED cloud control plane — Bandit+Plug,"
  say "           not Phoenix; dev port FIXED 4100, PORT env is prod-only)"
  say "journey:   $JOURNEY_EMAIL (fresh per run; password minted in-process, never printed)"
  say "isolation: every bp call runs under an isolated XDG_CONFIG_HOME — the operator's"
  say "           real ~/.config/barkpark is never read, never written"
  say "budgets:   boot ${BOOT_BUDGET}s · identity leg ${IDENTITY_BUDGET}s (verification measured 0.32s)"
  say "outcomes:  PASS / ABORT / FAIL — no silent skip. Exit 0/2/1 (+3 usage or refusal)."
  say ""
  say "THE SAFETY LAW (locality guard — negctl-proven):"
  say "  · cloud/accounts.ex has NO delete_user: an account registered against a"
  say "    non-local host is PERMANENT. The fresh-register leg HARD-REFUSES every"
  say "    target whose host is not localhost/127.0.0.1/::1 — api.barkpark.cloud"
  say "    by name, and every other remote host with it — exit 3, BEFORE any"
  say "    side effect. --negctl proves the refusal fires AND that localhost"
  say "    passes (the guard can pass, so its refusal is not vacuous)."
  say ""
  say "RUNGS (LIVE):"
  say "  0  PRECONDITION — ABORT-only: the locality guard first; curl/python3/go/mix"
  say "     on PATH; postgres accepting on localhost:5432; cloud/mix.exs present;"
  say "     fresh bp builds from ./cmd/barkpark into the workdir."
  say "  1  BOOT — mix deps.get + ecto.create + ecto.migrate + mix run --no-halt"
  say "     (backgrounded, own process group); poll GET /v1/auth/oauth/providers"
  say "     until JSON answers (<= ${BOOT_BUDGET}s, else ABORT with the CP log tail);"
  say "     anon GET /v1/me must 401 (the auth gate is live). An already-serving CP"
  say "     on 4100 is REUSED and named; a non-CP squatter is an ABORT."
  say "  2  IDENTITY (wall-clocked, <= ${IDENTITY_BUDGET}s) — the one transaction:"
  say "     · POST /v1/auth/register {$JOURNEY_EMAIL} -> 201 {token, team_id}"
  say "     · bp login --url $CP_BASE --device-start -> {device_code, user_code}"
  say "       (envelope captured to a file, printed MASKED — codes never hit the transcript)"
  say "     · bp login --device-poll <code> -> {\"status\":\"pending\"}, non-zero exit"
  say "     · curl POST /v1/auth/device/approve (Bearer session) {user_code} -> 200 {ok:true}"
  say "     · bp login --device-poll <code> -> exit 0, {ok, cloud_url, team_id};"
  say "       the cloud_token lands ONLY in the isolated config"
  say "     · REPLAY-BURN: the same device_code polls again -> expired_or_invalid,"
  say "       non-zero exit (a burned code stays burned)"
  say "     · RE-REGISTER: same email + same VALID password -> 409 {error: email_taken}"
  say "       (the enumeration gate 409s only for a valid password — the honest signal)"
  say "  3  RECEIPT — one receipt, three surfaces, all agreeing:"
  say "     · GET /v1/me (CLI-minted bearer): user.email + team.id match; onboarding"
  say "       carries non-empty steps[] of {key,done} — printed key by key"
  say "     · bp whoami -o json: cloud.logged_in true, cloud.url + cloud.team match"
  say "     · bp doctor --onboarding -o json: cloud_session {present,url,team} matches"
  say "  4  TRANSCRIPT-SCAN — the run's own tee'd transcript is scanned for the"
  say "     session token, cloud_token, password, device_code, anthropic-key prefix:"
  say "     ZERO hits or FAIL (--negctl seeds a fake bearer to prove the scanner fires)."
  say "  5  NAMED OUT-OF-SUBSTRATE LEGS — never silently absorbed:"
  say "     · --leg windows        needs a Windows host (this rig is POSIX-only)"
  say "     · --leg installer-ps1  needs Windows PowerShell for install-cli.ps1"
  say "     · --leg paid-instance  needs paid-plan credentials + a billing-enabled CP"
  say "     · --leg mcp-instance   needs a provisioned instance for the read-only MCP call"
  say "     each ABORTs honestly, naming its substrate — run one to see."
  say "  6  TEARDOWN — kill the booted CP (skipped when reused / ONBJP_KEEP_CP=1);"
  say "     transcript kept (path printed); workdir removed; dev DB throwaway"
  say "     (reset: cd cloud && mix ecto.drop)."
  say ""
  say "  --negctl (no boot, no register): guard fires on api.barkpark.cloud + a raw"
  say "  non-local host + guerrilla; guard passes localhost; the FULL LIVE entry"
  say "  pointed at prod refuses before RUNG 1 with zero writes; the transcript"
  say "  scanner flags a seeded fake bearer and passes a clean file."
  say ""
  say "  --scan-transcript <file>: config bearers (~/.config/barkpark), raw"
  say "  raw bearer-header prints, the anthropic key prefix — ZERO hits or no commit."
  rule
  say "Run it:  $0            (the proof — LIVE: boots + proves + tears down)"
  say "         $0 --negctl   (the control that must fire — free)"
  rule
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# --scan-transcript — the pre-commit token scan (local reads only, no network)
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "scan" ]; then
  TRANSCRIPT_TARGET="$ARG2"
  [ -r "$TRANSCRIPT_TARGET" ] || die "cannot read $TRANSCRIPT_TARGET"
  command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"
  HITS=0
  scan_value() { # label value — grep -F the literal value; masked report
    label="$1"; v="$2"
    [ -n "$v" ] && [ "${#v}" -ge 8 ] || return 0
    n="$(grep -cF -- "$v" "$TRANSCRIPT_TARGET" 2>/dev/null || true)"
    n="${n:-0}"
    if [ "$n" -gt 0 ]; then
      HITS=$((HITS + n))
      say "  HIT    $label (len ${#v}) appears $n time(s) — DO NOT COMMIT"
    else
      say "  clean  $label (len ${#v}) — 0 occurrences"
    fi
  }
  scan_pattern() { # label ERE
    label="$1"; pat="$2"
    n="$(grep -cE -- "$pat" "$TRANSCRIPT_TARGET" 2>/dev/null || true)"
    n="${n:-0}"
    if [ "$n" -gt 0 ]; then
      HITS=$((HITS + n))
      say "  HIT    $label appears $n time(s) — DO NOT COMMIT"
    else
      say "  clean  $label — 0 occurrences"
    fi
  }
  say "token-scan of $TRANSCRIPT_TARGET"
  if [ -r "$CONFIG_JSON" ]; then
    scan_value "guerrilla admin bearer (config .token)" \
      "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token") or "")' "$CONFIG_JSON")"
    scan_value "cloud bearer (config .cloud_token)" \
      "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cloud_token") or "")' "$CONFIG_JSON")"
  fi
  # Labels avoid the literal patterns (sentinel-free reports): a transcript
  # that CONTAINS a scan report must still re-scan clean.
  scan_pattern "raw bearer-header print" 'Authorization: ''Bearer [A-Za-z0-9._~+/=-]{8,}'
  scan_pattern "anthropic key prefix" 'sk-''ant'
  if [ "$HITS" -gt 0 ]; then
    say "TOKEN-SCAN: $HITS hit(s) — the transcript is NOT committable."
    exit 1
  fi
  say "TOKEN-SCAN: zero hits — the transcript is committable."
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# --leg <name> — the NAMED out-of-substrate legs. Each ABORTs honestly, naming
# the substrate it needs. Never silently absorbed, never faked green.
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "leg" ]; then
  case "$ARG2" in
    windows)
      head_rung W "WINDOWS ONBOARDING LEG — named, not runnable here"
      abort W "substrate:windows-host" "this rig runs on $(uname -s); the Windows onboarding journey (bp.exe login → device flow → receipt) needs a real Windows host. The leg exists and is NAMED — it is not absorbed into the POSIX run."
      exit 2 ;;
    installer-ps1)
      head_rung I "INSTALL-CLI.PS1 LEG — named, not runnable here"
      abort I "substrate:powershell" "install-cli.ps1 needs Windows PowerShell; this host has no PowerShell substrate. The installer leg is NAMED here, never silently absorbed."
      exit 2 ;;
    paid-instance)
      head_rung P "PAID-INSTANCE PROVISIONING LEG — named, not runnable here"
      abort P "substrate:billing-credentials" "provisioning a paid instance needs a billing-enabled control plane + paid-plan credentials + real spend authorization — none of which this local throwaway rig carries. The leg is NAMED, not absorbed."
      exit 2 ;;
    mcp-instance)
      head_rung M "MCP-INSTANCE READ-ONLY CALL LEG — named, not runnable here"
      abort M "substrate:provisioned-instance" "the read-only MCP tool call needs a provisioned content instance bound to the session (optional stretch: a local api/ Phoenix boot as second substrate). This rig boots only the cloud/ control plane. The leg is NAMED, not absorbed."
      exit 2 ;;
    *) die "unknown leg '$ARG2' (windows|installer-ps1|paid-instance|mcp-instance)" ;;
  esac
fi

# ═════════════════════════════════════════════════════════════════════════════
# --negctl — no boot, no register, no spend: the locality guard and the
# transcript scanner must both PROVABLY fire (a check that cannot fail proves
# nothing — PDS-D20 inherited).
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "negctl" ]; then
  rule
  say "ONBOARDING JOURNEY PROOF — NEGATIVE CONTROLS (no boot, no register, no writes"
  say "beyond two temp files for the scanner control)"
  rule

  head_rung N0 "GUARD FIRES — api.barkpark.cloud must be REFUSED (exit 3)"
  OUT="$("$0" --guard-probe https://api.barkpark.cloud 2>&1)" && RC=0 || RC=$?
  say "$OUT" | sed 's/^/      /'
  if [ "$RC" -ne 3 ]; then efail "expected exit 3, got $RC"; fi
  case "$OUT" in *REFUSED*) : ;; *) efail "the refusal text did not print" ;; esac
  rung_seal N0 "the locality guard refuses api.barkpark.cloud (exit 3, REFUSED printed)"

  head_rung N1 "GUARD FIRES — every non-local host, not just the named one"
  for U in https://guerrilla.barkpark.cloud http://157.180.90.121:4100 http://barkpark.internal:4100; do
    RC=0; OUT="$("$0" --guard-probe "$U" 2>&1)" || RC=$?
    if [ "$RC" -ne 3 ]; then efail "$U: expected exit 3, got $RC"; else info "$U → REFUSED (exit 3)"; fi
  done
  rung_seal N1 "the guard refuses guerrilla, a raw IP, and an internal name alike"

  head_rung N2 "GUARD PASSES LOCALHOST — the refusal is not vacuous"
  for U in http://localhost:4100 http://127.0.0.1:4100; do
    RC=0; OUT="$("$0" --guard-probe "$U" 2>&1)" || RC=$?
    if [ "$RC" -ne 0 ]; then efail "$U: expected exit 0 (ALLOWED), got $RC"; else info "$U → ALLOWED (exit 0)"; fi
  done
  rung_seal N2 "localhost/127.0.0.1 are ALLOWED — the guard can pass, so its refusal means something"

  head_rung N3 "FULL LIVE ENTRY vs PROD — the run itself must refuse BEFORE RUNG 1"
  RC=0; OUT="$(ONBJP_CP_BASE=https://api.barkpark.cloud "$0" 2>&1)" || RC=$?
  say "$OUT" | sed 's/^/      /'
  if [ "$RC" -ne 3 ]; then efail "expected exit 3 from the LIVE entry pointed at prod, got $RC"; fi
  case "$OUT" in *REFUSED*) : ;; *) efail "the LIVE entry did not print the refusal" ;; esac
  case "$OUT" in *"RUNG 1"*) efail "the LIVE entry reached RUNG 1 despite a prod target — the guard is NOT pre-side-effect" ;; *) : ;; esac
  rung_seal N3 "the LIVE entry pointed at prod refuses before any rung — zero writes"

  head_rung N4 "SCANNER FIRES — a seeded fake bearer must be flagged; a clean file must pass"
  SCANDIR="$(mktemp -d "${TMPDIR:-/tmp}/onbjp-negctl.XXXXXX")"
  printf 'harmless line\ncurl -H "Authorization: Bearer FAKEFAKE0123456789abcdef" …\nsk-ant-api03-fake\n' > "$SCANDIR/dirty"
  printf 'harmless line\nPASS 2 identity leg 0.32s\n' > "$SCANDIR/clean"
  RC=0; "$0" --scan-transcript "$SCANDIR/dirty" >/dev/null 2>&1 || RC=$?
  if [ "$RC" -ne 1 ]; then efail "dirty transcript: expected exit 1 (HIT), got $RC"; else info "dirty transcript → HIT (exit 1) — the scanner fires"; fi
  RC=0; "$0" --scan-transcript "$SCANDIR/clean" >/dev/null 2>&1 || RC=$?
  if [ "$RC" -ne 0 ]; then efail "clean transcript: expected exit 0, got $RC"; else info "clean transcript → zero hits (exit 0)"; fi
  rm -rf "$SCANDIR"
  rung_seal N4 "the transcript scanner demonstrably fires on a fake bearer and passes a clean file"

  say ""
  rule
  say "VERDICT — negctl: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
  say "NEGCTL OK — the locality refusal and the token scanner are real instruments:"
  say "both fire when they must and pass when they should."
  rule
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# LIVE — the proof. THE GUARD RUNS FIRST: before the tee re-exec, before
# mktemp, before any network byte.
# ═════════════════════════════════════════════════════════════════════════════

guard_local "$CP_BASE" || refuse_nonlocal "$CP_BASE"

command -v curl    >/dev/null 2>&1 || die "curl not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

# Tee re-exec: the run records its OWN transcript so RUNG 4 can scan it. The
# child re-runs this script with the same env; the guard above already held.
if [ -z "${ONBJP_TEE_CHILD:-}" ]; then
  TRANSCRIPT="${ONBJP_TRANSCRIPT:-${TMPDIR:-/tmp}/onbjp-run-$TS.transcript}"
  STF="${TMPDIR:-/tmp}/onbjp-status.$$"
  ( set +e
    ONBJP_TEE_CHILD=1 ONBJP_TRANSCRIPT="$TRANSCRIPT" "$0"
    echo "$?" > "$STF"
  ) 2>&1 | tee "$TRANSCRIPT"
  RC="$(cat "$STF" 2>/dev/null || echo 1)"; rm -f "$STF"
  exit "$RC"
fi
TRANSCRIPT="${ONBJP_TRANSCRIPT:?tee child needs ONBJP_TRANSCRIPT}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/onbjp.XXXXXX")"
XDG_ISO="$WORKDIR/xdg"
mkdir -p "$XDG_ISO"
BP="$WORKDIR/bp"

# Secrets live ONLY in these vars (and the isolated config file); they are
# never echoed. RUNG 4 greps the transcript for each literal to prove it.
SESSION_TOKEN=""; CLOUD_TOKEN=""; DEVICE_CODE=""; USER_CODE=""
JOURNEY_PASSWORD="$(python3 -c 'import secrets; print("Onbjp-" + secrets.token_urlsafe(18))')"
TEAM_ID=""

CP_PID=""; CP_REUSED=""

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  set +e
  if [ -n "$CP_PID" ] && [ -z "$CP_REUSED" ] && [ -z "${ONBJP_KEEP_CP:-}" ]; then
    say "cleanup: stopping the booted control plane (pgid $CP_PID)"
    kill -TERM -- "-$CP_PID" 2>/dev/null || kill -TERM "$CP_PID" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$CP_PID" 2>/dev/null || true
  fi
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}
trap cleanup EXIT

# bp under the ISOLATED config — the operator's real ~/.config/barkpark is
# never read, never written. Stdout goes to the given file, NOT the transcript
# (envelopes carry device_code / could carry tokens).
bp_iso() { # outfile args… -> exit code; envelope written to outfile
  OUTF="$1"; shift
  RCV=0
  XDG_CONFIG_HOME="$XDG_ISO" BP_COLOR=none "$BP" "$@" >"$OUTF" 2>"$WORKDIR/bp-stderr.log" || RCV=$?
  return "$RCV"
}

jfield() { # file key… -> nested value or "" (never raises)
  python3 - "$@" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    print(""); sys.exit(0)
for k in sys.argv[2:]:
    if isinstance(d, dict):
        d = d.get(k)
    else:
        d = None
if d is None:
    print("")
elif isinstance(d, bool):
    print("true" if d else "false")
elif isinstance(d, (dict, list)):
    print(json.dumps(d, sort_keys=True))
else:
    print(d)
PYEOF
}

curl_code() { # method url outfile [bearer] [json-body] -> http code
  M="$1"; U="$2"; O="$3"; B="${4:-}"; D="${5:-}"
  if [ -n "$B" ] && [ -n "$D" ]; then
    curl -sS --max-time 25 -o "$O" -w '%{http_code}' -X "$M" "$U" \
      -H "Authorization: Bearer $B" -H 'Content-Type: application/json' -d "$D" 2>/dev/null | tr -dc '0-9' | tail -c 3
  elif [ -n "$D" ]; then
    curl -sS --max-time 25 -o "$O" -w '%{http_code}' -X "$M" "$U" \
      -H 'Content-Type: application/json' -d "$D" 2>/dev/null | tr -dc '0-9' | tail -c 3
  elif [ -n "$B" ]; then
    curl -sS --max-time 25 -o "$O" -w '%{http_code}' -X "$M" "$U" \
      -H "Authorization: Bearer $B" 2>/dev/null | tr -dc '0-9' | tail -c 3
  else
    curl -sS --max-time 25 -o "$O" -w '%{http_code}' -X "$M" "$U" 2>/dev/null | tr -dc '0-9' | tail -c 3
  fi
}

say "# onboarding-journey-proof — transcript"
say "# tree: $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)) · host: $(uname -s | tr '[:upper:]' '[:lower:]') · $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "# command: scripts/onboarding-journey-proof.sh"
say ""
rule
say "ONBOARDING IDENTITY-TRANSACTION PROOF — LIVE — run $RUN_ID"
rule
say "tree:        $REPO_ROOT"
say "target:      $CP_BASE (locality-guarded: register only ever hits a local host)"
say "journey:     $JOURNEY_EMAIL"
say "isolation:   XDG_CONFIG_HOME=$XDG_ISO (the real ~/.config/barkpark untouched)"
say "transcript:  $TRANSCRIPT (self-scanned at RUNG 4, kept after the run)"
say "budgets:     boot ${BOOT_BUDGET}s · identity ${IDENTITY_BUDGET}s"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 0 "PRECONDITION — ABORT-only (substrate, never a verdict)"
# ─────────────────────────────────────────────────────────────────────────────

for T in go mix; do
  if ! command -v "$T" >/dev/null 2>&1; then
    abort 0 "env:$T-missing" "$T is not on PATH — the rig cannot build bp / boot the CP. Nothing created."
    exit 2
  fi
done
if command -v pg_isready >/dev/null 2>&1; then
  if ! pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
    abort 0 "env:postgres-down" "postgres is not accepting on localhost:5432 — start it, then re-run. Nothing created."
    exit 2
  fi
  info "postgres: accepting on localhost:5432"
else
  info "pg_isready not on PATH — postgres reachability will surface at ecto.create"
fi
if [ ! -f "$REPO_ROOT/cloud/mix.exs" ]; then
  abort 0 "env:no-cloud-tree" "$REPO_ROOT/cloud/mix.exs is missing — not a barkpark tree with the control plane"
  exit 2
fi
# `cc` on PATH can be shadowed by a non-compiler (live-hit on this rig: an
# agent-CLI wrapper that even answers --version cleanly). The CP's NIF deps
# (bcrypt_elixir via elixir_make) need a REAL C compiler — sniff the version
# banner (clang/gcc/FSF), and when the PATH cc is an impostor, front a shim
# dir so the LITERAL `cc` the NIF Makefiles invoke resolves to the system one
# (exporting CC alone loses: the Makefiles hardcode `cc`).
if ! cc --version 2>/dev/null | grep -qiE 'clang|gcc|free software' && [ -x /usr/bin/cc ]; then
  mkdir -p "$WORKDIR/ccshim"
  ln -sf /usr/bin/cc "$WORKDIR/ccshim/cc"
  PATH="$WORKDIR/ccshim:$PATH"; export PATH
  CC=/usr/bin/cc; export CC
  info "cc on PATH is not a compiler — shimmed cc→/usr/bin/cc (PATH front) for the NIF builds"
fi
info "building bp: CGO_ENABLED=0 go build -o \$WORKDIR/bp ./cmd/barkpark …"
# CGO_ENABLED=0: bp is pure Go — building without cgo needs no C toolchain and
# dodges hosts where `cc` on PATH is not a compiler (a live-hit on this rig).
if ! (cd "$REPO_ROOT" && CGO_ENABLED=0 go build -o "$BP" ./cmd/barkpark) >"$WORKDIR/bp-build.log" 2>&1; then
  sed 's/^/      /' "$WORKDIR/bp-build.log" | tail -20
  abort 0 "env:bp-build-failed" "go build ./cmd/barkpark failed — see above. Nothing created."
  exit 2
fi
pass 0 "substrate holds: guard passed $CP_BASE · go+mix+postgres present · bp built fresh"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 1 "BOOT — the local control plane (Bandit+Plug; mix run --no-halt; port 4100)"
# ─────────────────────────────────────────────────────────────────────────────

probe_cp() { # -> 0 iff the CP answers the providers read with JSON
  O="$WORKDIR/probe.json"
  C="$(curl_code GET "$CP_BASE/v1/auth/oauth/providers" "$O")" || true
  [ "${C:-000}" = "200" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$O" 2>/dev/null
}

if probe_cp; then
  CP_REUSED=1
  info "port already serving a control plane at $CP_BASE — REUSING it (nothing to"
  info "boot, nothing to kill at teardown; the journey writes only its own fresh user)"
else
  if curl -sS --max-time 3 -o /dev/null "$CP_BASE/" 2>/dev/null; then
    abort 1 "env:port-squatted" "something answers on $CP_BASE but it is not a Barkpark CP (the providers read did not answer JSON) — free the port, then re-run"
    exit 2
  fi
  info "mix deps.get … (cloud/)"
  if ! (cd "$REPO_ROOT/cloud" && mix deps.get) >"$WORKDIR/deps.log" 2>&1; then
    sed 's/^/      /' "$WORKDIR/deps.log" | tail -15
    abort 1 "env:deps-get-failed" "mix deps.get failed in cloud/ — see above. Nothing booted."
    exit 2
  fi
  info "mix ecto.create + ecto.migrate … (throwaway dev DB barkpark_cloud_dev)"
  if ! (cd "$REPO_ROOT/cloud" && mix ecto.create && mix ecto.migrate) >"$WORKDIR/ecto.log" 2>&1; then
    sed 's/^/      /' "$WORKDIR/ecto.log" | tail -20
    abort 1 "env:ecto-failed" "mix ecto.create/migrate failed — see above (a dep/NIF compile? postgres creds? stale schema?). Nothing booted."
    exit 2
  fi
  info "mix run --no-halt … (backgrounded, own process group; log \$WORKDIR/cp.log)"
  (cd "$REPO_ROOT/cloud" && exec mix run --no-halt) >"$WORKDIR/cp.log" 2>&1 &
  CP_PID=$!
  BOOT_T0="$(now_epoch)"
  BOOTED=""
  while :; do
    if probe_cp; then BOOTED=1; break; fi
    if ! kill -0 "$CP_PID" 2>/dev/null; then break; fi
    EL="$(fsub "$(now_epoch)" "$BOOT_T0")"
    LC_ALL=C awk -v e="$EL" -v b="$BOOT_BUDGET" 'BEGIN{exit !(e >= b)}' && break
    sleep 2
  done
  if [ -z "$BOOTED" ]; then
    say "      cp.log tail:"
    tail -40 "$WORKDIR/cp.log" 2>/dev/null | sed 's/^/      /'
    abort 1 "env:boot-timeout" "the CP did not answer $CP_BASE/v1/auth/oauth/providers within ${BOOT_BUDGET}s — an ABORT finding on the boot substrate, not a verdict on the identity transaction"
    exit 2
  fi
  info "CP serving after $(fsub "$(now_epoch)" "$BOOT_T0")s"
fi

# The auth gate must be LIVE: an anonymous /v1/me is a 401, never a 200.
ME_ANON="$WORKDIR/me-anon.json"
C="$(curl_code GET "$CP_BASE/v1/me" "$ME_ANON")" || true
if [ "${C:-000}" != "401" ]; then
  efail "anon GET /v1/me answered ${C:-000}, expected 401 — the auth gate is not gating"
fi
info "anon GET /v1/me → ${C:-000} (the auth gate is live)"
rung_seal 1 "control plane serving at $CP_BASE${CP_REUSED:+ (reused)} — providers read JSON, anon /v1/me 401"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 2 "IDENTITY — one wall-clocked transaction (budget ${IDENTITY_BUDGET}s)"
# ─────────────────────────────────────────────────────────────────────────────

ID_T0="$(now_epoch)"

# 2a — fresh register → 201 {token, team_id}
REG="$WORKDIR/register.json"
C="$(curl_code POST "$CP_BASE/v1/auth/register" "$REG" "" "{\"email\":\"$JOURNEY_EMAIL\",\"password\":\"$JOURNEY_PASSWORD\"}")" || true
SESSION_TOKEN="$(jfield "$REG" token)"
TEAM_ID="$(jfield "$REG" team_id)"
if [ "${C:-000}" != "201" ] || [ -z "$SESSION_TOKEN" ] || [ -z "$TEAM_ID" ]; then
  say "      body: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("token",None); print(json.dumps(d))' "$REG" 2>/dev/null || echo unparseable)"
  efail "register answered ${C:-000} (token present: $([ -n "$SESSION_TOKEN" ] && echo yes || echo no)) — expected 201 {token, team_id}"
  rung_seal 2 "identity transaction"
fi
info "2a register $JOURNEY_EMAIL → 201 (session token len ${#SESSION_TOKEN}, never printed; team_id $TEAM_ID)"

# 2b — device start via the shipped CLI (envelope to file — codes stay off the transcript)
DS="$WORKDIR/device-start.json"
if ! bp_iso "$DS" login --url "$CP_BASE" --device-start -o json; then
  sed 's/^/      /' "$WORKDIR/bp-stderr.log" | tail -5
  efail "bp login --device-start exited non-zero"
  rung_seal 2 "identity transaction"
fi
DEVICE_CODE="$(jfield "$DS" device_code)"
USER_CODE="$(jfield "$DS" user_code)"
if [ -z "$DEVICE_CODE" ] || [ -z "$USER_CODE" ]; then
  efail "the --device-start envelope carried no device_code/user_code"
  rung_seal 2 "identity transaction"
fi
info "2b bp login --device-start → device_code (len ${#DEVICE_CODE}) + user_code (len ${#USER_CODE}) — both masked"

# 2c — one poll BEFORE approval: pending, non-zero exit
DP="$WORKDIR/device-poll-1.json"
RCP=0; bp_iso "$DP" login --url "$CP_BASE" --device-poll "$DEVICE_CODE" -o json || RCP=$?
ST="$(jfield "$DP" status)"
if [ "$RCP" -eq 0 ] || [ "$ST" != "pending" ]; then
  efail "pre-approval poll: expected status=pending + non-zero exit, got status='$ST' exit=$RCP"
else
  info "2c poll before approval → {\"status\":\"pending\"}, exit $RCP (the loop keeps polling)"
fi

# 2d — headless approve: the session bearer approves its own user_code
AP="$WORKDIR/approve.json"
C="$(curl_code POST "$CP_BASE/v1/auth/device/approve" "$AP" "$SESSION_TOKEN" "{\"user_code\":\"$USER_CODE\"}")" || true
if [ "${C:-000}" != "200" ] || [ "$(jfield "$AP" ok)" != "true" ]; then
  say "      body: $(head -c 200 "$AP" | tr -d '\n')"
  efail "device approve answered ${C:-000}, expected 200 {ok:true}"
else
  info "2d approve (Bearer session, headless) → 200 {ok:true}"
fi

# 2e — poll AFTER approval: the token mints, exit 0, envelope {ok,cloud_url,team_id}
DP2="$WORKDIR/device-poll-2.json"
RCP=0; bp_iso "$DP2" login --url "$CP_BASE" --device-poll "$DEVICE_CODE" -o json || RCP=$?
if [ "$RCP" -ne 0 ] || [ "$(jfield "$DP2" ok)" != "true" ]; then
  efail "post-approval poll: expected exit 0 + {ok:true}, got exit=$RCP ok='$(jfield "$DP2" ok)'"
else
  info "2e poll after approval → exit 0, {ok:true, cloud_url $(jfield "$DP2" cloud_url), team_id $(jfield "$DP2" team_id)}"
fi
if [ "$(jfield "$DP2" team_id)" != "$TEAM_ID" ]; then
  efail "the device-minted session's team_id '$(jfield "$DP2" team_id)' != the registered team '$TEAM_ID'"
fi
ISO_CFG="$XDG_ISO/barkpark/config.json"
CLOUD_TOKEN="$(jfield "$ISO_CFG" cloud_token)"
if [ -z "$CLOUD_TOKEN" ]; then
  efail "no cloud_token landed in the ISOLATED config ($ISO_CFG) — the CLI did not persist the session"
else
  info "   cloud_token persisted ONLY to the isolated config (len ${#CLOUD_TOKEN}, never printed)"
fi

# 2f — REPLAY-BURN: the same device_code must now be dead
DP3="$WORKDIR/device-poll-3.json"
RCP=0; bp_iso "$DP3" login --url "$CP_BASE" --device-poll "$DEVICE_CODE" -o json || RCP=$?
ERRTXT="$(jfield "$DP3" error)"
if [ "$RCP" -eq 0 ]; then
  efail "replay-burn: a SECOND poll of the same device_code exited 0 — a burned code re-minted"
else
  case "$ERRTXT" in
    *expired_or_invalid*|*expired*|*invalid*) info "2f replay-burn → non-zero exit, error names expired_or_invalid (a burned code stays burned)" ;;
    *) efail "replay-burn: non-zero exit but the envelope named '$ERRTXT', not expired_or_invalid" ;;
  esac
fi

# 2g — RE-REGISTER: same email + same VALID password → 409 email_taken
RR="$WORKDIR/re-register.json"
C="$(curl_code POST "$CP_BASE/v1/auth/register" "$RR" "" "{\"email\":\"$JOURNEY_EMAIL\",\"password\":\"$JOURNEY_PASSWORD\"}")" || true
if [ "${C:-000}" != "409" ] || [ "$(jfield "$RR" error)" != "email_taken" ]; then
  say "      body: $(head -c 200 "$RR" | tr -d '\n')"
  efail "re-register answered ${C:-000} '$(jfield "$RR" error)' — expected 409 email_taken (the honest duplicate signal)"
else
  info "2g re-register (same email, valid password) → 409 {error: email_taken}"
fi

ID_WALL="$(fsub "$(now_epoch)" "$ID_T0")"
say ""
info "IDENTITY LEG WALL CLOCK: ${ID_WALL}s (budget ${IDENTITY_BUDGET}s; server-side verification measured 0.32s)"
if ! LC_ALL=C awk -v w="$ID_WALL" -v b="$IDENTITY_BUDGET" 'BEGIN{exit !(w < b)}'; then
  efail "the identity leg took ${ID_WALL}s — over the ${IDENTITY_BUDGET}s budget"
fi
rung_seal 2 "the identity transaction: register 201 → device pending → approve → token → replay-burn → 409 email_taken, in ${ID_WALL}s"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 3 "RECEIPT — one receipt, three surfaces (/v1/me · bp whoami · bp doctor)"
# ─────────────────────────────────────────────────────────────────────────────

ME="$WORKDIR/me.json"
C="$(curl_code GET "$CP_BASE/v1/me" "$ME" "$CLOUD_TOKEN")" || true
if [ "${C:-000}" != "200" ]; then
  efail "GET /v1/me with the CLI-minted bearer answered ${C:-000}, expected 200"
else
  ME_EMAIL="$(jfield "$ME" user email)"
  ME_TEAM="$(jfield "$ME" team id)"
  [ "$ME_EMAIL" = "$JOURNEY_EMAIL" ] || efail "/v1/me user.email '$ME_EMAIL' != '$JOURNEY_EMAIL'"
  [ "$ME_TEAM" = "$TEAM_ID" ] || efail "/v1/me team.id '$ME_TEAM' != registered team '$TEAM_ID'"
  info "GET /v1/me → 200: user.email=$ME_EMAIL · team.id=$ME_TEAM · confirmed=$(jfield "$ME" user confirmed)"
  STEPS_N="$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
ob = d.get("onboarding") or {}
steps = ob.get("steps") or []
ok = all(isinstance(s, dict) and "key" in s and "done" in s for s in steps)
print(len(steps) if ok and steps else 0)' "$ME")"
  if [ "${STEPS_N:-0}" -lt 1 ]; then
    efail "/v1/me onboarding.steps[] is empty or malformed — the receipt does not carry the checklist"
  else
    info "onboarding receipt: $STEPS_N steps —"
    python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
ob = d.get("onboarding") or {}
for s in ob.get("steps") or []:
    print("        step %-24s done=%s" % (s.get("key"), s.get("done")))
print("        completed=%s · last_step=%s" % (ob.get("completed"), ob.get("last_step")))' "$ME"
  fi
fi

WA="$WORKDIR/whoami.json"
if ! bp_iso "$WA" whoami -o json; then
  efail "bp whoami -o json exited non-zero"
else
  W_IN="$(jfield "$WA" cloud logged_in)"
  W_URL="$(jfield "$WA" cloud url)"
  W_TEAM="$(jfield "$WA" cloud team)"
  [ "$W_IN" = "true" ] || efail "bp whoami cloud.logged_in='$W_IN', expected true"
  [ "$W_URL" = "$CP_BASE" ] || efail "bp whoami cloud.url='$W_URL' != '$CP_BASE'"
  [ "$W_TEAM" = "$TEAM_ID" ] || efail "bp whoami cloud.team='$W_TEAM' != '$TEAM_ID'"
  info "bp whoami -o json → cloud {logged_in:$W_IN, url:$W_URL, team:$W_TEAM} — truthful"
fi

DR="$WORKDIR/doctor.json"
RCP=0; bp_iso "$DR" doctor --onboarding -o json || RCP=$?
D_PRES="$(jfield "$DR" cloud_session present)"
D_URL="$(jfield "$DR" cloud_session url)"
D_TEAM="$(jfield "$DR" cloud_session team)"
if [ -z "$D_PRES" ]; then
  sed 's/^/      /' "$WORKDIR/bp-stderr.log" | tail -5
  efail "bp doctor --onboarding -o json carried no cloud_session leg (exit $RCP)"
else
  [ "$D_PRES" = "true" ] || efail "doctor cloud_session.present='$D_PRES', expected true"
  [ "$D_URL" = "$CP_BASE" ] || efail "doctor cloud_session.url='$D_URL' != '$CP_BASE'"
  [ "$D_TEAM" = "$TEAM_ID" ] || efail "doctor cloud_session.team='$D_TEAM' != '$TEAM_ID'"
  info "bp doctor --onboarding → cloud_session {present:$D_PRES, url:$D_URL, team:$D_TEAM} · ok=$(jfield "$DR" ok)"
  info "(overall ok reflects a connected content instance too — this rig binds only the cloud session; the leg under proof is cloud_session, asserted truthful)"
fi
rung_seal 3 "the receipt agrees across /v1/me, bp whoami and bp doctor --onboarding — one identity, one story"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 4 "TRANSCRIPT-SCAN — no bearer ever printed (self-scan of $TRANSCRIPT)"
# ─────────────────────────────────────────────────────────────────────────────

scan_secret() { # label value — the literal must NOT appear in the transcript
  SLABEL="$1"; SV="$2"
  if [ -z "$SV" ] || [ "${#SV}" -lt 8 ]; then info "skip   $SLABEL (absent/short)"; return 0; fi
  SN="$(grep -cF -- "$SV" "$TRANSCRIPT" 2>/dev/null || true)"; SN="${SN:-0}"
  if [ "$SN" -gt 0 ]; then
    efail "$SLABEL (len ${#SV}) appears $SN time(s) in the transcript"
  else
    info "clean  $SLABEL (len ${#SV}) — 0 occurrences"
  fi
}
if [ ! -r "$TRANSCRIPT" ]; then
  efail "the transcript $TRANSCRIPT is unreadable — the self-scan cannot run"
else
  scan_secret "session token (register 201)" "$SESSION_TOKEN"
  scan_secret "cloud_token (CLI-minted)"     "$CLOUD_TOKEN"
  scan_secret "journey password"             "$JOURNEY_PASSWORD"
  scan_secret "device_code"                  "$DEVICE_CODE"
  # The label deliberately avoids the literal pattern: the transcript must not
  # contain its own sentinel, or every post-hoc re-scan flags the report line.
  SKN="$(grep -cE 'sk-''ant' "$TRANSCRIPT" 2>/dev/null || true)"; SKN="${SKN:-0}"
  [ "$SKN" -eq 0 ] && info "clean  anthropic key prefix — 0 occurrences" || efail "anthropic key prefix appears $SKN time(s)"
fi
rung_seal 4 "zero bearers in the transcript — the rig proves the journey without leaking it"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 5 "NAMED OUT-OF-SUBSTRATE LEGS — never silently absorbed"
# ─────────────────────────────────────────────────────────────────────────────

info "these legs exist, are NAMED, and cannot run on this substrate — each is an"
info "ABORT-only rung behind its own flag (run one to see it refuse honestly):"
info "  --leg windows        the Windows onboarding journey (needs a Windows host)"
info "  --leg installer-ps1  install-cli.ps1 (needs Windows PowerShell)"
info "  --leg paid-instance  paid-instance provisioning (needs billing credentials + spend)"
info "  --leg mcp-instance   the read-only MCP call (needs a provisioned instance;"
info "                       stretch: a local api/ Phoenix boot as second substrate)"
pass 5 "four out-of-substrate legs NAMED with their invocations — absorbed nowhere, faked never"

# ─────────────────────────────────────────────────────────────────────────────
head_rung 6 "TEARDOWN — stop the CP, keep the transcript, drop the workdir"
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "$CP_REUSED" ]; then
  info "the CP was reused — nothing to stop (the journey user $JOURNEY_EMAIL remains in the throwaway dev DB)"
elif [ -n "${ONBJP_KEEP_CP:-}" ]; then
  info "ONBJP_KEEP_CP=1 — leaving the CP running (pgid $CP_PID)"
else
  kill -TERM -- "-$CP_PID" 2>/dev/null || kill -TERM "$CP_PID" 2>/dev/null || true
  sleep 1
  if kill -0 "$CP_PID" 2>/dev/null; then kill -KILL -- "-$CP_PID" 2>/dev/null || true; sleep 1; fi
  if kill -0 "$CP_PID" 2>/dev/null; then
    efail "the CP process (pgid $CP_PID) survived TERM+KILL"
  else
    info "CP stopped (pgid $CP_PID)"
  fi
  CP_PID=""
fi
info "dev DB barkpark_cloud_dev is THROWAWAY — reset any time: cd cloud && mix ecto.drop"
info "transcript kept: $TRANSCRIPT (pre-commit re-scan: $0 --scan-transcript $TRANSCRIPT)"
rung_seal 6 "teardown clean — no process left, no bearer on disk outside the removed workdir"

say ""
rule
say "VERDICT — LIVE: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL · identity leg ${ID_WALL}s"
say "THE IDENTITY TRANSACTION HOLDS: one register, one device grant, one receipt —"
say "burned codes stay burned, duplicates answer honestly, and no bearer printed."
rule
exit 0
