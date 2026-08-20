#!/usr/bin/env bash
# preflight-vercel.sh — the Connectors Wave-34 host preflight (charter D267).
# Fast, LOUD, NON-CREATING. Answers ONE question before an operator (or a live
# gate) attempts a real :cloud turn: does THIS host have the four prerequisites a
# turn needs, or will it stall/refuse deep inside cloud-sandbox-runner.mjs?
#
# The four checks, in the order that fails cheapest-first:
#   1. vercel CLI present            — command -v vercel
#   2. vercel authenticated          — vercel whoami            (bogus token ~2.8s)
#   3. sandbox entitlement (scope)   — vercel sandbox list --scope <scope>
#        The entitlement-grade NON-CREATING probe: it round-trips the REAL Sandbox
#        API under the team scope (~3.3s green; a bad scope 403s ~2.2s), strictly
#        closer to what `create` checks than `whoami`. We NEVER run
#        `vercel sandbox create` — the 10-minute cold-start backstop lives at
#        cloud-sandbox-runner.mjs:84 and is exactly the stall this preflight exists
#        to prevent.
#   4. ANTHROPIC_API_KEY set          — honest-refusal (ambient key, D110/D23 —
#        never a run-secret; the isolated turn authenticates Claude with it).
# Each failure prints a LOUD, NAMED line to stderr and exits 1 at the FIRST miss.
#
# PORTABILITY: this script shells NO bare `timeout` — macOS dev boxes have neither
# `timeout` nor `gtimeout`. Non-interactive safety instead comes from redirecting
# each vercel probe's stdin from /dev/null so a would-be prompt gets EOF and the
# CLI fails fast rather than hanging.
#
# OFFLINE SELF-TEST (--self-test): hermetic, sub-second, CI-safe. Generates a fake
# `vercel` on PATH (modes: ok / whoami-fail / sandbox-list-fail) and drives THIS
# script through every leg — all-green, vercel-missing (PATH-hide), auth-fail,
# scope-fail, key-unset — asserting the exit code AND the named failure marker,
# plus a call-log tripwire that `sandbox create` is NEVER invoked. No real Vercel.
#
# CI: .github/workflows/connectors.yml runs `shellcheck -S error` + `--self-test`
# in a NAMED step (the workflow hardcodes proof scripts by name — it never
# glob-discovers scripts/connectors/).
#
# Usage:
#   scripts/connectors/preflight-vercel.sh                 # real preflight, exit 0/1
#   scripts/connectors/preflight-vercel.sh --scope <team>  # override the team scope
#   scripts/connectors/preflight-vercel.sh --self-test     # offline hermetic self-test
#   scripts/connectors/preflight-vercel.sh --help
#
# Charter: .claude/workflows/bp-connectors-charter.md (Wave 34, D267). The
# credentialed LIVE turn stays on connectors-hg-live-isolated-cloud-turn — this
# preflight is the non-creating gate BEFORE it.
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="preflight-vercel.sh"
SCOPE="${CONNECTORS_VERCEL_SCOPE:-guerrilla}"

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors host preflight (D267). NON-CREATING, fast, loud.

  (no flag)         run the four prerequisite checks against THIS host; exit 0 all
                    green, exit 1 (LOUD, named) at the first miss.
  --scope <team>    override the Vercel team scope (default: $SCOPE).
  --self-test       offline hermetic self-test (fake vercel on PATH); no real Vercel.
  -h, --help        this text.

Checks: (1) vercel CLI present, (2) vercel whoami, (3) vercel sandbox list --scope
$SCOPE, (4) ANTHROPIC_API_KEY set. NEVER runs 'vercel sandbox create'.
EOF
}

# ---- the preflight itself -------------------------------------------------
# Each miss: one LOUD line to stderr, tagged [name], then exit 1 immediately.
preflight() {
  if ! command -v vercel >/dev/null 2>&1; then
    echo "PREFLIGHT FAIL [vercel-cli]: the 'vercel' CLI is not on PATH. Install it ('npm i -g vercel') — a :cloud turn cannot provision a sandbox without it." >&2
    return 1
  fi

  if ! vercel whoami </dev/null >/dev/null 2>&1; then
    echo "PREFLIGHT FAIL [vercel-auth]: 'vercel whoami' failed — the CLI is not authenticated. Run 'vercel login' (or export a valid VERCEL_TOKEN) on this host." >&2
    return 1
  fi

  if ! vercel sandbox list --scope "$SCOPE" </dev/null >/dev/null 2>&1; then
    echo "PREFLIGHT FAIL [vercel-sandbox-scope]: 'vercel sandbox list --scope $SCOPE' failed — the '$SCOPE' team is missing or lacks the Sandbox entitlement. (NEVER run 'vercel sandbox create' to check this — that stalls up to 10m.)" >&2
    return 1
  fi

  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "PREFLIGHT FAIL [anthropic-key]: ANTHROPIC_API_KEY is unset — the isolated turn cannot authenticate Claude inside the sandbox. Export the ambient key (never a run-secret; D110/D23)." >&2
    return 1
  fi

  echo "PREFLIGHT OK: vercel present + authenticated, sandbox entitlement under scope '$SCOPE', ANTHROPIC_API_KEY set. Host is ready for a :cloud turn."
  return 0
}

