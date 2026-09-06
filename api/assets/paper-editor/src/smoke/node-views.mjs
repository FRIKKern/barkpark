// smoke/node-views.mjs — S3.x canvas node-view projection + round-trip gates:
// divider (S3) / callout (S3.2) / code (S3.3) / diagram (S3.4) / native field (S3.5)
// / sheet + embed read-only atoms (S3.6).
//
// VERBATIM extraction from src/__smoke.mjs: each S3.x section's projection /
// round-trip / edit / insert / remove / non-interference / still-opaque checks moved
// unchanged (same names, bodies, assertions), carrying their section-local fixtures
// (S35_FIELD_SEEDS / S35_FIELD_EDITS, S36_SHEET / S36_EMBED / S36_NODE_NAME / S36_SEEDS)
// with the section that uses them. The shared check()/assertFolds run through the
// harness so the aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import { coerceFieldValue, BP_NATIVE_FIELD_TYPES } from "../canvas/field-node.js";
import {
  sheetChipLabel,
  embedChipLabel,
  BP_SHEET_NODE_NAME,
  BP_EMBED_NODE_NAME,
} from "../canvas/embed-node.js";

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3 — the divider as a canvas ATOM node (run-convert.js).
// A divider in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"divider", attrs:{bpId,bpType} } leaf, and runToOps reconstructs a
// bare { type:"divider" } block. A leaf → NEVER an interior patch.
// ───────────────────────────────────────────────────────────────────────────

// S3-a) PROJECTION — a divider in a run projects to a native divider ATOM node
//       carrying ONLY { bpId, bpType }, NOT a bpOpaque placeholder. The prose
//       blocks around it still project as their own stamped textblocks.
check("S3 runToTiptap: a divider → { type:'divider', attrs:{bpId,bpType} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    { id: "d-1", type: "divider" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  assert.equal(doc.content.length, 3);

  const div = doc.content[1];
  assert.equal(div.type, "divider", "divider projects to a native divider node");
  assert.notEqual(div.type, "bpOpaque", "divider is NOT carried opaquely");
  assert.equal(div.attrs.bpId, "d-1");
  assert.equal(div.attrs.bpType, "divider");
  // A leaf: no content, and no opaque bpBlock carry.
  assert.ok(!("content" in div), "divider leaf carries no content");
  assert.ok(!("bpBlock" in div.attrs), "divider carries no opaque bpBlock");

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "heading");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3-b) ROUND-TRIP — an UNTOUCHED divider survives runToOps with ZERO ops (a
//       leaf reports no interior change), and the whole mixed run folds back to
//       the identical block list.
check("S3 runToOps: an untouched divider round-trips with ZERO ops", () => {
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    { id: "d-1", type: "divider" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched divider run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the divider survives as
  // its bare { id, type } leaf.
  const folded = assertFolds(blocks, doc, ops, "S3-b divider round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "d-1", "p-1"]);
  assert.deepEqual(folded[1], { id: "d-1", type: "divider" });
});

// S3-c) INSERT — a NEW divider (no bpId) between two surviving prose blocks →
//       an insert-after carrying a { type:"divider" } block with a client-minted
//       id, and NO patch on the divider (a leaf). The fold lands the divider
//       between the two prose blocks.
check("S3 runToOps: inserting a divider → insert-after with a {type:'divider'} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Splice a NEW divider (bpId null → minted) between p-1 and p-2.
  doc.content = [
    doc.content[0], // p-1
    { type: "divider", attrs: { bpId: null, bpType: "divider" } },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);

  // The new divider is grafted in as a divider BLOCK with a fresh minted id.
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "divider",
  );
  assert.ok(ins, "a divider block is inserted");
  assert.equal(ins.block.type, "divider");
  assert.ok(ins.block.id != null, "the inserted divider carries a minted id");
  assert.ok(
    ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the divider's minted id avoids the surviving prev ids",
  );
  // A leaf insert carries no body fields beyond id + type.
  assert.deepEqual(Object.keys(ins.block).sort(), ["id", "type"]);
  // No interior patch is emitted for the divider (it is a leaf).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "a divider never emits an interior patch",
  );

  // FOLD GATE: the divider lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3-c divider insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "divider");
  assert.equal(folded[2].id, "p-2");
});

