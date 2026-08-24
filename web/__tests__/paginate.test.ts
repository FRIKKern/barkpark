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
import {
  collectAllPages,
  readQueryPage,
  SERVER_MAX_PAGE_LIMIT,
  __resetPaginateWarnings,
} from "../lib/paginate.ts";

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

/* ── the clamped-page defect (task-6eb2d810605b1a41) ─────────────────────────
 *
 * The law above inferred exhaustion from page LENGTH. That is only sound while
 * the server honours the requested `limit` — and it does not: the query
 * controller clamps it to at most 1000
 * (`api/lib/barkpark_web/controllers/query_controller.ex:29`). A caller asking
 * for pages of 2500 was handed 1000 rows, read `1000 < 2500` as the end, and
 * reported a CLEAN termination over a 1000-row prefix. NAMED MUTANTS the tests
 * below kill:
 *   • no-clamp                → the clamped-corpus test reds (1500 rows lost)
 *   • terminate-on-length     → the `hasMore: true` short-page test reds
 *   • ignore-hasMore          → the full-page-hasMore-false test reds (extra call)
 *   • ignore-nextOffset       → the server-cursor test reds (wrong offsets)
 *   • advance-past-the-clamp  → the withheld-nextOffset test spins to the cap
 */

/** An upstream that behaves like the real one: it CLAMPS the requested limit
 * to `serverMax` and never says so, exactly as query_controller.ex:29 does. */
function clampingFetcher(
  total: number,
  serverMax: number,
  calls: Array<[number, number]>,
) {
  const all = Array.from({ length: total }, (_, i) => ({ i }));
  return async (limit: number, offset: number): Promise<unknown[]> => {
    calls.push([limit, offset]);
    const served = Math.min(limit, serverMax);
    return all.slice(offset, offset + served);
  };
}

/** The law as it stood BEFORE this fix, kept as a permanent witness: it is the
 * reason the clamp guard exists. Terminates on page length, nothing else. */
