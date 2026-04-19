# Realtime Gap Analysis — Studio edit → Next.js auto-refresh

- **Task:** #16 / Subtask 1
- **Date:** 2026-04-19
- **Author:** Worker 4.1 (team `barkpark-realtime`)
- **Branch:** `research/realtime-gap-task16` (cut from `shakedown/preview-2-verify-task15`)
- **Scope:** research-only, no source edits

---

## TL;DR

Most of the realtime wire *exists*: Phoenix exposes SSE at `/v1/data/listen/:dataset`, `@barkpark/core` ships a full SSE client (`client.listen()`), and `@barkpark/nextjs/client` exports `<BarkparkLive/>` which debounces events into `router.refresh()`. **But the loop is broken in four concrete places:** (1) `/v1/data/listen/:dataset` is behind `:require_token`, so a public browser can't subscribe without shipping a token; (2) `router.refresh()` does **not** bust Next's Data Cache — `barkparkFetch` uses `force-cache` with `next.tags` keyed on `bp:ds:<ds>:*`, so fetches still return stale bytes until `revalidateTag` runs; (3) nothing bridges the SSE event's `syncTags` to a `revalidateTag()` call; (4) `revalidateBarkpark()` in `@barkpark/nextjs/revalidate` emits a **different tag prefix** (`barkpark:doc:*`) than what `barkparkFetch` tags reads with (`bp:ds:<ds>:doc:*`), so even the webhook path revalidates tags nothing uses. Recommendation: **Option 1 (webhook-bridge)** with two backend tweaks and two SDK fixes — smallest surface, correct prod semantics, no browser token required.

---

## Backend surface (today)

### Listen controller — `api/lib/barkpark_web/controllers/listen_controller.ex`

- **Protocol:** HTTP SSE (`text/event-stream`, `send_chunked/2`, 30 s `": keepalive\n\n"`).
- **Route:** `get "/listen/:dataset"` (`api/lib/barkpark_web/router.ex:90`) inside the `[:api, :require_token]` pipe — **auth required** (`router.ex:87-90`).
- **Subscribes:** `Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")` (`listen_controller.ex:17`). Only the global topic.
- **Resume:** honours `Last-Event-ID` header or `?lastEventId=` param; replays from `Barkpark.Content.MutationEvent` via `replay_since/2` (`listen_controller.ex:11-15, 43-49`).
- **Frame shape** (`listen_controller.ex:52-73`):
  ```
  id: <ev.id>
  event: mutation
  data: {"eventId","mutation","type","documentId","rev","previousRev","result","syncTags":["bp:ds:<ds>:doc:<pubId>","bp:ds:<ds>:type:<type>"]}
  ```
  Plus a one-shot `event: welcome`.
- **Filtering:** none. `listen_controller.ex` does **not** inspect `perspective`, `types`, or `filter[...]` query params — it forwards every document-change event on the dataset to every subscriber. The client-side `createListenHandle` URL-encodes `types` / `perspective` / `filter[...]` (`js/packages/core/src/listen.ts:108-115`) but the server ignores them.

### Router — `api/lib/barkpark_web/router.ex`

```elixir
# api/lib/barkpark_web/router.ex:87-98
scope "/v1/data", BarkparkWeb do
  pipe_through [:api, :require_token]

  get "/listen/:dataset", ListenController, :listen
  get "/export/:dataset", ExportController, :export
  ...
end
```

