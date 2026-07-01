/**
 * Tests for `shapeFindResponse` — the pure `upstream JSON → FindResponse`
 * assembler that BOTH the HTTP route and the live WebSocket path feed, so the
 * two transports render byte-identically. It owns the mode/browse split, the
 * indx-downgrade flag, count/ms fallbacks, and the loose type guards on the
 * upstream payload. Shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/find-shape.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { shapeFindResponse, emptyParsed, type UpstreamSearchJson } from "../lib/find-shape.ts";

const args = (over: Record<string, unknown> = {}) => ({
  engine: "postgres" as const,
  engineUsed: "postgres" as const,
  browse: false,
  cache: false,
  upstreamMs: 10,
  ...over,
});

test("shapes a basic search payload", () => {
  const r = shapeFindResponse(
    { documents: [{ _id: "p1", _type: "post" }], count: 1, ms: 5 },
    args(),
  );
  assert.equal(r.mode, "search");
  assert.equal(r.hits.length, 1);
  assert.equal(r.total, 1);
  assert.equal(r.ms, 5);
  assert.equal(r.upstreamMs, 10);
  assert.equal(r.error, null);
  assert.equal(r.indxUnavailable, false);
});

test("browse mode forces mode=browse and parsedQuery=null", () => {
  const r = shapeFindResponse(
    { documents: [], parsedQuery: { terms: ["x"], phrases: [], excludes: [], prefixes: [] } },
    args({ browse: true }),
  );
  assert.equal(r.mode, "browse");
  assert.equal(r.parsedQuery, null);
});

test("search mode defaults parsedQuery to emptyParsed when absent", () => {
  const r = shapeFindResponse({ documents: [] }, args());
  assert.deepEqual(r.parsedQuery, emptyParsed());
});

test("total falls back to the hit count when no count is reported", () => {
  const r = shapeFindResponse(
    { documents: [{ _id: "a", _type: "post" }, { _id: "b", _type: "post" }] },
    args(),
  );
  assert.equal(r.total, 2);
});

test("indxUnavailable is set only when indx was asked for but not served", () => {
  assert.equal(shapeFindResponse({}, args({ engine: "indx", engineUsed: "postgres" })).indxUnavailable, true);
  assert.equal(shapeFindResponse({}, args({ engine: "indx", engineUsed: "indx" })).indxUnavailable, false);
  assert.equal(shapeFindResponse({}, args({ engine: "postgres", engineUsed: "postgres" })).indxUnavailable, false);
});

test("filters out documents that don't normalize", () => {
  const r = shapeFindResponse(
    { documents: [{ _id: "p1", _type: "post" }, { junk: true }, null] },
    args(),
  );
  assert.equal(r.hits.length, 1);
});

test("loose upstream fields are type-guarded (bad ms/searchEventId → null)", () => {
  // Deliberately malformed upstream (wrong types) to exercise the runtime
  // guards; cast past the compile-time shape since that's the whole point.
  const r = shapeFindResponse(
    { documents: [], ms: "10", searchEventId: 42, correctedTo: null } as unknown as UpstreamSearchJson,
    args(),
  );
  assert.equal(r.ms, null); // string ms is not a number
  assert.equal(r.searchEventId, null); // non-string
  assert.equal(r.correctedTo, null);
});

test("recovery/facets/truncation default to null when absent", () => {
  const r = shapeFindResponse({ documents: [] }, args());
  assert.equal(r.recovery, null);
  assert.equal(r.facets, null);
  assert.equal(r.truncation, null);
});
