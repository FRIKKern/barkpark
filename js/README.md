# Barkpark JS Monorepo

TypeScript packages for Barkpark clients and integrations.

## Packages

- `@barkpark/core` — runtime-agnostic HTTP client
- `@barkpark/codegen` — schema introspection + typed-client codegen
- `@barkpark/nextjs` — Next.js App Router integration (ADR-0003 — cache tag scheme)
- `@barkpark/react` — framework-free renderers (PortableText, Image, Reference)
- `@barkpark/groq` — **1.1 roadmap** — reserved npm name
- `@barkpark/nextjs-query` — **1.1 roadmap** — reserved npm name
- `create-barkpark-app` — project scaffolder

## Setup

```bash
cd js && pnpm install
```

## ADRs

See `docs/adr/` and `api/docs/adr/` for architectural decisions driving this layout.
