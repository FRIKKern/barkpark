/**
 * Tests for the places data layer's normalisation and tag handling.
 *
 * THESE TESTS NOW IMPORT THE SHIPPED CODE. They did not used to. `places.ts`
 * imports `server-only`, which is not resolvable under bare `node --test`, so
 * this file used to carry HAND-COPIED MIRRORS of `str()`, `coord()` and
 * `normalizePlace()` labelled "verbatim mirror … keep them in sync on any
 * future edit to that file". A mirror is not a link: it is a promise, and the
 * suite could not tell when the promise was broken.
 *
 * MEASURED, not assumed. Deleting the `(0,0)` guard from the REAL
 * `normalizePlace()` in `lib/places.ts` left all 24 tests green — including the
 * one named "normalizePlace returns null for a literal (0,0) coordinate". The
 * suite reported coverage it did not have.
 *
 * THE FIX, following the precedent this folder already set. `lib/paginate.ts`
 * exists for exactly this reason and says so: "This module deliberately imports
 * nothing, so the pagination behaviour ships and is tested as ONE artifact."
 * `lib/normalize.ts` now does the same for normalisation — it imports only the
 * dependency-free `paper-tags`, so it loads under `node --test`, and
 * `places.ts` consumes it rather than duplicating it. There is one
 * `normalizePlace` in this app and this file tests it.
 *
 * WHAT THE TAG TESTS COVER. `normalizePlace()` used to extract tags with a
 * FLAT-ONLY filter, which silently DROPPED authoring-excellence weighted-tag
 * objects `{tag, strength, rationale}` (charter D8–D10) — a place tagged with
 * the weighted shape lost every chip. That is the same bug `web/lib/listings.ts`
 * fixed via `web/lib/paper-tags.ts`; hundesteder is workspace-isolated
 * (pnpm-workspace.yaml `packages: []`) so the fix was PORTED, not imported, into
 * `lib/paper-tags.ts`. `oldFlatOnlyFilter` below is kept as the fail-before
 * baseline so the regression stays legible.
 *
 * Runs under Node's built-in test runner (`node --test`), which strips
 * TypeScript types at load time in Node v22+.
 *
 * Run: `npm test` (or `cd apps/hundesteder && node --test __tests__/places.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { paperTags, type PaperTag } from "../lib/paper-tags.ts";
// THE REAL FUNCTIONS — the ones `lib/places.ts` calls, not copies of them.
import {
  coord,
  normalizePlace,
  sortPlaces,
  str,
  type Place,
} from "../lib/normalize.ts";

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

/* ── str() ───────────────────────────────────────────────────────────────── */
/* Newly reachable: `str()` decides ABSENT vs PRESENT for every optional field
 * on a Place, so its empty-string rule is what keeps an empty upstream value
 * from rendering as a blank chip, a blank address line or an empty link. It
 * was unreachable while it lived behind `server-only`. */

test("str() treats an empty string as ABSENT, not as a present empty value", () => {
  assert.equal(str(""), undefined);
  assert.equal(str("Oslo"), "Oslo");
});

test("str() rejects every non-string, including numbers and objects", () => {
  for (const v of [null, undefined, 0, 42, true, {}, [], { toString: () => "x" }]) {
    assert.equal(str(v), undefined);
  }
});

test("str() preserves whitespace-only strings — trimming is the caller's job", () => {
  // Deliberate: `paperTags` trims tag names, but a title of "  " is a content
  // problem, not a parsing one, and silently blanking it would hide it.
  assert.equal(str("  "), "  ");
});

/* ── sortPlaces() ────────────────────────────────────────────────────────── */
/* Newly reachable: this comparator sets the order of the landing grid, the
 * /steder index and the map list. It was untestable behind `server-only`. */

function placeAt(city: string | undefined, title: string): Place {
  return { id: title, slug: title, title, lat: 1, lng: 1, tags: [], city };
}

test("sortPlaces groups by city first, then by title within the city", () => {
  const out = [
    placeAt("Oslo", "Zoo"),
    placeAt("Bergen", "Torget"),
    placeAt("Oslo", "Akersparken"),
    placeAt("Bergen", "Bryggen"),
  ]
    .sort(sortPlaces)
    .map((p) => `${p.city}/${p.title}`);
  assert.deepEqual(out, [
    "Bergen/Bryggen",
    "Bergen/Torget",
    "Oslo/Akersparken",
    "Oslo/Zoo",
  ]);
});

test("sortPlaces sorts a place with NO city before every named city", () => {
  // `(a.city ?? "")` makes the empty string the comparison key, and "" sorts
  // first. Pinned so the fallback is a decision rather than an accident.
  const out = [placeAt("Bergen", "B"), placeAt(undefined, "A")]
    .sort(sortPlaces)
    .map((p) => p.title);
  assert.deepEqual(out, ["A", "B"]);
});

test("sortPlaces uses NORWEGIAN collation — Ø sorts after Z, not with O", () => {
  // The distinguishing case: 'Ørsta'.localeCompare('Zakopane', 'nb') is +1,
  // but under 'en' it is -1 (ICU folds Ø to O). Dropping the "nb" argument
  // therefore flips this pair — which is exactly what this test exists to catch.
  const out = [placeAt("Ørsta", "A"), placeAt("Zakopane", "B")]
    .sort(sortPlaces)
    .map((p) => p.city);
  assert.deepEqual(out, ["Zakopane", "Ørsta"]);
});

test("sortPlaces is case-insensitive on titles — 'apple' before 'Banana'", () => {
  // A raw `<` comparison would put 'Banana' (0x42) before 'apple' (0x61).
  // localeCompare puts them in reading order, which is what a grid needs.
  const out = [placeAt("Oslo", "Banana"), placeAt("Oslo", "apple")]
    .sort(sortPlaces)
    .map((p) => p.title);
  assert.deepEqual(out, ["apple", "Banana"]);
});
