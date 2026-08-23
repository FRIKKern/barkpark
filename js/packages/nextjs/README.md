<!-- doc-tier: human | canonical-for: nextjs-package | budget: 200tok -->
# @barkpark/nextjs

Next.js App Router integration. Nine subpath entries: `.`, `./server`, `./client`, `./actions`, `./webhook`, `./draft-mode`, `./revalidate`, `./preload`, `./csp`.

- `./server` — `createBarkparkServer`, `defineLive`, `barkparkFetch` (RSC-only)
- `./client` — `BarkparkLive`, `BarkparkLiveProvider`, `startLiveSubscription` (use-client)
- `./actions` — `defineActions`, `useOptimisticDocument`
- `./webhook` — `createWebhookHandler`
- `./draft-mode` — `createDraftModeRoutes`
- `./revalidate` — the working `revalidateBarkpark` (`src/revalidate/index.ts`)
- `./preload` — preload helpers
- `./csp` — `createCspMiddleware`, `buildCspPolicy`, `generateNonce`, `cspMatcher`: the per-request-nonce CSP. Serves Next 15 `middleware.ts` AND Next 16 `proxy.ts` (only the exported name differs). Widen `img-src`/`connect-src` via `additional`; `script-src` refuses `'unsafe-inline'`.
- root — `revalidateBarkpark` is a throw-only Phase-3 **stub** (`src/index.ts`); use `./revalidate` for the working implementation. Also re-exports public types.

See **ADR-0003** (cache tag scheme — `docs/decisions/0003-sync-tags.md`). Redirect stub at the old path `api/docs/adr/ADR-0003-canonical-sync-tag-convention.md`.
