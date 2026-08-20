# Connectors calibration — engine-builder control stratum (mutate-check) — 2026-08-18

Wave: bp-connectors-wave-2026-08-18 · assignment calib-engine-control · origin/main = e21bf409
Verdict: ALL THREE control rows PRESENT AND WIRED. Mutate-check method discriminates (capability genuinely dispatched/emitted, not dead-defined).

## Row 1 — connectors-p4-slack-connect-oauth-route (#3246)
Claim: Slack OAuth callback route MOUNTED (dispatched), not just defined.
Nuance: the route lives in the JS connectors SERVICE router (webhook-server.ts), NOT the Phoenix router.
- Path const: `git show e21bf409:connectors/src/oauth/slack-oauth.ts | sed -n '67p'` → `SLACK_OAUTH_CALLBACK_PATH = "/connectors/oauth/slack/callback"`
- Matcher: `git show e21bf409:connectors/src/http/webhook-server.ts | sed -n '350,360p'` (isSlackOAuthCallbackRoute)
- DISPATCH (the mounting proof): `git show e21bf409:connectors/src/http/webhook-server.ts | sed -n '758,772p'` — `if (isSlackOAuthCallbackRoute(...)) { ... await handleSlackOAuthCallback(request, slackOAuth); ... }`

## Row 2 — connectors-linear-token-refresh (#3400)
Claim: dual-shape credential_ref (bare|bundle) refresh path present.
- Dual-shape handling: `git show e21bf409:connectors/src/oauth/linear-token-refresh.ts | sed -n '178,207p'` — bare-string/non-bundle → parseLinearBundle null → return null (serve as-is); bundle → exchange.
- WIRED: `git grep -n "createLinearTokenRefresher\|refreshCredential" origin/main -- 'connectors/src/**' | grep -v linear-token-refresh.ts` → linear.ts:124 creates it, :145 assigns as refreshCredential hook, connect.ts:396 invokes it.

## Row 3 — connectors-w29-elixir-egress-emission (#4184)
Claim: CloudPolicy derives per-connector MCP egress hosts.
- Derivation: `git show e21bf409:api/lib/barkpark/connectors/cloud_policy.ex | sed -n '245,283p'` — cloud_egress_hosts/2 flat_maps installed http descriptors → sanitized host.
- WIRED onto argv: `git grep -n "cloud_egress_hosts\|--egress-host" origin/main -- 'api/lib/**'` → claude_chat.ex:323-324 pipes derived hosts into repeated `--egress-host <host>` pairs.
