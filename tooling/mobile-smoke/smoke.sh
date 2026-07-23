#!/usr/bin/env bash
# Barkpark Tasks Mobile — app-token exchange smoke (mobile charter D9).
#
# Mints an app token through the member-reachable two-endpoint exchange
# (Cloud session-authed proxy -> instance admin-gated mint) against LIVE
# guerrilla, then runs the FULL v1 journey AS the minted token:
#
#   fleet/cascade walk -> capabilities -> structure admin-floor oracle ->
#   /v1/tasks/prime?view=brief -> /v1/tasks/events?since=0 ->
#   SSE welcome frame on /v1/data/listen/production -> one paper read ->
#   chat floor: sessions list + send/approve/interrupt legs.
#
# The chat send/approve/interrupt legs probe a NONEXISTENT session id and
# assert the not-found oracle (404, never 401/403): that proves the minted
# token clears the chat permission + workspace floor WITHOUT driving a real
# agent session on a production workspace.
#
# DEPLOYMENT-AWARE (the exchange ships THROUGH this repo): until the Cloud +
# instance halves are merged (merge == auto-deploy), the live servers 404 the
# new routes. In that window the script falls back, LOUDLY, to the configured
# instance token so the journey legs still run against live guerrilla, and it
# reports the minted-token proof as PENDING. Set BP_SMOKE_REQUIRE_EXCHANGE=1
# (the post-merge re-run, and the criterion-3 evidence run) to make any
# fallback a hard failure.
#
# NOTE (mob-bl-app-token-revoke): there is NO HTTP revoke path yet, so every
# exchange-minted smoke token remains live on the instance. They are labeled
# "app:<cloud-account-email>" — clean up server-side when the revoke path lands.
#
# Requires: curl, jq, a logged-in bp config (~/.config/barkpark/config.json
# with cloud_url + cloud_token; `bp login` refreshes it).
set -euo pipefail

CONFIG="${BP_CONFIG:-$HOME/.config/barkpark/config.json}"
INSTANCE_URL="${BP_SMOKE_INSTANCE_URL:-https://guerrilla.barkpark.cloud}"
REQUIRE_EXCHANGE="${BP_SMOKE_REQUIRE_EXCHANGE:-0}"
DATASET="${BP_SMOKE_DATASET:-production}"

pass=0
fail=0
mode="unresolved"

say()  { printf '%s\n' "$*"; }
ok()   { pass=$((pass + 1)); say "  ok   $*"; }
bad()  { fail=$((fail + 1)); say "  FAIL $*"; }
die()  { say "FATAL: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need curl
need jq

[ -f "$CONFIG" ] || die "no bp config at $CONFIG — run 'bp login' first"
CLOUD_URL=$(jq -r '.cloud_url // empty' "$CONFIG")
CLOUD_TOKEN=$(jq -r '.cloud_token // empty' "$CONFIG")
[ -n "$CLOUD_URL" ] && [ -n "$CLOUD_TOKEN" ] ||
  die "no cloud session in $CONFIG (cloud_url/cloud_token) — run 'bp login'"

say "== mobile app-token exchange smoke =="
say "   cloud:    $CLOUD_URL"
say "   instance: $INSTANCE_URL"
say ""

# ── 1. Fleet walk (cascade rung 1: the server list, as the cloud session) ──
say "-- fleet walk (cloud session) --"
fleet=$(curl -sf -H "Authorization: Bearer $CLOUD_TOKEN" "$CLOUD_URL/v1/barkparks") ||
  die "cloud fleet list failed — is the cloud session stale? (bp login)"

BP_ID=$(jq -r --arg url "$INSTANCE_URL" \
  '.barkparks[] | select(.url == $url) | .id' <<<"$fleet")
[ -n "$BP_ID" ] || die "no barkpark with url $INSTANCE_URL in the cloud fleet"
ok "fleet lists $INSTANCE_URL (id $BP_ID)"

# ── 2. Mint through the exchange ──────────────────────────────────────────
say ""
say "-- mint: POST /v1/barkparks/:id/app-token (member-reachable proxy) --"
mint_status=$(curl -s -o /tmp/mobile-smoke-mint.$$ -w '%{http_code}' \
  -X POST -H "Authorization: Bearer $CLOUD_TOKEN" \
  "$CLOUD_URL/v1/barkparks/$BP_ID/app-token")
mint_body=$(cat /tmp/mobile-smoke-mint.$$ && rm -f /tmp/mobile-smoke-mint.$$)

TOKEN=""
case "$mint_status" in
  200)
    TOKEN=$(jq -r '.token // empty' <<<"$mint_body")
    [ -n "$TOKEN" ] || die "cloud 200 without a token: $mint_body"
    mode="exchange"
    ok "exchange minted an app token (permissions $(jq -c '.permissions' <<<"$mint_body"), workspace_id $(jq -r '.workspace_id' <<<"$mint_body"))"
    say "       label app:<cloud email> — NO HTTP revoke exists yet (mob-bl-app-token-revoke)"
    ;;
  404)
    # The control plane predates the exchange route (pre-merge window).
    mode="pre-deploy-cloud"
    ;;
  409)
    if [ "$(jq -r '.error // empty' <<<"$mint_body")" = "app_token_unsupported" ]; then
      # Cloud half live, instance predates the mint route (charter D8 leg).
      mode="pre-deploy-instance"
    else
      die "cloud mint 409: $mint_body"
    fi
    ;;
  *)
    die "cloud mint returned $mint_status: $mint_body"
    ;;
