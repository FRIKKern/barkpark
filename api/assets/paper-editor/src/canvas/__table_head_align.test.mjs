// __table_head_align.test.mjs — header column and per-cell alignment on the table block (Barkdown
// plan #26), pure Node. `headCol: true` marks each body row's first cell a row header; a cell's
// `align` ("center" | "right") rides the stored cell as a content-map { content, align } and left
// drops it (back to the plain inline array). Both round-trip byte-exact and patch as one op.
// Run: node src/canvas/__table_head_align.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./run-convert.js";

let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }
const t = (v) => [{ type: "text", value: v }];
const PLAIN = { id: "t1", type: "table", head: [t("A"), t("B")], rows: [[t("a1"), t("b1")], [t("a2"), t("b2")]] };
const HEADCOL = { ...PLAIN, id: "t2", headCol: true };
const ALIGNED = { ...PLAIN, id: "t3", rows: [[t("a1"), { content: t("b1"), align: "right" }], [{ content: t("a2"), align: "center" }, t("b2")]] };

check("headCol marks the first body cells as row headers and round-trips byte-identically", () => {
  const doc = runToTiptap([HEADCOL]);
  const rows = doc.content[0].content;
  assert.equal(doc.content[0].attrs.headCol, true);
  assert.equal(rows[1].content[0].attrs.head, true);
  assert.equal(rows[1].content[1].attrs.head, false);
  assert.equal(rows[0].content[0].attrs.head, false, "the header row's cells are column headers, not row headers");
  assert.deepEqual(docToBlocks(doc), [HEADCOL]);
  assert.deepEqual(runToOps([HEADCOL], doc), []);
  assert.equal(runToTiptap([PLAIN]).content[0].attrs.headCol, false);
});

check("toggling the header column on / off emits one patch with headCol true / false", () => {
  const doc = runToTiptap([PLAIN]);
  doc.content[0].attrs.headCol = true;
  const on = runToOps([PLAIN], doc);
  assert.equal(on.length, 1, JSON.stringify(on));
  assert.equal(on[0].patch.headCol, true);
  const doc2 = runToTiptap([HEADCOL]);
  doc2.content[0].attrs.headCol = false;
  const off = runToOps([HEADCOL], doc2);
  assert.equal(off.length, 1, JSON.stringify(off));
  assert.equal(off[0].patch.headCol, false);
});

check("aligned cells mount with the align attr and round-trip byte-identically", () => {
  const doc = runToTiptap([ALIGNED]);
  const rows = doc.content[0].content;
  assert.equal(rows[1].content[1].attrs.align, "right");
  assert.equal(rows[2].content[0].attrs.align, "center");
  assert.equal(rows[1].content[0].attrs.align, null);
  assert.deepEqual(docToBlocks(doc), [ALIGNED]);
  assert.deepEqual(runToOps([ALIGNED], doc), []);
});

check("aligning a plain cell stores { content, align }; back to left returns the plain inline array", () => {
  const doc = runToTiptap([PLAIN]);
  doc.content[0].content[1].content[0].attrs.align = "right";
  const ops = runToOps([PLAIN], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.deepEqual(ops[0].patch.rows[0][0], { content: t("a1"), align: "right" });
  assert.deepEqual(ops[0].patch.rows[0][1], t("b1"));
  const doc2 = runToTiptap([ALIGNED]);
  doc2.content[0].content[1].content[1].attrs.align = null;
  const ops2 = runToOps([ALIGNED], doc2);
  assert.equal(ops2.length, 1, JSON.stringify(ops2));
  assert.deepEqual(ops2[0].patch.rows[0][1], t("b1"));
  assert.deepEqual(ops2[0].patch.rows[1][0], { content: t("a2"), align: "center" }, "the other aligned cell is untouched");
});

check("untouched explicit false and unknown cell alignment retain source metadata", () => {
  const source = { ...PLAIN, headCol: false, rows: [[{ content: t("a"), align: "justify", note: "keep" }, t("b")]] };
  assert.deepEqual(docToBlocks(runToTiptap([source])), [source]);
  assert.deepEqual(runToOps([source], runToTiptap([source])), []);
});

check("a spanning row header does not make the next row's second column a header", () => {
  const source = { ...HEADCOL, rows: [[t("both"), t("b1")], [[], t("b2")]], spans: [{ row: 0, col: 0, rowspan: 2, colspan: 1 }] };
  const doc = runToTiptap([source]);
  assert.equal(doc.content[0].content[1].content[0].attrs.head, true);
  assert.equal(doc.content[0].content[2].content[0].attrs.head, false);
  assert.deepEqual(docToBlocks(doc), [source]);
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
