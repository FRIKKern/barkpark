/**
 * Tests for `inlineText` — the recursive content → plain-text flattener behind
 * finder titles/excerpts (walks strings, numbers, arrays, and `{value,children}`
 * nodes, then trims). It runs over loosely-typed CMS content, so its guards
 * (null/undefined skipped, `0` kept, children recursed) are load-bearing for
 * every derived snippet. Shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/inline-text.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { inlineText } from "../lib/find.ts";

test("passes through strings and numbers", () => {
  assert.equal(inlineText("hello"), "hello");
  assert.equal(inlineText(42), "42");
});

test("concatenates arrays and recurses into children", () => {
  assert.equal(inlineText(["a", "b"]), "ab");
  assert.equal(inlineText({ value: "hi" }), "hi");
  assert.equal(inlineText({ children: [{ value: "x" }, { value: "y" }] }), "xy");
});

test("flattens a Portable-Text-ish block tree in order", () => {
  const content = [{ value: "Hello " }, { children: [{ value: "world" }] }];
  assert.equal(inlineText(content), "Hello world");
});

test("a node's own value comes before its children", () => {
  assert.equal(inlineText({ value: "V", children: [{ value: "C" }] }), "VC");
});

test("keeps a literal 0 (not undefined/null)", () => {
  assert.equal(inlineText({ value: 0 }), "0");
  assert.equal(inlineText(0), "0");
});

test("skips null / undefined, returns empty string", () => {
  assert.equal(inlineText(null), "");
  assert.equal(inlineText(undefined), "");
  assert.equal(inlineText({ value: null, children: undefined }), "");
});

test("trims the joined result but keeps internal spacing", () => {
  assert.equal(inlineText("  hi  "), "hi");
  assert.equal(inlineText([" hello ", " world "]), "hello  world");
});
