// smoke/node-views.mjs — S3 divider and S3.2 callout canvas node-view gates.
//
// VERBATIM extraction from src/__smoke.mjs: each S3.x section's projection /
// round-trip / edit / insert / remove / non-interference / still-opaque checks moved
// unchanged (same names, bodies, assertions), carrying their section-local fixtures
// with the section that uses them. The shared check()/assertFolds run through the
// harness so the aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";

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

// S3-f) SERVER-PAINTED — a NESTED-STRUCTURE field (composite), still a contextual
//       boundary on new mounts, has a compatibility receiver when projected. S3.5 and
//       the run-splitter tail pulled the PICKER fields field-image / field-reference in
//       too; nested-structure fields keep their full contextual editor rather than an
//       inline canvas editor.)
check("S3 runToTiptap: a composite field uses the server-paint compatibility receiver", () => {
  const field = {
    id: "f-1",
    type: "composite",
    fields: [{ name: "x", type: "string", title: "X" }],
    value: { x: "v" },
  };
  const doc = runToTiptap([field]);
  assert.equal(doc.content[0].type, "bpFleet", "composite uses the server-paint receiver");
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
  // A body edit writes ONLY the body: unchanged chrome (tone, and the title /
  // collapsible / collapsed keys this callout never carried) stays out of the patch,
  // so the stored block gains no keys the author never wrote (task-56bafb69a8a1f250).
  // A CHANGED chrome field is still explicit — see the S3.2-d cases below.
  assert.deepEqual(Object.keys(patches[0].patch), ["content"], "a body edit patches only the body");

  // FOLD GATE: the callout carries its new body; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.2-c callout body edit");
  assert.deepEqual(folded[1].content, [{ type: "text", value: "new body!" }]);
  for (const key of ["title", "collapsible", "collapsed"]) {
    assert.equal(key in folded[1], false, `the stored callout gains no ${key} key`);
  }
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
  assert.deepEqual(Object.keys(ops[0].patch), ["collapsed"], "only the changed field rides");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d fold toggle");
  assert.equal(folded[0].collapsed, true);
  assert.equal(folded[0].collapsible, true, "the unchanged stored collapsible survives the merge");
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
