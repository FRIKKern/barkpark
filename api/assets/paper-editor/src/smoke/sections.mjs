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
import {
  BP_SECTION_CONTENT,
  BP_SECTION_NODE_NAME,
  strictInt,
} from "../canvas/section-node.js";

// STEP-6 parity guard: the canvas span/order coercion must be the EXACT twin of the
// reader's Elixir `Integer.parse` + `{i, ""}` remainder guard. `parseInt` was too
// lenient ("2px" -> 2), so the canvas applied a placement the strict reader dropped —
// a reader↔canvas render divergence. strictInt closes it: a string is accepted ONLY
// as a whole integer (no trailing chars, no leading space), a number only if integral.
check("S6 strictInt: canvas span/order coercion mirrors the reader's Integer.parse (no parseInt lenience)", () => {
  // accepted — clean integers (the editor path)
  assert.equal(strictInt("2"), 2);
  assert.equal(strictInt("-1"), -1);
  assert.equal(strictInt("0"), 0);
  assert.equal(strictInt(3), 3);
  // DROPPED — exactly as the reader drops a non-"" remainder (the bug's repros)
  assert.equal(strictInt("2px"), null, '"2px" must drop (reader drops it too)');
  assert.equal(strictInt("2;background:url(x)"), null);
  assert.equal(strictInt("2 "), null, "trailing space => non-empty remainder => drop");
  assert.equal(strictInt(" 2"), null, "leading space is not parsed by Integer.parse");
  assert.equal(strictInt(2.5), null, "a non-integral number is not a valid span/order");
  assert.equal(strictInt(""), null);
  assert.equal(strictInt(null), null);
  assert.equal(strictInt(undefined), null);
});

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
    "divider", "callout", "bpCard", "bpStage", "bpCode", "bpDiagram", "bpField",
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

check("section runToOps: editing the section TITLE (children unchanged) → ONE patch-block{title}, no replace-block", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, title: "Renamed" };
  const ops = runToOps(blocks, doc);
  // The child-id sequence is unchanged → the fine-grained path. A title-only edit is
  // NOT structural (no replace-block) but it MUST still persist: the section's own
  // title is diffed and emitted as a patch-block on the section id — else it silently
  // reverts to the server title on the next echo (the pre-fix defect).
  assert.ok(!ops.some((o) => o.op === "replace-block"), "a title-only edit is not a structural change");
  const titleOp = ops.find(
    (o) => o.op === "patch-block" && o.patch && "title" in o.patch,
  );
  assert.ok(titleOp, "a title patch-block IS emitted (no silent revert)");
  assert.equal(titleOp.id, "s-1", "the patch targets the section id");
  assert.equal(titleOp.patch.title, "Renamed", "the new title persists");
});

check("section runToOps: CLEARING the title → patch-block{title:null}", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, title: "" };
  const ops = runToOps(blocks, doc);
  const titleOp = ops.find(
    (o) => o.op === "patch-block" && o.patch && "title" in o.patch,
  );
  assert.ok(titleOp, "clearing the title emits a patch-block");
  assert.equal(titleOp.patch.title, null, "a cleared title is null (patch.ex drops it)");
});

