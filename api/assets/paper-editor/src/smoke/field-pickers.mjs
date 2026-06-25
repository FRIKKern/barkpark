// smoke/field-pickers.mjs — the TAIL picker-field cases: field-image / field-reference
// (the picker control-atoms) projection / round-trip / value-edit / insert / remove /
// non-interference / mixed-run / dataset-override gates.
//
// VERBATIM extraction from src/__smoke.mjs §TAIL: each check moved unchanged (same
// name, body, assertions), carrying its section-local fixtures (TAIL_PICKER_SEEDS /
// TAIL_PICKER_EDITS) with it. The shared check()/assertFolds run through the harness so
// the aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import { runToTiptap, runToOps } from "../canvas/run-convert.js";
import { coercePickerValue, BP_PICKER_FIELD_TYPES } from "../canvas/field-node.js";

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 RUN-SPLITTER TAIL (part 1) — the 2 PICKER field-* blocks (field-image /
// field-reference) as canvas CONTROL-ATOM nodes mounting the EXISTING client-side
// picker WCs (run-convert.js + field-node.js). A picker field in a run is NO LONGER
// opaque: runToTiptap emits the SAME native { type:"bpField", attrs:{bpId,bpType,value,
// label?,fieldName?,refType?,dataset?} } ATOM node the 7 native types use, and runToOps
// reconstructs a { type:"field-image"|"field-reference", value, … } block via
// fieldNodeToBlock. The value is a STRING (a media id/url for image; a doc id for
// reference) — the picker's bp-change detail.value, lifted IDENTICALLY to the per-block
// BarkparkFieldBlockBridge (push(e.detail.value)). The ONLY mutable datum is `value`;
// the patch is { value }. STILL OUT (nested-structure increment): composite / arrayOf /
// codelist / localizedText / section.
// ───────────────────────────────────────────────────────────────────────────

// A representative seed per picker type: the value (a string) plus carried config.
// field-image carries label; field-reference carries label + refType (its target schema,
// "" by default — present & kept). A dataset override is exercised separately.
const TAIL_PICKER_SEEDS = {
  "field-image": { id: "fi-1", type: "field-image", label: "Hero", fieldName: "hero", value: "https://cdn.example/hero.png" },
  "field-reference": { id: "fr-1", type: "field-reference", label: "Author", fieldName: "author", refType: "author", value: "doc-123" },
};
const TAIL_PICKER_EDITS = {
  "field-image": "https://cdn.example/new-hero.png",
  "field-reference": "doc-456",
};

// TAIL-a) PROJECTION — EACH picker type projects to a native `bpField` ATOM node (NOT
//   bpOpaque): value→attr (a STRING), label/fieldName/(refType)→attr. node.type is the
//   NODE name `bpField`, NOT the bpType, NOT bpOpaque.
for (const type of BP_PICKER_FIELD_TYPES) {
  check(`TAIL runToTiptap: a ${type} block → { type:'bpField', attrs:{bpType,value,...} } (NOT bpOpaque)`, () => {
    const seed = TAIL_PICKER_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    const f = doc.content[1];
    assert.equal(f.type, "bpField", `${type} projects to a native bpField node`);
    assert.notEqual(f.type, "bpOpaque", `${type} is NOT carried opaquely`);
    assert.notEqual(f.type, type, "node name is bpField (not the bpType)");
    assert.equal(f.attrs.bpId, seed.id);
    assert.equal(f.attrs.bpType, type);
    // The picker value rides an attr as a STRING.
    assert.deepEqual(f.attrs.value, seed.value);
    assert.equal(typeof f.attrs.value, "string", "the picker value is a STRING");
    assert.equal(f.attrs.fieldName, seed.fieldName, "fieldName carried verbatim");
    assert.equal(f.attrs.label, seed.label, "label carried verbatim");
    if (type === "field-reference") {
      assert.equal(f.attrs.refType, seed.refType, "field-reference carries its refType config");
    }
    // An atom: no content hole, no opaque bpBlock carry.
    assert.ok(!("content" in f), "picker atom carries no content");
    assert.ok(!("bpBlock" in f.attrs), "picker carries no opaque bpBlock");
    // The flanking prose still projects normally.
    assert.equal(doc.content[0].type, "paragraph");
    assert.equal(doc.content[2].type, "paragraph");
  });
}

// TAIL-b) ROUND-TRIP — EACH picker type, untouched, survives runToOps with ZERO ops
//   (canonical compare, reordered attr keys), and the whole mixed run folds back to the
//   IDENTICAL block list (value + config preserved byte-for-byte, incl. refType).
for (const type of BP_PICKER_FIELD_TYPES) {
  check(`TAIL runToOps: an untouched ${type} block round-trips with ZERO ops (config preserved)`, () => {
    const seed = TAIL_PICKER_SEEDS[type];
    const blocks = [
      { id: "h-1", type: "heading", level: 1, text: "Doc" },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // Simulate the live editor's getJSON attr key order (reordered).
    const reordered = { value: seed.value, bpType: type, bpId: seed.id };
    if (seed.fieldName != null) reordered.fieldName = seed.fieldName;
    if (seed.label != null) reordered.label = seed.label;
    if (seed.refType != null) reordered.refType = seed.refType;
    doc.content[1].attrs = reordered;

    const ops = runToOps(blocks, doc);
    assert.equal(ops.length, 0, `an untouched ${type} run emits ZERO ops`);

    const folded = assertFolds(blocks, doc, ops, `TAIL-b ${type} round-trip`);
    assert.deepEqual(folded.map((b) => b.id), ["h-1", seed.id, "p-1"]);
    assert.deepEqual(folded[1], seed, `${type} folds back byte-identical`);
  });
}

// TAIL-c) VALUE EDIT — editing EACH picker's value (simulating the picker emitting its
//   bp-change → the node-view writing the coerced value to the `value` attr) → exactly
//   ONE patch-block carrying ONLY { value } (the bridge shape), keyed by id, no prose
//   perturbation.
for (const type of BP_PICKER_FIELD_TYPES) {
  check(`TAIL runToOps: editing a ${type} value → one patch-block{value} (bridge shape)`, () => {
    const seed = TAIL_PICKER_SEEDS[type];
    const edited = TAIL_PICKER_EDITS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // The picker's bp-change carried a new value; the node-view wrote it back via the
    // SAME identity coercion the per-block bridge uses (coercePickerValue).
    const nextValue = coercePickerValue({ value: edited });
    doc.content[1] = {
      ...doc.content[1],
      attrs: { ...doc.content[1].attrs, value: nextValue },
    };

    const ops = runToOps(blocks, doc);
    const patches = ops.filter((o) => o.op === "patch-block");
    assert.equal(patches.length, 1, "exactly one patch-block, for the picker field");
    assert.equal(patches[0].id, seed.id);
    // THE CRUX: the patch carries ONLY { value } — exactly the BarkparkFieldBlockBridge
    // picker shape ({op:"patch-block", id, patch:{value}}).
    assert.deepEqual(Object.keys(patches[0].patch), ["value"], "patch carries ONLY value (bridge shape)");
    assert.deepEqual(patches[0].patch.value, edited, "the edited value (identity-coerced)");
    assert.equal(typeof patches[0].patch.value, "string", "picker patch value is a STRING");

    const folded = assertFolds(blocks, doc, ops, `TAIL-c ${type} value edit`);
    assert.equal(folded[1].value, edited);
    // The carried config survives the value patch (shallow merge re-pins id/type).
    assert.equal(folded[1].fieldName, seed.fieldName, "fieldName survives the edit");
    if (type === "field-reference") {
      assert.equal(folded[1].refType, seed.refType, "refType survives the edit");
    }
    assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
    assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
  });
}

// TAIL-c2) PICKER-COERCION FIDELITY vs BarkparkFieldBlockBridge — coercePickerValue
//   produces the EXACT value the per-block bridge's picker branch does: identity on
//   detail.value (a string), with a missing detail/value → "" (the cleared value).
check("TAIL coercePickerValue matches BarkparkFieldBlockBridge picker branch (identity on detail.value)", () => {
  assert.equal(coercePickerValue({ value: "doc-123" }), "doc-123", "identity on a present value");
  assert.equal(coercePickerValue({ value: "https://cdn/x.png" }), "https://cdn/x.png");
  // A clear emits {detail:{value:""}} in the WCs; identity keeps "".
  assert.equal(coercePickerValue({ value: "" }), "", "an empty value stays empty");
  // Defensive: a missing detail or missing value → "" (never undefined into a patch).
  assert.equal(coercePickerValue({}), "", "a missing value coerces to empty string");
  assert.equal(coercePickerValue(null), "", "a missing detail coerces to empty string");
  assert.equal(coercePickerValue(undefined), "", "an undefined detail coerces to empty string");
});

// TAIL-d) INSERT — a NEW picker block (no bpId) between two surviving prose blocks → an
//   insert-after carrying a { type:"field-image"|"field-reference", value, label?, … }
//   block with a client-minted id. The fold lands it between the prose.
check("TAIL runToOps: inserting a field-image block → insert-after with a {type:'field-image', value} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    {
      type: "bpField",
      attrs: { bpId: null, bpType: "field-image", value: "https://cdn.example/x.png", label: "Cover", fieldName: "cover" },
    },
    doc.content[1],
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-image",
  );
  assert.ok(ins, "a field-image block is inserted");
  assert.equal(ins.block.type, "field-image", "the inserted block carries bpType 'field-image' (not 'bpField')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.value, "https://cdn.example/x.png");
  assert.equal(ins.block.fieldName, "cover", "fieldName carried through verbatim");
  assert.equal(ins.block.label, "Cover", "label carried through");
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted picker emits no extra interior patch",
  );

  const folded = assertFolds(blocks, doc, ops, "TAIL-d field-image insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "field-image");
  assert.equal(folded[1].value, "https://cdn.example/x.png");
  assert.equal(folded[2].id, "p-2");
});

