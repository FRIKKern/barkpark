/**
 * Tests for `normalizeRelated` — the pure `related-route JSON → RelatedEntry[]`
 * shaper the reader's Related section (`lib/related.ts` → `RelatedPapers`) feeds
 * on. It owns the `{ result: { related } }` envelope dig, the tolerant per-entry
 * field coercion, the two-leg `sources` allowlist, and the backlink-only
 * provenance predicate. Split out of the server-only `lib/related.ts` (which
 * imports `next/cache`, unimportable by the plain-node runner) exactly as
 * `find-shape.ts` is split out of `find-search.ts`.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/related.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  normalizeRelated,
  isBacklinkOnly,
  creditedStrength,
  type RelatedEntry,
} from "../lib/related-shape.ts";

/** The wire envelope the query controller returns. */
const body = (related: unknown[]) => ({
  result: { related, count: related.length },
  syncTags: ["bp:ds:production:related:src"],
});

test("shapes a tag-weighted entry from the full wire envelope", () => {
  const out = normalizeRelated(
    body([
      {
        doc_id: "rel-cand",
        type: "paper",
        title: "Candidate",
        score: 1.1,
        sources: ["tags"],
        shared_tags: [{ tag: "search", src_strength: 75, cand_strength: 50 }],
      },
    ]),
  );
  assert.equal(out.length, 1);
  const e = out[0];
  assert.equal(e.doc_id, "rel-cand");
  assert.equal(e.type, "paper");
  assert.equal(e.title, "Candidate");
  assert.equal(e.score, 1.1);
  assert.deepEqual(e.sources, ["tags"]);
  assert.deepEqual(e.shared_tags, [
    { tag: "search", src_strength: 75, cand_strength: 50 },
  ]);
  assert.equal(isBacklinkOnly(e), false);
  // Credited strength mirrors the server's LEAST(src, cand).
  assert.equal(creditedStrength(e.shared_tags[0]), 50);
});

test("flags a backlink-only entry (references, no shared tags)", () => {
  const out = normalizeRelated(
    body([
      {
        doc_id: "rel-linked",
        type: "post",
        title: "Links here",
        score: 0.5,
        sources: ["references"],
        shared_tags: [],
      },
    ]),
  );
  assert.equal(out.length, 1);
  assert.equal(isBacklinkOnly(out[0]), true);
  assert.deepEqual(out[0].shared_tags, []);
});

test("a both-legs entry is NOT backlink-only", () => {
  const out = normalizeRelated(
    body([
      {
        doc_id: "rel-both",
        type: "paper",
        title: "Both",
        score: 2,
        sources: ["tags", "references"],
        shared_tags: [{ tag: "nextjs", src_strength: 30, cand_strength: 90 }],
      },
    ]),
  );
  assert.equal(isBacklinkOnly(out[0]), false);
  assert.equal(creditedStrength(out[0].shared_tags[0]), 30);
});

test("empty related yields an empty array (the untagged/unreferenced case)", () => {
  assert.deepEqual(normalizeRelated(body([])), []);
});

test("tolerates the bare {related} shape and a raw array", () => {
  const entry = {
    doc_id: "x",
    type: "paper",
    title: "X",
    score: 1,
    sources: ["tags"],
    shared_tags: [],
  };
  assert.equal(normalizeRelated({ related: [entry] }).length, 1);
  assert.equal(normalizeRelated([entry]).length, 1);
});

test("drops malformed entries and coerces missing fields", () => {
  const out = normalizeRelated(
    body([
      null,
      42,
      "nope",
      { type: "paper" }, // no doc_id → dropped
      {
        doc_id: "rel-partial",
        // no type/title/score/sources/shared_tags → coerced to safe defaults
      },
      {
        doc_id: "rel-badtags",
        sources: ["tags", "bogus", "tags"], // unknown leg dropped, dedup applied
        shared_tags: [
          { tag: "ok", src_strength: 10, cand_strength: 20 },
          { strength: 5 }, // no tag → dropped
          null,
        ],
      },
    ]),
  );
  const ids = out.map((e) => e.doc_id);
  assert.deepEqual(ids, ["rel-partial", "rel-badtags"]);

  const partial = out[0] as RelatedEntry;
  assert.equal(partial.type, "_unknown");
  assert.equal(partial.title, null);
  assert.equal(partial.score, 0);
  assert.deepEqual(partial.sources, []);
  assert.deepEqual(partial.shared_tags, []);

  const badtags = out[1] as RelatedEntry;
  assert.deepEqual(badtags.sources, ["tags"]); // "bogus" gone, no duplicate
  assert.deepEqual(badtags.shared_tags, [
    { tag: "ok", src_strength: 10, cand_strength: 20 },
  ]);
});

test("non-object / non-array input is empty, never throws", () => {
  assert.deepEqual(normalizeRelated(null), []);
  assert.deepEqual(normalizeRelated(undefined), []);
  assert.deepEqual(normalizeRelated("nope"), []);
  assert.deepEqual(normalizeRelated(123), []);
  assert.deepEqual(normalizeRelated({ result: {} }), []);
  assert.deepEqual(normalizeRelated({ result: { related: "nope" } }), []);
});
