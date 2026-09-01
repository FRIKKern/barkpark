<!-- doc-tier: human | canonical-for: website-starter-template | budget: 500tok -->
# {{projectName}}

A Next.js 15 marketing site powered by [Barkpark](https://github.com/barkpark/barkpark) — a headless CMS with a Phoenix API, PostgreSQL backend, and Studio UI.

## What's inside

- Next.js 15 App Router, React 19, TypeScript
- `@barkpark/nextjs` for server fetching + Server Actions
- `@barkpark/react` `PortableDoc` — the canonical, Phoenix-faithful PortableDocument renderer, plus `@barkpark/react/client` media hydration (mermaid diagrams + asciicasts) and `@barkpark/react/paper-surface.css` for the skin
- Tailwind CSS
- `docker-compose.yml` bundling the Phoenix API + PostgreSQL
- Sample schemas (`page`, `post`, `author`, `contact`) + seed script
- SEO out of the box: per-page metadata + OpenGraph, `sitemap.ts`, `robots.ts`, `metadataBase`
- Graceful states: branded `not-found.tsx`, an `error.tsx` boundary, and a `loading.tsx` skeleton

## Quick start

```sh
cp .env.example .env.local
docker compose up -d          # Phoenix API on :4000, Postgres on :5432
{{pmCommand}} install
{{pmCommand}} codegen         # generate TypeScript types (runs barkpark generate; requires @barkpark/codegen in devDependencies)
{{pmCommand}} seed            # 2 authors, 3 pages, 3 posts — all published
{{pmCommand}} dev             # Next.js on :3000
```

Open http://localhost:3000 · Studio: http://localhost:4000/studio

## Auth

Default dev token: `barkpark-dev-token` (read + write + admin). **Must not be used in production — rotate before deploying.** See [docs/auth.md](https://github.com/barkpark/barkpark/blob/main/docs/auth.md) for the rotation rule.

> **Note:** `.env.example` ships with the placeholder value `changeme-barkpark-dev-token`. After `cp .env.example .env.local`, replace that placeholder with `barkpark-dev-token` — the value the API seeds on first boot. Auth calls will fail until you do.

```sh
BARKPARK_TOKEN=barkpark-dev-token
BARKPARK_SERVER_TOKEN=barkpark-dev-token
```

## Contact form

`app/contact/` posts to `POST /v1/data/mutate/:dataset`, which **always requires a
token** — anonymous callers can read a public dataset but can never write to it.
The Server Action therefore attaches `BARKPARK_SERVER_TOKEN` itself
(`app/contact/actions.ts`); it is not on `barkpark.config.ts`, so the credential
stays out of any module a client component could import. With the token unset the
form fails on every submission.

Create the `contact` document type in Studio before pointing the form at a real
project — `schemas/contact.ts` is the shape it writes. Keep it
`visibility: 'private'`: submissions carry a visitor's email address and must not
be readable over the public anonymous read path this site uses for its content.

A failed submission shows the visitor one fixed sentence; the upstream detail goes
to the server log only (`lib/submission-error.ts`), because the raw error can name
your API host, dataset, workspace/project slugs, or schema fields.

## Realtime revalidation

Webhook handler at `app/api/barkpark/webhook/route.ts`. HMAC signing is the combined `t=<unix>,v1=<hex>` header, HMAC-SHA256 over `<timestamp>.<rawBody>`. Tags follow `bp:ds:<dataset>:{_all|doc:<id>|type:<type>}`. See [webhook-realtime.md](https://github.com/barkpark/barkpark/blob/main/docs/contracts/webhook-realtime.md) for the full wire contract.

```sh
BARKPARK_WEBHOOK_SECRET=<shared-secret-with-studio>
```

## Deploy

Set `NEXT_PUBLIC_SITE_URL` to your public origin in the deploy environment — it drives canonical/OpenGraph URLs, `sitemap.xml`, and `robots.txt` (without it they emit `localhost`). Then see the [Barkpark deployment guide](https://github.com/barkpark/barkpark#deploy-to-server).

## License

Apache-2.0
