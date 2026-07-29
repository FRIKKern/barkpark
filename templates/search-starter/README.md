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
#    (`bp cloud status` lists your instances and their ids)
bp cloud site create --name my-search --dataset default/default/production \
  --instance <your-box> --kind node --framework nextjs --template search-starter

# 4. deploy it — streams the six stages, prints the live URL
bp cloud site deploy <slug>
```

> `--template` is live today — it is in `bp cloud site create`'s own usage. The
> site is bound by `--instance`, and `--name` / `--dataset` / `--instance` are
> all required. There is no `--barkpark` flag; that spelling was printed here
> until it was checked against the CLI.

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

You set `BARKPARK_*` vars only. Everything the browser needs is **derived from
them at build time** by `next.config.mjs` — including live search's websocket
URL, token, and dataset (see below). `bp cloud site deploy` injects the
`BARKPARK_*` set for you; `.env.example` is the annotated list for local dev.

| Var | Reach | Meaning |
|---|---|---|
| `BARKPARK_API_URL` | server | Bare origin or scoped base `…/w/:ws/p/:proj` |
| `BARKPARK_TOKEN` | server | Read token; blank = anonymous public read |
| `BARKPARK_DATASET` | server | Dataset to read (default `docs`) |
| `BARKPARK_WORKSPACE` / `BARKPARK_PROJECT` | server | Only if `BARKPARK_API_URL` is a bare origin |
| `BARKPARK_DOC_TYPE` | server | Which type the finder indexes and details |
| `BARKPARK_SITE_BASE` | build | The `/sites/<slug>/` path baked as `basePath` (see below) |

### Live search: three derived vars, and why the third one decides everything

The keystroke path is a browser→Phoenix websocket, so its config has to be
**inlined into the client bundle**. The managed deploy path can't carry
`NEXT_PUBLIC_*` names at all (its env allowlist is closed over `BARKPARK_*`), so
`next.config.mjs` derives them instead — nothing to configure:

| Derived (browser) | From | Note |
|---|---|---|
| `NEXT_PUBLIC_BARKPARK_WS_URL` | `origin(BARKPARK_API_URL) + /socket` | `origin` strips any `/w/:ws/p/:proj` suffix — the socket lives at the bare origin |
| `NEXT_PUBLIC_BARKPARK_WS_TOKEN` | `BARKPARK_TOKEN` | Reaches the browser by design; must be **public-read** only |
| `NEXT_PUBLIC_BARKPARK_DATASET` | `BARKPARK_DATASET` | The channel topic is `search:<ws>:<proj>:<dataset>` |
| `NEXT_PUBLIC_BARKPARK_WORKSPACE` / `_PROJECT` | same names, unprefixed | Portability — the topic must not lean on the `default` fallback |

The dataset is the one that bites. Wire the URL and the token but not the
dataset, and the browser falls back to the `docs` default: it joins
`search:default:default:docs`, the join **succeeds**, the LIVE badge lights —
and every keystroke comes back with zero hits, forever, with no error anywhere.
Live search looks fixed and finds nothing. Hence: all three, or none.

With `BARKPARK_TOKEN` empty the live path ships **dark** — the socket is never
constructed (it's dead-code-eliminated from the bundle) and every keystroke
rides the same-origin HTTP `/api/find` route. That's a soft degrade, not a
failure. One public-read site token satisfies both the search channel and the
flat `/v1/graph` corpus route.

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
