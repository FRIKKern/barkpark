// __heading_levels.test.mjs — D-headings: the canvas offers three levels; a deeper stored level
// (an import, an agent) is shown at the nearest level, carried on the source, and never
// rewritten by a text edit; a turn-into to another level is the author's change and wins.
// Run: node src/__heading_levels.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";

let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

const H4 = { id: "h4", type: "heading", level: 4, text: "Deep" };
const H2 = { id: "h2", type: "heading", level: 2, text: "Plain" };

check("a level-4 heading is shown at level 3 and round-trips as level 4", () => {
  const doc = runToTiptap([H4, H2]);
  assert.equal(doc.content[0].attrs.level, 3, "shown at the nearest level");
  assert.deepEqual(docToBlocks(doc), [H4, H2]);
  assert.deepEqual(runToOps([H4, H2], doc), []);
});

check("editing the text of a level-4 heading keeps level 4 on the patch", () => {
  const doc = runToTiptap([H4]);
  doc.content[0].content = [{ type: "text", text: "Deeper" }];
  const ops = runToOps([H4], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].patch.level, 4, JSON.stringify(ops[0]));
  assert.equal(ops[0].patch.text, "Deeper");
});

check("turning a level-4 heading into level 2 is the author's change and wins", () => {
  const doc = runToTiptap([H4]);
  doc.content[0].attrs.level = 2;
  const ops = runToOps([H4], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.level, 2, JSON.stringify(ops[0]));
});

check("a level-2 heading carries no level on its source and patches as level 2", () => {
  const doc = runToTiptap([H2]);
  assert.equal(doc.content[0].attrs.bpHeadingSource.level, undefined);
  doc.content[0].content = [{ type: "text", text: "Plainer" }];
  assert.equal(runToOps([H2], doc)[0].patch.level, 2);
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
