#!/bin/bash
# fleet-run-verdict-test.sh — fixture gate for fleet-run.sh's PDF-D100 honest-verdict ladder.
#
# No real agent turn, no server, no network: sources fleet-run.sh (its mode dispatch is
# source-guarded) and feeds SAVED claude-2.1.220 receipt shapes through order_verdict,
# run_turn, record_spend and — with a mocked `bp` — full do_order transcripts. The receipt
# fixtures reproduce the LIVE-MEASURED trap: `subtype` is "success" on every failure shape,
# the key set is identical between success and failure, and a 401 reports total_cost_usd:0.
#
#   bash tooling/fleet/fleet-run-verdict-test.sh     # exit 0 = green
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-run.sh
source "$HERE/fleet-run.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-verdict-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

N_PASS=0; N_FAIL=0
ok(){  N_PASS=$((N_PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad(){ N_FAIL=$((N_FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
hr(){ printf '\n── %s\n' "$*"; }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

V_VERDICT=""; V_TIER=""; V_EVIDENCE=""
run_verdict(){ # log exit claim_ts agent ctext brief → V_* globals
  local out; out=$(order_verdict "$1" "$2" "$3" "$4" "$5" "$6")
  V_VERDICT=$(sed -n 's/^verdict=//p' <<<"$out")
  V_TIER=$(sed -n 's/^tier=//p' <<<"$out")
  V_EVIDENCE=$(sed -n 's/^evidence=//p' <<<"$out")
}
expect(){ # label want_verdict [substring-that-must-appear-in-evidence]
  local label="$1" want="$2" sub="${3:-}"
  if [ "$V_VERDICT" != "$want" ]; then
    bad "$label: verdict=$V_VERDICT (wanted $want) [$V_TIER] $V_EVIDENCE"; return
  fi
  if [ -n "$sub" ] && ! has "$V_EVIDENCE" "$sub"; then
    bad "$label: evidence lacks '$sub' — got: $V_EVIDENCE"; return
  fi
  ok "$label"
}

# ── fixtures: the four live-proven claude receipt shapes, IDENTICAL key sets ─────────────────
cat >"$TMP/receipt-success.json" <<'JSON'
{"type":"result","subtype":"success","is_error":false,"duration_ms":6188,"duration_api_ms":5920,"num_turns":3,"result":"Done — wrote the requested file.","session_id":"fixture","total_cost_usd":0.0442,"usage":{},"terminal_reason":"completed","api_error_status":null}
JSON
cat >"$TMP/receipt-401-key.json" <<'JSON'
{"type":"result","subtype":"success","is_error":true,"duration_ms":901,"duration_api_ms":880,"num_turns":1,"result":"API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}","session_id":"fixture","total_cost_usd":0,"usage":{},"terminal_reason":"api_error","api_error_status":401}
JSON
cat >"$TMP/receipt-not-logged-in.json" <<'JSON'
{"type":"result","subtype":"success","is_error":true,"duration_ms":412,"duration_api_ms":0,"num_turns":1,"result":"Invalid API key · Please run /login","session_id":"fixture","total_cost_usd":0,"usage":{},"terminal_reason":"api_error","api_error_status":null}
JSON
cat >"$TMP/receipt-odd-subtype.json" <<'JSON'
{"type":"result","subtype":"error_during_execution","is_error":false,"duration_ms":6188,"duration_api_ms":5920,"num_turns":3,"result":"Done anyway.","session_id":"fixture","total_cost_usd":0.01,"usage":{},"terminal_reason":"completed","api_error_status":null}
JSON
: >"$TMP/receipt-empty.log"
NOW=$(date +%s)
PAST=$((NOW - 100))       # a claim in the past  → files written now are FRESH
FUTURE=$((NOW + 100))     # a claim in the future → files written now are STALE

hr "AC0 — the verdict never reads subtype; is_error is the truth"
run_verdict "$TMP/receipt-success.json" 0 "$PAST" claude "" ""
expect "success receipt, exit 0 → PASS (receipt tier)" PASS "attests the turn ran, not the outcome"
has "$V_EVIDENCE" "is_error=false" && ok "receipt values are quoted in the evidence" \
  || bad "PASS evidence does not quote the receipt: $V_EVIDENCE"
run_verdict "$TMP/receipt-401-key.json" 0 "$PAST" claude "" ""
expect "401 with subtype:\"success\" + is_error:true → MISS" MISS "is_error=True"
run_verdict "$TMP/receipt-not-logged-in.json" 0 "$PAST" claude "" ""
expect "not-logged-in (api_error_status null, is_error true) → MISS" MISS "api_error_status=None"
run_verdict "$TMP/receipt-odd-subtype.json" 0 "$PAST" claude "" ""
expect "garbage subtype but is_error:false → PASS (subtype is never consulted)" PASS
run_verdict "$TMP/receipt-empty.log" 0 "$PAST" claude "" ""
expect "zero-byte log, exit 0 → MISS (no receipt, nothing to attest)" MISS "no parseable receipt"

hr "AC1 — the agent's exit status reaches the verdict; the turn is time-bounded"
run_verdict "$TMP/receipt-success.json" 3 "$PAST" claude "" ""
expect "success-shaped receipt but exit 3 → MISS (exit code is read first)" MISS "agent exited 3"
run_verdict "$TMP/receipt-empty.log" 124 "$PAST" claude "" ""
expect "exit 124 → MISS (timeout, TRAP B named)" MISS "TRAP B"
# live: run_turn returns the agent's REAL exit status (the old subshell discarded it)
FLEET_AGENT=custom FLEET_AGENT_EXEC='exit 7'
run_turn "$TMP" "unused" "$TMP/turn-exit.log" 30; RC=$?
[ "$RC" -eq 7 ] && ok "run_turn returns the agent's real exit status (7)" \
  || bad "run_turn returned $RC, wanted the agent's own 7"
# live: a hung turn is killed at the bound and reports 124
FLEET_AGENT_EXEC='sleep 60'
T0=$(date +%s); run_turn "$TMP" "unused" "$TMP/turn-hang.log" 2; RC=$?; EL=$(( $(date +%s) - T0 ))
{ [ "$RC" -eq 124 ] && [ "$EL" -le 20 ]; } && ok "run_turn kills a hung turn at the bound (124 after ${EL}s)" \
  || bad "run_turn on a hung turn: rc=$RC after ${EL}s (wanted 124, fast)"
run_turn "$TMP/does-not-exist" "unused" "$TMP/turn-cd.log" 30; RC=$?
[ "$RC" -eq 97 ] && ok "an unusable workdir is its own failure (97), not a silent green" \
  || bad "run_turn with a bad workdir returned $RC, wanted 97"
FLEET_AGENT=claude; unset FLEET_AGENT_EXEC

hr "AC2 — PATH-READ: exists + size>0 + mtime AFTER the claim (the mtime control is load-bearing)"
ART="$TMP/artifact.txt"; printf 'hello fleet\n' >"$ART"
CT="The file $ART exists and carries the summary."
run_verdict "$TMP/receipt-success.json" 0 "$PAST" claude "$CT" ""
expect "fresh artifact (mtime after claim) → PASS at path-read tier" PASS
[ "$V_TIER" = "path-read" ] && ok "tier is path-read, not receipt" || bad "tier=$V_TIER, wanted path-read"
run_verdict "$TMP/receipt-success.json" 0 "$FUTURE" claude "$CT" ""
expect "PRE-EXISTING artifact (mtime before claim) → MISS, vacuous green refused" MISS "STALE"
has "$V_EVIDENCE" "PDS-D20" && ok "the stale MISS names the vacuous-green trap (PDS-D20)" \
  || bad "stale evidence does not name PDS-D20: $V_EVIDENCE"
run_verdict "$TMP/receipt-success.json" 0 "$PAST" claude "The file $TMP/never-made.txt exists." ""
expect "artifact ABSENT → MISS" MISS "ABSENT"
: >"$TMP/empty.txt"
run_verdict "$TMP/receipt-success.json" 0 "$PAST" claude "The file $TMP/empty.txt exists." ""
expect "artifact EMPTY (0 bytes) → MISS" MISS "EMPTY"
# criterion paths outrank brief paths: a stale input named in the brief must not poison a
# fresh deliverable named in the criterion
STALEIN="$TMP/stale-input.txt"; printf 'old\n' >"$STALEIN"
run_verdict "$TMP/receipt-success.json" 0 "$PAST" claude "The file $ART exists." "Read $STALEIN and write $ART."
expect "criterion's path wins over the brief's extra paths" PASS
run_verdict "$TMP/receipt-401-key.json" 0 "$PAST" claude "$CT" ""
expect "fresh artifact CANNOT rescue a failed receipt (is_error wins)" MISS "is_error=True"

hr "AC5 — the spend row carries the verdict (TRAP A: a 401 reports total_cost_usd:0)"
export FLEET_HOME="$TMP/fleet-home"; WORKER="verdict-test"; KLASS=standard; FLEET_AGENT=claude
run_verdict "$TMP/receipt-401-key.json" 0 "$PAST" claude "" ""
record_spend "order-401" "$TMP/receipt-401-key.json" "$V_VERDICT"
ROW=$(tail -1 "$TMP/fleet-home/$WORKER/spend.jsonl")
has "$ROW" '"verdict": "MISS"' && has "$ROW" '"cost_usd": 0.0' \
  && ok "401 row: cost 0.0 but verdict MISS — no longer a \$0 success" \
  || bad "401 spend row lacks the failure verdict: $ROW"
run_verdict "$TMP/receipt-success.json" 0 "$PAST" claude "" ""
record_spend "order-ok" "$TMP/receipt-success.json" "$V_VERDICT"
ROW=$(tail -1 "$TMP/fleet-home/$WORKER/spend.jsonl")
has "$ROW" '"verdict": "PASS"' && ok "success row carries verdict PASS" \
  || bad "success spend row lacks verdict PASS: $ROW"

# ── mocked-bp transcripts: miss→release never closes; close gated on a LANDED stamp ─────────
BP_LOG="$TMP/bp-calls.log"; MOCK_STATE="$TMP/mock-state"; MOCK_ART="$TMP/mock-artifact.txt"
MOCK_CRITERIA="one"; STAMP_NOOP=""
mock_task_json(){
  python3 - "$MOCK_STATE" "$MOCK_ART" "$MOCK_CRITERIA" <<'PY'
import sys, json, os
state, art, crit = sys.argv[1:4]
met = os.path.exists(os.path.join(state, "stamped"))
life = "done" if os.path.exists(os.path.join(state, "closed")) else "open"
ac = [] if crit == "none" else [{"criterion": "the artifact %s exists non-empty" % art, "met": met}]
print(json.dumps({"doc": {"lifecycle_status": life, "claim": {"worker": "", "epoch": 3},
      "content": {"acceptance_criteria": ac, "brief": {"blocks": [{"content": [
      {"value": "Write hello into %s. FENCE: fleet/mock-order" % art}]}]}}}}))
PY
}
bp(){ # transcript-logging mock — the ledger the runner *thinks* it is talking to
  printf 'bp %s\n' "$*" >>"$BP_LOG"
  case "${1:-}:${2:-}" in
    task:get)     mock_task_json ;;
    task:claim)   printf '{"doc":{"claim":{"epoch":3,"worker":"%s"}}}\n' "$WORKER" ;;
    task:stamp)   case " $* " in *" --met "*) [ -z "$STAMP_NOOP" ] && touch "$MOCK_STATE/stamped" ;; esac
                  printf '{"ok":true}\n' ;;
    task:close)   touch "$MOCK_STATE/closed"; printf '{"ok":true}\n' ;;
    task:release) touch "$MOCK_STATE/released"; printf '{"ok":true}\n' ;;
    *)            printf '{}\n' ;;
  esac
}
reset_mock(){ rm -rf "$MOCK_STATE" "/tmp/fleet-run/$1-$WORKER"; mkdir -p "$MOCK_STATE"; : >"$BP_LOG"; rm -f "$MOCK_ART"; }

