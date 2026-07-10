#!/usr/bin/env bash
# cmux-smoke.sh — the committed live E2E proof of the CMUX × Barkpark bridge
# (cmux-bridge epic, wave 2, task cb-live-smoke). It replaces the unrecorded
# Jul 6-7 hand smokes with one repeatable run that drives the FULL pane
# lifecycle against the REAL guerrilla server — install → claim → renew → honest
# leave-claimed → close → the cardinal dead-server fail-safe row — and proves the
# bridge never touches the operator's real config.
#
# WHY a bash harness (not a Go test): the loop only exists across real processes
# (a fresh `bp cmux hook` per event, keyed on env, no persisted epoch between
# SessionStart and Stop — cmux_hook.go), against a real task document with a real
# lease/epoch/CAS. A unit test with an injected client proves the branches; only
# this proves the wiring.
#
# MANUAL RUN ONLY — NEVER wire into CI (same stance as scripts/claude-chat-e2e.sh,
# scripts/media-smoke.sh, scripts/idp-interop.sh). It writes to the live guerrilla
# task ledger. It is self-cleaning (creates AND closes its own throwaway tasks,
# labeled `smoke`), but a crashed run can leave two `smoke` tasks briefly claimed
# until their lease expires.
#
#   Invocation (from anywhere; it cd's to the repo root itself):
#     ./scripts/cmux-smoke.sh
#   Requires: bp on PATH (or BP=/path/to/bp), python3, shasum, and a working
#   ~/.config/barkpark/config.json whose ACTIVE server is guerrilla. Cost: ~4
#   throwaway task writes + a handful of claims on guerrilla; seconds to run.
#
# GATE (cb-live-smoke): `bash -n scripts/cmux-smoke.sh && bash scripts/cmux-smoke.sh`
# must end in a PASS summary with 0 failures; paste the output (incl. both shasum
# proofs + the dead-server assertions) as task evidence.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- resolve bp or REFUSE (idp-interop.sh stance: no silent skip) ----------------
BP_BIN="${BP:-bp}"
if ! command -v "$BP_BIN" >/dev/null 2>&1; then
  echo "REFUSE: bp binary not found (looked for '${BP_BIN}'; set BP=/path/to/bp)." >&2
  echo "        This harness proves the LIVE bridge — it must not run without bp." >&2
  exit 1
fi
BP="$(command -v "$BP_BIN")"
for tool in python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "REFUSE: '$tool' not found." >&2; exit 1; }
done

# --- pass/fail counters (media-smoke.sh style) -----------------------------------
pass=0
fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }
die() { echo "FATAL: $1" >&2; exit 1; }

# small JSON readers over stdin-piped `bp ... -o json` payloads
# sfield "<json>" a.b.c → the dotted value ('' when any hop is absent/null)
sfield() {
  printf '%s' "$1" | python3 -c '
import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)
' "$2"
}
# has_key "<json>" key → yes|no (top-level key presence, distinct from null value)
has_key() {
  printf '%s' "$1" | python3 -c '
import json,sys
print("yes" if sys.argv[1] in json.load(sys.stdin) else "no")
' "$2"
}

# =================================================================================
# 1. Capture the REAL guerrilla creds + untouched-config shasums BEFORE any
#    reassignment or any bp write. Everything after this runs in a scratch HOME.
# =================================================================================
REAL_HOME="$HOME"
REAL_CONFIG_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}"
REAL_CONFIG="$REAL_CONFIG_DIR/barkpark/config.json"
REAL_SETTINGS="$REAL_HOME/.claude/settings.json"

[ -f "$REAL_CONFIG" ] || die "no real config at $REAL_CONFIG — guerrilla creds unknown."

# Active-server creds straight off the config's top level (the `bp use` active set).
read_cfg() { python3 -c "import json;print(json.load(open('$REAL_CONFIG')).get('$1',''))"; }
G_SERVER="$(read_cfg server)"
G_TOKEN="$(read_cfg token)"
G_WORKSPACE="$(read_cfg workspace)"
G_PROJECT="$(read_cfg project)"
G_DATASET="$(read_cfg dataset)"
[ -n "$G_SERVER" ] && [ -n "$G_TOKEN" ] || die "config missing server/token."
case "$G_SERVER" in
  *guerrilla*) : ;;
  *) echo "WARNING: active server '$G_SERVER' is not guerrilla — proceeding anyway." >&2 ;;
esac

# The isolation proof: both real targets, byte-for-byte, before and after.
sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "ABSENT"; }
BEFORE_SETTINGS="$(sha_of "$REAL_SETTINGS")"
BEFORE_CONFIG="$(sha_of "$REAL_CONFIG")"

