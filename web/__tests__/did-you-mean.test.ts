/**
 * Tests for `suggestCorrection` — the finder's client-side "Did you mean …?".
 * It's a pure, conservative spell-suggester: single-token queries ≥4 chars, it
 * suggests the nearest candidate (Levenshtein ≤1 for short terms, ≤2 for longer)
 * drawn from result text / popular queries / a browse corpus, and NEVER suggests
 * when the typed term already appears verbatim in the results. This locks that
 * contract in — the function shipped without coverage.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/did-you-mean.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { suggestCorrection, type SuggestArgs } from "../lib/did-you-mean.ts";
import type { FindHit } from "../lib/find.ts";

function hit(title: string, excerpt = ""): FindHit {
  return {
    id: "x",
    type: "post",
    title,
    excerpt,
    body: null,
    date: null,
    slug: "x",
    href: "/d/post/x",
    facets: {},
  };
}

function args(over: Partial<SuggestArgs>): SuggestArgs {
  return { query: "", parsed: null, hits: [], popular: [], corpus: [], ...over };
}

test("suggests the nearest corpus word for a single-token typo", () => {
  assert.equal(
    suggestCorrection(args({ query: "hadless", corpus: ["headless"] })),
    "headless",
  );
});

test("does not suggest when the term appears verbatim in results", () => {
  assert.equal(
    suggestCorrection(args({ query: "headless", hits: [hit("Headless CMS")], corpus: ["headless"] })),
    null,
  );
});

test("does not suggest for a term shorter than the 4-char floor", () => {
  assert.equal(suggestCorrection(args({ query: "cms", corpus: ["cms"] })), null);
});

test("does not suggest for a multi-token query", () => {
  const parsed = { terms: ["food", "bard"], phrases: [], excludes: [], prefixes: [] };
  assert.equal(suggestCorrection(args({ query: "food bard", parsed, corpus: ["good", "bird"] })), null);
});

test("short words allow only distance 1 (no over-eager flips)", () => {
  // "wrld" → "world" is one insert → suggested.
  assert.equal(suggestCorrection(args({ query: "wrld", corpus: ["world"] })), "world");
  // "wrld" → "worlds" is two edits → beyond the short-word budget → nothing.
  assert.equal(suggestCorrection(args({ query: "wrld", corpus: ["worlds"] })), null);
});

test("a popular query outranks an incidental word at the same distance", () => {
  const got = suggestCorrection(
    args({
      query: "serch",
      popular: [{ query: "search", count: 5, resultCount: 3 }],
      corpus: ["serce"],
    }),
  );
  assert.equal(got, "search");
});

test("returns null when no candidate is within the distance budget", () => {
  assert.equal(suggestCorrection(args({ query: "headless", corpus: ["kubernetes"] })), null);
});
