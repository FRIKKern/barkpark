/**
 * Tests for `fuzzy.ts` — the finder's search-highlight scorer/renderer. This is
 * a large, previously-untested module; the cases below lock the pure, contract-
 * bearing exports: the tokenizer, the score→colour ramp (monotonic red→green,
 * null below the floor), the quality-label mapping, the term-hit predicate, and
 * the highlighter's text-preservation invariant (segments must reconstruct the
 * input exactly — a highlighter that drops or duplicates text corrupts the row).
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/fuzzy.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  words,
  termHitsWords,
  highlightColors,
  qualityLabel,
  highlightSegments,
  MIN_SCORE,
} from "../lib/fuzzy.ts";

/* ── words (tokenizer) ─────────────────────────────────────────────────── */

test("words splits on non-word chars, keeps apostrophes", () => {
  assert.deepEqual(words("hello world"), ["hello", "world"]);
  assert.deepEqual(words("a-b.c"), ["a", "b", "c"]);
  assert.deepEqual(words("it's fine"), ["it's", "fine"]);
});

test("words returns [] for empty / whitespace", () => {
  assert.deepEqual(words(""), []);
  assert.deepEqual(words("   \n\t"), []);
});

/* ── highlightColors (score → colour ramp) ─────────────────────────────── */

const hueOf = (c: { light: string } | null): number =>
  Number(c!.light.match(/hsl\((\d+)/)![1]);

test("highlightColors returns null below the score floor", () => {
  assert.equal(highlightColors(MIN_SCORE - 0.01), null);
  assert.equal(highlightColors(0), null);
});

test("highlightColors returns colours at/above the floor", () => {
  assert.notEqual(highlightColors(MIN_SCORE), null);
  assert.notEqual(highlightColors(1), null);
});

test("highlightColors hue climbs red→emerald with the score", () => {
  const lo = hueOf(highlightColors(MIN_SCORE));
  const mid = hueOf(highlightColors(0.7));
  const hi = hueOf(highlightColors(1));
  assert.equal(lo, 0); // worst real match → red
  assert.equal(hi, 162); // exact → emerald
  assert.ok(lo < mid && mid < hi, `hue must be monotonic: ${lo} < ${mid} < ${hi}`);
});

/* ── qualityLabel (kind + score → label) ───────────────────────────────── */

test("qualityLabel names both axes (kind and confidence)", () => {
  assert.equal(qualityLabel("exact", 1), "Exact match");
  assert.equal(qualityLabel("inflection", 0.9), "Strong match");
  assert.equal(qualityLabel("inflection", 0.75), "Solid match");
  assert.equal(qualityLabel("inflection", 0.5), "Related form");
  assert.equal(qualityLabel("verbatim", 0.9), "Strong match");
  assert.equal(qualityLabel("verbatim", 0.8), "Solid match");
  assert.equal(qualityLabel("verbatim", 0.5), "Partial match");
  assert.equal(qualityLabel("corrected", 0.7), "Corrected — close");
  assert.equal(qualityLabel("corrected", 0.56), "Corrected — fuzzy");
  assert.equal(qualityLabel("corrected", 0.4), "Corrected — loose");
});

/* ── termHitsWords ─────────────────────────────────────────────────────── */

test("termHitsWords is true for an exact hit, false for no words", () => {
  assert.equal(termHitsWords("headless", ["headless", "cms"]), true);
  assert.equal(termHitsWords("headless", []), false);
});

/* ── highlightSegments (text-preservation invariant) ───────────────────── */

test("highlightSegments reconstructs the input text exactly", () => {
  for (const text of ["The headless CMS", "no matches here", "", "a b c d e"]) {
    const segs = highlightSegments(text, ["headless"]);
    assert.equal(segs.map((s) => s.text).join(""), text, `text lost for: ${JSON.stringify(text)}`);
  }
});

test("highlightSegments highlights a matching term and leaves non-matches plain", () => {
  const segs = highlightSegments("The headless CMS", ["headless"]);
  assert.ok(segs.some((s) => s.match && s.text.toLowerCase() === "headless"), "expected a match segment");

  // With no terms, nothing is highlighted.
  const none = highlightSegments("The headless CMS", []);
  assert.ok(none.every((s) => !s.match), "no terms → no highlights");
});
