// smoke/node-views-fields.mjs — S3.5 native-field canvas node-view gates.
//
// Mechanical continuation of node-views.mjs; check bodies and fixtures are preserved.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import { coerceFieldValue, BP_NATIVE_FIELD_TYPES } from "../canvas/field-node.js";

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
//   field-number  number input      NUMBER  (min/max/step/unit config carried)
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
  "field-number": { id: "f-num", type: "field-number", label: "Pages", fieldName: "pages", value: 312, min: 1, max: 999, step: 1, unit: "pp" },
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
  "field-number": 128,
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
    } else if (type === "field-number") {
      assert.equal(typeof f.attrs.value, "number", "number value is a NUMBER");
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
    for (const k of ["min", "max", "step", "unit"]) if (seed[k] != null) reordered[k] = seed[k];
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
    } else if (type === "field-number") {
      assert.equal(typeof patches[0].patch.value, "number", "number patch value is a NUMBER");
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

  // field-number → a NUMBER, or null when empty/unparseable.
  assert.equal(coerceFieldValue("field-number", { value: "4.5" }), 4.5);
  assert.equal(coerceFieldValue("field-number", { value: "" }), null);
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
