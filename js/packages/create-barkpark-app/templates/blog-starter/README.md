# {{projectName}}

A Next.js 15 blog starter powered by [Barkpark](https://github.com/barkpark/barkpark) —
a headless CMS with a Phoenix API, PostgreSQL backend, and Studio UI.

## What's inside

- Next.js 15 App Router, React 18, TypeScript
- `@barkpark/nextjs` for server fetching + draft-mode preview
- `@barkpark/react` for `PortableText` rendering of rich-text content
- Tailwind CSS for styling
- `docker-compose.yml` bundling the Phoenix API + PostgreSQL
- Schemas for `post`, `author`, `tag` and a seed script with sample content
- A paginated home feed, author pages, tag archives, and a draft-mode preview
  that uses `useOptimisticDocument` to show live edits

## Quick start

### 1. Start the API + database

```sh
cp .env.example .env.local
docker compose up -d
```

This launches:

- **Phoenix API** on `http://localhost:4000`
- **PostgreSQL 16** on `localhost:5432`

> To run the API from a local checkout of the barkpark repo instead of the
> published image, copy `docker-compose.override.yml.example` to
> `docker-compose.override.yml` and run `docker compose up -d --build`.

### 2. Install dependencies

```sh
{{pmCommand}} install
```

### 3. Seed sample content

```sh
{{pmCommand}} seed
```

Creates 2 authors, 3 tags, and 7 posts (6 published, 1 draft).

### 4. Run the dev server

```sh
{{pmCommand}} dev
```

Open [http://localhost:3000](http://localhost:3000).

## URLs

- **Blog:** http://localhost:3000
- **Studio:** http://localhost:4000/studio (edit content here)

## Schemas

- `post` — title, slug, content (richText), author (reference), tags (array of references), publishedAt, excerpt, coverImage
- `author` — name, slug, bio, avatar
- `tag` — title, slug, description

Edit `schemas/*.ts` and restart the API (`docker compose restart api`) to pick
up changes.

## Draft-mode preview

This starter wires [Next.js draft mode](https://nextjs.org/docs/app/building-your-application/configuring/draft-mode)
to the Barkpark `drafts` perspective so editors can preview unpublished work.

- Enter preview: visit `/api/preview?path=/posts/upcoming-portable-text`
- Exit preview: visit `/api/exit-preview` (or click **Exit preview** in the banner)

While draft mode is enabled, `app/posts/[slug]/page.tsx` renders the
`DraftModePreview` client component, which uses
[`useOptimisticDocument`](https://github.com/barkpark/barkpark/tree/main/js/packages/nextjs)
from `@barkpark/nextjs/actions` to show edits optimistically. The default
commit function in `draft-preview.tsx` is a no-op; replace it with a server
action built on `defineActions().patchDoc` once you want edits to persist.

For production, use `createDraftModeRoutes` from `@barkpark/nextjs/draft-mode`
with a signed preview URL (HMAC + 10-minute TTL).

## Auth

The default development token is `barkpark-dev-token`. It has read + write +
admin scopes and **must not be used in production** — rotate it before
deploying.

```sh
BARKPARK_TOKEN=barkpark-dev-token
BARKPARK_SERVER_TOKEN=barkpark-dev-token
```

## Project layout

```
app/
  layout.tsx                   root layout + nav
  globals.css                  tailwind base
  page.tsx                     paginated home feed (5/page)
  components/Pagination.tsx    page-number nav component
  posts/[slug]/page.tsx        post detail (server component)
  posts/[slug]/draft-preview.tsx  useOptimisticDocument client boundary
  authors/[id]/page.tsx        author profile + their posts
  tags/[slug]/page.tsx         tag archive
  api/preview/route.ts         enable draftMode()
  api/exit-preview/route.ts    disable draftMode()
lib/
  barkpark.ts                  typed server-only fetchers
  queries.ts                   reusable query strings + POSTS_PER_PAGE
schemas/
  post.ts author.ts tag.ts
seeds/
  seed.ts                      POST /v1/data/mutate with Bearer token
barkpark.config.ts             createClient() wiring from env
docker-compose.yml             Phoenix API + Postgres
next.config.mjs tsconfig.json tailwind.config.ts postcss.config.js
```

## Deploy

1. Build and push the `@barkpark/api` image (or use the published one).
2. Set `BARKPARK_API_URL`, `BARKPARK_SERVER_TOKEN`, `BARKPARK_PREVIEW_SECRET`
   in your Next.js deploy environment.
3. Deploy the Next app to Vercel / Fly / your platform of choice.
4. Point `BARKPARK_API_URL` at your self-hosted Phoenix API.

See the [Barkpark deployment guide](https://github.com/barkpark/barkpark#deploy-to-server)
for server setup.

## License

Apache-2.0
