// smoke/sections.mjs — the `section` CONTAINER node projection + round-trip + op
// strategy gates (loop-epic/editable-section).
//
// A top-level `section` block projects to an EDITABLE `bpSection` container whose
// nested children join the canvas doc; a nested (depth>=1) section is carried opaque
// (V1 forbid-nesting). The op strategy:
//   * pure interior edit of a pre-existing nested child (stable child-id sequence)
//     → fine-grained patch-block{id:childId} (patch.ex resolves nested ids).
//   * any structural change (add/remove/reorder/reparent/a null-id child) → ONE
//     coarse replace-block{id:sectionId, block:<rebuilt subtree>}.
// The make-or-break: minting for new blocks seeds `taken` from the WHOLE tree (nested
// section bodies included) so a mint never collides with a nested id (patch.ex
// duplicate_id would abort the whole atomic batch).
//
// Pure Node — no editor mounted. section-node.js's Node SCHEMA object loads in plain
// Node (it references `document` lazily inside addNodeView, which never runs here), so
// importing BP_SECTION_CONTENT for the lockstep gate is safe.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "../canvas/run-convert.js";
import { BP_SECTION_CONTENT, BP_SECTION_NODE_NAME } from "../canvas/section-node.js";

// A section fixture: a titled section holding a heading + a paragraph + a callout.
const SECTION = () => ({
  id: "s-1",
  type: "section",
  title: "Overview",
  blocks: [
    { id: "sc-h", type: "heading", level: 2, text: "Intro" },
    {
      id: "sc-p",
      type: "paragraph",
      content: [{ type: "text", value: "body text" }],
    },
    {
      id: "sc-c",
      type: "callout",
      tone: "info",
      content: [{ type: "text", value: "note" }],
    },
  ],
});

// Collect every id in a block tree (top-level + nested section.blocks at any depth).
function allIds(blocks) {
  const out = [];
  const walk = (arr) => {
    for (const b of arr || []) {
      if (b && b.id != null) out.push(b.id);
      if (b && Array.isArray(b.blocks)) walk(b.blocks);
    }
  };
  walk(blocks);
  return out;
}

// ── PROJECTION ───────────────────────────────────────────────────────────────
check("section runToTiptap: a top-level section → { type:'bpSection', content:[…] } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    SECTION(),
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3, "section folds INTO the run (no split)");

  const sec = doc.content[1];
  assert.equal(sec.type, "bpSection", "section projects to the bpSection container");
  assert.notEqual(sec.type, "bpOpaque", "section is NOT carried opaquely");
  assert.equal(sec.attrs.bpId, "s-1");
  assert.equal(sec.attrs.bpType, "section");
  assert.equal(sec.attrs.title, "Overview");
  assert.equal(sec.content.length, 3, "the three children project as nested nodes");
  assert.equal(sec.content[0].type, "heading");
  assert.equal(sec.content[1].type, "paragraph");
  assert.equal(sec.content[2].type, "callout");
  // The nested children carry their own bpIds so the reverse diff keys by them.
  assert.deepEqual(
    sec.content.map((c) => c.attrs.bpId),
    ["sc-h", "sc-p", "sc-c"],
  );
});

check("section runToTiptap: an ABSENT title round-trips as ABSENT (present-only)", () => {
  const s = SECTION();
  delete s.title;
  const sec = runToTiptap([s]).content[0];
  assert.ok(!("title" in sec.attrs) || sec.attrs.title == null, "no title attr when absent");

  // And an empty section (no children) projects with NO content key.
  const empty = { id: "s-e", type: "section", blocks: [] };
  const en = runToTiptap([empty]).content[0];
  assert.equal(en.type, "bpSection");
  assert.ok(!("content" in en), "an empty section has no content key");
});

// ── ROUND-TRIP (untouched → ZERO ops, folds back identical) ──────────────────
check("section runToOps: an untouched section round-trips with ZERO ops", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] },
    SECTION(),
  ];
  const doc = runToTiptap(blocks);
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched section emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "section round-trip");
  // The whole nested subtree survives byte-identical.
  assert.deepEqual(folded[1], SECTION());
});

