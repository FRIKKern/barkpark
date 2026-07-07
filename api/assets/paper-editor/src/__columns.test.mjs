// __columns.test.mjs — pure-Node unit test for the columns CONTAINER canvas node
// (S10) — the FIRST canvas node whose interior is a NESTED BLOCK TREE. Proves the
// block ⇄ bpColumns node ⇄ ops round-trip in run-convert.js: an unedited columns
// emits ZERO ops; an interior edit emits ONE coarse patch-block replacing the WHOLE
// `columns` array; a non-first-class child (callout) rides a verbatim bpColumnAtom;
// prose/heading/list/divider children project to their editable nodes; an empty
// column seeds+strips a sentinel paragraph; an unknown top-level key (gap) survives
// the coarse patch; a phantom nested null bpId (the depth>0 attr the live getJSON
// gains via BpAttrs) is immune to the coarse content-diff. DOM-free — imports only
// run-convert.js (which imports the pure convert.js), never TipTap.
//
// Run: node src/__columns.test.mjs   (or: npm test)

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

// ── fixtures (the READER shape: columns is a LIST OF COLUMNS, each a LIST OF
//    BLOCKS — a list-of-lists; children are id-less) ──────────────────────────

// Two prose columns: a paragraph on the left, a heading on the right.
const COLUMNS = {
  id: "col1",
  type: "columns",
  columns: [
    [{ type: "paragraph", content: [{ type: "text", value: "Left" }] }],
    [{ type: "heading", level: 2, text: "Right" }],
  ],
};

// A column whose child is a CALLOUT — NOT a valid bpColumn child by name, so it must
// ride a verbatim read-only bpColumnAtom (else PM drops it = data loss).
const CALLOUT_COL = {
  id: "col2",
  type: "columns",
  columns: [
    [{ type: "callout", tone: "warn", content: [{ type: "text", value: "Note" }] }],
  ],
};

// An EMPTY first column (must seed + strip a sentinel paragraph so bpColumn `…+` is
// satisfiable) alongside a real second column.
const EMPTY_COL = {
  id: "col3",
  type: "columns",
  columns: [[], [{ type: "paragraph", content: [{ type: "text", value: "R" }] }]],
};

// A columns block carrying an UNKNOWN top-level key (`gap`) that must survive the
// coarse round-trip (the diff patches ONLY `columns`, so a shallow server merge
// leaves `gap` intact).
const GAP_COL = {
  id: "col4",
  type: "columns",
  gap: "2rem",
  columns: [[{ type: "paragraph", content: [{ type: "text", value: "X" }] }]],
};

// A column mixing a paragraph with a leaf divider (both first-class bpColumn children).
const DIVIDER_COL = {
  id: "col5",
  type: "columns",
  columns: [
    [
      { type: "paragraph", content: [{ type: "text", value: "A" }] },
      { type: "divider" },
    ],
  ],
};

// A column with a bullet LIST child.
const LIST_COL = {
  id: "col6",
  type: "columns",
  columns: [
    [
      {
        type: "list",
        ordered: false,
        items: [[{ type: "text", value: "one" }], [{ type: "text", value: "two" }]],
      },
    ],
  ],
};

// ── 1. round-trip: an UNEDITED columns emits ZERO ops ───────────────────────

check("unedited columns (prose/callout/empty/gap/divider/list) each emit ZERO ops", () => {
  for (const block of [COLUMNS, CALLOUT_COL, EMPTY_COL, GAP_COL, DIVIDER_COL, LIST_COL]) {
    const doc = runToTiptap([block]);
    const ops = runToOps([block], doc);
    assert.deepEqual(ops, [], `${block.id} should emit no ops when unedited`);
  }
});

// ── 2. docToBlocks reconstructs each columns block byte-identically ─────────

check("docToBlocks reconstructs prose columns (children id-less, keys stable)", () => {
  assert.deepEqual(docToBlocks(runToTiptap([COLUMNS]))[0], {
    id: "col1",
    type: "columns",
    columns: [
      [{ type: "paragraph", content: [{ type: "text", value: "Left" }] }],
      [{ type: "heading", text: "Right", level: 2 }],
    ],
  });
});

check("docToBlocks carries a callout child VERBATIM through bpColumnAtom", () => {
  assert.deepEqual(docToBlocks(runToTiptap([CALLOUT_COL]))[0], {
    id: "col2",
    type: "columns",
    columns: [
      [{ type: "callout", tone: "warn", content: [{ type: "text", value: "Note" }] }],
    ],
  });
});

check("docToBlocks collapses an empty column's sentinel back to []", () => {
  assert.deepEqual(docToBlocks(runToTiptap([EMPTY_COL]))[0], {
    id: "col3",
    type: "columns",
    columns: [[], [{ type: "paragraph", content: [{ type: "text", value: "R" }] }]],
  });
});

