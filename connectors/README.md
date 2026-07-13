<!-- doc-tier: human -->

# Barkpark Connectors

The provider-agnostic bridge: **write bot logic once, deploy everywhere.**

A standalone Node/TypeScript service built on [Vercel's Chat SDK](https://chat-sdk.dev)
(`chat` + `@chat-adapter/*`). It is a **client** of Barkpark's `/v1/chat` HTTP+SSE
API — the BEAM stays the engine; the bridge speaks the channels. Adding a channel
(Slack, Discord, Teams, WhatsApp, iMessage) is a registry entry, not a core change.

> **Status: W3-1 (scaffold) only.** This package currently contains the state
> layer and the shared `ChatClient` contract. The HTTP/SSE client (W3-2), the turn
> loop (W3-3), the connector registry (W3-4) and the Telegram smoke adapter (W3-5)
> land on top of it. There is no runnable service entrypoint yet.

## Why it is not in `js/`

`js/` is a changesets-published SDK **library** workspace (every package ships to
npm as `@barkpark/*`). This is a private, **deployable service**. It therefore lives
at the repo root with its own `package-lock.json`, deliberately **outside** the root
`pnpm-workspace.yaml`. Do not add a nested `pnpm-workspace.yaml` here — it shadows
the root one and breaks `pnpm install` for the whole repo. (Charter D27.)

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
    npm run typecheck     # tsc --noEmit
    npm test              # vitest run

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

Per-workspace `/v1/chat` credentials are **not** global env vars: each tenant's
chat-permission token is resolved through `connector_installs` (D29/D33). Barkpark's
`secrets` table is currently instance-global and is *not* a per-workspace credential
store, so the bridge owns its own.
