# Discord — bring your own bot (there is no one-click install)

**Discord onboarding is BYO-bot, not an "Add to Discord" button.** Each workspace creates its own
Discord Application and its own bot token. That is a real cost — roughly Telegram-weight, five
minutes in a browser — and this page says so up front rather than letting you discover it.

Charter: `.claude/workflows/bp-connectors-charter.md` (D41). Code:
`connectors/src/connectors/discord.ts`.

## Why not a shared app + `guild_id`

A single Barkpark-owned Discord app with an OAuth "Add to Server" button is the nicer story, and it
is the exact bug this wave exists to kill.

`DiscordAdapterConfig` takes **one static `botToken`**, with no installation provider and no
per-guild credential hook. So a shared app means **one credential serving every tenant** — the
headline multi-tenant leak, wearing an OAuth button as a disguise. A guild id in the payload does
not save you: a guild does not *own* the bot, the **application** does.

So the bot token IS the tenant binding (`tenantResolution: "credential-bound"`, exactly like
Telegram), and the tenant is resolved from the inbound path before the payload is ever inspected.

## What you create (per workspace)

1. <https://discord.com/developers/applications> → **New Application**.
2. **General Information** → copy the **Application ID** and the **Public Key**.
3. **Bot** → **Reset Token** → copy the **bot token**. This is the secret; it is shown once.
4. **Bot** → **Privileged Gateway Intents** → enable **Message Content Intent**. Without it the
   Gateway delivers empty message bodies and the bot will look alive but answer nothing.
5. **OAuth2 → URL Generator** → scopes `bot`, permissions `Send Messages` + `Read Message History`
   → open the generated URL and invite the bot to your server.

## The install row

`chat_bridge.connector_installs`:

| column | value |
|---|---|
| `provider` | `discord` |
| `install_key` | the **Application ID** (non-secret, stable — never a raw token) |
| `workspace_id` | the workspace that owns this bot |
| `credential_ref` | the JSON triple below |

```json
{"applicationId":"111111111111111111","botToken":"<bot token>","publicKey":"<public key>"}
```

**All three are required.** The vendor's adapter constructor falls back to
`process.env.DISCORD_BOT_TOKEN` / `DISCORD_APPLICATION_ID` / `DISCORD_PUBLIC_KEY` for anything you
leave out — in a multi-tenant bridge that fallback is a **cross-tenant leak**, so
`parseDiscordCredential()` refuses an incomplete credential rather than letting a process-wide token
stand in for a workspace's own. A test poisons those env vars and proves the leak is unreachable.

`publicKey` verifies the Ed25519 signature on Discord's HTTP **interactions** (slash commands). It is
required from the start — not defaulted to a sentinel — precisely so that the day slash commands
landed, every existing install already carried a real key.

## Two transports, one handler

Discord speaks to the bridge over **two inbound transports, and they run side by side** (charter
D225/D228) — never an either/or at the bridge:

| Transport | Carries | Needs |
|---|---|---|
| **Gateway websocket** (`listen()`) | DMs and @-mentions | no public URL — nothing inbound |
| **Ed25519-signed HTTP webhook** | slash-command **interactions** | a public HTTPS endpoint |

DMs and mentions keep flowing over the socket with no inbound URL at all. Slash commands ride the
generic webhook seam: the vendor `DiscordAdapter.handleWebhook` already ships the whole interaction
protocol — raw-body Ed25519 verify, PING→PONG, the synchronous deferred ack, and background
dispatch — so the bridge adds zero protocol code. The connector declares `webhook: { keySource:
"path" }` and the same `chat.onSlashCommand` handler funnels a command into the identical turn loop
DMs and mentions use.

> **Discord's own either/or.** *Delivery* of interactions is mutually exclusive per application:
> once you set the portal **Interactions Endpoint URL**, Discord stops sending `INTERACTION_CREATE`
> over the Gateway and sends every interaction to the webhook instead. `MESSAGE_CREATE` (DMs,
> mentions) is unaffected and keeps flowing on the socket. So "two transports" means *socket for
> messages, webhook for interactions* — the same registered handler serves whichever delivers.

## Turning on slash commands (ops runbook)

