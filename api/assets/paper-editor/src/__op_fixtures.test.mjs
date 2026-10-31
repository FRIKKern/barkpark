import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { applyOps } from "./smoke/harness.mjs";
import {
  buildCardBodyOp,
  buildTableCellsOp,
  cardBodyProjection,
  tableProjection,
  tableProjectionMatchesAction,
  tableProjectionMatchesCells,
} from "./convert.js";

const dir = new URL("../../../priv/portable_doc/goldens/ops/", import.meta.url);
const fixtures = Object.fromEntries(readdirSync(dir).filter((name) => name.endsWith(".json")).map((name) => {
  const fixture = JSON.parse(readFileSync(new URL(name, dir), "utf8"));
  return [fixture.op.op, fixture];
}));

assert.deepEqual(Object.keys(fixtures).sort(), [
  "append-block", "insert-after", "move-block", "patch-block", "patch-card-body",
  "patch-table-cells", "patch-table-structure", "remove-block", "replace-block",
], "the golden pack carries one op fixture per edit verb");

for (const verb of ["append-block", "insert-after", "patch-block", "replace-block", "remove-block", "move-block"]) {
  const { before, op, after } = fixtures[verb];
  assert.deepEqual(applyOps(before.blocks, [op]), after.blocks, `${verb}: the editor's patch.ex fold lands on the server's after`);
}

assert.throws(() => applyOps(fixtures["insert-after"].before.blocks, [{ ...fixtures["insert-after"].op, afterId: "absent" }]),
  /afterId not found absent/, "insert-after: a missing anchor is an error, as in patch.ex");

const card = fixtures["patch-card-body"];
const byId = (doc) => doc.blocks.find((block) => block.id === card.op.id);
assert.deepEqual(buildCardBodyOp(cardBodyProjection(byId(card.after)).doc, byId(card.before)), card.op,
  "patch-card-body: the editor emits the server's op for the server's after");

const cells = fixtures["patch-table-cells"];
assert.deepEqual(buildTableCellsOp(tableProjection(cells.tableProjections.after).doc, cells.tableProjections.before), cells.op,
  "patch-table-cells: the editor emits the server's op for the server's after");
assert.ok(tableProjectionMatchesCells(cells.tableProjections.after, cells.op.cells),
  "patch-table-cells: the editor reads the server's after as its own cells landing");

const structure = fixtures["patch-table-structure"];
assert.deepEqual(tableProjection(structure.tableProjections.before).shape, structure.op.shape,
  "patch-table-structure: the op carries the shape the editor projects");
assert.ok(tableProjectionMatchesAction(structure.tableProjections.before, structure.tableProjections.after, structure.op.action),
  "patch-table-structure: the editor predicts the server's after for the action");

console.log("PASS  op fixtures: the editor agrees with the server on all 9 edit verbs");
