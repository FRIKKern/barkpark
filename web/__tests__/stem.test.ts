/**
 * Tests for `stem.ts` — the shared conservative token stemmer every client
 * matcher (fuzzy highlighter, did-you-mean) leans on, so its exact behaviour is
 * load-bearing for match strength AND ranking agreement. It's deliberately
 * LESS aggressive than Snowball: possessives + simple plurals only, keeping
 * `-ss` / vowel-`s` / a non-plural blocklist intact. This locks each documented
 * rule; it shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/stem.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { stemToken, queryStems } from "../lib/stem.ts";

test("strips possessives (straight and curly apostrophes)", () => {
  assert.equal(stemToken("operator's"), "operator");
  assert.equal(stemToken("operator’s"), "operator"); // curly ’
  // Plural possessive: strip `'` → "devs", then the plural rule → "dev".
  assert.equal(stemToken("devs'"), "dev");
});

test("consonant + ies → y", () => {
  assert.equal(stemToken("companies"), "company");
  assert.equal(stemToken("libraries"), "library");
});

test("sibilant + es drops just the es", () => {
  assert.equal(stemToken("boxes"), "box");
  assert.equal(stemToken("classes"), "class");
  assert.equal(stemToken("watches"), "watch");
  assert.equal(stemToken("dishes"), "dish");
});

test("keeps -ss and vowel+s words intact (no foot-gun folding)", () => {
  assert.equal(stemToken("class"), "class");
  assert.equal(stemToken("process"), "process");
  assert.equal(stemToken("analysis"), "analysis");
  assert.equal(stemToken("basis"), "basis");
});

test("folds simple plurals", () => {
  assert.equal(stemToken("operators"), "operator");
  assert.equal(stemToken("docs"), "doc");
  assert.equal(stemToken("cats"), "cat");
});

test("leaves the non-plural -s blocklist alone", () => {
  assert.equal(stemToken("news"), "news");
  assert.equal(stemToken("series"), "series");
  assert.equal(stemToken("always"), "always");
});

test("short words pass through unchanged", () => {
  assert.equal(stemToken("cat"), "cat");
  assert.equal(stemToken("bus"), "bus");
});

test("a singular and its plural stem to the same token", () => {
  assert.equal(stemToken("company"), stemToken("companies"));
  assert.equal(stemToken("operator"), stemToken("operators"));
});

test("queryStems dedups and drops empties", () => {
  const s = queryStems(["cats", "cat", "docs", ""]);
  assert.deepEqual([...s].sort(), ["cat", "doc"]);
});