// ── LOCKSTEP: the content expression tracks the canvas roster MINUS bpSection ─
check("section content-expression LOCKSTEP: forbids bpSection, allows the child roster + bpOpaque", () => {
  const names = new Set(
    BP_SECTION_CONTENT.replace(/[()+]/g, " ")
      .split("|")
      .join(" ")
      .split(/\s+/)
      .filter(Boolean),
  );
  // V1 forbid-nesting: bpSection is NOT an allowed child (the schema-level guard
  // against the silent-lift trap).
  assert.ok(!names.has("bpSection"), "bpSection must NOT be a section child (forbid nesting)");
  // The canvas child roster (node NAMES) that MUST be insertable in a section body.
  const roster = [
    "paragraph", "heading", "bulletList", "orderedList",
    "divider", "callout", "bpCode", "bpDiagram", "bpField",
    "bpSheet", "bpEmbed", "bpFleet",
    "eyebrow", "byline", "ingress", "pullquote",
  ];
  for (const n of roster) {
    assert.ok(names.has(n), `section content must allow ${n}`);
  }
  // bpOpaque MUST be allowed — a non-canvas child (nested section / composite /
  // codelist) projects to it; without it PM would LIFT it out of the section.
  assert.ok(names.has("bpOpaque"), "section content must allow bpOpaque (verbatim carry)");
});

// ── NESTED SECTION (depth>=1) → bpOpaque verbatim carry (silent-lift mitigation) ─
check("section runToTiptap: a NESTED section child is carried bpOpaque VERBATIM (not bpSection)", () => {
  const nested = {
    id: "outer",
    type: "section",
    title: "Outer",
    blocks: [
      { id: "op", type: "paragraph", content: [{ type: "text", value: "top" }] },
      {
        id: "inner",
        type: "section",
        title: "Inner",
        blocks: [
          { id: "ip", type: "paragraph", content: [{ type: "text", value: "deep" }] },
        ],
      },
    ],
  };
  const sec = runToTiptap([nested]).content[0];
  assert.equal(sec.type, "bpSection");
  const innerNode = sec.content[1];
  assert.equal(innerNode.type, "bpOpaque", "a nested section child is bpOpaque, NOT bpSection");
  assert.equal(innerNode.attrs.bpId, "inner");
  assert.equal(innerNode.attrs.bpType, "section");
  // The WHOLE nested section rides verbatim on bpBlock (deep-cloned).
  assert.deepEqual(innerNode.attrs.bpBlock, nested.blocks[1]);

  // Round-trips byte-identical (getJSON → docToBlocks === original).
  const back = docToBlocks(runToTiptap([nested]));
  assert.deepEqual(back, [nested], "a legacy nested-section paper round-trips byte-identical");

  // And runToOps emits ZERO ops for it untouched.
  assert.equal(runToOps([nested], runToTiptap([nested])).length, 0);
});

// ── FINE-GRAINED: a pure interior edit of a stable nested child → patch-block ─
check("section runToOps: editing a nested child's interior → ONE patch-block{childId} (not replace-block)", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  // Edit ONLY the paragraph child's text (child-id sequence unchanged).
  doc.content[0].content[1].content = [{ type: "text", text: "EDITED body" }];

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op");
  assert.equal(ops[0].op, "patch-block", "a fine-grained patch, NOT a coarse replace-block");
  assert.equal(ops[0].id, "sc-p", "keyed by the NESTED child id (patch.ex resolves it)");
  assert.ok(!ops.some((o) => o.op === "replace-block"), "no replace-block");

  const folded = assertFolds(blocks, doc, ops, "section child interior edit");
  assert.equal(folded[0].blocks[1].content[0].value, "EDITED body");
  assert.equal(folded[0].blocks[0].id, "sc-h", "the untouched siblings survive");
  assert.equal(folded[0].blocks[2].id, "sc-c");
});