hr "AC3 — a MISS stamps --miss --note, then RELEASES; bp task close never appears"
reset_mock mock-miss; MOCK_CRITERIA="one"
FLEET_AGENT=custom FLEET_AGENT_EXEC='echo attempting; exit 3'
do_order mock-miss >/dev/null 2>&1
grep -q ' --miss ' "$BP_LOG" && ok "transcript: bp task stamp --miss --note" || bad "no --miss stamp in transcript"
grep -q 'task release' "$BP_LOG" && ok "transcript: bp task release" || bad "no release in transcript"
grep -q 'task close' "$BP_LOG" && bad "transcript CONTAINS bp task close on the miss path" \
  || ok "transcript: NO bp task close on the miss path"
ROW=$(tail -1 "$TMP/fleet-home/$WORKER/spend.jsonl")
has "$ROW" '"verdict": "MISS"' && ok "the miss transcript's spend row carries verdict MISS" \
  || bad "miss transcript spend row: $ROW"

hr "AC4 — the close is GATED on a stamp that actually LANDED (re-GET, PDF-D33)"
reset_mock mock-pass; MOCK_CRITERIA="one"; STAMP_NOOP=""
FLEET_AGENT_EXEC="printf 'hello fleet\n' > '$MOCK_ART'; echo wrote-artifact"
do_order mock-pass >/dev/null 2>&1
grep -q -- '--met --evidence' "$BP_LOG" && grep -q 'task close' "$BP_LOG" \
  && ok "landed stamp → close (the happy path still closes)" \
  || bad "happy path did not stamp+close: $(grep 'task' "$BP_LOG" | head -4)"
grep -- '--met --evidence' "$BP_LOG" | grep -q 'mock-artifact.txt' \
  && ok "the --met evidence quotes the artifact read, not a canned literal" \
  || bad "the --met evidence does not mention the artifact path"
reset_mock mock-noop; MOCK_CRITERIA="one"; STAMP_NOOP=1     # pds-bl-stamp-silent-noop shape
do_order mock-noop >/dev/null 2>&1
grep -q 'task close' "$BP_LOG" && bad "a silently-no-op stamp was followed by a close" \
  || ok "stamp returned ok but criterion never flipped → close REFUSED"
grep -q 'task release' "$BP_LOG" && ok "the refused close releases instead" || bad "no release after refused close"
STAMP_NOOP=""
reset_mock mock-noc; MOCK_CRITERIA="none"                   # TRAP C: criterion-less order
do_order mock-noc >/dev/null 2>&1
grep -q 'task close' "$BP_LOG" && bad "criterion-less order was closed (TRAP C regression)" \
  || ok "criterion-less order (empty \$CTEXT) → never closed"
grep -q -- '--met --evidence' "$BP_LOG" && bad "criterion-less order attempted a doomed --met stamp" \
  || ok "criterion-less order skips the doomed --met (would 409), releases instead"

hr "AC4 — static: stamp/close are no longer silenced"
if grep -n 'bp task stamp\|bp task close' "$HERE/fleet-run.sh" | grep -q '/dev/null'; then
  bad "a bp task stamp/close line still redirects to /dev/null:"; grep -n 'bp task stamp\|bp task close' "$HERE/fleet-run.sh" | grep '/dev/null'
else
  ok "no bp task stamp/close line redirects to /dev/null (output is captured)"
fi

printf '\n%d passed, %d failed\n' "$N_PASS" "$N_FAIL"
[ "$N_FAIL" -eq 0 ] || exit 1
exit 0
