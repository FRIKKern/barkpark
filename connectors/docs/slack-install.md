<!-- doc-tier: human | canonical-for: slack-connector-install | budget: 6000tok -->

# Installing the Slack connector

Slack is the `payload-team-id` channel: ONE Slack app, ONE HTTP endpoint, ONE
signing secret, MANY tenants. Which Barkpark workspace an inbound event belongs
to is read from the (signature-verified) event envelope, then looked up in
`chat_bridge.connector_installs`. Contrast Telegram, which is BYO-bot: there the
credential that received the message IS the tenant binding.

Both strategies run on the same core loop. Adding Slack changed
`core/dispatch.ts`, `tenant/resolve.ts`, `connector/registry.ts` and `turn/` by
exactly zero lines.

## Status: NOT LIVE — the Add-to-Slack round trip has NOT been passed

Everything below is code that exists and is tested. **No live Slack install has
been performed.** The round trip (real Slack app → real workspace → a real bot
reply) is a HUMAN GATE and is marked NOT PASSED. Nothing in this repo should be
read as claiming otherwise.

## THE HUMAN GATE

A human must create a Slack app at <https://api.slack.com/apps> and hand the
bridge four values. No agent can do this — it needs a Slack account, a workspace,
and a browser.

| Value | Where it comes from | Env var |
|---|---|---|
| Client ID | Basic Information → App Credentials | `SLACK_CLIENT_ID` |
| Client Secret | Basic Information → App Credentials | `SLACK_CLIENT_SECRET` |
| Signing Secret | Basic Information → App Credentials | `SLACK_SIGNING_SECRET` |
| Redirect URL | OAuth & Permissions → Redirect URLs | must byte-match `${PUBLIC_URL}/connectors/oauth/slack/callback` |

**This gate is BLOCKED on a public URL.** Slack pushes events over HTTP to a
publicly reachable host and will not talk to `localhost`. The bridge's public URL
is a separate slice (W4-5); until it exists there is nowhere to point
`Event Subscriptions → Request URL` or the OAuth redirect.

Also needed, and bridge-side rather than Slack-side:

| Value | Why | Env var |
|---|---|---|
| OAuth state secret | HMAC key that binds an install to a workspace. Without it, anyone who can reach the callback can mount their Slack team inside someone else's workspace. | (passed to `handleSlackOAuthCallback`) |

## App manifest

Paste this into **Create New App → From an app manifest**, replacing
`PUBLIC_URL`.

```yaml
display_information:
  name: Barkpark
  description: Talk to your Barkpark agent from Slack.
features:
  bot_user:
    display_name: barkpark
    always_online: false
oauth_config:
  redirect_urls:
    - https://PUBLIC_URL/connectors/oauth/slack/callback
  scopes:
    bot:
      - app_mentions:read
      - channels:history
      - channels:read
      - chat:write
      - groups:history
      - groups:read
      - im:history
      - im:read
      - mpim:history
      - mpim:read
      - reactions:read
      - reactions:write
      - users:read
settings:
  event_subscriptions:
    request_url: https://PUBLIC_URL/connectors/webhook/slack
    bot_events:
      - app_mention
      - message.im
      - message.channels
      - message.groups
      - message.mpim
  interactivity:
    is_enabled: false
  org_deploy_enabled: true
  # SOCKET MODE MUST STAY FALSE. See below — it is not merely "worse", it is a
  # silent cross-tenant leak.
  socket_mode_enabled: false
  token_rotation_enabled: false
```

The scope list is duplicated in code as `SLACK_BOT_SCOPES`
(`src/oauth/slack-oauth.ts`), which is what builds the Add-to-Slack URL — so the
manifest and the install URL cannot drift apart.

## SOCKET MODE IS DISQUALIFIED — and it fails silently

This is the single most important line in this document.

`@chat-adapter/slack` guards socket mode against multi-workspace **credentials**:

```js
if (mode === "socket" && (config?.clientId || config?.clientSecret)) {
  throw new ValidationError("slack", "Multi-workspace (clientId/clientSecret) is not supported in socket mode.");
}
```

The guard does **not** look at `installationProvider`. So this constructs happily:

```js
createSlackAdapter({ mode: "socket", appToken, botToken, installationProvider })  // NO THROW
```

…and then every tenant replies with the one static `botToken`, while
`getInstallation` is never called even once. The mechanism is that socket mode's
`routeSocketEvent` calls `processEventPayload` **directly**, skipping the
`resolveTokenForTeam` + `requestContext.run` wrap that the webhook path performs —
and `getToken()` reads `requestContext` first, a store that is always empty in
socket mode.