No other SSE / long-poll endpoint. The endpoint (`api/lib/barkpark_web/endpoint.ex:16-18`) declares **only** the LiveView socket:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: [connect_info: [session: @session_options]]
```

No custom `UserSocket`, no `channel "documents:*"`, no non-LiveView channel surface. CORS is `origins: "*"` (`endpoint.ex:52`) with `last-event-id` in `allow_headers`.

### PubSub — `api/lib/barkpark/content.ex`

- `tap_broadcast/5` (`content.ex:871-907`) fires on every successful `{:ok, doc}` from create / update / publish / unpublish / discardDraft / delete (call sites at `content.ex:204,210,248,289,308,331,535,592,598`).
- Two topics broadcast per mutation:
  - Global: `"documents:#{dataset}"` — `{:document_changed, msg}` (`content.ex:896, 899`)
  - Per-doc: `"doc:#{dataset}:#{type}:#{published_id(doc.doc_id)}"` — `{:doc_updated, msg}` (`content.ex:897, 900`)
- Payload `msg` (`content.ex:877-894`): `event_id, type, mutation (create|update|publish|unpublish|discardDraft|delete), action: :mutate, doc_id, rev, previous_rev, document (Envelope.render/1), doc (legacy shape), sender: self()`.
- **Transaction safety:** `maybe_broadcast/2` (`content.ex:911-918`) defers into the process dict when inside `Repo.in_transaction?` and flushes via `flush_deferred_broadcasts/0` on commit (`content.ex:936-952`) — drops on rollback. No ghost events on the SSE stream.
- **Subscribers today (Phoenix-internal only):**
  - `DashboardLive` (`api/lib/barkpark_web/live/studio/dashboard_live.ex:11`)
  - `DocumentListLive`, `DocumentEditLive`, `StudioLive` (Studio panes)
  - `ListenController` (SSE)
  - `Webhooks.Dispatcher.dispatch_async/6` (`content.ex:901, 930` → `webhooks/dispatcher.ex:27`)

### Wire-protocol verdict

A non-LiveView client has **one** subscription surface today: the SSE stream at `/v1/data/listen/:dataset` — gated by `:require_token`. The SSE payload already carries `syncTags` in the canonical `bp:ds:<ds>:doc:<id>` / `bp:ds:<ds>:type:<type>` format. Broadcasts are **not** perspective-aware — a `published`-consumer receives every `drafts.*` update too.

---

## Client surface (today)

### Inventory

| Symbol | Package | File:line | Connects to | Status |
|---|---|---|---|---|
| `createListenHandle<T>` | `@barkpark/core` | `js/packages/core/src/listen.ts:52` | `GET /v1/data/listen/:dataset` via `fetch()` + `ReadableStream` reader | **Functional.** Uses `Authorization: Bearer <token>`, `Last-Event-ID`, exponential backoff (max 5, base 500 ms, cap 8 s), edge-runtime hard throw. EventSource explicitly rejected because it can't set Authorization (`listen.ts:7-8`). |
| `client.listen(type, filter)` | `@barkpark/core` | `js/packages/core/src/client.ts:172-177` | Delegates to `createListenHandle` | Functional. |
| `BarkparkLive` | `@barkpark/nextjs/client` | `js/packages/nextjs/src/client/live.tsx:73-96` | `client.listen()` inside `useEffect` | Functional at the transport layer. On each event, debounces 500 ms then calls `router.refresh()` (`live.tsx:83-93, 231-247`). Renders `null`. Edge-guard synchronous throw in `assertNotEdge()`. |
| `BarkparkLiveProvider` | `@barkpark/nextjs/client` | `js/packages/nextjs/src/client/live.tsx:127-137` | React context wrapper for client | Functional. |
| `startLiveSubscription(opts)` | `@barkpark/nextjs/client` | `js/packages/nextjs/src/client/live.tsx:179-250` | Same as above, framework-free | Functional. |
| `defineLive(cfg)` | `@barkpark/nextjs/server` | `js/packages/nextjs/src/server/core.ts:212-218` | **Nothing realtime.** Returns `{ barkparkFetch }` | **Misleading name** — no SSE, no channel, no `Live`. This is a server-fetch config helper. |
| `createBarkparkServer(cfg)` | `@barkpark/nextjs/server` | `js/packages/nextjs/src/server/core.ts:249-255` | Wraps `defineLive` | Functional. |
| `createWebhookHandler(cfg)` | `@barkpark/nextjs/webhook` | `js/packages/nextjs/src/webhook/index.ts:135-198` | Inbound HTTP POST handler (HMAC-SHA256 `t=<ts>,v1=<hex>`, LRU dedup) | Functional. Matches Phoenix dispatcher wire (`api/lib/barkpark/webhooks/dispatcher.ex:64-73`). |
| `revalidateBarkpark(payload)` | `@barkpark/nextjs/revalidate` | `js/packages/nextjs/src/revalidate/index.ts:46-74` | `next/cache` `revalidateTag` / `revalidatePath` | **Broken prefix** — emits `barkpark:doc:*` / `barkpark:type:*` (`revalidate/index.ts:50,54,55,58,62`). `barkparkFetch` reads with `bp:ds:<ds>:doc:*` / `bp:ds:<ds>:type:*` (`server/core.ts:109`). No overlap. |
| `defineActions(...)` | `@barkpark/nextjs/actions` | `js/packages/nextjs/src/actions/defineActions.ts:57-60` | Fans out canonical `bp:ds:<ds>:doc:<id>` + `bp:ds:<ds>:type:<type>` on in-app Server Action mutations | Functional — but **only fires when the Next.js app itself performs the mutation**. A Studio edit never traverses this path. |
| `@barkpark/react/src/server.ts` | `@barkpark/react` | RSC helpers (Image, PortableText, Reference) | — | **No realtime here.** `client.ts` is absent — the package is RSC-only (`js/packages/react/src/` has `index.ts`, `server.ts`, three `.tsx`). |

### What `BarkparkLive` actually does

```
useEffect mount
  └─ client.listen()                 ← opens SSE
      └─ for await (evt of handle)   ← yields on every mutation
          └─ debounce 500 ms
              └─ router.refresh()     ← ONLY action taken
