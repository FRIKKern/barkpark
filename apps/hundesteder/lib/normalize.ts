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

/** Coerce a coordinate that arrives as a numeric string (or, defensively, a
 * number). Returns undefined when the value can't be read as a finite number. */
export function coord(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = parseFloat(v);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

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
