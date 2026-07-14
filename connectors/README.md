<!-- doc-tier: human -->

# Barkpark Connectors

The provider-agnostic bridge: **write bot logic once, deploy everywhere.**

A standalone Node/TypeScript service built on [Vercel's Chat SDK](https://chat-sdk.dev)
(`chat` + `@chat-adapter/*`). It is a **client** of Barkpark's `/v1/chat` HTTP+SSE
API — the BEAM stays the engine; the bridge speaks the channels. Adding a channel
(Slack, Discord, Teams, WhatsApp, iMessage) is a registry entry, not a core change.

> **Status: the P2 core is complete; the live Telegram round-trip is a HUMAN GATE
> that has NOT been run.** Everything here is proven by unit tests against a real
> ephemeral Postgres and a byte-exact `/v1/chat` mock. Nothing has yet talked to a
> real BotFather bot or a running BEAM. See `docs/telegram-smoke.md` — it opens
> with "Status: NOT PASSED", and that is the honest state.

## The core loop

    inbound event
      -> connector.resolveTenant   which workspace? (fail closed)
      -> map.resolveOrMint         which Session? (mint once, resume after)
      -> runTurn                   send the turn, consume the SSE stream
      -> thread.post(finalText)    reply EXACTLY once per turn

`src/core/dispatch.ts` is that loop, and it **never names a channel**. Adding
Slack/Discord/Teams/WhatsApp/iMessage in P3 is one `registry.register(...)` entry
plus its `@chat-adapter/*` dependency — no core edit. A structural tripwire in
`test/tenant.test.ts` fails the build if a provider name ever appears in the core's
executable code.

## Why it is not in `js/`

`js/` is a changesets-published SDK **library** workspace (every package ships to
npm as `@barkpark/*`). This is a private, **deployable service**. It therefore lives
at the repo root with its own `package-lock.json`, deliberately **outside** the root
`pnpm-workspace.yaml`. Do not add a nested `pnpm-workspace.yaml` here — it shadows
the root one and breaks `pnpm install` for the whole repo. (Charter D27.)

## Deploy shape

A **persistent, always-on Node process** — not Vercel serverless functions
(charter D32). Telegram's `getUpdates` polling wants a long-lived loop, P3's
Discord needs a persistent Gateway websocket, and the streaming glue is itself a
long-lived SSE client. There is deliberately **no `vercel.json`**: it would imply
a deploy shape this wave explicitly rejected. Webhook-only providers could get one
later. The host is not a commitment of this wave.

## The one piece of state

The bridge holds exactly **one** piece of per-conversation state:

    (workspace_id, thread_id)  ->  Barkpark Session UUID   (chat_sessions.id)

Minted on a thread's first message, resumed on every message after — so a
conversation stays continuous. `POST /v1/chat/sessions` always mints a *fresh*
UUID (there is no find-or-create server-side), so this map is what makes resume
work at all.

Continuity is **per-channel** this wave; true cross-channel identity linking is
deferred to P4 (charter D31).

### Schema isolation is load-bearing

Everything the bridge writes lives in its own `chat_bridge` Postgres schema,
never in Barkpark's Ecto-owned `public` schema. This is not cosmetic:

- `@chat-adapter/state-pg` auto-creates **five** tables (`chat_state_cache`,
  `chat_state_lists`, `chat_state_locks`, `chat_state_queues`,
  `chat_state_subscriptions`) with **unqualified** `CREATE TABLE IF NOT EXISTS`,
  and exposes **no** schema/searchPath/table-prefix option.
- So the **only** thing deciding where those tables land is the `search_path` of
  the pool it is handed. `db/pool.ts` pins it via the Postgres startup parameter
  `options=-c search_path=chat_bridge`, applied before any query runs.
- `keyPrefix` namespaces the SDK's **row keys**, not its table names. It cannot
  do this job. Handing state-pg a bare `url` would create those five tables right
  next to `chat_sessions`.

There is **no Ecto migration** for any of this — the bridge creates its own schema
and tables idempotently at boot (`ensureBridgeSchema`). (Charter D28.)

### Why not `thread.setState`

The Chat SDK's thread state hardcodes `THREAD_STATE_TTL_MS = 30 days`. A Session
binding stored there would silently vanish for any conversation that goes quiet
for a month, and the next message would start a brand-new Session with no memory.
The binding is a plain indexed row instead. A test enforces this (`D28 invariant`).

## Tables

| Table | Key | Purpose |
|---|---|---|
| `thread_session_map` | `(workspace_id, thread_id)` | The Session binding above. |
| `connector_installs` | `(provider, install_key)` | Tenant routing: which workspace an inbound provider event belongs to, and where that tenant's credential lives. The seam P3/OAuth writes into (D29). |

## Development

    npm install
    npm run typecheck        # tsc --noEmit (src, test AND scripts)
    npm test                 # vitest run
    npm run format:check     # prettier
    npm start                # the persistent bridge process
    npm run smoke:telegram   # the human gate (prints what it needs, never fakes it)

### The tests need a real Postgres

The state-layer proofs run against a **real, ephemeral** Postgres database that the
test creates and drops (`connectors_bridge_test_*`). They never touch Barkpark's
own database.

They deliberately do **not** use `pg-mem`: it treats `SET search_path` as a no-op
and reports every table in `public`, so it is structurally incapable of proving
schema isolation — the one thing that matters here. It also diverges from Postgres
on `ON CONFLICT DO NOTHING ... RETURNING`, the exact branch `resolveOrMint` relies
on for concurrent first messages. A green from it would be a fabricated green.

- Default admin connection: `postgres://localhost:5432/postgres`.
- Override with `CONNECTORS_TEST_DATABASE_URL`.
- **If no Postgres is reachable, these tests SKIP with a loud warning.** Set
  `CONNECTORS_REQUIRE_DB=1` to turn that skip into a hard failure (use this in CI,
  which should run a Postgres service).

## Configuration

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Postgres for the bridge's `chat_bridge` schema. |
| `BARKPARK_API_URL` | Base URL of the Barkpark API serving `/v1/chat`. |
| `BARKPARK_CHAT_TOKEN` | An ApiToken with the `chat` permission **and** a `workspace_id`. A `chat` token without a workspace is `403` (D33). |
| `BRIDGE_USER_NAME` | The agent's display name in a channel. Default `barkpark`. |

## Known gaps — read before trusting the isolation story

These are real, filed, and deliberately not papered over:

- **One chat token serves every tenant.** `chatClientFor(workspaceId)` in
  `src/index.ts` currently **ignores** its argument and hands back a client built
  from the single `BARKPARK_CHAT_TOKEN`. The multi-tenant *seam* is right, but
  today isolation of `/v1/chat` reads is only as strong as that one token — and a
  `:global` one would see every workspace's sessions. Filed:
  `connectors-per-workspace-chat-token`.
- **`credential_ref` is plaintext.** The BotFather token is stored as-is in
  `connector_installs`. Filed: `connectors-encrypt-install-credentials`.
- **No self-serve install flow.** `upsertInstall()` is an operator/smoke write
  path; a workspace cannot connect a bot for itself. That is the P3 connect UX.
  Filed: `connectors-p3-install-write-credentials`.

What *is* structurally enforced today: an inbound event never resolves to a tenant
it does not belong to (fail-closed reads, no default-workspace fallback anywhere),
and one workspace's adapter is only ever built from that workspace's own credential.
