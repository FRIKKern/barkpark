#!/usr/bin/env bash
# w30-shim-sanitize-proof.sh — the Connectors Wave-30 shim error-sanitize proof
# (W30, D213). BLACK-BOX, hermetic, provisions NO real sandbox.
#
# THE LEAK PATH THIS PROOF SEALS. The shim's stderr tail (last ~8KB/20 lines) is
# broadcast VERBATIM to every connected viewer's ChatLive:
#   claude_chat.ex:1267/1668-1689 → recorder.ex:585-594 → chat_live.ex:4512
# (a String.trim passthrough into a visible system chat message). Three EXISTING
# cloud-sandbox-runner.mjs call sites fold the LOCAL `vercel` child's RAW stderr
# (`res.err`) into a thrown Error.message — sandbox create, the npm-install
# fallback, and the claude version probe — and the version-probe path ALSO `log()`s
# that same message on its non-strict WARNING branch. Today none carries credential
# material, but the path is one refactor from leaking (D213 forbids folding
# response/config/credential bytes into Error.message). W30 routes all four through
# ONE `sanitizeErr()` helper at MESSAGE CONSTRUCTION, so both the throw and the
# log() path are covered.
#
# This proof drives the REAL shim end to end against a generated FAKE `vercel` that
# prints a SECRET-SHAPED string to stderr and exits nonzero at a chosen stage. It
# asserts the planted secret markers do NOT survive into the shim's own stderr (the
# ChatLive-bound tail), while the useful diagnostic (the failing verb) DOES — the
# fold path ran, non-vacuously. FOUR scenarios, one per leak surface:
#   (A) sandbox create fails      → thrown Error.message  (create fold)
#   (B) npm-install fallback fails → thrown Error.message  (npm-install fold)
#   (C) version probe fails STRICT → thrown Error.message  (version-probe fold)
#   (D) version probe fails soft   → log() WARNING line     (the 694 log leak)
#
# The secret plants all three redacted shapes — env-assignment, bearer-token, and
# base64-blob — so a single run proves the helper strips each.
#
# See .claude/workflows/bp-connectors-charter.md (D213) and the wave paper
# connectors-wave-30-2026-07-21. Sibling idiom: w12-shim-confinement-proof.sh
# (fake `vercel`, NUL-delimited argv capture, hermetic; no real Vercel).
#
# Usage:
#   scripts/connectors/w30-shim-sanitize-proof.sh --check   # lint the shim + print the plan, run NO subprocess
#   scripts/connectors/w30-shim-sanitize-proof.sh           # hermetic black-box run (fake vercel; no real sandbox)
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w30-shim-sanitize-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"

# The planted secret plants all three redacted shapes. Each marker below MUST be
# absent from the shim's stderr after sanitize; the shapes around them are what
# sanitizeErr() targets.
ENV_MARKER="w30planted_envval"
BEARER_MARKER="w30planted_bearerval_longtokenmaterialxxxx"
BLOB_MARKER="w30planted_base64blobmaterialAAAAAAAAAAAAAAAA"
SECRET="HOST_SECRET=$ENV_MARKER Authorization: Bearer $BEARER_MARKER $BLOB_MARKER"

WORKSPACE="w30-proof-ws"
PIN="2.1.211"

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-30 shim error-sanitize proof (D213).

  --check    node --check the shim, verify sanitizeErr() is wired into all four
             leak surfaces, print the plan; runs NO shim subprocess and spawns
             NO vercel (real or fake).
  --help     this text.

