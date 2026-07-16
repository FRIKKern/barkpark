#!/usr/bin/env bash
# w14-session-sandbox-proof.sh — the Connectors Wave-14 session-sandbox lifecycle
# proof (D137/D138). BLACK-BOX, hermetic, provisions NO real sandbox.
#
# Wave 11 wired the one-shot `:cloud` turn; Wave 14 makes the Cloud Runner a real
# multi-turn Barkpark Chat SESSION. The continuity mechanism (D134): create the
# sandbox ONCE, STOP it after each turn (auto-snapshots, Persistent=true), and let
# the NEXT turn's `vercel sandbox exec` auto-resume it with /tmp intact. The shim
# grew two ADDITIVE pre-`--` flags + one sideband frame + a mode-dependent teardown
# (D137); this proof pins that lifecycle without a live Vercel.
#
# Same technique as w12-shim-confinement-proof.sh (D122): `CLOUD_SANDBOX_VERCEL_BIN`
# points the REAL cloud-sandbox-runner.mjs at a generated FAKE `vercel` that records
# every invocation's argv (NUL-delimited, so the multi-line in-sandbox `-lc` script
# survives) and echoes a sandbox id on `sandbox create`. No real Vercel, no GNU
# `timeout` (absent on darwin — the shim self-terminates in <1s against the fake).
# `CLOUD_SANDBOX_SNAPSHOT` is set so create takes the snapshot path (no `npm i -g`
# exec noise), leaving crisp create → exec → teardown sequences.
#
# Three legs (charter D137/D138):
#   (a) REUSE — `--sandbox-id <id>` ⇒ ZERO `sandbox create` invocations, and the
#       turn exec targets the supplied id (auto-resume path).
#   (b) TEARDOWN VERB — `--keep-sandbox` ⇒ teardown invokes `sandbox stop` and
#       NEVER `sandbox remove`; flag-less ⇒ the legacy `create + exec + remove`
#       sequence, `stop` NEVER invoked (byte-preserved).
#   (c) SIDEBAND FRAME — a keep-mode CREATE emits EXACTLY ONE valid
#       {"type":"bp_sandbox","subtype":"created","sandbox_id":"<id>"} NDJSON line
#       on stdout BEFORE any claude frame, carrying the created id; a flag-less
#       CREATE emits NONE (stdout byte-identical to pre-D137).
#
# Wave 15 (D147) hardens the reuse path with two additive assertions:
#   (a′) the REUSE leg's OWN stdout carries ZERO bp_sandbox frames (reuse creates
#        nothing, so it must mint no phantom id); and
#   (d) CHAINED ID ROUND-TRIP — the id a keep-mode CREATE emits is harvested and fed
#       back as the next invocation's --sandbox-id, which must then create nothing and
#       target the harvested id. This pins the SHIM's OWN id round-trip ONLY; session
#       identity / Recorder / chat_sessions persistence is the ExUnit capstone (D144).
#
# The turn exec is located by its `-lc` argv token, NEVER by capture ordering.
# See .claude/workflows/bp-connectors-charter.md (Wave 14, D134-D143) and the wave
# paper connectors-wave-14-2026-07-16. Sibling idiom: w12-shim-confinement-proof.sh.
#
# Usage:
#   scripts/connectors/w14-session-sandbox-proof.sh --check   # lint the shim + print the plan, run NO subprocess
#   scripts/connectors/w14-session-sandbox-proof.sh           # hermetic black-box run (fake vercel; no real sandbox)
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w14-session-sandbox-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"

WORKSPACE="w14-proof-ws"
REUSE_ID="sb_reuse_target_w14"
FAKE_CREATE_ID="sb_fake_w14_session"
ANTHROPIC_KEY_VAL="sk-test"
# The claude segment every leg passes after `--` (the D109 argv shape).
CLAUDE_ARGS=(--input-format stream-json --output-format stream-json --include-partial-messages --verbose --permission-mode plan)

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-14 session-sandbox lifecycle proof (D137/D138).

  --check    node --check the shim, verify the D137 lifecycle markers, print the
             plan; runs NO shim subprocess and spawns NO vercel (real or fake).
  --help     this text.

