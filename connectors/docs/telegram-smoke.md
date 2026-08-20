<!-- doc-tier: human | canonical-for: connectors-telegram-smoke | budget: 2000tok -->
# Telegram smoke — the human gate

**Status: NOT PASSED. This gate cannot be passed by CI, and has not been passed by a machine.**

The bridge's unit tests prove the map, the turn loop, and the dispatch loop
against a faithful mock of `/v1/chat`. They do **not** prove a real Telegram
round-trip, because that needs two things no test runner has:

1. a real bot, created by a human in Telegram (BotFather), and
2. a **running** Barkpark API serving `/v1/chat`.

So the live round-trip is a human gate. This doc is how you pass it. Nothing
here is simulated; if a step fails, the gate fails.

---

## What you are proving

One message, one reply, one Session:

```
you (Telegram)  ──DM──▶  bot
                          │  getUpdates (polling — no public URL needed)
                          ▼
                     connectors bridge
                          │  resolveTenant   (which workspace owns this bot?)
                          │  resolveOrMint   (mint a Session on 1st msg, resume after)
                          │  POST /v1/chat/sessions/:id/messages
                          │  GET  /v1/chat/sessions/:id/events   (SSE)
                          ▼
                     Barkpark (the engine)
                          │  accumulate `event: chat` frames
                          │  finish on stream-json `type:"result"`
                          ▼
you (Telegram)  ◀─post──  ONE reply per turn
```

---

## 1. Get a bot token (BotFather)

In Telegram, message **@BotFather** → `/newbot` → follow the prompts. It replies
with a token shaped `123456789:AAH...`.

```bash
export TELEGRAM_BOT_TOKEN='123456789:AAH...'
```

The number before the `:` is the **bot id**. That is the install key in
`chat_bridge.connector_installs` — the routing table never stores the raw secret
as a primary key.

## 2. Run a Barkpark API that serves `/v1/chat`

```bash
cd api && mix phx.server
export BARKPARK_API_URL='http://localhost:4000'
```

Sanity-check the route exists. **`401` is the healthy answer** here — it means
the route is live and the auth plug is doing its job:

```bash
curl -si localhost:4000/v1/chat/sessions | head -1     # HTTP/1.1 401 Unauthorized
```

> Local boot can be fussy (see `[[local-api-boot-blockers]]`). If `mix phx.server`
> will not come up, you cannot pass this gate — say so, do not fake it.

## 3. Mint a chat token

P2 ships **zero Elixir changes** (charter D33): the token is minted out-of-band
with the API that already exists. In `cd api && iex -S mix`:

```elixir
# create_token(raw_token, label, dataset, permissions, workspace_id \\ nil)
Barkpark.Auth.create_token(
  "my-telegram-secret",   # the raw token you will export
  "telegram-bridge",      # label
  "production",           # dataset
  ["read", "chat"],       # permissions — `chat` is REQUIRED
  ws.id                   # workspace_id — REQUIRED for real tenancy
)
```

```bash
export BARKPARK_CHAT_TOKEN='my-telegram-secret'
```

**Gotcha (D33):** a `chat` token **without** a `workspace_id` resolves to
`:global` (admin scope). That is fine for a solo dev smoke, and **wrong** for
multi-tenant isolation — a global token can read every workspace's sessions.
A workspace-bound token is what a real connector uses.

## 4. Point at Postgres

```bash
export DATABASE_URL='postgres://postgres:postgres@localhost:5432/barkpark_dev'
```

The bridge creates and owns **only** the `chat_bridge` schema
(`thread_session_map`, `connector_installs`, plus the Chat SDK's own 5
bookkeeping tables). It never writes to `public`. There is no Ecto migration.

Optional:

```bash
export BARKPARK_WORKSPACE_ID='<the ws uuid the token is bound to>'  # default: smoke-workspace
export BRIDGE_PERSIST_INSTALL=1   # write the install row to connector_installs
```

## 4b. Set the credential key (D35)

```bash
export CONNECTORS_CREDENTIAL_KEY=$(openssl rand -base64 32)
```

Both secrets in an install row — the bot token **and** the chat token — are sealed
with AES-256-GCM, bound by AAD to `(provider, install_key, workspace_id)`. Missing
key ⇒ the bridge refuses to boot; there is deliberately no plaintext fallback.

