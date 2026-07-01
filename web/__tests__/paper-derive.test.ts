/**
 * Tests for the paper derivation helpers in `papers.ts` — `paperSlug` (the URL
 * key), `paperBlocks` (top-level vs nested body), and `paperTitle` (title →
 * first heading → "(untitled)"). These drive every paper's link and heading in
 * the finder; `paperExcerpt` is covered separately. Shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/paper-derive.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { paperSlug, paperTitle, paperBlocks, type Block, type PaperDocument } from "../lib/papers.ts";

const paper = (o: Record<string, unknown>): PaperDocument => o as unknown as PaperDocument;

test("paperSlug prefers slug, then _publishedId, then _id", () => {
  assert.equal(paperSlug(paper({ slug: "my-paper", _publishedId: "p1", _id: "drafts.p1" })), "my-paper");
  assert.equal(paperSlug(paper({ _publishedId: "p1", _id: "drafts.p1" })), "p1");
  assert.equal(paperSlug(paper({ _id: "p1" })), "p1");
});

test("paperBlocks reads top-level blocks, else body.blocks, else []", () => {
  const top: Block[] = [{ type: "heading", text: "H" }];
  const body: Block[] = [{ type: "paragraph" }];
  assert.deepEqual(paperBlocks(paper({ blocks: top })), top);
  assert.deepEqual(paperBlocks(paper({ body: { blocks: body } })), body);
  assert.deepEqual(paperBlocks(paper({})), []);
  // Top-level blocks win over the nested body.
  assert.deepEqual(paperBlocks(paper({ blocks: top, body: { blocks: body } })), top);
});

test("paperTitle prefers title, else the first heading, else (untitled)", () => {
  assert.equal(paperTitle(paper({ title: "My Title" })), "My Title");
  assert.equal(
    paperTitle(paper({ blocks: [{ type: "paragraph", text: "p" }, { type: "heading", text: "H1" }] })),
    "H1",
  );
  assert.equal(paperTitle(paper({ blocks: [{ type: "paragraph" }] })), "(untitled)");
  assert.equal(paperTitle(paper({})), "(untitled)");
  // An empty title falls through to the first heading.
  assert.equal(paperTitle(paper({ title: "", blocks: [{ type: "heading", text: "H" }] })), "H");
});
