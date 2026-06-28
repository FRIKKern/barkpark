# Place Directory — Barkpark listing template

A minimal **vertical slice**: a `place` document type in Barkpark → the Next.js
map demo in [`web/`](../../web) reads it and plots every place as a pin.

The `web/` app is the stock Barkpark demo (its default landing is the docs
graph); this template flips one env var — `NEXT_PUBLIC_FINDER_LANDING=map` — to
turn the landing into the places map. It's an opt-in demo on the same core, not
a replacement.

```
Barkpark place docs ──GET /v1/data/query/{dataset}/place──▶ web/lib/listings.ts
   (fetch + normalize)                                   ──▶ map of pins (web/components/listings-map.tsx)
```

The frontend already ships with bundled sample data, so you can see the map in
~1 minute with no backend, then flip one env var to read real Barkpark content.

---

## A · See the map now (frontend only, no backend)

```sh
cd web
pnpm install
echo "NEXT_PUBLIC_FINDER_LANDING=map" >> .env.local   # opt into the map landing
pnpm dev            # → http://localhost:3000
```

The right pane is a map of 12 sample dog-friendly places across Norway, with
OpenStreetMap tiles. Search in the left rail; click a pin for its popover.
(`web/` ships a self-contained Canvas2D map — **zero map dependencies**.)

---

## B · Wire it to a real Barkpark (the vertical slice)

### 1. Run Barkpark locally

Postgres + Phoenix on `:4000`. See [`docs/setup/SETUP.md`](../../docs/setup/SETUP.md);
typically `make dev` (or `cd api && mix setup && mix phx.server`). The dev token
`barkpark-dev-token` has all permissions.

### 2. Install the `place` schema + seed sample places

```sh
cd templates/place-directory
BARKPARK_SERVER=http://localhost:4000 \
BARKPARK_API_TOKEN=barkpark-dev-token \
BARKPARK_DATASET=production \
./install.sh
```

`install.sh` upserts [`schemas/place.json`](schemas/place.json) and seeds the
sample places from [`seed-places.json`](seed-places.json), then smoke-tests the public read. Both
steps are idempotent.

> **Publish note:** `createOrReplace` may write *drafts* on your Barkpark
> version. If the smoke test returns 0 published places, publish them in Studio
> (`http://localhost:4000/studio` → each place → **Publish**), or use your
> publish flow. The schema `visibility` is `public`, so published places are
> readable anonymously — no token needed by the frontend.

### 3. Point the frontend at it

Create `web/.env.local`:

```sh
NEXT_PUBLIC_FINDER_LANDING=map
NEXT_PUBLIC_API_URL=http://localhost:4000
BARKPARK_DATASET=production
LISTINGS_TYPE=place
# optional: turn the basemap off for a pins-only map
# NEXT_PUBLIC_MAP_TILES=off
```

Restart `pnpm dev`. The map now renders **real Barkpark places** instead of the
bundled sample. With `LISTINGS_TYPE` unset it falls back to the sample set, so
the demo never breaks.

---

## How the frontend consumes it

`web/lib/listings.ts` → `fetchListings()`:
- queries `GET /v1/data/query/{dataset}/place?filter[status]=published`
- normalizes each doc to `{ id, title, lat, lng, category, city, address, … }`
- finds coordinates whether `geo.{latitude,longitude}` sits at the document top
  level or nested under `content`
- **never throws** — any failure (or `LISTINGS_TYPE` unset) falls back to the
  bundled sample so the map always has pins.

Only `id`, `title`, `lat`, `lng` are load-bearing; everything else is rendered
when present and skipped when absent. To model your own directory, edit
`schemas/place.json` and the seed, or add your own places in Studio.

---

## API contracts used (verified against this repo)

| Step | Request |
|---|---|
| Install schema | `POST /v1/schemas/{dataset}` — body = the schema object (flat) |
| Seed / write | `POST /v1/data/mutate/{dataset}` — `{"mutations":[{"createOrReplace":{…}}]}` |
| Frontend read | `GET /v1/data/query/{dataset}/place?filter[status]=published` |

Auth is `Authorization: Bearer <token>` (writes need a write/admin token; the
public read needs none because the schema is `public`).