esac

if [ -z "$TOKEN" ]; then
  say "  PENDING exchange not deployed yet ($mode; cloud mint -> $mint_status)"
  if [ "$REQUIRE_EXCHANGE" = "1" ]; then
    die "BP_SMOKE_REQUIRE_EXCHANGE=1 and the exchange is not live — rerun after merge/deploy"
  fi
  TOKEN=$(jq -r --arg url "$INSTANCE_URL" \
    '(.known_servers[]? | select(.server == $url) | .token) // .token // empty' "$CONFIG" |
    head -n1)
  [ -n "$TOKEN" ] || die "no fallback instance token in $CONFIG"
  say "  PENDING journey runs on the CONFIGURED instance token instead —" \
    "minted-token proof deferred to the post-merge rerun (BP_SMOKE_REQUIRE_EXCHANGE=1)"
fi

auth=(-H "Authorization: Bearer $TOKEN")

# ── 3. The journey AS the (minted) token ──────────────────────────────────
say ""
say "-- journey as the ${mode} token --"

# capabilities: the manifest-driven cascade root every client boots from.
if curl -sf "${auth[@]}" "$INSTANCE_URL/v1/capabilities" | jq -e '.commands | length > 0' >/dev/null; then
  ok "GET /v1/capabilities -> manifest with commands"
else
  bad "GET /v1/capabilities"
fi

# structure: /v1/structure is ADMIN-gated (router :require_admin) and the
# mobile app never calls it — the cascade rides the Cloud fleet walk +
# /v1/capabilities. As the member-shaped minted token this MUST bounce:
# the admin floor holding is the assertion (in fallback mode the configured
# token may be admin, so a 200 is accepted there and labeled as such).
structure_status=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" \
  "$INSTANCE_URL/v1/structure/$DATASET")
case "$structure_status" in
  401 | 403)
    ok "GET /v1/structure/$DATASET -> $structure_status (admin floor holds against the member token)"
    ;;
  200)
    if [ "$mode" = "exchange" ]; then
      bad "GET /v1/structure/$DATASET -> 200 — the minted token cleared an ADMIN surface"
    else
      ok "GET /v1/structure/$DATASET -> 200 (fallback token is admin-tier; member oracle deferred)"
    fi
    ;;
  *)
    bad "GET /v1/structure/$DATASET -> $structure_status"
    ;;
esac

# tasks prime (brief view) — the mobile Tasks tab's first paint.
prime_status=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" \
  "$INSTANCE_URL/v1/tasks/prime?view=brief")