Green tests, one operator token, every tenant. `test/slack-connector.test.ts` pins
the no-throw as a regression tripwire so nobody "fixes" this by turning socket
mode on.

The same hole opens in **webhook** mode the moment a static `botToken` is present,
because the SDK only resolves a per-team token when there is no default one:

```js
if (!this.defaultBotTokenProvider && payload.type === "event_callback") { … resolveTokenForTeam … }
```

So `src/connectors/slack.ts` passes **no `botToken` at all**, and a protective test
reintroduces one to prove the per-tenant suite goes red when it does.

## Where the bot token lives

`chat_bridge.connector_installs.credential_ref`, and nowhere else.

The adapter reads it through `installationProvider.getInstallation`, which is
scoped to ONE install: an envelope naming any other installation resolves to
`null`, and the SDK then answers `200 ok` without ever entering
`processEventPayload`. A mis-routing bug therefore degrades to a **dropped event**,
never to a cross-tenant reply.

Two SDK affordances are deliberately **never** used:

- **`encryptionKey`** — never passed.
- **`setInstallation`** (and therefore `adapter.handleOAuthCallback`, which calls
  it internally) — never called. It writes the bot token into the SDK's *own*
  `state-pg` rows, sealed by `@chat-adapter/shared`'s no-AAD `encryptToken`. That
  is a second home for a credential we keep in exactly one place.

`src/oauth/slack-oauth.ts` therefore performs the `oauth.v2.access` exchange
itself. That also fixes a second SDK problem: `handleOAuthCallback` discards
`enterprise` and `is_enterprise_install`, so it cannot key an Enterprise Grid
org-wide install correctly.

## Enterprise Grid

`install_key = enterprise_id ?? team_id` — but the enterprise id is used **only**
when `is_enterprise_install` is true. Slack sends an `enterprise` object for a
*workspace-level* install inside a Grid too, and there the install id is still the
team id. Keying on `enterprise` unconditionally would collapse every workspace of
one Grid onto a single install row: one tenant's bot token serving all of them.

Get this wrong the other way and every org-wide event resolves to no install and
is fail-closed dropped.

## Installing a workspace

1. The bridge mints an Add-to-Slack URL for the target workspace:

   ```ts
   buildSlackInstallUrl({
     clientId, redirectUri, workspaceId, stateSecret,
   });
   ```

   The workspace rides the OAuth `state`, **HMAC-SHA256 signed** with a
   bridge-held secret and expiring after 10 minutes. An unsigned `state` is an
   open tenant-assignment hole: hand the callback a state naming a victim's
   workspace and your Slack team mounts inside it.

2. The admin clicks it and approves the scopes.

3. Slack redirects to `GET /connectors/oauth/slack/callback?code=…&state=…`.
   `handleSlackOAuthCallback` verifies the state **before** spending the code,
   exchanges the code, seals the bot token into `credential_ref`, upserts the
   install row, and calls `Bridge.mount(install)` — so the team can message the
   bot immediately. **No restart, no deploy.**

Every failure path (cancelled install, forged state, refused exchange, no team id)
installs **nothing**. A half-written install row is a tenant with a bot token and
no owner.

## What is NOT done

- **The live round trip: NOT PASSED.** Blocked on the human gate above, which is
  itself blocked on the public URL (W4-5). No live install has been performed and
  none is claimed.
- **`credential_ref` is still plaintext.** `sealCredential` / `decryptCredential`
  are wired as injection points and default to identity — the honest current state
  of the column, already documented in `tenant/installs.ts`. The credential cipher
  is a sibling slice; when it lands it plugs into the ONE call site in `index.ts`
  and nothing in the Slack connector changes.
- **The per-workspace `/v1/chat` token.** `chatClientFor(workspaceId)` still hands
  every tenant the one operator token (the P2 known gap). Slack does not make that
  worse — but it does not fix it either, and a Slack install is not tenant-isolated
  on the *Barkpark* side until that slice lands.
- **The HTTP ingress.** This slice ships the connector, its OAuth handler and the
  `extractInstallKey` the router must use; the HTTP server that mounts
  `/connectors/webhook/slack` and `/connectors/oauth/slack/callback` is a sibling
  slice. `SLACK_WEBHOOK_PATH` and `SLACK_OAUTH_CALLBACK_PATH` are exported for it.