// S3-d) REMOVE — deleting a divider → a remove-block keyed by its id, and the
//       surrounding prose is untouched (no spurious patches). The fold drops it.
check("S3 runToOps: removing a divider → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "d-1", type: "divider" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Backspace-deletes the divider: the doc is now just the two prose blocks.
  doc.content = [doc.content[0], doc.content[2]];

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "d-1" }],
    "exactly one remove-block for the divider",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  // FOLD GATE: the divider is gone; the two prose blocks remain in order.
  const folded = assertFolds(blocks, doc, ops, "S3-d divider remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3-e) NON-INTERFERENCE — a divider between two prose blocks does not break the
//       prose diff: editing BOTH prose blocks emits exactly their two patches and
//       the divider emits NONE. (Proves the leaf sits transparently in the run.)
check("S3 runToOps: a divider between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "d-1", type: "divider" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  // Edit BOTH prose blocks; leave the divider untouched.
  doc.content[0] = {
    ...doc.content[0],
    content: [{ type: "text", text: "ONE!" }],
  };
  doc.content[2] = {
    ...doc.content[2],
    content: [{ type: "text", text: "TWO!" }],
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the divider");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "d-1").length,
    0,
    "the divider emits no patch",
  );

  // FOLD GATE: both prose blocks carry their new content; the divider survives
  // untouched at slot 1.
  const folded = assertFolds(blocks, doc, ops, "S3-e divider non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], { id: "d-1", type: "divider" });
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3-f) STILL-OPAQUE — a NESTED-STRUCTURE field (composite), still a boundary, is
//       STILL carried opaquely. (S3.5 pulled the 7 NATIVE field-* types into the canvas;
//       the run-splitter tail pulled the PICKER fields field-image / field-reference in
//       too — but composite / arrayOf / codelist / localizedText / section stay opaque
//       boundaries, a separate nested-structure increment.)
check("S3 runToTiptap: a composite field is STILL opaque (native + picker fields became canvas-handled, nested-structure fields did not)", () => {
  const field = {
    id: "f-1",
    type: "composite",
    fields: [{ name: "x", type: "string", title: "X" }],
    value: { x: "v" },
  };
  const doc = runToTiptap([field]);
  assert.equal(doc.content[0].type, "bpOpaque", "composite stays opaque");
  assert.deepEqual(doc.content[0].attrs.bpBlock, field);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.2 — the callout as a canvas CONTENT node (run-convert.js).
// A callout in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"callout", attrs:{bpId,bpType,tone,title?,collapsible?,collapsed?},
//   content:[inline…] } node, and runToOps reconstructs a callout block via
// calloutNodeToBlock. Unlike the divider ATOM, a callout HAS an editable body, so
// a body/chrome edit → exactly one patch-block; an untouched callout → ZERO ops.
// ───────────────────────────────────────────────────────────────────────────

// S3.2-a) PROJECTION — a callout in a run projects to a native callout CONTENT
//   node (NOT bpOpaque): body→content (inline), tone/title/collapsible→attrs.
check("S3.2 runToTiptap: a callout → { type:'callout', content:[…], attrs:{tone,title,collapsible} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    {
      id: "c-1",
      type: "callout",
      tone: "warning",
      title: "Heads up",
      collapsible: true,
      content: [
        { type: "text", value: "Be " },
        { type: "strong", children: [{ type: "text", value: "careful" }] },
      ],
    },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const c = doc.content[1];
  assert.equal(c.type, "callout", "callout projects to a native callout node");
  assert.notEqual(c.type, "bpOpaque", "callout is NOT carried opaquely");
  assert.equal(c.attrs.bpId, "c-1");
  assert.equal(c.attrs.bpType, "callout");
  // Chrome rides attrs.
  assert.equal(c.attrs.tone, "warning");
  assert.equal(c.attrs.title, "Heads up");
  assert.equal(c.attrs.collapsible, true);
  assert.ok(!("collapsed" in c.attrs), "absent collapsed is NOT projected (byte-fidelity)");
  assert.ok(!("bpBlock" in c.attrs), "callout carries no opaque bpBlock");
  // Body is editable inline content — reuses the shared inline serializer, so the
  // bold mark round-trips exactly as a paragraph's would.
  assert.deepEqual(c.content, [
    { type: "text", text: "Be " },
    { type: "text", text: "careful", marks: [{ type: "bold" }] },
  ]);

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3.2-b) ROUND-TRIP — an UNTOUCHED callout survives runToOps with ZERO ops
//   (canonical compare), and the whole mixed run folds back to the identical
//   block list (body inline + chrome fields all preserved, absent fields absent).
check("S3.2 runToOps: an untouched callout round-trips with ZERO ops (canonical compare)", () => {
  const callout = {
    id: "c-1",
    type: "callout",
    tone: "info",
    content: [{ type: "text", value: "note" }],
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    callout,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Simulate the live editor's getJSON key order on the callout's body text node
  // (type, marks, text) AND its attrs — change-detection must be key-order-safe.
  const c = doc.content[1];
  c.attrs = { bpType: "callout", tone: "info", bpId: "c-1" }; // reordered keys
  c.content = [{ text: "note", type: "text" }]; // reordered keys

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched callout run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the callout survives with
  // its tone + body, and NO stray title/collapsible/collapsed.
  const folded = assertFolds(blocks, doc, ops, "S3.2-b callout round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "c-1", "p-1"]);
  assert.deepEqual(folded[1], callout);
});

// S3.2-c) BODY EDIT — editing the callout's BODY → exactly one patch-block for
//   the callout carrying the new content (and tone), no prose perturbation.
check("S3.2 runToOps: editing the callout BODY → one patch-block with the new content", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      content: [{ type: "text", value: "old body" }],
    },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Edit ONLY the callout body (live-editor key order).
  doc.content[1] = {
    ...doc.content[1],
    content: [{ type: "text", text: "new body!" }],
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the callout");
  assert.equal(patches[0].id, "c-1");
  assert.deepEqual(patches[0].patch.content, [{ type: "text", value: "new body!" }]);
  assert.equal(patches[0].patch.tone, "info", "tone is carried in the patch");
  // The patch carries the chrome fields EXPLICITLY (removal-safe over the shallow
  // merge): a title-less callout patches title:null, which compose drops — so the
  // stored callout stays title-less.
  assert.equal(patches[0].patch.title, null, "explicit title:null (removal-safe)");
  assert.equal(patches[0].patch.collapsible, false);
  assert.equal(patches[0].patch.collapsed, false);

  // FOLD GATE: the callout carries its new body; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.2-c callout body edit");
  assert.deepEqual(folded[1].content, [{ type: "text", value: "new body!" }]);
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// S3.2-d) CHROME EDIT — changing tone / title / collapsed → a patch-block
//   carrying that field. Three sub-cases, each emitting exactly one patch.
check("S3.2 runToOps: changing tone → a patch-block carrying the new tone", () => {
  const blocks = [
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, tone: "danger" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "c-1");
  assert.equal(ops[0].patch.tone, "danger");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d tone change");
  assert.equal(folded[0].tone, "danger");
});

check("S3.2 runToOps: changing title → a patch-block carrying the new title", () => {
  const blocks = [
    { id: "c-1", type: "callout", tone: "info", title: "Old", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, title: "New title" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.title, "New title");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d title change");
  assert.equal(folded[0].title, "New title");
});

check("S3.2 runToOps: toggling the fold (collapsed) → a patch-block carrying collapsed", () => {
  const blocks = [
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      collapsible: true,
      content: [{ type: "text", value: "x" }],
    },
  ];
  const doc = runToTiptap(blocks);
  // The fold toggle flips collapsed false→true on the node attrs.
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, collapsed: true },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].patch.collapsed, true);
  assert.equal(ops[0].patch.collapsible, true, "collapsible is carried alongside");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d fold toggle");
  assert.equal(folded[0].collapsed, true);
});

// S3.2-d2) REMOVAL DIRECTIONS — patch-block is a SHALLOW merge that cannot delete
//   a key, so EXPANDING a collapsed callout (collapsed true→false) and CLEARING a
//   title (set→null) must emit the field EXPLICITLY or the stale value survives the
//   merge and the edit silently reverts on reload. These fold through the real
//   shallow-merge (applyOps) — they FAIL if calloutNodeToPatch omits false/null.
check("S3.2 runToOps: EXPANDING a collapsed callout (true→false) actually persists", () => {
  const blocks = [
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      collapsible: true,
      collapsed: true,
      content: [{ type: "text", value: "x" }],
    },
  ];
  const doc = runToTiptap(blocks);
  // Fold button expands it: collapsed true→false on the node attrs.
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, collapsed: false },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.collapsed, false, "explicit collapsed:false in the patch");

  // FOLD GATE through the shallow merge: the stored callout is now EXPANDED.
  const folded = assertFolds(blocks, doc, ops, "S3.2-d2 expand");
  assert.equal(folded[0].collapsed, false, "expand persists (no stale collapsed:true)");
});

check("S3.2 runToOps: CLEARING a title (set→null) actually persists", () => {
  const blocks = [
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      title: "Old title",
      content: [{ type: "text", value: "x" }],
    },
  ];
  const doc = runToTiptap(blocks);
  // Clear the title: set→null on the node attrs.
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, title: null },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.title, null, "explicit title:null in the patch");

  // FOLD GATE: the stored callout's title is gone (compose drops a null title).
  const folded = assertFolds(blocks, doc, ops, "S3.2-d2 title clear");
  assert.equal(folded[0].title, null, "title cleared (no stale old title)");
});

// S3.2-e) INSERT — a NEW callout (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"callout", … } block with a client-minted
//   id, body + chrome reconstructed. The fold lands it between the prose.
check("S3.2 runToOps: inserting a callout → insert-after with a {type:'callout'} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "callout",
      attrs: { bpId: null, bpType: "callout", tone: "success", title: "Done" },
      content: [{ type: "text", text: "shipped" }],
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "callout",
  );
  assert.ok(ins, "a callout block is inserted");
  assert.equal(ins.block.type, "callout");
  assert.ok(ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2", "minted id avoids prev ids");
  assert.equal(ins.block.tone, "success");
  assert.equal(ins.block.title, "Done");
  assert.deepEqual(ins.block.content, [{ type: "text", value: "shipped" }]);
  // No separate interior patch for a fresh insert (the body rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted callout emits no extra interior patch",
  );

  // FOLD GATE: the callout lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.2-e callout insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "callout");
  assert.equal(folded[2].id, "p-2");
});

// S3.2-f) REMOVE — deleting a callout → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("S3.2 runToOps: removing a callout → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "x" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the callout

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "c-1" }],
    "exactly one remove-block for the callout",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.2-f callout remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.2-g) NON-INTERFERENCE — a callout between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the callout untouched)
