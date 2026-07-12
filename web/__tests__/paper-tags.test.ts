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
import { paperTags, type PaperTag } from "../lib/paper-tags.ts";

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
