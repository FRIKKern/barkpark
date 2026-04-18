# @barkpark/nextjs

Next.js App Router integration. Six subpath entries: `.`, `./server`, `./client`, `./actions`, `./webhook`, `./draft-mode`.

- `./server` — `createBarkparkServer`, `defineLive` (RSC-only)
- `./client` — `BarkparkLive` (use-client)
- `./actions` — `defineActions`, `useOptimisticDocument`
- `./webhook` — `createWebhookHandler`
- `./draft-mode` — `createDraftModeRoutes`
- root — `revalidateBarkpark` + public type re-exports

See **ADR-003** (cache tag scheme), **ADR-004** (draft-mode branching), **ADR-008** (mutations + defineActions).
