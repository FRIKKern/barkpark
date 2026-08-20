# Search Starter — Astro edition

The flagship search experience as **pure static files**: every document
pre-rendered at build by the canonical `@barkpark/react` `PortableDoc` (the
same renderer Phoenix and the Next edition use — one block grammar, three
frameworks), the interactive corpus graph baked to a JSON asset, and
per-keystroke live search that talks to Barkpark **straight from the browser**
— there is no server to run.

What a deploy produces:

- `/` — the corpus graph (zero-dependency Canvas2D, hand-written force
  simulation) with the live-search bar floating over it
- `/d/<type>/<slug>/` — one static page per published document, full
  PortableDoc block rendering, `paper-surface.css` design system
- `graph.json` — the whole corpus baked at build: the landing draws instantly,
  no token ever reaches a visitor
- HEALTH markers (`bp-build-id` / `bp-content-rev` / `bp-doc-id`) in every
  page — the deploy engine gates on them before any traffic switches

Deploys ride the static engine: immutable release dirs, atomic symlink swap,
health-gated, instant rollback. Publish content → the box rebuilds → the swap
is atomic. See `templates/DEPLOYING.md`.

## One command

```bash
bp cloud site create --name my-search --dataset default/default/production \
  --instance <your-box> --framework astro --template astro-search-starter
```

Or pick **Search Starter (Astro)** in the dashboard's *+ New site* dialog.

## Local dev

```bash
cp .env.example .env   # point it at your Barkpark
npm install
npm run dev
```

`BARKPARK_THEME` pins the palette (evergreen · ember · fjord · charple);
visitors' own picker choices still win.

## The finder is THE finder — proving it (`parity-check`)

This edition ships the same dual-engine finder as the original Next finder:
**indx** and **Postgres FTS**, per keystroke, straight from the browser. On a
headless/managed deploy indx is unprovisionable, so the default served engine
is Postgres — misspellings are widened server-side by its trigram similarity
(not a full fuzzy engine, and not client-side); `?engine=indx` still opts in
where indx exists. The acceptance bar is not a vibe — it is **measured** and
re-runnable with `scripts/parity-check.mjs` (Node stdlib, zero deps).

The bar is **cross-EDITION parity, per engine**: the Next finder and the Astro
finder, given the *same engine* and the *same query*, must return the *same
hits*. It is **not** cross-*engine* identity — indx and Postgres legitimately
diverge on multi-term and typo queries (e.g. `portable document` → indx 37
hits, Postgres 100). Parity is a *set* relation, not an ordered one: both
editions read the identical route on the identical server, so hit order is a
server-side ranking detail that jitters run-to-run at a capped-result boundary,
never an edition property.

The harness hits the exact flat-anonymous route the finder uses:

```
GET /v1/data/search/:dataset?q&engine&types&perspective=published&limit=100
```

### Record a baseline (against the reference edition)

Build/deploy the **reference** edition (the live Next finder, or the last
signed-off Astro deploy) and record its hit sets:

```bash
node scripts/parity-check.mjs \
  --base https://guerrilla.barkpark.cloud \
  --dataset production --type paper \
  --write parity-baseline.json
```

This sweeps a committed **13-query, corpus-real** fixture (override with
`--fixture <json>`) across `{indx, postgres}`, **asserts determinism** (each
`(query, engine)` returns the same hit set across a repeat run), and writes
`{query, engine → [ids]}`. It exits non-zero if any pair is non-deterministic.

### Sign off this edition (side-by-side, both engine modes)

Point the **same** command at *this* edition's live deploy and `--compare`:

```bash
node scripts/parity-check.mjs \
  --base https://<this-edition-host> \
  --dataset production --type paper \
  --compare parity-baseline.json
```

It re-runs the sweep and **exits non-zero on any per-`(query, engine)` hit-set
divergence**, naming the dropped/appeared doc ids. **Exit 0 across both engine
modes IS the parity sign-off.** Example clean run against guerrilla:

```
OK — every (query, engine) hit set is deterministic across a repeat run.
...
OK — every (query, engine) hit set matches parity-baseline.json. Parity holds.
```

Build against guerrilla (or your own box) first — `cp .env.example .env`,
`npm install`, `npm run build` — so the deploy under test is real; then run the
two commands above. Same query → same hits, both engines: signed off.
