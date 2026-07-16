<!-- doc-tier: human | canonical-for: search-starter-template | budget: 1600tok -->
# Barkpark search-starter

**A search engine you'd pay for — live in ~90 seconds, from one command.**

Pick this template and you get a running site that feels expensive:

- **Instant, as-you-type live search** over a Phoenix websocket — every
  keystroke flips one frame on a warm socket, no request round-trip.
- **A zero-dependency Canvas2D force graph** — a hand-written physics engine
  (`bp-graph.js`, no D3, no network) that breathes between densely interlinked
  documents. On first load the corpus is a constellation.
- **A Leaflet-free OpenStreetMap map** — raw OSM tiles, no map library.
- **PortableDoc detail pages** — every document renders pixel-perfect through
  the canonical `@barkpark/react` `PortableDoc` (all block types), never a fork.
- **Four themes** — evergreen / ember / fjord / charple (theme matrix lands in a
  later wave; the graph re-skins live on `bp:themechange`).

This is the flagship proof of the claim: *Barkpark is the fastest way to
something genuinely premium, without worries.* It is a standalone Next.js
(App Router) app — the web demo's finder, graph, map and `lib` modules
extracted into their own tree with their own `package.json` — deployed as a
long-lived **Node SSR process** through Barkpark Cloud's proven six-stage
deploy engine.

## One command to a live URL

Install the CLI (this works **today** — `install-cli.sh` installs `bp` 1.15.0,
fix #2797; the old 404 is gone), then log in device-style and ship:

```sh
# 1. install bp (macOS / Linux)
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
#    Windows (PowerShell):
#    irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex

# 2. log in — device flow, no password paste
bp login --device

# 3. spawn the site from this template, bound to your Barkpark instance
bp cloud site create --template search-starter --barkpark <id> --kind node

# 4. deploy it — streams the six stages, prints the live URL
bp cloud site deploy <slug>
```

> **Template selection is landing across this epic.** The deploy engine already
> materializes `search-starter` (the `template` axis ships in Wave 1); the
> `--template` flag on `bp cloud site create` and the dashboard picker are the
> epic's next surface (Wave 2). Until then, bind the site with `--instance <id>`
> (`bp cloud site create --name <name> --dataset <ws/proj/ds> --instance <id>
> --kind node --framework nextjs`) and select the template on deploy.

`create` registers the site (node runtime target) against your instance;
`deploy` enqueues the build and **streams the six visible stages live**:

```
PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE
```

`HEALTH` curls the running node process for content-truth `<meta>` markers
before `SWITCH` flips the Caddy upstream — a broken build never takes traffic.
The result is a live `/sites/<slug>/` URL. Rollback is sub-second
(`bp cloud site rollback <slug>` re-points the upstream at the last-good slot;
nothing rebuilds).

> Windows/PowerShell one-liner for step 1 is `install-cli.ps1` (shown above).
> The full manual golden path — workspace, schema, seed, token — is in
> [DEPLOYING.md](./DEPLOYING.md).

## What's in the box

| Path | What it is |
|---|---|
| `app/(finder)/` + `finder.tsx` | The search UI — as-you-type results, facets, empty/loading/error states |
| `graph-view.tsx` + `public/bp-graph.js` | Zero-dependency Canvas2D force graph (born theme-correct, live re-skin) |
| `listings-map.tsx` | Leaflet-free map on raw OpenStreetMap tiles |
| `lib/` | The content link — search, graph fetch (`/v1/graph`), live-search socket, config |
| `app/d/[type]/[slug]/` | Document detail page rendered by `@barkpark/react` `PortableDoc` |

The renderer is the **published** `@barkpark/react` (server subpath +
`@barkpark/react/paper-surface.css`), pinned exact — never a vendored copy of
the demo's `portable-doc.tsx` fork.

## Env contract

Server-only vars drive the SSR fetch; the two `NEXT_PUBLIC_BARKPARK_WS_*` vars
(and only those) reach the browser to power live search. `bp cloud site deploy`
injects these for you; `.env.example` is the annotated list for local dev.

| Var | Reach | Meaning |
|---|---|---|
| `BARKPARK_API_URL` | server | Bare origin or scoped base `…/w/:ws/p/:proj` |
| `BARKPARK_TOKEN` | server | Read token; blank = anonymous public read |
| `BARKPARK_DATASET` | server | Dataset to read (default `docs`) |
| `BARKPARK_WORKSPACE` / `BARKPARK_PROJECT` | server | Only if `BARKPARK_API_URL` is a bare origin |
| `BARKPARK_DOC_TYPE` | server | Which type the finder indexes and details |
| `BARKPARK_SITE_BASE` | build | The `/sites/<slug>/` path baked as `basePath` (see below) |
| `NEXT_PUBLIC_BARKPARK_WS_URL` | **browser** | Phoenix socket, e.g. `wss://api.barkpark.cloud/socket` |
| `NEXT_PUBLIC_BARKPARK_WS_TOKEN` | **browser** | Read-only token scoped to the site's public workspace |

Both WS vars must be set or live search silently degrades to server-side
search — the socket path is gated on `Boolean(WS_URL && WS_TOKEN)`. A public-read
site token satisfies both the search channel and the flat `/v1/graph` corpus
route.

## Serving under `/sites/<slug>/`

Unlike a single-page site, the finder is **multi-route** (`/d/[type]/[slug]`,
graph-node clicks, home/bench links — all root-absolute). So `basePath` is
**baked at build time** from `BARKPARK_SITE_BASE`: Next auto-prefixes every
`<Link>`, `router.push`, `usePathname` and `next/image`, so no href edits and
no client-navigation escaping to the domain root. This is why the sub-path is a
build-time value, not a runtime one.

## Why the graph looks alive

The force graph is only a constellation because the **shipped seed corpus is
densely interlinked** — each document references its siblings through a scalar
`reference` field and an array-of-`reference` field, and every edge you see is a
real link in the data. A sparse dataset renders a sparse graph; the premium feel
comes from the seed being rich. (The corpus lives in the site's **Default**
workspace so the flat `/v1/graph` route, which resolves the default scope,
finds it.)

## Local dev

```sh
npm ci
cp .env.example .env      # fill BARKPARK_API_URL + BARKPARK_DATASET (+ token, + WS_* for live search)
npm run dev               # http://localhost:3000
```

Production build is what the deploy engine boots:

```sh
BARKPARK_SITE_BASE=/sites/<slug>/ npm run build
node .next/standalone/server.js
```

---

**One command in, a premium search engine out.** No worries about the socket,
the graph physics, the map library, or the renderer — they ship correct.
