#!/usr/bin/env bash
# w35-live-turn-driver.sh — the Connectors Wave-35 LIVE turn driver (charter
# D270/D271/D279). The crown's missing instrument: neither committed harness can
# close the live-success gates — w11-isolated-turn-proof.sh injects a BOGUS key
# and hard-asserts the 401 (a real-key success FAILS it), and
# w14-session-sandbox-proof.sh is hermetic by design (fake vercel, provisions NO
# real sandbox). The human gates connectors-hg-live-isolated-cloud-turn and
# connectors-hg-live-cloud-multiturn need a driver that runs the REAL
# cloud-sandbox-runner.mjs with a REAL ANTHROPIC_API_KEY and asserts SUCCESS.
# This is that driver. It NEVER modifies the shim — it drives it (D270).
#
# Four modes (+ the hermetic --self-test CI wires):
#
#   bake      Create the warm snapshot the egress lock rides on. The deny-all
#             `--allowed-domain` allowlist rides ONLY the snapshot branch of
#             cloud-sandbox-runner.mjs (createSandbox ~742-785: `if (SNAPSHOT)
#             { --allowed-domain … } else { allow-all fallback }`) — and the
#             account has ZERO snapshots today, so without bake every live turn
#             is BOTH cold (npm install inside the 10m backstop) AND unlocked.
#             bake checks the pinned claude version resolves on the npm registry
#             (`npm view`) BEFORE creating anything — a 404 fails LOUD with no
#             sandbox spend. Then: create (plain node24) → in-sandbox
#             `npm i -g @anthropic-ai/claude-code@<pin>` → `vercel sandbox
#             snapshot <id> --stop` → print `export CLOUD_SANDBOX_SNAPSHOT=<id>`.
#             The snapshot is the PRODUCT — bake's teardown removes the bake
#             sandbox but never the snapshot (delete it at the end of the
#             SITTING, D279 spend bound; see connectors/docs/live-gates-packet.md).
#
#   single    One live stream-json turn through the REAL shim:
#             `node cloud-sandbox-runner.mjs --workspace w35-live-ws -- <belt>`.
#             The claude segment mirrors ClaudeChat.cloud_claude_args/2 —
#             stream-json in/out, `--permission-mode plan`, and the three
#             knob-2 tool-removal belts from the ONE CloudPolicy owner:
#             `--tools ""`, a `--settings` deny JSON, and `--disallowedTools`
#             with the EXACT @cloud_disallowed_tools set (cloud_policy.ex:110),
#             emitted LAST (the variadic list needs the argv boundary).
#             Asserts the terminal `{"type":"result"}` frame has `is_error`
#             absent/false and non-empty result text.
#
#   multiturn Two turns, one sandbox, REAL conversation recall. Turn 1:
#             `--keep-sandbox`, claude args carry `--session-id <uuid>` (front
#             of the post-`--` segment, D139), plant a codeword; harvest the
#             sandbox id from the FIRST stdout line ({"type":"bp_sandbox",
#             "subtype":"created","sandbox_id":…}, D137). Turn 2:
#             `--sandbox-id <harvested> --keep-sandbox`, claude args carry
#             `--resume <uuid>`; assert the result frame recalls the codeword.
#             CRITICAL (the reason this driver exists): the shim reuses only the
#             FILESYSTEM across stop/resume — conversation recall is claude's
#             OWN --session-id/--resume session flags, which w14 never pinned.
#
#   teardown  Explicit cleanup: `teardown <sandbox-id>...` removes each id,
#             sweeps its stop-snapshots, and asserts `sandbox ls` AND
#             `sandbox snapshots ls` are empty of the session. The SAME logic
#             runs as an EXIT trap in every live mode (even on error/Ctrl-C).
#
# KEY CUSTODY (D110, the W30 belt is load-bearing): ANTHROPIC_API_KEY is read
# from the driver's OWN env ONLY — the driver never echoes it, never puts it on
# argv, never `set -x`s around it. The shim forwards it into the sandbox as its
# single explicit `--env ANTHROPIC_API_KEY=…` pair (runTurn, runner.mjs:826-831)
# — never an ambient var of the local vercel child (D121 allowlist). The
# self-test PLANTS a key and proves it appears ONLY inside that one --env pair
# in the recorded argv and NEVER in the driver's own stdout/stderr.
#
# PREFLIGHT FIRST (D267): every live mode runs preflight-vercel.sh before any
# vercel invocation and refuses LOUD (named, exit 1) unless it prints
# PREFLIGHT OK. EGRESS HONESTY: with CLOUD_SANDBOX_SNAPSHOT set the create argv
# carries `--allowed-domain` (deny-all-except, proven from recorded argv in the
# self-test); without it the driver WARNS LOUDLY that the turn is ALLOW-ALL —
# never a silent unlocked turn.
#
# --self-test (hermetic, no credentials, no real Vercel — the w14/w12 idiom):
# a generated fake `vercel` (via CLOUD_SANDBOX_VERCEL_BIN + PATH) records every
# invocation's argv NUL-delimited and emulates just enough state (create/stop/
# remove/snapshot/ls) for the driver's assertions to bite. Legs: preflight
# refusal (zero creates), single (snapshot ⇒ --allowed-domain on create argv),
# egress warn (no snapshot ⇒ loud allow-all), multiturn (session-id turn 1,
# resume turn 2, harvested-id targeting, full teardown lifecycle incl.
# snapshots-delete), MUTATION (W35_MUTATE=drop-resume ⇒ the resume-wiring check
# goes RED — the self-test can fail), bake (npm view BEFORE create, order
# proven from a shared sequence log; the 404 leg creates nothing), explicit
# teardown, and planted-key custody over every leg's captures + driver output.
# W35_MUTATE and W35_CODEWORD are self-test hooks — the driver REFUSES
# W35_MUTATE outside the self-test (fail closed).
#
# CI: ONE named blocking step in .github/workflows/connectors.yml (D267
# precedent — the workflow hardcodes proof scripts BY NAME).
#
# Gate:
#   bash scripts/connectors/w35-live-turn-driver.sh --self-test \
#     && shellcheck -S error scripts/connectors/w35-live-turn-driver.sh
#
# Charter: .claude/workflows/bp-connectors-charter.md (Wave 35, D270/D271/D279).
# Human packet: connectors/docs/live-gates-packet.md (the ONE consolidated
# sitting that closes the live rows). Siblings: w11 (401 wire proof, untouched),
# w14 (hermetic lifecycle, untouched), preflight-vercel.sh (D267).
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w35-live-turn-driver.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"
PREFLIGHT="$HERE/preflight-vercel.sh"
PIN_FILE="$HERE/cloud-claude-pinned-version.txt"

