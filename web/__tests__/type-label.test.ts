/**
 * Tests for `typeLabel` — maps a content-type slug to its human display label
 * (used in finder facets / type chips), falling back to the raw slug for an
 * unregistered type. The last untested pure export in `find.ts`.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/type-label.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { typeLabel } from "../lib/find.ts";

test("maps registered types to their display labels", () => {
  assert.equal(typeLabel("post"), "Posts");
  assert.equal(typeLabel("paper"), "Papers");
  assert.equal(typeLabel("sheet"), "Sheets");
  assert.equal(typeLabel("author"), "Authors");
});

test("falls back to the raw slug for an unregistered type", () => {
  assert.equal(typeLabel("widget"), "widget");
  assert.equal(typeLabel(""), "");
});
