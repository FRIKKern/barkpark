# @barkpark/demo

Read-only Vercel-hosted demo of the Barkpark headless CMS. Published documents
are rendered through server-side fetches — the browser never talks to the
Barkpark API directly.

## What this is

- Next.js 15 App Router, React 19 server components.
- Three pages: schema index (`/`), type list (`/[type]`), document detail
  (`/[type]/[id]`).
- Three route handlers under `/api/barkpark/*` that proxy to the Barkpark API
  from the server — so the browser only ever talks to the Vercel origin.

## Local dev

```bash
cd apps/demo
cp .env.example .env.local           # fill in real values
pnpm install
pnpm dev
```

Open http://localhost:3000.

## Vercel deploy

1. Import the GitHub repo in Vercel.
2. **Root Directory:** `apps/demo`.
3. **Framework Preset:** Next.js (auto-detected).
4. Add env vars (Production + Preview):
   - `BARKPARK_API_URL` — e.g. `http://89.167.28.206`
   - `BARKPARK_PUBLIC_READ_TOKEN` — rotated weekly
5. Region pinned to `fra1` via `vercel.json` (closest to the Hetzner EU VPS).
6. Create a **Deploy Hook** under Settings → Git — the VPS rotation timer
   posts to it weekly to redeploy with the fresh token.

## Mixed-content caveat

Vercel serves this app over HTTPS. The Barkpark API currently runs at plain
HTTP. A browser will **refuse** to fetch an HTTP resource from an HTTPS page
(mixed-content block), so every API call goes through a Next.js route handler
that runs on the Vercel server:

- `app/api/barkpark/schemas/route.ts` → static fallback list
- `app/api/barkpark/query/[type]/route.ts` → `${BARKPARK_API_URL}/v1/data/query/...`
- `app/api/barkpark/doc/[type]/[id]/route.ts` → `${BARKPARK_API_URL}/v1/data/doc/...`

**Do not** add any client-side `fetch` call that targets `BARKPARK_API_URL` —
the browser will block it. All pages are `export const dynamic = "force-dynamic"`
so the build succeeds without env vars; fetches happen at request time.

This limitation disappears once a domain + TLS lands for the API — see
`docs-site/ops/adding-a-domain.md`.

## Token rotation

`BARKPARK_PUBLIC_READ_TOKEN` rotates weekly (Mon 03:00 UTC) via a systemd
timer on the VPS:

1. The timer fires `barkpark-rotate-token.service`.
2. The service runs the `Barkpark.RotatePublicRead` mix task, which generates
   a new `public-read` token, inserts it into `api_tokens`, and revokes
   tokens older than 8 days (24 h grace window).
3. The task writes the new token to `/opt/barkpark/public-read.token` and
   POSTs `VERCEL_DEPLOY_HOOK` — Vercel then redeploys this app with the
   rotated value.

Operator setup (one-off):

1. In Vercel: Settings → Environment Variables → add
   `BARKPARK_PUBLIC_READ_TOKEN` (Production).
2. Settings → Git → create a Deploy Hook; copy the URL.
3. On the VPS: add `VERCEL_DEPLOY_HOOK=<url>` to `/opt/barkpark/.env`.
4. Install the systemd units shipped in `deploy/systemd/` and enable the
   timer.

See `.doey/plans/research/w4-phase7-hosted-demo.md` §3 for the full design.

## File layout

```
apps/demo/
├── app/
│   ├── layout.tsx                                # shell, inline styles
│   ├── page.tsx                                  # schema index
│   ├── [type]/page.tsx                           # list published docs
│   ├── [type]/[id]/page.tsx                      # single doc detail
│   └── api/barkpark/
│       ├── schemas/route.ts                      # fallback schema list
│       ├── query/[type]/route.ts                 # proxy → /v1/data/query/...
│       └── doc/[type]/[id]/route.ts              # proxy → /v1/data/doc/...
├── lib/
│   ├── barkpark.ts                               # server fetch helper + types
│   └── public-schemas.ts                         # PUBLIC_SCHEMAS fallback
├── .env.example
├── next.config.mjs
├── package.json
├── tsconfig.json
└── vercel.json
```