// TAIL-d2) INSERT a field-reference → the inserted block carries its refType config.
check("TAIL runToOps: inserting a field-reference block → insert-after with {type, value, refType}", () => {
  const blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpField", attrs: { bpId: null, bpType: "field-reference", value: "doc-9", refType: "author", fieldName: "by" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-reference",
  );
  assert.ok(ins, "a field-reference block is inserted");
  assert.equal(ins.block.value, "doc-9");
  assert.equal(ins.block.refType, "author", "the inserted reference carries its refType");
  assert.equal(ins.block.fieldName, "by");
});

// TAIL-e) REMOVE — deleting a picker block → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("TAIL runToOps: removing a field-reference block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    TAIL_PICKER_SEEDS["field-reference"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the picker

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "fr-1" }],
    "exactly one remove-block for the picker",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "TAIL-e picker remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// TAIL-f) NON-INTERFERENCE — a picker between two prose blocks does not perturb the
//   prose diff: editing BOTH prose blocks (leaving the picker untouched) emits exactly
//   their two patches and NONE for the picker.
check("TAIL runToOps: a picker between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    TAIL_PICKER_SEEDS["field-image"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the picker");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "fi-1").length,
    0,
    "the picker emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "TAIL-f picker non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "picker untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// TAIL-g) MIXED — a picker (image), a reference, a native field, a code, and a callout
