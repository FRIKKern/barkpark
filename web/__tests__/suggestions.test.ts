/**
 * Tests for the finder's reading of `/api/find?suggest=1` (`lib/suggestions.ts`).
 *
 * THE DEFECT THESE PIN. `app/api/find/route.ts` computes an `error` field for
 * the express purpose of separating "the corpus has no popular queries yet"
 * from "the suggestions endpoint is down" — its own comment says that without
 * it the two "are the same bytes" — and `__tests__/find-suggestions-receipt.test.ts`
 * holds that receipt in place at the route. The route's ONE consumer then read
 * the body through `{ popular?: PopularQuery[] }`, a type that does not declare
 * `error`, and swallowed every transport failure with `.catch(() => {})`.
 *
 * So the receipt was computed, tested, transmitted, and discarded, and the two
 * empties became the same bytes again one layer up.
 *
 * The load-bearing arm here is the LAST one: an answered-and-genuinely-empty
 * corpus and an unreachable endpoint must NOT read the same. Everything else
 * exists so that arm cannot be satisfied by accident.
 *
 * Run: `cd web && node --test --import ./__tests__/support/stub-server-only.mjs __tests__/suggestions.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  POPULAR_CHIP_LIMIT,
  readSuggestions,
  suggestionsNotice,
  suggestionsUnreachable,
} from "../lib/suggestions.ts";

/** The route's answered shape, as `app/api/find/route.ts` builds it. */
function answered(popular: { query: string; count: number }[]) {
  return { popular, nohits: [], error: null };
}

/** The route's degraded shape — 200, empty lists, the upstream's own reason. */
function degraded(reason: string) {
  return { popular: [], nohits: [], error: reason };
}

test("an ANSWERED empty corpus reports error: null — that empty is a fact", () => {
  const out = readSuggestions(answered([]));
  assert.deepEqual(out.popular, []);
  assert.equal(out.error, null);
  assert.equal(suggestionsNotice(out), null, "nothing failed — say nothing");
});

test("a DEGRADED answer keeps the upstream's own reason", () => {
  const out = readSuggestions(degraded("search 503: API is restarting"));
  assert.deepEqual(out.popular, []);
  assert.equal(out.error, "search 503: API is restarting");
  assert.match(suggestionsNotice(out) ?? "", /search 503: API is restarting/);
});

test("an UNREACHABLE fetch builds the same shape, never a silent empty", () => {
  const out = suggestionsUnreachable(new TypeError("Failed to fetch"));
  assert.deepEqual(out.popular, []);
  assert.match(out.error ?? "", /unreachable.*Failed to fetch/);
  assert.ok(suggestionsNotice(out));
});

test("chips are read, trimmed of unusable rows, and capped at the row's width", () => {
  const rows = Array.from({ length: POPULAR_CHIP_LIMIT + 4 }, (_, i) => ({
    query: `q${i}`,
    count: i,
  }));
  const out = readSuggestions(answered(rows));
  assert.equal(out.popular.length, POPULAR_CHIP_LIMIT);
  assert.equal(out.error, null);

  // The pre-existing filter was `.filter((p) => p.query)`; keep refusing the
  // rows it refused, plus whitespace-only, which it would have let through.
  const dirty = readSuggestions({
    popular: [
      { query: "keep", count: 3 },
      { query: "", count: 9 },
      { query: "   ", count: 9 },
      { count: 9 },
      null,
      "nope",
    ],
    error: null,
  });
  assert.deepEqual(
    dirty.popular.map((p) => p.query),
    ["keep"],
  );
});

test("a body we could not read NEVER reports error: null", () => {
  // Reporting null would assert an upstream answer that was never read — the
  // fabrication in the opposite direction, and the same mistake as swallowing.
  for (const junk of [null, undefined, "a string", 42, [1, 2, 3]]) {
    const out = readSuggestions(junk);
    assert.deepEqual(out.popular, [], String(junk));
    assert.notEqual(out.error, null, `${String(junk)} must carry a reason`);
  }
  // A body with a list but no receipt at all (an older route): the list IS the
  // answer, so that one is legitimately null.
  assert.equal(readSuggestions({ popular: [{ query: "a", count: 1 }] }).error, null);
  // …but no list AND no receipt tells us nothing, and must say so.
  assert.notEqual(readSuggestions({}).error, null);
});

test("THE DISTINCTION HOLDS: an empty corpus and a dead endpoint do not read alike", () => {
  // This is the whole point of the route's `error` field, and the assertion the
  // previous consumer could not have made — it never read the field.
  const emptyCorpus = readSuggestions(answered([]));
  const deadEndpoint = readSuggestions(degraded("upstream 500"));
  const noAnswerAtAll = suggestionsUnreachable(new Error("network down"));

  // Identical on the visible half…
  assert.deepEqual(emptyCorpus.popular, deadEndpoint.popular);
  assert.deepEqual(emptyCorpus.popular, noAnswerAtAll.popular);

  // …and distinguishable on the half that says why.
  assert.notDeepEqual(emptyCorpus, deadEndpoint);
  assert.notDeepEqual(emptyCorpus, noAnswerAtAll);
  assert.equal(suggestionsNotice(emptyCorpus), null);
  assert.ok(suggestionsNotice(deadEndpoint));
  assert.ok(suggestionsNotice(noAnswerAtAll));

  // The notice explains the consequence, not just the cause: an operator
  // reading it must not conclude the corpus is quiet.
  assert.match(suggestionsNotice(deadEndpoint) ?? "", /NOT because the corpus/);
});
