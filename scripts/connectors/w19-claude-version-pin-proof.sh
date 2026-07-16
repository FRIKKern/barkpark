#!/usr/bin/env bash
# w19-claude-version-pin-proof.sh — the Connectors Wave-19 claude-version-pin proof
# (D176/D180). BLACK-BOX, hermetic, provisions NO real sandbox.
#
# The sandbox npm-installs `claude` FRESH on every fallback boot (and bakes it into
# the production snapshot), so the RUNNING version is not guaranteed — yet knob-5's
# unattended permission semantics were probed against a SPECIFIC version
# (cloud_policy.ex:57, 2.1.211). Wave 19 pins it at BOTH ends of provisioning:
#   (1) the fallback npm install is version-suffixed (`@anthropic-ai/claude-code@<pin>`),
#   (2) createSandbox probes `claude --version` in-sandbox at its END — the convergence
#       point BOTH the snapshot and the fallback paths reach — and a divergence
#       surfaces LOUDLY (a warning by default, a hard fail under
#       CLOUD_SANDBOX_CLAUDE_VERSION_STRICT), NEVER silently.
#
# This proof drives the REAL cloud-sandbox-runner.mjs end to end with ZERO shim
# refactor (the w12/w14 idiom): CLOUD_SANDBOX_VERCEL_BIN points at a generated FAKE
# `vercel` that records every invocation's argv (NUL-delimited, so the multi-line
# in-sandbox `-c` script survives) and answers the `claude --version` probe with a
# version BAKED INTO the fake (the shim's env allowlist strips any outer var, so the
# version cannot ride the env — it is written literally into each leg's fake). No real
# Vercel, no real sandbox, no GNU `timeout` (absent on darwin — the shim self-
# terminates in <1s against the fake).
#
# RED-then-GREEN, across BOTH provisioning paths:
#   fallback + pinned  → GREEN: 'claude version OK', NO mismatch; the npm install argv
#                               carries the exact `@anthropic-ai/claude-code@<pin>`.
#   fallback + wrong   → RED  : a 'claude-version-mismatch' WARNING naming both
#                               versions fires (the guard actually detects drift).
#   snapshot + pinned  → GREEN: 'claude version OK', NO mismatch, and NO npm install
#                               exec (the snapshot path takes no install).
#   snapshot + wrong   → RED  : the mismatch warning fires on the snapshot path too.
#   strict  + wrong    → RED-HARD: CLOUD_SANDBOX_CLAUDE_VERSION_STRICT=1 ⇒ the shim
#                               exits NON-ZERO and NO turn exec is dispatched
#                               (createSandbox threw before runTurn).
#
# The version-probe exec is `bash -c` (NOT `-lc`), so it never collides with the
# `-lc` turn-locator the w12/w14 proofs key on; those proofs stay green unmodified.
#
# See .claude/workflows/bp-connectors-charter.md (D176/D180) and the wave paper
# connectors-wave-19-2026-07-16. Sibling idioms: w12-shim-confinement-proof.sh
# (fake-vercel argv/env capture), w14-session-sandbox-proof.sh (snapshot leg,
# --sandbox-id round-trip).
#
# Usage:
#   scripts/connectors/w19-claude-version-pin-proof.sh --check   # lint the shim + pin, print the plan, spawn NOTHING
#   scripts/connectors/w19-claude-version-pin-proof.sh           # hermetic black-box run (fake vercel; no real sandbox)
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w19-claude-version-pin-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"
PIN_FILE="$HERE/cloud-claude-pinned-version.txt"
HOST_PIN_FILE="$HERE/../claude-pinned-version.txt"

ANTHROPIC_KEY_VAL="sk-test"
WORKSPACE="w19-proof-ws"
WRONG_VER="9.9.9"  # a clean semver so the shim's parse == the baked value (a suffix like -wrong would be stripped by the semver regex)

CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help)
    cat <<EOF
$SCRIPT_NAME — Connectors Wave-19 claude-version-pin proof (D176/D180).

  --check    node --check the shim, verify the pin file (2.1.211, separate from the
             host pin), print the plan; spawns NO shim and NO vercel (real or fake).
  --help     this text.