echo "=== cmux bridge live smoke — guerrilla: $G_SERVER ==="
echo "captured real-config shasum + real-settings shasum (isolation baseline)"

# =================================================================================
# 2. Scratch HOME + XDG (BOTH: install --merge targets os.UserHomeDir()/.claude;
#    hook state roots at os.UserConfigDir which IGNORES XDG on macOS). Guerrilla
#    creds via explicit env (env beats config, cli.go envContext). Tier-2 worker:
#    BARKPARK_WORKER_ID stays UNSET so `cmux-<surface>` is what we prove.
# =================================================================================
SCRATCH="$(mktemp -d)"
export HOME="$SCRATCH"
export XDG_CONFIG_HOME="$SCRATCH/.config"
export BARKPARK_API_URL="$G_SERVER"
export BARKPARK_API_TOKEN="$G_TOKEN"
export BARKPARK_WORKSPACE="$G_WORKSPACE"
export BARKPARK_PROJECT="$G_PROJECT"
export BARKPARK_DATASET="$G_DATASET"
export CMUX_SURFACE_ID="smoke-$$-$RANDOM"
unset BARKPARK_WORKER_ID || true      # tier-2 (cmux-<surface>) is the proof target
WORKER="cmux-$CMUX_SURFACE_ID"

T1=""
T2=""
# trap: close throwaway tasks (best-effort, same worker = renew→close) + nuke scratch.
cleanup() {
  local rc=$?
  set +e
  for t in "$T1" "$T2"; do
    [ -n "$t" ] || continue
    local cl ep
    cl=$(BARKPARK_TASK="$t" "$BP" task claim "$t" "$WORKER" 2>/dev/null)
    ep=$(printf '%s' "$cl" | grep -oE 'epoch=[0-9]+' | head -1 | cut -d= -f2)
    [ -n "$ep" ] && "$BP" task close "$t" "$WORKER" "$ep" done "smoke cleanup" >/dev/null 2>&1
  done
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  return $rc
}
trap cleanup EXIT

# state-dir roots (both platforms) — nuked in scenario C to beat the 60s throttle.
CMUX_STATE_XDG="$XDG_CONFIG_HOME/barkpark/cmux"
CMUX_STATE_MAC="$HOME/Library/Application Support/barkpark/cmux"

# hook runner: captures rc + EXACT stdout byte count (command-subst would strip a
# trailing newline, masking a byte-empty violation — so we go through a file).
OUTFILE="$SCRATCH/hook.out"
run_hook() {  # run_hook <stdin-json> <event> [VAR=VAL ...]
  local stdin="$1" event="$2"; shift 2
  printf '%s' "$stdin" | env "$@" "$BP" cmux hook "$event" >"$OUTFILE" 2>/dev/null \
    && HOOK_RC=0 || HOOK_RC=$?
  HOOK_BYTES=$(wc -c <"$OUTFILE" | tr -d ' ')
}
status_of() {  # status_of <task> [VAR=VAL ...] → STATUS
  local task="$1"; shift
  STATUS=$(env BARKPARK_TASK="$task" "$@" "$BP" cmux status -o json 2>/dev/null)
}
new_smoke_task() {  # → prints the created task id
  "$BP" task create "cmux smoke $1 $(date +%s)" --publish --yes \
    --set 'labels:=["smoke"]' \
    --set 'acceptance_criteria:=[{"criterion":"smoke","met":false}]' \
    -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'
}

# =================================================================================
# PREFLIGHT (mandatory): a known task must resolve on guerrilla. Under an isolated
# HOME a missing scope var silently falls to the baked localhost:4000/dev-token
# floor — every scenario would then fake a dead server. This is the tripwire.
# =================================================================================
echo ""
echo "--- preflight: guerrilla reachable under isolated HOME ---"
if "$BP" task get cmux-bridge-goal >/dev/null 2>&1; then
  ok "preflight: bp task get cmux-bridge-goal succeeds (env creds reach guerrilla)"
else
  die "preflight FAILED — bp task get cmux-bridge-goal did not resolve. Isolated HOME likely fell to the localhost floor; refusing to run (every scenario would fake dead-server)."
fi

# =================================================================================
# A. install --merge writes the scratch settings with our hook command.
# =================================================================================
echo ""
echo "--- A. install --merge into scratch HOME ---"
"$BP" cmux install --merge --yes >/dev/null 2>&1 || true
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q 'bp cmux hook' "$SETTINGS"; then
  ok "install --merge wrote $SETTINGS containing 'bp cmux hook'"
