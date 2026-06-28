<!-- doc-tier: human | canonical-for: js-monorepo-overview | budget: 250tok -->
# Barkpark JS Monorepo

TypeScript packages for Barkpark clients and integrations.

## Packages

| Package | Status | Purpose |
|---|---|---|
| `@barkpark/core` | preview | Runtime-agnostic HTTP client |
| `@barkpark/codegen` | preview | Schema introspection + typed-client codegen |
| `@barkpark/nextjs` | preview | Next.js App Router integration (ADR-0003 cache tag scheme) |
| `@barkpark/react` | preview | Framework-free renderers (PortableText, Image, Reference) |
| `@barkpark/groq` | 1.1 roadmap — npm name reserved | See `docs/decisions/deferred.md` |
| `@barkpark/nextjs-query` | 1.1 roadmap — npm name reserved | See `docs/decisions/deferred.md` |
| `create-barkpark-app` | preview | Project scaffolder |

## Setup

```bash
cd js && pnpm install && pnpm build
```

## ADRs

See `docs/adr/` and `api/docs/adr/` for architectural decisions driving this layout. Consolidated decisions at `docs/decisions/`.
