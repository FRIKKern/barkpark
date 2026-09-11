import assert from "node:assert/strict";
import { blockToTiptap, tiptapToBlock, inlineArrayToTiptap } from "./convert.js";

const text = value => ({ type: "text", value });
const items = [
  { id: "rich", content: [{ type: "strong", children: [text("Alpha")] }], text: "stale", audit: { keep: true } },
  { id: "fallback", content: [], text: "Beta", audit: [1, 2] },
  '[{"type":"text","value":"Gamma"}]',
  "Delta",
  12,
  [text("Epsilon")],
];
const block = { id: "list", type: "list", ordered: false, items };
const projected = blockToTiptap(block);
assert.deepEqual(projected.content[0].content.map(li => li.content[0].content.map(n => n.text).join("")),
  ["Alpha", "Beta", "Gamma", "Delta", "12", "Epsilon"]);
assert.deepEqual(tiptapToBlock(projected, "list", "list").items, items,
  "no-op projection preserves every original carrier");
projected.content[0].content[0].content[0].content[0].text = "Changed";
const edited = tiptapToBlock(projected, "list", "list").items;
assert.deepEqual(edited[0], { ...items[0], content: [{ type: "strong", children: [text("Changed")] }] });
assert.deepEqual(edited.slice(1), items.slice(1), "editing one item preserves all siblings exactly");
projected.content[0].content.reverse();
assert.deepEqual(tiptapToBlock(projected, "list", "list").items, [...edited].reverse(),
  "source metadata follows its item, not its former position");
assert.deepEqual(block.items, items, "conversion never mutates the source");
assert.deepEqual(inlineArrayToTiptap(items[2]), [{ type: "text", text: items[2] }],
  "list-only decoding never changes literal paragraph strings");
const cleared = blockToTiptap(block);
cleared.content[0].content[0].content[0].content = [];
assert.deepEqual(tiptapToBlock(cleared, "list", "list").items[0],
  { ...items[0], content: [], text: "" }, "clearing content cannot revive stale fallback text");
const fallback = blockToTiptap(block);
fallback.content[0].content[1].content[0].content[0].text = "Updated";
assert.deepEqual(tiptapToBlock(fallback, "list", "list").items[1],
  { ...items[1], text: "Updated" }, "plain edits retain the text carrier and empty content marker");
console.log("list carrier conversion preservation passed");
