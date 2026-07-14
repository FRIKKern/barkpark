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

`publicKey` verifies Ed25519 webhook signatures, which v1 does not use — it is required anyway, not
defaulted to a sentinel, so that the day slash commands land every existing install already carries
a real key.

## Gateway-only in v1

The bot connects over the **Gateway websocket**. It needs **no public URL**, no tunnel, and no
inbound HTTP at all — DMs and mentions (everything the turn loop needs) arrive over the socket.

**Slash commands are out of v1.** They require Discord's Ed25519-signed HTTP interaction endpoint,
which is a webhook seam this connector deliberately does not depend on. Filed as
`connectors-discord-slash-commands`.

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
