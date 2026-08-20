import assert from "node:assert/strict";
import { test } from "node:test";

import {
  curatePopularQueries,
  POPULAR_CHIP_CAP,
  type PopularQuery,
} from "./find.ts";

const q = (query: string, count = 1): PopularQuery => ({ query, count });

/**
 * FIXTURE — the real popular pool measured on the live demo
 * (guerrilla.barkpark.cloud/sites/search-ember, 2026-07-26), in rank order.
 * "research coverage ledger" is agent exhaust: a three-word internal phrase
 * that shipped as a tappable chip promising it was a search worth trying.
 */
const LIVE_POOL: PopularQuery[] = [
  q("deploy", 41),
  q("research coverage ledger", 33),
  q("task", 22),
  q("search", 19),
  q("barkpark", 15),
  q("theme", 11),
];

test("drops the multi-word agent exhaust, keeps the real queries in rank order", () => {
  assert.deepEqual(
    curatePopularQueries(LIVE_POOL).map((p) => p.query),
    ["deploy", "task", "search", "barkpark", "theme"],
  );
});

test("keeps a two-word query but not a three-word one", () => {
  assert.deepEqual(
    curatePopularQueries([q("cli guide"), q("how do webhooks work")]).map(
      (p) => p.query,
    ),
    ["cli guide"],
  );
});

test("drops a long one-word query (24-char ceiling)", () => {
  const ok = "a".repeat(24);
  const tooLong = "a".repeat(25);
  assert.deepEqual(
    curatePopularQueries([q(tooLong), q(ok)]).map((p) => p.query),
    [ok],
  );
});

test("dedupes case-insensitively, keeping the higher-ranked spelling", () => {
  assert.deepEqual(
    curatePopularQueries([q("Deploy", 9), q("deploy", 4)]).map((p) => p.query),
    ["Deploy"],
  );
});

test("trims whitespace and drops blank/whitespace-only entries", () => {
  assert.deepEqual(
    curatePopularQueries([q("  deploy  "), q("   "), q("")]).map((p) => p.query),
    ["deploy"],
  );
});

test("caps the row at POPULAR_CHIP_CAP", () => {
  const many = Array.from({ length: 20 }, (_, i) => q(`term${i}`));
  assert.equal(curatePopularQueries(many).length, POPULAR_CHIP_CAP);
});

test("degrades to no row: empty pool, missing pool, and an all-noise pool", () => {
  // A fresh dataset has no query log at all…
  assert.deepEqual(curatePopularQueries([]), []);
  assert.deepEqual(curatePopularQueries(undefined), []);
  assert.deepEqual(curatePopularQueries(null), []);
  // …and a dev-heavy one can have a log with nothing short in it. Both must
  // yield [] so the caller renders NO chip row rather than a row of leftovers.
  assert.deepEqual(
    curatePopularQueries([
      q("research coverage ledger"),
      q("what does the provisioner do when the token expires"),
    ]),
    [],
  );
});

test("preserves the rest of the entry (count drives nothing here, but must survive)", () => {
  assert.deepEqual(curatePopularQueries([q("deploy", 41)]), [
    { query: "deploy", count: 41 },
  ]);
});
