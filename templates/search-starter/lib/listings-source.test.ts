// The map's sample-vs-live provenance, pinned (task-fe4648fa743ab0a6).
//
// THE DEFECT: `fetchListings()` ended in three silent substitutions of the
// bundled sample rows for the operator's data — unconfigured, empty, and a bare
// `catch {}` that swallowed the CAUSE. With `LISTINGS_TYPE` configured, a
// broken upstream drew exactly the same map as a working one: no flag, no
// badge, not one log line. A legitimately EMPTY corpus was substituted
// identically, so a correct empty state could not be told from a populated one.
//
// This is the DISTRIBUTABLE artifact — every scaffolded project inherits it —
// so the decision is tested where it ships. `resolveListings` lives in
// `lib/listings-data.ts` precisely because that module is dependency-free and
// loads under bare `node --test` (Node >=22 strips the types natively);
// `lib/listings.ts` pulls `server-only` + `next/cache` and cannot be imported
// here at all.
//
// MUTATION MAP — reintroduce the defect, and a NAMED assertion reds:
//   • collapse sample:failed  -> sample:unconfigured   → "a failed fetch is not the unconfigured case"
//   • collapse sample:empty   -> live (return live)    → "an empty live corpus is disclosed, not passed off as live"
//   • drop `substituted: true` on the failed branch    → "the page's disclosure bit"
//   • drop the `notice` string                         → "a notice exists exactly when something was substituted"
import test from "node:test";
import assert from "node:assert/strict";
import {
  resolveListings,
  SAMPLE_LISTINGS,
  type Listing,
  type ResolvedListings,
} from "./listings-data.ts";

const LIVE: Listing[] = [
  { id: "live-1", type: "listing", slug: "live-1", title: "Live One", lat: 1, lng: 2 },
  { id: "live-2", type: "listing", slug: "live-2", title: "Live Two", lat: 3, lng: 4 },
];

/* ── branch 1: unconfigured — the template working as intended ───────────── */

test("unconfigured serves the samples QUIETLY — they are the product here", () => {
  const r = resolveListings({ configured: false });
  assert.equal(r.source, "sample:unconfigured");
  // nothing was replaced; nothing to disclose
  assert.equal(r.substituted, false, "out of the box is not a substitution");
  assert.equal(r.notice, undefined, "no source was configured, so nothing failed");
  assert.deepEqual(r.listings, SAMPLE_LISTINGS);
});

/* ── branch 2: configured + fetch FAILED — the silent lie ────────────────── */

test("a FAILED fetch is disclosed, not passed off as the operator's data", () => {
  const r = resolveListings({
    configured: true,
    sourceName: "place",
    error: new Error("listings 503: upstream down"),
  });
  assert.equal(
    r.source,
    "sample:failed",
    "a failed fetch is not the unconfigured case — they must stay distinct",
  );
  assert.equal(r.substituted, true, "the page's disclosure bit must be set");
  assert.equal(r.listings, SAMPLE_LISTINGS);
  assert.ok(r.notice, "a notice exists exactly when something was substituted");
  // The notice must carry the CAUSE — a bare catch threw it away.
  assert.match(r.notice!, /listings 503: upstream down/);
  assert.match(r.notice!, /LISTINGS_TYPE="place"/);
  assert.match(r.notice!, /NOT your dataset/);
  // And it must count what it is actually about to render, not a hard-coded 13.
  assert.match(r.notice!, new RegExp(`SERVING ${SAMPLE_LISTINGS.length} BUNDLED`));
});

/* ── branch 3: configured + EMPTY live corpus ────────────────────────────── */

test("an EMPTY live corpus is disclosed, not passed off as live", () => {
  const r = resolveListings({ configured: true, sourceName: "place", live: [] });
  assert.equal(
    r.source,
    "sample:empty",
    "an empty live corpus is disclosed, not passed off as live",
  );
  assert.equal(r.substituted, true, "the page's disclosure bit must be set");
  assert.ok(r.notice, "a notice exists exactly when something was substituted");
  assert.match(r.notice!, /matched ZERO rows/);
  // `null` (nothing fetched, no error) is the same state as an empty array.
  assert.equal(resolveListings({ configured: true, live: null }).source, "sample:empty");
});

/* ── branch 4: live rows win ─────────────────────────────────────────────── */

test("live rows are returned untouched and reported as live", () => {
  const r = resolveListings({ configured: true, sourceName: "place", live: LIVE });
  assert.equal(r.source, "live");
  assert.equal(r.substituted, false);
  assert.equal(r.notice, undefined, "nothing was substituted, so say nothing");
  assert.deepEqual(r.listings, LIVE);
  assert.notDeepEqual(r.listings, SAMPLE_LISTINGS);
});

/* ── error shapes + precedence ───────────────────────────────────────────── */

test("a non-Error throw still yields a readable cause", () => {
  assert.match(resolveListings({ configured: true, error: "boom" }).notice!, /boom/);
  assert.match(
    resolveListings({ configured: true, error: { weird: true } }).notice!,
    /unknown error/,
  );
});

test("an error OUTRANKS an empty result — the cause is the useful half", () => {
  const r = resolveListings({ configured: true, live: [], error: new Error("x") });
  assert.equal(r.source, "sample:failed");
});

/* ── the contract the page renders off ───────────────────────────────────── */

test("substituted <-> notice, on every branch", () => {
  const all: ResolvedListings[] = [
    resolveListings({ configured: false }),
    resolveListings({ configured: true, error: new Error("e") }),
    resolveListings({ configured: true, live: [] }),
    resolveListings({ configured: true, live: LIVE }),
  ];
  for (const r of all) {
    assert.equal(typeof r.substituted, "boolean");
    // A notice exists exactly when something was substituted — never otherwise.
    assert.equal(
      r.notice !== undefined,
      r.substituted,
      "a notice exists exactly when something was substituted",
    );
    assert.ok(r.listings.length > 0, "the map always has something to draw");
  }
});

test("the four sources are DISTINCT — collapsing any two is the defect", () => {
  const sources = [
    resolveListings({ configured: false }).source,
    resolveListings({ configured: true, error: new Error("e") }).source,
    resolveListings({ configured: true, live: [] }).source,
    resolveListings({ configured: true, live: LIVE }).source,
  ];
  assert.deepEqual(sources, [
    "sample:unconfigured",
    "sample:failed",
    "sample:empty",
    "live",
  ]);
  assert.equal(new Set(sources).size, 4, "four cases, four distinct answers");
});

test("only the two BROKEN cases disclose — unconfigured stays quiet", () => {
  // This is exactly the predicate `app/(finder)/page.tsx` renders the banner on
  // and suppresses the bp-doc-id health marker on.
  assert.equal(resolveListings({ configured: false }).substituted, false);
  assert.equal(resolveListings({ configured: true, live: LIVE }).substituted, false);
  assert.equal(resolveListings({ configured: true, live: [] }).substituted, true);
  assert.equal(
    resolveListings({ configured: true, error: new Error("e") }).substituted,
    true,
  );
});
