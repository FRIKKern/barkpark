// __technical_atoms.test.mjs — scaffy-backlog-blocks-editable-studio.
//
// The `diff` + `filetree` blocks became EDITABLE canvas attr-atoms (bpDiff /
// bpFiletree, technical-node.js). This pure-Node gate proves the property the
// task's first acceptance lock names: LOSSLESS ROUND-TRIP. For each type:
//
//   1. block → runToTiptap → node  carries every authored field;
//   2. node → runToOps(prev, doc)  emits ZERO ops when nothing was edited
//      (an untouched block must never dirty the document — the no-op settlement
//      that makes "open the canvas and save" a no-write);
//   3. an EDIT to the body or to a metadata field emits EXACTLY ONE patch-block
//      whose patch keys are the SAME key set TechnicalBlockEditor.build_patch/2
//      writes from the classic form (so both Studio surfaces persist the same
//      shape — this is what "both surfaces, lossless" means mechanically);
//   4. docToBlocks reconstructs the ORIGINAL block byte-for-byte (deep-equal),
//      including the ABSENCE of an unset metadata key (no stray file:"").
//
// WHICH TEST FAILS IF A SURFACE IS MISSING
//   * canvas surface absent (diff/filetree not in CANVAS_ATTR_ATOM_TYPES): the
//     "projects to its bp* attr-atom node" check reds — the block falls through to
//     the read-only bpOpaque atom and node.type is "bpOpaque", not "bpDiff".
//   * canvas patch path absent (no technicalNodeToPatch dispatch): the "a body edit
//     emits one patch-block" check reds with zero ops.
//   * classic-form surface absent: api/test/.../technical_block_editor_test.exs and
//     paper_editor_technical_test.exs red (Elixir side).
//
// Run: node src/canvas/__technical_atoms.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./run-convert.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.error(`FAIL  ${name}\n      ${e && e.message}`);
  }
}

// runToTiptap returns the whole { type:"doc", content:[…] }; these helpers keep
// the checks reading in block terms.
const project = (blocks) => runToTiptap(blocks).content;
const doc = (nodes) => ({ type: "doc", content: nodes });

// Author fixtures carrying REAL, whitespace-significant bodies: a multi-line
// unified diff (leading +/-/space column is load-bearing) and a box-glyph tree.
const DIFF_BLOCK = {
  id: "b-diff",
  type: "diff",
  diff: "@@ -1,2 +1,2 @@\n context\n-old\n+new",
  file: "lib/a.ex",
  lang: "elixir",
};

const FILETREE_BLOCK = {
  id: "b-tree",
  type: "filetree",
  text: "lib/\n├── a.ex ● covered\n└── b.ex ✕ missing",
  legend: "● covered  ✕ missing",
};

// The metadata-LESS twins: an absent optional key must round-trip as ABSENT.
const DIFF_BARE = { id: "b-diff2", type: "diff", diff: "+one line" };
const TREE_BARE = { id: "b-tree2", type: "filetree", text: "lib/\n└── a.ex" };

const CASES = [
  {
    label: "diff",
    node: "bpDiff",
    block: DIFF_BLOCK,
    bare: DIFF_BARE,
    body: "diff",
    // The EXACT key set TechnicalBlockEditor.build_patch(%{"type"=>"diff"}, …)
    // writes from the classic form — ~w(diff file lang).
    patchKeys: ["diff", "file", "lang"],
    meta: "file",
  },
  {
    label: "filetree",
    node: "bpFiletree",
    block: FILETREE_BLOCK,
    bare: TREE_BARE,
    body: "text",
    // TechnicalBlockEditor.build_patch(%{"type"=>"filetree"}, …) — ~w(text legend).
    patchKeys: ["text", "legend"],
    meta: "legend",
  },
];

