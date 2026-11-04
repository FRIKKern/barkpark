// smoke/node-views-readonly-action.mjs — S3.6 read-only atoms and editable-action gates.
//
// Mechanical continuation of node-views.mjs; check bodies and fixtures are preserved.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import {
  sheetChipLabel,
  embedChipLabel,
  BP_SHEET_NODE_NAME,
  BP_EMBED_NODE_NAME,
} from "../canvas/embed-node.js";

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

// S3.6-h) SERVER-PAINTED — a NESTED-STRUCTURE field (composite), still a contextual
//   boundary, uses a compatibility receiver (NOT a read-only atom/control-atom). After S3.6
//   sheet/embed are canvas-eligible, and the run-splitter tail made field-image /
//   field-reference canvas-eligible too — but composite / arrayOf / codelist /
//   localizedText stay contextual boundaries.
check("S3.6 runToTiptap: a composite field uses the server-paint compatibility receiver", () => {
  const nested = { id: "cmp-1", type: "composite", fields: [], value: {} };
  const doc = runToTiptap([nested]);
  assert.equal(doc.content[0].type, "bpFleet", "composite uses the server-paint receiver");
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
