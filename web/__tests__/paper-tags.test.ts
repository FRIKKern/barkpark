/**
 * Tests for the shared `paperTags` normaliser. The authoring-excellence wall
 * (charter D8–D10) upgraded tags from flat strings to weighted
 * `{tag, strength, rationale}` objects, so published papers now carry EITHER
 * shape (or a mix mid-migration). This reader — the one the /tags/[tag] listing
 * and the sitemap both lean on — must surface every shape's tag NAMES, clean
 * and unique, so no weighted paper falls off a public surface (charter D18).
 *
 * Runs under Node's built-in test runner (`node --test`), which strips
 * TypeScript types at load time in Node v22+.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/paper-tags.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  paperTags,
  paperTagEntries,
  tagStrength,
  sortPapersByTagStrength,
  type PaperTag,
} from "../lib/paper-tags.ts";

test("flat string array yields the names verbatim", () => {
  assert.deepEqual(paperTags(["search", "cms", "postgres"]), [
    "search",
    "cms",
    "postgres",
  ]);
});

test("weighted-object array yields the tag names", () => {
  const tags: PaperTag[] = [
    { tag: "search", strength: 90, rationale: "core topic" },
    { tag: "cms", strength: 40, rationale: "domain" },
  ];
  assert.deepEqual(paperTags(tags), ["search", "cms"]);
});

test("mixed flat + weighted array reads both shapes", () => {
  const tags: PaperTag[] = [
    "legacy",
    { tag: "search", strength: 90, rationale: "core topic" },
    "postgres",
  ];
  assert.deepEqual(paperTags(tags), ["legacy", "search", "postgres"]);
});

test("empty array yields an empty list", () => {
  assert.deepEqual(paperTags([]), []);
});

test("undefined / null / non-array input yields an empty list", () => {
  assert.deepEqual(paperTags(undefined), []);
  assert.deepEqual(paperTags(null), []);
  // Malformed projection (not an array) must not throw.
  assert.deepEqual(paperTags("search" as unknown as PaperTag[]), []);
});

test("drops blanks, whitespace-only names, and trims", () => {
  const tags: PaperTag[] = [
    "  search  ",
    "",
    "   ",
    { tag: "  cms  ", strength: 30, rationale: "x" },
    { tag: "" },
  ];
  assert.deepEqual(paperTags(tags), ["search", "cms"]);
});

test("dedups repeated names across both shapes, first-seen order", () => {
  const tags: PaperTag[] = [
    "search",
    { tag: "search", strength: 90, rationale: "dup by object" },
    "cms",
    "search",
  ];
  assert.deepEqual(paperTags(tags), ["search", "cms"]);
});

test("drops malformed entries (null, number, tagless object) without throwing", () => {
  const tags = [
    null,
    42,
    { strength: 50, rationale: "no tag member" },
    { tag: 7 },
    "search",
  ] as unknown as PaperTag[];
  assert.deepEqual(paperTags(tags), ["search"]);
});

/* ── paperTagEntries — dual-shape, preserves strength + rationale ─────────── */

test("paperTagEntries: weighted objects keep strength + rationale", () => {
  const tags: PaperTag[] = [
    { tag: "search", strength: 90, rationale: "core topic" },
    { tag: "cms", strength: 40, rationale: "domain" },
  ];
  assert.deepEqual(paperTagEntries(tags), [
    { tag: "search", strength: 90, rationale: "core topic" },
    { tag: "cms", strength: 40, rationale: "domain" },
  ]);
});

test("paperTagEntries: flat legacy strings carry no strength / rationale", () => {
  assert.deepEqual(paperTagEntries(["search", "cms"]), [
    { tag: "search" },
    { tag: "cms" },
  ]);
});

test("paperTagEntries: mixed shapes, trims names, dedups first-seen", () => {
  const tags: PaperTag[] = [
    "  legacy  ",
    { tag: "search", strength: 90, rationale: "  weighs in  " },
    { tag: "legacy", strength: 12, rationale: "dup — dropped" },
  ];
  assert.deepEqual(paperTagEntries(tags), [
    { tag: "legacy" },
    { tag: "search", strength: 90, rationale: "weighs in" },
  ]);
});

test("paperTagEntries: malformed metadata degrades to a bare name, never throws", () => {
  const tags = [
    { tag: "search", strength: "90", rationale: 7 }, // wrong types → dropped
    { tag: "cms", strength: Number.NaN, rationale: "   " }, // NaN + blank → dropped
    { tag: "postgres", strength: 0, rationale: "zero is a valid weight" },
    null,
    42,
    { strength: 50 }, // tagless → dropped
  ] as unknown as PaperTag[];
  assert.deepEqual(paperTagEntries(tags), [
    { tag: "search" },
    { tag: "cms" },
    { tag: "postgres", strength: 0, rationale: "zero is a valid weight" },
  ]);
});

