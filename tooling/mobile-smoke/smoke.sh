#!/usr/bin/env bash
# Barkpark Tasks Mobile — app-token exchange smoke (mobile charter D9).
#
# Mints an app token through the member-reachable two-endpoint exchange
# (Cloud session-authed proxy -> instance admin-gated mint) against LIVE
# guerrilla, then runs the FULL v1 journey AS the minted token:
#
#   fleet/cascade walk -> capabilities (public-manifest reachability) ->
#   structure admin-floor oracle -> token-floor control (anonymous
#   /v1/tasks/prime -> 401) -> /v1/tasks/prime?view=brief as the token ->
#   /v1/tasks/events?since=0 -> SSE welcome frame on
#   /v1/data/listen/production -> one paper read ->
#   chat floor: sessions list + send/approve/interrupt legs.
#
# AUTH-FLOOR HONESTY: /v1/capabilities answers 200 with NO Authorization header
# at all, so an authed 200 there is a LIVENESS check, not a credential proof —
# it would pass with a revoked, garbage or absent token. That leg now carries an
# anonymous control probe and is labeled for what it proves (reachability). The
# credential assertion lives on /v1/tasks/prime, which is probed BOTH ways:
# anonymous (must fail closed, 401/403) and as the token (must be 200). Only the
# pair proves the token — that is the shape the teardown recheck already used.
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
# TEARDOWN: the run revokes the token it minted through the Cloud revoke half
# (DELETE /v1/barkparks/:id/app-token with body {"token": <raw>} — landed with
# the wave-2 revoke, so the old "no HTTP revoke path" note is obsolete). The
# body form kills exactly THIS run's token; an EMPTY body is logout-everywhere
# for the account, so the body is never omitted. Only an exchange-minted token
# is ever revoked — the configured fallback token is left untouched.
#
# MEMBER-SHAPED, not owner-shaped: the fleet walk uses ?scope=all (every Team
# membership, as the app does) and every cloud call carries X-Barkpark-Team so
# the control plane resolves the instance's OWN team instead of the caller's
# oldest membership — without it a real member whose primary team is not the
# instance's team dies at "no barkpark with url …", and the mint route 404s
# (it requires current_team to match the barkpark's team). The team id comes
# from BP_SMOKE_TEAM, else config cloud_team, else the fleet row's own team.
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

# Team scoping: env override wins, then the logged-in config's team. May stay
# empty here — the ?scope=all fleet row below carries the instance's own team,
# which is what the mint/revoke calls actually need.
TEAM="${BP_SMOKE_TEAM:-$(jq -r '.cloud_team // empty' "$CONFIG")}"

# Rebuilt whenever TEAM changes: the cloud-session headers every control-plane
# call sends. X-Barkpark-Team is omitted entirely when no team is known (the
# control plane then falls back to the caller's primary team).
cloud_hdrs=()
set_cloud_hdrs() {
  cloud_hdrs=(-H "Authorization: Bearer $CLOUD_TOKEN")
  if [ -n "$TEAM" ]; then
    cloud_hdrs+=(-H "X-Barkpark-Team: $TEAM")
  fi
}
set_cloud_hdrs

say "== mobile app-token exchange smoke =="
say "   cloud:    $CLOUD_URL"
say "   instance: $INSTANCE_URL"
say "   team:     ${TEAM:-<from the fleet row>}"
say ""

# ── 1. Fleet walk (cascade rung 1: the server list, as the cloud session) ──
# ?scope=all = every Team membership, exactly what the app's cascade does
# (apps/mobile/src/api.ts). Bare /v1/barkparks is scoped to ONE team (the
# caller's oldest membership when no X-Barkpark-Team is sent), which hides the
# instance from any member whose primary team is not the instance's team.
say "-- fleet walk (cloud session, scope=all) --"
fleet=$(curl -sf "${cloud_hdrs[@]}" "$CLOUD_URL/v1/barkparks?scope=all") ||
  die "cloud fleet list failed — is the cloud session stale? (bp login)"

BP_ID=$(jq -r --arg url "$INSTANCE_URL" \
  '.barkparks[] | select(.url == $url) | .id' <<<"$fleet")
