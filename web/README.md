<!-- doc-tier: human | canonical-for: web-demo | budget: 300tok -->
# `web/` — Barkpark Vercel demo

Next.js (App Router) demo at https://barkpark.cloud — read-only consumer of the Phoenix API at https://api.barkpark.cloud. Tenancy-scoped routes `/w/:workspace/p/:project` plus a flat published-document finder and graph explorer (the `(finder)` route group) and a `/papers` listing.

Run: `pnpm install && pnpm dev`. Reads `NEXT_PUBLIC_BARKPARK_API_URL` (legacy `NEXT_PUBLIC_API_URL` still honoured as a fallback) — the code falls back to `http://localhost:4000` when unset, but `.env.example` ships the production URL `https://api.barkpark.cloud`, so copy it to `.env.local` and point it at your own server for local dev. The server-only client (`lib/barkpark-client.ts`) reads `BARKPARK_TOKEN` (legacy `BARKPARK_READ_TOKEN`; never `NEXT_PUBLIC_*`) — scoped routes return 403 anonymously. Env names resolve in `lib/bp-env.ts` (canonical first, legacy fallback).

**SDK status:** `@barkpark/core` (local workspace link) handles reads. `@barkpark/nextjs` (`1.0.0-preview.3`) live updates are **wired but gated**: `<LiveBridge/>` (root layout — `components/live-bridge.tsx` — conditionally renders `<BarkparkLive/>` from `@barkpark/nextjs/client`) subscribes via the same-origin SSE proxy `app/v1/data/listen/[dataset]/route.ts` (injects `BARKPARK_TOKEN`, which needs `listen` permission) and triggers `router.refresh()`. Inert until `NEXT_PUBLIC_BARKPARK_LIVE=1` **and** a listen-capable token are set — then the flat surface (`force-dynamic`) auto-refreshes on change. Guide: `docs/cards/js-sdk.md`.

**Rollback** (if the SDK preview breaks before GA — mechanical): `pnpm remove @barkpark/core @barkpark/nextjs`, then write `lib/barkpark.ts` with three ~20-line `fetch` helpers — `query`, `doc`, `mutate` — against `${NEXT_PUBLIC_BARKPARK_API_URL}/v1/data/...`.

**CORS/check_origin gate:** browser-side `fetch` from this app requires `https://barkpark.cloud` (+ the Vercel preview wildcard) in Phoenix `check_origin` AND per-dataset `cors_origins` (`api/lib/barkpark_web/plugs/dataset_cors.ex`). Server-rendered fetches are server-to-server and unaffected. DNS runbook: `docs/ops/vercel-dns-connect.md`.
