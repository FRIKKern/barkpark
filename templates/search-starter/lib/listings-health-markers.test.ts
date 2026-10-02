// The MAP landing's two deploy HEALTH markers, pinned
// (dr-bl-map-landing-empty-marker).
//
// THE DEFECT, as measured on origin/main: `app/(finder)/page.tsx`'s map arm
// emitted `bp-doc-id` and, beside it, `bp-listings-source` — a marker name with
// exactly ONE occurrence in the whole repository, the emit site itself. The
// deploy engine reads `bp-corpus-status` (deploy/site-deploy-node.sh
// health_gate_node, `got_corpus="$(meta_value "$body" bp-corpus-status)"`), so
// the map arm's cause-truth went to a channel with no reader and the recorded
// failure_reason fell back to "no bp-corpus-status marker: this build predates
// the corpus-status contract". And in the UNCONFIGURED case the content-truth
// marker carried a BUNDLED SAMPLE id (`mocca-oslo`), so a site never pointed at
// a content type passed the gate on fabricated content.
//
// TWO ARMS, on purpose:
//   • the REDS-when-reverted arm — every non-live read anchors no document and
//     names its cause;
//   • the STAYS-QUIET arm — a live read emits NO cause marker at all, so this
//     cannot become a marker that is always present and therefore never read.
//
// MUTATION MAP — reintroduce the defect, and a NAMED assertion reds:
//   • docId = listings[0].id on the unconfigured branch  → "a bundled sample id is never content-truth"
//   • docId = substituted ? "" : listings[0]?.id         → "a bundled sample id is never content-truth"
//   • drop `upstreamReason` from the failed branch       → "the upstream cause reaches the marker verbatim"
//   • emit the cause on a healthy render                 → "a healthy render records NOTHING"
import test from "node:test";
import assert from "node:assert/strict";
import {
  listingsHealthMarkers,
  resolveListings,
  SAMPLE_LISTINGS,
  type Listing,
} from "./listings-data.ts";
import { CORPUS_STATUS_MARKER_MAX } from "./markers.ts";

const LIVE: Listing[] = [
  { id: "real-doc-1", type: "place", slug: "real-doc-1", title: "Real", lat: 1, lng: 2 },
];

/* ── the arm that must RED when the fix is reverted ───────────────────────── */

test("a bundled sample id is never content-truth", () => {
  const sampleId = SAMPLE_LISTINGS[0]!.id;

  for (const resolved of [
    resolveListings({ configured: false }),
    resolveListings({ configured: true, sourceName: "place", error: new Error("boom") }),
    resolveListings({ configured: true, sourceName: "place", live: [] }),
  ]) {
    const { docId } = listingsHealthMarkers(resolved);
    assert.equal(docId, "", `${resolved.source} must anchor no document`);
    assert.notEqual(docId, sampleId);
  }

  // The map still DRAWS the sample pins — the degrade is deliberate. What
  // stopped is sourcing the health marker from them.
  assert.ok(resolveListings({ configured: false }).listings.length > 0);
});

test("every empty doc id carries a cause — no symptom-only refusal", () => {
  for (const resolved of [
    resolveListings({ configured: false }),
    resolveListings({ configured: true, sourceName: "place", error: new Error("boom") }),
    resolveListings({ configured: true, sourceName: "place", live: [] }),
  ]) {
    const { docId, corpusStatus } = listingsHealthMarkers(resolved);
    assert.equal(docId, "");
    assert.notEqual(corpusStatus, "", `${resolved.source} must name its cause`);
    assert.ok(corpusStatus.length <= CORPUS_STATUS_MARKER_MAX);
    // The engine reads the value back with a shell `sed` on content="…".
    assert.ok(!/["'<>\r\n\t]/.test(corpusStatus), "marker text stays sed-safe");
  }
});

test("the upstream cause reaches the marker verbatim", () => {
  const resolved = resolveListings({
    configured: true,
    sourceName: "place",
    error: new Error("listings 403: public-read tokens may only read published public documents"),
  });
  const { corpusStatus } = listingsHealthMarkers(resolved);
  assert.match(corpusStatus, /403/);
  assert.match(corpusStatus, /public-read tokens may only read published public documents/);
});

test("the three causes are DISTINGUISHABLE — collapsing any two is the defect", () => {
  const causes = [
    listingsHealthMarkers(resolveListings({ configured: false })).corpusStatus,
    listingsHealthMarkers(
      resolveListings({ configured: true, sourceName: "place", error: new Error("boom") }),
    ).corpusStatus,
    listingsHealthMarkers(
      resolveListings({ configured: true, sourceName: "place", live: [] }),
    ).corpusStatus,
  ];
  assert.equal(new Set(causes).size, 3, "unconfigured / failed / empty read differently");
  assert.match(causes[0]!, /unset/);
  assert.match(causes[1]!, /fetch failed/);
  assert.match(causes[2]!, /ZERO rows/);
});

/* ── the arm that must stay QUIET ─────────────────────────────────────────── */

test("a healthy render records NOTHING — a real doc id and no cause marker", () => {
  const { docId, corpusStatus } = listingsHealthMarkers(
    resolveListings({ configured: true, sourceName: "place", live: LIVE }),
  );
  assert.equal(docId, "real-doc-1");
  assert.equal(corpusStatus, "", "a healthy render records NOTHING");
});

test("the cause marker is emitted EXACTLY when the doc id is empty", () => {
  for (const resolved of [
    resolveListings({ configured: false }),
    resolveListings({ configured: true, sourceName: "place", error: new Error("e") }),
    resolveListings({ configured: true, sourceName: "place", live: [] }),
    resolveListings({ configured: true, sourceName: "place", live: LIVE }),
  ]) {
    const { docId, corpusStatus } = listingsHealthMarkers(resolved);
    assert.equal(
      corpusStatus !== "",
      docId === "",
      `${resolved.source}: cause marker present exactly when bp-doc-id is empty`,
    );
  }
});
