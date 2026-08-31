<!-- doc-tier: human | canonical-for: next-starter-template | budget: 1000tok -->
# Barkpark Next.js starter

The flagship [Barkpark Cloud](https://barkpark.cloud) site-spawner **container**
adapter: a minimal-but-real [Next.js](https://nextjs.org) (App Router) site that
reads its content from a Barkpark dataset **at request time** and runs as a
long-lived **Node SSR process** on the node-slot runtime target. It is the
container analog of `templates/astro-starter` — where Astro emits static HTML,
this emits a running PROCESS with a port + lifecycle.

`@barkpark/core` is framework-free and **is** the content link here — read
directly via this module's `createBpClient`, no Next-native wrapper. (An
earlier version routed reads through `@barkpark/nextjs`'s
`createBarkparkServer`; see the token gotcha below for why that path was
abandoned.) The whole link is one small server-only module,
`src/lib/barkpark.ts`.

## Two runtime targets, one deploy engine

The site-spawner deploy state machine (PLAN → BUILD → STAGE → HEALTH → SWITCH →
RETIRE) drives **two** runtime targets:

| | static-symlink-swap (astro-starter) | **node-slot SSR (this)** |
|---|---|---|
| BUILD output | static `dist/` | `.next/standalone/` (a Node server) |
| artifact | plain HTML files | a running **process** with a PORT |
| HEALTH | curl a static file for markers | curl the **running node process** |
| SWITCH | flip a symlink | flip the **Caddy upstream** to the slot's port |
| markers | baked at BUILD | read from the **boot env** at REQUEST time |
| density | many sites / box | resource-bounded — a process each (cap it) |

## What it does

The single page (`src/app/page.tsx`) is `export const dynamic = 'force-dynamic'`,
so on **every request** the running node slot:

1. resolves the [env contract](#env-contract) (same names as every adapter),
2. builds a fresh `@barkpark/core` client via `createBpClient` — token-authed,
   carrying `BARKPARK_TOKEN` straight in the Authorization header (no
   `createPreloader` — that helper bleeds request state across module scope),
3. fetches one document (newest published `BARKPARK_DOC_TYPE`, default `paper`),
4. renders five deploy markers into `<head>` (React 19 hoists the `<meta>`
   tags) so the deploy engine can assert **content-truth** before flipping the
   Caddy upstream to this slot:

   ```html
   <meta name="bp-build-id"    content="…">  <!-- which build this slot serves (boot env) -->
   <meta name="bp-content-rev" content="…">  <!-- content revision it was cut against (boot env) -->
   <meta name="bp-doc-id"      content="…">  <!-- featured doc id     (content-truth) -->
   <meta name="bp-doc-title"   content="…">  <!-- featured doc title  (content-truth) -->
   <meta name="bp-site-base"   content="…">  <!-- the /sites/<slug>/ path Caddy serves -->
   ```

`force-dynamic` is load-bearing: a static render would bake the **build-time**
`BUILD_ID`, and the HEALTH probe (which curls the running process for the marker)
would read a stale id and fail the switch.

Fail-closed: an unreachable API / auth error **throws** → the page 500s → HEALTH
fails → the broken slot never takes the Caddy upstream (last-good keeps serving).
A **Branch-2 404** (the `BARKPARK_DOC_TYPE` schema is missing or private) is
caught in-page and renders an honest-empty 200 — mirroring `@barkpark/core`
`doc.ts:86`, without patching core.

## Quick start

```sh
npm ci
cp .env.example .env      # fill in BARKPARK_API_URL + BARKPARK_DATASET (+ token)
npm run dev               # http://localhost:3000
```

Production build → run the node-slot server the deploy engine boots:

```sh
npm run build
# → .next/standalone/server.js  (self-contained Node SSR process)
BUILD_ID=v1 CONTENT_REV=rev1 PORT=3001 HOSTNAME=127.0.0.1 \
  BARKPARK_API_URL=https://guerrilla.barkpark.cloud BARKPARK_DATASET=production \
  node .next/standalone/server.js
curl -s http://127.0.0.1:3001/ | grep bp-build-id     # → content="v1"
```

## Env contract

See `.env.example` for the annotated list. Names are **identical** across every
adapter (Astro / Next / Nuxt / …).

| Var                 | Required | Meaning |
|---------------------|:--------:|---------|
| `BARKPARK_API_URL`  | ✓ | Bare origin or scoped base `…/w/:ws/p/:proj` |
| `BARKPARK_DATASET`  | ✓ | Dataset to read (e.g. `production`) |
| `BARKPARK_TOKEN`    |   | Server-only read token; blank = anonymous public read |
| `BARKPARK_WORKSPACE`/`BARKPARK_PROJECT` | | Only used if `BARKPARK_API_URL` is a bare origin |
| `BARKPARK_DOC_TYPE`/`BARKPARK_DOC_ID`   | | Which document to feature (default `paper`) |
| `BARKPARK_SITE_BASE`| | The `/sites/<slug>/` path baked into `bp-site-base` |
| `BUILD_ID`/`CONTENT_REV` | | Node-slot boot markers (the engine injects these) |

### ⚠️ Two token gotchas

- **`NEXT_PUBLIC_` leaks.** Next inlines any `NEXT_PUBLIC_`-prefixed var into the
  client bundle. Never name a token that way. `src/lib/barkpark.ts` reads
  `BARKPARK_TOKEN` only in server code (guarded by `import 'server-only'`).
- **`@barkpark/nextjs` is NOT the content link here — that path caused a real
  incident.** An earlier version read through `@barkpark/nextjs`'s
  `createBarkparkServer`/`barkparkFetch`, which puts the read token in
  `serverToken` — the draft-preview slot — so the *published* content query
  went out ANONYMOUS. On a token-required dataset that answered 403, 500ing
  every SSR request (see Fail-closed, above). `createBpClient` fixes this by
  calling `@barkpark/core`'s `createClient` directly, carrying `BARKPARK_TOKEN`
  in the Authorization header — published reads are authenticated end-to-end,
  and a dataset whose published docs genuinely aren't publicly readable still
  fails closed at HEALTH like any other auth error.

## Serving under a path

The node-slot listens on `127.0.0.1:$PORT` (root) and Caddy reverse-proxies the
per-slug `/sites/<slug>/` prefix to it. The prefix is not baked into the build —
`BARKPARK_SITE_BASE` only feeds the `bp-site-base` marker so the deploy engine can
assert the slot targets the right path.