//   emits exactly their two patches and NONE for the callout.
check("S3.2 runToOps: a callout between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "mid" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the callout");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);

  const folded = assertFolds(blocks, doc, ops, "S3.2-g callout non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "callout untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.3 — the code block as a canvas ATTR-ATOM node (run-convert.js).
// A code block in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"bpCode", attrs:{bpId,bpType,value,lang?} } ATOM node (node NAME bpCode,
// bpType "code" — the StarterKit inline code MARK owns the name `code`), and
// runToOps reconstructs a { type:"code", value, lang? } block via codeNodeToBlock.
// UNLIKE the divider ATOM (no interior, zero ops forever), a code attr-atom HAS a
// mutable value/lang, so a value/lang edit → exactly one patch-block; an untouched
// code → ZERO ops. UNLIKE the callout it has NO inline body (value is a string).
// ───────────────────────────────────────────────────────────────────────────

// S3.3-a) PROJECTION — a code block projects to a native bpCode ATTR-ATOM node
//   (NOT bpOpaque): value→attr, lang→attr (only when present). node.type is the
//   NODE name `bpCode`, NOT the bpType `code`.
check("S3.3 runToTiptap: a code block → { type:'bpCode', attrs:{bpId,bpType,value,lang} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "k-1", type: "code", lang: "elixir", value: "IO.puts(:ok)\n:done" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const k = doc.content[1];
  assert.equal(k.type, "bpCode", "code projects to a native bpCode node");
  assert.notEqual(k.type, "bpOpaque", "code is NOT carried opaquely");
  assert.notEqual(k.type, "code", "node name is bpCode (code is the inline MARK)");
  assert.equal(k.attrs.bpId, "k-1");
  assert.equal(k.attrs.bpType, "code");
  // value rides an attr, MULTI-LINE preserved verbatim.
  assert.equal(k.attrs.value, "IO.puts(:ok)\n:done");
  assert.equal(k.attrs.lang, "elixir");
  // An atom: no content hole, no opaque bpBlock carry.
  assert.ok(!("content" in k), "code atom carries no content");
  assert.ok(!("bpBlock" in k.attrs), "code carries no opaque bpBlock");

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3.3-a2) PROJECTION — a code block WITHOUT lang projects with NO lang attr
//   (byte-fidelity: put_if_present drops an absent/empty lang on persist).
check("S3.3 runToTiptap: a lang-less code block carries NO lang attr", () => {
  const doc = runToTiptap([{ id: "k-1", type: "code", value: "x = 1" }]);
  const k = doc.content[0];
  assert.equal(k.type, "bpCode");
  assert.equal(k.attrs.value, "x = 1");
  assert.ok(!("lang" in k.attrs), "absent lang is NOT projected");
});

// S3.3-b) ROUND-TRIP — an UNTOUCHED code block survives runToOps with ZERO ops
//   (canonical compare, incl. a MULTI-LINE value + reordered attr keys), and the
//   whole mixed run folds back to the identical block list (value + lang preserved,
//   absent lang absent).
check("S3.3 runToOps: an untouched code block round-trips with ZERO ops (multi-line + reordered keys)", () => {
  const code = {
    id: "k-1",
    type: "code",
    lang: "js",
    value: "function f() {\n  return 42;\n}",
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    code,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Simulate the live editor's getJSON attr key order (reordered) — change
  // detection must be key-order-safe.
  const k = doc.content[1];
  k.attrs = { value: "function f() {\n  return 42;\n}", bpType: "code", lang: "js", bpId: "k-1" };

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched code run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the code survives with its
  // multi-line value + lang, and the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.3-b code round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "k-1", "p-1"]);
  assert.deepEqual(folded[1], code);
});

// S3.3-b2) ROUND-TRIP — an untouched LANG-LESS code block emits ZERO ops and folds
//   back WITHOUT a lang key (lang:null normalizes to "" for compare).
check("S3.3 runToOps: an untouched lang-less code block round-trips with ZERO ops", () => {
  const code = { id: "k-1", type: "code", value: "noop" };
  const blocks = [code, { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched lang-less code emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.3-b2 lang-less code round-trip");
  assert.deepEqual(folded[0], code);
  assert.ok(!("lang" in folded[0]), "folded code carries no lang key");
});

// S3.3-c) VALUE EDIT — editing the code's value → exactly one patch-block carrying
//   the new value, no prose perturbation. The patch carries value (the new text).
check("S3.3 runToOps: editing the code VALUE → one patch-block with the new value", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "k-1", type: "code", value: "old code" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // The textarea island wrote the new value back to the node's `value` attr.
  doc.content[1] = {
    ...doc.content[1],
    attrs: { ...doc.content[1].attrs, value: "new code line\nsecond line" },
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the code");
  assert.equal(patches[0].id, "k-1");
  assert.equal(patches[0].patch.value, "new code line\nsecond line");
  assert.equal("lang" in patches[0].patch, false,
    "a body-only edit must not create an absent language field");

  // FOLD GATE: the code carries its new value; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.3-c code value edit");
  assert.equal(folded[1].value, "new code line\nsecond line");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// S3.3-d) LANG CHANGE — changing the language → a patch-block carrying the new
//   lang (and the unchanged value).
check("S3.3 runToOps: changing the code LANG → a patch-block carrying the new lang", () => {
  const blocks = [
    { id: "k-1", type: "code", lang: "js", value: "x" },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, lang: "ruby" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "k-1");
  assert.equal(ops[0].patch.lang, "ruby");
  assert.equal(ops[0].patch.value, "x", "value carried alongside");

  const folded = assertFolds(blocks, doc, ops, "S3.3-d lang change");
  assert.equal(folded[0].lang, "ruby");
});

// S3.3-d2) CLEARING the lang (set→"" via the lang input) emits lang:"" which the
//   server drops (put_if_present) — so the stored code becomes lang-less. The fold
//   here uses the JS reference applyOps (shallow merge), then we assert the
//   reconstructed-on-reload block via codeNodeToBlock semantics: lang "" → no key.
check("S3.3 runToOps: CLEARING the lang (set→'') persists lang:'' in the patch", () => {
  const blocks = [
    { id: "k-1", type: "code", lang: "js", value: "x" },
  ];
  const doc = runToTiptap(blocks);
  // The lang input cleared → null on the node attrs (the node-view maps "" → null).
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, lang: null },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.lang, "", "explicit lang:'' in the patch (removal-safe)");

  // FOLD GATE: the shallow merge writes lang:"". (On the server put_if_present
  // would drop it; the JS reference fold keeps the explicit "" — which is the
  // lang-less canonical for compare, so a subsequent round-trip is a no-op.)
  const folded = assertFolds(blocks, doc, ops, "S3.3-d2 lang clear");
  assert.equal(folded[0].lang, "");
});

// S3.3-e) INSERT — a NEW code block (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"code", value, lang? } block with a
//   client-minted id. The fold lands it between the prose.
check("S3.3 runToOps: inserting a code block → insert-after with a {type:'code', value} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpCode",
      attrs: { bpId: null, bpType: "code", value: "let y = 2", lang: "ts" },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "code",
  );
  assert.ok(ins, "a code block is inserted");
  assert.equal(ins.block.type, "code", "the inserted block carries bpType 'code' (not 'bpCode')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.value, "let y = 2");
  assert.equal(ins.block.lang, "ts");
  // No separate interior patch for a fresh insert (the value rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted code emits no extra interior patch",
  );

  // FOLD GATE: the code lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.3-e code insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "code");
  assert.equal(folded[1].value, "let y = 2");
  assert.equal(folded[2].id, "p-2");
});

// S3.3-e2) INSERT a LANG-LESS code block → the inserted block has NO lang key.
check("S3.3 runToOps: inserting a lang-less code block → block carries no lang key", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpCode", attrs: { bpId: null, bpType: "code", value: "bare" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "code",
  );
  assert.ok(ins, "a code block is inserted");
  assert.equal(ins.block.value, "bare");
  assert.ok(!("lang" in ins.block), "a lang-less insert carries no lang key");
  assert.deepEqual(Object.keys(ins.block).sort(), ["id", "type", "value"]);
});

// S3.3-f) REMOVE — deleting a code block → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("S3.3 runToOps: removing a code block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "k-1", type: "code", value: "drop me" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the code

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "k-1" }],
    "exactly one remove-block for the code",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.3-f code remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.3-g) NON-INTERFERENCE — a code block between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the code untouched) emits
//   exactly their two patches and NONE for the code.
check("S3.3 runToOps: a code block between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "k-1", type: "code", lang: "sh", value: "echo hi" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the code");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "k-1").length,
    0,
    "the code emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "S3.3-g code non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "code untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3.3-h) STILL-OPAQUE — a non-canvas block (composite, a nested-structure field) is