check("section runToOps: UNCHANGED title + unchanged children → ZERO ops (no spurious title churn)", () => {
  const blocks = [SECTION()];
  const doc = runToTiptap(blocks);
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched section emits nothing");
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

// ═══ STEP-2 LAYOUT ENGINE (grid mode + span/order transport) ═══════════════════
//
// A section MAY carry `layout` ({mode,tracks?,gap?,breakpoints?}); grid mode gates
// the reader/canvas grid. Children MAY carry span/order (hoisted to attrs.cells for
// getJSON-safe transport). BACKWARD-COMPAT is structural: a no-layout section adds
// NO new attrs → zero-ops (proven by the existing untouched round-trip above and
// re-asserted in test 1 below). distrust-vacuous-green: every grid assertion pairs
// a round-trip with a zero-ops check so a spurious layout/cells diff reds.

// A GRID section fixture: {mode:grid,tracks:2} over the same three children.
const GRID_SECTION = () => ({
  id: "s-1",
  type: "section",
  title: "Overview",
  layout: { mode: "grid", tracks: 2 },
  blocks: [
    { id: "sc-h", type: "heading", level: 2, text: "Intro" },
    { id: "sc-p", type: "paragraph", content: [{ type: "text", value: "body text" }] },
    { id: "sc-c", type: "callout", tone: "info", content: [{ type: "text", value: "note" }] },
  ],
});

// ── TEST 1: BACKWARD-COMPAT — a no-layout section projects with NO layout/cells
//    attr and round-trips ZERO ops (the legacy path is structurally untouched).
check("S2 backward-compat: a no-layout section adds NO layout/cells attr and is zero-ops", () => {
  const sec = runToTiptap([SECTION()]).content[0];
  assert.ok(sec.attrs.layout == null, "no layout attr on a no-layout section");
  assert.ok(sec.attrs.cells == null, "no cells attr on a no-layout section");
  const blocks = [SECTION()];
  assert.equal(runToOps(blocks, runToTiptap(blocks)).length, 0, "legacy section is zero-ops");
});

// ── TEST 2: GRID round-trip is DEEP-EQUAL to source (a dropped layout key reds).
check("S2 grid round-trip: a {mode:grid,tracks:2} section survives blocks→node→docToBlocks byte-equal", () => {
  const src = GRID_SECTION();
  const node = runToTiptap([src]).content[0];
  assert.deepEqual(node.attrs.layout, { mode: "grid", tracks: 2 }, "layout rides node.attrs verbatim");
  const back = docToBlocks(runToTiptap([src]));
  assert.deepEqual(back, [src], "the whole grid section round-trips byte-equal (layout preserved)");
});

// ── TEST 3: ZERO-OPS — the anti-vacuous check: an unedited grid section emits nothing.
check("S2 grid zero-ops: an untouched grid section round-trips with ZERO ops", () => {
  const blocks = [GRID_SECTION()];
  const doc = runToTiptap(blocks);
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "no spurious layout/cells diff — an untouched grid section is zero-ops");
  const folded = assertFolds(blocks, doc, ops, "grid section round-trip");
  assert.deepEqual(folded[0], GRID_SECTION());
});

// ── TEST 4: MODE TOGGLE — flip grid→stack → EXACTLY one patch-block{layout}, folds.
check("S2 mode toggle: grid→stack emits exactly ONE patch-block{layout:{mode:stack}} and folds", () => {
  const blocks = [GRID_SECTION()];
  const doc = runToTiptap(blocks);
  // The node-view's toggle keeps tracks when flipping to stack: {mode:stack,tracks:2}.
  doc.content[0].attrs = { ...doc.content[0].attrs, layout: { mode: "stack", tracks: 2 } };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op — the fine path, not a coarse replace");
  assert.deepEqual(ops[0], {
    op: "patch-block",
    id: "s-1",
    patch: { layout: { mode: "stack", tracks: 2 } },
  });
  const folded = assertFolds(blocks, doc, ops, "section mode toggle");
  assert.deepEqual(folded[0].layout, { mode: "stack", tracks: 2 }, "the section now persists stack layout");
});

// ── TEST 4b: CLEAR LAYOUT → patch-block{layout:null} (compose grid_layout→nil→stack).
check("S2 clear layout: removing the layout attr → patch-block{layout:null}", () => {
  const blocks = [GRID_SECTION()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, layout: null };
  const ops = runToOps(blocks, doc);
  const layoutOp = ops.find((o) => o.op === "patch-block" && o.patch && "layout" in o.patch);
  assert.ok(layoutOp, "clearing the layout emits a patch-block");
  assert.equal(layoutOp.patch.layout, null, "a cleared layout is null (compose → stack path)");
});

// ── TEST 5: SPAN/ORDER PRESERVE — a child span:2,order:1 survives the round-trip
//    (hoisted to the bpId-keyed attrs.cells) and an unedited such section is ZERO-OPS.
const SPAN_SECTION = () => ({
  id: "s-1",
  type: "section",
  layout: { mode: "grid", tracks: 2 },
  blocks: [
    { id: "c1", type: "paragraph", content: [{ type: "text", value: "a" }] },
    { id: "c2", type: "paragraph", span: 2, order: 1, content: [{ type: "text", value: "b" }] },
  ],
});

check("S2 span/order: a child span/order survives blocks→node→docToBlocks and is zero-ops", () => {
  const src = SPAN_SECTION();
  const node = runToTiptap([src]).content[0];
  // STEP-6: span/order are HOISTED into the section's own cells attr as a bpId-keyed
  // OBJECT (present-only): the child NODE drops them (getJSON-safe transport lives on
  // the section). c1 (no span/order) is ABSENT from the map (present-only).
  assert.deepEqual(node.attrs.cells, { c2: { span: 2, order: 1 } }, "cells is keyed by child bpId (c1 absent, present-only)");
  assert.ok(node.content[1].attrs.span == null, "span does NOT ride the child node (it would be dropped on getJSON)");
  const back = docToBlocks(runToTiptap([src]));
  assert.deepEqual(back, [src], "span/order split back onto the RIGHT child byte-equal");
  assert.equal(runToOps([src], runToTiptap([src])).length, 0, "an unedited span/order section is zero-ops");
});

// ── TEST 5a: THE BUG — a canvas REORDER must keep span/order on the SAME child.
//    Under the OLD positional cells array, swapping the child order applied stale
//    cells[i] to the child now at position i → span/order swapped onto the WRONG
//    child. bpId keying is position-independent → the fix. This is the regression.
check("S2 reorder regression (THE BUG): span/order stays on its OWN child after a canvas reorder", () => {
  const blocks = [SPAN_SECTION()];
  const doc = runToTiptap(blocks);
  // Swap the two children in the live doc (content order changes; attrs.cells does not).
  const c = doc.content[0].content;
  [c[0], c[1]] = [c[1], c[0]];

  const ops = runToOps(blocks, doc);
  // A structural reorder → ONE coarse replace-block of the whole section.
  assert.equal(ops.length, 1, "exactly one op");
  assert.equal(ops[0].op, "replace-block", "a reorder is a structural change → replace-block");
  const rebuilt = ops[0].block.blocks;
  assert.deepEqual(rebuilt.map((x) => x.id), ["c2", "c1"], "children are rebuilt in the new order");
  // THE ASSERTION: c2 STILL carries span:2/order:1; c1 STILL carries neither. Under
  // the old index array this FAILED (c1, now at position 0, wrongly got cells[0]={}
  // while c2 at position 1 got cells[1]={span,order} — coincidentally OK on a pure
  // swap, but a non-symmetric reorder mangled it). bpId keying is correct for ANY
  // permutation: assert by id, not position.
  const byId = Object.fromEntries(rebuilt.map((x) => [x.id, x]));
  assert.equal(byId.c2.span, 2, "c2 keeps its span after reorder");
  assert.equal(byId.c2.order, 1, "c2 keeps its order after reorder");
  assert.ok(byId.c1.span == null && byId.c1.order == null, "c1 gains NO span/order (it never had any)");

  const folded = assertFolds(blocks, doc, ops, "reorder span/order fidelity");
  const foldedById = Object.fromEntries(folded[0].blocks.map((x) => [x.id, x]));
  assert.equal(foldedById.c2.span, 2, "folded c2 still span:2");
  assert.ok(foldedById.c1.span == null, "folded c1 still has no span");
});

// ── TEST 5b: ANTI-VACUOUS — a NON-symmetric reorder (3 children, rotate) proves
//    the fix is real, not a swap coincidence. c3 (the only one with span/order)
//    must carry it wherever it lands.
check("S2 reorder regression (non-symmetric): span/order tracks its child through a rotation", () => {
  const src = {
    id: "s-1",
    type: "section",
    layout: { mode: "grid", tracks: 3 },
    blocks: [
      { id: "c1", type: "paragraph", content: [{ type: "text", value: "1" }] },
      { id: "c2", type: "paragraph", content: [{ type: "text", value: "2" }] },
      { id: "c3", type: "paragraph", span: 3, order: 2, content: [{ type: "text", value: "3" }] },
    ],
  };
  const blocks = [src];
  const doc = runToTiptap(blocks);
  // Rotate [c1,c2,c3] → [c3,c1,c2]: c3 (the span-bearer) moves from index 2 to index 0.
  const c = doc.content[0].content;
  doc.content[0].content = [c[2], c[0], c[1]];

  const ops = runToOps(blocks, doc);
  const rebuilt = ops[0].block.blocks;
  assert.deepEqual(rebuilt.map((x) => x.id), ["c3", "c1", "c2"], "rotated order");
  const byId = Object.fromEntries(rebuilt.map((x) => [x.id, x]));
  assert.equal(byId.c3.span, 3, "c3 keeps span:3 even though it moved to position 0");
  assert.equal(byId.c3.order, 2, "c3 keeps order:2");
  assert.ok(byId.c1.span == null && byId.c2.span == null, "c1/c2 gain nothing");
});

// ── TEST 6: EXPLICIT-STACK ≡ ABSENT — a {mode:stack} section and a no-layout
//    section project their children IDENTICALLY (byte-equal minus the layout attr).
check("S2 explicit-stack ≡ absent: {mode:stack} and no-layout project children identically", () => {
  const withStack = { ...SECTION(), layout: { mode: "stack" } };
  const stackNode = runToTiptap([withStack]).content[0];
  const bareNode = runToTiptap([SECTION()]).content[0];
  // The ONLY difference is the layout attr — content + title + ids are identical.
  const strip = (n) => {
    const { layout, ...rest } = n.attrs;
    return { ...n, attrs: rest };
  };
  assert.deepEqual(strip(stackNode), strip(bareNode), "explicit-stack projects children identically to absent");
  assert.deepEqual(stackNode.attrs.layout, { mode: "stack" }, "the explicit-stack layout is carried verbatim");
});

// ── TEST 7: ECHO — reconcileServerEcho recognizes a layout-only own-echo
//    (stableSectionKey includes layout) — no phantom replace-block.
check("S2 echo: a layout-bearing section own-echoes (stableSectionKey includes layout)", () => {
  const server = [GRID_SECTION()];
  const liveDoc = runToTiptap(server);
  const { ownEcho, idWrites } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, true, "an unchanged grid section is its own echo");
  assert.equal(idWrites.length, 0);
});