With no flag it runs the HERMETIC black-box proof: a generated fake \`vercel\` with a
version BAKED IN answers the \`claude --version\` probe, the REAL shim is driven across
both provisioning paths, and RED-then-GREEN is asserted for each. NO real sandbox.

Charter: $CHARTER (D176/D180).
EOF
    exit 0 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
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

fail() { echo "FAIL: $1" >&2; exit 1; }

# The pinned version the SHIM will read from cloud-claude-pinned-version.txt — read
# from the SAME file here so the proof can never drift from the shim's source of truth.
read_pin() {
  [ -f "$PIN_FILE" ] || fail "pin file missing: $PIN_FILE"
  local v
  v="$(tr -d '[:space:]' < "$PIN_FILE")"
  [ -n "$v" ] || fail "pin file empty: $PIN_FILE"
  printf '%s' "$v"
}

lint() {
  echo "==> lint: node --check $SHIM"
  command -v node >/dev/null 2>&1 || { echo "ERROR: 'node' not found on PATH." >&2; exit 1; }
  node --check "$SHIM" || fail "shim failed node --check"

  echo "==> lint: pin file present, non-empty, and SEPARATE from the host-CLI pin"
  local pin host_pin
  pin="$(read_pin)"
  echo "    cloud pin (cloud-claude-pinned-version.txt): $pin"
  if [ -f "$HOST_PIN_FILE" ]; then
    host_pin="$(tr -d '[:space:]' < "$HOST_PIN_FILE")"
    echo "    host  pin (claude-pinned-version.txt):       $host_pin"
    [ "$pin" != "$host_pin" ] || fail "cloud pin must NOT equal the host-CLI pin ($host_pin) — different surface/proof-lane (D176)"
  fi

  echo "==> lint: shim reads the cloud pin, version-suffixes the install, and asserts"
  grep -q "readPinnedClaudeVersion" "$SHIM" || fail "shim lost readPinnedClaudeVersion() — the pin is no longer read"
  grep -q "cloud-claude-pinned-version.txt" "$SHIM" || fail "shim no longer references cloud-claude-pinned-version.txt"
  grep -q "assertClaudeVersion" "$SHIM" || fail "shim lost assertClaudeVersion() — the drift check is gone"
  grep -q "await assertClaudeVersion(id)" "$SHIM" || fail "createSandbox no longer calls assertClaudeVersion(id) at its end"
  echo "    OK: shim lints; pin read + install-suffix + end-of-createSandbox assert all wired."
}

print_plan() {
  local pin; pin="$(read_pin)"
  cat <<EOF
$SCRIPT_NAME — PLAN (pin = $pin, wrong = $WRONG_VER)

A full (non --check) run is hermetic — it provisions NO real sandbox:

  For each leg a fake \`vercel\` is generated with a claude version BAKED IN (the
  shim's env allowlist strips outer vars, so the version cannot ride the env). The
  fake records argv (NUL-delimited) + env per call, echoes an id on 'sandbox create',
  answers the 'claude --version' probe with the baked version, and exits 0 otherwise.

  Legs (each drives the REAL shim, one stream-json user frame on stdin):
    1. fallback + pinned  → GREEN: exit 0; stderr 'claude version OK'; NO 'mismatch';
                                   npm install argv token == @anthropic-ai/claude-code@$pin.
    2. fallback + wrong   → RED  : stderr 'claude-version-mismatch' naming $pin and $WRONG_VER.
    3. snapshot + pinned  → GREEN: exit 0; 'claude version OK'; NO 'mismatch'; NO npm install exec.
    4. snapshot + wrong   → RED  : stderr 'claude-version-mismatch' (snapshot path).
    5. strict  + wrong    → RED-HARD: CLOUD_SANDBOX_CLAUDE_VERSION_STRICT=1 ⇒ exit != 0,
                                   'claude-version-mismatch', and ZERO '-lc' turn execs.

No GNU timeout; the shim self-terminates against the fake. Scratch tree removed on exit.
EOF
}

# ── Generate a fake \`vercel\` with a claude version baked in. ──────────────────
# Args: <capdir> <path> <baked-claude-version>
make_fake_vercel() {
  local capdir="$1" path="$2" ver="$3"
  cat >"$path" <<FAKE
#!/usr/bin/env bash
# Fake \`vercel\` for the W19 version-pin proof. Records argv (NUL-delimited) + env,
# echoes an id on 'sandbox create', answers 'claude --version' with the BAKED version.
set -u
capdir="$capdir"
baked_ver="$ver"
mkdir -p "\$capdir"
n=0
while ! ( set -o noclobber; : >"\$capdir/lock.\$n" ) 2>/dev/null; do
  n=\$((n + 1))
done
: >"\$capdir/argv.\$n"
for a in "\$@"; do
  printf '%s\0' "\$a" >>"\$capdir/argv.\$n"
done
env >"\$capdir/env.\$n"
is_sandbox=0; is_create=0; is_verprobe=0
for a in "\$@"; do
  [ "\$a" = "sandbox" ] && is_sandbox=1
  [ "\$a" = "create" ] && is_create=1
  case "\$a" in *"claude --version"*) is_verprobe=1 ;; esac
done
if [ "\$is_sandbox" = 1 ] && [ "\$is_create" = 1 ]; then
  echo "sb_fake_w19"
elif [ "\$is_verprobe" = 1 ]; then
  echo "\$baked_ver (Claude Code)"
fi
exit 0
FAKE
  chmod +x "$path"
}

# Read a NUL-delimited argv capture into the global array CAP_TOKENS.
read_argv() {
  CAP_TOKENS=()
  local tok
  while IFS= read -r -d '' tok; do CAP_TOKENS+=("$tok"); done <"$1"
}

# Drive the REAL shim once. Args: <leg-label> <baked-version> <extra-env-assignments...>
# Sets globals: LEG_RC, LEG_ERR (stderr file), LEG_CAP (capture dir).
drive_shim() {
  local label="$1" ver="$2"; shift 2
  local leg="$WORK/$label"
  LEG_CAP="$leg/cap"
  LEG_ERR="$leg/err"
  local tmp="$leg/tmp" fake="$leg/vercel"
  mkdir -p "$LEG_CAP" "$tmp"
  make_fake_vercel "$LEG_CAP" "$fake" "$ver"

  local frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  printf '%s\n' "$frame" | \
    env ANTHROPIC_API_KEY="$ANTHROPIC_KEY_VAL" \
        CLOUD_SANDBOX_VERCEL_BIN="$fake" \
        TMPDIR="$tmp" \
        "$@" \
        node "$SHIM" --workspace "$WORKSPACE" -- \
          --input-format stream-json --output-format stream-json \
          --include-partial-messages --verbose --permission-mode plan \
      >/dev/null 2>"$LEG_ERR"
  LEG_RC=$?
  echo "    ($label) shim exit=$LEG_RC, $(find "$LEG_CAP" -name 'argv.*' | wc -l | tr -d ' ') vercel invocation(s)."
}

# Locate the version-probe capture (its `-c` script token carries 'claude --version').
find_verprobe_capture() {
  local capdir="$1" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    grep -zq "claude --version" "$f" && { echo "$f"; return 0; }
  done
  return 1
}

# Locate the npm-install capture (argv carries `i` `-g` and an @anthropic-ai token).
find_npm_capture() {
  local capdir="$1" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    grep -zq "@anthropic-ai/claude-code" "$f" && { echo "$f"; return 0; }
  done
  return 1
}

# Any capture whose argv carries a whole-record `-lc` token (a real turn exec).
has_turn_exec() {
  local capdir="$1" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    grep -zxq -e '-lc' "$f" && return 0
  done
  return 1
}

assert_green() {
  local label="$1" cap="$2" err="$3"
  grep -q "claude version OK" "$err" || { sed 's/^/      /' "$err" >&2; fail "($label GREEN) no 'claude version OK' line — the match did not confirm"; }
  if grep -q "claude-version-mismatch" "$err"; then
    sed 's/^/      /' "$err" >&2; fail "($label GREEN) a mismatch warning fired on the PINNED version — false positive"
  fi
  find_verprobe_capture "$cap" >/dev/null || fail "($label GREEN) no version-probe exec captured — the check never ran"
  echo "    PASS ($label): version probe ran, matched the pin, no mismatch."
}

assert_red() {
  local label="$1" cap="$2" err="$3" pin="$4"
  grep -q "claude-version-mismatch" "$err" || { sed 's/^/      /' "$err" >&2; fail "($label RED) NO 'claude-version-mismatch' — the guard did not fire on a wrong version (vacuous)"; }
  grep -q "$pin" "$err" || fail "($label RED) mismatch line does not name the pinned $pin"
  grep -q "$WRONG_VER" "$err" || fail "($label RED) mismatch line does not name the wrong $WRONG_VER"
  find_verprobe_capture "$cap" >/dev/null || fail "($label RED) no version-probe exec captured — the check never ran"
  echo "    PASS ($label): guard FIRED — mismatch surfaced naming $pin vs $WRONG_VER."
}

run_proof() {
  WORK="$(mktemp -d)"
  local pin; pin="$(read_pin)"

  # ── Leg 1: fallback + pinned → GREEN (+ install-suffix assertion) ────────────
  echo "==> Leg 1: FALLBACK + pinned ($pin) → expect GREEN ..."
  drive_shim fb-pinned "$pin"
  [ "$LEG_RC" -eq 0 ] || { sed 's/^/      /' "$LEG_ERR" >&2; fail "(1) fallback+pinned shim exit=$LEG_RC, expected 0"; }
  assert_green "1 fallback+pinned" "$LEG_CAP" "$LEG_ERR"
  # The fallback install must be version-suffixed to the exact pin.
  local npm_cap
  npm_cap="$(find_npm_capture "$LEG_CAP")" || fail "(1) no npm-install exec captured on the fallback path"
  read_argv "$npm_cap"
  local found_pkg="" want="@anthropic-ai/claude-code@$pin" t
  for t in "${CAP_TOKENS[@]}"; do [ "$t" = "$want" ] && found_pkg="$t"; done
  [ -n "$found_pkg" ] || fail "(1) fallback npm install is not pinned — expected token '$want' in the install argv"
  echo "    PASS (1 install-suffix): npm install argv carries '$want'."

  # ── Leg 2: fallback + wrong → RED ───────────────────────────────────────────
  echo "==> Leg 2: FALLBACK + wrong ($WRONG_VER) → expect RED ..."
  drive_shim fb-wrong "$WRONG_VER"
  assert_red "2 fallback+wrong" "$LEG_CAP" "$LEG_ERR" "$pin"

  # ── Leg 3: snapshot + pinned → GREEN (no npm install on this path) ───────────
  echo "==> Leg 3: SNAPSHOT + pinned ($pin) → expect GREEN, no install exec ..."
  drive_shim snap-pinned "$pin" CLOUD_SANDBOX_SNAPSHOT="snap_fake_w19"
  [ "$LEG_RC" -eq 0 ] || { sed 's/^/      /' "$LEG_ERR" >&2; fail "(3) snapshot+pinned shim exit=$LEG_RC, expected 0"; }
  assert_green "3 snapshot+pinned" "$LEG_CAP" "$LEG_ERR"
  if find_npm_capture "$LEG_CAP" >/dev/null; then
    fail "(3) snapshot path ran an npm install exec — claude must be pre-baked, no install"
  fi
  echo "    PASS (3 snapshot-no-install): no npm install exec on the snapshot path."

  # ── Leg 4: snapshot + wrong → RED (snapshot path covered) ────────────────────
  echo "==> Leg 4: SNAPSHOT + wrong ($WRONG_VER) → expect RED ..."
  drive_shim snap-wrong "$WRONG_VER" CLOUD_SANDBOX_SNAPSHOT="snap_fake_w19"
  assert_red "4 snapshot+wrong" "$LEG_CAP" "$LEG_ERR" "$pin"

  # ── Leg 5: strict + wrong → RED-HARD (fail closed, turn never dispatches) ────
  echo "==> Leg 5: STRICT + wrong ($WRONG_VER) → expect HARD FAIL, no turn exec ..."
  drive_shim strict-wrong "$WRONG_VER" CLOUD_SANDBOX_CLAUDE_VERSION_STRICT=1
  [ "$LEG_RC" -ne 0 ] || fail "(5) strict+wrong shim exited 0 — a hard fail must exit non-zero"
  grep -q "claude-version-mismatch" "$LEG_ERR" || { sed 's/^/      /' "$LEG_ERR" >&2; fail "(5) strict+wrong: no mismatch surfaced"; }
  if has_turn_exec "$LEG_CAP"; then
    fail "(5) strict+wrong dispatched a turn exec ('-lc') — a hard-failed create must abort BEFORE the turn"
  fi
  echo "    PASS (5): exit=$LEG_RC (non-zero), mismatch surfaced, ZERO turn execs — failed closed before dispatch."
}

main() {
  echo "== Connectors Wave-19 claude-version-pin proof =="
  echo "== charter: $CHARTER (D176/D180) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim linted, pin verified separate, plan printed, nothing spawned."
    return 0
  fi

  run_proof
  echo ""
  echo "== PROVEN: the in-sandbox claude version is pinned + asserted at the END of"
  echo "==         createSandbox across BOTH provisioning paths; a wrong version surfaces"
  echo "==         LOUDLY (warning by default, hard fail under STRICT) — RED before, GREEN"
  echo "==         on the pin; the fallback install itself is version-suffixed. =="
  echo "== The LIVE in-sandbox version observation rides connectors-hg-live-isolated-cloud-turn. =="
}

main
