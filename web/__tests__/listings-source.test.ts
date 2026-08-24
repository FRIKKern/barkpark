/**
 * The listings map's sample-vs-live provenance decision
 * (`lib/listings-data.ts`, task-78bd64a68c6de26f).
 *
 * THE DEFECT: `fetchListings()` ended in three silent substitutions of bundled
 * sample rows for real content —
 *
 *     if (!LISTINGS_TYPE) return SAMPLE_LISTINGS;
 *     try {
 *       const live = await cachedListings();
 *       return live.length > 0 ? live : SAMPLE_LISTINGS;
 *     } catch {
 *       return SAMPLE_LISTINGS;
 *     }
 *
 * The bare `catch` is the serious one: with `LISTINGS_TYPE` set — a deployment
 * that HAS wired a live source — any upstream failure rendered the 13 bundled
 * pins as though they were the operator's own listings, with no error, no badge
 * and not one log line. A working deployment and a broken one drew the same
 * map. The `live.length > 0` test is the subtler one: a legitimately EMPTY
 * corpus was substituted identically, so a correct empty state could not be
 * told from a populated one.
 *
 * The degrade is DELIBERATE and stays — a thrown error would crash the Server
 * Component that renders the map. What changed is that it now names itself.
 *
 * `lib/listings-data.ts` is dependency-free (no `server-only`, no `next/cache`,
 * no `@/` aliases), which is why the decision lives there: these tests load the
 * SHIPPED function, not a hand-kept mirror like `listings.test.ts` must use.
 *
 * NAMED MUTANTS these tests kill:
 *   • collapse-unconfigured-into-failed → the quiet-out-of-the-box test reds
 *   • drop-the-notice                   → the notice tests red
 *   • treat-empty-live-as-live          → the empty-corpus test reds
 *   • rethrow-instead-of-degrade        → the never-throws test reds
 *   • forget-substituted-flag           → the page-disclosure tests red
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/listings-source.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  resolveListings,
  SAMPLE_LISTINGS,
  type Listing,
} from "../lib/listings-data.ts";

const LIVE: Listing[] = [
  { id: "real-1", type: "listing", slug: "real-1", title: "A Real Place", lat: 1, lng: 2 },
];

/**
 * The decision as it stood BEFORE this fix, kept as a permanent witness. Note
 * what it CANNOT return: which case fired, and anything to log. Every caller
 * got an indistinguishable `Listing[]`.
 */
function preFixDecision(input: {
  configured: boolean;
  live?: Listing[] | null;
  threw?: boolean;
}): Listing[] {
  if (!input.configured) return SAMPLE_LISTINGS;
  if (input.threw) return SAMPLE_LISTINGS;
  const live = input.live ?? [];
  return live.length > 0 ? live : SAMPLE_LISTINGS;
}

test("THE DEFECT: the pre-fix decision returned the same thing for a broken source, an empty one, and no source at all", () => {
  const noSource = preFixDecision({ configured: false });
  const broken = preFixDecision({ configured: true, threw: true });
  const empty = preFixDecision({ configured: true, live: [] });
  // Byte-identical outcomes for three completely different operational states.
  assert.deepEqual(broken, noSource);
  assert.deepEqual(empty, noSource);
  assert.equal(broken.length, SAMPLE_LISTINGS.length);
  // And nothing in the return value could tell an operator which one happened.
  assert.equal(Array.isArray(broken), true);
});

test("no source configured: samples, quietly — out of the box they ARE the content", () => {
  const r = resolveListings({ configured: false });
  assert.equal(r.source, "sample:unconfigured");
  assert.equal(r.substituted, false); // nothing was replaced; nothing to disclose
  assert.equal(r.notice, undefined); // and NOTHING is logged
  assert.deepEqual(r.listings, SAMPLE_LISTINGS);
});

test("a configured source that FAILED is named, and its cause survives into the notice", () => {
  const r = resolveListings({
    configured: true,
    sourceName: "place",
    error: new Error("listings 503: upstream unavailable"),
    live: null,
  });
  assert.equal(r.source, "sample:failed");
  assert.equal(r.substituted, true); // the operator must see this
  assert.deepEqual(r.listings, SAMPLE_LISTINGS); // still renderable
  // The cause is the whole point — the bare `catch {}` threw it away.
  assert.match(r.notice!, /listings 503: upstream unavailable/);
  assert.match(r.notice!, /LISTINGS_TYPE="place"/);
  assert.match(r.notice!, /NOT your dataset/);
  assert.match(r.notice!, new RegExp(String(SAMPLE_LISTINGS.length)));
});

test("a configured source that answered with ZERO rows is a DIFFERENT case, and says so", () => {
  const r = resolveListings({ configured: true, sourceName: "place", live: [] });
  assert.equal(r.source, "sample:empty");
  assert.equal(r.substituted, true);
  assert.match(r.notice!, /matched ZERO rows/);
  // It must NOT claim a fetch failure — nothing failed.
  assert.doesNotMatch(r.notice!, /fetch failed/);
});

test("live rows are served untouched, and nothing is logged", () => {
  const r = resolveListings({ configured: true, sourceName: "place", live: LIVE });
  assert.equal(r.source, "live");
  assert.equal(r.substituted, false);
  assert.equal(r.notice, undefined);
  assert.deepEqual(r.listings, LIVE); // the samples never mix in
});

test("a non-Error throw still produces a usable notice rather than [object Object]", () => {
  const fromString = resolveListings({ configured: true, error: "boom" });
  assert.match(fromString.notice!, /boom/);
  const fromJunk = resolveListings({ configured: true, error: { weird: true } });
  assert.equal(fromJunk.source, "sample:failed");
  assert.match(fromJunk.notice!, /unknown error/);
});

test("an unnamed source still yields a notice — the log is never blank", () => {
  const r = resolveListings({ configured: true, error: new Error("x") });
  assert.match(r.notice!, /LISTINGS_TYPE/);
  assert.equal(r.substituted, true);
});

test("THE DEGRADE IS PRESERVED: every case returns renderable rows and never throws", () => {
  const cases = [
    { configured: false },
    { configured: true, error: new Error("down"), live: null },
    { configured: true, live: [] },
    { configured: true, live: LIVE },
  ];
  for (const input of cases) {
    const r = resolveListings(input);
    assert.ok(r.listings.length > 0, `empty render set for ${JSON.stringify(input)}`);
    // `substituted` is the ONLY bit the page needs to decide on disclosure.
    assert.equal(typeof r.substituted, "boolean");
    // A notice exists exactly when something was substituted — never otherwise.
    assert.equal(r.notice !== undefined, r.substituted);
  }
});

test("the four sources are mutually exclusive — one input, one verdict", () => {
  const seen = new Set(
    [
      resolveListings({ configured: false }),
      resolveListings({ configured: true, error: new Error("e") }),
      resolveListings({ configured: true, live: [] }),
      resolveListings({ configured: true, live: LIVE }),
    ].map((r) => r.source),
  );
  // collapse-unconfigured-into-failed reds here with 3.
  assert.equal(seen.size, 4);
});