Slash commands are BYO-bot too: three ops steps, each with a failure mode Discord surfaces quietly.

### 1. Deploy the webhook route BEFORE you save the URL

Your interactions endpoint is, per install (the install key is the **Application ID**):

```
https://<your-public-host>/connectors/webhooks/discord/<applicationId>
```

Concrete example against the reference host:

```
https://guerrilla.barkpark.cloud/connectors/webhooks/discord/111111111111111111
```

Paste it into **General Information → Interactions Endpoint URL** in the Developer Portal and Save.
**The route must already be live and reachable.** Discord PING-validates at save time: it sends a
signed `type: 1` PING and refuses the save unless it gets a `type: 1` PONG back. If the bridge is
not deployed, or the endpoint is behind auth, or the install's `publicKey` is wrong, the portal
rejects the URL and will not save it. There is **no** "copy this URL from Studio" — Studio surfaces
no webhook URL for any provider; you construct it from your public host + the Application ID above.

### 2. Named failure mode — a failing endpoint is SILENTLY removed

After the URL is saved, Discord runs **ongoing invalid-signature probes**. If your endpoint starts
failing verification (an expired/rotated `publicKey`, a bridge regression on the Ed25519 path),
Discord **silently removes the Interactions Endpoint URL** and notifies only by email / a System DM
to the app owner — there is **no** error in the bridge logs. The symptom reads as *"slash commands
reverted to unconfigured"* with zero bridge-side signal. If commands stop arriving over the webhook
but DMs still work (they are on the socket), check the portal: the Interactions Endpoint URL is
probably blank. Fix the `publicKey`/signature path, then re-save the URL (step 1 re-runs the PING).

### 3. Register the commands (guild-scoped for dev, global for prod)

Registering the command *definitions* is a Discord REST call, not something the bridge does — it is
an ops step, run once per command shape. **Guild-scoped** registration updates **instantly** and is
what you want while developing; **global** registration takes up to **~1 hour** to propagate.

```bash
# Guild-scoped (instant) — dev loop:
curl -X PUT \
  "https://discord.com/api/v10/applications/<applicationId>/guilds/<guildId>/commands" \
  -H "Authorization: Bot <botToken>" \
  -H "Content-Type: application/json" \
  -d '[{"name":"ask","description":"Ask the agent","type":1,"options":[{"name":"q","description":"your question","type":3,"required":true}]}]'

# Global (all guilds, ~1h propagation) — production:
curl -X PUT \
  "https://discord.com/api/v10/applications/<applicationId>/commands" \
  -H "Authorization: Bot <botToken>" \
  -H "Content-Type: application/json" \
  -d '[{"name":"status","description":"Bridge status","type":1}]'
```

A command with no `options` (like `/status`) arrives with empty argument text — the bridge funnels
the command name itself (`/status`) into the turn loop, so a bare command still reaches the agent.

**Interaction tokens live 15 minutes.** The synchronous deferred ack buys the turn that long to
produce its reply; a turn that runs past 15 minutes can no longer edit the interaction.

## Three vendor traps, handled once

`connectors/src/connectors/gateway.ts` is the shared supervisor for the socket channels (Discord and
iMessage speak the identical `startGatewayListener` API). It exists because the vendor has three
sharp edges, and all three fail *silently*:

1. **A 500 that looks like silence.** `startGatewayListener` returns (not throws) a same-tick
   `500` when `waitUntil` is missing, or when `chat.initialize()` has not run. We check `res.ok`
   and throw, so a misconfigured install breaks the boot loudly.
2. **`durationMs` is a `setTimeout` delay.** The listener is `setTimeout(resolve, durationMs)`
   followed by `client.destroy()`. Node **silently collapses any delay above 2^31-1 to 1 ms**, so
   `Number.MAX_SAFE_INTEGER` destroys the connection about a millisecond after login — strictly
   worse than the 3-minute default it was meant to defeat. We cap at `NODE_TIMEOUT_MAX` and reject
   anything larger rather than truncate it.
3. **A window still ends.** 24.8 days is not forever, and a revoked token ends one in seconds. The
   bridge is a persistent process, so the supervisor **re-arms** — with exponential backoff for
   connections that die fast, so a bad token never hot-loops against Discord's API.