//   STILL carried opaquely. divider (S3), callout (S3.2), code (S3.3), diagram (S3.4),
//   the 7 NATIVE field-* types (S3.5), and the 2 PICKER fields field-image /
//   field-reference (run-splitter tail) are ALL canvas-handled; composite / arrayOf /
//   codelist / localizedText / section remain opaque boundaries.
check("S3.3 runToTiptap: a composite field is STILL opaque (native + picker fields canvas-handled, nested-structure fields not)", () => {
  const field = { id: "f-1", type: "composite", fields: [], value: {} };
  const doc = runToTiptap([field]);
  assert.equal(doc.content[0].type, "bpOpaque", "composite stays opaque");
  assert.deepEqual(doc.content[0].attrs.bpBlock, field);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.4 — the diagram block as a canvas ATTR-ATOM node (run-convert.js),
// MIRRORING the S3.3 code cases. A diagram block in a run is NO LONGER opaque:
// runToTiptap emits a native { type:"bpDiagram", attrs:{bpId,bpType,source,caption?} }
// ATOM node (node NAME bpDiagram, bpType "diagram"), and runToOps reconstructs a
// { type:"diagram", source, caption? } block via diagramNodeToBlock. UNLIKE the
// divider ATOM (no interior, zero ops forever), a diagram attr-atom HAS a mutable
// source/caption, so a source/caption edit → exactly one patch-block; an untouched
// diagram → ZERO ops. UNLIKE the callout it has NO inline body (source is a string).
// The diagram's body field is `source` (NOT `value`) and its optional field is
// `caption` (where code had `lang`).
// ───────────────────────────────────────────────────────────────────────────

// S3.4-a) PROJECTION — a diagram block projects to a native bpDiagram ATTR-ATOM node
//   (NOT bpOpaque): source→attr, caption→attr (only when present). node.type is the
//   NODE name `bpDiagram`, NOT the bpType `diagram`.
check("S3.4 runToTiptap: a diagram block → { type:'bpDiagram', attrs:{bpId,bpType,source,caption} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "g-1", type: "diagram", caption: "Figure 1.", source: "graph TD\n  A-->B" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const g = doc.content[1];
  assert.equal(g.type, "bpDiagram", "diagram projects to a native bpDiagram node");
  assert.notEqual(g.type, "bpOpaque", "diagram is NOT carried opaquely");
  assert.notEqual(g.type, "diagram", "node name is bpDiagram (not the bpType)");
  assert.equal(g.attrs.bpId, "g-1");
  assert.equal(g.attrs.bpType, "diagram");
  // source rides an attr, MULTI-LINE preserved verbatim.
  assert.equal(g.attrs.source, "graph TD\n  A-->B");
  assert.equal(g.attrs.caption, "Figure 1.");
  // An atom: no content hole, no opaque bpBlock carry.
  assert.ok(!("content" in g), "diagram atom carries no content");
  assert.ok(!("bpBlock" in g.attrs), "diagram carries no opaque bpBlock");

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3.4-a2) PROJECTION — a diagram block WITHOUT caption projects with NO caption attr
//   (byte-fidelity: an absent/empty caption round-trips as absent, like code's lang).
check("S3.4 runToTiptap: a caption-less diagram block carries NO caption attr", () => {
  const doc = runToTiptap([{ id: "g-1", type: "diagram", source: "graph LR\n  X-->Y" }]);
  const g = doc.content[0];
  assert.equal(g.type, "bpDiagram");
  assert.equal(g.attrs.source, "graph LR\n  X-->Y");
  assert.ok(!("caption" in g.attrs), "absent caption is NOT projected");
});

// S3.4-b) ROUND-TRIP — an UNTOUCHED diagram block survives runToOps with ZERO ops
//   (canonical compare, incl. a MULTI-LINE source + reordered attr keys), and the
//   whole mixed run folds back to the identical block list (source + caption
//   preserved, absent caption absent).
check("S3.4 runToOps: an untouched diagram block round-trips with ZERO ops (multi-line + reordered keys)", () => {
  const diagram = {
    id: "g-1",
    type: "diagram",
    caption: "Figure 2. The flow.",
    source: "sequenceDiagram\n  Alice->>Bob: hi\n  Bob-->>Alice: yo",
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    diagram,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Simulate the live editor's getJSON attr key order (reordered) — change
  // detection must be key-order-safe.
  const g = doc.content[1];
  g.attrs = {
    source: "sequenceDiagram\n  Alice->>Bob: hi\n  Bob-->>Alice: yo",
    bpType: "diagram",
    caption: "Figure 2. The flow.",
    bpId: "g-1",
  };

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched diagram run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the diagram survives with its
  // multi-line source + caption, and the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.4-b diagram round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "g-1", "p-1"]);
  assert.deepEqual(folded[1], diagram);
});

// S3.4-b2) ROUND-TRIP — an untouched CAPTION-LESS diagram block emits ZERO ops and
//   folds back WITHOUT a caption key (caption:null normalizes to "" for compare).
check("S3.4 runToOps: an untouched caption-less diagram block round-trips with ZERO ops", () => {
  const diagram = { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" };
  const blocks = [diagram, { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched caption-less diagram emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.4-b2 caption-less diagram round-trip");
  assert.deepEqual(folded[0], diagram);
  assert.ok(!("caption" in folded[0]), "folded diagram carries no caption key");
});

// S3.4-c) SOURCE EDIT — editing the diagram's source → exactly one patch-block
//   carrying the new source, no prose perturbation.
check("S3.4 runToOps: editing the diagram SOURCE → one patch-block with the new source", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // The textarea island wrote the new source back to the node's `source` attr.
  doc.content[1] = {
    ...doc.content[1],
    attrs: { ...doc.content[1].attrs, source: "graph LR\n  A-->B\n  B-->C" },
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the diagram");
  assert.equal(patches[0].id, "g-1");
  assert.equal(patches[0].patch.source, "graph LR\n  A-->B\n  B-->C");
  // caption explicit as "" (removal-safe: a caption-less diagram patches caption:"").
  assert.equal(patches[0].patch.caption, "", "caption explicit '' (removal-safe)");

  // FOLD GATE: the diagram carries its new source; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.4-c diagram source edit");
  assert.equal(folded[1].source, "graph LR\n  A-->B\n  B-->C");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// S3.4-d) CAPTION SET — setting the caption → a patch-block carrying the new caption
//   (and the unchanged source).
check("S3.4 runToOps: setting the diagram CAPTION → a patch-block carrying the new caption", () => {
  const blocks = [
    { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, caption: "Figure 3." },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "g-1");
  assert.equal(ops[0].patch.caption, "Figure 3.");
  assert.equal(ops[0].patch.source, "graph TD\n  A-->B", "source carried alongside");

  const folded = assertFolds(blocks, doc, ops, "S3.4-d caption set");
  assert.equal(folded[0].caption, "Figure 3.");
});

// S3.4-d2) CLEARING the caption (set→"" via the caption input) emits caption:"" which
//   the shallow merge stores — render-equivalent to a caption-less diagram. The
//   canonical compare normalizes ""/null equal so a subsequent round-trip is a no-op.
check("S3.4 runToOps: CLEARING the caption (set→'') persists caption:'' in the patch", () => {
  const blocks = [
    { id: "g-1", type: "diagram", caption: "Figure 4.", source: "graph TD\n  A-->B" },
  ];
  const doc = runToTiptap(blocks);
  // The caption input cleared → null on the node attrs (node-view maps "" → null).
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, caption: null },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.caption, "", "explicit caption:'' in the patch (removal-safe)");

  // FOLD GATE: the shallow merge writes caption:"" (render-equivalent to caption-less).
  const folded = assertFolds(blocks, doc, ops, "S3.4-d2 caption clear");
  assert.equal(folded[0].caption, "");
});

// S3.4-e) INSERT — a NEW diagram block (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"diagram", source, caption? } block with a
//   client-minted id. The fold lands it between the prose.
check("S3.4 runToOps: inserting a diagram block → insert-after with a {type:'diagram', source} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpDiagram",
      attrs: { bpId: null, bpType: "diagram", source: "graph TD\n  M-->N", caption: "Figure 5." },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "diagram",
  );
  assert.ok(ins, "a diagram block is inserted");
  assert.equal(ins.block.type, "diagram", "the inserted block carries bpType 'diagram' (not 'bpDiagram')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.source, "graph TD\n  M-->N");
  assert.equal(ins.block.caption, "Figure 5.");
  // No separate interior patch for a fresh insert (the source rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted diagram emits no extra interior patch",
  );

  // FOLD GATE: the diagram lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.4-e diagram insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "diagram");
  assert.equal(folded[1].source, "graph TD\n  M-->N");
  assert.equal(folded[2].id, "p-2");
});

// S3.4-e2) INSERT a CAPTION-LESS diagram block → the inserted block has NO caption
//   key (the insert path mirrors the persist default — render-equivalent to "").
check("S3.4 runToOps: inserting a caption-less diagram block → block carries no caption key", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpDiagram", attrs: { bpId: null, bpType: "diagram", source: "graph TD\n  A-->B" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "diagram",
  );
  assert.ok(ins, "a diagram block is inserted");
  assert.equal(ins.block.source, "graph TD\n  A-->B");
  assert.ok(!("caption" in ins.block), "a caption-less insert carries no caption key");
  assert.deepEqual(Object.keys(ins.block).sort(), ["id", "source", "type"]);
});

// S3.4-f) REMOVE — deleting a diagram block → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("S3.4 runToOps: removing a diagram block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the diagram

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "g-1" }],
    "exactly one remove-block for the diagram",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.4-f diagram remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.4-g) NON-INTERFERENCE — a diagram block between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the diagram untouched) emits
//   exactly their two patches and NONE for the diagram.
check("S3.4 runToOps: a diagram block between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "g-1", type: "diagram", caption: "Fig", source: "graph TD\n  A-->B" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the diagram");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "g-1").length,
    0,
    "the diagram emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "S3.4-g diagram non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "diagram untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3.4-h) MIXED — a diagram, a code, AND a callout in ONE run all round-trip with
