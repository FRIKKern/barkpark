// smoke/node-views-code-diagram.mjs — S3.3 code and S3.4 diagram node-view gates.
//
// Mechanical continuation of node-views.mjs; check bodies and fixtures are preserved.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";

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

// S3.3-h) SERVER-PAINTED — a composite retains its contextual editor on new mounts,
//   with a compatibility receiver when projected. divider (S3), callout (S3.2),
//   code (S3.3), diagram (S3.4),
//   the 7 NATIVE field-* types (S3.5), and the 2 PICKER fields field-image /
//   field-reference (run-splitter tail) are ALL canvas-handled; composite / arrayOf /
//   codelist / localizedText remain contextual boundaries.
check("S3.3 runToTiptap: a composite field uses the server-paint compatibility receiver", () => {
  const field = { id: "f-1", type: "composite", fields: [], value: {} };
  const doc = runToTiptap([field]);
  assert.equal(doc.content[0].type, "bpFleet", "composite uses the server-paint receiver");
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
