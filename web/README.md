# `web/` — Barkpark Vercel demo

Next.js (App Router) demo deployed to Vercel at the apex `https://barkpark.cloud`. Read-only consumer of the Phoenix API at `https://api.barkpark.cloud`. Renders published posts from the `production` dataset across tenancy-scoped `/w/:workspace/p/:project` routes plus a flat top-level list.

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

This project uses two `@barkpark/*` packages:

| Package | Spec (`web/package.json`) | Used for |
|---------|---------------------------|----------|
| `@barkpark/core` | `file:../js/packages/core` — a local workspace link, not a pinned release | Runtime-agnostic HTTP client (`createClient`). Used directly for reads. |
| `@barkpark/nextjs` | pinned exact `1.0.0-preview.3` | App Router integration — `createBarkparkServer`, `BarkparkLive`, draft-mode routes, webhook handler. **Installed and ready** for later wiring of preview / live updates; not called into yet. |

`lib/barkpark-client.ts` builds the `@barkpark/core` client from `NEXT_PUBLIC_API_URL` with `dataset: "production"`, `perspective: "published"`. It is `import "server-only"` and reads a server-side `BARKPARK_READ_TOKEN` (never `NEXT_PUBLIC_*`) sent as `Authorization: Bearer` so SSR fetches authenticate — required for the scoped `/w/:ws/p/:project` routes (anonymous → 403) and the switcher's tenancy fetches. The `createClient(scope)` factory scopes each request to `/w/<workspace>/p/<project>` when both slugs are passed; the default `client` export uses the flat `/v1/...` back-compat path.

## Routes

The app is tenancy-scoped, not a single flat posts page:

| Route | What |
|-------|------|
| `app/page.tsx` | Top-level (flat-scope) published-posts list |
| `app/w/[workspace]/page.tsx` | Workspace landing |
| `app/w/[workspace]/p/[project]/page.tsx` | Project-scoped posts list (uses `createClient({workspace, project})`) |
| `app/w/[workspace]/p/[project]/posts/[slug]/page.tsx` | Single post by slug |

`components/workspace-project-switcher.tsx` lets the user switch workspace/project. `lib/posts.ts` exposes `fetchPosts`, `fetchPostBySlug`, and `postSlug` over a `PostDocument` type.

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

- `app/page.tsx` — flat-scope Server Component, published-posts list.
- `app/w/[workspace]/...` — tenancy-scoped route tree (workspace landing, project posts list, single post).
- `components/workspace-project-switcher.tsx` — workspace/project switcher.
- `components/posts-list.tsx` — shared posts-list rendering.
- `lib/barkpark-client.ts` — server-only `@barkpark/core` client factory (scoped + flat), reads `BARKPARK_READ_TOKEN`.
- `lib/posts.ts` — `fetchPosts`, `fetchPostBySlug`, `postSlug`, `PostDocument`.
- `.env.example` — copy to `.env.local` for local dev.

## Cross-links

- Apex DNS / Vercel attachment runbook: `/docs/ops/vercel-dns-connect.md`.
- Phoenix CORS plug: `/api/lib/barkpark_web/plugs/dataset_cors.ex`.
- 2026-04-19 PHX_HOST/check_origin outage post-mortem: `/docs/ops/studio-nav-bug-2026-04-19.md`.