//   ZERO ops untouched (the three attr-atom/content kinds coexist in one canvas doc).
check("S3.4 runToOps: a diagram + code + callout in ONE run all round-trip with ZERO ops", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    { id: "g-1", type: "diagram", caption: "Fig 1.", source: "graph TD\n  A-->B" },
    { id: "k-1", type: "code", lang: "js", value: "const x = 1;" },
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      content: [{ type: "text", value: "note" }],
    },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "outro" }] },
  ];
  const doc = runToTiptap(blocks);

  // All three non-prose kinds project to their native canvas nodes.
  assert.equal(doc.content[1].type, "bpDiagram");
  assert.equal(doc.content[2].type, "bpCode");
  assert.equal(doc.content[3].type, "callout");

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched mixed run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.4-h mixed diagram+code+callout");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "g-1", "k-1", "c-1", "p-2"]);
  assert.deepEqual(folded[1], blocks[1], "diagram untouched");
  assert.deepEqual(folded[2], blocks[2], "code untouched");
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.5 — the 7 NATIVE-CONTROL field-* blocks as canvas CONTROL-ATOM
// nodes (run-convert.js + field-node.js). A native field block in a run is NO LONGER
// opaque: runToTiptap emits a native { type:"bpField", attrs:{bpId,bpType,value,
// fieldName?,label?,options?,rows?} } ATOM node (ONE node `bpField` for all 7 types,
// discriminated by bpType), and runToOps reconstructs a { type:"field-*", value, … }
// block via fieldNodeToBlock. The value is COERCED BY FIELD TYPE exactly like
// BarkparkFieldBlockBridge: field-boolean → a BOOLEAN (control.checked); every other
// native type → a STRING (control.value). field-image / field-reference (pickers)
// STILL project to bpOpaque (boundaries).
//
// The 7 native types, their control, and their value type:
//   field-string  text input        string
//   field-slug    text input        string
//   field-text    textarea          string
//   field-boolean checkbox          BOOLEAN
//   field-select  <select>          string  (options config carried)
//   field-datetime datetime-local   string
//   field-color   color input       string
// ───────────────────────────────────────────────────────────────────────────

// A representative seed per native field type: the value plus carried config
// (label, fieldName, and options for select). The value type matches the stored
// shape (boolean for field-boolean, string for the rest).
const S35_FIELD_SEEDS = {
  "field-string": { id: "f-str", type: "field-string", label: "Title", fieldName: "title", value: "Hello" },
  "field-slug": { id: "f-slug", type: "field-slug", label: "Slug", fieldName: "slug", value: "hello-world" },
  "field-text": { id: "f-txt", type: "field-text", label: "Body", fieldName: "body", rows: 5, value: "Para one\nPara two" },
  "field-boolean": { id: "f-bool", type: "field-boolean", label: "Featured", fieldName: "featured", value: true },
  "field-select": {
    id: "f-sel",
    type: "field-select",
    label: "Status",
    fieldName: "status",
    value: "published",
    options: [
      { value: "draft", label: "Draft" },
      { value: "published", label: "Published" },
    ],
  },
  "field-datetime": { id: "f-dt", type: "field-datetime", label: "Published at", fieldName: "publishedAt", value: "2026-06-24T10:00" },
  "field-color": { id: "f-col", type: "field-color", label: "Accent", fieldName: "accent", value: "#3b82f6" },
};

// The EDITED value per type — a second valid value to drive the value-edit case.
// field-boolean flips true→false (a BOOLEAN); the rest take a new STRING.
const S35_FIELD_EDITS = {
  "field-string": "Goodbye",
  "field-slug": "goodbye-world",
  "field-text": "Rewritten body",
  "field-boolean": false,
  "field-select": "draft",
  "field-datetime": "2026-07-01T09:30",
  "field-color": "#ef4444",
};

// S3.5-a) PROJECTION — EACH of the 7 native field types projects to a native
//   `bpField` ATOM node (NOT bpOpaque): value→attr, fieldName/label/(options)→attr.
//   node.type is the NODE name `bpField`, NOT the bpType. The value type matches the
//   stored shape (boolean for boolean, string otherwise).
for (const type of BP_NATIVE_FIELD_TYPES) {
  check(`S3.5 runToTiptap: a ${type} block → { type:'bpField', attrs:{bpType,value,fieldName} } (NOT bpOpaque)`, () => {
    const seed = S35_FIELD_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    assert.equal(doc.content.length, 3);

    const f = doc.content[1];
    assert.equal(f.type, "bpField", `${type} projects to a native bpField node`);
    assert.notEqual(f.type, "bpOpaque", `${type} is NOT carried opaquely`);
    assert.notEqual(f.type, type, "node name is bpField (not the bpType)");
    assert.equal(f.attrs.bpId, seed.id);
    assert.equal(f.attrs.bpType, type);
    // value rides an attr, with the STORED type (boolean for boolean, else string).
    assert.deepEqual(f.attrs.value, seed.value);
    if (type === "field-boolean") {
      assert.equal(typeof f.attrs.value, "boolean", "boolean value is a BOOLEAN");
    } else {
      assert.equal(typeof f.attrs.value, "string", "non-boolean value is a STRING");
    }
    // fieldName carried verbatim (binds to an Expectation field).
    assert.equal(f.attrs.fieldName, seed.fieldName);
    // An atom: no content hole, no opaque bpBlock carry.
    assert.ok(!("content" in f), "field atom carries no content");
    assert.ok(!("bpBlock" in f.attrs), "field carries no opaque bpBlock");

    // The flanking prose still projects normally.
    assert.equal(doc.content[0].type, "paragraph");
    assert.equal(doc.content[2].type, "paragraph");
  });
}

// S3.5-b) ROUND-TRIP — EACH native field type, untouched, survives runToOps with
//   ZERO ops (canonical compare, reordered attr keys), and the whole mixed run folds
//   back to the IDENTICAL block list (value + config preserved byte-for-byte).
for (const type of BP_NATIVE_FIELD_TYPES) {
  check(`S3.5 runToOps: an untouched ${type} block round-trips with ZERO ops (config preserved)`, () => {
    const seed = S35_FIELD_SEEDS[type];
    const blocks = [
      { id: "h-1", type: "heading", level: 1, text: "Doc" },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);

    // Simulate the live editor's getJSON attr key order (reordered) — change
    // detection must be key-order-safe.
    const f = doc.content[1];
    const reordered = { value: seed.value, bpType: type, bpId: seed.id };
    if (seed.fieldName != null) reordered.fieldName = seed.fieldName;
    if (seed.label != null) reordered.label = seed.label;
    if (seed.options != null) reordered.options = seed.options;
    if (seed.rows != null) reordered.rows = seed.rows;
    f.attrs = reordered;

    const ops = runToOps(blocks, doc);
    assert.equal(ops.length, 0, `an untouched ${type} run emits ZERO ops`);

    // FOLD GATE: folds back to the identical block list; the field survives with its
    // value + carried config, and the prose is untouched.
    const folded = assertFolds(blocks, doc, ops, `S3.5-b ${type} round-trip`);
    assert.deepEqual(folded.map((b) => b.id), ["h-1", seed.id, "p-1"]);
    assert.deepEqual(folded[1], seed, `${type} folds back byte-identical`);
  });
}

// S3.5-c) VALUE EDIT — editing EACH native field's value → exactly one patch-block
//   carrying the CORRECTLY COERCED value (a boolean for field-boolean; a string for
//   the rest), keyed by id, with no prose perturbation.
for (const type of BP_NATIVE_FIELD_TYPES) {
  check(`S3.5 runToOps: editing a ${type} value → one patch-block with the COERCED value`, () => {
    const seed = S35_FIELD_SEEDS[type];
    const edited = S35_FIELD_EDITS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // The native control wrote the (coerced) new value back to the node's `value`
    // attr — boolean for field-boolean, string for the rest.
    doc.content[1] = {
      ...doc.content[1],
      attrs: { ...doc.content[1].attrs, value: edited },
    };

    const ops = runToOps(blocks, doc);
    const patches = ops.filter((o) => o.op === "patch-block");
    assert.equal(patches.length, 1, "exactly one patch-block, for the field");
    assert.equal(patches[0].id, seed.id);
    // THE CRUX: the patch carries ONLY { value } — exactly the
    // BarkparkFieldBlockBridge shape ({op:"patch-block", id, patch:{value}}).
    assert.deepEqual(Object.keys(patches[0].patch), ["value"], "patch carries ONLY value (bridge shape)");
    assert.deepEqual(patches[0].patch.value, edited, "the COERCED edited value");
    if (type === "field-boolean") {
      assert.equal(typeof patches[0].patch.value, "boolean", "boolean patch value is a BOOLEAN");
    } else {
      assert.equal(typeof patches[0].patch.value, "string", "non-boolean patch value is a STRING");
    }

    // FOLD GATE: the field carries its new value; the prose is untouched.
    const folded = assertFolds(blocks, doc, ops, `S3.5-c ${type} value edit`);
    assert.deepEqual(folded[1].value, edited);
    // The carried config survives the patch (shallow merge re-pins id/type, keeps the
    // rest of the block — patch.ex merge_block).
    assert.equal(folded[1].fieldName, seed.fieldName, "fieldName survives the edit");
    assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
    assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
  });
}

