<!-- doc-tier: human | canonical-for: blog-starter-template | budget: 800tok -->
# {{projectName}}

A Next.js 15 blog starter powered by [Barkpark](https://github.com/barkpark/barkpark) — a headless CMS with a Phoenix API, PostgreSQL backend, and Studio UI.

## What's inside

- Next.js 15 App Router, React 19, TypeScript
- `@barkpark/nextjs` for server fetching + draft-mode preview
- `@barkpark/react` `PortableDoc` — the canonical, Phoenix-faithful PortableDocument renderer, plus `@barkpark/react/client` media hydration (mermaid diagrams + asciicasts) and `@barkpark/react/paper-surface.css` for the skin
- Tailwind CSS
- `docker-compose.yml` bundling the Phoenix API + PostgreSQL
- Schemas: `post`, `author`, `tag` + seed script with sample content
- Paginated home feed, author pages, tag archives, draft-mode preview with `useOptimisticDocument`
- SEO out of the box: per-page metadata + OpenGraph, `sitemap.ts`, `robots.ts`, `metadataBase`
- Graceful states: branded `not-found.tsx`, an `error.tsx` boundary, and a `loading.tsx` skeleton

## Quick start

```sh
cp .env.example .env.local
docker compose up -d          # Phoenix API on :4000, Postgres on :5432
{{pmCommand}} install
{{pmCommand}} seed            # 2 authors, 3 tags, 7 posts (6 published, 1 draft)
{{pmCommand}} dev             # Next.js on :3000
```

Open http://localhost:3000 · Studio: http://localhost:4000/studio

> To run from a local barkpark checkout instead of the published image, copy `docker-compose.override.yml.example` → `docker-compose.override.yml` and `docker compose up -d --build`.

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

```sh
BARKPARK_WEBHOOK_SECRET=<shared-secret-with-studio>
```

Register the webhook in Studio pointing at `https://<your-app>/api/barkpark/webhook`.

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
  not-found.tsx / error.tsx / loading.tsx   branded 404 / error boundary / skeleton
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
