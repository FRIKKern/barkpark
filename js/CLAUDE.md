<!-- doc-tier: agent | canonical-for: js-monorepo | budget: 600tok -->
# js/ — Barkpark JS monorepo

pnpm + changesets. `cd js && pnpm install && pnpm build`; tests via `pnpm test` (projects: `node`, `core-workerd`, `react-browser`). Consumption guide: `docs/cards/js-sdk.md`. NOTE: the repo-root `sdk/` is the Bulldocs ingest SDK — a different thing.

## Package map

| Package | What |
|---|---|
| `@barkpark/core` | runtime-agnostic HTTP client (`createClient`) |
| `@barkpark/codegen` | schema introspection + typed-client codegen (see its README for the not-built boundary) |
| `@barkpark/nextjs` | App Router integration — subpaths `client` / `server` / `webhook` / `draft-mode` / `revalidate` / `preload` |
| `@barkpark/react` | framework-free renderers (PortableText, Image, Reference) — zero `next` imports |
| `@barkpark/groq`, `@barkpark/nextjs-query` | 1.1 roadmap, reserved npm names — `docs/decisions/deferred.md` |
| `create-barkpark-app` | scaffolder + starter templates |

## Hard rules

- **CI gate:** `.github/workflows/js-tests.yml` — build → test → lint → typecheck → size on every `js/**` push/PR (added 2026-06-11; nothing ran the suite before).
- **No `node:` imports** in `@barkpark/core` or the `@barkpark/nextjs` edge subpaths (`client`, `server`). `webhook`/`draft-mode` VIOLATE this (Phase-5 `node:crypto`) — the check step is ADVISORY pending the ADR-002 port-or-amend decision (`docs/decisions/deferred.md`).
- **Bundle budget:** `pnpm size`; the CI gate fails on >2% regression. Don't grow core to fix an integration.
- **ADR amendment rule:** any change to the Decision section of a locked ADR requires a follow-up amendment ADR (`js/docs/adr/`, repo-wide `docs/decisions/`).
- **Changesets:** every PR touching `packages/**` needs `pnpm changeset` — the `changesets` CI job blocks PRs without one.

## Root-export stub trap

`@barkpark/nextjs`'s root export of `revalidateBarkpark` is a throw-only Phase-3 **stub** (`src/index.ts`). The working implementation is the `./revalidate` subpath (`src/revalidate/index.ts`). Never import revalidation from the package root.
