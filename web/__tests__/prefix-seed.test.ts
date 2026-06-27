/**
 * Tests for the client-side prefix seed — the in-browser 0ms head-start that
 * resolves 1-2 char queries before the live WS reply lands. Runs under Node's
 * built-in test runner (`node --test`), which strips TypeScript types at
 * load time in Node v22+. No external test framework needed.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/prefix-seed.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildPrefixSeed,
  lookupPrefix,
  seedDocToFindHit,
  MAX_PER_PREFIX,
  type SeedDoc,
} from "../lib/prefix-seed.ts";

/** A fixture corpus that exercises every interesting branch:
 *
 *   - multiple docs sharing a single-letter prefix (`j`: JavaScript, Jenkins, jq)
 *   - 2-char specificity (`ja` ≠ `je` ≠ `jq`)
 *   - slug-only matches (the `r` of `rust-guide`)
 *   - non-ASCII / weird title chars (uppercase / punctuation tokenize correctly)
 *   - a doc that should never match a non-existent prefix
 */
const corpus: SeedDoc[] = [
  { id: "1", title: "JavaScript Guide", slug: "javascript-guide", type: "paper" },
  { id: "2", title: "Jenkins CI", slug: "jenkins-ci", type: "post" },
  { id: "3", title: "jq Cheatsheet", slug: "jq-cheatsheet", type: "post" },
  { id: "4", title: "Rust Guide", slug: "rust-guide", type: "paper" },
  { id: "5", title: "Python: A primer", slug: "python-primer", type: "page" },
  { id: "6", title: "Webhooks 101", slug: "webhooks-101", type: "post" },
];

test("buildPrefixSeed returns a serializable shape", () => {
  const seed = buildPrefixSeed(corpus);
  // Round-trip through JSON to confirm it's wire-safe.
  const roundtripped = JSON.parse(JSON.stringify(seed));
  assert.deepEqual(roundtripped.docs.length, corpus.length);
  assert.equal(typeof roundtripped.index, "object");
});

test("buildPrefixSeed indexes single-character prefixes (lowercase)", () => {
  const seed = buildPrefixSeed(corpus);
  // "j" — covers JavaScript, Jenkins, jq (3 distinct docs)
  assert.ok(seed.index["j"], "expected `j` bucket");
  assert.deepEqual(seed.index["j"].slice().sort(), [0, 1, 2]);
  // "r" — Rust
  assert.ok(seed.index["r"], "expected `r` bucket");
  assert.ok(seed.index["r"].includes(3));
  // "p" — Python
  assert.ok(seed.index["p"]);
  // "w" — Webhooks
  assert.ok(seed.index["w"]);
});

test("buildPrefixSeed indexes 2-char prefixes distinctly", () => {
  const seed = buildPrefixSeed(corpus);
  assert.ok(seed.index["ja"]);
  assert.ok(seed.index["je"]);
  assert.ok(seed.index["jq"]);
  // "ja" only catches JavaScript (idx 0), not Jenkins (idx 1) or jq (idx 2).
  assert.deepEqual(seed.index["ja"], [0]);
  assert.deepEqual(seed.index["je"], [1]);
  assert.deepEqual(seed.index["jq"], [2]);
});

test("buildPrefixSeed indexes slug tokens, not just title tokens", () => {
  // A doc whose TITLE has no token starting with `c` — but the slug does.
  const slugOnly: SeedDoc[] = [
    { id: "10", title: "Rust Guide", slug: "rust-guide-cheatsheet", type: "paper" },
  ];
  const seed = buildPrefixSeed(slugOnly);
  // "c" comes from the slug token "cheatsheet"
  assert.ok(seed.index["c"]);
  assert.ok(seed.index["ch"]);
  assert.deepEqual(seed.index["c"], [0]);
});

test("buildPrefixSeed caps each bucket at MAX_PER_PREFIX", () => {
  // 50 docs all starting with "x" — single bucket should not exceed the cap.
  const big: SeedDoc[] = Array.from({ length: 50 }, (_, i) => ({
    id: `x${i}`,
    title: `Xenon ${i}`,
    slug: `xenon-${i}`,
    type: "post",
  }));
  const seed = buildPrefixSeed(big);
  assert.equal(seed.index["x"].length, MAX_PER_PREFIX);
  assert.equal(seed.index["xe"].length, MAX_PER_PREFIX);
  // Insertion order preserved — the first MAX_PER_PREFIX docs win.
  assert.deepEqual(
    seed.index["x"],
    Array.from({ length: MAX_PER_PREFIX }, (_, i) => i),
  );
});