// S3.5-c2) COERCION FIDELITY vs BarkparkFieldBlockBridge — the lifted
//   coerceFieldValue produces the EXACT value the per-block bridge's `send()` does:
//   field-boolean reads control.checked (a BOOLEAN); every other type reads
//   control.value (a STRING). Drive a fake control and assert byte-identity.
check("S3.5 coerceFieldValue matches BarkparkFieldBlockBridge (boolean→checked; else→value)", () => {
  // field-boolean → control.checked (a strict boolean), IGNORING control.value.
  assert.equal(coerceFieldValue("field-boolean", { checked: true, value: "on" }), true);
  assert.equal(coerceFieldValue("field-boolean", { checked: false, value: "on" }), false);
  assert.equal(typeof coerceFieldValue("field-boolean", { checked: true }), "boolean");

  // every other native type → control.value (a string), IGNORING control.checked.
  for (const type of ["field-string", "field-slug", "field-text", "field-select", "field-datetime", "field-color"]) {
    assert.equal(coerceFieldValue(type, { value: "abc", checked: true }), "abc", `${type} reads control.value`);
    assert.equal(typeof coerceFieldValue(type, { value: "abc" }), "string", `${type} value is a STRING`);
  }
});

// S3.5-d) INSERT — a NEW native field block (no bpId) between two surviving prose
//   blocks → an insert-after carrying a { type:"field-*", value, fieldName?, … } block
//   with a client-minted id. The fold lands it between the prose.
check("S3.5 runToOps: inserting a field-string block → insert-after with a {type:'field-string', value, fieldName} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpField",
      attrs: { bpId: null, bpType: "field-string", value: "New value", fieldName: "subtitle", label: "Subtitle" },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-string",
  );
  assert.ok(ins, "a field-string block is inserted");
  assert.equal(ins.block.type, "field-string", "the inserted block carries bpType 'field-string' (not 'bpField')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.value, "New value");
  assert.equal(ins.block.fieldName, "subtitle", "fieldName carried through verbatim");
  assert.equal(ins.block.label, "Subtitle", "label carried through");
  // No separate interior patch for a fresh insert (the value rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted field emits no extra interior patch",
  );

  // FOLD GATE: the field lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.5-d field insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "field-string");
  assert.equal(folded[1].value, "New value");
  assert.equal(folded[2].id, "p-2");
});

// S3.5-d2) INSERT a field-boolean → the inserted block's value is a BOOLEAN (false),
//   not a string — the coercion target rides the insert path too.
check("S3.5 runToOps: inserting a field-boolean block → the inserted value is a BOOLEAN", () => {
  const blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpField", attrs: { bpId: null, bpType: "field-boolean", value: false, fieldName: "flag" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-boolean",
  );
  assert.ok(ins, "a field-boolean block is inserted");
  assert.equal(ins.block.value, false);
  assert.equal(typeof ins.block.value, "boolean", "the inserted boolean value is a BOOLEAN");
  assert.equal(ins.block.fieldName, "flag");
});

// S3.5-e) REMOVE — deleting a native field block → a remove-block keyed by its id;
//   the surrounding prose is untouched. The fold drops it.
check("S3.5 runToOps: removing a field-select block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    S35_FIELD_SEEDS["field-select"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the field

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "f-sel" }],
    "exactly one remove-block for the field",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.5-e field remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.5-f) NON-INTERFERENCE — a field block between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the field untouched) emits
//   exactly their two patches and NONE for the field.
check("S3.5 runToOps: a field between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    S35_FIELD_SEEDS["field-boolean"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the field");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "f-bool").length,
    0,
    "the field emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "S3.5-f field non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "field untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3.5-g) MIXED — a field, a code, a callout, AND a diagram in ONE run all round-trip
//   with ZERO ops untouched (the field control-atom coexists with the other variants).
check("S3.5 runToOps: a field + code + callout + diagram in ONE run all round-trip with ZERO ops", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    S35_FIELD_SEEDS["field-string"],
    { id: "k-1", type: "code", lang: "js", value: "const x = 1;" },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "note" }] },
    { id: "g-1", type: "diagram", caption: "Fig 1.", source: "graph TD\n  A-->B" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "outro" }] },
  ];
  const doc = runToTiptap(blocks);

  // All four non-prose kinds project to their native canvas nodes.
  assert.equal(doc.content[1].type, "bpField");
  assert.equal(doc.content[2].type, "bpCode");
  assert.equal(doc.content[3].type, "callout");
  assert.equal(doc.content[4].type, "bpDiagram");

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched mixed run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.5-g mixed field+code+callout+diagram");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "f-str", "k-1", "c-1", "g-1", "p-2"]);
  assert.deepEqual(folded[1], blocks[1], "field untouched");
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.6 — the sheet + embed blocks as canvas READ-ONLY ATOM nodes
// (run-convert.js + embed-node.js). A sheet/embed in a run is NO LONGER opaque:
// runToTiptap emits a native { type:"bpSheet"|"bpEmbed", attrs:{bpId,bpType,bpBlock} }
// READ-ONLY ATOM carrying the WHOLE block VERBATIM on bpBlock (the bpOpaque
// verbatim-carry, made canvas-eligible), and runToOps reconstructs the carried block
// verbatim. UNLIKE the field control-atom (whose value IS edited → a patch), a
// read-only atom NEVER emits a value/content patch — nothing is edited — but it IS
// canvas-eligible (no split) and DOES participate in structural ops (insert/remove/
// move by bpId). (field-image / field-reference (pickers) now ALSO ride the canvas — as
// control-atoms — per the run-splitter tail; the remaining bpOpaque boundaries are the
// nested-structure fields composite / arrayOf / codelist / localizedText / section.)
//
// The two read-only-atom seeds: a sheet (ref + cached value-grid snapshot) and an
// embed (a note transclusion target). Both ride the whole block verbatim.
// ───────────────────────────────────────────────────────────────────────────

const S36_SHEET = {
  id: "sh-1",
  type: "sheet",
  ref: "production/budget",
  snapshot: {
    rows: [
      ["Item", "Cost"],
      ["Server", "100"],
      ["Domain", "12"],
    ],
    head: ["Item", "Cost"],
  },
};

const S36_EMBED = { id: "em-1", type: "embed", target: "Linked Note" };

// The node NAME (bpSheet / bpEmbed) per bpType — the read-only atom maps a block.type
// to its dedicated NODE, NOT the generic bpOpaque.
const S36_NODE_NAME = { sheet: BP_SHEET_NODE_NAME, embed: BP_EMBED_NODE_NAME };
const S36_SEEDS = { sheet: S36_SHEET, embed: S36_EMBED };

// S3.6-a) PROJECTION — a sheet / embed projects to its dedicated READ-ONLY ATOM node
//   (bpSheet / bpEmbed), NOT the generic bpOpaque, carrying the WHOLE block VERBATIM on
//   bpBlock (deep-equal but NOT a shared ref). The flanking prose still projects
//   normally.
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToTiptap: a ${type} block → the READ-ONLY atom node (NOT bpOpaque), carrying bpBlock VERBATIM`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    assert.equal(doc.content.length, 3);

    const n = doc.content[1];
    // THE CRUX: it is the dedicated read-only NODE, NOT the generic bpOpaque.
    assert.equal(n.type, S36_NODE_NAME[type], `${type} projects to its read-only node`);
    assert.notEqual(n.type, "bpOpaque", `${type} is NOT the generic opaque placeholder`);
    assert.notEqual(n.type, type, "node name is the bp-prefixed read-only node, not the bpType");
    assert.equal(n.attrs.bpId, seed.id);
    assert.equal(n.attrs.bpType, type);
    // The WHOLE block rides bpBlock VERBATIM — deep-equal, but NOT a shared ref.
    assert.deepEqual(n.attrs.bpBlock, seed, "the whole block rides bpBlock verbatim");
    assert.notEqual(n.attrs.bpBlock, seed, "but bpBlock is NOT a shared ref (deep-cloned)");
    if (seed.snapshot) {
      assert.notEqual(n.attrs.bpBlock.snapshot, seed.snapshot, "nested snapshot is deep-cloned too (no shared ref)");
    }
    // A read-only atom: no content hole, NO individually-mutable value attr.
    assert.ok(!("content" in n), "read-only atom carries no content");
    assert.ok(!("value" in n.attrs), "read-only atom carries no editable value attr");

    // The flanking prose still projects normally.
    assert.equal(doc.content[0].type, "paragraph");
    assert.equal(doc.content[2].type, "paragraph");
  });
}

// S3.6-a2) READ-ONLY REPRESENTATION — the chip label the node-view renders: the sheet
//   summary "Sheet · <ref> · NxM" (N rows × M cols from the snapshot); the embed
//   reference "↪ <target>". Purely presentational; the block rides verbatim regardless.
check("S3.6 read-only representation: sheet → summary chip 'Sheet · <ref> · NxM'", () => {
  // 3 rows × 2 cols, ref present.
  assert.equal(sheetChipLabel(S36_SHEET), "Sheet · production/budget · 3×2");
  // A ref-less / snapshot-less sheet degrades gracefully (0×0, no ref segment).
  assert.equal(sheetChipLabel({ type: "sheet" }), "Sheet · 0×0");
  assert.equal(sheetChipLabel({ type: "sheet", ref: "g" }), "Sheet · g · 0×0");
});

check("S3.6 read-only representation: embed → reference chip '↪ <target>'", () => {
  assert.equal(embedChipLabel(S36_EMBED), "↪ Linked Note");
  // A blank target renders "↪ (untitled)" (no dangling trailing space).
  assert.equal(embedChipLabel({ type: "embed" }), "↪ (untitled)");
});

// S3.6-b) ROUND-TRIP — an UNTOUCHED sheet / embed survives runToOps with ZERO ops, and
//   the whole mixed run folds back to the IDENTICAL block list — the carried block is
//   deep-equal to the original (the verbatim round-trip).
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: an untouched ${type} round-trips with ZERO ops (verbatim, deep-equal)`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "h-1", type: "heading", level: 1, text: "Doc" },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);

    // Simulate the live editor's getJSON attr key order (reordered) — change detection
    // must be key-order-safe (here: trivially so, since a read-only atom never patches).
    const n = doc.content[1];
    n.attrs = { bpBlock: n.attrs.bpBlock, bpType: type, bpId: seed.id };

    const ops = runToOps(blocks, doc);
    assert.equal(ops.length, 0, `an untouched ${type} run emits ZERO ops`);

    // FOLD GATE: folds back to the identical block list; the read-only block survives
    // VERBATIM (deep-equal), and the prose is untouched.
    const folded = assertFolds(blocks, doc, ops, `S3.6-b ${type} round-trip`);
    assert.deepEqual(folded.map((b) => b.id), ["h-1", seed.id, "p-1"]);
    assert.deepEqual(folded[1], seed, `${type} folds back byte-identical (verbatim)`);
  });
}