check("section runToOps: editing the section TITLE (children unchanged) → ZERO structural ops, no replace-block", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, title: "Renamed" };
  const ops = runToOps(blocks, doc);
  // The child-id sequence is unchanged → the fine-grained path. No child interior
  // changed, so NO ops. (A title-only edit is intentionally NOT diffed in v1 via the
  // fine-grained path — the coarse path is reserved for structural change.)
  assert.ok(!ops.some((o) => o.op === "replace-block"), "a title-only edit is not a structural change");
});

// ── COARSE: structural changes → ONE replace-block{sectionId, rebuilt subtree} ─
check("section runToOps: adding a nested child (null id) → ONE replace-block of the whole section", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  // Append a NEW paragraph child (canvas-created → bpId:null).
  doc.content[0].content.push({
    type: "paragraph",
    attrs: { bpId: null, bpType: null },
    content: [{ type: "text", text: "new child" }],
  });

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op");
  assert.equal(ops[0].op, "replace-block", "a structural change → coarse replace-block");
  assert.equal(ops[0].id, "s-1", "keyed by the SECTION id");
  // The rebuilt subtree carries all 4 children; the new one has a minted id.
  assert.equal(ops[0].block.blocks.length, 4);
  assert.deepEqual(
    ops[0].block.blocks.slice(0, 3).map((b) => b.id),
    ["sc-h", "sc-p", "sc-c"],
    "surviving children keep their ids",
  );
  const newId = ops[0].block.blocks[3].id;
  assert.ok(newId != null && !allIds(blocks).includes(newId), "the new child got a fresh minted id");

  const folded = assertFolds(blocks, doc, ops, "section add child");
  assert.equal(folded[0].blocks.length, 4);
  assert.equal(folded[0].blocks[3].content[0].value, "new child");
});

check("section runToOps: reordering nested children → ONE replace-block (nested reorder rides inside)", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  // Swap the heading and paragraph children (child-id sequence changes).
  const c = doc.content[0].content;
  [c[0], c[1]] = [c[1], c[0]];

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "replace-block");
  assert.ok(!ops.some((o) => o.op === "move-block"), "NEVER a move-block on a nested id");
  assert.deepEqual(
    ops[0].block.blocks.map((b) => b.id),
    ["sc-p", "sc-h", "sc-c"],
    "the reorder rides inside the rebuilt subtree",
  );
  const folded = assertFolds(blocks, doc, ops, "section reorder children");
  assert.deepEqual(folded[0].blocks.map((b) => b.id), ["sc-p", "sc-h", "sc-c"]);
});

check("section runToOps: removing a nested child → ONE replace-block", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  doc.content[0].content.splice(1, 1); // drop the paragraph child
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "replace-block");
  const folded = assertFolds(blocks, doc, ops, "section remove child");
  assert.deepEqual(folded[0].blocks.map((b) => b.id), ["sc-h", "sc-c"]);
});