```

`router.refresh()` re-renders the current route's Server Components, but in production fetches issued by `barkparkFetch` use `cache: 'force-cache'` with `next.tags` (`server/core.ts:146-150`) — they return cached bytes until `revalidateTag()` invalidates the relevant tag. `router.refresh()` invalidates the **Router Cache** (client RSC payloads), not the **Data Cache**. The `evt.syncTags` array that arrives on the wire (`listen.ts:327-329`) is *discarded* by `BarkparkLive`.

### Server vs client split

- **Server-only** (`'use client'` forbidden): `server/core.ts`, `preload/index.ts`, `webhook/index.ts`, `revalidate/index.ts`, `actions/defineActions.ts`, `@barkpark/react/server.ts`.
- **Client-only** (`'use client'` at top): `client/live.tsx`, `client/index.ts`.
- **Isomorphic:** `@barkpark/core` (no React deps, edge-aware).
- Realtime today lives **only** in the browser. There is no server-side `listen()` consumer anywhere in `js/packages/*`.

---

## End-to-end trace — where the wire breaks

Scenario: production `next build` + `next start`, `BarkparkLiveProvider` mounted in the root layout, `app/posts/[slug]/page.tsx` calls `server.barkparkFetch({ type: 'post', id })`. User edits the post in `/studio`.

1. **Studio (LiveView) writes to Postgres.** `MutateController → Content.apply_mutations → tap_broadcast` deferred inside the Ecto transaction. ✅
2. **Transaction commits → flush_deferred_broadcasts.** `Phoenix.PubSub.broadcast` fires on `"documents:production"` and the per-doc topic. ✅
3. **SSE listeners receive `{:document_changed, msg}`.** `ListenController.listen_loop/2` formats a `mutation` frame with `syncTags: ["bp:ds:production:doc:p1","bp:ds:production:type:post"]` and chunks it out. ✅
4. **Browser receives the frame** — if it successfully opened the stream. **First break point:** `/v1/data/listen/:dataset` requires a Bearer token (`router.ex:88`). For a public website, the client instance given to `<BarkparkLive client={...} />` must be created with a token baked into the browser bundle. No "listen-only" restricted-scope token type exists; production would have to expose a full token. In practice today this only works with `barkpark-dev-token` in dev or a misuse in prod.
5. **`createListenHandle` parses the frame → yields `ListenEvent<T>` with `.syncTags`.** ✅ (`listen.ts:300-330`)
6. **`BarkparkLive` debounces 500 ms and calls `router.refresh()`.** ✅ (`live.tsx:231-247`)
7. **Next.js re-renders the Server Component.** `server.barkparkFetch({ type: 'post', id })` re-executes — but its fetch is `cache: 'force-cache'` with `next.tags: ['bp:ds:production:_all']` (plus `userTags`, plus `opts.syncTags` if the caller threaded them through `preloadDocument` — which the default starter does not). **Second break point:** nothing invalidated those tags, so the fetch returns the **same stale JSON from the Data Cache**. The user sees no change.

Even if the server somehow invalidated the right tag, it wouldn't be the right tag: the event's `syncTags` are `bp:ds:production:doc:p1` / `bp:ds:production:type:post`, but the default list-query fetch only carries `bp:ds:production:_all`. `_all` is not in the event payload. **Third break point.**

Webhook alternative path (Studio → Phoenix webhook → Next.js `/api/barkpark/webhook`):
- `createWebhookHandler` accepts the POST. ✅ (`webhook/index.ts:135`)
- `cfg.onMutation(payload)` runs. The example in the doc-block wires it to `revalidateBarkpark(payload)`.
- **Fourth break point:** `revalidateBarkpark` emits `barkpark:doc:*` / `barkpark:type:*` — no fetch in the codebase reads with that prefix. Zero tags invalidated.
- Even ignoring the prefix bug, the Phoenix webhook payload is `{event, type, doc_id, document, dataset, timestamp}` (`dispatcher.ex:53-62`), but `revalidateBarkpark` expects `{_id, _type, ids, types, ...}` (`revalidate/index.ts:12-19`). Silent no-op by field-name mismatch.

---

## EXISTS vs MISSING

### EXISTS

- Phoenix SSE endpoint `/v1/data/listen/:dataset` with Last-Event-ID resume and 30 s keepalive.
- Full-fidelity `MutationEvent` replay table for disconnect recovery.
- PubSub broadcast on every write, transaction-safe, deferred-flush on commit.
- Phoenix webhook system: per-dataset endpoints, HMAC-v1 signing (`t.body`), dedup via `UNIQUE(endpoint_id, event_id)`, retry backoff `[1s, 5s, 30s]`.
- `@barkpark/core` SSE client with Authorization support, Last-Event-ID resume, exponential-backoff reconnect, edge-guard.
- `<BarkparkLive/>` and `<BarkparkLiveProvider/>` client components — they actually open the stream and trigger `router.refresh()`.
- `createWebhookHandler` wire-compatible with the Phoenix dispatcher (matching `t=<unix>,v1=<hex>` HMAC signing).
- `defineActions` correctly fans out `bp:ds:<ds>:doc:<id>` + `bp:ds:<ds>:type:<type>` tags on in-app Server-Action mutations.
- Canonical tag format shared between server-fetch tag-write (`server/core.ts:109, 147`) and Studio-side tag payload (`listen_controller.ex:55-58`): `bp:ds:<ds>:doc:<id>`, `bp:ds:<ds>:type:<type>`.

### MISSING

- **Browser-safe listen-only token.** `/v1/data/listen/:dataset` requires a full token; no restricted-scope or signed-short-lived-token mechanism for public browsers.
- **SSE-to-`revalidateTag` bridge.** `BarkparkLive` receives `evt.syncTags` and throws them away. Nothing in the SDK forwards them into a `revalidateTag` call (client can't — `revalidateTag` is server-only).
- **Correct tag prefix in `revalidateBarkpark`.** Helper currently emits `barkpark:doc:*` / `barkpark:type:*`; the canonical prefix in fetches and in listen-event `syncTags` is `bp:ds:<ds>:*`. Dataset is also absent from the helper's output — no way to scope per dataset.
- **Phoenix webhook payload → revalidateBarkpark shape adapter.** Phoenix sends `{event, type, doc_id, document, dataset}`; helper reads `{_id, _type, ids, types, path, paths}`. No mapping published.
- **Phoenix webhook payload does not include `syncTags`.** `dispatcher.ex:53-62` omits them; downstream revalidation has to re-derive tags from `doc_id` + `type` + `dataset`.
- **Auto-syncTag inclusion on list fetches.** `barkparkFetch` for a list query only tags with `bp:ds:<ds>:_all` + user-supplied tags. Revalidating `bp:ds:<ds>:doc:p1` does not invalidate the cached `type=post` list because the list's cache entry isn't tagged with that id. Options: (a) include `bp:ds:<ds>:type:<type>` on list fetches automatically, and ensure the listen-event's `syncTags` always contains `type:<type>` (it does, `listen_controller.ex:57`); (b) push-invalidate `_all` on every mutation (blunt, thrashes cache).
- **Perspective-aware listen filter.** `listen_controller.ex` ignores `perspective`, `types`, and `filter[...]` params — all subscribers get all events, including draft-only writes. A public site's listener will fire `router.refresh()` on every keystroke in the Studio draft editor.
- **Server-side SSE consumer in `@barkpark/nextjs`.** No helper that opens the Phoenix SSE from a long-lived Next.js route/worker and calls `revalidateTag`.
- **No Phoenix.Channel surface.** `endpoint.ex:16` has `"/live"` (LiveView) only — no custom `UserSocket` / `channel` for external clients; so `phoenix-js` can't be used today.

---

## Options to close the gap

### Option 1 — Webhook-bridge (Phoenix → Next.js webhook route) **[Recommended]**

- **Protocol:** HTTP POST webhook. No persistent connection. Revalidation happens server-side in the Next.js runtime.
- **Backend work** (small):
  - No endpoint changes — webhook system already exists (`api/lib/barkpark_web/controllers/webhook_controller.ex`, `api/lib/barkpark/webhooks/dispatcher.ex`).
  - **Add `syncTags` to the dispatcher payload** (`api/lib/barkpark/webhooks/dispatcher.ex:53-62`) mirroring the listen envelope — one-line enrichment: `sync_tags: ["bp:ds:#{dataset}:doc:#{published_id(doc_id)}", "bp:ds:#{dataset}:type:#{type}"]`. Keeps client tag derivation in one place.
- **Client work** (small):
  - Fix tag prefix in `js/packages/nextjs/src/revalidate/index.ts:50,54,55,58,62` — emit `bp:ds:<ds>:doc:<id>` / `bp:ds:<ds>:type:<type>` (requires dataset on the payload).
  - Teach `revalidateBarkpark` to accept the Phoenix payload shape `{event, type, doc_id, document, dataset, syncTags?}` directly (or export `revalidateFromBarkparkWebhook(payload)` as a thin adapter).
  - Add a scaffolded `app/api/barkpark/webhook/route.ts` to the `create-barkpark-app` template.
  - Auto-set `bp:ds:<ds>:type:<type>` on list fetches inside `barkparkFetchInner` (`js/packages/nextjs/src/server/core.ts:108-124`) so list-page invalidation works. ~3 lines.
  - **Retire or re-purpose `<BarkparkLive/>` for prod.** In prod, preview-mode draft pages use `cache:'no-store'` and don't need SSE; published pages are refreshed via the webhook route. Keep `<BarkparkLive/>` as a dev-time helper (or wire it to *also* hit a server action that performs `revalidateTag`, see Option 3).
- **Complexity:** **small.** ~4 file edits, no new infra, no new transport.
- **Trade-offs:**
  - ✅ No browser token. No CORS. No long-lived process.
  - ✅ Works on serverless Next.js hosts (Vercel, Netlify).
  - ✅ HMAC signed, dedup'd, retried on 5xx — production-grade delivery semantics already exist.
  - ✅ Correct Data-Cache invalidation. Eventual consistency ≈ webhook-delivery latency (~sub-second LAN, <5 s WAN including retries).
  - ❌ Requires a public webhook URL from the site — reachable from Phoenix. Local dev needs `ngrok`/tunnel (acceptable; Sanity has the same constraint with GROQ-powered webhooks).
  - ❌ Per-user preview/draft interactivity still requires `router.refresh()` on the client — the webhook path doesn't help preview because preview fetches are `cache:'no-store'`. Preview mode stays on `<BarkparkLive/>`.

### Option 2 — Server-side SSE bridge inside Next.js (long-lived route)

- **Protocol:** Re-use existing SSE. A Node.js runtime route / custom worker opens `/v1/data/listen/:dataset` with a server-side token and calls `revalidateTag(evt.syncTags)` per event.
- **Backend work** (none): SSE already emits `syncTags` in canonical form.
- **Client work** (medium):
  - New export `@barkpark/nextjs/live-worker` or similar that wraps `client.listen()` + `revalidateTag`, intended to run from a Node process or `runtime = 'nodejs'` route with `maxDuration = 300` equivalent.
  - Lifecycle/restart/healthcheck logic. Reconnect is handled by `createListenHandle` but process restart coordination is the user's problem.
- **Complexity:** **large.** The real cost isn't code — it's the deployment footprint. Serverless Next.js targets (Vercel, Netlify, Cloudflare) don't run long-lived server processes; edge runtimes don't support streaming fetch (`detectEdgeRuntime` throws, `listen.ts:59-65`). You'd need a dedicated Node worker (`railway`, `fly.io`, self-hosted) that shares the Next.js Data Cache — which is per-instance on most hosts. Cache invalidation wouldn't propagate across instances without sticky routing or a shared cache backend.
- **Trade-offs:**
  - ✅ No extra HTTP surface on the Next.js app (no webhook route, no secrets to rotate).
  - ✅ Immediate invalidation — no webhook-delivery latency.
  - ❌ Hostile to serverless. Hostile to edge. Won't work on Vercel without workarounds.
  - ❌ Multi-instance Data Cache fragmentation: revalidation in worker A doesn't invalidate cache held by worker B.
  - ❌ Still requires a server-scoped token, but at least not shipped to the browser.

### Option 3 — Client-side SSE → Server Action revalidate

- **Protocol:** Existing SSE (client-side). Every event POSTs to a Next.js Server Action that performs `revalidateTag()` + `router.refresh()`.
- **Backend work** (none — or small): optionally add a **restricted listen-only token type** (admin issues, ~30 min scope, HMAC-signed) so the browser gets a safe-to-expose credential for the SSE stream.
- **Client work** (small):
  - Inside `startLiveSubscription` (`js/packages/nextjs/src/client/live.tsx:179-250`): after each `evt`, call `'use server'` `revalidateSyncTags(evt.syncTags)` before the debounced `router.refresh()`.
  - Export `revalidateSyncTags` that whitelists tags matching `/^bp:ds:${configuredDataset}:(doc|type):/` — prevents tag-injection from a malicious packet.
- **Complexity:** **small-medium.**
- **Trade-offs:**
  - ✅ Works on serverless. No long-lived process.
  - ✅ Correct cache invalidation.
  - ✅ Fixes preview *and* published without per-environment branching.
  - ❌ **Still requires a browser-exposed token** to open `/v1/data/listen/:dataset`. Without a listen-only token, ships a full-scope token in the bundle — not acceptable for public sites.
  - ❌ Chatty: one server-action roundtrip per event. Debouncing helps. Listen controller doesn't filter on perspective → published sites get round-trips on every draft keystroke.
  - ❌ Server Action endpoint is unauthenticated from the public Internet — rate-limiting + tag-format whitelist required to avoid abuse.

---

## Recommendation

**Ship Option 1 first, then add a `BarkparkLive` tweak (Option 3) for preview mode only.**

Option 1 gets production right for ~4 SDK edits and one trivial backend payload enrichment. It sidesteps the browser-token problem entirely, matches the existing deployment story (serverless-friendly), and exercises the webhook machinery we already built and tested. It also aligns tag formats across listen-event `syncTags`, `defineActions` mutation revalidation, and webhook-triggered revalidation — a single `bp:ds:<ds>:doc:<id>` universe. The gap was never the transport; it was the **post-transport plumbing** (tag prefix, payload shape, auto-typing of list fetches).

Preview mode already uses `cache:'no-store'`, so `<BarkparkLive/>` + `router.refresh()` is sufficient there today. If we want a per-pane-fast Studio preview experience, Option 3 layered on Option 1 would give immediate feedback without shipping a wide-scope token (gated behind an explicit `listen-only` token type — small backend addition).

**Do not** take Option 2. The serverless-hosting impedance mismatch makes it a bad fit for the Next.js ecosystem we're targeting.

---

## Sanity parallel (only where relevant)

- Sanity's `listen=mutation` uses the same `EventSource`-style SSE pattern with `Last-Event-ID` — but Sanity issues **browser-scoped listen-only tokens** as part of the studio-read token grant. That informs the Option 3 add-on: a "listen-only" scope is the precedent. Our current `api_tokens` table has no concept of restricted listen scope.
- Sanity's `next-sanity` `defineLive` bundles both the SSE subscription *and* the server-side `revalidateTag` on syncTags in one helper. Ours is split across `defineLive` (server fetch only), `BarkparkLive` (client SSE only), `revalidateBarkpark` (wrong tag format). Option 1 + the tag-prefix fix makes ours converge on the same mental model.
- Sanity broadcasts per-perspective topics (`listen?visibility=query`), filtering drafts out for published subscribers. Our `listen_controller.ex` ignores the `perspective` query param (`listen_controller.ex:10-41`) — a drive-by fix at the backend (add a `filter_event?/3` that skips draft events when `perspective=published`) is cheap and eliminates spurious refresh traffic on public sites regardless of which option we take.
