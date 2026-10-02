// An edit to one run of a paragraph, heading or list item keeps every run it did not
// reach exactly as the author stored it: `strike`/`s` spellings, flat `marks` leaves,
// legacy `text` keys and unknown keys survive; only the edited stretch is re-serialized.
// Found by the r2b click-to-edit census: typing into the showcase paragraph's first run
// rewrote its untouched `strike` run as `strikethrough` (.content.5.type drift).
import assert from "node:assert/strict";
import { blockToTiptap, tiptapToBlock } from "./convert.js";

const text = (value) => ({ type: "text", value });
const showcase = {
  id: "p", type: "paragraph", content: [
    text("A paragraph carries every inline mark: "),
    { type: "strong", children: [text("strong")] },
    text(", "),
    { type: "em", children: [text("emphasis")] },
    text(", "),
    { type: "strike", children: [text("struck-through")] },
    text(", inline "),
    { type: "code", value: "code()" },
    text(", and a "),
    { type: "link", href: "https://example.test/doctrine", children: [text("link to the doctrine")] },
    text(". The same marks survive."),
  ],
};

// Typing into the first run (a click between its first two characters).
const doc = blockToTiptap(showcase);
const first = doc.content[0].content[0];
first.text = first.text.slice(0, 1) + "QZMRK" + first.text.slice(1);
const edited = tiptapToBlock(doc, "p", "paragraph");
assert.deepEqual(edited.content[0], text("AQZMRK paragraph carries every inline mark: "));
assert.deepEqual(edited.content.slice(1), showcase.content.slice(1), "untouched runs keep their source nodes (strike stays strike)");

// Typing into the middle run: both ends are kept verbatim, the middle re-serializes.
const flat = {
  id: "q", type: "paragraph", content: [
    { type: "text", value: "Lead ", qa: "keep-me" },
    { type: "text", value: "flat bold", marks: [{ type: "bold" }] },
    { type: "text", text: " legacy tail" },
  ],
};
const flatDoc = blockToTiptap(flat);
const nodes = flatDoc.content[0].content;
assert.equal(nodes.length, 3);
nodes[1].text = "flat boldX";
const flatEdited = tiptapToBlock(flatDoc, "q", "paragraph");
// The flat bold leaf is the leading part of the edited bold text, so it is kept and
// only the typed "X" is new; the unknown key and the legacy text-key leaf survive.
assert.deepEqual(flatEdited.content, [flat.content[0], flat.content[1], { type: "strong", children: [text("X")] }, flat.content[2]]);

// Heading with rich content: an edit at the end keeps the leading strike run.
const heading = { id: "h", type: "heading", level: 2, content: [{ type: "s", children: [text("Old")] }, text(" title")] };
const hDoc = blockToTiptap(heading);
const hNodes = hDoc.content[0].content;
hNodes[hNodes.length - 1].text += "!";
const hEdited = tiptapToBlock(hDoc, "h", "heading");
assert.deepEqual(hEdited.content, [{ type: "s", children: [text("Old")] }, text(" title!")]);

// A list item carried as an inline array keeps its untouched runs.
const list = { id: "l", type: "list", ordered: false, items: [[{ type: "strike", children: [text("gone")] }, text(" item")]] };
const lDoc = blockToTiptap(list);
const para = lDoc.content[0].content[0].content[0];
para.content[para.content.length - 1].text = " itemZ";
const lEdited = tiptapToBlock(lDoc, "l", "list");
assert.deepEqual(lEdited.items[0], [{ type: "strike", children: [text("gone")] }, text(" itemZ")]);

// An edit that merges into a neighbour (typing bold next to bold) still projects exactly.
const merge = { id: "m", type: "paragraph", content: [text("a "), { type: "strong", children: [text("b")] }, text(" c")] };
const mDoc = blockToTiptap(merge);
const mNodes = mDoc.content[0].content;
mNodes[0] = { type: "text", text: "a ", marks: [{ type: "bold" }] };
const mEdited = tiptapToBlock(mDoc, "m", "paragraph");
assert.deepEqual(blockToTiptap({ ...merge, content: mEdited.content }).content[0].content
  .reduce((acc, n) => acc + n.text, ""), "a b c");
assert.deepEqual(mEdited.content[mEdited.content.length - 1], text(" c"));

console.log("inline source reuse passed");
