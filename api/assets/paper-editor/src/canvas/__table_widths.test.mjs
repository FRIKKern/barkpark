// __table_widths.test.mjs — column widths on the table block (Barkdown plan #25), pure Node.
// `cols[i].width` (CSS px) rides the node as `colWidths`; the diff writes it back beside the
// reader's column types, emits `cols` on the patch, and `cols: []` when the last entry goes.
// Run: node src/canvas/__table_widths.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./run-convert.js";

let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }
const t = (v) => [{ type: "text", value: v }];
const PLAIN = { id: "t1", type: "table", head: [t("A"), t("B")], rows: [[t("a1"), t("b1")]] };
const WIDE = { ...PLAIN, id: "t2", cols: [{ width: 220 }, { type: "num" }] };

check("widths mount as colWidths (null where unset) and round-trip byte-identically; a plain table has none", () => {
  const doc = runToTiptap([WIDE]);
  assert.deepEqual(doc.content[0].attrs.colWidths, [220, null]);
  assert.deepEqual(docToBlocks(doc), [WIDE]);
  assert.deepEqual(runToOps([WIDE], doc), []);
  const plain = runToTiptap([PLAIN]);
  assert.equal(plain.content[0].attrs.colWidths, null);
  assert.deepEqual(docToBlocks(plain), [PLAIN]);
});

check("dragging a column (colWidths changes) emits ONE patch carrying cols with the width beside the existing type", () => {
  const doc = runToTiptap([WIDE]);
  doc.content[0].attrs.colWidths = [220, 90];
  const ops = runToOps([WIDE], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "patch-block");
  assert.deepEqual(ops[0].patch.cols, [{ width: 220 }, { type: "num", width: 90 }]);
});

check("a plain table gaining a width emits cols; clearing every width on a width-only table emits cols: []", () => {
  const doc = runToTiptap([PLAIN]);
  doc.content[0].attrs.colWidths = [null, 150];
  const ops = runToOps([PLAIN], doc);
  assert.equal(ops.length, 1);
  assert.deepEqual(ops[0].patch.cols, [{}, { width: 150 }]);
  const only = { ...PLAIN, id: "t3", cols: [{ width: 100 }] };
  const doc2 = runToTiptap([only]);
  doc2.content[0].attrs.colWidths = null;
  const ops2 = runToOps([only], doc2);
  assert.equal(ops2.length, 1, JSON.stringify(ops2));
  assert.deepEqual(ops2[0].patch.cols, []);
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