[ -n "$BP_ID" ] || die "no barkpark with url $INSTANCE_URL in the cloud fleet"

# The instance's OWN team — the only value the team-scoped mint/revoke accept.
BP_TEAM=$(jq -r --arg url "$INSTANCE_URL" \
  '.barkparks[] | select(.url == $url) | .team.id // empty' <<<"$fleet")
if [ -n "$BP_TEAM" ] && [ "$BP_TEAM" != "$TEAM" ]; then
  say "       team scope -> ${BP_TEAM} (the instance's own team${TEAM:+, was $TEAM})"
  TEAM="$BP_TEAM"
  set_cloud_hdrs
fi
ok "fleet lists $INSTANCE_URL (id $BP_ID)"

# ── 2. Mint through the exchange ──────────────────────────────────────────
say ""
say "-- mint: POST /v1/barkparks/:id/app-token (member-reachable proxy) --"
mint_status=$(curl -s -o /tmp/mobile-smoke-mint.$$ -w '%{http_code}' \
  -X POST "${cloud_hdrs[@]}" \
  "$CLOUD_URL/v1/barkparks/$BP_ID/app-token")
mint_body=$(cat /tmp/mobile-smoke-mint.$$ && rm -f /tmp/mobile-smoke-mint.$$)

TOKEN=""
case "$mint_status" in
  200)
    TOKEN=$(jq -r '.token // empty' <<<"$mint_body")
    [ -n "$TOKEN" ] || die "cloud 200 without a token: $mint_body"
    mode="exchange"
    ok "exchange minted an app token (permissions $(jq -c '.permissions' <<<"$mint_body"), workspace_id $(jq -r '.workspace_id' <<<"$mint_body"))"
    say "       label app:<cloud email> — revoked by body at teardown (see below)"
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

# Teardown, armed the moment a token exists so even a mid-journey `die` cleans
# up: DELETE /v1/barkparks/:id/app-token with body {"token": <raw>} kills
# exactly this credential. The body is MANDATORY — an empty body means
# logout-everywhere for the whole account. Only ever aimed at an
# exchange-minted token; the configured fallback token must survive the run.
# Not a counted assertion (the journey's "N ok, 0 failed" verdict is the proof
# surface) — a failure here is a LOUD warning naming the leftover token.
revoked=0
revoke_minted_token() {
  [ "$mode" = "exchange" ] || return 0
  [ "$revoked" -eq 0 ] || return 0
  revoked=1

  local status body
  say ""
  say "-- teardown: revoke the minted token (body {token}, never empty) --"
  status=$(curl -s -o /tmp/mobile-smoke-revoke.$$ -w '%{http_code}' \
    -X DELETE "${cloud_hdrs[@]}" -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$TOKEN" '{token: $t}')" \
    "$CLOUD_URL/v1/barkparks/$BP_ID/app-token")
  body=$(cat /tmp/mobile-smoke-revoke.$$ && rm -f /tmp/mobile-smoke-revoke.$$)

  if [ "$status" = "200" ]; then
    say "  ok   DELETE app-token -> 200 $(jq -c '.' <<<"$body" 2>/dev/null || printf '%s' "$body")"
    # The revoke is only real if the credential is now dead: one re-use of the
    # revoked token must fail closed (Auth.verify_token filters revoked rows in
    # its WHERE clause). Probed on /v1/tasks/prime, which is token-GATED — not
    # /v1/capabilities, which answers 200 anonymously and would pass vacuously.
    local recheck
    recheck=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" \
      "$INSTANCE_URL/v1/tasks/prime?view=brief")
    case "$recheck" in
      401 | 403)
        say "  ok   revoked token re-use -> $recheck (fails closed; this run leaves no live token)"
        ;;
      *)
        say "  WARN revoked token re-use -> $recheck — the token still authenticates on $INSTANCE_URL"
        ;;
    esac
  else
    say "  WARN DELETE app-token -> $status: $body"
    say "  WARN the minted app:<cloud email> token is STILL LIVE on $INSTANCE_URL —" \
      "revoke it server-side"
  fi
}
trap revoke_minted_token EXIT

