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

See **ADR-003** (cache tag scheme), **ADR-004** (draft-mode branching), **ADR-008** (mutations + defineActions).