else
  bad "install --merge did NOT wire 'bp cmux hook' into $SETTINGS"
fi

# =================================================================================
# B. Healthy claim: SessionStart claims T1 as cmux-<surface>, exit 0, empty stdout.
# =================================================================================
echo ""
echo "--- B. SessionStart claims a throwaway task ---"
T1="$(new_smoke_task T1)"
[ -n "$T1" ] || die "could not create throwaway task T1."
echo "  T1=$T1"
run_hook '{"session_id":"smoke"}' SessionStart BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "SessionStart rc==0" || bad "SessionStart rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "SessionStart stdout byte-empty" || bad "SessionStart wrote $HOOK_BYTES stdout bytes (must be 0)"

status_of "$T1"
CW="$(sfield "$STATUS" claim_worker)"
HC="$(sfield "$STATUS" has_claim)"
E1="$(sfield "$STATUS" claim_epoch)"
[ "$CW" = "$WORKER" ] && ok "claim_worker == $WORKER (tier-2, BARKPARK_WORKER_ID unset)" || bad "claim_worker='$CW' expected '$WORKER'"
[ "$HC" = "True" ] && ok "has_claim true" || bad "has_claim='$HC' (expected True)"
case "$E1" in ''|*[!0-9]*) bad "claim_epoch not an integer: '$E1'";; *) ok "claim_epoch E1=$E1";; esac

# =================================================================================
# C. Renew bumps epoch, same worker. Nuke the state dir first to beat the 60s
#    throttle (renewDue fails OPEN; never compute sha1 stamp filenames).
# =================================================================================
echo ""
echo "--- C. PreToolUse renews (epoch bumps, worker unchanged) ---"
rm -rf "$CMUX_STATE_XDG" "$CMUX_STATE_MAC"
run_hook '{"tool_name":"Bash"}' PreToolUse BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "PreToolUse rc==0" || bad "PreToolUse rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "PreToolUse stdout byte-empty" || bad "PreToolUse wrote $HOOK_BYTES stdout bytes (must be 0)"

status_of "$T1"
E2="$(sfield "$STATUS" claim_epoch)"
CW2="$(sfield "$STATUS" claim_worker)"
case "$E2" in ''|*[!0-9]*) bad "renewed claim_epoch not an integer: '$E2'";; *)
  if [ "$E2" -gt "$E1" ]; then ok "claim_epoch bumped $E1 → $E2"; else bad "claim_epoch $E2 not > $E1"; fi ;;
esac
[ "$CW2" = "$WORKER" ] && ok "claim_worker unchanged ($WORKER)" || bad "claim_worker changed to '$CW2'"

# =================================================================================
# D. Honest non-close: Stop with an UNMET criterion leaves the task claimed —
#    lifecycle != done, still claimed, and NO breadcrumb (leave-claimed is honest,
#    not an error).
# =================================================================================
echo ""
echo "--- D. Stop with unmet criterion leaves claimed (no breadcrumb) ---"
run_hook '{}' Stop BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "Stop rc==0" || bad "Stop rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "Stop stdout byte-empty" || bad "Stop wrote $HOOK_BYTES stdout bytes (must be 0)"
status_of "$T1"
LC="$(sfield "$STATUS" lifecycle)"
HC="$(sfield "$STATUS" has_claim)"
[ "$LC" != "done" ] && ok "lifecycle != done (leave-claimed): '$LC'" || bad "lifecycle == done — closed on unmet criteria!"
[ "$HC" = "True" ] && ok "has_claim still true" || bad "has_claim='$HC' (expected still True)"
[ "$(has_key "$STATUS" last_error)" = "no" ] && ok "no last_error breadcrumb (honest leave is not an error)" || bad "last_error present after an honest leave-claimed"

# =================================================================================
# E. Close with evidence: flip the criterion met:=true, Stop again → observed_rev
#    CAS close → lifecycle == done. The patch alone lands in a `drafts.<id>`
#    overlay that guerrilla's `?perspective=drafts` doc read (the exact endpoint
#    the hook uses, apiclient.GetPerspectiveResult) does NOT surface for the base
#    id — so we PUBLISH the flip, which is what makes met:true visible to the
#    hook's acceptance gate. (The charter assumed the patch alone suffices; the
#    live server needs the publish. Verified against guerrilla.)
# =================================================================================
echo ""
echo "--- E. met-flip (patch + publish) then Stop closes the task ---"
"$BP" doc patch task "$T1" --yes \
  --set 'acceptance_criteria:=[{"criterion":"smoke","met":true}]' >/dev/null 2>&1 \
  || bad "doc patch (met-flip) failed"
