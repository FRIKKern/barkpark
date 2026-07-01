/**
 * Tests for listing/search excerpt extraction. PortableDoc stores marked-up
 * runs (bold/link/em) as WRAPPER nodes whose text lives in `children`, not as a
 * flat `.value` leaf — so a paragraph that opens with a styled run must still
 * yield its text. Runs under Node's built-in test runner (`node --test`), which
 * strips TypeScript types at load time in Node v22+.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/paper-excerpt.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { paperExcerpt, type Block, type PaperDocument } from "../lib/papers.ts";
import { inlineText } from "../lib/find.ts";

/** Build a minimal PaperDocument carrying just the block array under test. */
function paperWith(blocks: Block[]): PaperDocument {
  return { blocks } as unknown as PaperDocument;
}

test("excerpt keeps text inside a leading link/strong wrapper run", () => {
  const paper = paperWith([
    {
      type: "paragraph",
      content: [
        { type: "link", href: "/x", children: [{ type: "text", value: "Barkpark" }] },
        " is a CMS.",
      ],
    },
  ]);
  const excerpt = paperExcerpt(paper);
  assert.ok(excerpt, "excerpt should not be null");
  assert.ok(excerpt!.includes("Barkpark"), "wrapped run text must survive");
  assert.equal(excerpt, "Barkpark is a CMS.");
});

test("all-bold opening paragraph yields a non-empty excerpt", () => {
  const paper = paperWith([
    {
      type: "paragraph",
      content: [{ type: "strong", children: [{ type: "text", value: "Fully bold intro." }] }],
    },
  ]);
  const excerpt = paperExcerpt(paper);
  assert.ok(excerpt && excerpt.length > 0, "all-bold paragraph must still excerpt");
  assert.equal(excerpt, "Fully bold intro.");
});

test("plain-text paragraph still excerpts (no regression)", () => {
  const paper = paperWith([
    { type: "paragraph", content: [{ type: "text", value: "Plain words." }] },
  ]);
  assert.equal(paperExcerpt(paper), "Plain words.");
});

test("empty / no paragraph returns null", () => {
  assert.equal(paperExcerpt(paperWith([])), null);
  assert.equal(paperExcerpt(paperWith([{ type: "heading", text: "Title" }])), null);
});

test("inlineText descends nested wrappers and bare string/number leaves", () => {
  assert.equal(
    inlineText([
      { type: "em", children: [{ type: "strong", children: [{ type: "text", value: "deep" }] }] },
      " ",
      42,
    ]),
    "deep 42",
  );
});
