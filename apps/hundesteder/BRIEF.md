# Hundesteder.no — build brief

A real, editorial directory of **dog-friendly places in Norway** (hundesteder = "dog places").
Next.js App Router app, served from this folder, deployed to Vercel (`hundesteder.vercel.app`).
Norwegian-language UI copy.

## Data (Barkpark, prod)

- Base: `https://api.barkpark.cloud/w/hundesteder/p/default`
- List published places: `GET {base}/v1/data/query/production/place?filter[status]=published`
- Single: `GET {base}/v1/data/doc/production/place/{id}`
- Auth header (server-side only): `Authorization: Bearer ${BARKPARK_API_TOKEN}` — this is a
  read-only token; **never expose it to the browser** (no `NEXT_PUBLIC_` prefix). Fetch in
  Server Components / route handlers only.
- Response envelope: `{ "result": { "count": N, "documents": [ ... ] } }` (note the `result` wrapper).
- `doc.get` envelope: `{ "result": { ...doc } }`.

### `place` document shape
```
_id, slug, title, description, category, city,
geo:    { latitude: string, longitude: string }   // NOTE: strings — parseFloat them
address:{ street?, postal_code?, country? },
website_url?, price_range?, tags: string[]
```
Categories currently in the data: `Café`, `Food hall`, `Park`, `Sight`, `Beach`.
12 places across Oslo, Bergen, Trondheim, Stavanger, Tromsø.

### Env vars
```
BARKPARK_API_BASE=https://api.barkpark.cloud/w/hundesteder/p/default
BARKPARK_DATASET=production
BARKPARK_API_TOKEN=<server-only read token — provided separately, write to .env.local>
```

## Design system — "Pawtrails" (already materialized in this folder)

- `styles/pawtrails-tokens.css` — the full token set + base element styles + utilities
  (`.eyebrow`, `.ingress`, `.measure`, `.muted`, etc.). **Import this globally.**
- `styles/pawtrails-palettes.css` — 12 dog-breed themes (light+dark) via `html[data-theme="…"]`.
  Default (no `data-theme`) is the brand: warm cream `--paper #FBFAF6` + terracotta `--accent #A23925` + ink.
  A small theme switcher is a nice-to-have, not required.
- Fonts: load **Fraunces** (serif, display+body), **Inter Tight** (sans/UI), **JetBrains Mono**
  via `next/font/google`, exposing CSS variables `--font-fraunces`, `--font-inter-tight`,
  `--font-jetbrains-mono` (the tokens reference these). Set them on `<html>` in `app/layout.tsx`.
- Icons: `public/icons/{pawtrails-mark,paw,pin,bowl,cafe,bar,restaurant,trail,leash}.svg`.
  `pawtrails-mark.svg` = the logo. Stroke icons use `currentColor`.
  Category → icon: Café→cafe, Food hall→bowl, Restaurant→restaurant, Bar→bar,
  Park/Beach→trail, Sight→pin, default→paw.

### Visual language
Editorial Scandinavian magazine: Fraunces headlines (`font-variation-settings:"opsz"`),
terracotta used surgically (links, eyebrows, active pins), generous whitespace, hairline
`--rule` dividers, cards on `--paper-white` with `--shadow-hover` on hover. Status pill
`--ok` "åpent" style is available but we have no hours data yet — skip until the schema gains hours.

## Pages

1. **`/` landing** — hero (`.eyebrow` "Hundesteder" + Fraunces H1 + `.ingress` in Norwegian),
   the interactive **map of all places**, then an editorial grid of place cards (name, category
   icon+label, city, one-line description). Footer with the paw mark.
2. **`/steder` index** — all places as cards, filter by city and by category (client-side).
3. **`/sted/[slug]` detail** — large Fraunces title, category pill, city, description (`.ingress`),
   address block, website link, a small map centred on the pin, "tilbake" link.

## Map

Reuse the self-contained Canvas2D map already in the monorepo (zero map deps):
`../../web/components/listings-map.tsx` + `../../web/lib/listings.ts`. Copy them into this app
(`components/` + `lib/`), repoint the fetch at the data above (the `result` envelope + this token),
and restyle pins/popover with the Pawtrails tokens (terracotta pins). Keep it dependency-free.

## Build / verify

- Package manager: pnpm. `pnpm build` MUST pass (no type errors).
- `pnpm dev` renders the landing with 12 real pins + cards.
- Keep dependencies minimal (next, react, react-dom, typescript, @types). No Tailwind — plain CSS
  with the Pawtrails tokens. CSS Modules are fine.
- This app is isolated under `apps/hundesteder/`; do not modify `web/` or `api/`.
