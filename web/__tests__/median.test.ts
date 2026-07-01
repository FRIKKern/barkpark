/**
 * Tests for the true-median helper used by the engine benchmark table. Runs
 * under Node's built-in test runner (`node --test`), which strips TypeScript
 * types at load time in Node v22+. No external test framework needed.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/median.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { median } from "../lib/median.ts";

test("even-length input averages the two middle elements", () => {
  assert.equal(median([1, 2, 3, 4]), 2.5);
});

test("odd-length input returns the exact middle element", () => {
  assert.equal(median([1, 2, 3]), 2);
});

test("empty input returns 0", () => {
  assert.equal(median([]), 0);
});

test("unsorted input is handled and left unmutated", () => {
  const xs = [4, 1, 3, 2];
  assert.equal(median(xs), 2.5);
  assert.deepEqual(xs, [4, 1, 3, 2]);
});