check("docToBlocks reconstructs divider + list children", () => {
  assert.deepEqual(docToBlocks(runToTiptap([DIVIDER_COL]))[0].columns, [
    [
      { type: "paragraph", content: [{ type: "text", value: "A" }] },
      { type: "divider" },
    ],
  ]);
  assert.deepEqual(docToBlocks(runToTiptap([LIST_COL]))[0].columns, [
    [
      {
        type: "list",
        ordered: false,
        items: [[{ type: "text", value: "one" }], [{ type: "text", value: "two" }]],
      },
    ],
  ]);
});

// ── 3. the bpColumns node carries bpId/bpType + a static cols count ─────────

check("bpColumns node carries bpId/bpType and cols = column count", () => {
  const node = runToTiptap([COLUMNS]).content[0];
  assert.equal(node.type, "bpColumns");
  assert.equal(node.attrs.bpId, "col1");
  assert.equal(node.attrs.bpType, "columns");
  assert.equal(node.attrs.cols, 2, "cols reflects the 2 source columns");
  // The child of the first bpColumn is an editable paragraph; the CALLOUT child of
  // CALLOUT_COL is a read-only bpColumnAtom carrying the whole block.
  const atomNode = runToTiptap([CALLOUT_COL]).content[0].content[0].content[0];
  assert.equal(atomNode.type, "bpColumnAtom");
  assert.equal(atomNode.attrs.bpType, "callout");
  assert.deepEqual(atomNode.attrs.bpBlock, CALLOUT_COL.columns[0][0]);
});

// ── 4. an interior edit → ONE coarse patch-block replacing the WHOLE columns ─

check("a column-body edit → ONE patch-block { columns } with the whole array", () => {
  const doc = clone(runToTiptap([COLUMNS]));
  // Edit the left column's paragraph text (bpColumns > bpColumn[0] > paragraph[0]).
  doc.content[0].content[0].content[0].content = [{ type: "text", text: "Left EDITED" }];
  const ops = runToOps([COLUMNS], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "col1");
  assert.deepEqual(Object.keys(ops[0].patch), ["columns"], "coarse patch touches ONLY columns");
  assert.deepEqual(ops[0].patch.columns, [
    [{ type: "paragraph", content: [{ type: "text", value: "Left EDITED" }] }],
    [{ type: "heading", text: "Right", level: 2 }],
  ]);
});

check("an unknown top-level key (gap) never rides the coarse patch (survives merge)", () => {
  // Unedited → zero ops → gap untouched on the server.
  assert.deepEqual(runToOps([GAP_COL], runToTiptap([GAP_COL])), []);
  // Edited → the patch carries ONLY `columns` (gap is a sibling key patch.ex's shallow
  // merge preserves — never rebuilt/dropped here).
  const doc = clone(runToTiptap([GAP_COL]));
  doc.content[0].content[0].content[0].content = [{ type: "text", text: "X!" }];
  const ops = runToOps([GAP_COL], doc);
  assert.equal(ops.length, 1);
  assert.deepEqual(Object.keys(ops[0].patch), ["columns"]);
});

// ── 5. robustness: a phantom nested null bpId is immune to the coarse diff ───

check("a phantom nested null bpId/bpType on a child paragraph emits ZERO ops", () => {
  // The live getJSON gains { bpId:null, bpType:null } on a nested paragraph (BpAttrs
  // declares them globally). index.js normalizeCanvasDoc strips them, but even
  // UN-normalized the coarse content-diff reconstructs to BLOCKS (child attrs
  // excluded), so it must be immune regardless.
  const doc = clone(runToTiptap([COLUMNS]));
  doc.content[0].content[0].content[0].attrs = { bpId: null, bpType: null };
  const ops = runToOps([COLUMNS], doc);
  assert.deepEqual(ops, [], "phantom child attrs must not look like an edit");
});

// ── 6. structural: inserting a NEW columns block mints an id ─────────────────

check("a new columns block (bpId null) → append-block with a minted id", () => {
  const doc = clone(runToTiptap([COLUMNS]));
  doc.content[0].attrs.bpId = null; // simulate a freshly-inserted columns
  const ops = runToOps([], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "append-block");
  assert.equal(ops[0].block.type, "columns");
  assert.ok(ops[0].block.id, "a minted id is stamped");
  assert.deepEqual(ops[0].block.columns, [
    [{ type: "paragraph", content: [{ type: "text", value: "Left" }] }],
    [{ type: "heading", text: "Right", level: 2 }],
  ]);
});

// ── 7. reconcileServerEcho recognizes a columns own-echo ────────────────────

check("reconcileServerEcho treats an unchanged columns run as an own echo", () => {
  const server = [COLUMNS, CALLOUT_COL];
  const live = runToTiptap(server).content;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.deepEqual(idWrites, []);
});

check("reconcileServerEcho falls through to external on a real columns edit", () => {
  const server = [COLUMNS];
  const live = clone(runToTiptap(server).content);
  live[0].content[0].content[0].content = [{ type: "text", text: "changed" }];
  const { ownEcho } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, false);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall columns-node checks PASS");
