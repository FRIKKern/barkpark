/**
 * The basemap-tile configuration, read in ONE place.
 *
 * WHY THIS FILE EXISTS: the tile template is consumed by two modules that must
 * agree exactly, and until now only one of them knew about it.
 *
 *   - `components/listings-map.tsx` (the browser) builds each tile request from
 *     `NEXT_PUBLIC_MAP_TILE_URL` and loads it with `new Image()`.
 *   - `lib/csp.ts` (the edge proxy) builds the `img-src` directive the browser
 *     enforces against exactly those requests.
 *
 * `img-src` was `'self' data: blob:` with no tile host in it, so EVERY basemap
 * tile the map asked for was blocked by the app's own Content-Security-Policy —
 * in every deployment, not as a rare upstream blip. The map degraded to its
 * graticule (by design, `listings-map.tsx`'s header) and said nothing, so
 * `NEXT_PUBLIC_MAP_TILE_URL` was an env var the app accepted, documented in
 * `.env.example`, and then rendered structurally inert. Worse, the popover
 * still printed the OpenStreetMap attribution the tile policy demands — a
 * credit for tiles that never arrived.
 *
 * Both readers now derive from the SAME constants and the SAME predicates
 * below, so a tile host the map fetches and a tile host the policy allows
 * cannot drift apart again.
 *
 * Every value is read at CALL time, never captured at module load: the CSP is
 * built per request in the edge proxy, and the tests flip these vars between
 * cases.
 */

/** The tile server used when `NEXT_PUBLIC_MAP_TILE_URL` is unset. */
export const DEFAULT_TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";

/**
 * The subdomains `{s}` cycles through, character by character. A template like
 * `https://{s}.tile.example.com/{z}/{x}/{y}.png` therefore issues requests to
 * THREE distinct origins, all of which the policy has to name — allowing only
 * the literal `{s}` spelling would allow an origin that is never requested and
 * block all three that are.
 *
 * `listings-map.tsx` picks per tile with `"abc"[(x + y) % 3]`; this constant is
 * what it indexes, so the two can never disagree about the alphabet.
 */
export const TILE_SUBDOMAINS = "abc";

/** The configured tile template, or the OSM default. */
export function tileUrlTemplate(): string {
  return process.env.NEXT_PUBLIC_MAP_TILE_URL || DEFAULT_TILE_URL;
}

/** Tiles are drawn unless explicitly switched off (`NEXT_PUBLIC_MAP_TILES=off`). */
export function tilesEnabled(): boolean {
  return process.env.NEXT_PUBLIC_MAP_TILES !== "off";
}

/**
 * Is the map landing the one mounted at "/"? `app/(finder)/page.tsx` renders
 * `<MapLanding>` only for the exact value `"map"`; anything else (including
 * unset) gets the graph landing and never mounts the map at all.
 *
 * The CSP reads this so the tile host is allowed ONLY on a deployment that
 * actually draws tiles — an `img-src` entry is an exfiltration channel, so the
 * policy stays as narrow as the feature that needs it. If the map is ever
 * mounted somewhere other than that landing, THIS predicate is the one place
 * to widen; `listings-map.tsx` warns at runtime when it mounts into a policy
 * that will block it, so the mismatch can never be silent again.
 */
export function mapLandingActive(): boolean {
  return process.env.NEXT_PUBLIC_FINDER_LANDING === "map";
}

/**
 * Will the CSP permit the tile requests this configuration actually produces?
 *
 * This is NOT the same question `csp.ts` gates its directive on, and collapsing
 * the two would make the map cry wolf. The policy asks "must I widen `img-src`
 * for an external host?"; this asks "will anything I request be refused?" —
 * and three configurations request nothing external, so nothing can be blocked:
 *
 *   - tiles switched off: no request is made at all;
 *   - a template naming no external host (same-origin `/tiles/…`, or one that
 *     does not parse): `'self'` already covers the former and the latter was
 *     never going to load.
 *
 * Only a template that resolves to a real external origin needs the landing
 * gate, which is the one condition `csp.ts` widens under.
 */
export function tilesAllowedByCsp(): boolean {
  if (!tilesEnabled()) return true;
  if (tileOrigins().length === 0) return true;
  return mapLandingActive();
}

/**
 * Every ORIGIN (scheme + host + port, never a path) the tile template can
 * resolve to, deduped and in `{s}` order.
 *
 * Empty when nothing external is fetched, and the caller must then add nothing
 * to the policy:
 *   - a SAME-ORIGIN template (`/tiles/{z}/{x}/{y}.png`) is not an absolute URL,
 *     so it does not parse — and `'self'` already covers it;
 *   - an unparseable/garbage template contributes nothing rather than a
 *     fabricated host;
 *   - an opaque-origin scheme (`data:`) yields the literal string "null", which
 *     is never a usable source expression.
 *
 * The `{z}/{x}/{y}` placeholders are left in the path deliberately: the WHATWG
 * parser percent-encodes them and `origin` discards the path anyway.
 */
export function tileOrigins(): string[] {
  const template = tileUrlTemplate();
  const candidates = template.includes("{s}")
    ? Array.from(TILE_SUBDOMAINS, (s) => template.split("{s}").join(s))
    : [template];

  const origins: string[] = [];
  for (const candidate of candidates) {
    let origin: string;
    try {
      origin = new URL(candidate).origin;
    } catch {
      continue; // relative or malformed — contributes no host
    }
    if (origin === "null" || origin === "") continue; // opaque origin
    if (!origins.includes(origin)) origins.push(origin);
  }
  return origins;
}