VERCEL_BIN="${CLOUD_SANDBOX_VERCEL_BIN:-vercel}"
SCOPE="${CLOUD_SANDBOX_SCOPE:-guerrilla}"
WORKSPACE="${W35_WORKSPACE:-w35-live-ws}"
export CLOUD_SANDBOX_TIMEOUT="${CLOUD_SANDBOX_TIMEOUT:-10m}"
RUNTIME="${CLOUD_SANDBOX_RUNTIME:-node24}"

# Self-test hooks. W35_MUTATE is honored ONLY under the self-test (fail closed
# in live modes — a mutated live turn would fabricate a green).
SELF_TEST_ENV="${W35_SELF_TEST:-0}"
MUTATE="${W35_MUTATE:-}"

# The knob-2 tool-removal belt, mirroring ClaudeChat.cloud_claude_args/2 from
# the single CloudPolicy owner (cloud_policy.ex:110 @cloud_disallowed_tools).
# --disallowedTools is LAST: its variadic tool list needs the argv boundary.
CLOUD_DENY_TOOLS=(Bash Edit Write Read NotebookEdit WebFetch WebSearch Task)
SETTINGS_DENY_JSON='{"permissions":{"deny":["Bash","Edit","Write","Read","NotebookEdit","WebFetch","WebSearch","Task"]}}'
BELT=(
  --input-format stream-json
  --output-format stream-json
  --include-partial-messages
  --verbose
  --permission-mode plan
  --tools ""
  --settings "$SETTINGS_DENY_JSON"
  --disallowedTools "${CLOUD_DENY_TOOLS[@]}"
)

TRACKED_IDS=()
BAKE_MODE=0
TRAP_ARMED=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-35 LIVE turn driver (D270/D271/D279).

  bake                    LIVE: bake the warm snapshot (npm-view pin check FIRST,
                          then create + in-sandbox install + snapshot --stop).
                          Prints 'export CLOUD_SANDBOX_SNAPSHOT=<id>'.
  single                  LIVE: one real stream-json turn through the shim;
                          asserts the result frame is_error absent/false.
  multiturn               LIVE: two turns, one sandbox — --session-id then
                          --resume; asserts the codeword is recalled.
  teardown <id>...        LIVE: remove the given sandbox id(s), sweep their
                          stop-snapshots, assert ls + snapshots ls clean.
  --self-test             Hermetic self-test (fake vercel; no credentials, no
                          real Vercel). This is what CI runs.
  -h, --help              This text.

Every live mode runs preflight-vercel.sh FIRST and refuses loud on any miss.
ANTHROPIC_API_KEY comes from THIS shell's env only (D110) — the shim forwards
it as its single --env pair; the driver never prints it. Spend bound (D279):
<=2 sandboxes, <=10m each (CLOUD_SANDBOX_TIMEOUT backstop), bake snapshots
deleted the same sitting. Human packet: connectors/docs/live-gates-packet.md.
EOF
}

fail() {
  # $1 = tag, $2 = message. LOUD, named, exit 1.
  echo "W35 FAIL [$1]: $2" >&2
  exit 1
}

warn() {
  echo "W35 WARN [$1]: $2" >&2
}

note() {
  echo "W35: $*"
}

vc() {
  # Every driver-owned vercel invocation goes through here (the shim runs its
  # own). stdin from /dev/null: a would-be prompt gets EOF, never a hang.
  "$VERCEL_BIN" "$@" </dev/null
}

mint_uuid() {
  node -e 'process.stdout.write(require("crypto").randomUUID())'
}

preflight_or_refuse() {
  # Fail-closed guards first: no mutation knob outside the self-test, no empty
  # scope, never the Hobby scope (its quota overrun PAUSES creation 30 days).
  if [ -n "$MUTATE" ] && [ "$SELF_TEST_ENV" != "1" ]; then
    fail "mutation-live" "W35_MUTATE='$MUTATE' is a SELF-TEST hook — refusing to run a mutated LIVE mode"
  fi
  [ -n "$SCOPE" ] || fail "scope-empty" "CLOUD_SANDBOX_SCOPE is empty — refusing an unscoped live turn"
  if [ "$SCOPE" != "guerrilla" ]; then
    warn "scope-nonstandard" "scope '$SCOPE' is not 'guerrilla' — the proven Pro team is guerrilla (Hobby PAUSES on quota overrun)"
  fi
  [ -f "$SHIM" ] || fail "shim-missing" "cloud-sandbox-runner.mjs not found next to this driver"
  command -v node >/dev/null 2>&1 || fail "node-missing" "'node' not found on PATH"

  note "preflight (D267): bash $PREFLIGHT"
  local out rc
  out="$(CONNECTORS_VERCEL_SCOPE="$SCOPE" bash "$PREFLIGHT" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q "PREFLIGHT OK"; then
    fail "preflight" "preflight-vercel.sh did not print PREFLIGHT OK (exit $rc) — fix the named miss above before any live turn"
  fi
}