//   in ONE run all round-trip with ZERO ops untouched (the picker control-atom coexists
//   with every other variant).
check("TAIL runToOps: field-image + field-reference + native field + code + callout in ONE run → ZERO ops", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    TAIL_PICKER_SEEDS["field-image"],
    TAIL_PICKER_SEEDS["field-reference"],
    { id: "n-1", type: "field-string", label: "Title", fieldName: "title", value: "Hi" },
    { id: "k-1", type: "code", lang: "js", value: "const x = 1;" },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "note" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "outro" }] },
  ];
  const doc = runToTiptap(blocks);

  // The pickers AND the native field project to the SAME bpField node.
  assert.equal(doc.content[1].type, "bpField", "field-image → bpField");
  assert.equal(doc.content[2].type, "bpField", "field-reference → bpField");
  assert.equal(doc.content[3].type, "bpField", "native field → bpField");
  assert.equal(doc.content[4].type, "bpCode");
  assert.equal(doc.content[5].type, "callout");

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched mixed run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "TAIL-g mixed pickers+native+code+callout");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "fi-1", "fr-1", "n-1", "k-1", "c-1", "p-2"]);
  assert.deepEqual(folded[1], blocks[1], "field-image untouched");
  assert.deepEqual(folded[2], blocks[2], "field-reference untouched");
});

// TAIL-h) DATASET OVERRIDE — a picker block that pins a per-block `dataset` round-trips
//   it verbatim (the canvas carries it as config so the picker fetches against the
//   pinned dataset), with ZERO ops untouched and a value edit still emitting only { value }.
check("TAIL runToOps: a field-image with a per-block dataset round-trips the dataset (config), value edit is still {value}", () => {
  const seed = { id: "fi-2", type: "field-image", label: "Pic", value: "u1", dataset: "staging" };
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] },
    seed,
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content[1].attrs.dataset, "staging", "the pinned dataset rides an attr");

  // Untouched → zero ops, dataset preserved.
  assert.equal(runToOps(blocks, doc).length, 0, "untouched → zero ops");
  const folded0 = assertFolds(blocks, doc, runToOps(blocks, doc), "TAIL-h dataset round-trip");
  assert.deepEqual(folded0[1], seed, "dataset round-trips verbatim");

  // A value edit → ONE patch-block{value} (dataset is config, never in the patch).
  doc.content[1] = { ...doc.content[1], attrs: { ...doc.content[1].attrs, value: "u2" } };
  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1);
  assert.deepEqual(Object.keys(patches[0].patch), ["value"], "patch is {value} only — dataset is NOT patched");
  const folded = assertFolds(blocks, doc, ops, "TAIL-h dataset value edit");
  assert.equal(folded[1].value, "u2");
  assert.equal(folded[1].dataset, "staging", "the dataset config survives the value patch");
});
