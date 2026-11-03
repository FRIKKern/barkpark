// The six Canvas specialty renderers use the mounted bpFleet host-paint seam:
// source data rides verbatim in the ProseMirror node and the host supplies the
// canonical reader HTML. This test locks projection/round-trip behavior; the
// conformance runner mounts the same node-view and proves the painted DOM shapes.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import { BP_FLEET_NODE_NAME, fleetChipLabel } from "./canvas/embed-node.js";

const TYPES = [
  "api-endpoint",
  "bar-chart",
  "code-tabs",
  "criteria-progress",
  "gauge-list",
  "route",
];

const blocks = TYPES.map((type) => {
  const path = join("../../../priv/portable_doc/goldens/blocks", `${type}.golden.json`);
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
assert.equal(
  runToTiptap([{ id: "unknown", type: "not-a-specialty" }]).content[0].type,
  "bpOpaque",
  "unknown blocks remain honestly missing",
);

assert.deepEqual(
  blocks.map(fleetChipLabel),
  ["API endpoint", "Bar chart", "Code tabs", "Criteria progress", "Gauge list", "Route"],
  "pre-paint fallbacks name every specialty block",
);

console.log("specialty renderers: 6 mounted host-paint projections passed");
