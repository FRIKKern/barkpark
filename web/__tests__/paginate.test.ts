/**
 * Tests for the REAL pagination loop (`lib/paginate.ts`) that `fetchPapers()`
 * / `fetchPosts()` / `rawListings()` walk `/v1/data/query` with
 * (task-269eefbe4864d8a5). Unlike the normalisation coverage in
 * `listings.test.ts` these are NOT hand-kept mirrors — `paginate.ts` imports
 * nothing, so `node --test` loads the shipped code directly.
 *
 * Ported verbatim (same law, same mutant set) from
 * `apps/hundesteder/__tests__/paginate.test.ts` (PR #13316), the second
 * instance of this fix — this is the third, same shape.
 *
 * The defect class under pin: `fetchPapers()` issued ONE query with a fixed
 * `.limit(50)` and no offset, and 118 papers live in prod today — 68 papers
 * silently missing from `/papers`, `sitemap.xml`, and `feed.xml`. NAMED
 * MUTANTS each test kills:
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
  const out = await collectAllPages(corpusFetcher(118, calls), {
    limit: 50,
    maxPages: 20,
  });
  // The exact live-prod shape from the brief: 118 papers, limit(50) used to
  // truncate at 50 — NOT 50 here, the single-page mutant reds on this line.
  assert.equal(out.rows.length, 118);
  assert.equal(out.truncated, undefined);
  assert.deepEqual(calls, [
    [50, 0],
    [50, 50],
    [50, 100], // short page (18) — the walk stops, no 4th call
  ]);
});

test("a corpus exactly divisible by the page size terminates on the empty page, not forever", async () => {
  const calls: Array<[number, number]> = [];
  const out = await collectAllPages(corpusFetcher(100, calls), {
    limit: 50,
    maxPages: 20,
  });
  assert.equal(out.rows.length, 100);
  assert.equal(out.truncated, undefined);
  assert.equal(calls.length, 3); // the third page is [] — short — end
});

test("the offset advances by the RAW page length, so the cursor never stalls", async () => {
  const calls: Array<[number, number]> = [];
  await collectAllPages(corpusFetcher(75, calls), { limit: 50, maxPages: 20 });
  assert.deepEqual(
    calls.map(([, offset]) => offset),
    [0, 50],
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
