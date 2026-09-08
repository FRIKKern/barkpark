import assert from "node:assert/strict";
import { blockToTiptap, tiptapToBlock } from "./convert.js";

const inline = [{ type: "strong", children: [{ type: "text", value: "Visible title" }] }];
const block = { id: "h", type: "heading", level: 2, content: inline, text: "stale fallback" };
const doc = blockToTiptap(block);
assert.equal(doc.content[0].content[0].text, "Visible title");
assert.deepEqual(tiptapToBlock(doc, "h", "heading"), { level: 2, content: inline, text: "stale fallback" });
doc.content[0].content[0].text = "Changed title";
assert.deepEqual(tiptapToBlock(doc, "h", "heading"), { level: 2, content: [{ type: "strong", children: [{ type: "text", value: "Changed title" }] }], text: "stale fallback" });
doc.content[0].content = [];
assert.deepEqual(tiptapToBlock(doc, "h", "heading"), { level: 2, content: [], text: "" });
const numericFallback = blockToTiptap({ ...block, text: 12 });
numericFallback.content[0].content = [];
assert.deepEqual(tiptapToBlock(numericFallback, "h", "heading"), { level: 2, content: [], text: "" });
const freshRich = blockToTiptap(block);
delete freshRich.content[0].attrs.bpHeadingSource;
assert.deepEqual(tiptapToBlock(freshRich, "h", "heading"), { level: 2, content: inline });
for (const text of [12, false, "Plain title"]) {
  const source = { id: "h", type: "heading", level: 1, text };
  const projected = blockToTiptap(source);
  assert.equal(projected.content[0].content[0].text, String(text));
  assert.deepEqual(tiptapToBlock(projected, "h", "heading"), { level: 1, text });
}
console.log("heading carrier projection and serialization passed");
