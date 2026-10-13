<!-- doc-tier: human | canonical-for: blog-starter-template | budget: 800tok -->
# {{projectName}}

A Next.js 15 blog starter powered by [Barkpark](https://github.com/barkpark/barkpark) — a headless CMS with a Phoenix API, PostgreSQL backend, and Studio UI.

## What's inside

- Next.js 15 App Router, React 19, TypeScript
- `@barkpark/nextjs` for server fetching + draft-mode preview
- `@barkpark/react` `PortableDoc` — the canonical, Phoenix-faithful PortableDocument renderer, plus `@barkpark/react/client` media hydration (mermaid diagrams + asciicasts) and `@barkpark/react/paper-surface.css` for the skin
- Tailwind CSS
- `docker-compose.yml` running the published API image + PostgreSQL (optional; see Quick start)
- Schemas: `post`, `author`, `tag` + seed script with sample content
- Paginated home feed, author pages, tag archives, draft-mode preview with `useOptimisticDocument`
- SEO out of the box: per-page metadata + OpenGraph, `sitemap.ts`, `robots.ts`, `metadataBase`
- Graceful states: a branded `not-found.tsx` served with a real 404 status, and an `error.tsx` boundary

## Quick start

```sh
# 1. A Barkpark API on :4000 — skip if you already run one
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup --target local --yes # clones Barkpark and runs it on :4000; names any missing prerequisite

# 2. This app
cp .env.example .env.local
npm install                   # or: pnpm install · yarn · bun install
{{pmCommand}} seed            # 2 authors, 3 tags, 7 posts (6 published, 1 draft)
{{pmCommand}} dev             # Next.js on :3000
```

Open http://localhost:3000 · Studio: http://localhost:4000/studio

> **Docker instead of `bp setup`:** `docker-compose.yml` runs the published image `ghcr.io/barkpark/api:latest` beside Postgres. Create a `.env` beside it with `BARKPARK_CLOAK_KEY` and `BARKPARK_KEK` (each `openssl rand -base64 32`), `PREVIEW_JWT_SECRET` and `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` (each `openssl rand -base64 48`), then `docker compose up -d`. If the image cannot be pulled, build it from a Barkpark checkout: copy `docker-compose.override.yml.example` → `docker-compose.override.yml` and run `docker compose up -d --build`. Full setup guide: [QUICKSTART](https://github.com/FRIKKern/barkpark/blob/main/docs/setup/QUICKSTART.md).

## Auth

Default dev token: `barkpark-dev-token` (read + write + admin). **Must not be used in production — rotate before deploying.** See `docs/auth.md` for the rotation rule. This is enforced: if `BARKPARK_SERVER_TOKEN` is unset with `NODE_ENV=production`, `lib/barkpark.ts` throws at startup instead of silently falling back to the dev token.

> **Note:** `.env.example` ships with the placeholder value `changeme-barkpark-dev-token`. After `cp .env.example .env.local`, replace that placeholder with `barkpark-dev-token` — the value the API seeds on first boot. Auth calls will fail until you do.

```sh
BARKPARK_TOKEN=barkpark-dev-token
BARKPARK_SERVER_TOKEN=barkpark-dev-token
```

## Draft-mode preview

Enter: `/api/preview?path=/posts/upcoming-portable-text` · Exit: `/api/exit-preview`

While active, `app/posts/[slug]/page.tsx` renders `DraftModePreview`, which uses `useOptimisticDocument` from `@barkpark/nextjs/actions`. For production, use `createDraftModeRoutes` from `@barkpark/nextjs/draft-mode` with a signed preview URL (HMAC + 10-minute TTL).

## Realtime revalidation

Webhook handler at `app/api/barkpark/webhook/route.ts`. HMAC signing is the combined `t=<unix>,v1=<hex>` header, HMAC-SHA256 over `<timestamp>.<rawBody>`. Tags follow `bp:ws:<workspace>:p:<project>:ds:<dataset>:{_all|doc:<id>|type:<type>}` when workspace and project are set (the default); the legacy flat shape `bp:ds:<dataset>:{_all|doc:<id>|type:<type>}` is used as back-compat fallback when they are not. See `docs/contracts/webhook-realtime.md` for the full wire contract.

Register the webhook with the `bp` CLI (Studio has no webhook screen), then mint its signing secret:

```sh
bp webhook create https://<your-app>/api/barkpark/webhook my-site   # prints: id: <webhook-id>
bp webhook rotate <webhook-id> -o json                             # {"secret":"whsec_…", …} — shown once
```

Set that secret in the app's environment:

```sh
BARKPARK_WEBHOOK_SECRET=whsec_…
```

A webhook with no secret sends unsigned deliveries, and this route answers every one of them 401.

## Deploy

1. Build/push the `@barkpark/api` image or use the published one.
2. Set `BARKPARK_API_URL`, `BARKPARK_SERVER_TOKEN`, `BARKPARK_PREVIEW_SECRET`, and `NEXT_PUBLIC_SITE_URL` (your public origin — drives canonical/OpenGraph URLs, `sitemap.xml`, and `robots.txt`; without it they emit `localhost`) in your deploy environment.
3. Deploy the Next app to Vercel / Fly / your platform.

## Project layout

```
app/
  posts/[slug]/page.tsx        post detail (server component)
  posts/[slug]/draft-preview.tsx  useOptimisticDocument client boundary
  authors/[id]/page.tsx        author profile
  tags/[slug]/page.tsx         tag archive
  api/preview/route.ts         enable draftMode()
  api/exit-preview/route.ts    disable draftMode()
  sitemap.ts / robots.ts       SEO discovery (absolute URLs from NEXT_PUBLIC_SITE_URL)
  not-found.tsx / error.tsx    branded 404 / error boundary
lib/
  barkpark.ts                  typed server-only fetchers
  queries.ts                   reusable query strings
schemas/
  post.ts author.ts tag.ts
seeds/seed.ts
barkpark.config.ts             createClient() wiring from env
```

## License

Apache-2.0
