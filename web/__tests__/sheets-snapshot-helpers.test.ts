/**
 * Unit tests for the snapshot-presentation helpers in `lib/sheets.ts`:
 * `looksNumericDisplay` (right-align already-formatted numeric strings) and
 * `truncationNotice` (the "partial data" note for a clipped snapshot). Both are
 * pure; the notice text mirrors the server walker (`Walk.sheet_truncation_note/3`).
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/sheets-snapshot-helpers.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { looksNumericDisplay, truncationNotice } from "../lib/sheets.ts";

test("looksNumericDisplay accepts formatted numeric strings", () => {
  for (const s of ["1,234", "$1,234.50", "25.00%", "-3.5", "1e-7"]) {
    assert.equal(looksNumericDisplay(s), true, `expected ${s} to read numeric`);
  }
});

test("looksNumericDisplay rejects non-numeric text", () => {
  for (const s of ["", "abc", "12 apples", "A1", "1,23"]) {
    assert.equal(looksNumericDisplay(s), false, `expected ${s} to read non-numeric`);
  }
});

test("truncationNotice returns the note for a clipped snapshot", () => {
  assert.equal(
    truncationNotice({ rows: [["a"], ["b"], ["c"]], truncated: true, total_rows: 30000 }),
    "Sheet truncated — showing the first 3 rows",
  );
});

test("truncationNotice returns null when the grid is whole", () => {
  assert.equal(truncationNotice({ rows: [["a"]] }), null);
  assert.equal(truncationNotice({ rows: [["a"]], truncated: false }), null);
});

test("truncationNotice tolerates a missing rows array", () => {
  assert.equal(
    truncationNotice({ truncated: true }),
    "Sheet truncated — showing the first 0 rows",
  );
});