egress_honesty() {
  # The deny-all egress lock rides ONLY the shim's snapshot branch. No
  # snapshot ⇒ fallback boot ⇒ ALLOW-ALL. Loud, never silent (D270).
  if [ -n "${CLOUD_SANDBOX_SNAPSHOT:-}" ]; then
    note "egress: CLOUD_SANDBOX_SNAPSHOT=${CLOUD_SANDBOX_SNAPSHOT} — create rides the snapshot branch (deny-all-except via --allowed-domain)"
  else
    warn "egress-allow-all" "CLOUD_SANDBOX_SNAPSHOT is UNSET — the shim's fallback boot has NO egress lock (allow-all; the --allowed-domain allowlist rides ONLY the snapshot branch). Run '$SCRIPT_NAME bake' first and export the printed snapshot id."
  fi
}

# ── Teardown (EXIT trap in live modes + the explicit `teardown` mode) ─────────

sweep_snapshots_for() {
  # Best-effort: list snapshots, delete every line mentioning the sandbox id
  # (first whitespace token = snapshot id). A parse miss surfaces as a
  # lingering-snapshot FAIL in assert_clean — fail closed, never silent.
  local id="$1" ls_out line snap
  ls_out="$(vc sandbox snapshots ls 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      *"$id"*)
        snap="${line%% *}"
        [ -n "$snap" ] || continue
        note "teardown: deleting stop-snapshot $snap (sandbox $id)"
        vc sandbox snapshots delete "$snap" >/dev/null 2>&1 || warn "snapshot-delete" "could not delete snapshot $snap — delete it manually (vercel sandbox snapshots delete $snap)"
        ;;
    esac
  done <<EOF2
$ls_out
EOF2
}

assert_clean() {
  # End-of-run honesty: the session left NOTHING behind. sandbox ls AND
  # snapshots ls must be empty of every tracked id (D279).
  local id ls_out snaps_out
  ls_out="$(vc sandbox ls --scope "$SCOPE" 2>/dev/null || true)"
  for id in ${TRACKED_IDS[@]+"${TRACKED_IDS[@]}"}; do
    if printf '%s' "$ls_out" | grep -q "$id"; then
      fail "teardown-lingering-sandbox" "sandbox $id still present in 'vercel sandbox ls --scope $SCOPE' after teardown — remove it manually (vercel sandbox remove $id --scope $SCOPE)"
    fi
  done
  if [ "$BAKE_MODE" -ne 1 ]; then
    snaps_out="$(vc sandbox snapshots ls 2>/dev/null || true)"
    for id in ${TRACKED_IDS[@]+"${TRACKED_IDS[@]}"}; do
      if printf '%s' "$snaps_out" | grep -q "$id"; then
        fail "teardown-lingering-snapshot" "a snapshot for sandbox $id survives in 'vercel sandbox snapshots ls' — delete it manually (vercel sandbox snapshots ls / delete)"
      fi
    done
  fi
  if [ "$BAKE_MODE" -eq 1 ]; then
    note "TEARDOWN CLEAN: bake sandbox removed; the bake snapshot is the PRODUCT (delete it at the end of the sitting, D279)"
  else
    note "TEARDOWN CLEAN: no session sandboxes or stop-snapshots remain"
  fi
}

live_teardown() {
  local rc=$? id
  set +e
  for id in ${TRACKED_IDS[@]+"${TRACKED_IDS[@]}"}; do
    note "teardown: vercel sandbox remove $id --scope $SCOPE"
    vc sandbox remove "$id" --scope "$SCOPE" >/dev/null 2>&1
    # `remove` does NOT delete stop-snapshots — sweep them (never in bake mode:
    # bake's snapshot is the product this whole mode exists to produce).
    if [ "$BAKE_MODE" -ne 1 ]; then
      sweep_snapshots_for "$id"
    fi
  done
  # assert_clean fails loud (exit 1) on any lingering artifact; otherwise the
  # run's own exit code stands.
  assert_clean || exit 1
  exit "$rc"
}

arm_teardown_trap() {
  if [ "$TRAP_ARMED" -eq 0 ]; then
    trap live_teardown EXIT
    TRAP_ARMED=1
  fi
}

# ── Turn plumbing ─────────────────────────────────────────────────────────────

user_frame() {
  # $1 = message text (driver-controlled: alnum/space/hyphen/colon/period only,
  # so inlining into the JSON frame is safe).
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$1"
}

run_shim_turn() {
  # $1=outfile $2=errfile $3=frame-text; remaining args = shim pre/post argv
  # (everything after the fixed --workspace). The key rides the driver's OWN
  # env into the shim implicitly (D110) — never argv, never a log line.
  local outf="$1" errf="$2" text="$3"
  shift 3
  user_frame "$text" | node "$SHIM" --workspace "$WORKSPACE" "$@" >"$outf" 2>"$errf"
}

result_text_of() {
  # Parse the LAST {"type":"result"} frame of an NDJSON capture; print its
  # result text; rc 1 (with a stderr reason) when absent / is_error / empty.
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    let res = null;
    for (const l of lines) {
      try { const f = JSON.parse(l); if (f && f.type === "result") res = f; } catch {}
    }
    if (!res) { console.error("no result frame in turn output"); process.exit(1); }
    if (res.is_error) { console.error("result frame carries is_error:true (subtype " + (res.subtype || "?") + ")"); process.exit(1); }
    const t = typeof res.result === "string" ? res.result : JSON.stringify(res.result ?? "");
    if (!t) { console.error("result frame has empty result text"); process.exit(1); }
    process.stdout.write(t);
  ' "$1"
}