# ── 3. The journey AS the (minted) token ──────────────────────────────────
say ""
say "-- journey as the ${mode} token --"

# capabilities: the manifest-driven cascade root every client boots from — and a
# PUBLIC surface. GET /v1/capabilities answers 200 with no Authorization header
# at all (verified on guerrilla), so an authed 200 here proves the manifest is
# REACHABLE and well-formed, never that the credential is good: this leg passes
# with a revoked, garbage or absent token. The anonymous control probe pins that
# in the output instead of leaving it implied, and the leg is labeled for what it
# actually proves. The credential assertion is the anonymous-401 + authed-200
# pair on /v1/tasks/prime below.
cap_anon=$(curl -s -o /dev/null -w '%{http_code}' "$INSTANCE_URL/v1/capabilities")
cap_status=$(curl -s -o /tmp/mobile-smoke-cap.$$ -w '%{http_code}' "${auth[@]}" \
  "$INSTANCE_URL/v1/capabilities")
cap_body=$(cat /tmp/mobile-smoke-cap.$$ && rm -f /tmp/mobile-smoke-cap.$$)
if [ "$cap_status" = "200" ] &&
  jq -e '.commands | length > 0' <<<"$cap_body" >/dev/null 2>&1; then
  if [ "$cap_anon" = "200" ]; then
    ok "GET /v1/capabilities -> manifest with commands; anon control -> 200 too" \
      "(PUBLIC surface: this leg proves reachability, NOT the token)"
  else
    ok "GET /v1/capabilities -> manifest with commands; anon control -> $cap_anon" \
      "(token-gated on this deployment, so here the leg IS also a credential proof)"
  fi
else
  bad "GET /v1/capabilities -> $cap_status (no commands manifest)"
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

# token floor — the assertion /v1/capabilities cannot make. /v1/tasks/prime is
# token-GATED (verified: 401 anonymously on guerrilla), so probing it with NO
# Authorization header first is what turns the authed 200 below into a real
# credential proof: the route demonstrably rejects an anonymous caller AND this
# token clears it. Without the control, an authed 200 alone cannot tell "the
# token works" apart from "the route is public" — exactly the hole the old
# capabilities leg had. Deliberately unauthenticated: no "${auth[@]}" here.
prime_anon=$(curl -s -o /dev/null -w '%{http_code}' \
  "$INSTANCE_URL/v1/tasks/prime?view=brief")
floor="unproven"
case "$prime_anon" in
  401 | 403)
    floor="proven"
    ok "GET /v1/tasks/prime (no Authorization) -> $prime_anon" \
      "(token floor exists — so the authed 200 next is a real credential proof)"
    ;;
  *)
    bad "GET /v1/tasks/prime (no Authorization) -> $prime_anon (expected 401/403;" \
      "if this route answers anonymously, NOTHING in this journey proves the token)"
    ;;
esac

# tasks prime (brief view) — the mobile Tasks tab's first paint, AS the token:
# the authed half of the pair above. The label only claims a credential proof
# when the control probe actually established the floor.
prime_status=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" \
  "$INSTANCE_URL/v1/tasks/prime?view=brief")
if [ "$prime_status" = "200" ]; then
  if [ "$floor" = "proven" ]; then
    ok "GET /v1/tasks/prime?view=brief -> 200 (the ${mode} token clears the floor" \
      "the control probe just proved)"
  else
    ok "GET /v1/tasks/prime?view=brief -> 200 (route reachable; NOT a credential" \
      "proof — the anonymous control above did not fail closed)"
  fi
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

# ── 5. Teardown: revoke the token THIS run minted ─────────────────────────
revoke_minted_token

# ── verdict ───────────────────────────────────────────────────────────────
say ""
say "== $pass ok, $fail failed (mode: $mode) =="
if [ "$mode" != "exchange" ]; then
  say "== PENDING: exchange not yet deployed — journey ran on the configured token."
  say "==          Rerun with BP_SMOKE_REQUIRE_EXCHANGE=1 after merge for the minted-token proof."
fi
[ "$fail" -eq 0 ]
