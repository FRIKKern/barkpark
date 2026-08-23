/**
 * Tests for the REAL pagination loop (`lib/paginate.ts`) that `fetchPlaces()`
 * walks the query API with (task-32a7f8c07041d4d6). Unlike the normalisation
 * coverage in places.test.ts these are NOT hand-kept mirrors — paginate.ts
 * imports nothing, so `node --test` loads the shipped code.
 *
 * The defect class under pin (the chat roster's sibling,
 * task-35e4fa473743f866): the old fetchPlaces issued ONE query with no
 * limit/offset, and the server's default limit of 100 silently truncated any
 * corpus past 100 published places. NAMED MUTANTS each test kills:
 *   • single-page-only          → the multi-page test reds (rows lost)
 *   • advance-by-filtered-count → the raw-advance test reds (cursor stalls)
 *   • no-cap                    → the cap test never terminates / reds
 *   • swallow-failed-page       → the mid-walk failure test reds (no flag)
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { collectAllPages } from "../lib/paginate.ts";

/** A fake corpus served in pages of `limit`, counting the calls. */
function corpusFetcher(total: number, calls: Array<[number, number]>) {
  const rows = Array.from({ length: total }, (_, i) => ({ i }));
  return async (limit: number, offset: number): Promise<unknown[] | null> => {
    calls.push([limit, offset]);
    return rows.slice(offset, offset + limit);
  };
}

test("walks every page and terminates on the short page", async () => {
  const calls: Array<[number, number]> = [];
  const out = await collectAllPages(corpusFetcher(2503, calls), {
    limit: 1000,
    maxPages: 20,
  });
  assert.equal(out.rows.length, 2503); // NOT 1000 — the single-page mutant reds here
  assert.equal(out.truncated, undefined);
  assert.deepEqual(calls, [
    [1000, 0],
    [1000, 1000],
    [1000, 2000], // short page (503) — the walk stops, no 4th call
  ]);
});

test("a corpus exactly divisible by the page size terminates on the empty page, not forever", async () => {
  const calls: Array<[number, number]> = [];
  const out = await collectAllPages(corpusFetcher(2000, calls), {
    limit: 1000,
    maxPages: 20,
  });
  assert.equal(out.rows.length, 2000);
  assert.equal(out.truncated, undefined);
  assert.equal(calls.length, 3); // the third page is [] — short — end
});

test("the offset advances by the RAW page length, so the cursor never stalls", async () => {
  const calls: Array<[number, number]> = [];
  await collectAllPages(corpusFetcher(1500, calls), { limit: 1000, maxPages: 20 });
  assert.deepEqual(
    calls.map(([, offset]) => offset),
    [0, 1000],
  );
});

test("an upstream that always returns full pages hits the cap and SAYS so", async () => {
  // The roster lesson verbatim: termination must not depend on upstream
  // good behaviour. This fetcher never serves a short page.
  let callCount = 0;
  const out = await collectAllPages(
    async (limit) => {
      callCount++;
      return Array.from({ length: limit }, (_, i) => ({ i }));
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(callCount, 5); // bounded — the no-cap mutant never gets here
  assert.equal(out.rows.length, 50);
  assert.equal(out.truncated, "cap"); // truncation is REPORTED, never silent
});

test("a failed page mid-walk returns the collected rows flagged, never throws", async () => {
  const out = await collectAllPages(
    async (limit, offset) =>
      offset === 0 ? Array.from({ length: limit }, (_, i) => ({ i })) : null,
    { limit: 10, maxPages: 5 },
  );
  assert.equal(out.rows.length, 10);
  assert.equal(out.truncated, "failed_page");
});

test("a failed FIRST page is the existing degrade-to-empty, not a truncation claim", async () => {
  const out = await collectAllPages(async () => null, { limit: 10, maxPages: 5 });
  assert.deepEqual(out, { rows: [] }); // no flag: there is no partial truth to disclaim
});
