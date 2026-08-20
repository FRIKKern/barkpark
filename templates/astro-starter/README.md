<!-- doc-tier: human | canonical-for: astro-starter-template | budget: 900tok -->
# Barkpark Astro starter

The flagship [Barkpark Cloud](https://barkpark.cloud) site-spawner adapter: a
minimal-but-real [Astro](https://astro.build) site that reads its content from a
Barkpark dataset **at build time** and produces plain static HTML. It is built
and served right next to Phoenix, over the internal content link, riding the
same Caddy + blue/green + webhook machinery — the deploy engine
(`site-spawner-w1-deploy-engine`) health-gates the output before it goes live.

`@barkpark/core` is framework-free, so there is no `@barkpark/astro` package —
the whole content link is one small module, `src/lib/barkpark.ts`.

## What it does

At build time it:

1. resolves the [env contract](#env-contract) (same names across every adapter),
2. builds a **fresh** `@barkpark/core` client (not memoized; no `createPreloader`
   — that helper is Next.js-only and bleeds request state across module scope),
3. fetches one document (newest published `BARKPARK_DOC_TYPE`, default `post`),
4. bakes five `<meta>` deploy markers into `dist/index.html` so the deploy engine
   can assert **content-truth** before switching traffic:

   ```html
   <meta name="bp-build-id"    content="…">   <!-- which build -->
   <meta name="bp-content-rev" content="…">   <!-- content revision it was cut against -->
   <meta name="bp-doc-id"      content="…">   <!-- featured doc id  -->
   <meta name="bp-doc-title"   content="…">   <!-- featured doc title -->
   <meta name="bp-site-base"   content="…">   <!-- the Astro `base` it was built under -->
   ```

A broken content link (unreachable API, bad token) **fails the build** — it never
reaches visitors. A reachable-but-empty dataset renders an honest empty state and
still builds.

## Quick start

```sh
npm ci
cp .env.example .env      # fill in BARKPARK_API_URL + BARKPARK_DATASET (+ token)
npm run build             # → dist/
npm run preview           # serve dist/ locally
```

Or one-shot, without a `.env` file:

```sh
BARKPARK_API_URL=https://guerrilla.barkpark.cloud/w/acme/p/default \
BARKPARK_TOKEN=<public-read token> \
BARKPARK_DATASET=production \
  npm run build
```

## Env contract

See `.env.example` for the annotated list. The essentials:

| Var                 | Required | Meaning |
|---------------------|:--------:|---------|
| `BARKPARK_API_URL`  | ✓ | Scoped base `…/w/:ws/p/:proj` (workspace+project already in the URL) |
| `BARKPARK_DATASET`  | ✓ | Dataset to read (e.g. `production`) |
| `BARKPARK_TOKEN`    |   | Server-only read token; blank = anonymous public read |
| `BARKPARK_WORKSPACE`/`BARKPARK_PROJECT` | | Only used if `BARKPARK_API_URL` is a bare origin (not already scoped) |
| `BARKPARK_DOC_TYPE`/`BARKPARK_DOC_ID`   | | Which document to feature |
| `BARKPARK_SITE_BASE`| | Astro `base` — the `/sites/<slug>/` path this site serves under |
| `BARKPARK_BUILD_ID`/`BARKPARK_CONTENT_REV` | | Deploy markers (the engine injects these) |

### ⚠️ Ambient-env shadow gotcha (live-proven)

Vite gives `process.env` **precedence** over `.env`. On a dev box where `bp` is
configured, an exported `BARKPARK_TOKEN` / `BARKPARK_API_URL` in your shell will
**silently shadow** what you put in `.env` — you'll build against the wrong
workspace. The deploy engine scrubs the environment per build; when building by
hand, `unset` the ambient `BARKPARK_*` vars (or pass them inline via `env -u`).

## Serving under a path

`astro.config.mjs` sets `base` from `BARKPARK_SITE_BASE` (default
`/sites/astro-starter/`). The spawner serves every site at a PATH under the
content FQDN, so asset URLs must carry that prefix — the deploy engine sets the
per-slug value at build.
