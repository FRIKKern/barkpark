/**
 * Tests for the places data layer's tag handling and normalisation
 * (`apps/hundesteder/lib/places.ts`).
 *
 * `normalizePlace()` used to extract a place's tags with a FLAT-ONLY filter:
 *
 *     const tags = Array.isArray(tagsRaw)
 *       ? tagsRaw.filter((t): t is string => typeof t === "string")
 *       : [];
 *
 * That silently DROPPED authoring-excellence weighted-tag objects
 * `{tag, strength, rationale}` (charter D8–D10) — a place tagged with the
 * weighted shape lost every chip. This is the exact bug `web/lib/listings.ts`
 * already fixed via `web/lib/paper-tags.ts`; hundesteder is workspace-isolated
 * (pnpm-workspace.yaml `packages: []`) so the fix was PORTED, not imported,
 * into `apps/hundesteder/lib/paper-tags.ts`. `normalizePlace()` now leans on
 * that shared `paperTags` normaliser, so both shapes — and a mid-migration
 * mix — survive.
 *
 * `places.ts` itself imports `server-only`, which isn't a resolvable package
 * outside the Next.js build (it isn't a direct dependency of this workspace),
 * so it can't be loaded under bare `node --test` — the same constraint
 * `web/__tests__/listings.test.ts` documents for `web/lib/listings.ts`.
 * These tests mirror `coord()` and `normalizePlace()` verbatim from
 * `../lib/places.ts` (keep them in sync on any future edit to that file) and
 * exercise the real, importable `paperTags` normaliser for the tag-shape
 * coverage, side by side with the OLD flat-only filter as the fail-before
 * baseline.
 *
 * Runs under Node's built-in test runner (`node --test`), which strips
 * TypeScript types at load time in Node v22+.
 *
 * Run: `npm test` (or `cd apps/hundesteder && node --test __tests__/places.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { paperTags, type PaperTag } from "../lib/paper-tags.ts";

/* ── mirrors of ../lib/places.ts (kept in sync by hand; see file header) ── */

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Verbatim mirror of `coord()` in `../lib/places.ts`. */
function coord(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = parseFloat(v);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

interface Place {
  id: string;
  slug: string;
  title: string;
  description?: string;
  category?: string;
  city?: string;
  lat: number;
  lng: number;
  address?: { street?: string; postalCode?: string; country?: string };
  websiteUrl?: string;
  priceRange?: string;
  tags: string[];
}

/** Verbatim mirror of `normalizePlace()` in `../lib/places.ts`. */
function normalizePlace(raw: unknown): Place | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const geo = (r.geo && typeof r.geo === "object" ? r.geo : {}) as Record<
    string,
    unknown
  >;
  const lat = coord(geo.latitude);
  const lng = coord(geo.longitude);
  if (lat === undefined || lng === undefined) return null;
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

/** The FLAT-ONLY filter `normalizePlace()` used BEFORE this fix — kept here
 * verbatim as the fail-before baseline. */
function oldFlatOnlyFilter(tagsRaw: unknown): string[] {
  return Array.isArray(tagsRaw)
    ? tagsRaw.filter((t): t is string => typeof t === "string")
    : [];
}

/** A minimal raw upstream `place` doc with a usable, non-origin coordinate. */
function rawPlace(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    _id: "place-1",
    slug: "oslo-dog-park",
    title: "Oslo Dog Park",
    geo: { latitude: "59.9139", longitude: "10.7522" },
    ...overrides,
  };
}

/* ── weighted-tag survival (fails-before-fix) ───────────────────────────── */

test("FAIL-BEFORE: the old flat-only filter drops weighted-tag objects", () => {
  const weighted: PaperTag[] = [
    { tag: "dog_friendly", strength: 90, rationale: "core amenity" },
    { tag: "outdoor_seating", strength: 40, rationale: "amenity" },
  ];
  assert.deepEqual(oldFlatOnlyFilter(weighted), []);
});