// ── NEW SECTION INSERT (whole subtree rebuilt; nested nulls minted) ──────────
check("section runToOps: inserting a NEW section (null id, null-id children) → insert carrying the rebuilt subtree", () => {
  const prev = [{ id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(prev);
  // A brand-new section node (bpId:null) with two canvas-created children.
  doc.content.push({
    type: "bpSection",
    attrs: { bpId: null, bpType: "section", title: "Fresh" },
    content: [
      { type: "paragraph", attrs: { bpId: null, bpType: null }, content: [{ type: "text", text: "a" }] },
      { type: "paragraph", attrs: { bpId: null, bpType: null }, content: [{ type: "text", text: "b" }] },
    ],
  });

  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(ins, "a new section inserts via the standard insert path");
  assert.equal(ins.block.type, "section");
  assert.equal(ins.block.title, "Fresh");
  assert.equal(ins.block.blocks.length, 2, "both nested children rebuilt");
  const ids = allIds([ins.block]);
  assert.equal(new Set(ids).size, ids.length, "every id in the new subtree is unique");

  const folded = assertFolds(prev, doc, ops, "new section insert");
  assert.equal(folded.length, 2);
  assert.equal(folded[1].type, "section");
  assert.deepEqual(folded[1].blocks.map((b) => b.content[0].value), ["a", "b"]);
});

// ── THE MAKE-OR-BREAK: no minted id collides with a NESTED prev id ───────────
check("section duplicate_id guard: minting a new top-level block never collides with a nested id (full-tree seed)", () => {
  const prev = [
    {
      id: "s-1",
      type: "section",
      blocks: [
        { id: "n-1", type: "paragraph", content: [{ type: "text", value: "1" }] },
        { id: "n-2", type: "paragraph", content: [{ type: "text", value: "2" }] },
        { id: "n-3", type: "paragraph", content: [{ type: "text", value: "3" }] },
      ],
    },
  ];
  const doc = runToTiptap(prev);
  // Add a NEW top-level paragraph AND a new nested child (both null id) in one batch.
  doc.content.push({
    type: "paragraph",
    attrs: { bpId: null, bpType: null },
    content: [{ type: "text", text: "top-new" }],
  });
  doc.content[0].content.push({
    type: "paragraph",
    attrs: { bpId: null, bpType: null },
    content: [{ type: "text", text: "nested-new" }],
  });

  const ops = runToOps(prev, doc);
  const folded = assertFolds(prev, doc, ops, "duplicate_id guard");
  // The observable guarantee the recursive `taken` seed protects: EVERY id in the
  // folded full tree is unique (a mint colliding with a nested id would duplicate it
  // and patch.ex would abort the batch).
  const ids = allIds(folded);
  assert.equal(new Set(ids).size, ids.length, "no id appears twice anywhere in the tree");
  // The pre-existing nested ids are all preserved.
  for (const id of ["n-1", "n-2", "n-3"]) {
    assert.ok(ids.includes(id), `nested id ${id} preserved`);
  }
});

// ── docToBlocks recurses a section ───────────────────────────────────────────
check("section docToBlocks: projects a live section doc back to blocks, minting nested null ids", () => {
  const doc = runToTiptap([SECTION()]);
  // A canvas-created nested child (null id).
  doc.content[0].content.push({
    type: "paragraph",
    attrs: { bpId: null, bpType: null },
    content: [{ type: "text", text: "live" }],
  });
  const back = docToBlocks(doc);
  assert.equal(back.length, 1);
  assert.equal(back[0].type, "section");
  assert.equal(back[0].blocks.length, 4);
  const minted = back[0].blocks[3].id;
  assert.ok(minted != null, "the null nested child got a minted id");
  const ids = allIds(back);
  assert.equal(new Set(ids).size, ids.length, "all ids unique");
});

// ── echo reconcile (V1 non-recursive) ────────────────────────────────────────
check("section reconcileServerEcho: an untouched section own-echoes (+ no idWrites)", () => {
  const server = [SECTION()];
  const liveDoc = runToTiptap(server);
  const { ownEcho, idWrites } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, true, "an unchanged section is its own echo");
  assert.equal(idWrites.length, 0);
});

check("section reconcileServerEcho: a section holding a canvas-CREATED child does NOT own-echo (v1 coarse cost)", () => {
  const server = [SECTION()];
  const liveDoc = runToTiptap(server);
  // The live section has an extra canvas-created (null id) child the server has not
  // yet confirmed → structurally different → NOT an own echo (external path → re-emit).
  liveDoc.content[0].content.push({
    type: "paragraph",
    attrs: { bpId: null, bpType: null },
    content: [{ type: "text", text: "unconfirmed" }],
  });
  const { ownEcho } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, false, "a section with an unconfirmed child re-emits (documented v1 churn)");
});

// A sanity check that the node name constant is what run-convert projects.
check("section node-name constant matches the projector", () => {
  assert.equal(BP_SECTION_NODE_NAME, "bpSection");
  assert.equal(runToTiptap([SECTION()]).content[0].type, BP_SECTION_NODE_NAME);
});
