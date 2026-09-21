// __table_spans.test.mjs — merged cells on the table block (Barkdown plan #24), pure Node.
// The block keeps a rectangular grid and a `spans` list; covered positions hold `[]` placeholders.
// The canvas holds only visible cells with colspan/rowspan attrs. Both directions round-trip
// byte-exact, a merge is one patch carrying rows + spans, a split clears them with `spans: []`,
// and the grid transforms keep merged cells consistent through add/remove row/col.
// Run: node src/canvas/__table_spans.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./run-convert.js";
import { gridTransforms, gridToVisible, visibleToGrid, normalizeSpans, coverMap } from "./table-grid.js";

let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }
const t = (v) => [{ type: "text", value: v }];

const PLAIN = { id: "t1", type: "table", head: [t("A"), t("B"), t("C")], rows: [[t("a1"), t("b1"), t("c1")], [t("a2"), t("b2"), t("c2")], [t("a3"), t("b3"), t("c3")]] };
const MERGED = { ...PLAIN, id: "t2", rows: [[t("a1+b1"), [], t("c1")], [t("a2"), t("b2"), t("c2")], [t("a3"), t("b3"), t("c3")]], spans: [{ row: 0, col: 0, colspan: 2, rowspan: 1 }] };
const TALL = { ...PLAIN, id: "t3", rows: [[t("a1"), t("b1"), t("c1")], [t("tall"), t("b2"), t("c2")], [[], t("b3"), t("c3")]], spans: [{ row: 1, col: 0, colspan: 1, rowspan: 2 }] };

check("a plain table mounts with colspan/rowspan 1 everywhere and round-trips byte-identically", () => {
  const doc = runToTiptap([PLAIN]);
  const table = doc.content[0];
  assert.equal(table.type, "bpTable");
  for (const row of table.content) for (const cell of row.content) { assert.equal(cell.attrs.colspan, 1); assert.equal(cell.attrs.rowspan, 1); }
  assert.deepEqual(docToBlocks(doc), [PLAIN]);
  assert.deepEqual(runToOps([PLAIN], doc), []);
});

check("a merged table mounts WITHOUT the covered cell and with colspan on the origin; round-trips byte-identically", () => {
  const doc = runToTiptap([MERGED]);
  const rows = doc.content[0].content;
  assert.equal(rows[0].content.length, 3, "head row: three cells");
  assert.equal(rows[1].content.length, 2, "first body row: two visible cells");
  assert.equal(rows[1].content[0].attrs.colspan, 2);
  assert.equal(rows[2].content.length, 3);
  assert.deepEqual(docToBlocks(doc), [MERGED]);
  assert.deepEqual(runToOps([MERGED], doc), []);
});

check("a rowspan covers the cell below: it has no node; round-trips byte-identically", () => {
  const doc = runToTiptap([TALL]);
  const rows = doc.content[0].content;
  assert.equal(rows[2].content[0].attrs.rowspan, 2);
  assert.equal(rows[3].content.length, 2, "the row under the tall cell has two visible cells");
  assert.deepEqual(docToBlocks(doc), [TALL]);
  assert.deepEqual(runToOps([TALL], doc), []);
});

check("merging two cells in the live doc emits ONE patch-block carrying rows (with the placeholder) and spans", () => {
  const doc = runToTiptap([PLAIN]);
  const row1 = doc.content[0].content[1];
  // The canvas's merge: origin gets colspan 2, the covered cell's node disappears, its text joins.
  row1.content[0].attrs.colspan = 2;
  row1.content[0].content = [{ type: "text", text: "a1b1" }];
  row1.content.splice(1, 1);
  const ops = runToOps([PLAIN], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "patch-block");
  assert.deepEqual(ops[0].patch.spans, [{ row: 0, col: 0, colspan: 2, rowspan: 1 }]);
  assert.deepEqual(ops[0].patch.rows[0], [t("a1b1"), [], t("c1")]);
  assert.equal(ops[0].patch.rows[0].length, 3, "the row stays rectangular");
});

