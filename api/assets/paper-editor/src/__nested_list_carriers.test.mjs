import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { blockToTiptap, tiptapToBlock } from "./convert.js";

const fixture = JSON.parse(readFileSync(new URL("../../../test/support/fixtures/nested-list-carriers.json", import.meta.url)));
const block = fixture.blocks[0];
const clone = value => structuredClone(value);
const originalBlock = clone(block);
const words = node => [node.text || "", ...(node.content || []).map(words)].join("");
const save = doc => tiptapToBlock(doc, block.id, "list");
const projected = blockToTiptap(block);
assert.equal(words(projected), "PlanBuildVerifyShipFlat siblingFallback parentAlias child",
  "projection includes every nested word in reader order");
assert.deepEqual(save(projected), { ordered: false, items: block.items }, "nested no-op is exact");

const changed = clone(projected);
changed.content[0].content[0].content[1].content[0].content[0].content[0].text = "Build carefully";
const expected = clone(block.items);
expected[0].children[0].items[0].text = "Build carefully";
assert.deepEqual(save(changed).items, expected, "a child edit preserves all other carriers and metadata");
assert.deepEqual(block, originalBlock, "projection never mutates source");

const opaque = { type: "list", items: [{ id: "parent", text: "Parent", children: [
  { type: "paragraph", text: "opaque", audit: true },
  { id: "frame", type: "ordered-list", ordered: false, style: "authored", items: ["Child"] },
  null,
  { type: "list", items: "invalid" },
] }] };
const withOpaque = blockToTiptap(opaque);
assert.equal(words(withOpaque), "ParentChild");
assert.deepEqual(tiptapToBlock(withOpaque, "opaque", "list").items, opaque.items);
withOpaque.content[0].content[0].content[1].type = "bulletList";
const markerChange = clone(opaque.items);
markerChange[0].children[1] = { ...markerChange[0].children[1], type: "list", ordered: false };
assert.deepEqual(tiptapToBlock(withOpaque, "opaque", "list").items, markerChange,
  "changing an ordered alias keeps frame metadata and opaque child slots");

const empty = { type: "list", items: [{ text: "Parent", children: [{ id: "empty", type: "list", items: [] }] }] };
assert.deepEqual(tiptapToBlock(blockToTiptap(empty), "empty", "list").items, empty.items,
  "the editor placeholder for an empty nested list must not create a stored item");

const splitFrame = blockToTiptap(opaque);
const frame = splitFrame.content[0].content[0].content[1];
splitFrame.content[0].content[0].content.push(clone(frame));
const duplicateFrames = tiptapToBlock(splitFrame, "opaque", "list").items[0].children;
assert.equal(duplicateFrames.filter(child => child?.id === "frame").length, 1,
  "native frame copies retain the original frame identity only once");
assert.deepEqual(duplicateFrames.at(-1), { type: "list", ordered: true, items: ["Child"] });
console.log("nested list carrier projection and serialization passed");
