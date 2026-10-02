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
 *
 * THE SECOND DEFECT (task-a5b10e7a686e37bb), ported from
 * `web/__tests__/paginate.test.ts` (PR #13657): the short-page inference is
 * only sound while the server honours the requested `limit`, and it does not —
 * it clamps to 1000. Everything below the `THE SECOND DEFECT` banner pins the
 * clamp, the exact `hasMore`/`nextOffset` termination, and the `no_advance`
 * state. NAMED MUTANTS those add:
 *   • no-clamp                  → the clamp test reds (1000 of 2500 rows)
 *   • ignore-hasMore            → the full-page-hasMore:false test reds (2 calls)
 *   • ignore-nextOffset         → the cursor test reds ([0, 2] not [0, 7])
 *   • advance-past-the-clamp    → the no_advance test reds (5 calls, 'cap')
 *
 * WHY A LIMIT ABOVE 1000 AT ALL, when `places.ts` passes exactly
 * `PLACES_PAGE_LIMIT = 1000`: because that coincidence is the ONLY thing that
 * made this edition safe. The guard is caller-INDEPENDENT, so the test that
 * proves it must ask for more than the ceiling — a test pinned at 1000 is
 * vacuous and would stay green through the exact edit (raising the constant)
 * that reintroduces the defect.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  collectAllPages,
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

/* ── THE SECOND DEFECT: a server-clamped page read as an exhausted one ────── */

/**
 * A fake corpus behind a server that CLAMPS every page to `serverMax`, exactly
 * as `query_controller.ex` does — the shape the old law could not survive.
 */
function clampingFetcher(
  total: number,
  serverMax: number,
  calls: Array<[number, number]>,
) {
  const rows = Array.from({ length: total }, (_, i) => ({ i }));
  return async (limit: number, offset: number): Promise<unknown[] | null> => {
    calls.push([limit, offset]);
    return rows.slice(offset, offset + Math.min(limit, serverMax));
  };
}

/** The law as this edition shipped it before task-a5b10e7a686e37bb, kept here
 * so the defect is DEMONSTRATED rather than asserted about. */
async function preFixLaw(
  fetchPage: (limit: number, offset: number) => Promise<unknown[] | null>,
  { limit, maxPages }: { limit: number; maxPages: number },
): Promise<{ rows: unknown[]; truncated?: string }> {
  const rows: unknown[] = [];
  let offset = 0;
  for (let page = 0; page < maxPages; page++) {
    const batch = await fetchPage(limit, offset);
    if (batch === null) {
      return page === 0 ? { rows } : { rows, truncated: "failed_page" };
    }
    rows.push(...batch);
    if (batch.length < limit) return { rows };
    offset += batch.length;
  }
  return { rows, truncated: "cap" };
}

test("THE DEFECT: the pre-fix law called a server-clamped page an exhausted one", async () => {
  const calls: Array<[number, number]> = [];
  const out = await preFixLaw(clampingFetcher(2500, 1000, calls), {
    limit: 2500,
    maxPages: 20,
  });
  assert.equal(out.rows.length, 1000); // a silent 60% prefix
  assert.equal(out.truncated, undefined); // and it reported CLEAN exhaustion
  assert.equal(calls.length, 1); // one request, then it stopped
});

test("THE ROW: a limit past the ceiling is clamped, the walk warns, and the WHOLE corpus arrives", async () => {
  __resetPaginateWarnings();
  const warnings: string[] = [];
  const orig = console.warn;
  console.warn = (msg: string) => warnings.push(String(msg));
  let out: { rows: unknown[]; truncated?: string };
  const calls: Array<[number, number]> = [];
  try {
    // PLACES_PAGE_LIMIT is 1000 today; 2500 is the edit that used to be fatal.
    out = await collectAllPages(clampingFetcher(2500, 1000, calls), {
      limit: 2500,
      maxPages: 20,
    });
  } finally {
    console.warn = orig;
  }
  // The no-clamp mutant reds here with 1000 — the silent prefix.
  assert.equal(out.rows.length, 2500);
  assert.equal(out.truncated, undefined);
  // Every request went out at the ceiling, never above it.
  assert.deepEqual(calls, [
    [1000, 0],
    [1000, 1000],
    [1000, 2000], // short page (500) — genuinely the end now
  ]);
  // …and the substitution was SAID, naming both numbers.
  assert.equal(warnings.length, 1, "once per process, not once per page");
  assert.match(warnings[0], /2500/);
  assert.match(warnings[0], /1000/);
});

test("a limit AT the ceiling is silent — the value places.ts already passes", async () => {
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

test("the ceiling matches the controller's clamp — drift here is the whole defect", () => {
  // query_controller.ex: limit = parse_int(params["limit"], 100) |> min(1000) |> max(1)
  // A ceiling set ABOVE the server's clamp puts the silent-prefix defect back.
  assert.equal(SERVER_MAX_PAGE_LIMIT, 1000);
});

test("hasMore:false ends the walk on a FULL page — no wasted probe request", async () => {
  let callCount = 0;
  const out = await collectAllPages(
    async (limit) => {
      callCount++;
      return { rows: Array.from({ length: limit }, (_, i) => ({ i })), hasMore: false };
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(callCount, 1); // ignore-hasMore reds here with 2
  assert.equal(out.rows.length, 10);
  assert.equal(out.truncated, undefined); // exhausted, and it KNOWS
});

test("a SHORT page carrying hasMore:true keeps walking — length is no longer the oracle", async () => {
  const calls: Array<[number, number]> = [];
  const out = await collectAllPages(
    async (limit, offset) => {
      calls.push([limit, offset]);
      if (offset === 0) return { rows: [{ i: 0 }, { i: 1 }], hasMore: true, nextOffset: 2 };
      return { rows: [{ i: 2 }], hasMore: false };
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(out.rows.length, 3); // terminate-on-length reds here with 2
  assert.equal(out.truncated, undefined);
  assert.equal(calls.length, 2);
});

test("nextOffset drives the cursor when the server supplies it", async () => {
  const calls: Array<[number, number]> = [];
  await collectAllPages(
    async (limit, offset) => {
      calls.push([limit, offset]);
      // A cursor that does NOT equal offset + rows.length: only a walk that
      // honours nextOffset lands on 7.
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
  // nextOffset because a further read re-serves this same page.
  let callCount = 0;
  const out = await collectAllPages(
    async (limit) => {
      callCount++;
      return { rows: Array.from({ length: limit }, (_, i) => ({ i })), hasMore: true };
    },
    { limit: 10, maxPages: 5 },
  );
  assert.equal(callCount, 1); // advance-past-the-clamp reds here with 5
  assert.equal(out.rows.length, 10); // …and would have collected 50 DUPLICATE rows
  assert.equal(out.truncated, "no_advance"); // partial truth, NAMED
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

test("places.ts hands the walk the RICH page, so the exact signal is not thrown away", () => {
  // `places.ts` imports `server-only` and cannot be loaded by this dep-free
  // job, so the wiring is asserted from SOURCE — the same technique the astro
  // edition uses on `bp.ts`. Without this, every test above could pass while
  // `fetchPlaces()` kept discarding `hasMore`/`nextOffset` at the call site,
  // which would leave the exact-termination law unreachable in production.
  const raw = readFileSync(
    fileURLToPath(new URL("../lib/places.ts", import.meta.url)),
    "utf8",
  );
  const src = raw.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^[ \t]*\/\/.*$/gm, "");
  const body = src.slice(src.indexOf("export async function fetchPlaces"));
  assert.ok(body.startsWith("export async function fetchPlaces"));
  assert.match(body, /hasMore/, "fetchPlaces must forward result.hasMore to the walk");
  assert.match(body, /nextOffset/, "fetchPlaces must forward result.nextOffset to the walk");
});