# ---- offline hermetic self-test -------------------------------------------
self_test() {
  local td fails=0 out rc calls bash_bin
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  calls="$td/vercel.calls"
  # Absolute bash — the PATH-hide leg sets PATH to an empty dir, and `bash "$0"`
  # would otherwise be unresolvable (127) since the invoked bash is looked up
  # against that same emptied PATH.
  bash_bin="$(command -v bash)"

  # Fake vercel: records every argv to $VERCEL_CALLS, honors FAKE_VERCEL_MODE, and
  # FATALs on any `sandbox create` (the preflight must NEVER reach it).
  cat > "$td/vercel" <<'SH'
#!/bin/sh
echo "$*" >> "${VERCEL_CALLS:-/dev/null}"
case "$1" in
  whoami)
    [ "${FAKE_VERCEL_MODE:-}" = whoami-fail ] && exit 1
    echo "fake-user"; exit 0 ;;
  sandbox)
    if [ "${2:-}" = create ]; then
      echo "FATAL: preflight invoked 'vercel sandbox create' — forbidden" >&2
      exit 99
    fi
    # $2 = list
    [ "${FAKE_VERCEL_MODE:-}" = sandbox-list-fail ] && { echo "Error: forbidden (403)" >&2; exit 1; }
    exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$td/vercel"

  # A guaranteed-empty dir for the PATH-hide leg (no vercel resolvable).
  mkdir -p "$td/empty"

  say() { echo "  self-test: $*"; }
  # assert <desc> <expected_rc> <actual_rc> <needle> <output>
  assert() {
    local desc="$1" exp="$2" act="$3" needle="$4" body="$5"
    if [ "$act" != "$exp" ]; then
      echo "  FAIL: $desc — expected exit $exp, got $act" >&2
      echo "$body" | sed 's/^/        /' >&2
      fails=$((fails + 1)); return
    fi
    if [ -n "$needle" ] && ! printf '%s' "$body" | grep -q "$needle"; then
      echo "  FAIL: $desc — exit $act correct but missing marker '$needle'" >&2
      echo "$body" | sed 's/^/        /' >&2
      fails=$((fails + 1)); return
    fi
    say "$desc (exit $act${needle:+, marker '$needle'})"
  }

  # LEG 1: all green.
  : > "$calls"
  out="$(PATH="$td:$PATH" VERCEL_CALLS="$calls" FAKE_VERCEL_MODE=ok ANTHROPIC_API_KEY=sk-test "$bash_bin" "$0" 2>&1)"; rc=$?
  assert "all prerequisites present -> OK" 0 "$rc" "PREFLIGHT OK" "$out"
  if grep -q 'sandbox create' "$calls"; then
    echo "  FAIL: all-green leg invoked 'vercel sandbox create' (call-log tripwire)" >&2
    fails=$((fails + 1))
  else
    say "call-log tripwire: 'vercel sandbox create' never invoked"
  fi
  if grep -q "^sandbox list --scope guerrilla$" "$calls"; then
    say "used the NON-CREATING probe 'sandbox list --scope guerrilla'"
  else
    echo "  FAIL: all-green leg did not run 'sandbox list --scope guerrilla'" >&2
    fails=$((fails + 1))
  fi

  # LEG 2: vercel missing (PATH-hide) -> [vercel-cli].
  out="$(PATH="$td/empty" ANTHROPIC_API_KEY=sk-test "$bash_bin" "$0" 2>&1)"; rc=$?
  assert "vercel CLI absent -> named [vercel-cli] miss" 1 "$rc" "vercel-cli" "$out"

  # LEG 3: auth fails -> [vercel-auth].
  out="$(PATH="$td:$PATH" VERCEL_CALLS="$calls" FAKE_VERCEL_MODE=whoami-fail ANTHROPIC_API_KEY=sk-test "$bash_bin" "$0" 2>&1)"; rc=$?
  assert "vercel whoami fails -> named [vercel-auth] miss" 1 "$rc" "vercel-auth" "$out"

  # LEG 4: sandbox list fails (bad scope / no entitlement) -> [vercel-sandbox-scope].
  out="$(PATH="$td:$PATH" VERCEL_CALLS="$calls" FAKE_VERCEL_MODE=sandbox-list-fail ANTHROPIC_API_KEY=sk-test "$bash_bin" "$0" 2>&1)"; rc=$?
  assert "sandbox entitlement probe fails -> named [vercel-sandbox-scope] miss" 1 "$rc" "vercel-sandbox-scope" "$out"

  # LEG 5: key unset -> [anthropic-key] (last check, so vercel must be all-green).
  # env -u strips ANTHROPIC_API_KEY even if the outer shell exported one.
  out="$(PATH="$td:$PATH" VERCEL_CALLS="$calls" FAKE_VERCEL_MODE=ok env -u ANTHROPIC_API_KEY "$bash_bin" "$0" 2>&1)"; rc=$?
  assert "ANTHROPIC_API_KEY unset -> named [anthropic-key] miss" 1 "$rc" "anthropic-key" "$out"

  echo
  if [ "$fails" -eq 0 ]; then
    echo "SELF-TEST: ALL PASS (5 legs + 2 tripwires)"
    return 0
  fi
  echo "SELF-TEST: $fails FAILURE(S)"
  return 1
}

# ---- arg dispatch ----------------------------------------------------------
case "${1:-}" in
  --self-test) self_test ;;
  --scope)
    [ -n "${2:-}" ] || { echo "$SCRIPT_NAME: --scope needs a team slug" >&2; exit 2; }
    SCOPE="$2"; preflight ;;
  -h | --help) usage ;;
  "") preflight ;;
  *) echo "$SCRIPT_NAME: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac
