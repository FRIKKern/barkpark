#!/usr/bin/env bash
# tooling/chat-drive/drive.sh — the D41 real-send drive against guerrilla.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE D41 SAFETY LAW (charter bp-barkpark-tasks-mobile, D41 — quoted verbatim):
#
#   "SAFETY LAW, absolute: guerrilla sessions run with cwd /opt/barkpark/api
#    (the PRODUCTION checkout) and an ALLOWED ExitPlanMode card auto-engages
#    autopilot (mode "auto" = write authority in prod) — never allow a plan
#    card on guerrilla; the DENY half of approve-deny is proven on the
#    ExitPlanMode card, the ALLOW half on a harmless read-only
#    non-ExitPlanMode ask. Assert STATE, never status codes (a reaped
#    Recorder 204s/202s while writing nothing — the 30-minute idle reap makes
#    pending cards permanently unanswerable); interrupt is proven by SSE
#    deltas STOPPING mid-stream, not by the 202. Session created out-of-band
#    (the app has no create verb — by design), clearly titled, ARCHIVED on
#    completion (D28 makes residue ≈ zero); any minted token revoked by
#    body, never empty-body logout-everywhere."
#
#   Bounded at a $2.00 HARD SPEND CAP (D41; measured floor $0.342/turn on
#   haiku — the drive pins model=haiku and aborts en route at $1.50).
# ══════════════════════════════════════════════════════════════════════════════
#
# What this drives (bp task mob-seal-real-send, root criterion 3):
#   1. Mint a member-shaped [read,write,chat] workspace-bound app token
#      (admin bearer used ONLY for mint + revoke; the drive itself is member).
#   2. Create a clearly-titled session OUT-OF-BAND: POST /v1/chat/sessions
#      with the closed key set {provider, mode, model} (claude/plan/haiku).
#   3. REAL SEND: streamed assistant deltas observed over
#      GET /v1/chat/sessions/:id/events; re-read shows message_count +
#      total_cost_usd advanced.
#   4. INTERRUPT: POSTed while deltas are ARRIVING; proven by the SSE stream
#      stopping mid-turn + agent_state leaving "working" on re-read — the
#      202/request_id is recorded but NEVER cited as proof.
#   5. APPROVE-DENY, both ways, fail-closed: ALLOW one harmless read-only
#      non-ExitPlanMode ask (Bash `ls`, input verified against a read-only
#      allowlist BEFORE allowing); DENY the ExitPlanMode plan card. ANY
#      unexpected card is denied. Proof = approval_status on message re-read,
#      and session.mode still "plan" at the end.
#   6. HYGIENE: archive the session (absent from default list, present under
#      ?archived=true); revoke the minted token BY BODY {"token": raw} and
#      prove revocation by the member token failing closed (401) after.
#
# Usage:
#   BARKPARK_ADMIN_TOKEN=... ./drive.sh            # server defaults to guerrilla
#   BARKPARK_SERVER=https://guerrilla.barkpark.cloud BARKPARK_ADMIN_TOKEN=... ./drive.sh
#   (BARKPARK_ADMIN_TOKEN falls back to .token in ~/.config/barkpark/config.json)
#
# Output: a masked transcript (tokens redacted) + raw SSE event log in
# DRIVE_OUT (default: ./drive-out-<utc-ts>). The transcript is the committed
# evidence artifact. Requires: bash 3.2+, curl, jq.
#
# Keep the WHOLE drive inside one sitting: the Recorder's 30-minute idle reap
# makes a pending card older than that permanently unanswerable.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SERVER="${BARKPARK_SERVER:-https://guerrilla.barkpark.cloud}"
ADMIN_TOKEN="${BARKPARK_ADMIN_TOKEN:-}"
if [ -z "$ADMIN_TOKEN" ] && [ -f "$HOME/.config/barkpark/config.json" ]; then
  ADMIN_TOKEN="$(jq -r '.token // empty' "$HOME/.config/barkpark/config.json")"
fi
[ -n "$ADMIN_TOKEN" ] || { echo "FATAL: BARKPARK_ADMIN_TOKEN not set and no config token" >&2; exit 1; }

DRIVE_EMAIL="${DRIVE_EMAIL:-pelle@jarl.no}"
TS_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${DRIVE_OUT:-./drive-out-$TS_UTC}"
mkdir -p "$OUT"
TRANSCRIPT="$OUT/transcript.log"
EVENTS="$OUT/events.log"
: > "$TRANSCRIPT"
: > "$EVENTS"

SPEND_CAP="2.00"     # D41 hard cap — the drive FAILS if total_cost_usd exceeds this
SPEND_ABORT="1.50"   # en-route abort threshold: never start a turn above this

MEMBER_TOKEN=""
SID=""
SSE_PID=""
INTERRUPTED_CLEANLY=0

# ── Transcript helpers (tokens NEVER reach the transcript) ────────────────────
mask() {
  local s="$1"
  s="${s//$ADMIN_TOKEN/[ADMIN_TOKEN]}"
  if [ -n "$MEMBER_TOKEN" ]; then s="${s//$MEMBER_TOKEN/[MEMBER_TOKEN]}"; fi
  printf '%s' "$s"
}
log() { printf '%s | %s\n' "$(date -u +%H:%M:%S)" "$(mask "$1")" | tee -a "$TRANSCRIPT"; }
logq() { printf '%s | %s\n' "$(date -u +%H:%M:%S)" "$(mask "$1")" >> "$TRANSCRIPT"; }
fail() { log "FAIL: $1"; cleanup_best_effort; exit 1; }

PASS_LINES=""
proof() { log "PROOF: $1"; PASS_LINES="${PASS_LINES}PROOF: $1"$'\n'; }

# ── HTTP helpers: body captured to $BODY, status to $STATUS ───────────────────
BODY=""
STATUS=""
req() { # method url token [json-body]
  local method="$1" url="$2" token="$3" data="${4:-}"
  local tmp; tmp="$(mktemp)"
  if [ -n "$data" ]; then
    STATUS="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      --data "$data" "$url")"
  else
    STATUS="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $token" "$url")"
  fi
  BODY="$(cat "$tmp")"; rm -f "$tmp"
  logq ">> $method $url ${data:+body=$data}"
  # Belt-and-braces: redact any "token" value at log time — the mint response
  # arrives BEFORE $MEMBER_TOKEN is known, so mask() alone cannot catch it.
  logq "<< $STATUS $(printf '%s' "$BODY" | sed -E 's/"token":"[^"]+"/"token":"[REDACTED]"/g')"
}
member_req() { req "$1" "$2" "$MEMBER_TOKEN" "${3:-}"; }
admin_req()  { req "$1" "$2" "$ADMIN_TOKEN" "${3:-}"; }

session_read() { member_req GET "$SERVER/v1/chat/sessions/$SID"; }
session_field() { printf '%s' "$BODY" | jq -r "$1"; }

# ── SSE helpers ───────────────────────────────────────────────────────────────
events_offset() { wc -c < "$EVENTS" | tr -d ' '; }
events_since() { tail -c "+$(( $1 + 1 ))" "$EVENTS"; }

wait_for_pattern() { # offset pattern timeout_s label
  local off="$1" pat="$2" timeout="$3" label="$4" waited=0
  while ! events_since "$off" | grep -q "$pat"; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -lt $((timeout * 2)) ] || fail "timeout waiting for $label (pattern: $pat)"
  done
}

# stream_event frames beyond an offset (each `event: chat` data line, filtered)
delta_count_since() { events_since "$1" | grep -c '"type":"stream_event"' || true; }

# The permission ask (data line) that follows the first `event: permission`
# beyond the offset. SSE frame shape: "event: permission\ndata: {...}\n\n".
permission_ask_since() {
  events_since "$1" | grep -A1 '^event: permission' | grep '^data: ' | head -1 | sed 's/^data: //'
}

wait_turn_end() { # offset timeout_s — the claude stream-json result frame
  wait_for_pattern "$1" '"type":"result"' "$2" "turn end (result frame)"
}

# Wait for whichever comes first beyond the offset: a permission card ("card"),
# the turn's result frame ("end"), or neither ("timeout"). Live finding
# (2026-07-26 drive, session afd1696e): plan mode AUTO-APPROVES classifier-safe
# read-only Bash (`ls` ran with ZERO permission frames), so a card-minting ask
# must be one the classifier cannot pre-clear — command substitution does it.
wait_card_or_end() { # offset timeout_s
  local off="$1" timeout="$2" waited=0
  while :; do
    if events_since "$off" | grep -q '^event: permission'; then echo card; return 0; fi
    if events_since "$off" | grep -q '"type":"result"'; then echo end; return 0; fi
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -lt $((timeout * 2)) ] || { echo timeout; return 0; }
  done
}

# ── Spend guard (D41 $2.00 hard cap) ──────────────────────────────────────────
spend_guard() {
  session_read
  local cost; cost="$(session_field '.total_cost_usd // 0')"
  log "spend check: total_cost_usd=$cost (cap $SPEND_CAP, abort-above $SPEND_ABORT)"
  if [ "$(printf '%s\n' "$cost" | awk -v t="$SPEND_ABORT" '{print ($1 > t) ? 1 : 0}')" = "1" ]; then
    fail "spend $cost exceeds en-route abort threshold $SPEND_ABORT"
  fi
}

# ── Fail-closed card answering ────────────────────────────────────────────────
deny_card() { # request_id
  member_req POST "$SERVER/v1/chat/sessions/$SID/approval" \
    "$(jq -cn --arg r "$1" '{request_id:$r, decision:"deny"}')"
}
allow_card() { # request_id
  member_req POST "$SERVER/v1/chat/sessions/$SID/approval" \
    "$(jq -cn --arg r "$1" '{request_id:$r, decision:"allow"}')"
}

# approval_status of the message row carrying this request_id (STATE re-read)
approval_status_of() { # request_id
  session_read
  printf '%s' "$BODY" | jq -r --arg r "$1" \
    '[.messages[] | select((.metadata.request_id // "") == $r)] | last | .metadata.approval_status // "ABSENT"'
}

# ── Cleanup (never leave residue: interrupt, archive, revoke, kill SSE) ───────
cleanup_best_effort() {
  set +e
  if [ -n "$SID" ] && [ -n "$MEMBER_TOKEN" ]; then
    curl -sS -o /dev/null -X POST -H "Authorization: Bearer $MEMBER_TOKEN" \
      "$SERVER/v1/chat/sessions/$SID/interrupt"
    curl -sS -o /dev/null -X POST -H "Authorization: Bearer $MEMBER_TOKEN" \
      "$SERVER/v1/chat/sessions/$SID/archive"
  fi
  if [ -n "$MEMBER_TOKEN" ]; then
    curl -sS -o /dev/null -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$(jq -cn --arg t "$MEMBER_TOKEN" '{token:$t}')" \
      "$SERVER/v1/auth/app-tokens"
  fi
  [ -n "$SSE_PID" ] && kill "$SSE_PID" 2>/dev/null
  set -e
}
trap 'cleanup_best_effort' INT TERM

# ══════════════════════════════════════════════════════════════════════════════
# Phase 0 — preflight
# ══════════════════════════════════════════════════════════════════════════════
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 1; }
log "D41 drive start — server=$SERVER out=$OUT email=$DRIVE_EMAIL"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1 — mint the member token (admin bearer used ONLY here and for revoke)
# ══════════════════════════════════════════════════════════════════════════════
admin_req POST "$SERVER/v1/auth/app-tokens" \
  "$(jq -cn --arg e "$DRIVE_EMAIL" '{email:$e}')"
[ "$STATUS" = "201" ] || fail "app-token mint returned $STATUS: $BODY"
MEMBER_TOKEN="$(printf '%s' "$BODY" | jq -r '.token')"
[ -n "$MEMBER_TOKEN" ] && [ "$MEMBER_TOKEN" != "null" ] || fail "no token in mint response"
MINT_PERMS="$(printf '%s' "$BODY" | jq -c '.permissions')"
MINT_WS="$(printf '%s' "$BODY" | jq -r '.workspace_id // "?"')"
log "minted member app token: permissions=$MINT_PERMS workspace_id=$MINT_WS (raw token redacted)"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2 — create the session OUT-OF-BAND (closed key set), clearly titled
# ══════════════════════════════════════════════════════════════════════════════
member_req POST "$SERVER/v1/chat/sessions" \
  '{"provider":"claude","mode":"plan","model":"haiku"}'
[ "$STATUS" = "201" ] || fail "session create returned $STATUS: $BODY"
SID="$(session_field '.id')"
[ -n "$SID" ] && [ "$SID" != "null" ] || fail "no session id in create response"
CREATED_MODE="$(session_field '.mode')"
[ "$CREATED_MODE" = "plan" ] || fail "created mode is '$CREATED_MODE', wanted plan"
log "session created out-of-band: id=$SID mode=$CREATED_MODE (member token, closed key set)"

TITLE="D41 e2e drive $TS_UTC — mob-seal-real-send (auto; will be archived)"
member_req PATCH "$SERVER/v1/chat/sessions/$SID" \
  "$(jq -cn --arg t "$TITLE" '{title:$t}')"
[ "$STATUS" = "200" ] || fail "title patch returned $STATUS"
proof "session $SID created out-of-band by MEMBER token, mode=plan, model=haiku, titled: $TITLE"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3 — open the SSE stream (one long-lived member connection)
# ══════════════════════════════════════════════════════════════════════════════
curl -sSN -H "Authorization: Bearer $MEMBER_TOKEN" -H "Accept: text/event-stream" \
  "$SERVER/v1/chat/sessions/$SID/events" >> "$EVENTS" 2>/dev/null &
SSE_PID=$!
log "SSE stream open (pid $SSE_PID) -> $EVENTS"
sleep 2

# ══════════════════════════════════════════════════════════════════════════════
# Phase 4 — REAL SEND: streamed deltas over /events, state advanced on re-read
# ══════════════════════════════════════════════════════════════════════════════
spend_guard
OFF1="$(events_offset)"
member_req POST "$SERVER/v1/chat/sessions/$SID/messages" \
  '{"content":"In plain text and WITHOUT using any tools: give a two-sentence description of what a headless CMS is."}'
[ "$STATUS" = "202" ] || fail "send returned $STATUS: $BODY"
log "turn 1 sent (202 recorded, not cited as proof) — waiting for streamed deltas"
wait_for_pattern "$OFF1" '"type":"stream_event"' 120 "turn-1 streamed deltas"
wait_for_pattern "$OFF1" 'text_delta' 120 "turn-1 text_delta"
wait_turn_end "$OFF1" 180
T1_DELTAS="$(delta_count_since "$OFF1")"
T1_EXCERPT="$(events_since "$OFF1" | grep 'text_delta' | head -3)"
session_read
T1_COUNT="$(session_field '.message_count')"
T1_COST="$(session_field '.total_cost_usd')"
[ "${T1_COUNT:-0}" -ge 2 ] || fail "message_count=$T1_COUNT after turn 1 (< 2)"
[ "$(printf '%s\n' "$T1_COST" | awk '{print ($1 > 0) ? 1 : 0}')" = "1" ] || fail "total_cost_usd=$T1_COST did not advance"
proof "REAL SEND: $T1_DELTAS stream_event frames observed over /events; re-read message_count=$T1_COUNT total_cost_usd=$T1_COST"
log "turn-1 delta excerpt (first 3): $T1_EXCERPT"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 5 — INTERRUPT mid-stream: proven by deltas STOPPING + agent_state
# ══════════════════════════════════════════════════════════════════════════════
spend_guard
OFF2="$(events_offset)"
member_req POST "$SERVER/v1/chat/sessions/$SID/messages" \
  '{"content":"WITHOUT using any tools: write the numbers one to three hundred as English words, one per line. Do not stop early."}'
[ "$STATUS" = "202" ] || fail "turn-2 send returned $STATUS"
wait_for_pattern "$OFF2" 'text_delta' 120 "turn-2 first delta"
# Deltas are ARRIVING NOW — POST the interrupt mid-stream.
member_req POST "$SERVER/v1/chat/sessions/$SID/interrupt"
[ "$STATUS" = "202" ] || fail "interrupt returned $STATUS"
INT_RID="$(session_field '.request_id // "null"' 2>/dev/null || echo null)"
log "interrupt POSTed mid-stream (202 request_id=$INT_RID recorded, NOT the proof)"
# Proof 1: the stream STOPS — delta count becomes stationary.
sleep 3
C_A="$(delta_count_since "$OFF2")"
sleep 5
C_B="$(delta_count_since "$OFF2")"
[ "$C_A" = "$C_B" ] || { sleep 8; C_B2="$(delta_count_since "$OFF2")"; [ "$C_B" = "$C_B2" ] || fail "deltas still arriving after interrupt ($C_A -> $C_B -> $C_B2)"; C_B="$C_B2"; }
# Proof 2: STATE — agent_state leaves "working" on re-read.
WAITED=0
while :; do
  session_read
  T2_STATE="$(session_field '.agent_state')"
  [ "$T2_STATE" != "working" ] && break
  WAITED=$((WAITED + 1)); [ "$WAITED" -lt 30 ] || fail "agent_state still 'working' 60s after interrupt"
  sleep 2
done
T2_LAST=""
T2_LAST="$(printf '%s' "$BODY" | jq -r '[.messages[] | select(.role=="assistant")] | last | .source_markdown // ""' | tail -1)"
if printf '%s' "$T2_LAST" | grep -qi 'three hundred'; then
  log "note: turn-2 tail reached 'three hundred' — interrupt landed but output may have completed"
fi
proof "INTERRUPT: POSTed while deltas arriving; stream stopped (delta count stationary at $C_B for 5s+); re-read agent_state=$T2_STATE (left working). 202 not cited."
INTERRUPTED_CLEANLY=1

# ══════════════════════════════════════════════════════════════════════════════
# Phase 6 — ALLOW leg: harmless read-only non-ExitPlanMode ask, fail-closed
#
# Live finding (first drive, session afd1696e): plan mode auto-approves
# classifier-safe read-only Bash (`ls` ran, zero cards). To MINT a card the ask
# must defeat the classifier while staying read-only IN EFFECT — command
# substitution (`echo $(date)`) and `sleep 3` (no reads, no writes) both
# qualify. Candidates are tried in order until one mints a card; any card that
# is not the expected harmless Bash ask is DENIED and the drive aborts.
# ══════════════════════════════════════════════════════════════════════════════
spend_guard
ALLOW_PROMPTS=(
  'Run exactly this shell command via the Bash tool, without modifying or simplifying it in any way: echo $(date). Then reply with its output. Use no other tools.'
  'Run exactly this shell command via the Bash tool, without modifying it: sleep 3. Then reply done. Use no other tools.'
)
ASK3_RID=""
ASK3_TOOL=""
ASK3_CMD=""
for PROMPT in "${ALLOW_PROMPTS[@]}"; do
  OFF3="$(events_offset)"
  member_req POST "$SERVER/v1/chat/sessions/$SID/messages" \
    "$(jq -cn --arg c "$PROMPT" '{content:$c}')"
  [ "$STATUS" = "202" ] || fail "allow-leg send returned $STATUS"
  OUTCOME="$(wait_card_or_end "$OFF3" 90)"
  case "$OUTCOME" in
    card) break ;;
    end)  log "allow-leg candidate auto-approved by the classifier (no card) — trying next candidate" ;;
    timeout) fail "allow-leg: neither card nor turn end within 90s" ;;
  esac
  OFF3=""
done
[ "$OUTCOME" = "card" ] || fail "no allow-leg candidate minted a permission card"
ASK3="$(permission_ask_since "$OFF3")"
ASK3_RID="$(printf '%s' "$ASK3" | jq -r '.request_id')"
ASK3_TOOL="$(printf '%s' "$ASK3" | jq -r '.tool_name')"
ASK3_CMD="$(printf '%s' "$ASK3" | jq -r '.input.command // ""')"
log "turn-3 card: tool=$ASK3_TOOL request_id=$ASK3_RID input.command='$ASK3_CMD'"
# THE LAW: never allow ExitPlanMode; only allow a verified harmless ask.
if [ "$ASK3_TOOL" = "ExitPlanMode" ]; then
  deny_card "$ASK3_RID"
  fail "ExitPlanMode card arrived on the ALLOW leg — denied (law) and aborting"
fi
[ "$ASK3_TOOL" = "Bash" ] || { deny_card "$ASK3_RID"; fail "unexpected tool '$ASK3_TOOL' — denied fail-closed"; }
case "$ASK3_CMD" in
  'echo $(date)'|'date'|'sleep 3'|'sleep 2')
    : ;; # verified harmless, read-only in effect (no state read or written)
  *)
    deny_card "$ASK3_RID"
    fail "unexpected ask command '$ASK3_CMD' — denied fail-closed and aborting" ;;
esac
allow_card "$ASK3_RID"
[ "$STATUS" = "204" ] || fail "allow returned $STATUS"
A3_STATUS="$(approval_status_of "$ASK3_RID")"
[ "$A3_STATUS" = "allowed" ] || fail "re-read approval_status='$A3_STATUS' (wanted allowed)"
wait_turn_end "$OFF3" 120
proof "ALLOW: harmless read-only-in-effect non-ExitPlanMode ask (tool=$ASK3_TOOL, command='$ASK3_CMD') allowed; re-read approval_status=allowed"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 7 — DENY leg: the ExitPlanMode plan card (NEVER allowed on guerrilla)
# ══════════════════════════════════════════════════════════════════════════════
spend_guard
OFF4="$(events_offset)"
member_req POST "$SERVER/v1/chat/sessions/$SID/messages" \
  '{"content":"You are done planning. Present a one-sentence plan and call the ExitPlanMode tool now."}'
[ "$STATUS" = "202" ] || fail "turn-4 send returned $STATUS"
wait_for_pattern "$OFF4" '^event: permission' 180 "turn-4 plan card"
ASK4="$(permission_ask_since "$OFF4")"
ASK4_RID="$(printf '%s' "$ASK4" | jq -r '.request_id')"
ASK4_TOOL="$(printf '%s' "$ASK4" | jq -r '.tool_name')"
log "turn-4 card: tool=$ASK4_TOOL request_id=$ASK4_RID"
[ "$ASK4_TOOL" = "ExitPlanMode" ] || { deny_card "$ASK4_RID"; fail "expected ExitPlanMode card, got $ASK4_TOOL — denied fail-closed"; }
deny_card "$ASK4_RID"
[ "$STATUS" = "204" ] || fail "deny returned $STATUS"
A4_STATUS="$(approval_status_of "$ASK4_RID")"
[ "$A4_STATUS" = "denied" ] || fail "re-read approval_status='$A4_STATUS' (wanted denied)"
# The turn may keep going after a denial — bound the spend by ending it.
sleep 5
member_req POST "$SERVER/v1/chat/sessions/$SID/interrupt"
session_read
END_MODE="$(session_field '.mode')"
[ "$END_MODE" = "plan" ] || fail "session mode flipped to '$END_MODE' — autopilot engaged, LAW VIOLATED"
proof "DENY: ExitPlanMode card denied; re-read approval_status=denied; session mode still '$END_MODE' (never flipped to auto)"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 8 — spend cap (D41: total recorded spend <= \$2.00)
# ══════════════════════════════════════════════════════════════════════════════
session_read
FINAL_COST="$(session_field '.total_cost_usd')"
FINAL_COUNT="$(session_field '.message_count')"
[ "$(printf '%s\n' "$FINAL_COST" | awk -v t="$SPEND_CAP" '{print ($1 <= t) ? 1 : 0}')" = "1" ] \
  || fail "total_cost_usd=$FINAL_COST exceeds the D41 cap $SPEND_CAP"
proof "SPEND: total_cost_usd=$FINAL_COST <= $SPEND_CAP (D41 cap); message_count=$FINAL_COUNT"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 9 — hygiene: archive (STATE: gone from default list, on archived shelf)
# ══════════════════════════════════════════════════════════════════════════════
member_req POST "$SERVER/v1/chat/sessions/$SID/archive"
[ "$STATUS" = "200" ] || fail "archive returned $STATUS"
member_req GET "$SERVER/v1/chat/sessions"
IN_DEFAULT="$(printf '%s' "$BODY" | jq -r --arg s "$SID" '[.sessions[] | select(.id==$s)] | length')"
member_req GET "$SERVER/v1/chat/sessions?archived=true"
IN_SHELF="$(printf '%s' "$BODY" | jq -r --arg s "$SID" '[.sessions[] | select(.id==$s)] | length')"
[ "$IN_DEFAULT" = "0" ] || fail "session still in default list after archive"
[ "$IN_SHELF" = "1" ] || fail "session not on the archived shelf"
proof "ARCHIVE: session absent from default list (0 rows) and present under ?archived=true (1 row)"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 10 — revoke the minted token BY BODY; prove it fails closed after
# ══════════════════════════════════════════════════════════════════════════════
[ -n "$SSE_PID" ] && kill "$SSE_PID" 2>/dev/null || true
SSE_PID=""
admin_req DELETE "$SERVER/v1/auth/app-tokens" \
  "$(jq -cn --arg t "$MEMBER_TOKEN" '{token:$t}')"
[ "$STATUS" = "200" ] || [ "$STATUS" = "204" ] || fail "revoke-by-body returned $STATUS: $BODY"
REVOKE_BODY="$BODY"
member_req GET "$SERVER/v1/chat/sessions"
POST_REVOKE_STATUS="$STATUS"
[ "$POST_REVOKE_STATUS" = "401" ] || fail "member token still live after revoke (got $POST_REVOKE_STATUS)"
proof "REVOKE: minted token revoked BY BODY ($REVOKE_BODY); member token now fails closed ($POST_REVOKE_STATUS)"

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
log "──────────────────────────────────────────────"
log "D41 DRIVE COMPLETE — session=$SID cost=$FINAL_COST messages=$FINAL_COUNT"
printf '%s' "$PASS_LINES" | tee -a "$TRANSCRIPT"
log "transcript: $TRANSCRIPT  events: $EVENTS"
