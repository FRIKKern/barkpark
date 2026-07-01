/**
 * Tests for the A1 spreadsheet-reference helpers in `sheets.ts` — `parseA1`
 * ("AA12" → 0-based {row,col}) and its inverse `colToLetters` (26 → "AA"). These
 * bijective base-26 conversions are exactly where off-by-one / multi-letter-
 * column bugs hide; the round-trip property below pins them together. Both
 * shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/sheets-a1.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseA1, colToLetters } from "../lib/sheets.ts";

test("parseA1 maps single-letter refs to 0-based row/col", () => {
  assert.deepEqual(parseA1("A1"), { row: 0, col: 0 });
  assert.deepEqual(parseA1("E6"), { row: 5, col: 4 });
  assert.deepEqual(parseA1("Z1"), { row: 0, col: 25 });
});

test("parseA1 handles multi-letter (bijective base-26) columns", () => {
  assert.deepEqual(parseA1("AA12"), { row: 11, col: 26 });
  assert.deepEqual(parseA1("AB1"), { row: 0, col: 27 });
  assert.deepEqual(parseA1("AAA1"), { row: 0, col: 702 });
});

test("parseA1 is case-insensitive and trims whitespace", () => {
  assert.deepEqual(parseA1("a1"), { row: 0, col: 0 });
  assert.deepEqual(parseA1("  c3  "), { row: 2, col: 2 });
});

test("parseA1 returns null for junk keys (so callers skip, not throw)", () => {
  for (const junk of ["A", "1", "", "   ", "A1B", "ABC", "A-1", "1A"]) {
    assert.equal(parseA1(junk), null, `expected null for ${JSON.stringify(junk)}`);
  }
  // Row is 1-based, so row 0 is not a valid reference.
  assert.equal(parseA1("A0"), null);
});

test("colToLetters is the inverse column encoding", () => {
  assert.equal(colToLetters(0), "A");
  assert.equal(colToLetters(25), "Z");
  assert.equal(colToLetters(26), "AA");
  assert.equal(colToLetters(27), "AB");
  assert.equal(colToLetters(701), "ZZ");
  assert.equal(colToLetters(702), "AAA");
});

test("parseA1 ∘ colToLetters round-trips across boundaries", () => {
  for (const c of [0, 1, 25, 26, 27, 51, 52, 675, 676, 701, 702, 1000]) {
    const back = parseA1(`${colToLetters(c)}1`);
    assert.equal(back?.col, c, `round-trip failed at col ${c} (${colToLetters(c)})`);
  }
});
