// __table.test.mjs — pure-Node unit test for the editable TABLE canvas node tree
// (bpTable > bpTableRow > bpTableHeaderCell|bpTableCell). Proves the block ⇄ node ⇄
// ops round-trip in run-convert.js: an unedited table emits ZERO ops, a cell edit
// emits exactly one COARSE whole-table patch, header removal emits `head:[]`
// EXPLICITLY (the removal-safe contract), scalar cells normalize without choking,
// inline MARKS round-trip through the cell body, empty cells stay contentless, and a
// fresh (bpId-less) table reconstructs on insert. DOM-free — imports only
// run-convert.js (never table-node.js / TipTap).
//
// Run: node src/__table.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "./canvas/run-convert.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const clone = (v) => JSON.parse(JSON.stringify(v));

// A 2×2 table with a header row + two body rows. Cells are portable-doc inline arrays
// ({type:"text",value:"…"}), the SAME shape a paragraph/callout body carries.
const TABLE = {
  id: "t1",
  type: "table",
  head: [[{ type: "text", value: "Name" }], [{ type: "text", value: "Age" }]],
  rows: [
    [[{ type: "text", value: "Ada" }], [{ type: "text", value: "36" }]],
    [[{ type: "text", value: "Bob" }], [{ type: "text", value: "40" }]],
  ],
};

// The same table with NO header row (head must round-trip ABSENT, not []).
const TABLE_NOHEAD = {
  id: "t2",
  type: "table",
  rows: [[[{ type: "text", value: "x" }], [{ type: "text", value: "y" }]]],
};

// A scalar-cell table — upstream converters (paper_to_blocks.py) emit text-only cells
// as PLAIN strings. The canvas must not choke; it normalizes to inline runs on load.
const TABLE_SCALAR = { id: "t3", type: "table", rows: [["hi", "there"]] };

// A cell carrying an inline MARK (strong) — must round-trip so bold/italic/links are
// not silently stripped (the whole reason for the nested-PM path over an atom island).
const TABLE_BOLD = {
  id: "t4",
  type: "table",
  rows: [[[{ type: "strong", children: [{ type: "text", value: "Bold" }] }]]],
};

// A table with an EMPTY cell (an empty inline array) alongside a filled one.
const TABLE_EMPTY = {
  id: "t5",
  type: "table",
  rows: [[[], [{ type: "text", value: "x" }]]],
};

// ── 1. round-trip: an UNEDITED table emits ZERO ops ─────────────────────────

check("unedited table (head + body) emits ZERO ops", () => {
  const doc = runToTiptap([TABLE]);
  assert.deepEqual(runToOps([TABLE], doc), []);
});

check("unedited head-less / scalar / bold / empty tables each emit ZERO ops", () => {
  for (const block of [TABLE_NOHEAD, TABLE_SCALAR, TABLE_BOLD, TABLE_EMPTY]) {
    const doc = runToTiptap([block]);
    assert.deepEqual(runToOps([block], doc), [], `${block.id} should emit no ops`);
  }
});

// ── 2. docToBlocks reconstructs the block ───────────────────────────────────

check("docToBlocks reconstructs a table with header byte-identically", () => {
  assert.deepEqual(docToBlocks(runToTiptap([TABLE]))[0], TABLE);
});

check("a head-less table reconstructs with NO head key", () => {
  const out = docToBlocks(runToTiptap([TABLE_NOHEAD]))[0];
  assert.deepEqual(out, TABLE_NOHEAD);
  assert.ok(!("head" in out), "no header row → no head key (byte-fidelity)");
});

check("inline MARKS in a cell round-trip (bold not stripped)", () => {
  assert.deepEqual(docToBlocks(runToTiptap([TABLE_BOLD]))[0], TABLE_BOLD);
});

check("an EMPTY cell round-trips as an empty inline array", () => {
  const out = docToBlocks(runToTiptap([TABLE_EMPTY]))[0];
  assert.deepEqual(out.rows[0][0], []);
  assert.deepEqual(out.rows[0][1], [{ type: "text", value: "x" }]);
});

check("a SCALAR cell normalizes to an inline run without choking", () => {
  const out = docToBlocks(runToTiptap([TABLE_SCALAR]))[0];
  assert.deepEqual(out.rows[0][0], [{ type: "text", value: "hi" }]);
  assert.deepEqual(out.rows[0][1], [{ type: "text", value: "there" }]);
});

