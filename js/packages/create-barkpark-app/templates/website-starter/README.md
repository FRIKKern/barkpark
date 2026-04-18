# {{projectName}}

A Next.js 15 marketing site powered by [Barkpark](https://github.com/barkpark/barkpark) —
a headless CMS with a Phoenix API, PostgreSQL backend, and Studio UI.

## What's inside

- Next.js 15 App Router, React 18, TypeScript
- `@barkpark/nextjs` for server fetching + Server Actions
- `@barkpark/react` for `PortableText` rendering
- Tailwind CSS for styling
- `docker-compose.yml` bundling the Phoenix API + PostgreSQL
- Sample schemas (`page`, `post`, `author`) + a seed script

## Getting started

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

### 3. Generate types

```sh
{{pmCommand}} codegen
```

This runs the Barkpark CLI to generate TypeScript types from your schemas.

### 4. Seed sample content

```sh
{{pmCommand}} seed
```

Creates 2 authors, 3 pages (home / about / pricing), and 3 posts — all published.

### 5. Run the dev server

```sh
{{pmCommand}} dev
```

Open [http://localhost:3000](http://localhost:3000).

## Auth

The default development token is `barkpark-dev-token`. It has read + write + admin
scopes and **must not be used in production** — rotate it before deploying.

Set it via:

```sh
BARKPARK_TOKEN=barkpark-dev-token
BARKPARK_SERVER_TOKEN=barkpark-dev-token
```

## Project layout

```
app/
  layout.tsx              root layout with top nav + HostedDemoBanner
  page.tsx                home: hero + posts list
  about/page.tsx          fetches page document "about"
  pricing/page.tsx        fetches page document "pricing"
  posts/[slug]/page.tsx   post detail with PortableText rendering
  contact/page.tsx        contact form using Server Actions
  contact/actions.ts      server action wrapping defineActions().createDoc
  hosted-demo-banner.tsx  banner shown only on barkpark.dev hosted demo
lib/
  barkpark.ts             typed fetch helpers around /v1/data/query + /v1/data/doc
schemas/
  page.ts post.ts author.ts
seeds/
  seed.ts                 POST /v1/data/mutate/production with Bearer token
barkpark.config.ts        createClient() wiring from env
docker-compose.yml        Phoenix API + Postgres
next.config.mjs tsconfig.json tailwind.config.ts postcss.config.js
```

## Studio

Content editing happens in the Barkpark Studio that ships with the API:

- http://localhost:4000/studio

## Deploy

See the [Barkpark deployment guide](https://github.com/barkpark/barkpark#deploy-to-server).

## License

Apache-2.0
