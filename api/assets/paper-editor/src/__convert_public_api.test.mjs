// Public conversion seams that must survive internal module extraction.
// Run: node src/__convert_public_api.test.mjs
import assert from "node:assert/strict";
import * as convert from "./convert.js";

const expectedExports = [
  "blockToTiptap",
  "buildCardBodyOp",
  "buildPatchBlockOp",
  "buildTableCellsOp",
  "cardBodyContentMatches",
  "cardBodyProjection",
  "cardBodyTiptapDocSupported",
  "inlineArrayToTiptap",
  "listStart",
  "tableProjection",
  "tableProjectionMatchesAction",
  "tableProjectionMatchesCells",
  "tableTiptapDocSupported",
  "tiptapInlineToPd",
  "tiptapToBlock",
  "tiptapToFullBlock",
];

assert.deepEqual(Object.keys(convert).sort(), expectedExports,
  "convert.js exposes exactly the public conversion namespace");

const opaque = {
  type: "future-inline",
  payload: { nested: [{ value: "source" }] },
};
const projected = convert.inlineArrayToTiptap([opaque]);
assert.notStrictEqual(projected[0].attrs.node, opaque,
  "an opaque inline projection owns its cloned carrier");
projected[0].attrs.node.payload.nested[0].value = "projected";
assert.equal(opaque.payload.nested[0].value, "source",
  "mutating an opaque inline projection does not mutate the source node");

const table = {
  type: "table",
  id: "property-order",
  shape: {
    v: 1,
    head: { state: "absent" },
    rows: [{ kind: "array", cells: ["inline-array"] }],
  },
  head: null,
  rows: [[[{ type: "text", value: "Cell" }]]],
};
const reorderedCell = { value: "Cell", type: "text" };
assert.equal(convert.tableProjectionMatchesCells(table, [{
  area: "body",
  row: 0,
  column: 0,
  content: [reorderedCell],
}]), true, "table cell matching ignores JSON object property insertion order");

console.log("PASS  convert public API: namespace, cloning, and JSON equality are stable");
