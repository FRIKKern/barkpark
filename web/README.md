# `web/` — Barkpark Vercel demo

Next.js (App Router) demo deployed to Vercel at the apex `https://barkpark.cloud`. Read-only consumer of the Phoenix API at `https://api.barkpark.cloud`. Lists published posts from the `production` dataset.

This replaces the prior `apps/demo/` Next.js project (retired in the same PR — see Task #27 plan §Phase 1).

## Run locally

```bash
cd web
pnpm install
pnpm dev
```

The page reads from `process.env.NEXT_PUBLIC_API_URL`. Defaults to `http://localhost:4000` if unset (matches a local `mix phx.server`).

```bash
# Hit the live API instead of local Phoenix
NEXT_PUBLIC_API_URL=https://api.barkpark.cloud pnpm dev
```

Open [http://localhost:3000](http://localhost:3000) — the index page lists published posts.

Copy `.env.example` → `.env.local` to pin local values; `.env.local` is gitignored (only `.env.example` is committed, see `.gitignore`).

## SDK

This project uses two pinned `@barkpark/*` packages — both at exact `1.0.0-preview.2` (no caret, no tilde) so the demo is locked off a moving preview API surface:

| Package | Used for |
|---------|----------|
| `@barkpark/core` | Runtime-agnostic HTTP client (`createClient`, `client.docs(type).find()`). Phase 1 demo uses this directly for public reads of `perspective=published`. |
| `@barkpark/nextjs` | App Router integration — `createBarkparkServer`, `BarkparkLive`, draft-mode routes, webhook handler. **Installed and ready** for Phase 5+ wiring of preview / live updates. The Phase 1 demo does NOT call into it yet. |

`lib/barkpark-client.ts` constructs the shared `@barkpark/core` client from `NEXT_PUBLIC_API_URL`, `dataset: "production"`, `perspective: "published"`.

### Why the shim exists

`lib/barkpark-shim.ts` wraps `createClient` with a custom `fetch` that unwraps Phoenix's `{result: …}` envelope before the SDK parses it. Background:

- `@barkpark/nextjs@1.0.0-preview.2` and `@barkpark/core@1.0.0-preview.2` expect read responses to be flat — e.g. `client.docs("post").find()` reads `data.documents` directly.
- Phoenix `/v1/data/query/{dataset}/{type}` returns `{"result":{"count":N,"documents":[…]}}` (the canonical envelope shared by `getDoc`, mutate, etc.).
- Without the shim, `data.documents ?? []` returns `[]` and the demo page renders an empty list even though the API is healthy.

The shim is intentionally minimal (~50 lines) and lives only in `web/`. Removal path:

1. Upstream SDK fix lands as `@barkpark/nextjs@1.0.0-preview.3` / `@barkpark/core@1.0.0-preview.3` — tracked in **Doey Task #32** (upstream SDK PR).
2. Bump both pinned versions in `package.json`.
3. Delete `web/lib/barkpark-shim.ts` and switch `app/page.tsx` (and any future consumers) back to `@/lib/barkpark-client`.

Cross-link: see plan masterplan `masterplan-20260417-212541` for the broader Phoenix-vs-SDK envelope reconciliation context.

### Rolling back to a vendored thin client

If the SDK preview ships a breaking change before this app reaches GA, the rollback is mechanical:

```bash
cd web
pnpm remove @barkpark/core @barkpark/nextjs
# Then write web/lib/barkpark.ts with three functions:
#   query(dataset, type, opts?), doc(dataset, type, id), mutate(dataset, mutations[])
# Each is ~20 lines of `fetch` against `${NEXT_PUBLIC_API_URL}/v1/data/...`.
```

The plan default for Task #27 was a vendored thin client; we chose the published SDK because it was on npm with `latest` and `preview` dist-tags both pinned to `1.0.0-preview.2`.

## Deploying to Vercel

The Vercel project (`guerrilla/demo`) builds from this directory — see root `vercel.json` and Phase 3 of the Task #27 plan. Production env var: `NEXT_PUBLIC_API_URL=https://api.barkpark.cloud`.

Phase 2 of Task #27 must add `https://barkpark.cloud` (and the Vercel preview wildcard) to Phoenix's `check_origin` and per-dataset `cors_origins` allowlists before browser-side `fetch` from this app will work without CORS errors. Server-rendered pages (this demo today) talk to the API server-to-server and are not affected by `check_origin`, but client-side hooks added later will be.

## Files

- `app/page.tsx` — Server Component, fetches published posts and renders `title + slug` list.
- `lib/barkpark-client.ts` — `@barkpark/core` client bound to `production` / `published` from `NEXT_PUBLIC_API_URL`.
- `lib/barkpark-shim.ts` — Phoenix-envelope-aware client (unwraps `{result: …}`). Used by `app/page.tsx`. Remove when Task #32 lands.
- `.env.example` — copy to `.env.local` for local dev.

## Cross-links

- Plan: `/.doey/plans/1.md` (5-phase bringup).
- Phase 0 discovery + DNS state: `/docs/ops/web-vercel-bringup-discovery.md`.
- Apex DNS / Vercel attachment runbook: `/docs/ops/vercel-dns-connect.md`.
- Phoenix CORS plug: `/api/lib/barkpark_web/plugs/dataset_cors.ex` (touched in Phase 2, NOT this PR).
- 2026-04-19 PHX_HOST/check_origin outage post-mortem: `/docs/ops/studio-nav-bug-2026-04-19.md`.