With no flag it runs the HERMETIC black-box proof: a generated fake \`vercel\`
records argv per call, the REAL $SHIM is driven for three legs (reuse / teardown
verb / sideband frame), and the D137/D138 lifecycle assertions are checked from the
captures + the shim's stdout. NO real Vercel sandbox is ever created.

Charter: $CHARTER (Wave 14, D137/D138).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  "") CHECK_ONLY=0 ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
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

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

lint() {
  echo "==> lint: node --check $SHIM"
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' not found on PATH." >&2
    exit 1
  fi
  node --check "$SHIM" || { echo "ERROR: shim failed node --check" >&2; exit 1; }

  echo "==> lint: shim carries the D137 session-sandbox lifecycle"
  # The two additive flags, the mode-dependent teardown verb, and the sideband
  # frame emitter must all be present. A regression that drops any one silently
  # breaks session continuity, so pin them.
  grep -q -- '--sandbox-id' "$SHIM" || fail "shim lost the --sandbox-id reuse flag (D137)"
  grep -q -- '--keep-sandbox' "$SHIM" || fail "shim lost the --keep-sandbox flag (D137)"
  grep -q 'keepMode ? "stop" : "remove"' "$SHIM" || fail "shim lost the mode-dependent teardown verb (D137)"
  grep -q 'emitSandboxFrame' "$SHIM" || fail "shim lost the bp_sandbox sideband emitter (D137)"
  grep -q '"bp_sandbox"' "$SHIM" || fail "shim lost the bp_sandbox frame type (D137)"
  echo "    OK: shim lints; --sandbox-id / --keep-sandbox / stop-not-remove / bp_sandbox frame all present."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN

A full (non --check) run is hermetic — it provisions NO real sandbox:

  1. Generate a fake \`vercel\` that records each invocation's argv (NUL-delimited)
     to a per-leg capture dir, echoes '$FAKE_CREATE_ID' on 'sandbox create', and
     exits 0 otherwise.

  2. Drive the REAL shim three times (fresh capture dir each), snapshot path forced
     (CLOUD_SANDBOX_SNAPSHOT set ⇒ no npm-install exec noise):

     (a) REUSE: node $SHIM --workspace $WORKSPACE --sandbox-id $REUSE_ID --keep-sandbox -- <claude args>
         ASSERT: ZERO 'sandbox create' captures; the '-lc' turn exec targets $REUSE_ID.

     (b) KEEP CREATE: node $SHIM --workspace $WORKSPACE --keep-sandbox -- <claude args>
         ASSERT: teardown invokes 'sandbox stop', NEVER 'sandbox remove'.
     (b) FLAG-LESS: node $SHIM --workspace $WORKSPACE -- <claude args>
         ASSERT: legacy 'create + exec + remove'; 'sandbox stop' NEVER invoked.

     (c) SIDEBAND: from the KEEP CREATE run's stdout, the FIRST non-empty line is a
         valid {"type":"bp_sandbox","subtype":"created","sandbox_id":"$FAKE_CREATE_ID"}
         NDJSON frame before any claude frame; the FLAG-LESS run's stdout has NONE.

No GNU timeout is used; the shim self-terminates against the fake. Scratch tree is
removed on exit.
EOF
}

# ── Generate the fake `vercel` CLI: records argv, echoes an id on create. ───────
make_fake_vercel() {
  local capdir="$1" path="$2"
  cat >"$path" <<FAKE
#!/usr/bin/env bash
# Fake \`vercel\` for the W14 session-sandbox proof. Records this invocation's argv
# (NUL-delimited), then emulates just enough for the shim to proceed.
set -u
capdir="$capdir"
mkdir -p "\$capdir"
# Monotonic per-invocation index via an exclusive-create counter (calls are serial).
n=0
while ! ( set -o noclobber; : >"\$capdir/lock.\$n" ) 2>/dev/null; do
  n=\$((n + 1))
done
# argv: one NUL-terminated record per token (survives the multi-line -lc script).
: >"\$capdir/argv.\$n"
for a in "\$@"; do
  printf '%s\0' "\$a" >>"\$capdir/argv.\$n"
done
# Emulate: 'sandbox create ...' echoes an id the shim parses; all else exits 0.
is_create=0; is_sandbox=0
for a in "\$@"; do
  [ "\$a" = "sandbox" ] && is_sandbox=1
  [ "\$a" = "create" ] && is_create=1
done
if [ "\$is_sandbox" = 1 ] && [ "\$is_create" = 1 ]; then
  echo "$FAKE_CREATE_ID"
fi
exit 0
FAKE
  chmod +x "$path"
}

# ── argv predicates over a NUL-delimited capture file. ─────────────────────────
# 0 if the file contains ALL given tokens (each as a whole NUL-delimited record).
argv_has_all() {
  local f="$1"
  shift
  local t
  for t in "$@"; do
    grep -zxq -e "$t" "$f" || return 1
  done
  return 0
}

# 0 if ANY capture in capdir carries the `sandbox <sub>` pair.
has_invocation() {
  local capdir="$1" sub="$2" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    argv_has_all "$f" sandbox "$sub" && return 0
  done
  return 1
}

# Count REAL `sandbox create` captures (the retention probe carries `--help`; the
# real create does not — count only the latter).
count_real_creates() {
  local capdir="$1" n=0 f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    if argv_has_all "$f" sandbox create && ! grep -zxq -e '--help' "$f"; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# Echo the capture file holding the turn exec (the one with a `-lc` token).
find_turn_capture() {
  local capdir="$1" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    grep -zxq -e '-lc' "$f" && {
      echo "$f"
      return 0
    }
  done
  return 1
}

# ── Drive the REAL shim once against a fresh fake. Sets globals CAP / OUT / RC. ─
# Args: <leg-label> <shim-flag...> (the pre-`--` flags for this leg; claude args
# are appended by this function).
drive_shim() {
  local label="$1"
  shift
  local leg="$WORK/$label"
  CAP="$leg/cap"
  OUT="$leg/out"
  local tmp="$leg/tmp" fake="$leg/vercel" err="$leg/err"
  mkdir -p "$CAP" "$tmp"
  make_fake_vercel "$CAP" "$fake"

  local user_frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  printf '%s\n' "$user_frame" |
    ANTHROPIC_API_KEY="$ANTHROPIC_KEY_VAL" \
      CLOUD_SANDBOX_VERCEL_BIN="$fake" \
      CLOUD_SANDBOX_SNAPSHOT="snap_fake_w14" \
      TMPDIR="$tmp" \
      node "$SHIM" --workspace "$WORKSPACE" "$@" -- "${CLAUDE_ARGS[@]}" \
      >"$OUT" 2>"$err"
  RC=$?
  echo "    ($label) shim exit=$RC, $(find "$CAP" -name 'argv.*' | wc -l | tr -d ' ') vercel invocation(s)."
}

run_proof() {
  WORK="$(mktemp -d)"

  # ── (a) REUSE: --sandbox-id ⇒ zero create, turn targets the supplied id. ─────
  echo "==> (a) REUSE leg: --sandbox-id $REUSE_ID --keep-sandbox ..."
  drive_shim reuse --sandbox-id "$REUSE_ID" --keep-sandbox
  local reuse_cap="$CAP" reuse_out="$OUT"
  local creates
  creates="$(count_real_creates "$reuse_cap")"
  [ "$creates" -eq 0 ] || fail "(a) --sandbox-id still ran $creates 'sandbox create' invocation(s) — must skip create entirely"
  local turn_cap
  turn_cap="$(find_turn_capture "$reuse_cap")" || fail "(a) no turn exec captured (no '-lc' token)"
  argv_has_all "$turn_cap" sandbox exec "$REUSE_ID" ||
    fail "(a) turn exec does not target the reused sandbox id $REUSE_ID"
  # The sideband bp_sandbox frame is emitted ONLY on a real create; the reuse path
  # creates nothing, so its OWN stdout must carry ZERO bp_sandbox frames (a leak here
  # would mint a phantom id for a sandbox the reuse leg never created).
  if grep -q 'bp_sandbox' "$reuse_out"; then
    fail "(a) reuse leg emitted a bp_sandbox frame — reuse creates no sandbox, so no sideband frame may appear"
  fi
  echo "    PASS: zero create invocations; turn exec targets $REUSE_ID."
  echo "    PASS: reuse stdout carries NO bp_sandbox frame (reuse mints no phantom id)."

  # ── (b) TEARDOWN VERB: keep ⇒ stop-not-remove; flag-less ⇒ create+exec+remove. ─
  echo "==> (b) TEARDOWN VERB — keep-mode create (stop, never remove) ..."
  drive_shim keepcreate --keep-sandbox
  local keep_cap="$CAP" keep_out="$OUT"
  has_invocation "$keep_cap" stop || fail "(b) keep-mode teardown did NOT invoke 'sandbox stop'"
  if has_invocation "$keep_cap" remove; then
    fail "(b) keep-mode teardown invoked 'sandbox remove' — must STOP, never remove (breaks resume)"
  fi
  creates="$(count_real_creates "$keep_cap")"
  [ "$creates" -eq 1 ] || fail "(b) keep-mode expected exactly one real create, got $creates"
  echo "    PASS: keep-mode ⇒ exactly one create + 'sandbox stop', 'sandbox remove' NEVER invoked."

  echo "==> (b) TEARDOWN VERB — flag-less (legacy create + exec + remove) ..."
  drive_shim flagless
  local bare_cap="$CAP" bare_out="$OUT"
  has_invocation "$bare_cap" remove || fail "(b) flag-less teardown did NOT invoke 'sandbox remove' — legacy behavior broke"
  if has_invocation "$bare_cap" stop; then
    fail "(b) flag-less teardown invoked 'sandbox stop' — flag-less must stay REMOVE (byte-preserved)"
  fi
  creates="$(count_real_creates "$bare_cap")"
  [ "$creates" -eq 1 ] || fail "(b) flag-less expected exactly one create, got $creates"
  find_turn_capture "$bare_cap" >/dev/null || fail "(b) flag-less produced no turn exec ('-lc')"
  echo "    PASS: flag-less ⇒ create + exec + remove; 'sandbox stop' NEVER invoked."

  # ── (c) SIDEBAND FRAME: keep-mode create emits exactly one valid bp_sandbox line. ─
  echo "==> (c) SIDEBAND FRAME — keep-mode create emits one bp_sandbox line before claude ..."
  local first_line
  first_line="$(grep -m1 . "$keep_out" || true)"
  [ -n "$first_line" ] || fail "(c) keep-mode create produced NO stdout — the bp_sandbox frame is missing"
  # Valid JSON of the exact shape, carrying the created id, and it is the FIRST
  # non-empty line (before any claude frame).
  FIRST_LINE="$first_line" EXPECT_ID="$FAKE_CREATE_ID" node -e '
    const line = process.env.FIRST_LINE;
    let f;
    try { f = JSON.parse(line); } catch (e) { console.error("not valid JSON:", line); process.exit(1); }
    if (f.type !== "bp_sandbox") { console.error("type is not bp_sandbox:", f.type); process.exit(1); }
    if (f.subtype !== "created") { console.error("subtype is not created:", f.subtype); process.exit(1); }
    if (f.sandbox_id !== process.env.EXPECT_ID) { console.error("sandbox_id mismatch:", f.sandbox_id); process.exit(1); }
  ' || fail "(c) first stdout line is not a valid bp_sandbox created frame carrying $FAKE_CREATE_ID"
  # Exactly ONE bp_sandbox frame in the whole keep-mode stdout.
  local frame_count
  frame_count="$(grep -c '"type":"bp_sandbox"' "$keep_out" || true)"
  [ "$frame_count" = "1" ] || fail "(c) expected exactly ONE bp_sandbox frame in keep-mode stdout, got $frame_count"
  # Flag-less create emits NONE (stdout byte-identical to pre-D137).
  if grep -q 'bp_sandbox' "$bare_out"; then
    fail "(c) flag-less create emitted a bp_sandbox frame — the sideband must be keep-mode ONLY"
  fi
  echo "    PASS: keep-mode ⇒ exactly one valid bp_sandbox frame first; flag-less ⇒ none."

  # ── (d) CHAINED ID ROUND-TRIP: the id a create EMITS plugs into the next invocation. ─
  # A keep-mode create emits a bp_sandbox frame carrying a sandbox_id; harvest that
  # exact id (node -e JSON parse, same as leg (c)) and feed it as the next invocation's
  # --sandbox-id. That second invocation must create NOTHING and its turn exec must
  # target the harvested id. This proves the SHIM's OWN id round-trip only — it says
  # NOTHING about session identity, the Recorder swallow, or chat_sessions persistence
  # (that coverage is the ExUnit capstone connectors-w14-two-turn-stub-proof, D144).
  echo "==> (d) CHAINED ID ROUND-TRIP — harvest a created id, feed it back as --sandbox-id ..."
  drive_shim chainsrc --keep-sandbox
  local chain_src_out="$OUT" src_line harvested
  src_line="$(grep -m1 'bp_sandbox' "$chain_src_out" || true)"
  [ -n "$src_line" ] || fail "(d) source create emitted no bp_sandbox frame to harvest an id from"
  harvested="$(SRC_LINE="$src_line" node -e '
    const f = JSON.parse(process.env.SRC_LINE);
    if (f.type !== "bp_sandbox" || !f.sandbox_id) { console.error("no sandbox_id in frame:", process.env.SRC_LINE); process.exit(1); }
    process.stdout.write(f.sandbox_id);
  ')" || fail "(d) could not harvest sandbox_id from the emitted bp_sandbox frame"
  [ -n "$harvested" ] || fail "(d) harvested sandbox_id is empty"
  drive_shim chaindst --sandbox-id "$harvested" --keep-sandbox
  local chain_dst_cap="$CAP"
  creates="$(count_real_creates "$chain_dst_cap")"
  [ "$creates" -eq 0 ] || fail "(d) chained invocation ran $creates real 'sandbox create' call(s) — a harvested --sandbox-id must skip create entirely"
  local chain_turn
  chain_turn="$(find_turn_capture "$chain_dst_cap")" || fail "(d) no turn exec captured on the chained invocation (no '-lc' token)"
  argv_has_all "$chain_turn" sandbox exec "$harvested" ||
    fail "(d) chained turn exec does not target the harvested id $harvested"
  echo "    PASS: harvested id $harvested round-trips — chained invocation creates nothing, turn exec targets it."
}

main() {
  echo "== Connectors Wave-14 session-sandbox lifecycle proof =="
  echo "== charter: $CHARTER (Wave 14, D137/D138) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim linted, lifecycle markers present, plan printed, nothing spawned."
    return 0
  fi

  run_proof
  echo ""
  echo "== PROVEN: --sandbox-id reuses (zero create, exec targets the id);"
  echo "==         --keep-sandbox STOPS not removes; flag-less stays create+exec+remove;"
  echo "==         keep-mode create emits exactly one valid bp_sandbox frame first. =="
  echo "== The LIVE multi-turn model conversation rides connectors-hg-live-cloud-multiturn. =="
}

main
