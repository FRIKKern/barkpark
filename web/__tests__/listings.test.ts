/**
 * Tests for the listings data layer's tag handling (`web/lib/listings.ts`).
 *
 * The finder/map listings (the geo `LISTINGS_TYPE` doctype) used to extract a
 * row's tags with a FLAT-ONLY filter:
 *
 *     const tags = Array.isArray(tagsRaw)
 *       ? tagsRaw.filter((t): t is string => typeof t === "string")
 *       : undefined;
 *
 * That silently DROPPED authoring-excellence weighted-tag objects
 * `{tag, strength, rationale}` (charter D8–D10) — a listing tagged with the
 * weighted shape lost every chip. `listings.ts` now leans on the shared
 * `paperTags` normalizer (the same reader the Paper surfaces use), so both
 * shapes — and a mid-migration mix — survive.
 *
 * `listings.ts` itself imports `server-only` + `next/cache` + `@/` path aliases,
 * so it can't be loaded under bare `node --test`. These tests instead exercise
 * the exact extraction expression the normalizer now runs (`paperTags(content.tags
 * ?? r.tags)`) against the OLD flat-only filter, side by side, on the same
 * weighted input — proving the fix RETAINS what the pre-fix filter DROPPED.
 *
 * Runs under Node's built-in test runner (`node --test`), which strips
 * TypeScript types at load time in Node v22+.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/listings.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { paperTags, type PaperTag } from "../lib/paper-tags.ts";

/**
 * The FLAT-ONLY filter `listings.ts` used BEFORE this fix — kept here verbatim
 * as the fail-before baseline. It returns `undefined` for a non-array and keeps
 * only entries that are already plain strings, so every weighted-tag object is
 * dropped.
 */
function oldFlatOnlyFilter(tagsRaw: unknown): string[] | undefined {
  return Array.isArray(tagsRaw)
    ? tagsRaw.filter((t): t is string => typeof t === "string")
    : undefined;
}

/**
 * The extraction `normalizeListing` runs TODAY: `content.tags ?? r.tags`, fed
 * through the shared `paperTags` normalizer. Mirrors `listings.ts` exactly so
 * these assertions track the real code path.
 */
function extractTags(
  content: { tags?: unknown },
  r: { tags?: unknown },
): string[] {
  return paperTags((content.tags ?? r.tags) as PaperTag[] | undefined);
}

test("FAIL-BEFORE: the old flat-only filter drops weighted-tag objects", () => {
  const weighted: PaperTag[] = [
    { tag: "dog_friendly", strength: 90, rationale: "core amenity" },
    { tag: "outdoor_seating", strength: 40, rationale: "amenity" },
  ];
  // The pre-fix filter kept ONLY plain strings, so a weighted-tag listing lost
  // every chip — this is the bug the fix closes.
  assert.deepEqual(oldFlatOnlyFilter(weighted), []);
});

test("a weighted-tag listing is RETAINED (its tag names survive)", () => {
  const content = {
    tags: [
      { tag: "dog_friendly", strength: 90, rationale: "core amenity" },
      { tag: "outdoor_seating", strength: 40, rationale: "amenity" },
    ] as PaperTag[],
  };
  assert.deepEqual(extractTags(content, {}), [
    "dog_friendly",
    "outdoor_seating",
  ]);
});

test("flat-string listings still read verbatim (no regression)", () => {
  const content = { tags: ["dog_friendly", "off_leash_area"] as PaperTag[] };
  assert.deepEqual(extractTags(content, {}), [
    "dog_friendly",
    "off_leash_area",
  ]);
});

test("a mid-migration mix of flat + weighted reads both shapes", () => {
  const content = {
    tags: [
      "dog_friendly",
      { tag: "outdoor_seating", strength: 55, rationale: "amenity" },
    ] as PaperTag[],
  };
  assert.deepEqual(extractTags(content, {}), [
    "dog_friendly",
    "outdoor_seating",
  ]);
});

test("top-level `r.tags` is used when `content.tags` is absent", () => {
  const r = {
    tags: [{ tag: "off_leash_area", strength: 70, rationale: "amenity" }] as PaperTag[],
  };
  assert.deepEqual(extractTags({}, r), ["off_leash_area"]);
});

test("`content.tags` wins over `r.tags` when both are present", () => {
  const content = { tags: ["dog_friendly"] as PaperTag[] };
  const r = { tags: ["stale_top_level"] as PaperTag[] };
  assert.deepEqual(extractTags(content, r), ["dog_friendly"]);
});

test("a listing with no tags yields an empty list (→ undefined at the call site)", () => {
  // `paperTags` returns `[]`; `listings.ts` line 126 maps `[]` → `undefined`
  // via `tags.length > 0 ? tags : undefined`, so the chip row stays absent.
  assert.deepEqual(extractTags({}, {}), []);
  const tags = extractTags({}, {});
  assert.equal(tags.length > 0 ? tags : undefined, undefined);
});

test("malformed weighted entries are dropped without throwing", () => {
  const content = {
    tags: [
      null,
      42,
      { strength: 50, rationale: "no tag member" },
      { tag: "dog_friendly", strength: 80, rationale: "amenity" },
    ] as unknown as PaperTag[],
  };
  assert.deepEqual(extractTags(content, {}), ["dog_friendly"]);
});

test("a non-array tags projection does not throw and yields no chips", () => {
  // A shape-drifted upstream row could hand back a scalar; the old filter
  // returned `undefined`, the normalizer returns `[]` — neither throws.
  assert.deepEqual(extractTags({ tags: "dog_friendly" }, {}), []);
});