for (const c of CASES) {
  check(`${c.label}: projects to its ${c.node} attr-atom node with every field`, () => {
    const [node] = project([c.block]);
    assert.equal(
      node.type,
      c.node,
      `expected ${c.node}, got ${node.type} — the type is not in CANVAS_ATTR_ATOM_TYPES, so the canvas shows a read-only atom instead of an editable one`,
    );
    assert.equal(node.attrs.bpId, c.block.id);
    assert.equal(node.attrs.bpType, c.label);
    assert.equal(node.attrs[c.body], c.block[c.body]);
    assert.equal(node.attrs[c.meta], c.block[c.meta]);
  });

  check(`${c.label}: an UNTOUCHED block emits ZERO ops (no-op settlement)`, () => {
    const nodes = project([c.block]);
    const ops = runToOps([c.block], doc(nodes));
    assert.deepEqual(ops, [], `untouched ${c.label} dirtied the document`);
  });

  check(`${c.label}: a BODY edit emits exactly one patch-block with the form's key set`, () => {
    const nodes = project([c.block]);
    nodes[0].attrs[c.body] = c.block[c.body] + "\n+appended";
    const ops = runToOps([c.block], doc(nodes));
    assert.equal(ops.length, 1, `expected 1 op, got ${ops.length}`);
    assert.equal(ops[0].op, "patch-block");
    assert.equal(ops[0].id, c.block.id);
    assert.deepEqual(
      Object.keys(ops[0].patch).sort(),
      [...c.patchKeys].sort(),
      "the canvas patch key set diverged from TechnicalBlockEditor.build_patch/2 — the two Studio surfaces would persist different shapes",
    );
    assert.equal(ops[0].patch[c.body], c.block[c.body] + "\n+appended");
  });

  check(`${c.label}: CLEARING a metadata field emits it as "" (removal-safe merge)`, () => {
    // patch-block folds via Patch.apply_patches → a SHALLOW Map.merge that can
    // REPLACE but never DELETE a key. Omitting the cleared key would leave the
    // STALE value on the stored block, so the patch must carry "".
    const nodes = project([c.block]);
    nodes[0].attrs[c.meta] = null;
    const ops = runToOps([c.block], doc(nodes));
    assert.equal(ops.length, 1);
    assert.equal(ops[0].patch[c.meta], "");
  });

  check(`${c.label}: docToBlocks reconstructs the ORIGINAL block byte-for-byte`, () => {
    const nodes = project([c.block]);
    const [back] = docToBlocks(doc(nodes));
    assert.deepEqual(back, c.block);
  });

  check(`${c.label}: an ABSENT metadata key round-trips as ABSENT (no stray "")`, () => {
    const nodes = project([c.bare]);
    assert.equal(
      Object.prototype.hasOwnProperty.call(nodes[0].attrs, c.meta),
      false,
      `${c.meta} was projected onto a block that never carried it`,
    );
    const [back] = docToBlocks(doc(nodes));
    assert.deepEqual(back, c.bare);
    assert.deepEqual(runToOps([c.bare], doc(nodes)), []);
  });
}

// A CONTROL: the two types must not collide. A run carrying BOTH projects two
// DISTINCT node types and round-trips both — proving the shared factory in
// technical-node.js / TECHNICAL_ATOM_SHAPES keys off bpType, not a shared global.
check("diff + filetree in ONE run keep distinct node types and both round-trip", () => {
  const blocks = [DIFF_BLOCK, FILETREE_BLOCK];
  const nodes = project(blocks);
  assert.deepEqual(
    nodes.map((n) => n.type),
    ["bpDiff", "bpFiletree"],
  );
  assert.deepEqual(docToBlocks(doc(nodes)), blocks);
  assert.deepEqual(runToOps(blocks, doc(nodes)), []);
});

// A CONTROL on the no-op settlement itself: prove the zero-op assertions above are
// not vacuous (a runToOps that always returned [] would pass every one of them).
check("CONTROL: runToOps DOES emit for a real edit (the zero-op checks have teeth)", () => {
  const nodes = project([DIFF_BLOCK]);
  nodes[0].attrs.file = "lib/other.ex";
  const ops = runToOps([DIFF_BLOCK], doc(nodes));
  assert.equal(ops.length, 1, "a metadata edit produced no op — the detector is inert");
  assert.equal(ops[0].patch.file, "lib/other.ex");
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
