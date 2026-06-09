<!-- doc-tier: human | canonical-for: web-demo | budget: 300tok -->
# `web/` — Barkpark Vercel demo

Next.js (App Router) demo at https://barkpark.cloud — read-only consumer of the Phoenix API at https://api.barkpark.cloud. Tenancy-scoped routes `/w/:workspace/p/:project` plus a flat published-posts list.

Run: `pnpm install && pnpm dev`. Reads `NEXT_PUBLIC_API_URL` (default `http://localhost:4000`); copy `.env.example` → `.env.local`. The server-only client (`lib/barkpark-client.ts`) reads `BARKPARK_READ_TOKEN` (never `NEXT_PUBLIC_*`) — scoped routes return 403 anonymously.

**SDK status:** `@barkpark/core` (local workspace link) handles reads. `@barkpark/nextjs` (pinned exact `1.0.0-preview.3`) is **installed and ready but not wired yet** — preview/live-update integration comes later. Guide: `docs/cards/js-sdk.md`.

**Rollback** (if the SDK preview breaks before GA — mechanical): `pnpm remove @barkpark/core @barkpark/nextjs`, then write `lib/barkpark.ts` with three ~20-line `fetch` helpers — `query`, `doc`, `mutate` — against `${NEXT_PUBLIC_API_URL}/v1/data/...`.

**CORS/check_origin gate:** browser-side `fetch` from this app requires `https://barkpark.cloud` (+ the Vercel preview wildcard) in Phoenix `check_origin` AND per-dataset `cors_origins` (`api/lib/barkpark_web/plugs/dataset_cors.ex`). Server-rendered fetches are server-to-server and unaffected. DNS runbook: `docs/ops/vercel-dns-connect.md`.