check("splitting a merged cell emits a patch with spans: [] so the server drops the old list", () => {
  const doc = runToTiptap([MERGED]);
  const row1 = doc.content[0].content[1];
  row1.content[0].attrs.colspan = 1;
  row1.content.splice(1, 0, { type: "bpTableCell", attrs: { colspan: 1, rowspan: 1 } });
  const ops = runToOps([MERGED], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.deepEqual(ops[0].patch.spans, []);
  assert.equal(ops[0].patch.rows[0].length, 3);
});

check("grid transforms: remove the last column shrinks a span reaching it; remove the last row shrinks a rowspan; add keeps spans", () => {
  const g = { head: ["A", "B", "C"], rows: [["ab", null, "c"], ["a2", "b2", "c2"]], spans: [{ row: 0, col: 0, colspan: 2, rowspan: 1 }] };
  gridTransforms.addCol(g, () => null);
  assert.equal(g.rows[0].length, 4); assert.deepEqual(g.spans, [{ row: 0, col: 0, colspan: 2, rowspan: 1 }]);
  gridTransforms.removeCol(g); gridTransforms.removeCol(g);
  assert.equal(g.rows[0].length, 2); assert.deepEqual(g.spans, [{ row: 0, col: 0, colspan: 2, rowspan: 1 }]);
  gridTransforms.removeCol(g);
  assert.equal(g.rows[0].length, 1); assert.deepEqual(g.spans, [], "a span of one column is no span");
  const g2 = { head: null, rows: [["tall", "b1"], [null, "b2"], ["a3", "b3"]], spans: [{ row: 0, col: 0, colspan: 1, rowspan: 2 }] };
  gridTransforms.removeRow(g2);
  assert.deepEqual(g2.spans, [{ row: 0, col: 0, colspan: 1, rowspan: 2 }], "removing the last row leaves a span above it alone");
  gridTransforms.removeRow(g2);
  assert.deepEqual(g2.spans, [], "removing the covered row collapses the rowspan");
});

check("grid merge widens to swallow a touched span and reports the origin; split clears it; visible rows follow", () => {
  const g = { head: null, rows: [["a", "b", "c"], ["d", "e", "f"]], spans: [] };
  const m = gridTransforms.merge(g, 0, 0, 0, 1);
  assert.deepEqual(m, { row: 0, col: 0, colspan: 2, rowspan: 1 });
  const m2 = gridTransforms.merge(g, 1, 1, 0, 1);
  assert.deepEqual(m2, { row: 0, col: 0, colspan: 2, rowspan: 2 }, "merging into the span takes the whole rectangle");
  const visible = gridToVisible(g);
  assert.deepEqual(visible.map((r) => r.cells.map((c) => [c.cell, c.colspan, c.rowspan])), [[["a", 2, 2], ["c", 1, 1]], [["f", 1, 1]]]);
  assert.equal(gridTransforms.split(g, 1, 1), true, "split from a covered position");
  assert.deepEqual(g.spans, []);
  assert.deepEqual(visibleToGrid(gridToVisible(g), () => null).rows, g.rows);
});

check("toggling the header off shifts span rows down; toggling it on splits the first row's spans", () => {
  const g = { head: ["A", "B"], rows: [["ab", null], ["a2", "b2"]], spans: [{ row: 0, col: 0, colspan: 2, rowspan: 1 }] };
  gridTransforms.toggleHeader(g, () => null);
  assert.equal(g.head, null);
  assert.deepEqual(g.spans, [{ row: 1, col: 0, colspan: 2, rowspan: 1 }]);
  gridTransforms.toggleHeader(g, () => null);
  assert.deepEqual(g.head, ["A", "B"]);
  assert.deepEqual(g.spans, [{ row: 0, col: 0, colspan: 2, rowspan: 1 }]);
  gridTransforms.toggleHeader(g, () => null); gridTransforms.merge(g, 0, 0, 0, 1);
  assert.deepEqual(g.spans, [{ row: 0, col: 0, colspan: 2, rowspan: 1 }, { row: 1, col: 0, colspan: 2, rowspan: 1 }]);
  gridTransforms.toggleHeader(g, () => null);
  assert.deepEqual(g.spans, [{ row: 0, col: 0, colspan: 2, rowspan: 1 }], "a head never spans: the first row's span is split, the next row's shifts up");
});

check("normalizeSpans drops malformed, out-of-grid and overlapping entries", () => {
  assert.deepEqual(normalizeSpans([{ row: 0, col: 0, colspan: 1, rowspan: 1 }, { row: 5, col: 0, colspan: 2 }, { row: 0, col: 1, colspan: 5, rowspan: 1 }, { row: 0, col: 2, colspan: 2, rowspan: 1 }, "junk"], 2, 3), [{ row: 0, col: 1, colspan: 2, rowspan: 1 }]);
  assert.deepEqual([...coverMap([{ row: 0, col: 0, colspan: 2, rowspan: 2 }]).keys()].sort(), ["0,1", "1,0", "1,1"]);
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
