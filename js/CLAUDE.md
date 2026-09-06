<!-- doc-tier: agent | canonical-for: js-monorepo | budget: 600tok -->
# js/ — Barkpark JS monorepo

pnpm + changesets. `cd js && pnpm install && pnpm build`; tests via `pnpm test`. Consumption guide: `docs/cards/js-sdk.md`. NOTE: repo-root `sdk/` is the Bulldocs ingest SDK — a different thing.

## Package map

| Package | What |
|---|---|
| `@barkpark/core` | runtime-agnostic HTTP client (`createClient`) |
| `@barkpark/codegen` | schema → typed-client codegen: `barkpark generate` (+ `--from` drift gate); pairs with core `typedClient<TMap>` |
| `@barkpark/nextjs` | App Router integration — subpaths `client` / `server` / `webhook` / `draft-mode` / `revalidate` / `preload` / `actions` |
| `@barkpark/react` | framework-free renderers (PortableText, Image, Reference); zero `next` imports |
| `@barkpark/groq`, `@barkpark/nextjs-query` | 1.1 roadmap, reserved npm names (`docs/decisions/deferred.md`) |
| `create-barkpark-app` | scaffolder + starters |

## Hard rules

- **CI gate:** `.github/workflows/js-tests.yml` — build → test → lint → typecheck → size on every `js/**` push/PR.
- **No `node:` imports** in `@barkpark/core` or the `@barkpark/nextjs` edge subpaths (`client`, `server`, `webhook`). `webhook` was ported to Web Crypto (#498); only `draft-mode` still VIOLATES this (Phase-5 `node:crypto`, sync `signDraftModeToken`), so the check step is ADVISORY pending the ADR-002 port-or-amend call (`docs/decisions/deferred.md`).
- **Bundle budget:** `pnpm size` — an **absolute byte cap per entry** in that package's `.size-limit.json`; no percentage, no baseline, nothing compared against a previous build. **On a breach: trim first**; the bundle carries no third-party bytes, so foreign fat is not the cause and a trim means deleting your own. A raise is legitimate ONLY when the bytes are PROVEN irremovable and the derivation is RECORDED: cite the measured size and the commits that carried the growth, re-base ALL of a package's entries together (core's ESM rotted to 60 B of headroom while CJS was raised solo in #14267), and set `limit` = measured size rounded up to the next 0.25 KB **+ 0.5 KB fixed headroom** (~4 ordinary commits, measured). The headroom constant is FIXED, so a ceiling can only move as far as the bundle actually moved; the derivation lives in each entry's `name` and is printed by every CI run. Don't grow core to fix an integration.
- **ADR amendment rule:** any change to a locked ADR's Decision section requires a follow-up amendment ADR (`docs/decisions/`).
- **Changesets:** every PR touching `packages/**` MUST carry one, `git add`ed — `changeset status --since` reads git, so untracked still reds. That job (js-tests.yml) is NOT advisory: it FAILS HARD, just outside main's required set. Green only certifies a changeset FILE exists, never that its bump is correct (#9601 shipped a wrong one green).

## Root-export stub trap

`@barkpark/nextjs`'s root export of `revalidateBarkpark` is a throw-only Phase-3 **stub** (`src/index.ts`). The working implementation is the `./revalidate` subpath (`src/revalidate/index.ts`). Never import revalidation from the package root.