if [ "$prime_status" = "200" ]; then
  ok "GET /v1/tasks/prime?view=brief -> 200"
else
  bad "GET /v1/tasks/prime?view=brief -> $prime_status (expected 200)"
fi

# tasks events feed.
if curl -sf "${auth[@]}" "$INSTANCE_URL/v1/tasks/events?since=0" | jq -e 'has("events")' >/dev/null; then
  ok "GET /v1/tasks/events?since=0 -> events feed"
else
  bad "GET /v1/tasks/events?since=0"
fi

# SSE: the welcome frame on the live listen stream.
sse_head=$(curl -sN --max-time 8 "${auth[@]}" -H "Accept: text/event-stream" \
  "$INSTANCE_URL/v1/data/listen/$DATASET" 2>/dev/null | head -c 200 || true)
if grep -q "welcome" <<<"$sse_head"; then
  ok "GET /v1/data/listen/$DATASET -> SSE welcome frame"
else
  bad "GET /v1/data/listen/$DATASET -> no welcome frame in first 8s: ${sse_head:-<empty>}"
fi

# one paper read — the Papers tab floor (limit=1: one full document, not the
# whole multi-MB corpus).
papers=$(curl -sf "${auth[@]}" "$INSTANCE_URL/v1/data/query/$DATASET/paper?limit=1" || true)
paper_id=$(jq -r '.result.documents[0]._id // empty' <<<"$papers" 2>/dev/null || true)
if [ -n "$paper_id" ]; then
  ok "GET /v1/data/query/$DATASET/paper?limit=1 -> paper '$paper_id' readable"
else
  bad "paper read (no document in response)"
fi

# ── 4. Chat floor (third sibling client) ──────────────────────────────────
say ""
say "-- chat floor as the ${mode} token --"

sessions=$(curl -s -o /tmp/mobile-smoke-chat.$$ -w '%{http_code}' "${auth[@]}" \
  "$INSTANCE_URL/v1/chat/sessions")
chat_body=$(cat /tmp/mobile-smoke-chat.$$ && rm -f /tmp/mobile-smoke-chat.$$)
if [ "$sessions" = "200" ]; then
  ok "GET /v1/chat/sessions -> 200 ($(jq '.sessions | length' <<<"$chat_body") sessions on the workspace floor, D10)"
else
  bad "GET /v1/chat/sessions -> $sessions (expected 200 — chat floor denied?)"
fi

# send / approve / interrupt legs against a NONEXISTENT session id: the
# not-found oracle (404) proves the token clears the chat auth floor without
# touching a real production agent session. 401/403 here = floor broken.
ghost="00000000-0000-4000-8000-000000000000"
probe_chat_leg() {
  local name="$1" method="$2" path="$3" body="$4"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "${auth[@]}" \
    -H "Content-Type: application/json" ${body:+-d "$body"} \
    "$INSTANCE_URL$path")
  if [ "$status" = "404" ]; then
    ok "$name -> 404 not-found oracle (auth floor cleared, no real session driven)"
  else
    bad "$name -> $status (expected the 404 oracle; 401/403 = chat floor broken)"
  fi
}

probe_chat_leg "send      POST /v1/chat/sessions/:ghost/messages" POST \
  "/v1/chat/sessions/$ghost/messages" '{"content":"smoke"}'
probe_chat_leg "approve   POST /v1/chat/sessions/:ghost/approval" POST \
  "/v1/chat/sessions/$ghost/approval" '{"request_id":"r","decision":"allow"}'
probe_chat_leg "interrupt POST /v1/chat/sessions/:ghost/interrupt" POST \
  "/v1/chat/sessions/$ghost/interrupt" ''

# ── verdict ───────────────────────────────────────────────────────────────
say ""
say "== $pass ok, $fail failed (mode: $mode) =="
if [ "$mode" != "exchange" ]; then
  say "== PENDING: exchange not yet deployed — journey ran on the configured token."
  say "==          Rerun with BP_SMOKE_REQUIRE_EXCHANGE=1 after merge for the minted-token proof."
fi
[ "$fail" -eq 0 ]
