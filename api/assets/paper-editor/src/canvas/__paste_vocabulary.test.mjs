// fitBlocksToVocabulary: a paste is fitted to the field's vocabulary node by
// node and never dropped whole (task-76c5440175affe20).
// Run: node src/canvas/__paste_vocabulary.test.mjs
import assert from "node:assert/strict";
import { fitBlocksToVocabulary, blocksNeedFitting, droppedNotice } from "./paste-vocabulary.js";
import { parseVocabulary } from "./vocabulary.js";

const SANITY = parseVocabulary({ styles: ["normal", "h2", "h3", "blockquote"], lists: ["bullet"], marks: ["strong", "em", "code"], annotations: [{ name: "link" }] });
const BARE = parseVocabulary({ styles: ["normal"], marks: [] });
const txt = (value) => [{ type: "text", value }];
const types = (r) => r.blocks.map((b) => b.type);

let passed = 0;
function test(name, run) { run(); console.log("PASS " + name); passed++; }

test("a blockquote becomes the field's quote block (the blockquote STYLE is the pullquote)", () => {
  const r = fitBlocksToVocabulary([{ id: "q", type: "blockquote", content: txt("MD quote") }], SANITY);
  assert.deepEqual(r.blocks, [{ id: "q", type: "pullquote", content: txt("MD quote") }]);
  assert.deepEqual(r.dropped, []);
});

test("a quote in a field with no quote style becomes a paragraph, text kept", () => {
  const r = fitBlocksToVocabulary([{ id: "q", type: "blockquote", content: txt("Kept") }], BARE);
  assert.deepEqual(r.blocks, [{ id: "q", type: "paragraph", content: txt("Kept") }]);
});

test("a table becomes one paragraph per cell, header first", () => {
  const table = { id: "t", type: "table", head: [txt("A"), txt("B")], rows: [[txt("1"), txt("2")]] };
  const r = fitBlocksToVocabulary([table], SANITY);
  assert.deepEqual(r.blocks.map((b) => b.content[0].value), ["A", "B", "1", "2"]);
  assert.deepEqual(new Set(types(r)), new Set(["paragraph"]));
  assert.equal(new Set(r.blocks.map((b) => b.id)).size, 4, "each cell paragraph has its own id");
});

test("a code block becomes a paragraph with a code mark, or plain text without one", () => {
  const code = { id: "c", type: "code", value: "const x = 1" };
  assert.deepEqual(fitBlocksToVocabulary([code], SANITY).blocks, [{ id: "c", type: "paragraph", content: [{ type: "code", value: "const x = 1" }] }]);
  assert.deepEqual(fitBlocksToVocabulary([code], BARE).blocks, [{ id: "c", type: "paragraph", content: txt("const x = 1") }]);
});

test("an image is left out and named; a figure keeps its caption text", () => {
  const r = fitBlocksToVocabulary([{ id: "i", type: "image", src: "x.png", alt: "" }, { id: "p", type: "paragraph", content: txt("After") }], SANITY);
  assert.deepEqual(types(r), ["paragraph"]);
  assert.deepEqual(r.dropped, ["an image"]);
  const f = fitBlocksToVocabulary([{ id: "f", type: "figure", caption: "A caption", children: [] }], SANITY);
  assert.deepEqual(f.blocks, [{ id: "f", type: "paragraph", content: txt("A caption") }]);
  assert.deepEqual(f.dropped, ["an image"]);
});

test("headings, list kinds and marks the field lacks are coerced, never dropped", () => {
  const r = fitBlocksToVocabulary([
    { id: "h", type: "heading", level: 1, text: "Top" },
    { id: "l", type: "list", ordered: true, items: [txt("one")] },
    { id: "p", type: "paragraph", content: [{ type: "underline", children: txt("under") }, { type: "strong", children: txt("bold") }] },
  ], SANITY);
  assert.equal(r.blocks[0].level, 2);
  assert.equal(r.blocks[1].ordered, false);
  assert.deepEqual(r.blocks[2].content, [{ type: "text", value: "under" }, { type: "strong", children: txt("bold") }]);
  const bare = fitBlocksToVocabulary([{ id: "h", type: "heading", level: 2, text: "Top" }, { id: "l", type: "list", items: [txt("a"), txt("b")] }], BARE);
  assert.deepEqual(types(bare), ["paragraph", "paragraph", "paragraph"]);
});

test("an in-vocabulary paste needs no fitting (the native slice is kept)", () => {
  const blocks = [{ id: "p", type: "paragraph", content: [{ type: "strong", children: txt("b") }] }, { id: "h", type: "heading", level: 2, text: "H" }];
  assert.equal(blocksNeedFitting(blocks, SANITY), false);
  assert.equal(blocksNeedFitting([{ id: "q", type: "blockquote", content: txt("q") }], SANITY), true);
  assert.equal(blocksNeedFitting(blocks, null), false, "no vocabulary (a paper canvas) never fits");
});

test("the notice names what was left out, counted", () => {
  assert.equal(droppedNotice([]), null);
  assert.match(droppedNotice(["an image", "an image", "block:diagram"]), /Left out: an image \(×2\), a diagram block\./);
});

console.log(`\n${passed} passed`);
