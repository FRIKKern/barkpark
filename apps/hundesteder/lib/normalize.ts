/**
 * The PURE normalisation layer for the places data layer — every function that
 * turns a raw upstream `place` document into a `Place`, extracted so the REAL
 * code is the code under test.
 *
 * WHY THIS FILE EXISTS. `places.ts` imports `server-only`, which is not a
 * resolvable package outside the Next.js build, so it cannot be loaded under
 * bare `node --test`. For as long as that was true, `__tests__/places.test.ts`
 * tested HAND-COPIED MIRRORS of `str()`, `coord()` and `normalizePlace()` with
 * a "keep them in sync on any future edit" comment as the only link back to the
 * shipped code. That is a vacuous suite: deleting the `(0,0)` guard from the
 * real `normalizePlace()` left all 24 tests green — including the one named
 * "normalizePlace returns null for a literal (0,0) coordinate". A test that
 * cannot fail when the shipped function breaks is not coverage; it is a report
 * that coverage exists.
 *
 * `lib/paginate.ts` already legislated the remedy for the pagination loop, in
 * its own words: "This module deliberately imports nothing, so the pagination
 * behaviour ships and is tested as ONE artifact." This file finishes the job
 * for normalisation. It imports ONLY `./paper-tags` (itself dependency-free),
 * so it loads under `node --test` and the shipped function is the tested one.
 *
 * THE RULE THIS FILE CARRIES: nothing here may import `server-only`, `next/*`,
 * or anything that reaches the network. Fetching, env reading, caching and the
 * pagination walk stay in `places.ts`; deciding what a document MEANS lives
 * here.
 */

import { paperTags, type PaperTag } from "./paper-tags.ts";

/** A normalised, renderable place. */
export interface Place {
  id: string;
  slug: string;
  title: string;
  description?: string;
  category?: string;
  city?: string;
  /** Latitude, parsed from the upstream string. */
  lat: number;
  /** Longitude, parsed from the upstream string. */
  lng: number;
  address?: {
    street?: string;
    postalCode?: string;
    country?: string;
  };
  websiteUrl?: string;
  priceRange?: string;
  tags: string[];
}

/** A non-empty string, or undefined. Empty strings are absent, not present. */
export function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** A COMPLETE numeric literal, and nothing else. Optional sign, digits with an
 * optional fractional part (or a bare fraction), optional exponent. */
const NUMERIC_LITERAL = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;

/** Coerce a coordinate that arrives as a numeric string (or, defensively, a
 * number). Returns undefined when the value can't be read as a finite number.
 *
 * THE WHOLE STRING OR NOTHING. This used to be `parseFloat`, which stops at the
 * first character it cannot use and returns what it read so far — so a value it
 * only PARTIALLY understood came back looking exactly like a value it fully
 * understood. Measured on the real function:
 *
 *     coord("59,9139")  ->  59        a Norwegian decimal COMMA: ~101 km south
 *     coord("59.9deg")  ->  59.9      a stray unit, silently eaten
 *     coord("12abc")    ->  12
 *
 * The comma is the one that matters, and it is not hypothetical: this is a
 * Norwegian directory, nb-NO writes decimals with a comma, and `geo.latitude`
 * arrives from upstream as a free-text STRING. An editor who types the number
 * the way their locale spells it gets a place pinned about a hundred kilometres
 * from where it is — no error, no warning, and a page that looks entirely
 * normal. A wrong coordinate is worse than an absent one, because the reader
 * acts on it.
 *
 * So the string is a complete numeric literal or it is refused, and a refused
 * coordinate makes normalizePlace() return null — the same outcome the (0,0)
 * guard already produces, for the same reason. `Number()` alone would not do:
 * it reads "0x10" as 16 and "" as 0. */
export function coord(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  if (!NUMERIC_LITERAL.test(t)) return undefined;
  const n = Number(t);
  return Number.isFinite(n) ? n : undefined; // "1e999" is a literal, but Infinity
}

/** Web-Mercator's domain — the honest limit of "somewhere we can put on a map".
 *
 * OUT OF RANGE IS THE SAME CLASS AS (0,0): not a real coordinate, and drawing it
 * anyway is worse than dropping it. `components/places-map.tsx` CLAMPS latitude
 * to +/-85.05 before projecting (`clampLat`, called inside `latToWorldY`), so a
 * latitude of 599 does not fail — it silently becomes a pin in the Arctic. And
 * `fitToPlaces()` takes min/max over EVERY place before choosing the zoom, so
 * that single row drags the bounding box to the pole and collapses the landing
 * map towards MIN_ZOOM: one malformed document, and every other pin on the
 * shared surface becomes an unreadable dot. */
const LAT_LIMIT = 900;
const LNG_LIMIT = 180;

/** Normalise one raw upstream `place` document into a `Place`, or null if it
 * lacks a usable coordinate (the map can only show what it can place, and the
 * detail page centres on the pin). */
export function normalizePlace(raw: unknown): Place | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const geo = (r.geo && typeof r.geo === "object" ? r.geo : {}) as Record<
    string,
    unknown
  >;
  const lat = coord(geo.latitude);
  const lng = coord(geo.longitude);
  if (lat === undefined || lng === undefined) return null;
  // A literal (0,0) is an unset default, not a real place — drop it.
  if (lat === 0 && lng === 0) return null;
  // Outside the projection's domain: also not a real place. See LAT_LIMIT.
  if (Math.abs(lat) > LAT_LIMIT || Math.abs(lng) > LNG_LIMIT) return null;

  const id = str(r._id) ?? str(r.id) ?? str(r.slug);
  if (!id) return null;

  const slug = str(r.slug) ?? id;

  const addrRaw = (
    r.address && typeof r.address === "object" ? r.address : {}
  ) as Record<string, unknown>;
  const address = {
    street: str(addrRaw.street),
    postalCode: str(addrRaw.postal_code),
    country: str(addrRaw.country),
  };
  const hasAddress = address.street || address.postalCode || address.country;

  // Paper surfaces carry weighted tags (charter D8–D10): a flat-string-only
  // filter here silently drops any `{tag,strength,rationale}` object, so lean
  // on the shared `paperTags` normaliser instead (ported from
  // `web/lib/paper-tags.ts`, which fixed the identical bug in listings.ts).
  const tags = paperTags(r.tags as PaperTag[] | undefined);

  return {
    id,
    slug,
    title: str(r.title) ?? id,
    description: str(r.description),
    category: str(r.category),
    city: str(r.city),
    lat,
    lng,
    address: hasAddress ? address : undefined,
    websiteUrl: str(r.website_url),
    priceRange: str(r.price_range),
    tags,
  };
}

/** Sort: group by city (alphabetical), then by title within a city. Gives the
 * landing grid and the index a stable, scannable order. Norwegian collation, so
 * æ/ø/å sort after z rather than by code point. */
export function sortPlaces(a: Place, b: Place): number {
  const c = (a.city ?? "").localeCompare(b.city ?? "", "nb");
  if (c !== 0) return c;
  return a.title.localeCompare(b.title, "nb");
}
