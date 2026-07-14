<!-- doc-tier: human | canonical-for: slack-app-gate | budget: 2600tok -->
# Add to Slack — the Slack app human gate (Connectors P4b)

Everything up to the moment a real Slack app exists is built and proven offline
(the OAuth callback is mounted, state-authenticated, joins a loopback-staged chat
token, and refuses a team another workspace owns). What Barkpark **cannot** do for
you is create the Slack app and paste its live secrets — that is a human step at
[api.slack.com/apps](https://api.slack.com/apps). This runbook names each gate to
the inch. **Do not fabricate a live install; leave the live criterion OPEN until a
human completes these steps.**

## The gates, in order

1. **Create the Slack app** at `https://api.slack.com/apps` → *Create New App* (from
   scratch, or from the manifest you keep beside this file). It gives you three
   secrets:
   - **Client ID** — public-ish, goes in the Add-to-Slack URL.
   - **Client Secret** — used ONCE, server-side, in the `oauth.v2.access` exchange.
   - **Signing Secret** — verifies every inbound event's HMAC (app-wide, not
     per-tenant).

2. **OAuth & Permissions → Redirect URLs.** Add EXACTLY:
   `https://<your-public-host>/connectors/oauth/slack/callback`
   (on guerrilla: `https://guerrilla.barkpark.cloud/connectors/oauth/slack/callback`).
   This MUST byte-match both the bridge's `redirectUri` and Studio's
   `slack_redirect_uri` — a mismatch is `redirect_uri did not match` at exchange time.

3. **Bot Token Scopes.** Add the scopes the code already lists in ONE place
   (`connectors/src/oauth/slack-oauth.ts#SLACK_BOT_SCOPES`, mirrored in
   `api/lib/barkpark/connectors/catalog.ex`): `app_mentions:read`,
   `channels:history`, `channels:read`, `chat:write`, `groups:history`,
   `groups:read`, `im:history`, `im:read`, `mpim:history`, `mpim:read`,
   `reactions:read`, `reactions:write`, `users:read`.

4. **Event Subscriptions → Request URL.** Set:
   `https://<your-public-host>/connectors/webhooks/slack`
   Slack immediately POSTs a `url_verification` challenge with **no team_id** — the
   bridge answers it via `handleUnkeyed` (the ONE tenant-less hook), so *Verify* goes
   green. Subscribe to the bot events you want (`app_mention`, `message.im`, …).
   **Bring the bridge unit up BEFORE saving this URL** (D34) — until then the path
   lands on Caddy's 503 and Slack disables a webhook after repeated non-2xx.
   **Socket Mode stays OFF** — it is structurally disqualified for Cloud (D40).

## Wiring the secrets in (both processes, same box)

The bridge and the BEAM each need their half:

- **Bridge** (`/etc/barkpark/connectors.env`, mode 0600): `SLACK_CLIENT_ID`,
  `SLACK_CLIENT_SECRET`, `SLACK_SIGNING_SECRET`, and `CONNECTORS_PUBLIC_BASE_URL`
  (e.g. `https://guerrilla.barkpark.cloud`). Absent ⇒ the callback route is a
  loud, opaque 404 and the channel simply isn't offered.
- **Studio (BEAM)** — `config :barkpark, Barkpark.Connectors, slack_client_id: …,
  slack_redirect_uri: …` (from runtime env). Absent ⇒ the Slack card shows the
  honest "Add to Slack is not configured on this instance" note, never a broken
  button. The `state` HMAC secret is the SHARED `CONNECTORS_CONNECT_SECRET` — the
  same key the bridge verifies connect tickets with; there is no separate Slack
  state secret.

## The live criterion stays OPEN

Once the app exists and both processes carry the secrets: click **Add to Slack**
in Studio → approve the bot in a real Slack workspace → the callback lands, the
install is written with both secrets, and the card flips to Connected. Only a human
with a Slack workspace can perform that round trip. Until it is done, the live-Slack
criterion is **NOT PASSED** — record it honestly, never a fabricated install.

## Known limitation (filed backlog)

The chat token for a Slack install is minted BEFORE the OAuth callback learns the
`install_key` (team/enterprise id), so it is labelled `connector:slack:oauth`, not
`connector:slack:<install_key>`. Disconnect revokes that OAuth label as well as the
install-key label, so no token is orphaned — but relabelling by `install_key` after
the callback (or tracking a nonce→install_key map) is filed as follow-up.