// S3.6-c) READ-ONLY NEVER PATCHES — even if some attr on the read-only atom is TOUCHED,
//   runToOps emits ZERO ops for it (it is a reference; nothing is editable). We mutate a
//   non-bp attr on the node and assert no patch lands. (The node-view never writes such
//   an attr; this proves the diff path itself never emits a value/content patch.)
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: a ${type} NEVER emits a value patch even if an attr is touched (read-only)`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] },
      seed,
    ];
    const doc = runToTiptap(blocks);
    // Touch an attr on the read-only node — a read-only atom must still emit NOTHING.
    doc.content[1] = {
      ...doc.content[1],
      attrs: { ...doc.content[1].attrs, somethingTouched: "ignored" },
    };

    const ops = runToOps(blocks, doc);
    assert.equal(
      ops.filter((o) => o.op === "patch-block" && o.id === seed.id).length,
      0,
      `a ${type} never emits a value/content patch (read-only)`,
    );
    assert.equal(ops.length, 0, "no ops at all — the read-only atom is inert to edits");
  });
}

// S3.6-d) INSERT — a NEW sheet / embed (no bpId) between two surviving prose blocks →
//   an insert-after carrying the VERBATIM block (the whole block off bpBlock) with a
//   client-minted id, and NO patch on the read-only atom. The fold lands it between the
//   prose.
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: inserting a ${type} → insert-after carrying the VERBATIM block`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
      { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // Splice a NEW read-only atom (bpId null → minted) between p-1 and p-2, carrying the
    // whole block verbatim on bpBlock (id stripped — it is minted on insert).
    const carried = { ...seed };
    delete carried.id;
    doc.content = [
      doc.content[0], // p-1
      {
        type: S36_NODE_NAME[type],
        attrs: { bpId: null, bpType: type, bpBlock: carried },
      },
      doc.content[1], // p-2
    ];

    const ops = runToOps(blocks, doc);
    const ins = ops.find(
      (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === type,
    );
    assert.ok(ins, `a ${type} block is inserted`);
    assert.equal(ins.block.type, type, `the inserted block carries bpType '${type}' (not the node name)`);
    assert.ok(
      ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
      "the minted id avoids the surviving prev ids",
    );
    // The carried block is VERBATIM (every non-id field of the seed survives).
    for (const k of Object.keys(seed)) {
      if (k === "id") continue;
      assert.deepEqual(ins.block[k], seed[k], `${type} insert carries ${k} verbatim`);
    }
    // No separate interior patch for a read-only insert (it never patches).
    assert.equal(
      ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
      0,
      "an inserted read-only atom emits no interior patch",
    );

    // FOLD GATE: the read-only block lands at slot 1, between the two surviving prose,
    // VERBATIM (minus its now-minted id).
    const folded = assertFolds(blocks, doc, ops, `S3.6-d ${type} insert`);
    assert.equal(folded[0].id, "p-1");
    assert.equal(folded[1].type, type);
    assert.equal(folded[2].id, "p-2");
    // The carried block survived verbatim under the minted id.
    const landed = { ...folded[1] };
    delete landed.id;
    const expected = { ...seed };
    delete expected.id;
    assert.deepEqual(landed, expected, `${type} landed verbatim (sans id)`);
  });
}

// S3.6-e) REMOVE — deleting a sheet / embed → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it. (Backspace on the selected atom
//   maps to this remove-block — the structural delete affordance.)
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: removing a ${type} → remove-block (Backspace deletes the atom)`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    doc.content = [doc.content[0], doc.content[2]]; // Backspace-deletes the read-only atom

    const ops = runToOps(blocks, doc);
    assert.deepEqual(
      ops.filter((o) => o.op === "remove-block"),
      [{ op: "remove-block", id: seed.id }],
      `exactly one remove-block for the ${type}`,
    );
    assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

    const folded = assertFolds(blocks, doc, ops, `S3.6-e ${type} remove`);
    assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
  });
}

// S3.6-f) NON-INTERFERENCE — a sheet / embed between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the read-only atom untouched)
//   emits exactly their two patches and NONE for the read-only atom.
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: a ${type} between edited prose emits only the prose patches (none for the ${type})`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
      seed,
      { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
    ];
    const doc = runToTiptap(blocks);
    doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
    doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

    const ops = runToOps(blocks, doc);
    const patches = ops.filter((o) => o.op === "patch-block");
    assert.equal(patches.length, 2, `exactly the two prose patches, none for the ${type}`);
    assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
    assert.equal(
      ops.filter((o) => o.op === "patch-block" && o.id === seed.id).length,
      0,
      `the ${type} emits no patch`,
    );

    // FOLD GATE: both prose blocks carry their new content; the read-only atom survives
    // untouched at slot 1 (verbatim).
    const folded = assertFolds(blocks, doc, ops, `S3.6-f ${type} non-interference`);
    assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
    assert.deepEqual(folded[1], seed, `${type} survives untouched (verbatim)`);
    assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
  });
}

// S3.6-g) A sheet AND an embed in the SAME run round-trip together with ZERO ops — the
//   run can now span [p, sheet, embed, p] without splitting (completing S3).
check("S3.6 runToOps: [paragraph, sheet, embed, paragraph] round-trips with ZERO ops (one run, no split)", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    S36_SHEET,
    S36_EMBED,
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Both project to their dedicated read-only nodes (NOT bpOpaque).
  assert.equal(doc.content[1].type, BP_SHEET_NODE_NAME);
  assert.equal(doc.content[2].type, BP_EMBED_NODE_NAME);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched [p, sheet, embed, p] run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.6-g sheet+embed one run");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "sh-1", "em-1", "p-2"]);
  assert.deepEqual(folded[1], S36_SHEET, "sheet survives verbatim");
  assert.deepEqual(folded[2], S36_EMBED, "embed survives verbatim");
});

// S3.6-h) STILL-OPAQUE — a NESTED-STRUCTURE field (composite), still a boundary, is
//   STILL carried opaquely (NOT a read-only atom, NOT a control-atom). After S3.6
//   sheet/embed are canvas-eligible, and the run-splitter tail made field-image /
//   field-reference canvas-eligible too — but composite / arrayOf / codelist /
//   localizedText / section stay boundaries (a separate nested-structure increment).
check("S3.6 runToTiptap: a composite field is STILL opaque (sheet/embed + pickers became canvas-eligible, nested-structure fields did not)", () => {
  const nested = { id: "cmp-1", type: "composite", fields: [], value: {} };
  const doc = runToTiptap([nested]);
  assert.equal(doc.content[0].type, "bpOpaque", "composite stays opaque");
  assert.notEqual(doc.content[0].type, BP_SHEET_NODE_NAME);
  assert.notEqual(doc.content[0].type, BP_EMBED_NODE_NAME);
  assert.notEqual(doc.content[0].type, "bpField", "composite is NOT a control-atom");
  assert.deepEqual(doc.content[0].attrs.bpBlock, nested);
});

