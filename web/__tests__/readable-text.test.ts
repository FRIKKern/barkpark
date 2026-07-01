/**
 * Tests for the sheet-cell contrast helper. Runs under Node's built-in test
 * runner (`node --test`), which strips TypeScript types at load time in Node
 * v22+. No external test framework needed.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/readable-text.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readableText } from "../lib/readable-text.ts";

test("dark hex background gets light text", () => {
  assert.equal(readableText("#111827"), "#f5f5f5");
});

test("light hex background gets dark text", () => {
  assert.equal(readableText("#fde68a"), "#111");
});

test("rgb() black gets light text", () => {
  assert.equal(readableText("rgb(0,0,0)"), "#f5f5f5");
});

test("rgba() white gets dark text", () => {
  assert.equal(readableText("rgba(255, 255, 255, 0.5)"), "#111");
});

test("shorthand hex is parsed", () => {
  assert.equal(readableText("#fff"), "#111");
});

test("unparseable input returns undefined", () => {
  assert.equal(readableText("garbage"), undefined);
  assert.equal(readableText(""), undefined);
});