async function preFixLaw(
  fetchPage: (limit: number, offset: number) => Promise<unknown[] | null>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<{ rows: unknown[]; truncated?: string }> {
  const rows: unknown[] = [];
  let offset = 0;
  for (let page = 0; page < maxPages; page++) {
    const batch = await fetchPage(limit, offset);
    if (batch === null) return page === 0 ? { rows } : { rows, truncated: "failed_page" };
    rows.push(...batch);
    if (batch.length < limit) return { rows };
    offset += batch.length;
  }
  return { rows, truncated: "cap" };
}

test("THE DEFECT: the pre-fix law called a server-clamped page an exhausted one", async () => {
  // 2500 rows behind a server that clamps every page to 1000. The old law
  // asked for 2500, got 1000, and called it the end — with NO truncation flag.
  const calls: Array<[number, number]> = [];
  const out = await preFixLaw(clampingFetcher(2500, 1000, calls), {
    limit: 2500,
    maxPages: 20,
  });
  assert.equal(out.rows.length, 1000); // a silent 60% prefix
  assert.equal(out.truncated, undefined); // and it reported CLEAN exhaustion
  assert.equal(calls.length, 1); // one request, then it stopped
});

test("the requested limit is clamped to the server ceiling, so the whole corpus arrives", async () => {
  __resetPaginateWarnings();
  const calls: Array<[number, number]> = [];
  const out = await collectAllPages(clampingFetcher(2500, 1000, calls), {
    limit: 2500,
    maxPages: 20,
  });
  // The no-clamp mutant reds here with 1000.
  assert.equal(out.rows.length, 2500);
  assert.equal(out.truncated, undefined);
  // Every request went out at the ceiling, never above it.
  assert.deepEqual(calls, [
    [1000, 0],
    [1000, 1000],
    [1000, 2000], // short page (500) — genuinely the end now
  ]);
});

test("asking above the ceiling warns ONCE, naming both numbers", async () => {
  __resetPaginateWarnings();
  const warnings: string[] = [];
  const orig = console.warn;
  console.warn = (msg: string) => warnings.push(String(msg));
  try {
    await collectAllPages(clampingFetcher(2500, 1000, []), { limit: 2500, maxPages: 20 });
    await collectAllPages(clampingFetcher(2500, 1000, []), { limit: 2500, maxPages: 20 });
  } finally {
    console.warn = orig;
  }
  assert.equal(warnings.length, 1); // once per process, not once per page
  assert.match(warnings[0], /2500/);
  assert.match(warnings[0], /1000/);
});

test("a limit AT the ceiling is silent — the value papers.ts/posts.ts already pass", async () => {
  __resetPaginateWarnings();
  const warnings: string[] = [];
  const orig = console.warn;
  console.warn = (msg: string) => warnings.push(String(msg));
  try {
    const out = await collectAllPages(clampingFetcher(2500, 1000, []), {
      limit: 1000,
      maxPages: 20,
    });
    assert.equal(out.rows.length, 2500);
  } finally {
    console.warn = orig;
  }
  assert.deepEqual(warnings, []); // no false alarm on the correct call
});

test("hasMore:false ends the walk on a FULL page — no wasted probe request", async () => {
  // Without the exact signal, a full page forces one more request to discover
  // the end. With it, the walk stops knowing. The ignore-hasMore mutant makes
  // a second call and reds on callCount.
  let callCount = 0;
  const out = await collectAllPages(
    async (limit) => {
      callCount++;
      return { rows: Array.from({ length: limit }, (_, i) => ({ i })), hasMore: false };
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(callCount, 1);
  assert.equal(out.rows.length, 10);
  assert.equal(out.truncated, undefined); // exhausted, and it KNOWS
});

test("a SHORT page carrying hasMore:true keeps walking — length is no longer the oracle", async () => {
  // The exactness case the length inference can never get right: a server free
  // to serve fewer rows than asked while more remain.
  const calls: Array<[number, number]> = [];
  const out = await collectAllPages(
    async (limit, offset) => {
      calls.push([limit, offset]);
      if (offset === 0) return { rows: [{ i: 0 }, { i: 1 }], hasMore: true, nextOffset: 2 };
      return { rows: [{ i: 2 }], hasMore: false };
    },
    { limit: 10, maxPages: 5 },
  );
  // terminate-on-length reds here with 2 rows and one call.
  assert.equal(out.rows.length, 3);
  assert.equal(out.truncated, undefined);
  assert.equal(calls.length, 2);
});

test("nextOffset drives the cursor when the server supplies it", async () => {
  const calls: Array<[number, number]> = [];
  await collectAllPages(
    async (limit, offset) => {
      calls.push([limit, offset]);
      // A server whose cursor does NOT equal offset + rows.length: only a walk
      // that honours nextOffset lands on 7.
      if (offset === 0) return { rows: [{ i: 0 }, { i: 1 }], hasMore: true, nextOffset: 7 };
      return { rows: [], hasMore: false };
    },
    { limit: 10, maxPages: 5 },
  );
  assert.deepEqual(
    calls.map(([, offset]) => offset),
    [0, 7], // ignore-nextOffset reds with [0, 2]
  );
});

test("hasMore with NO nextOffset stops and says no_advance — it never spins on the clamp", async () => {
  // The real shape past the 100_000 offset ceiling: the controller withholds
  // nextOffset because a further read re-serves this same page
  // (query_controller.ex maybe_put_next_offset/4).
  let callCount = 0;
  const out = await collectAllPages(
    async (limit) => {
      callCount++;
      return { rows: Array.from({ length: limit }, (_, i) => ({ i })), hasMore: true };
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(callCount, 1); // advance-past-the-clamp reds here with 5
  assert.equal(out.rows.length, 10);
  assert.equal(out.truncated, "no_advance"); // partial truth, named
});

test("an EMPTY page claiming hasMore cannot loop forever", async () => {
  let callCount = 0;
  const out = await collectAllPages(
    async () => {
      callCount++;
      return { rows: [], hasMore: true, nextOffset: 0 }; // a cursor that never moves
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(callCount, 1);
  assert.deepEqual(out, { rows: [], truncated: "no_advance" });
});

test("the ceiling matches the controller's clamp — drift here is the whole defect", async () => {
  // api/lib/barkpark_web/controllers/query_controller.ex:29
  //   limit = parse_int(params["limit"], 100) |> min(1000) |> max(1)
  // If that number ever moves, this constant must move with it: a ceiling set
  // ABOVE the server's clamp puts the silent-prefix defect straight back.
  assert.equal(SERVER_MAX_PAGE_LIMIT, 1000);
});

/* ── the envelope reader, and the listings walk end to end ────────────────── */

test("readQueryPage lifts hasMore and nextOffset off the real query envelope", () => {
  // The shape query_controller.ex:120-131 actually emits.
  const page = readQueryPage({
    result: {
      perspective: "published",
      documents: [{ _id: "a" }, { _id: "b" }],
      count: 2,
      limit: 1000,
      offset: 0,
      hasMore: true,
      nextOffset: 1000,
    },
  });
  assert.deepEqual(page, {
    rows: [{ _id: "a" }, { _id: "b" }],
    hasMore: true,
    nextOffset: 1000,
  });
});

test("readQueryPage keeps hasMore:false — the exhausted answer is not the same as no answer", () => {
  const page = readQueryPage({ result: { documents: [{ _id: "a" }], hasMore: false } });
  assert.equal(page.hasMore, false); // dropping this reintroduces the guessing
  assert.equal(page.nextOffset, undefined); // withheld when no next page exists
});

test("readQueryPage tolerates the shapes the walkers already accepted", () => {
  // Bare array and un-nested envelope: rows, but no signal — the walk then
  // falls back to the short-page test, which the clamp has made sound again.
  assert.deepEqual(readQueryPage([{ _id: "a" }]), { rows: [{ _id: "a" }] });
  assert.deepEqual(readQueryPage({ documents: [{ _id: "a" }] }), { rows: [{ _id: "a" }] });
  assert.deepEqual(readQueryPage({}), { rows: [] });
  assert.deepEqual(readQueryPage(null), { rows: [] });
  // A non-array `documents` must not become the rows.
  assert.deepEqual(readQueryPage({ result: { documents: "nope" } }), { rows: [] });
});

test("THE LISTINGS PATH end to end: an over-large LISTINGS_LIMIT no longer truncates", async () => {
  // Everything the real `rawListings` walk does except the HTTP call: a server
  // that clamps `limit` to 1000 and emits the real envelope, read by the real
  // `readQueryPage`, walked by the real `collectAllPages`.
  // `LISTINGS_LIMIT=2000` is the reachable case — it is read from the env with
  // no upper bound (web/lib/listings.ts).
  __resetPaginateWarnings();
  const SERVER_CLAMP = 1000;
  const corpus = Array.from({ length: 2500 }, (_, i) => ({ _id: `listing-${i}` }));
  const requested: number[] = [];

  const out = await collectAllPages(
    async (limit, offset) => {
      requested.push(limit);
      const served = Math.min(limit, SERVER_CLAMP);
      const documents = corpus.slice(offset, offset + served);
      const hasMore = offset + documents.length < corpus.length;
      return readQueryPage({
        result: {
          documents,
          count: documents.length,
          limit: served,
          offset,
          hasMore,
          ...(hasMore ? { nextOffset: offset + served } : {}),
        },
      });
    },
    { limit: 2000, maxPages: 20 },
  );

  assert.equal(out.rows.length, 2500); // every pin, not the first 1000
  assert.equal(out.truncated, undefined); // and the walk is honestly clean
  assert.deepEqual(requested, [1000, 1000, 1000]); // never asked above the ceiling
});
