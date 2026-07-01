/**
 * Tests for `bp-tags.ts` — the Next cache-tag builders that connect reader/
 * finder caches to webhook revalidation. The exact string format MUST match the
 * webhook wire contract (`bp:ds:<dataset>:_all` / `:type:<type>`); a drift here
 * silently breaks cache-busting (a published change stops invalidating reads).
 * Load-bearing and shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/bp-tags.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { bpAll, bpType, DATASET } from "../lib/bp-tags.ts";

test("bpAll builds the dataset-wide tag", () => {
  assert.equal(bpAll("docs"), "bp:ds:docs:_all");
  assert.equal(bpAll("production"), "bp:ds:production:_all");
});

test("bpType builds the per-type tag", () => {
  assert.equal(bpType("post", "docs"), "bp:ds:docs:type:post");
  assert.equal(bpType("author", "production"), "bp:ds:production:type:author");
});

test("both default to the configured DATASET", () => {
  assert.equal(bpAll(), `bp:ds:${DATASET}:_all`);
  assert.equal(bpType("post"), `bp:ds:${DATASET}:type:post`);
});

test("DATASET is a non-empty string (env override or 'docs' default)", () => {
  assert.equal(typeof DATASET, "string");
  assert.ok(DATASET.length > 0);
});