test("a weighted-tag object survives normalizePlace() (its tag names survive)", () => {
  const raw = rawPlace({
    tags: [
      { tag: "dog_friendly", strength: 90, rationale: "core amenity" },
      { tag: "outdoor_seating", strength: 40, rationale: "amenity" },
    ],
  });
  const place = normalizePlace(raw) as Place;
  assert.ok(place, "normalizePlace should return a Place, not null");
  assert.deepEqual(place.tags, ["dog_friendly", "outdoor_seating"]);
});

test("flat-string tags still read verbatim (no regression)", () => {
  const raw = rawPlace({ tags: ["dog_friendly", "off_leash_area"] });
  const place = normalizePlace(raw) as Place;
  assert.deepEqual(place.tags, ["dog_friendly", "off_leash_area"]);
});

test("a mid-migration mix of flat + weighted tags reads both shapes", () => {
  const raw = rawPlace({
    tags: [
      "dog_friendly",
      { tag: "outdoor_seating", strength: 55, rationale: "amenity" },
    ],
  });
  const place = normalizePlace(raw) as Place;
  assert.deepEqual(place.tags, ["dog_friendly", "outdoor_seating"]);
});

test("null/missing tags yield an empty list, not a crash", () => {
  const place = normalizePlace(rawPlace({ tags: null })) as Place;
  assert.deepEqual(place.tags, []);
  const placeNoTags = normalizePlace(rawPlace()) as Place;
  assert.deepEqual(placeNoTags.tags, []);
});

test("malformed weighted entries are dropped without throwing", () => {
  const raw = rawPlace({
    tags: [null, 42, { strength: 50, rationale: "no tag member" }, "dog_friendly"],
  });
  const place = normalizePlace(raw) as Place;
  assert.deepEqual(place.tags, ["dog_friendly"]);
});

/* ── normalizePlace() edge cases ─────────────────────────────────────────── */

test("normalizePlace returns null for a non-object input", () => {
  assert.equal(normalizePlace(null), null);
  assert.equal(normalizePlace("not an object"), null);
  assert.equal(normalizePlace(undefined), null);
});

test("normalizePlace returns null when geo coordinates are missing", () => {
  assert.equal(normalizePlace({ _id: "x", title: "No Geo" }), null);
});

test("normalizePlace returns null for a literal (0,0) coordinate", () => {
  const raw = rawPlace({ geo: { latitude: "0", longitude: "0" } });
  assert.equal(normalizePlace(raw), null);
});

test("normalizePlace returns null when no usable id/slug is present", () => {
  const raw = { title: "No Id", geo: { latitude: "59.9", longitude: "10.7" } };
  assert.equal(normalizePlace(raw), null);
});

test("normalizePlace omits address when no address fields are present", () => {
  const place = normalizePlace(rawPlace()) as Place;
  assert.equal(place.address, undefined);
});

test("normalizePlace includes address when at least one field is present", () => {
  const place = normalizePlace(
    rawPlace({ address: { street: "Karl Johans gate 1" } }),
  ) as Place;
  assert.deepEqual(place.address, {
    street: "Karl Johans gate 1",
    postalCode: undefined,
    country: undefined,
  });
});

test("normalizePlace falls back to id when title/slug are absent", () => {
  const place = normalizePlace({
    _id: "place-42",
    geo: { latitude: "59.9", longitude: "10.7" },
  }) as Place;
  assert.equal(place.slug, "place-42");
  assert.equal(place.title, "place-42");
});

/* ── coord() edge cases ──────────────────────────────────────────────────── */

test("coord() parses a numeric string", () => {
  assert.equal(coord("59.9139"), 59.9139);
});

test("coord() passes through a finite number", () => {
  assert.equal(coord(10.75), 10.75);
});

test("coord() rejects a non-numeric string", () => {
  assert.equal(coord("not-a-number"), undefined);
});

test("coord() rejects an empty/whitespace-only string", () => {
  assert.equal(coord(""), undefined);
  assert.equal(coord("   "), undefined);
});

test("coord() rejects null, undefined, NaN, and Infinity", () => {
  assert.equal(coord(null), undefined);
  assert.equal(coord(undefined), undefined);
  assert.equal(coord(NaN), undefined);
  assert.equal(coord(Infinity), undefined);
});
