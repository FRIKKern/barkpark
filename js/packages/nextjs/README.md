<!-- doc-tier: human | canonical-for: nextjs-package | budget: 200tok -->
# @barkpark/nextjs

Next.js App Router integration. Eight subpath entries: `.`, `./server`, `./client`, `./actions`, `./webhook`, `./draft-mode`, `./revalidate`, `./preload`.

- `./server` — `createBarkparkServer`, `defineLive` (RSC-only)
- `./client` — `BarkparkLive` (use-client)
- `./actions` — `defineActions`, `useOptimisticDocument`
- `./webhook` — `createWebhookHandler`
- `./draft-mode` — `createDraftModeRoutes`
- `./revalidate` — the working `revalidateBarkpark` (`src/revalidate/index.ts`)
- `./preload` — preload helpers
- root — `revalidateBarkpark` is a throw-only Phase-3 **stub** (`src/index.ts`); use `./revalidate` for the working implementation. Also re-exports public types.

See **ADR-0003** (cache tag scheme — `docs/decisions/0003-sync-tags.md`). Redirect stub at the old path `api/docs/adr/ADR-0003-canonical-sync-tag-convention.md`.
