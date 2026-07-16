# Search Starter — Astro edition

The flagship search experience as **pure static files**: every document
pre-rendered at build by the canonical `@barkpark/react` `PortableDoc` (the
same renderer Phoenix and the Next edition use — one block grammar, three
frameworks), the interactive corpus graph baked to a JSON asset, and
per-keystroke live search that talks to Barkpark **straight from the browser**
— there is no server to run.

What a deploy produces:

- `/` — the corpus graph (zero-dependency Canvas2D, 3218 lines of hand-written
  force simulation) with the live-search bar floating over it
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