harvest_sandbox_id() {
  # The FIRST bp_sandbox created frame (D137) — the session's durable binding.
  local line
  line="$(grep -m1 'bp_sandbox' "$1" || true)"
  [ -n "$line" ] || return 1
  SRC_LINE="$line" node -e '
    const f = JSON.parse(process.env.SRC_LINE);
    if (f.type !== "bp_sandbox" || f.subtype !== "created" || !f.sandbox_id) process.exit(1);
    process.stdout.write(f.sandbox_id);
  '
}

shim_err_tail() {
  # Shim stderr is already W30-sanitized at message construction; bound it
  # anyway (last 20 lines) for the loud failure paths.
  tail -n 20 "$1" 2>/dev/null | sed 's/^/    shim| /' >&2
}

# ── Modes ─────────────────────────────────────────────────────────────────────

mode_bake() {
  preflight_or_refuse
  local pin id snap_out snap create_out install_rc
  pin="$(cat "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$pin" ] || fail "bake-no-pin" "$PIN_FILE is absent/empty — the bake installs a PINNED claude (D176/D180), never latest"

  # Registry check BEFORE any create: a 404 here costs zero sandboxes.
  note "bake: npm view @anthropic-ai/claude-code@$pin version (registry check BEFORE create)"
  local view_out
  if ! view_out="$(npm view "@anthropic-ai/claude-code@$pin" version 2>&1)" || ! printf '%s' "$view_out" | grep -q "$pin"; then
    fail "bake-npm-pin" "pinned claude $pin does not resolve on the npm registry — nothing was created. npm said: $(printf '%.200s' "$view_out")"
  fi
  note "bake: pin $pin resolves on the registry"

  BAKE_MODE=1
  arm_teardown_trap
  note "bake: vercel sandbox create --runtime $RUNTIME --timeout $CLOUD_SANDBOX_TIMEOUT (scope $SCOPE)"
  create_out="$(vc sandbox create --runtime "$RUNTIME" --timeout "$CLOUD_SANDBOX_TIMEOUT" --tag purpose=w35-bake --scope "$SCOPE" 2>&1)" ||
    fail "bake-create" "vercel sandbox create failed: $(printf '%.200s' "$create_out")"
  id="$(printf '%s' "$create_out" | tr -s '[:space:]' ' ' | awk '{print $NF}')"
  [ -n "$id" ] || fail "bake-create" "vercel sandbox create returned no sandbox id"
  TRACKED_IDS+=("$id")
  note "bake: sandbox $id created; installing claude@$pin in-sandbox"

  vc sandbox exec "$id" --scope "$SCOPE" -- npm i -g "@anthropic-ai/claude-code@$pin" >/dev/null 2>&1
  install_rc=$?
  [ "$install_rc" -eq 0 ] || fail "bake-install" "in-sandbox 'npm i -g @anthropic-ai/claude-code@$pin' failed (exit $install_rc)"

  note "bake: vercel sandbox snapshot $id --stop (one-time, off the hot path — D10)"
  snap_out="$(vc sandbox snapshot "$id" --stop --scope "$SCOPE" 2>&1)" ||
    fail "bake-snapshot" "vercel sandbox snapshot failed: $(printf '%.200s' "$snap_out")"
  snap="$(printf '%s' "$snap_out" | tr -s '[:space:]' ' ' | awk '{print $NF}')"
  [ -n "$snap" ] || fail "bake-snapshot" "snapshot verb returned no snapshot id"

  echo "W35 BAKE OK: snapshot $snap (claude $pin baked; egress lock now available)"
  echo "    export CLOUD_SANDBOX_SNAPSHOT=$snap"
  echo "    Spend bound (D279): delete this snapshot at the end of the sitting:"
  echo "    vercel sandbox snapshots delete $snap"
}

mode_single() {
  preflight_or_refuse
  egress_honesty
  arm_teardown_trap
  local out err txt rc
  out="$(mktemp)" err="$(mktemp)"
  note "single: one live stream-json turn through the shim (workspace $WORKSPACE)"
  run_shim_turn "$out" "$err" "Reply with exactly: W35-LIVE-OK" -- "${BELT[@]}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    shim_err_tail "$err"
    fail "single-shim-exit" "shim exited $rc — the turn did not complete"
  fi
  if ! txt="$(result_text_of "$out")"; then
    shim_err_tail "$err"
    fail "single-result" "no clean result frame (is_error must be absent/false with non-empty text) — a 401 here means the key is invalid, see the packet's failure signatures"
  fi
  echo "W35 SINGLE PASS: result frame is_error=false; text: $(printf '%.160s' "$txt")"
  rm -f "$out" "$err"
}

