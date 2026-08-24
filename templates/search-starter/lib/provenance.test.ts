// The provenance surface's copy, pinned. `node --test` (Node ≥22 strips the
// types natively) — `lib/provenance.ts` is dependency-free for exactly this
// reason, the same way `lib/markers.ts` is.
//
// The point of pinning the TEXT and not just the state: this line is the one
// place the page tells a human what it is serving, so a silent copy drift back
// to "Showing the first N" (which names a ceiling that did not fire) or to a
// bare "1,765 documents" on a capped corpus is exactly the regression this
// module exists to prevent.
import test from "node:test";
import assert from "node:assert/strict";
import {
  buildIdentityLine,
  corpusProvenanceLine,
  groupDigits,
  type CorpusProvenance,
} from "./provenance.ts";

/** A healthy, complete, connected read — each test overrides one axis. */
function corpus(over: Partial<CorpusProvenance> = {}): CorpusProvenance {
  return {
    nodeCount: 12,
    docCount: 12,
    truncated: false,
    truncationReason: null,
    upstreamStatus: null,
    upstreamReason: null,
    apiConfigured: true,
    ...over,
  };
}

/* ── build identity ─────────────────────────────────────────────────────── */

test("both markers unset reads as a STATE, never as a build named 'dev'", () => {
  const line = buildIdentityLine({ buildId: null, contentRev: null });
  assert.equal(
    line,
    "Not a deployed build — no build id or content revision was stamped.",
  );
  // The sentinels `siteMarkers()` uses for the <meta> tags must never leak into
  // the human line as if they were values.
  assert.ok(!line.includes("dev"));
  assert.ok(!line.includes("unknown"));
});

test("a deployed build prints both markers verbatim", () => {
  assert.equal(
    buildIdentityLine({ buildId: "b-2026-08-19-01", contentRev: "rev-9f2c" }),
    "Build b-2026-08-19-01 · content rev-9f2c.",
  );
});

test("a half-stamped build names which half is missing", () => {
  assert.equal(
    buildIdentityLine({ buildId: "b-1", contentRev: null }),
    "Build b-1 · content revision not stamped.",
  );
  assert.equal(
    buildIdentityLine({ buildId: null, contentRev: "rev-9f2c" }),
    "Build id not stamped · content rev-9f2c.",
  );
});

test("no build line ever claims a build TIME", () => {
  for (const b of [
    { buildId: null, contentRev: null },
    { buildId: "b-1", contentRev: "rev-1" },
    { buildId: null, contentRev: "rev-1" },
  ]) {
    const line = buildIdentityLine(b).toLowerCase();
    for (const word of ["built at", "built on", "ago", "timestamp", "date"]) {
      assert.ok(!line.includes(word), `${word} in: ${line}`);
    }
  }
});

/* ── unreachable vs empty ───────────────────────────────────────────────── */

test("a failed read is reported as a failed read, never as an empty corpus", () => {
  const line = corpusProvenanceLine(
    corpus({ nodeCount: 0, docCount: 0, upstreamStatus: 403, upstreamReason: "graph 403: forbidden" }),
  );
  assert.equal(line.state, "unreachable");
  assert.equal(
    line.text,
    "Not connected — the corpus could not be read (graph 403: forbidden).",
  );
});

test("an unconfigured API base is its OWN state, not a generic failure", () => {
  const line = corpusProvenanceLine(
    corpus({
      nodeCount: 0,
      docCount: 0,
      apiConfigured: false,
      upstreamStatus: 0,
      upstreamReason: "graph 0: fetch failed",
    }),
  );
  assert.equal(line.state, "unconfigured");
  assert.equal(
    line.text,
    "Not connected — no corpus link is configured, so nothing was read (graph 0: fetch failed).",
  );
});

test("a genuinely empty corpus and an unreadable one do NOT render alike", () => {
  const empty = corpusProvenanceLine(corpus({ nodeCount: 0, docCount: 0 }));
  const dead = corpusProvenanceLine(
    corpus({ nodeCount: 0, docCount: 0, upstreamStatus: 0, upstreamReason: "graph 0: fetch failed" }),
  );
  assert.equal(empty.state, "empty");
  assert.equal(
    empty.text,
    "Connected — the corpus read succeeded and holds 0 documents.",
  );
  assert.notEqual(empty.text, dead.text);
  // The distinguishing word, spelled out: one says Connected, one does not.
  assert.ok(empty.text.startsWith("Connected —"));
  assert.ok(dead.text.startsWith("Not connected —"));
});

