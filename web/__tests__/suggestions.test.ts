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
  curatePopularQueries,
  POPULAR_CHIP_LIMIT,
  POPULAR_CHIP_MAX_CHARS,
  POPULAR_CHIP_MAX_WORDS,
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

/* ── curation ───────────────────────────────────────────────────────────────
 *
 * THE SECOND DEFECT THESE PIN. This module CAPPED the chip row at six and never
 * CURATED it, while the search-starter fork it mirrors filters machine exhaust
 * out of the same pool. So a whole-sentence agent probe, or a near-duplicate
 * differing only in case, could occupy one of the six visible slots.
 *
 * EVERY ARM BELOW MUST FAIL AGAINST A CAP-ONLY IMPLEMENTATION. A curation test
 * that a cap alone can satisfy is a test of the cap. Each arm therefore feeds
 * FEWER than POPULAR_CHIP_LIMIT rows, or asserts an output the cap cannot
 * produce, so `.slice(0, 6)` cannot pass it.
 * ------------------------------------------------------------------------- */

const q = (query: string, count = 1) => ({ query, count });

/**
 * FIXTURE — the shape of a real popular pool, in rank order.
 * "research coverage ledger" is agent exhaust: a three-word internal phrase
 * that shipped as a tappable chip promising it was a search worth trying.
 * Six rows in, five out: the cap is inert here, so only curation can move it.
 */
const LIVE_POOL = [
  q("deploy", 41),
  q("research coverage ledger", 33),
  q("task", 22),
  q("search", 19),
  q("barkpark", 15),
  q("theme", 11),
];

test("a whole-sentence agent probe is DROPPED, and rank order survives", () => {
  // Input length is exactly POPULAR_CHIP_LIMIT, so a cap-only reader returns
  // all six unchanged and fails this deepEqual on the missing exhaust row.
  assert.equal(LIVE_POOL.length, POPULAR_CHIP_LIMIT);
  assert.deepEqual(
    readSuggestions(answered(LIVE_POOL)).popular.map((p) => p.query),
    ["deploy", "task", "search", "barkpark", "theme"],
  );
});

test("the word bound and the character bound are BOTH load-bearing", () => {
  // Two words, but long: the word bound alone would let it through.
  const longTwoWord = "internationalisation checklists";
  assert.equal(longTwoWord.split(/\s+/).length, POPULAR_CHIP_MAX_WORDS);
  assert.ok(longTwoWord.length > POPULAR_CHIP_MAX_CHARS);
  // Short, but three words: the character bound alone would let it through.
  const shortThreeWord = "a b c";
  assert.ok(shortThreeWord.length <= POPULAR_CHIP_MAX_CHARS);
  assert.ok(shortThreeWord.split(/\s+/).length > POPULAR_CHIP_MAX_WORDS);

  assert.deepEqual(
    curatePopularQueries([
      q("cli guide"),
      q(longTwoWord),
      q(shortThreeWord),
      q("how do webhooks work"),
    ]).map((p) => p.query),
    ["cli guide"],
  );
});

test("a CASED duplicate collapses, keeping the higher-ranked spelling", () => {
  // Three rows, two chips: below the cap in and out, so the cap is inert.
  const out = curatePopularQueries([q("Deploy", 41), q("deploy", 9), q("task", 8)]);
  assert.deepEqual(
    out.map((p) => p.query),
    ["Deploy", "task"],
  );
  assert.equal(out[0].count, 41, "the surviving row keeps its own count");
});

test("a corpus whose every query is long yields an EMPTY row, not leftovers", () => {
  const allLong = [
    q("how do i configure the webhook retry backoff", 30),
    q("research coverage ledger for the sdk lane", 22),
    q("barkpark studio dataset scoping walkthrough", 11),
  ];
  const out = readSuggestions(answered(allLong));
  assert.deepEqual(out.popular, [], "no chip row at all beats a row of leftovers");
  // …and the receipt still says the upstream answered. This is criterion [1]'s
  // load-bearing arm: curation emptying the list is a FACT ABOUT THE CORPUS.
  assert.equal(out.error, null);
  assert.equal(suggestionsNotice(out), null, "nothing failed — say nothing");
});

test("CURATION CANNOT FORGE AN ABSENCE: an emptied list still reads as answered", () => {
  // The receipt is derived from whether `popular` was an ARRAY, never from the
  // curated list's length. If curation ever fed the receipt, this arm reverses:
  // a corpus of nothing but long queries would start reading like a dead
  // endpoint, which is the exact fusion `lib/suggestions.ts` exists to prevent.
  const curatedToNothing = readSuggestions(
    answered([q("a whole sentence of agent exhaust that no human typed", 99)]),
  );
  const genuinelyEmpty = readSuggestions(answered([]));
  const deadEndpoint = readSuggestions(degraded("upstream 500"));

  assert.deepEqual(curatedToNothing.popular, []);
  assert.equal(curatedToNothing.error, null);
  // Reads exactly like the answered-empty corpus…
  assert.deepEqual(curatedToNothing, genuinelyEmpty);
  // …and NOT like an endpoint that never answered.
  assert.notDeepEqual(curatedToNothing, deadEndpoint);
  assert.equal(suggestionsNotice(curatedToNothing), null);

  // The mirror: a DEGRADED answer whose (empty) list survives curation keeps
  // its reason. Curation must not launder a string error into a null one.
  assert.equal(deadEndpoint.error, "upstream 500");
});

test("curation runs BEFORE the cap — exhaust cannot consume a visible slot", () => {
  // Seven rows: one exhaust probe at rank 2, then seven human queries. A
  // cap-only reader slices the first six and ships the probe as chip #2 while
  // dropping "seventh". Curation drops the probe and the seventh row survives.
  const pool = [
    q("first", 9),
    q("a whole sentence probe from an agent", 8),
    q("second", 7),
    q("third", 6),
    q("fourth", 5),
    q("fifth", 4),
    q("sixth", 3),
  ];
  const out = readSuggestions(answered(pool)).popular.map((p) => p.query);
  assert.equal(out.length, POPULAR_CHIP_LIMIT);
  assert.deepEqual(out, ["first", "second", "third", "fourth", "fifth", "sixth"]);
});
