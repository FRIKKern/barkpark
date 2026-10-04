<!-- doc-tier: agent | canonical-for: js-sdk-consumption | budget: 500tok -->
# JS SDK (js/ monorepo)

Disambiguation: **`sdk/` at repo root is the Bulldocs ingest SDK, NOT the JS SDK** — that is the `js/` monorepo (`@barkpark/*`).

Consumption path:
- `@barkpark/core` — `createClient(config)` → typed client: query builder (filter ops, ordering, `expand`, projection, paging), `search()`, reads (`doc`/`getDocuments`, backlinks, history, graph), mutations (`create`/`patch`/`publish`/`unpublish`/`delete`/`discardDraft` + patch ops, `transaction`), media (`uploadAsset`/`imageUrl`, asset CRUD, collections, `searchAssets`), schema CRUD, webhook mgmt (CRUD + `verifyWebhookSignature`), `listen()`, tenancy, draft perspectives. Framework-free; server + edge. `resolve: 'tasks'` fills task blocks → js/packages/core/README.md.
- `@barkpark/nextjs` — App Router integration via subpath exports (`.`, `./server`, `./client`, `./actions`, `./webhook`, `./draft-mode`, `./revalidate`, `./preload`, `./csp`). **Root-export trap:** `revalidateBarkpark` from the root is a throw-only Phase-3 stub — import `./revalidate`.
- `web/` demo: reads via `@barkpark/core`; `@barkpark/nextjs` live updates stay inert unless `NEXT_PUBLIC_BARKPARK_LIVE=1` AND a listen-capable token are set. Versions, rollback, CORS → web/README.md.

Living example: `js/packages/create-barkpark-app/templates/blog-starter/` (queries, webhook revalidation, draft mode).

Stored shapes (rulings #42–44, #46): reference `{_ref}`, slug `{current}`, rich text Portable Text blocks, datetime UTC instant. Read older Studio values too (bare id, string, HTML, no zone): starters' `refOf`/`slugOf`.

Pointers: envelope decision (Phoenix canonical, SDK adapts) → docs/decisions/0001-sdk-envelope.md · webhook wire contract → docs/contracts/webhook-realtime.md · npm dist-tag publishing → docs/decisions/0002-npm-dist-tag.md · deferrals (groq, nextjs-query 1.1) → docs/decisions/deferred.md · contributor rules (ADR amendments, no `node:` imports, `.size-limit.json` caps: trim, never raise) → js/CONTRIBUTING.md.

## Code anchors
- js/packages/core/src/client.ts — createClient
- js/packages/nextjs/src/index.ts — root-export stub (throw-only revalidateBarkpark)
- js/packages/create-barkpark-app/templates/blog-starter/ — living example
- web/lib/barkpark-client.ts — raw @barkpark/core consumption
