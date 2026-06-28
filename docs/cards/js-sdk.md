<!-- doc-tier: agent | canonical-for: js-sdk-consumption | budget: 500tok -->
# JS SDK (js/ monorepo)

Disambiguation first: **`sdk/` at repo root is the Bulldocs ingest SDK — NOT the general JS SDK.** The general SDK is the `js/` monorepo (`@barkpark/*`). Root `packages/client/` is the deprecated predecessor (pin v0.0.83; see its README).

Consumption path:
- `@barkpark/core` — `createClient(config)` returns the typed client (query/doc/mutate, tenancy lists, draft perspectives). Framework-free; works server-side and edge.
- `@barkpark/nextjs` — App Router integration via eight subpath exports (`.`, `./server`, `./client`, `./actions`, `./webhook`, `./draft-mode`, `./revalidate`, `./preload`). **Root-export trap:** `revalidateBarkpark` from the root is a throw-only Phase-3 stub — import from `./revalidate` for the working one.
- `web/` demo uses `@barkpark/core` for all reads. `@barkpark/nextjs` is also installed (`1.0.0-preview.3`) and wired for live updates via `<BarkparkLive/>`, but gated behind `NEXT_PUBLIC_BARKPARK_LIVE=1` plus a listen-capable token — inert unless both are set. Rollback note in web/README.md; Next.js-version warning in web/AGENTS.md.

Living example: `js/packages/create-barkpark-app/templates/blog-starter/` — full consuming app (queries, webhook revalidation, draft mode).

Pointers: envelope decision (Phoenix canonical, SDK adapts) → docs/decisions/0001-sdk-envelope.md · webhook wire contract → docs/contracts/webhook-realtime.md · npm dist-tag publishing → docs/decisions/0002-npm-dist-tag.md · deferrals (groq, nextjs-query 1.1) → docs/decisions/deferred.md · contributor rules (ADR-amendment, no-node-imports, 2% bundle budget) → js/CONTRIBUTING.md.

## Code anchors
- js/packages/core/src/client.ts — createClient
- js/packages/nextjs/src/index.ts — root-export stub (throw-only revalidateBarkpark)
- js/packages/create-barkpark-app/templates/blog-starter/ — living example
- web/lib/barkpark-client.ts — raw @barkpark/core consumption
