# Barkpark JS Monorepo

TypeScript packages for Barkpark clients and integrations.

## Packages

- `@barkpark/core` — runtime-agnostic HTTP client (ADR-002, ADR-009)
- `@barkpark/codegen` — schema introspection + typed-client codegen (ADR-006)
- `@barkpark/nextjs` — Next.js App Router integration (ADR-003, ADR-004, ADR-008)
- `@barkpark/react` — framework-free renderers (PortableText, Image, Reference)
- `@barkpark/groq` — **1.1 roadmap** — reserved npm name (ADR-000)
- `@barkpark/nextjs-query` — **1.1 roadmap** — reserved npm name (ADR-012)

## Setup

```bash
cd js && pnpm install
```

## ADRs

See `.doey/plans/adrs/` for architectural decisions driving this layout.