// ── 3. node shape: bpTable carries the id; rows/cells carry none ────────────

check("bpTable carries bpId/bpType; header/body cells use the right node types", () => {
  const node = runToTiptap([TABLE]).content[0];
  assert.equal(node.type, "bpTable");
  assert.equal(node.attrs.bpId, "t1");
  assert.equal(node.attrs.bpType, "table");
  // rows/cells are internal PM structure — NO bpId.
  const headRow = node.content[0];
  assert.equal(headRow.type, "bpTableRow");
  assert.equal(headRow.content[0].type, "bpTableHeaderCell");
  assert.ok(!headRow.attrs || headRow.attrs.bpId == null, "row carries no bpId");
  assert.ok(
    !headRow.content[0].attrs || headRow.content[0].attrs.bpId == null,
    "cell carries no bpId"
  );
  const bodyRow = node.content[1];
  assert.equal(bodyRow.content[0].type, "bpTableCell");
});

// ── 4. a cell edit → one COARSE whole-table patch ───────────────────────────

check("a body-cell edit → one patch-block { rows, head }", () => {
  const doc = clone(runToTiptap([TABLE]));
  // doc.content[0] = bpTable; .content = [headRow, bodyRow0, bodyRow1].
  doc.content[0].content[1].content[0].content = [{ type: "text", text: "Ada Lovelace" }];
  const ops = runToOps([TABLE], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "t1");
  // head survives (explicit) and the edited cell lands.
  assert.deepEqual(ops[0].patch.head, [
    [{ type: "text", value: "Name" }],
    [{ type: "text", value: "Age" }],
  ]);
  assert.deepEqual(ops[0].patch.rows[0][0], [{ type: "text", value: "Ada Lovelace" }]);
  assert.equal(ops[0].patch.rows.length, 2, "whole body re-emitted (coarse round-trip)");
});

// ── 5. header removal emits head:[] EXPLICITLY (the removal-safe contract) ───

check("toggling the header row off → patch emits head:[] explicitly", () => {
  const doc = clone(runToTiptap([TABLE]));
  // toggle-header: the leading row's cells flip bpTableHeaderCell → bpTableCell.
  doc.content[0].content[0].content.forEach((c) => {
    c.type = "bpTableCell";
  });
  const ops = runToOps([TABLE], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.deepEqual(
    ops[0].patch.head,
    [],
    "head MUST be an explicit [] so the shallow patch-merge deletes the stale header"
  );
  // the former header row is now a body row → 3 body rows.
  assert.equal(ops[0].patch.rows.length, 3);
});

// ── 6. a fresh (bpId-less) table reconstructs on INSERT ─────────────────────

check("a fresh table (bpId:null) → append-block with the reconstructed block", () => {
  const fresh = clone(runToTiptap([TABLE]));
  fresh.content[0].attrs.bpId = null; // a typed/pasted table with no id yet
  const ops = runToOps([], fresh);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "append-block");
  assert.equal(ops[0].block.type, "table");
  assert.ok(ops[0].block.id, "the insert stamps a minted id");
  assert.deepEqual(ops[0].block.rows[0][0], [{ type: "text", value: "Ada" }]);
  assert.deepEqual(ops[0].block.head[0], [{ type: "text", value: "Name" }]);
});

// ── 7. reconcileServerEcho recognizes a table own-echo ──────────────────────

check("reconcileServerEcho treats an unchanged table run as an own echo", () => {
  const server = [TABLE, TABLE_NOHEAD];
  const live = runToTiptap(server).content;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.deepEqual(idWrites, []);
});

// ── 8. a table participates in structural ops (delete) via its bpId ─────────

check("deleting a table emits remove-block (type-agnostic structural op)", () => {
  const P = { id: "p0", type: "paragraph", text: "keep" };
  const doc = runToTiptap([P, TABLE]);
  // drop the table node from the live doc.
  const edited = { type: "doc", content: [clone(doc.content[0])] };
  const ops = runToOps([P, TABLE], edited);
  assert.deepEqual(ops, [{ op: "remove-block", id: "t1" }]);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall table-node checks PASS");