mode_multiturn() {
  preflight_or_refuse
  egress_honesty
  arm_teardown_trap
  local uuid codeword out1 err1 out2 err2 sid txt2 rc
  uuid="$(mint_uuid)" || fail "uuid" "could not mint a session uuid"
  codeword="${W35_CODEWORD:-w35-cw-$(mint_uuid | cut -c1-8)}"
  out1="$(mktemp)" err1="$(mktemp)" out2="$(mktemp)" err2="$(mktemp)"

  # Turn 1 — CREATE in keep mode; session flag at the FRONT of the post-`--`
  # segment (D139); plant the codeword.
  note "multiturn: turn 1 (create, --keep-sandbox, --session-id $uuid)"
  run_shim_turn "$out1" "$err1" "Remember this codeword: $codeword. Reply OK." \
    --keep-sandbox -- --session-id "$uuid" "${BELT[@]}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    shim_err_tail "$err1"
    fail "multiturn-turn1-exit" "turn 1 shim exited $rc"
  fi
  sid="$(harvest_sandbox_id "$out1")" ||
    fail "multiturn-no-sandbox-frame" "turn 1 emitted no bp_sandbox created frame — cannot bind the session (D137)"
  TRACKED_IDS+=("$sid")
  result_text_of "$out1" >/dev/null || {
    shim_err_tail "$err1"
    fail "multiturn-turn1-result" "turn 1 result frame is missing/is_error"
  }
  note "multiturn: turn 1 OK; sandbox $sid bound"

  # Turn 2 — REUSE the harvested sandbox; conversation recall is claude's OWN
  # --resume (the filesystem alone recalls nothing — D270's crux).
  local resume_flags=(--resume "$uuid")
  if [ "$MUTATE" = "drop-resume" ] && [ "$SELF_TEST_ENV" = "1" ]; then
    warn "mutation-drop-resume" "SELF-TEST MUTATION: turn 2 omits --resume (the wiring check must go RED)"
    resume_flags=()
  fi
  note "multiturn: turn 2 (--sandbox-id $sid, --resume $uuid)"
  run_shim_turn "$out2" "$err2" "What was the codeword? Reply with only the codeword." \
    --sandbox-id "$sid" --keep-sandbox -- ${resume_flags[@]+"${resume_flags[@]}"} "${BELT[@]}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    shim_err_tail "$err2"
    fail "multiturn-turn2-exit" "turn 2 shim exited $rc"
  fi
  if ! txt2="$(result_text_of "$out2")"; then
    shim_err_tail "$err2"
    fail "multiturn-turn2-result" "turn 2 result frame is missing/is_error"
  fi
  if ! printf '%s' "$txt2" | grep -q "$codeword"; then
    fail "multiturn-recall" "turn 2 did NOT recall the codeword — the filesystem resumed but the conversation did not; check the --resume/--session-id wiring (got: $(printf '%.160s' "$txt2"))"
  fi
  echo "W35 MULTITURN PASS: codeword recalled through --resume $uuid on sandbox $sid"
  rm -f "$out1" "$err1" "$out2" "$err2"
}

mode_teardown() {
  [ "$#" -ge 1 ] || fail "teardown-usage" "teardown needs at least one sandbox id: $SCRIPT_NAME teardown <id>..."
  preflight_or_refuse
  TRACKED_IDS=("$@")
  arm_teardown_trap
  note "teardown: sweeping ${#TRACKED_IDS[@]} sandbox id(s)"
  # The trap does the work on exit; nothing else to do here.
}

# ── Hermetic self-test ────────────────────────────────────────────────────────

self_test() {
  command -v node >/dev/null 2>&1 || { echo "ERROR: 'node' not found on PATH" >&2; exit 1; }
  [ -f "$SHIM" ] || { echo "ERROR: shim missing: $SHIM" >&2; exit 1; }
  [ -f "$PREFLIGHT" ] || { echo "ERROR: preflight missing: $PREFLIGHT" >&2; exit 1; }

  # td is deliberately NOT local: the EXIT trap fires after this function's
  # locals are gone, so a local td would be unbound at cleanup time.
  local fails=0 bash_bin pin
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' EXIT
  bash_bin="$(command -v bash)"
  pin="$(cat "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$pin" ] || pin="0.0.0-selftest"

  local PLANTED_KEY="sk-ant-w35-planted-$$-DO-NOT-LEAK"
  local CW="w35-fake-codeword"
  local FAKE_ID="sb_fake_w35"

  say() { echo "  self-test: $*"; }
  red() {
    echo "  FAIL: $*" >&2
    fails=$((fails + 1))
  }

  # Generate a per-leg fake bin dir: `vercel` (argv-recording, stateful) and
  # `npm` (pin resolver, 404-able). Both append to a shared sequence log so
  # ORDER (npm view BEFORE create) is provable, not assumed.
  make_fakes() {
    local legdir="$1" capdir="$1/cap" seq="$1/seq" bin="$1/bin"
    mkdir -p "$capdir" "$bin" "$legdir/tmp"
    : >"$seq"
    cat >"$bin/vercel" <<FAKE
#!/usr/bin/env bash
# Fake vercel for the W35 self-test: records argv (NUL-delimited), appends to
# the shared sequence log, and emulates stateful create/stop/remove/snapshot/ls.
set -u
capdir="$capdir"
seq="$seq"
cw="$CW"
pin="$pin"
fake_id="$FAKE_ID"
mkdir -p "\$capdir"
n=0
while ! ( set -o noclobber; : >"\$capdir/lock.\$n" ) 2>/dev/null; do
  n=\$((n + 1))
done
: >"\$capdir/argv.\$n"
for a in "\$@"; do
  printf '%s\0' "\$a" >>"\$capdir/argv.\$n"
done
printf 'vercel %s %s %s\n' "\${1:-}" "\${2:-}" "\${3:-}" >>"\$seq"
help=0 lc=0 verprobe=0
for a in "\$@"; do
  [ "\$a" = "--help" ] && help=1
  [ "\$a" = "-lc" ] && lc=1
  case "\$a" in *"claude --version"*) verprobe=1 ;; esac
done
case "\${1:-}" in
  whoami) echo fake-user; exit 0 ;;
  sandbox)
    case "\${2:-}" in
      create)
        [ "\$help" = 1 ] && exit 0
        : >"\$capdir/state.created"
        echo "\$fake_id"; exit 0 ;;
      exec)
        if [ "\$verprobe" = 1 ]; then echo "\$pin"; exit 0; fi
        if [ "\$lc" = 1 ]; then
          printf '{"type":"result","subtype":"success","is_error":false,"result":"OK W35-LIVE-OK %s"}\n' "\$cw"
          exit 0
        fi
        exit 0 ;;
      stop)   : >"\$capdir/state.stopped"; exit 0 ;;
      remove) : >"\$capdir/state.removed"; exit 0 ;;
      snapshot) echo "snap_fake_w35_product"; exit 0 ;;
      snapshots)
        case "\${3:-}" in
          ls)
            if [ -f "\$capdir/state.stopped" ] && [ ! -f "\$capdir/state.snapdeleted" ]; then
              echo "snap_fake_stop \$fake_id"
            fi
            exit 0 ;;
          delete) : >"\$capdir/state.snapdeleted"; exit 0 ;;
        esac
        exit 0 ;;
      ls | list)
        if [ -f "\$capdir/state.created" ] && [ ! -f "\$capdir/state.removed" ]; then
          echo "\$fake_id"
        fi
        exit 0 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
    chmod +x "$bin/vercel"
    cat >"$bin/npm" <<FAKE
