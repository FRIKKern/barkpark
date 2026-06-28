<!-- doc-tier: human | canonical-for: website-starter-template | budget: 500tok -->
# {{projectName}}

A Next.js 15 marketing site powered by [Barkpark](https://github.com/barkpark/barkpark) — a headless CMS with a Phoenix API, PostgreSQL backend, and Studio UI.

## What's inside

- Next.js 15 App Router, React 19, TypeScript
- `@barkpark/nextjs` for server fetching + Server Actions
- `@barkpark/react` for `PortableText` rendering
- Tailwind CSS
- `docker-compose.yml` bundling the Phoenix API + PostgreSQL
- Sample schemas (`page`, `post`, `author`) + seed script

## Quick start

```sh
cp .env.example .env.local
docker compose up -d          # Phoenix API on :4000, Postgres on :5432
{{pmCommand}} install
{{pmCommand}} codegen         # generate TypeScript types from schemas
{{pmCommand}} seed            # 2 authors, 3 pages, 3 posts — all published
{{pmCommand}} dev             # Next.js on :3000
```

Open http://localhost:3000 · Studio: http://localhost:4000/studio

## Auth

Default dev token: `barkpark-dev-token` (read + write + admin). **Must not be used in production — rotate before deploying.** See `docs/auth.md` for the rotation rule.

```sh
BARKPARK_TOKEN=barkpark-dev-token
BARKPARK_SERVER_TOKEN=barkpark-dev-token
```

## Realtime revalidation

Webhook handler at `app/api/barkpark/webhook/route.ts`. HMAC signing is the combined `t=<unix>,v1=<hex>` header, HMAC-SHA256 over `<timestamp>.<rawBody>`. Tags follow `bp:ds:<dataset>:{_all|doc:<id>|type:<type>}`. See `docs/contracts/webhook-realtime.md` for the full wire contract.

```sh
BARKPARK_WEBHOOK_SECRET=<shared-secret-with-studio>
```

## Deploy

See the [Barkpark deployment guide](https://github.com/barkpark/barkpark#deploy-to-server).

## License

Apache-2.0