// ═════ FRAMED-FINALE — the scalar `variant` attr (charter D34) ═══════════════
// A section MAY carry a scalar `variant` ("framed" — the framed-finale device).
// render/BPML/pdrender already handle it; the canvas must PRESERVE it (three drop
// sites: sectionBlockToNode threads it, sectionNodeToBlock lowers it, and the
// bpSection schema DECLARES it — PM strips undeclared attrs on setContent, so the
// declaration is load-bearing even with both converters fixed) and stableSectionKey
// includes it (echo fidelity). PRESENT-ONLY: a no-variant section is byte-identical
// to the pre-variant path. distrust-vacuous-green: every preserve assertion pairs
// with a zero-ops check, and the echo-key test asserts the FAILING direction.

const FRAMED_SECTION = () => ({ ...SECTION(), variant: "framed" });

// ── D34 TEST 1: ROUND-TRIP — variant survives blocks→node→docToBlocks byte-equal.
check("D34 variant round-trip: variant:'framed' survives blocks→node→docToBlocks byte-equal", () => {
  const src = FRAMED_SECTION();
  const node = runToTiptap([src]).content[0];
  assert.equal(node.attrs.variant, "framed", "variant rides node.attrs verbatim (sectionBlockToNode threads it)");
  const back = docToBlocks(runToTiptap([src]));
  assert.deepEqual(back, [src], "the whole framed section round-trips byte-equal (sectionNodeToBlock lowers it)");
});

