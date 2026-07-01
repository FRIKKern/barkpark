import { test } from "node:test";
import assert from "node:assert/strict";

import { paper, Paper } from "../src/paper.js";
import { resetBlockIds, heading, paragraph } from "../src/blocks.js";

// The `paper()` builder is the ingest SDK's top-level entry — it collects blocks
// and serialises the exact publish body the ingest endpoint accepts. It was
// exercised indirectly by client.test but never unit-tested; these pin the
// builder contract (opts passthrough, chainable add, copy-returning getters,
// only-set-keys serialisation).

test("paper() returns a Paper carrying slug + opts", () => {
  const p = paper("demo", { title: "Demo", style: "article" });
  assert.ok(p instanceof Paper);
  assert.equal(p.slug, "demo");
  assert.equal(p.title, "Demo");
  assert.equal(p.style, "article");
});

test("toJSON emits slug + blocks and only the optional keys that were set", () => {
  resetBlockIds();
  assert.deepEqual(paper("bare").toJSON(), { slug: "bare", blocks: [] });

  const withTitleOnly = paper("t", { title: "T" }).toJSON();
  assert.equal(withTitleOnly.title, "T");
  assert.ok(!("style" in withTitleOnly), "undefined style must be omitted, not emitted");
});

test("add() is chainable (returns the builder) and preserves order", () => {
  resetBlockIds();
  const a = heading(1, "A");
  const b = paragraph("B");
  const c = paragraph("C");

  const p = paper("x");
  assert.equal(p.add(a), p, "add returns the same builder");
  p.add(b, c); // variadic
  assert.deepEqual(p.getBlocks(), [a, b, c]);
});

test("getBlocks() and toJSON() return copies — the builder is immutable from outside", () => {
  resetBlockIds();
  const p = paper("x").add(paragraph("a"));

  p.getBlocks().push(paragraph("b")); // mutate the returned array
  assert.equal(p.getBlocks().length, 1, "getBlocks copy must not leak into the builder");

  p.toJSON().blocks.push(paragraph("c")); // mutate the serialised body's blocks
  assert.equal(p.getBlocks().length, 1, "toJSON blocks copy must not leak into the builder");
});