test("lookupPrefix resolves single-char queries to the prefix bucket", () => {
  const seed = buildPrefixSeed(corpus);
  const hits = lookupPrefix(seed, "j");
  // Expect Jenkins / JavaScript / jq — three docs, ranked by insertion order.
  assert.equal(hits.length, 3);
  const titles = hits.map((h) => h.title);
  assert.ok(titles.includes("JavaScript Guide"));
  assert.ok(titles.includes("Jenkins CI"));
  assert.ok(titles.includes("jq Cheatsheet"));
});

test("lookupPrefix resolves 2-char queries to a tighter set", () => {
  const seed = buildPrefixSeed(corpus);
  const ja = lookupPrefix(seed, "ja");
  assert.equal(ja.length, 1);
  assert.equal(ja[0].title, "JavaScript Guide");
  const je = lookupPrefix(seed, "je");
  assert.equal(je.length, 1);
  assert.equal(je[0].title, "Jenkins CI");
});

test("lookupPrefix is case- and whitespace-insensitive", () => {
  const seed = buildPrefixSeed(corpus);
  const upper = lookupPrefix(seed, "JA");
  const lower = lookupPrefix(seed, "ja");
  const padded = lookupPrefix(seed, "  ja  ");
  assert.deepEqual(
    upper.map((h) => h.id),
    lower.map((h) => h.id),
  );
  assert.deepEqual(
    padded.map((h) => h.id),
    lower.map((h) => h.id),
  );
});

test("lookupPrefix returns [] for empty and 3+ char queries", () => {
  const seed = buildPrefixSeed(corpus);
  assert.deepEqual(lookupPrefix(seed, ""), []);
  assert.deepEqual(lookupPrefix(seed, "   "), []);
  // Length-3 belongs to the engine — the seed bows out.
  assert.deepEqual(lookupPrefix(seed, "jav"), []);
  assert.deepEqual(lookupPrefix(seed, "java"), []);
});

test("lookupPrefix returns [] for unknown prefixes (no false positives)", () => {
  const seed = buildPrefixSeed(corpus);
  assert.deepEqual(lookupPrefix(seed, "zz"), []);
  assert.deepEqual(lookupPrefix(seed, "q"), []);
});

test("lookupPrefix tolerates null/undefined seed", () => {
  assert.deepEqual(lookupPrefix(null, "j"), []);
  assert.deepEqual(lookupPrefix(undefined, "j"), []);
});

test("seedDocToFindHit produces a renderable FindHit", () => {
  const hit = seedDocToFindHit({
    id: "1",
    title: "JavaScript Guide",
    slug: "javascript-guide",
    type: "paper",
  });
  assert.equal(hit.id, "1");
  assert.equal(hit.title, "JavaScript Guide");
  assert.equal(hit.slug, "javascript-guide");
  assert.equal(hit.type, "paper");
  // The reader href is the unified /d/<type>/<slug> path.
  assert.equal(hit.href, "/d/paper/javascript-guide");
  // Engine-only fields default to null so the renderer degrades gracefully.
  assert.equal(hit.excerpt, null);
  assert.equal(hit.body, null);
  assert.equal(hit.date, null);
  assert.deepEqual(hit.facets, { type: "paper" });
});

test("EXIT GATE: `j` and `ja` queries surface relevant candidates from fixture", () => {
  const seed = buildPrefixSeed(corpus);
  const jHits = lookupPrefix(seed, "j");
  const jaHits = lookupPrefix(seed, "ja");
  assert.ok(
    jHits.length >= 1,
    "single-letter `j` should surface at least one candidate",
  );
  assert.ok(
    jaHits.length >= 1,
    "two-letter `ja` should surface at least one candidate",
  );
  // `ja` is strictly narrower than `j` for the JavaScript-Jenkins-jq trio.
  assert.ok(jaHits.length <= jHits.length);
  assert.ok(
    jaHits.some((h) => h.title.toLowerCase().includes("javascript")),
    "`ja` must include JavaScript",
  );
});