Keep the key. Rows sealed under a key you lose can never be opened again (rotate
by moving the old key to `CONNECTORS_CREDENTIAL_KEY_PREVIOUS` and re-writing the
rows — never by dropping it).

The chat token you exported above is sealed into **this bot's** install row
(`chat_token_ref`). The running bridge reads it from there and nowhere else: there
is no process-wide operator token any more.

## 5. Run it

```bash
cd connectors && npm ci && npm run smoke:telegram
```

Polling mode (`getUpdates`) — **no public URL, no tunnel, no webhook.**

---

## What success looks like

The harness probes `/v1/chat` first and refuses to poll if the API is not
reachable. On a healthy run:

```
[smoke] Telegram bridge — live round-trip
[smoke]   api          http://localhost:4000
[smoke]   bot id       123456789
[smoke]   workspace    <ws uuid>

[smoke] /v1/chat reachable — probe session 0f3c…-…
[smoke] chat_bridge schema ready (thread_session_map, connector_installs)
[smoke] install held in memory (set BRIDGE_PERSIST_INSTALL=1 to persist)

[smoke] polling (getUpdates). No public URL needed.
[smoke] DM your bot on Telegram now. Ctrl-C to stop.
[smoke] Expect EXACTLY ONE reply per message (post-once-per-turn, D12).
```

Now **DM the bot**. Send `hello`. Expect:

```
[smoke] inbound  thread=telegram:… text="hello"
[smoke] outcome  posted
[smoke] session  0f3c…  (MINTED — first message in this thread)
[smoke] replied  "…"
[smoke] ✓ round-trip complete — check your Telegram chat.
```

Send a **second** message in the same chat. The Session must be **RESUMED**, not
minted again — that is the cross-surface memory (D6):

```
[smoke] session  0f3c…  (RESUMED — same Session as before)
```

### The three things that actually prove the core

| Claim | How you see it |
|---|---|
| **Mint once, resume after** | 1st msg says `MINTED`, every later msg in that chat says `RESUMED` with the **same** session uuid |
| **Post once per turn** (D12/D26) | exactly **one** Telegram bubble per message — never a partial-then-edited stream |
| **Tenant isolation** (D1/D29) | the Session is keyed `(workspace, thread)`; a bot with no install row is **dropped**, never routed to a default workspace |

You can confirm the map landed:

```sql
SELECT workspace_id, thread_id, session_uuid FROM chat_bridge.thread_session_map;
```

---

## When it fails

| Symptom | Meaning |
|---|---|
| `FAILED to create a session on /v1/chat` + `401`/`403` | the token lacks the `chat` permission, or carries no `workspace_id` |
| `FAILED …` + `ECONNREFUSED` | nothing is listening at `BARKPARK_API_URL` |
| `outcome  dropped_no_tenant` | no install row matches this bot id — the fail-closed path working as designed |
| `outcome  dropped_no_install` | the row's sealed refs did not open — wrong `CONNECTORS_CREDENTIAL_KEY`, or the row was sealed under another key (or moved between workspaces) |
| `outcome  dropped_no_chat_token` | the install has no `chat_token_ref` sealed. The bridge will **not** fall back to an operator token (D35) |
| `outcome  empty_reply` | the turn produced no text; we post nothing rather than an empty bubble |
| No `[smoke] inbound` at all | the bot never received the update. Another process may be polling the same bot, or a webhook is registered (polling and webhooks are mutually exclusive on Telegram) |

## What this gate does NOT cover

- Slack / Discord / Teams / WhatsApp / iMessage — **P3**, deliberately not wired.
- Webhook transport — **not implemented.** Polling (`getUpdates`) is the only
  transport the connector wires; there is no webhook route and no `setWebhook`
  call. A webhook wire is backlog (`connectors-telegram-webhook-wire`).
- The sandboxed runner (**P1**) and tool connectors (**P4**).
- A self-serve install flow: `upsertInstall()` (what this smoke calls) is an
  operator write path. Connecting a bot from Studio is P3 connect UX.
- A self-serve **mint** for the per-install chat token: `Auth.create_token/5`
  still has to be called from a console. The smoke seals whatever
  `BARKPARK_CHAT_TOKEN` you export into *this install's* `chat_token_ref` — it is
  an install-provisioning input, not a process-wide token (D35).