#!/usr/bin/env bash
set -u
seq="$seq"
pin="$pin"
if [ "\${1:-}" = "view" ]; then
  printf 'npm-view %s\n' "\${2:-}" >>"\$seq"
  if [ "\${FAKE_NPM_MODE:-}" = "404" ]; then
    echo "npm error code E404" >&2
    exit 1
  fi
  echo "\$pin"
  exit 0
fi
exit 0
FAKE
    chmod +x "$bin/npm"
  }

  # Drive the real driver ($0) in a given mode against a leg's fakes.
  # drive <legdir> <snapshot|""> <key|""> <mutate|""> <mode...>
  # Globals set: DRV_OUT (combined output), DRV_RC. Hygiene: the outer shell's
  # ANTHROPIC_API_KEY / CLOUD_SANDBOX_SNAPSHOT / W35_MUTATE are ALWAYS stripped
  # first, then re-added only when the leg asks — a live operator's exported
  # env can never bleed into a self-test leg.
  drive() {
    local legdir="$1" snapshot="$2" key="$3" mutate="$4"
    shift 4
    local envs=(
      "PATH=$legdir/bin:$PATH"
      "CLOUD_SANDBOX_VERCEL_BIN=$legdir/bin/vercel"
      "W35_SELF_TEST=1"
      "W35_CODEWORD=$CW"
      "TMPDIR=$legdir/tmp"
    )
    [ -n "$snapshot" ] && envs+=("CLOUD_SANDBOX_SNAPSHOT=$snapshot")
    [ -n "$key" ] && envs+=("ANTHROPIC_API_KEY=$key")
    [ -n "$mutate" ] && envs+=("W35_MUTATE=$mutate")
    DRV_OUT="$(env -u ANTHROPIC_API_KEY -u CLOUD_SANDBOX_SNAPSHOT -u W35_MUTATE \
      "${envs[@]}" "$bash_bin" "$0" "$@" 2>&1)"
    DRV_RC=$?
  }

  expect() {
    # expect <desc> <want_rc> <marker...>
    local desc="$1" want="$2"
    shift 2
    if [ "$DRV_RC" != "$want" ]; then
      red "$desc — expected exit $want, got $DRV_RC"
      printf '%s\n' "$DRV_OUT" | sed 's/^/        /' >&2
      return 1
    fi
    local m
    for m in "$@"; do
      if ! printf '%s' "$DRV_OUT" | grep -qF -- "$m"; then
        red "$desc — exit $DRV_RC correct but missing marker '$m'"
        printf '%s\n' "$DRV_OUT" | sed 's/^/        /' >&2
        return 1
      fi
    done
    say "$desc (exit $DRV_RC)"
    return 0
  }

  # ── argv predicates over NUL-delimited captures (w14 idiom) ────────────────
  any_capture_with() {
    # any_capture_with <capdir> <fixed-substring>  (substring within any record)
    local capdir="$1" needle="$2" f
    for f in "$capdir"/argv.*; do
      [ -e "$f" ] || continue
      grep -zqF -- "$needle" "$f" && return 0
    done
    return 1
  }
  real_create_capture() {
    # Echo the capture file of the REAL `sandbox create` (excludes the --help
    # retention probe); rc 1 when none.
    local capdir="$1" f
    for f in "$capdir"/argv.*; do
      [ -e "$f" ] || continue
      if grep -zxqF -- "sandbox" "$f" && grep -zxqF -- "create" "$f" && ! grep -zxqF -- "--help" "$f"; then
        echo "$f"
        return 0
      fi
    done
    return 1
  }
  lc_capture_with() {
    # Echo the -lc turn capture whose script contains the given substring.
    local capdir="$1" needle="$2" f
    for f in "$capdir"/argv.*; do
      [ -e "$f" ] || continue
      if grep -zxqF -- "-lc" "$f" && grep -zqF -- "$needle" "$f"; then
        echo "$f"
        return 0
      fi
    done
    return 1
  }
  key_custody_check() {
    # The planted key appears ONLY as records exactly equal to
    # ANTHROPIC_API_KEY=<key> (the shim's single --env pair value), each in a
    # capture that also carries the --env flag; and NEVER in the driver's own
    # combined output. At least one such pair must exist (the key DID cross).
    local capdir="$1" desc="$2" f total=0 n_any n_exact
    for f in "$capdir"/argv.*; do
      [ -e "$f" ] || continue
      n_any="$(grep -zcF -- "$PLANTED_KEY" "$f" 2>/dev/null | tr -d '[:space:]')"
      n_any="${n_any:-0}"
      [ "$n_any" -eq 0 ] && continue
      n_exact="$(grep -zxcF -- "ANTHROPIC_API_KEY=$PLANTED_KEY" "$f" 2>/dev/null | tr -d '[:space:]')"
      n_exact="${n_exact:-0}"
      if [ "$n_any" != "$n_exact" ]; then
        red "$desc — the planted key appears OUTSIDE the exact ANTHROPIC_API_KEY=<key> record in $f (leak)"
        return 1
      fi
      if ! grep -zxqF -- "--env" "$f"; then
        red "$desc — a capture carries the key without an --env flag record ($f)"
        return 1
      fi
      total=$((total + n_exact))
    done
    if [ "$total" -eq 0 ]; then
      red "$desc — the planted key never crossed as an --env pair (no turn dispatched?)"
      return 1
    fi
    if printf '%s' "$DRV_OUT" | grep -qF -- "$PLANTED_KEY"; then
      red "$desc — the planted key LEAKED into the driver's own stdout/stderr"
      return 1
    fi
    say "$desc: key rides ONLY the --env pair ($total record(s)); never in driver output"
    return 0
  }

  echo "== $SCRIPT_NAME --self-test (hermetic; fake vercel; no credentials, no real Vercel) =="

  # LEG 0 — preflight refusal: key unset ⇒ loud named miss, ZERO creates.
  local leg="$td/l0"
  make_fakes "$leg"
  drive "$leg" "" "" "" single
  expect "preflight refusal (key unset) -> loud named miss, exit 1" 1 "anthropic-key"
  if real_create_capture "$leg/cap" >/dev/null; then
    red "preflight-refusal leg still ran 'sandbox create' — refusal must precede any vercel spend"
  else
    say "preflight refusal: ZERO sandbox creates (refusal precedes spend)"
  fi

  # LEG 1 — single, snapshot set: PASS + egress lock on the create argv.
  leg="$td/l1"
  make_fakes "$leg"
  drive "$leg" "snap_fake_w35_product" "$PLANTED_KEY" "" single
  expect "single (snapshot set) -> W35 SINGLE PASS" 0 "PREFLIGHT OK" "W35 SINGLE PASS" "TEARDOWN CLEAN"
  local createf
  if createf="$(real_create_capture "$leg/cap")"; then
    if grep -zxqF -- "--allowed-domain" "$createf" && grep -zxqF -- "--snapshot" "$createf"; then
      say "egress lock: create argv carries --snapshot AND --allowed-domain (deny-all-except)"
    else
      red "single leg create argv lacks --allowed-domain/--snapshot with CLOUD_SANDBOX_SNAPSHOT set"
    fi
  else
    red "single leg produced no real 'sandbox create' capture"
  fi
  any_capture_with "$leg/cap" "--disallowedTools" || red "single leg turn script lacks the --disallowedTools belt"
  key_custody_check "$leg/cap" "key custody (single leg)"

  # LEG 2 — single, NO snapshot: loud allow-all warning, no --allowed-domain.
  leg="$td/l2"
  make_fakes "$leg"
  drive "$leg" "" "$PLANTED_KEY" "" single
  expect "single (no snapshot) -> LOUD allow-all warning" 0 "W35 WARN [egress-allow-all]" "W35 SINGLE PASS"
  if createf="$(real_create_capture "$leg/cap")"; then
    if grep -zxqF -- "--allowed-domain" "$createf"; then
      red "no-snapshot create argv carries --allowed-domain — the fallback path should be the unlocked one being warned about"
    else
      say "no-snapshot create argv has no --allowed-domain (matches the loud warning)"
    fi
  else
    red "no-snapshot leg produced no real create capture"
  fi

  # LEG 3 — multiturn: session-id turn 1, resume turn 2, harvested id, full
  # teardown lifecycle (stop from the shim, remove + snapshots delete from the
  # driver, both ls sweeps clean).
  leg="$td/l3"
  make_fakes "$leg"
  drive "$leg" "snap_fake_w35_product" "$PLANTED_KEY" "" multiturn
  expect "multiturn -> recall + clean teardown" 0 "W35 MULTITURN PASS" "TEARDOWN CLEAN"
  local capdir="$leg/cap" n_creates=0 f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    if grep -zxqF -- "sandbox" "$f" && grep -zxqF -- "create" "$f" && ! grep -zxqF -- "--help" "$f"; then
      n_creates=$((n_creates + 1))
    fi
  done
  [ "$n_creates" -eq 1 ] && say "multiturn: exactly ONE real create (turn 2 reused)" ||
    red "multiturn expected exactly 1 real create, got $n_creates"
  lc_capture_with "$capdir" "--session-id" >/dev/null && say "turn 1 claude args carry --session-id" ||
    red "no -lc turn script carries --session-id (turn-1 session flag missing)"
  local resumef
  if resumef="$(lc_capture_with "$capdir" "--resume")"; then
    if grep -zxqF -- "$FAKE_ID" "$resumef" && grep -zxqF -- "exec" "$resumef"; then
      say "turn 2 claude args carry --resume AND the exec targets the harvested id $FAKE_ID"
    else
      red "the --resume turn does not exec the harvested sandbox id"
    fi
  else
    red "no -lc turn script carries --resume (turn-2 resume wiring missing)"
  fi
  any_capture_with "$capdir" "snapshots" || red "multiturn teardown never touched 'sandbox snapshots'"
  if [ -f "$capdir/state.removed" ]; then
    say "driver teardown invoked 'sandbox remove'"
  else
    red "driver teardown never invoked 'sandbox remove'"
  fi
  [ -f "$capdir/state.snapdeleted" ] && say "driver teardown deleted the stop-snapshot (snapshots delete invoked)" ||
    red "driver teardown never invoked 'sandbox snapshots delete' for the stop-snapshot"
  key_custody_check "$capdir" "key custody (multiturn leg)"

  # LEG 4 — MUTATION: drop the resume flag; the leg-3 resume-wiring check MUST
  # go RED on these captures. This proves that check CAN fail
  # (make-the-check-able-to-fail): a driver that stopped emitting --resume
  # would be caught here, not shipped green.
  leg="$td/l4"
  make_fakes "$leg"
  drive "$leg" "snap_fake_w35_product" "$PLANTED_KEY" "drop-resume" multiturn
  expect "mutation leg driver run (announced, still completes against the fake)" 0 "mutation-drop-resume"
  if lc_capture_with "$leg/cap" "--resume" >/dev/null; then
    red "MUTATION leg: --resume still present after drop-resume — the mutation did not take, the wiring check cannot be trusted"
  else
    echo "  self-test: MUTATION LEG RED (as required): with W35_MUTATE=drop-resume, NO -lc turn script carries --resume — the resume-wiring check correctly FAILS when the flag is dropped"
  fi

  # LEG 5 — bake: npm view BEFORE create (order from the shared seq log),
  # in-sandbox pinned install, snapshot verb, sandbox removed, snapshot kept.
  leg="$td/l5"
  make_fakes "$leg"
  drive "$leg" "" "$PLANTED_KEY" "" bake
  expect "bake -> W35 BAKE OK + snapshot id printed" 0 "W35 BAKE OK" "export CLOUD_SANDBOX_SNAPSHOT=snap_fake_w35_product"
  local seqf="$leg/seq" view_ln create_ln
  view_ln="$(grep -nm1 '^npm-view' "$seqf" | cut -d: -f1 || true)"
  create_ln="$(grep -nm1 '^vercel sandbox create' "$seqf" | cut -d: -f1 || true)"
  if [ -n "$view_ln" ] && [ -n "$create_ln" ] && [ "$view_ln" -lt "$create_ln" ]; then
    say "bake order: npm view (seq line $view_ln) BEFORE sandbox create (seq line $create_ln)"
  else
    red "bake did not check the npm registry BEFORE creating (view=$view_ln create=$create_ln)"
  fi
  any_capture_with "$leg/cap" "@anthropic-ai/claude-code@$pin" && say "bake installs the PINNED claude ($pin)" ||
    red "bake install argv lacks the pinned spec @anthropic-ai/claude-code@$pin"
  any_capture_with "$leg/cap" "snapshot" || red "bake never invoked the snapshot verb"
  [ -f "$leg/cap/state.removed" ] && say "bake teardown removed the bake sandbox" ||
    red "bake teardown did not remove the bake sandbox"
  [ -f "$leg/cap/state.snapdeleted" ] && red "bake teardown DELETED the product snapshot — it must survive the run" ||
    say "bake product snapshot survives the run (deleted at end of sitting, D279)"

  # LEG 6 — bake refuses on a registry 404 BEFORE any create.
  leg="$td/l6"
  make_fakes "$leg"
  FAKE_NPM_MODE=404 drive "$leg" "" "$PLANTED_KEY" "" bake
  expect "bake (pin 404) -> loud refusal, nothing created" 1 "bake-npm-pin"
  if grep -q '^vercel sandbox create' "$leg/seq"; then
    red "bake-404 leg still ran 'sandbox create' — the registry check must gate ALL spend"
  else
    say "bake-404: zero sandbox creates (registry check gates all spend)"
  fi

  # LEG 7 — explicit teardown mode: remove + snapshot sweep + clean asserts.
  leg="$td/l7"
  make_fakes "$leg"
  : >"$leg/cap/state.created"
  : >"$leg/cap/state.stopped"
  drive "$leg" "" "$PLANTED_KEY" "" teardown "$FAKE_ID"
  expect "explicit teardown -> remove + sweep + TEARDOWN CLEAN" 0 "TEARDOWN CLEAN"
  [ -f "$leg/cap/state.removed" ] && say "teardown mode removed $FAKE_ID" ||
    red "teardown mode never removed $FAKE_ID"
  [ -f "$leg/cap/state.snapdeleted" ] && say "teardown mode deleted the stop-snapshot" ||
    red "teardown mode never deleted the stop-snapshot"

  # LEG 8 — live refusal of the mutation knob (fail closed outside self-test).
  leg="$td/l8"
  make_fakes "$leg"
  local out8 rc8
  out8="$(env "PATH=$leg/bin:$PATH" "CLOUD_SANDBOX_VERCEL_BIN=$leg/bin/vercel" \
    "ANTHROPIC_API_KEY=$PLANTED_KEY" "W35_MUTATE=drop-resume" "TMPDIR=$leg/tmp" \
    "$bash_bin" "$0" multiturn 2>&1)"
  rc8=$?
  if [ "$rc8" -eq 1 ] && printf '%s' "$out8" | grep -qF "mutation-live"; then
    say "live mode REFUSES the mutation knob (fail closed, exit 1, named [mutation-live])"
  else
    red "live mode did not refuse W35_MUTATE (exit $rc8) — a mutated live turn could fabricate a green"
  fi

  echo
  if [ "$fails" -eq 0 ]; then
    echo "SELF-TEST: ALL PASS (9 legs: refusal, single+egress-lock, allow-all warn, multiturn lifecycle, mutation-red, bake order, bake-404, explicit teardown, mutation-knob refusal; planted-key custody on every dispatching leg)"
    return 0
  fi
  echo "SELF-TEST: $fails FAILURE(S)"
  return 1
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
  --self-test) self_test ;;
  bake) mode_bake ;;
  single) mode_single ;;
  multiturn) mode_multiturn ;;
  teardown)
    shift
    mode_teardown "$@"
    ;;
  -h | --help) usage ;;
  "")
    usage >&2
    exit 2
    ;;
  *)
    echo "$SCRIPT_NAME: unknown mode '$1' (try --help)" >&2
    exit 2
    ;;
esac