"$BP" doc publish task "$T1" --yes >/dev/null 2>&1 \
  || bad "doc publish (met-flip) failed"
run_hook '{}' Stop BARKPARK_TASK="$T1"
[ "$HOOK_RC" = "0" ] && ok "Stop rc==0" || bad "Stop rc=$HOOK_RC (must be 0)"
[ "$HOOK_BYTES" = "0" ] && ok "closing Stop stdout byte-empty (branch-heaviest hook path)" || bad "closing Stop wrote $HOOK_BYTES stdout bytes (must be 0)"
status_of "$T1"
LC="$(sfield "$STATUS" lifecycle)"
[ "$LC" = "done" ] && ok "lifecycle == done (observed_rev CAS close)" || bad "lifecycle='$LC' (expected done after met-flip)"

# =================================================================================
# F. CARDINAL fail-safe row: a dead server must NOT harm the agent. SessionStart
#    against a connection-refused port → exit 0 + byte-empty stdout; then, with
#    guerrilla restored, the honest breadcrumb surfaces via `bp cmux status`.
# =================================================================================
echo ""
echo "--- F. dead server: exit 0, empty stdout, honest breadcrumb (NOT fail-invisible) ---"
T2="$(new_smoke_task T2)"
[ -n "$T2" ] || die "could not create throwaway task T2."
echo "  T2=$T2"
run_hook '{}' SessionStart BARKPARK_TASK="$T2" BARKPARK_API_URL="http://127.0.0.1:1"
[ "$HOOK_RC" = "0" ] && ok "dead-server SessionStart rc==0 (agent unharmed)" || bad "dead-server rc=$HOOK_RC (fail-safe VIOLATED)"
[ "$HOOK_BYTES" = "0" ] && ok "dead-server stdout byte-empty" || bad "dead-server wrote $HOOK_BYTES stdout bytes (fail-safe VIOLATED)"

status_of "$T2"
LE_EVENT="$(sfield "$STATUS" last_error.event)"
LE_ERR="$(sfield "$STATUS" last_error.error)"
[ "$LE_EVENT" = "SessionStart" ] && ok "last_error.event == SessionStart (breadcrumb stamped)" || bad "last_error.event='$LE_EVENT' (expected SessionStart)"
case "$LE_ERR" in
  *claim*) ok "last_error.error names the claim failure: \"$LE_ERR\"" ;;
  *) bad "last_error.error does not mention claim failure: '$LE_ERR'" ;;
esac

# =================================================================================
# G. Cleanup + isolation proof: close T1/T2 on guerrilla; the REAL config +
#    settings must be byte-for-byte identical to the baseline.
# =================================================================================
echo ""
echo "--- G. close throwaway tasks + isolation shasum proof ---"
for t in "$T1" "$T2"; do
  cl=$(BARKPARK_TASK="$t" "$BP" task claim "$t" "$WORKER" 2>/dev/null || true)
  ep=$(printf '%s' "$cl" | grep -oE 'epoch=[0-9]+' | head -1 | cut -d= -f2 || true)
  [ -n "$ep" ] && "$BP" task close "$t" "$WORKER" "$ep" done "smoke closed by harness" >/dev/null 2>&1 || true
done
# VERIFY the closes landed (T1 closed in scenario E; T2 by the loop above) — an
# ||-guarded loop must not report green while leaving a claimed smoke task behind.
status_of "$T2"
[ "$(sfield "$STATUS" lifecycle)" = "done" ] && ok "throwaway tasks closed on guerrilla (T2 lifecycle==done; T1 closed in E)" || bad "T2 lifecycle='$(sfield "$STATUS" lifecycle)' — throwaway task left unclosed on guerrilla"

AFTER_SETTINGS="$(sha_of "$REAL_SETTINGS")"
AFTER_CONFIG="$(sha_of "$REAL_CONFIG")"
echo "  real settings: before=$BEFORE_SETTINGS after=$AFTER_SETTINGS"
echo "  real config  : before=$BEFORE_CONFIG after=$AFTER_CONFIG"
[ "$AFTER_SETTINGS" = "$BEFORE_SETTINGS" ] && ok "real ~/.claude/settings.json UNTOUCHED (shasum byte-equal)" || bad "real settings shasum CHANGED — isolation breached!"
[ "$AFTER_CONFIG" = "$BEFORE_CONFIG" ] && ok "real ~/.config/barkpark/config.json UNTOUCHED (shasum byte-equal)" || bad "real config shasum CHANGED — isolation breached!"

# =================================================================================
echo ""
echo "=== SMOKE: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