With no flag it runs the HERMETIC black-box proof: a generated fake \`vercel\`
prints a secret-shaped string to stderr and fails at a chosen stage; the REAL
$SHIM is driven end to end four times (create / npm-install / version-strict /
version-soft), and each run asserts the planted secret markers do NOT survive
into the shim's stderr while the failing verb DOES. NO real Vercel sandbox is
ever created.

Charter: $CHARTER (D213).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# ── Scratch tree + teardown (fires on any exit, incl. error / Ctrl-C). ─────────
WORK=""
cleanup() {
  local rc=$?
  set +e
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT

lint() {
  echo "==> lint: node --check $SHIM"
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' not found on PATH." >&2; exit 1
  fi
  node --check "$SHIM" || { echo "ERROR: shim failed node --check" >&2; exit 1; }

  echo "==> lint: shim carries the sanitizeErr() belt AND wires it into every res.err fold"
  if ! grep -q "function sanitizeErr" "$SHIM"; then
    echo "ERROR: shim lost sanitizeErr() — the W30 error-sanitize belt is gone" >&2; exit 1
  fi
  # No RAW res.err/npm.err may be folded into a thrown Error or a logged msg. A
  # regression that drops the sanitize call re-opens the leak, so pin its absence.
  if grep -Eq '(res|npm)\.err\.trim\(\)' "$SHIM"; then
    echo "ERROR: a raw \`.err.trim()\` fold survives — it must route through sanitizeErr()" >&2; exit 1
  fi
  # Each of the three fold sites must pass its err through the helper.
  local wired
  wired="$(grep -c 'sanitizeErr(res.err)\|sanitizeErr(npm.err)' "$SHIM")"
  if [ "$wired" -lt 3 ]; then
    echo "ERROR: expected >=3 sanitizeErr(res.err|npm.err) folds, found $wired" >&2; exit 1
  fi
  echo "    OK: shim lints, sanitizeErr() present and wired into $wired res.err folds; no raw fold remains."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN

A full (non --check) run is hermetic — it provisions NO real sandbox. For each of
four leak surfaces it:

  1. Generates a fake \`vercel\` that fails at the named stage (create / npm /
     version), printing the planted secret to stderr:
       $SECRET

  2. Drives the REAL shim with that fake:
       printf '<user frame>' | \\
         CLOUD_SANDBOX_VERCEL_BIN=\$fake TMPDIR=\$tmp [pin/strict env] \\
           node $SHIM --workspace $WORKSPACE -- --permission-mode plan
     capturing the shim's stderr (the ChatLive-bound tail).

  3. ASSERTS from the captured stderr:
       - the failing verb's diagnostic IS present (the fold path ran — non-vacuous)
       - NONE of the planted markers survive:
           env-assignment  ($ENV_MARKER)
           bearer-token    ($BEARER_MARKER)
           base64-blob     ($BLOB_MARKER)

  Scenarios:
    (A) create fails       → thrown 'vercel sandbox create failed'
    (B) npm-install fails   → thrown 'in-sandbox claude install failed'
    (C) version probe fails → thrown 'claude-version-probe-failed' (STRICT)
    (D) version probe fails → 'WARNING: claude-version-probe-failed' via log() (soft)

No GNU timeout is used; the shim self-terminates against the fake. Scratch tree is
removed on exit.
EOF
}

# ── Generate a fake `vercel` that fails (secret to stderr) at $fail_stage. ──────
#   fail_stage ∈ { create, npm, version }. Every other stage succeeds so the shim
#   reaches the intended fold. The secret + stage are BAKED into the script — the
#   shim's env allowlist (HOME/PATH/TMPDIR/VERCEL_*) would strip any FAKE_* env.
make_fake_vercel() {
  local path="$1" fail_stage="$2"
  cat >"$path" <<FAKE
#!/usr/bin/env bash
set -u
secret='$SECRET'
fail_stage='$fail_stage'
is_sandbox=0; is_create=0; is_exec=0; has_npm=0; has_version=0
for a in "\$@"; do
  case "\$a" in
    sandbox) is_sandbox=1 ;;
    create)  is_create=1 ;;
    exec)    is_exec=1 ;;
    npm)     has_npm=1 ;;
    *--version*) has_version=1 ;;
  esac
done
# sandbox create: fail here for scenario A, else echo an id the shim parses.
if [ "\$is_sandbox" = 1 ] && [ "\$is_create" = 1 ]; then
  if [ "\$fail_stage" = create ]; then printf '%s\n' "\$secret" >&2; exit 1; fi
  echo "sb_fake_w30"; exit 0
fi
# npm-install fallback exec: fail here for scenario B.
if [ "\$is_exec" = 1 ] && [ "\$has_npm" = 1 ]; then
  if [ "\$fail_stage" = npm ]; then printf '%s\n' "\$secret" >&2; exit 1; fi
  exit 0
fi
# version probe exec ('bash -c "... claude --version"'): fail here for C/D.
if [ "\$is_exec" = 1 ] && [ "\$has_version" = 1 ]; then
  if [ "\$fail_stage" = version ]; then printf '%s\n' "\$secret" >&2; exit 1; fi
  echo "$PIN (Claude Code)"; exit 0
fi
# turn exec / teardown / anything else: succeed silently.
exit 0
FAKE
  chmod +x "$path"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# Drive the shim once against a fresh fake failing at $stage, then assert the
# diagnostic survived and every planted marker did NOT.
#   $1 label  $2 fail_stage  $3 expected diagnostic substring  $4.. extra shim env
run_scenario() {
  local label="$1" stage="$2" diag="$3"; shift 3
  local extra_env=("$@")
  local sd="$WORK/$label"
  local fake="$sd/vercel" tmp="$sd/tmp" errf="$sd/shim.err"
  mkdir -p "$sd" "$tmp"
  make_fake_vercel "$fake" "$stage"

  local frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  echo "==> scenario $label: fake vercel fails at '$stage', secret piped to stderr ..."
  printf '%s\n' "$frame" | \
    env CLOUD_SANDBOX_VERCEL_BIN="$fake" TMPDIR="$tmp" \
      ${extra_env[@]+"${extra_env[@]}"} \
      node "$SHIM" --workspace "$WORKSPACE" -- --permission-mode plan \
      >/dev/null 2>"$errf"
  local rc=$?
  echo "    shim exit=$rc (stderr captured for assertion)"

  # Non-vacuous: the failing verb's diagnostic must be present — proves the fold ran.
  if ! grep -qF "$diag" "$errf"; then
    echo "    --- shim stderr ---" >&2; sed 's/^/    /' "$errf" >&2
    fail "($label) expected diagnostic '$diag' absent — the fold path did not run"
  fi
  echo "    ok: diagnostic '$diag' present (fold ran)."

  # The seal: NO planted marker may survive into the ChatLive-bound stderr tail.
  local m
  for m in "$ENV_MARKER" "$BEARER_MARKER" "$BLOB_MARKER"; do
    if grep -qF "$m" "$errf"; then
      echo "    --- shim stderr ---" >&2; sed 's/^/    /' "$errf" >&2
      fail "($label) planted marker '$m' LEAKED into the shim stderr tail — sanitizeErr() did not strip it"
    fi
  done
  echo "    PASS ($label): env / bearer / base64 markers all stripped; diagnostic preserved."
}

run_proof() {
  WORK="$(mktemp -d)"

  # (A) create fold — no pin needed (fails before the version probe).
  run_scenario "A-create" create "vercel sandbox create failed"

  # (B) npm-install fold — no snapshot ⇒ fallback boot runs npm i -g, which fails.
  run_scenario "B-npm" npm "in-sandbox claude install failed"

  # (C) version-probe fold, STRICT — create+npm succeed, the probe throws.
  run_scenario "C-version-strict" version "claude-version-probe-failed" \
    CLOUD_SANDBOX_CLAUDE_VERSION="$PIN" CLOUD_SANDBOX_CLAUDE_VERSION_STRICT=1

  # (D) version-probe LOG leak (line 694), soft — the probe WARNs (not throws) but
  #     the same message flows through log(); the belt must cover that path too.
  run_scenario "D-version-warn" version "WARNING: claude-version-probe-failed" \
    CLOUD_SANDBOX_CLAUDE_VERSION="$PIN"
}

main() {
  echo "== Connectors Wave-30 shim error-sanitize proof =="
  echo "== charter: $CHARTER (D213) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim linted, sanitizeErr() wired into all four surfaces, plan printed, nothing spawned."
    return 0
  fi

  run_proof
  echo ""
  echo "== PROVEN: all four res.err→ChatLive surfaces (create / npm-install / version"
  echo "==         strict-throw / version soft-log 694) route through sanitizeErr(); a"
  echo "==         planted env-assignment / bearer / base64 secret is stripped at message"
  echo "==         construction while the failing-verb diagnostic survives. =="
}

main