test("paperTagEntries: non-array input yields an empty list", () => {
  assert.deepEqual(paperTagEntries(undefined), []);
  assert.deepEqual(paperTagEntries(null), []);
  assert.deepEqual(paperTagEntries("search" as unknown as PaperTag[]), []);
});

/* ── tagStrength — the matched weight, undefined for legacy / absent ──────── */

test("tagStrength: returns the weighted strength for a matched tag", () => {
  const tags: PaperTag[] = [
    { tag: "search", strength: 90, rationale: "core" },
    { tag: "cms", strength: 40, rationale: "domain" },
  ];
  assert.equal(tagStrength(tags, "search"), 90);
  assert.equal(tagStrength(tags, "cms"), 40);
});

test("tagStrength: legacy flat match has no strength (undefined)", () => {
  assert.equal(tagStrength(["search", "cms"], "search"), undefined);
});

test("tagStrength: absent tag and blank name are undefined", () => {
  const tags: PaperTag[] = [{ tag: "search", strength: 90, rationale: "x" }];
  assert.equal(tagStrength(tags, "missing"), undefined);
  assert.equal(tagStrength(tags, "   "), undefined);
  assert.equal(tagStrength(undefined, "search"), undefined);
});

test("tagStrength: name is compared trimmed", () => {
  const tags: PaperTag[] = [{ tag: "  search  ", strength: 55, rationale: "x" }];
  assert.equal(tagStrength(tags, "search"), 55);
});

/* ── sortPapersByTagStrength — strongest first, unknown last ──────────────── */
/*
 * MUTATION PROOF. The three fixtures below are supplied in `_updatedAt:desc`
 * order (newest first) — which is DELIBERATELY the inverse of their strength
 * order. If the sort is removed / falls back to the incoming (_updatedAt) order,
 * this assertion REDS: the array would read [weak, mid, strong] instead of
 * [strong, mid, weak]. Verified: deleting the `.sort(...)` in
 * sortPapersByTagStrength turns this test red.
 */
type SortFixture = { id: string; tags?: PaperTag[] | null };

test("sortPapersByTagStrength: ranks by matched-tag strength DESC (sort-removed → red)", () => {
  const papers: SortFixture[] = [
    { id: "weak-newest", tags: [{ tag: "search", strength: 10, rationale: "a" }] },
    { id: "mid", tags: [{ tag: "search", strength: 50, rationale: "b" }] },
    { id: "strong-oldest", tags: [{ tag: "search", strength: 95, rationale: "c" }] },
  ];
  const ranked = sortPapersByTagStrength(papers, "search").map((p) => p.id);
  assert.deepEqual(ranked, ["strong-oldest", "mid", "weak-newest"]);
});

test("sortPapersByTagStrength: unknown-strength papers sort LAST", () => {
  const papers: SortFixture[] = [
    { id: "legacy-flat", tags: ["search"] }, // no strength
    { id: "weighted-20", tags: [{ tag: "search", strength: 20, rationale: "x" }] },
    { id: "tag-absent", tags: [{ tag: "other", strength: 99, rationale: "y" }] },
    { id: "weighted-70", tags: [{ tag: "search", strength: 70, rationale: "z" }] },
  ];
  const ranked = sortPapersByTagStrength(papers, "search").map((p) => p.id);
  // weighted first (70 > 20), then the two unknowns in incoming order (stable).
  assert.deepEqual(ranked, [
    "weighted-70",
    "weighted-20",
    "legacy-flat",
    "tag-absent",
  ]);
});

test("sortPapersByTagStrength: equal strengths keep incoming order (stable)", () => {
  const papers: SortFixture[] = [
    { id: "first", tags: [{ tag: "search", strength: 50, rationale: "a" }] },
    { id: "second", tags: [{ tag: "search", strength: 50, rationale: "b" }] },
    { id: "third", tags: [{ tag: "search", strength: 50, rationale: "c" }] },
  ];
  const ranked = sortPapersByTagStrength(papers, "search").map((p) => p.id);
  assert.deepEqual(ranked, ["first", "second", "third"]);
});

test("sortPapersByTagStrength: is pure — does not mutate its input", () => {
  const papers: SortFixture[] = [
    { id: "a", tags: [{ tag: "search", strength: 10, rationale: "x" }] },
    { id: "b", tags: [{ tag: "search", strength: 90, rationale: "y" }] },
  ];
  const before = papers.map((p) => p.id);
  sortPapersByTagStrength(papers, "search");
  assert.deepEqual(
    papers.map((p) => p.id),
    before,
  );
});
