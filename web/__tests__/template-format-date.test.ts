/**
 * Locks the S4 template render-robustness fixes for create-barkpark-app.
 *
 * 1. `formatDate` (shipped as `lib/format-date.ts` in BOTH the blog-starter and
 *    website-starter scaffolds) must return `null` for absent AND malformed-but-
 *    truthy inputs, so the literal `"Invalid Date"` can never reach the UI. We
 *    import the real blog-starter helper — the website-starter copy is byte-
 *    identical (drift-guarded by the cloud-templates-sync diff in the gate).
 *
 * 2. The blog home page derives its page number as
 *    `Math.max(1, Math.floor(Number(sp.page ?? '1') || 1))`. Re-derived here to
 *    prove a fractional/garbage `?page` can no longer produce a fractional offset
 *    into getDocs/API.
 *
 * Run: `cd web && node --test --test-reporter=tap \
 *   --import ./__tests__/support/stub-server-only.mjs \
 *   __tests__/template-format-date.test.ts`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { formatDate } from "../../js/packages/create-barkpark-app/templates/_shared/lib/format-date.ts";

test("formatDate returns null for undefined / empty string", () => {
  assert.equal(formatDate(undefined), null);
  assert.equal(formatDate(""), null);
});

test("formatDate returns null for a malformed-but-truthy value (no 'Invalid Date')", () => {
  assert.equal(formatDate("not-a-date"), null);
  assert.equal(formatDate("2026-13-99"), null);
});

test("formatDate returns a non-empty string for a valid ISO date", () => {
  const out = formatDate("2026-08-18T12:00:00.000Z");
  assert.equal(typeof out, "string");
  assert.ok((out as string).length > 0);
  assert.notEqual(out, "Invalid Date");
});

// Mirrors blog-starter/app/page.tsx's page-number derivation exactly.
function pageNum(raw?: string): number {
  return Math.max(1, Math.floor(Number(raw ?? "1") || 1));
}

test("page number floors fractional / garbage / out-of-range ?page to an integer >= 1", () => {
  for (const [input, expected] of [
    ["2.5", 2],
    ["abc", 1],
    ["-3", 1],
    ["0", 1],
    ["3", 3],
    [undefined, 1],
  ] as Array<[string | undefined, number]>) {
    const n = pageNum(input);
    assert.equal(Number.isInteger(n), true, `pageNum(${String(input)}) must be an integer`);
    assert.equal(n, expected, `pageNum(${String(input)}) === ${expected}`);
  }
});
