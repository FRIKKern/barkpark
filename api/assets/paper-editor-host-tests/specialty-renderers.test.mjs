// Canonical specialty fixtures project through the mounted bpFleet host-paint seam.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runToTiptap, runToOps, docToBlocks } from "../paper-editor/src/canvas/run-convert.js";
import { BP_FLEET_NODE_NAME } from "../paper-editor/src/canvas/embed-node.js";

const TYPES = [
  "api-endpoint",
  "bar-chart",
  "code-tabs",
  "criteria-progress",
  "gauge-list",
  "route",
];

const blocks = TYPES.map((type) => {
  const path = join("../../priv/portable_doc/goldens/blocks", `${type}.golden.json`);
  return { ...JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8")).input, id: type };
});

const doc = runToTiptap(blocks);

assert.equal(doc.content.length, TYPES.length);
for (const [index, node] of doc.content.entries()) {
  const block = blocks[index];
  assert.equal(node.type, BP_FLEET_NODE_NAME, `${block.type}: mounted host-paint node`);
  assert.equal(node.attrs.bpId, block.id, `${block.type}: id stamped`);
  assert.equal(node.attrs.bpType, block.type, `${block.type}: kind stamped`);
  assert.deepEqual(node.attrs.bpBlock, block, `${block.type}: full source carried`);
  assert.notEqual(node.attrs.bpBlock, block, `${block.type}: source deep-cloned`);
}

assert.deepEqual(runToOps(blocks, doc), [], "untouched specialty nodes emit zero ops");
assert.deepEqual(docToBlocks(doc), blocks, "specialty nodes round-trip byte-for-byte");

console.log("specialty renderers: 6 mounted host-paint projections passed");