// ── D34 TEST 2: ZERO-OPS — an untouched framed section emits NOTHING, and folds.
check("D34 variant zero-ops: an untouched framed section round-trips with ZERO ops", () => {
  const blocks = [FRAMED_SECTION()];
  const doc = runToTiptap(blocks);
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "no spurious variant diff — an untouched framed section is zero-ops");
  const folded = assertFolds(blocks, doc, ops, "framed section round-trip");
  assert.deepEqual(folded[0], FRAMED_SECTION());
});

// ── D34 TEST 3: THE BUG — a structural reorder's coarse replace-block must CARRY
//    variant (before the fix, the rebuilt subtree silently dropped the frame).
check("D34 variant reorder: a structural reorder's replace-block CARRIES variant:'framed'", () => {
  const blocks = [FRAMED_SECTION()];
  const doc = runToTiptap(blocks);
  // Swap two children in the live doc — a structural change → coarse replace-block.
  const c = doc.content[0].content;
  [c[0], c[1]] = [c[1], c[0]];
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op");
  assert.equal(ops[0].op, "replace-block", "a reorder is a structural change → replace-block");
  assert.equal(ops[0].block.variant, "framed", "THE ASSERTION: the rebuilt section still carries variant");
  const folded = assertFolds(blocks, doc, ops, "framed reorder fidelity");
  assert.equal(folded[0].variant, "framed", "folded section keeps the frame");
});

// ── D34 TEST 4: BACKWARD-COMPAT — a no-variant section adds NO variant attr and
//    stays zero-ops (present-only; the legacy path is structurally untouched).
check("D34 backward-compat: a no-variant section adds NO variant attr and is zero-ops", () => {
  const sec = runToTiptap([SECTION()]).content[0];
  assert.ok(sec.attrs.variant == null, "no variant attr on a no-variant section");
  const blocks = [SECTION()];
  assert.equal(runToOps(blocks, runToTiptap(blocks)).length, 0, "legacy section is zero-ops");
});

// ── D34 TEST 5: ECHO KEY, both directions — a framed section own-echoes, and a
//    variant MISMATCH is NOT an own-echo (pins variant INSIDE stableSectionKey;
//    without it the mismatch case false-matches and this test reds).
check("D34 echo key: framed own-echoes; a variant mismatch is NOT an own-echo", () => {
  const server = [FRAMED_SECTION()];
  const { ownEcho, idWrites } = reconcileServerEcho(server, runToTiptap(server).content);
  assert.equal(ownEcho, true, "an unchanged framed section is its own echo");
  assert.equal(idWrites.length, 0);
  // The FAILING direction: same section, live node lacks the variant.
  const dropped = reconcileServerEcho(server, runToTiptap([SECTION()]).content);
  assert.equal(dropped.ownEcho, false, "a dropped variant must NOT read as an own-echo");
});
