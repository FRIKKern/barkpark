/**
 * Tests for the finder's honest result-count reading (`lib/result-window.ts`).
 *
 * THE DEFECT THESE PIN. The engine returns at most `MAX_HITS` (100) rows but
 * computes `total` and the facet buckets over the FULL match set — deliberately
 * (`api/lib/barkpark/search/documents_retriever.ex`'s `count_and_facets/1`:
 * "Facets + count stay on the FULL match set (not the ranking pool)"). The
 * finder then filters by facet and sorts CLIENT-SIDE over the rows in hand.
 * Past the window those are different sets, and the header printed them
 * together: `12 of 1200 results`, where the 12 came from filtering a 100-row
 * prefix and the 1200 from the unfiltered match set.
 *
 * The old inline expression is reproduced verbatim as `legacyLabel` below and
 * asserted to DISAGREE on exactly the narrowed-and-truncated case — so these
 * arms cannot pass against the code they replace, and the one case that
 * changed is named rather than assumed.
 *
 * Run: `cd web && node --test --import ./__tests__/support/stub-server-only.mjs __tests__/result-window.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readResultWindow, type ResultWindowInput } from "../lib/result-window.ts";

/**
 * The reading `components/finder.tsx` shipped before this module, transcribed
 * from the JSX exactly:
 *
 *   {visibleHits.length}
 *   {data && data.total > hits.length ? ` of ${data.total}` : ""}{" "}
 *   {visibleHits.length === 1 ? "result" : "results"}
 *
 * Note what it does NOT read: `facetActive` and `reordered` never entered it.
 * That is the defect — the label was blind to whether the number beside `total`
 * had been narrowed client-side.
 */
function legacyLabel({ total, fetched, visible }: ResultWindowInput): string {
  return `${visible}${total > fetched ? ` of ${total}` : ""}`;
}

/** Shorthand: a view with sensible defaults, overridden per case. */
function view(over: Partial<ResultWindowInput>): ResultWindowInput {
  return {
    total: 1200,
    fetched: 100,
    visible: 100,
    facetActive: false,
    reordered: false,
    ...over,
  };
}

/* ── the case that was wrong ─────────────────────────────────────────────── */

test("a FACETED view over a truncated window no longer borrows the unfiltered total", () => {
  const v = view({ visible: 12, facetActive: true });
  const out = readResultWindow(v);

  // The old label claimed the 1200 the engine matched, beside a 12 that came
  // from filtering 100 rows. That is the defect, reproduced:
  assert.equal(legacyLabel(v), "12 of 1200");
  assert.notEqual(out.countLabel, legacyLabel(v));

  // The new label counts what it actually counted, and names the window.
  assert.equal(out.countLabel, "12 of the first 100");
  assert.ok(out.windowTruncated);
  assert.ok(out.caveat, "a narrowed truncated view must disclose the window");
  assert.match(out.caveat!, /Filtering runs over the 100 results/);
  assert.match(out.caveat!, /not the 1200 it matched/);
});

test("a SORTED view over a truncated window discloses too — 'Newest' is newest of the window", () => {
  const v = view({ visible: 100, reordered: true });
  const out = readResultWindow(v);

  assert.equal(legacyLabel(v), "100 of 1200");
  assert.equal(out.countLabel, "100 of the first 100");
  assert.match(out.caveat ?? "", /^Sorting runs over the 100 results/);
});

test("facet AND sort together name both, not just one", () => {
  const out = readResultWindow(
    view({ visible: 7, facetActive: true, reordered: true }),
  );
  assert.match(out.caveat ?? "", /^Filtering and sorting run over the 100 results/);
});

/* ── the cases that must NOT change ──────────────────────────────────────── */

test("an UNNARROWED truncated view keeps the long-standing 'N of TOTAL' reading", () => {
  // Nothing client-side is reshaping the list, so the two numbers describe the
  // same set and the original label was already honest. Byte-for-byte equal to
  // the legacy expression — this arm is what proves the change is surgical.
  const v = view({ visible: 100 });
  const out = readResultWindow(v);
  assert.equal(out.countLabel, "100 of 1200");
  assert.equal(out.countLabel, legacyLabel(v));
  assert.equal(out.caveat, null, "nothing is narrowed — nothing to disclaim");
});

test("a COMPLETE window never warns, however it is narrowed", () => {
  // The engine handed over everything it matched, so the client-side facet and
  // sort are exact over the whole match set. A notice here would fire while the
  // finder is working correctly, which is how a real one gets ignored.
  for (const over of [
    { facetActive: true },
    { reordered: true },
    { facetActive: true, reordered: true },
    {},
  ]) {
    const v = view({ total: 40, fetched: 40, visible: 12, ...over });
    const out = readResultWindow(v);
    assert.equal(out.windowTruncated, false, JSON.stringify(over));
    assert.equal(out.caveat, null, JSON.stringify(over));
    assert.equal(out.countLabel, "12", JSON.stringify(over));
  }
});

test("an empty corpus and an exhausted page read as a bare count, never 'of 0'", () => {
  assert.equal(
    readResultWindow(view({ total: 0, fetched: 0, visible: 0 })).countLabel,
    "0",
  );
  assert.equal(
    readResultWindow(view({ total: 40, fetched: 40, visible: 40 })).countLabel,
    "40",
  );
});

/* ── the truncation signal itself ────────────────────────────────────────── */

test("truncation is total > fetched — NOT 'the page came back full'", () => {
  // A page that is exactly the cap and exactly the whole corpus is EXHAUSTED.
  // Inferring truncation from `fetched === 100` would call it truncated and
  // warn on a complete result set; the server's own count is the exact answer.
  const exhausted = readResultWindow(
    view({ total: 100, fetched: 100, visible: 100, facetActive: true }),
  );
  assert.equal(exhausted.windowTruncated, false);
  assert.equal(exhausted.caveat, null);

  // One row past it is genuinely truncated.
  const clipped = readResultWindow(
    view({ total: 101, fetched: 100, visible: 100, facetActive: true }),
  );
  assert.equal(clipped.windowTruncated, true);
  assert.ok(clipped.caveat);
});

test("plural tracks the VISIBLE count, not the total", () => {
  // A single visible row beside a 1200 total still reads "result".
  assert.equal(
    readResultWindow(view({ visible: 1, facetActive: true })).plural,
    false,
  );
  assert.equal(readResultWindow(view({ visible: 0 })).plural, true);
  assert.equal(readResultWindow(view({ visible: 2 })).plural, true);
});