// ───────────────────────────────────────────────────────────────────────────
// editable-action — the CTA `action` block as a canvas CONTROL-ATOM node
// (run-convert.js). An action in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"bpAction", attrs:{bpId,bpType,href?,label?,priority?} } ATOM node (node NAME
// bpAction, bpType "action"), and runToOps reconstructs a { type:"action", href?,
// label?, priority? } block via actionNodeToBlock. Each payload key is OPTIONAL (null =
// absence sentinel); priority is a TRI-STATE the reader collapses to BINARY, so the
// change-detector normalizes nil≡secondary. UNLIKE the field control-atom (one coerced
// `value`) an action carries THREE editable attrs; the coarse patch threads them when set.
// ───────────────────────────────────────────────────────────────────────────

// action-a) PROJECTION — an action projects to a native bpAction CONTROL-ATOM node
//   (NOT bpOpaque): href/label/priority → attrs. node.type is the NODE name `bpAction`,
//   NOT the bpType `action`.
check("editable-action runToTiptap: an action → { type:'bpAction', attrs:{bpId,bpType,href,label,priority} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "a-1", type: "action", href: "https://x.test", label: "Go", priority: "primary" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const a = doc.content[1];
  assert.equal(a.type, "bpAction", "action projects to a native bpAction node");
  assert.notEqual(a.type, "bpOpaque", "action is NOT carried opaquely");
  assert.notEqual(a.type, "action", "node name is bpAction (not the bpType)");
  assert.equal(a.attrs.bpId, "a-1");
  assert.equal(a.attrs.bpType, "action");
  assert.equal(a.attrs.href, "https://x.test");
  assert.equal(a.attrs.label, "Go");
  assert.equal(a.attrs.priority, "primary");
  // A leaf atom: no content hole, no opaque bpBlock carry.
  assert.ok(!("content" in a), "action atom carries no content");
  assert.ok(!("bpBlock" in a.attrs), "action carries no opaque bpBlock");

  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// action-a2) PROJECTION — a NO-KEYS action ({type:"action"}) projects with NO
//   href/label/priority attrs (byte-fidelity: null is the absence sentinel).
check("editable-action runToTiptap: a no-keys action carries NO href/label/priority attrs", () => {
  const doc = runToTiptap([{ id: "a-1", type: "action" }]);
  const a = doc.content[0];
  assert.equal(a.type, "bpAction");
  assert.equal(a.attrs.bpType, "action");
  assert.ok(!("href" in a.attrs), "absent href is NOT projected");
  assert.ok(!("label" in a.attrs), "absent label is NOT projected");
  assert.ok(!("priority" in a.attrs), "absent priority is NOT projected");
});

// action-b) ROUND-TRIP — an UNTOUCHED action survives runToOps with ZERO ops (canonical
//   compare, reordered attr keys), and folds back to the identical block list.
check("editable-action runToOps: an untouched action round-trips with ZERO ops (reordered keys)", () => {
  const action = { id: "a-1", type: "action", href: "https://x.test", label: "Go", priority: "primary" };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    action,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Simulate the live editor's getJSON attr key order.
  const a = doc.content[1];
  a.attrs = { label: "Go", bpType: "action", href: "https://x.test", bpId: "a-1", priority: "primary" };

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched action run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "action-b round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "a-1", "p-1"]);
  assert.deepEqual(folded[1], action);
});

// action-b2) ROUND-TRIP — a NO-KEYS action ({type:"action"}) round-trips with ZERO ops
//   and folds back to EXACTLY {id,type:"action"} (no stray href:"" / null priority).
check("editable-action runToOps: a no-keys action round-trips to exactly {id,type:'action'} with ZERO ops", () => {
  const action = { id: "a-1", type: "action" };
  const blocks = [action, { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched no-keys action emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "action-b2 no-keys round-trip");
  assert.deepEqual(folded[0], { id: "a-1", type: "action" });
  assert.deepEqual(Object.keys(folded[0]).sort(), ["id", "type"]);
});

// action-c) nil≡SECONDARY — selecting "Secondary" on a never-set-priority action is a
//   ZERO-op (the reader collapses nil≡secondary, so no persisted change).
check("editable-action runToOps: selecting Secondary on a never-set-priority action → ZERO ops (nil≡secondary)", () => {
  const blocks = [
    { id: "a-1", type: "action", href: "https://x.test", label: "Go" },
  ];
  const doc = runToTiptap(blocks);
  // The priority select committed "secondary" onto the node attrs (was absent).
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, priority: "secondary" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "nil→secondary is a no-op (matches the reader collapse)");
});

// action-c2) PRIMARY FLIP — selecting "Primary" on a never-set-priority action → ONE
//   coarse patch-block carrying priority:"primary" (and the unchanged href/label).
check("editable-action runToOps: selecting Primary → one patch-block carrying priority:'primary'", () => {
  const blocks = [
    { id: "a-1", type: "action", href: "https://x.test", label: "Go" },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, priority: "primary" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "a-1");
  assert.equal(ops[0].patch.priority, "primary");
  assert.equal(ops[0].patch.href, "https://x.test", "href carried alongside (coarse)");
  assert.equal(ops[0].patch.label, "Go", "label carried alongside (coarse)");

  const folded = assertFolds(blocks, doc, ops, "action-c2 primary flip");
  assert.equal(folded[0].priority, "primary");
});

// action-d) COARSE RE-EMIT — editing label + href → ONE patch-block carrying the whole
//   attrs (href+label+priority when set), no prose perturbation.
check("editable-action runToOps: editing label + href → one coarse patch-block with both", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "a-1", type: "action", href: "https://old.test", label: "Old", priority: "secondary" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // The label + href inputs wrote new values back to the node attrs.
  doc.content[1] = {
    ...doc.content[1],
    attrs: { ...doc.content[1].attrs, label: "New label", href: "https://new.test" },
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the action");
  assert.equal(patches[0].id, "a-1");
  assert.equal(patches[0].patch.label, "New label");
  assert.equal(patches[0].patch.href, "https://new.test");
  assert.equal(patches[0].patch.priority, "secondary", "priority carried (coarse whole-attrs)");

  const folded = assertFolds(blocks, doc, ops, "action-d coarse re-emit");
  assert.equal(folded[1].label, "New label");
  assert.equal(folded[1].href, "https://new.test");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// action-e) INSERT — a NEW action (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"action", href, label, priority } block with a
//   client-minted id. A no-keys insert carries no payload keys.
check("editable-action runToOps: inserting an action → insert-after with a {type:'action'} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpAction",
      attrs: { bpId: null, bpType: "action", href: "https://cta.test", label: "Buy", priority: "primary" },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "action",
  );
  assert.ok(ins, "an action block is inserted");
  assert.equal(ins.block.type, "action", "the inserted block carries bpType 'action' (not 'bpAction')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.href, "https://cta.test");
  assert.equal(ins.block.label, "Buy");
  assert.equal(ins.block.priority, "primary");
  // No separate interior patch for a fresh insert.
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted action emits no extra interior patch",
  );

  const folded = assertFolds(blocks, doc, ops, "action-e insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "action");
  assert.equal(folded[1].label, "Buy");
  assert.equal(folded[2].id, "p-2");
});

// action-f) REMOVE + NON-INTERFERENCE — deleting an action → a remove-block keyed by its
//   id; editing the flanking prose emits exactly their patches and NONE for the action.
check("editable-action runToOps: removing an action → remove-block; flanking prose edits emit only their patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "a-1", type: "action", href: "https://x.test", label: "Go" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  // Remove the action; edit both prose blocks.
  const doc = runToTiptap(blocks);
  doc.content = [
    { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] },
    { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] },
  ];

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "a-1" }],
    "exactly one remove-block for the action",
  );
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"], "only the prose patches");

  const folded = assertFolds(blocks, doc, ops, "action-f remove + non-interference");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1].content, [{ type: "text", value: "TWO!" }]);
});

// ── S4a) ECHO-DRIVEN BASELINE ───────────────────────────────────────────────
//
// The canvas's applyServerBlocks() uses runToOps as the OWN-ECHO match gate and
// resets this._blocks to the server-confirmed blocks so the NEXT diff is
// INCREMENTAL. These pure tests prove the two invariants the WC method relies on
// (the WC itself needs a DOM Editor, out of scope for the smoke; here we test the
// PURE runToOps math the method is built on).
