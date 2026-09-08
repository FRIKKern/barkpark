import assert from "node:assert/strict";
import { blockToTiptap, tiptapToBlock } from "./convert.js";

const source = { id: "p", type: "paragraph", content: [], text: "Legacy paragraph" };
const doc = blockToTiptap(source);
assert.equal(doc.content[0].content[0].text, source.text);
assert.deepEqual(tiptapToBlock(doc, "p", "paragraph"), { content: [], text: source.text });
doc.content[0].content[0].text = "Edited paragraph";
assert.deepEqual(tiptapToBlock(doc, "p", "paragraph"), { content: [], text: "Edited paragraph" });
const rich = { ...source, content: [{ type: "strong", children: [{ type: "text", value: "Primary" }] }] };
const richDoc = blockToTiptap(rich);
assert.equal(richDoc.content[0].content[0].text, "Primary");
assert.deepEqual(tiptapToBlock(richDoc, "p", "paragraph"), { content: rich.content, text: source.text });
richDoc.content[0].content = [];
assert.deepEqual(tiptapToBlock(richDoc, "p", "paragraph"), { content: [], text: "" });
for (const fields of [{}, { content: [] }, { text: 12 }, { text: null }, { content: "ignored scalar", text: "Fallback" }]) {
  const projected = blockToTiptap({ id: "p", type: "paragraph", ...fields });
  assert.deepEqual(tiptapToBlock(projected, "p", "paragraph"), fields);
}
console.log("paragraph carrier preservation passed");