test("a failed read with no recorded reason still names its status", () => {
  const line = corpusProvenanceLine(
    corpus({ nodeCount: 0, docCount: 0, upstreamStatus: 502, upstreamReason: null }),
  );
  assert.equal(line.state, "unreachable");
  assert.ok(line.text.includes("graph 502: no detail recorded"));
});

/* ── capped vs complete ─────────────────────────────────────────────────── */

test("a complete corpus says it is complete", () => {
  const line = corpusProvenanceLine(corpus({ nodeCount: 12, docCount: 12 }));
  assert.equal(line.state, "complete");
  assert.equal(line.text, "12 documents, complete — nothing was cut.");
});

test("12 results and 'at least 12, capped at 12' do NOT render identically", () => {
  const complete = corpusProvenanceLine(corpus({ nodeCount: 12, docCount: 12 }));
  const capped = corpusProvenanceLine(
    corpus({ nodeCount: 12, docCount: 12, truncated: true, truncationReason: "per_type_cap" }),
  );
  assert.notEqual(complete.text, capped.text);
  assert.ok(capped.text.startsWith("At least 12 documents"));
  assert.ok(!complete.text.startsWith("At least"));
});

test("the capped line names the ceiling that actually fired, in VISIBLE text", () => {
  // The live /v1/graph?dataset=production answer: 1796 nodes, 31 phantom,
  // truncated:true, truncation_reason:"per_type_cap".
  const line = corpusProvenanceLine(
    corpus({
      nodeCount: 1796,
      docCount: 1765,
      truncated: true,
      truncationReason: "per_type_cap",
    }),
  );
  assert.equal(line.state, "capped");
  assert.equal(
    line.text,
    "At least 1,765 documents — the server stopped at its per-type document cap, so some types are incomplete. " +
      "Cut reported as per_type_cap. 1,796 nodes drawn, 31 referenced but absent.",
  );
  // The retired copy described a PREFIX cut (node_budget), which is not what a
  // per-type cap does — nothing was "the first" of anything.
  assert.ok(!line.text.includes("Showing the first"));
  // The reason is in the copy itself, not parked in a title= no touch, keyboard
  // or screen-reader user ever reaches.
  assert.ok(line.text.includes("per_type_cap"));
});

test("a node-budget cut is described as a budget, not as a per-type cap", () => {
  const line = corpusProvenanceLine(
    corpus({ nodeCount: 2000, docCount: 2000, truncated: true, truncationReason: "node_budget" }),
  );
  assert.equal(line.state, "capped");
  assert.ok(line.text.includes("whole-graph node budget"));
  assert.ok(!line.text.includes("per-type document cap"));
  assert.ok(line.text.includes("Cut reported as node_budget."));
});

test("a compound reason names BOTH ceilings", () => {
  const line = corpusProvenanceLine(
    corpus({
      nodeCount: 2000,
      docCount: 2000,
      truncated: true,
      truncationReason: "per_type_cap+node_budget",
    }),
  );
  assert.ok(line.text.includes("BOTH its per-type document cap and its whole-graph node budget"));
  assert.ok(line.text.includes("Cut reported as per_type_cap+node_budget."));
});

test("a cut with no reason admits the ceiling is unnamed rather than guessing", () => {
  const line = corpusProvenanceLine(
    corpus({ nodeCount: 500, docCount: 500, truncated: true, truncationReason: null }),
  );
  assert.equal(line.state, "capped");
  assert.equal(
    line.text,
    "At least 500 documents — the server cut the corpus at a ceiling it did not name.",
  );
  assert.ok(!line.text.includes("Cut reported as"));
});

/* ── the count reconciliation ───────────────────────────────────────────── */

test("the document count and the node count are both accounted for", () => {
  const line = corpusProvenanceLine(corpus({ nodeCount: 1796, docCount: 1765 }));
  assert.equal(
    line.text,
    "1,765 documents, complete — nothing was cut. 1,796 nodes drawn, 31 referenced but absent.",
  );
});

test("no phantom sentence when the two counts agree", () => {
  const line = corpusProvenanceLine(corpus({ nodeCount: 40, docCount: 40 }));
  assert.ok(!line.text.includes("referenced but absent"));
});

test("digit grouping is deterministic (no runtime locale in a hydrated line)", () => {
  assert.equal(groupDigits(0), "0");
  assert.equal(groupDigits(31), "31");
  assert.equal(groupDigits(1765), "1,765");
  assert.equal(groupDigits(1000000), "1,000,000");
});
