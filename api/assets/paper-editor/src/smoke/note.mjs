// smoke/note.mjs — the notes-grid split: the singular `note` WIDGET projection +
// round-trip + op-strategy gates (the P2 "fully editable" proof).
//
// The NEW `note` block projects to an EDITABLE `note` CONTENT node — a callout
// SUPERSET: its body is an inline contentDOM, PLUS label + lead ride node.attrs (edited
// via input islands). The op strategy mirrors the callout: an UNEDITED note emits ZERO
// ops; a body/label/lead edit emits ONE patch-block carrying the changed field; a
// cleared lead REMOVAL lands (explicit lead:null, the callout title precedent).
//
// distrust-vacuous-green: every zero-ops check ALSO asserts the projected doc carries a
// real note node with body content; every mutation check asserts EXACTLY ONE op whose
// FOLD moves ONLY the edited field (a vacuously-[] change-detector would fail this).
//
// Pure Node — no editor mounted. run-convert.js references the note TYPE only (a string
// "note"), never the NodeView, so this imports it headless.
import assert from "node:assert/strict";
import { check, assertFolds, applyOps } from "./harness.mjs";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "../canvas/run-convert.js";

// A note WIDGET fixture in the FLAT wire form: label + lead + body `text`.
const NOTE = (id = "nw-1") => ({
  id,
  type: "note",
  label: "alive",
  lead: "Kept",
  text: "the body",
});

// A lead-less note (present-only lead proof): ONLY label + body.
const BARE_NOTE = (id = "nw-b") => ({
  id,
  type: "note",
  label: "solo",
  text: "just a line",
});

// The MATERIALIZED (slots) twin of NOTE — the additive encoding. Must project to a
// byte-IDENTICAL node (both encodings → the same three strings, the byte-align claim).
const MAT_NOTE = (id = "nw-1") => ({
  id,
  type: "note",
  slots: {
    label: [{ type: "paragraph", content: [{ type: "text", value: "alive" }] }],
    lead: [{ type: "paragraph", content: [{ type: "text", value: "Kept" }] }],
    body: [{ type: "paragraph", content: [{ type: "text", value: "the body" }] }],
  },
});

// ── PROJECTION ───────────────────────────────────────────────────────────────
check("note runToTiptap: a top-level note → { type:'note', content:[inline…] } (folds INTO a run)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    NOTE(),
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3, "the note folds INTO the run (no split)");

  const note = doc.content[1];
  assert.equal(note.type, "note", "the note projects to the note content node");
  assert.notEqual(note.type, "bpOpaque", "the note is NOT carried opaquely");
  assert.equal(note.attrs.bpId, "nw-1");
  assert.equal(note.attrs.bpType, "note");
  assert.equal(note.attrs.label, "alive", "label rides node.attrs");
  assert.equal(note.attrs.lead, "Kept", "lead rides node.attrs");
  assert.ok(note.content && note.content.length, "the body projects to inline contentDOM");
});

check("note runToTiptap: lead is PRESENT-ONLY (a lead-less note gains no lead attr)", () => {
  const node = runToTiptap([BARE_NOTE()]).content[0];
  assert.equal(node.type, "note");
  assert.equal(node.attrs.label, "solo");
  assert.ok(node.attrs.lead == null, "no lead attr on a lead-less note (round-trips ABSENT)");
});

check("note byte-align: flat and materialized display the same strings while retaining their carriers", () => {
  const flat = runToTiptap([NOTE()]).content[0];
  const mat = runToTiptap([MAT_NOTE()]).content[0];
  delete flat.attrs.bpBlock;
  delete mat.attrs.bpBlock;
  assert.deepEqual(mat, flat, "visible projections agree; carrier identity is not flattened");
});

// ── ZERO-OPS (anti-vacuous: the projected doc carries a real note body) ────────
check("note runToOps: an untouched top-level note round-trips with ZERO ops (+ real body)", () => {
  const blocks = [NOTE()];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content[0].type, "note");
  assert.ok(doc.content[0].content && doc.content[0].content.length, "body inline is non-empty");
  assert.equal(runToOps(blocks, doc).length, 0, "an untouched note emits ZERO ops");
});

check("note docToBlocks: a note round-trips blocks→node→docToBlocks BYTE-EQUAL (flat wire form)", () => {
  assert.deepEqual(docToBlocks(runToTiptap([NOTE()])), [NOTE()], "the note round-trips byte-identical");
  assert.deepEqual(docToBlocks(runToTiptap([BARE_NOTE()])), [BARE_NOTE()], "a lead-less note round-trips ABSENT lead");
  assert.deepEqual(docToBlocks(runToTiptap([MAT_NOTE()])), [MAT_NOTE()], "materialized shape survives reconstruction");
});

// ── NON-VACUOUS MUTATION (each edit → EXACTLY ONE patch; the fold moves ONLY it) ─
check("note runToOps: editing the BODY → ONE patch-block{text} (label + lead preserved)", () => {
  const blocks = [NOTE()];
  const doc = runToTiptap(blocks);
  doc.content[0].content = [{ type: "text", text: "EDITED body" }];
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op (not vacuously [])");
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "nw-1");
  assert.equal(ops[0].patch.text, "EDITED body", "the new plain body text");
  const folded = assertFolds(blocks, doc, ops, "note body edit");
  assert.deepEqual(folded[0], { ...NOTE(), text: "EDITED body" }, "ONLY text changed");
});

check("note runToOps: editing the LABEL → ONE patch-block{label} (lead + body preserved)", () => {
  const blocks = [NOTE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, label: "renamed" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.label, "renamed");
  const folded = assertFolds(blocks, doc, ops, "note label edit");
  assert.deepEqual(folded[0], { ...NOTE(), label: "renamed" }, "ONLY label changed");
});

check("note runToOps: editing the LEAD → ONE patch-block{lead} (label + body preserved)", () => {
  const blocks = [NOTE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, lead: "New lead" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.lead, "New lead");
  const folded = assertFolds(blocks, doc, ops, "note lead edit");
  assert.deepEqual(folded[0], { ...NOTE(), lead: "New lead" }, "ONLY lead changed");
});

// ── REMOVAL LANDS (explicit lead:null — the callout title precedent) ───────────
check("note runToOps: CLEARING the lead → patch-block emits lead:null EXPLICITLY (removal lands)", () => {
  const blocks = [NOTE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, lead: null };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "clearing the lead emits a patch");
  assert.equal(ops[0].patch.lead, null, "lead:null is EXPLICIT (patch-block can't delete a key)");
  const folded = assertFolds(blocks, doc, ops, "note lead clear");
  assert.equal(folded[0].lead, null, "the lead reverts to none, not the stale value");
});

// ── INSERT: a NEW note (null id) reconstructs the flat wire block ──────────────
check("note runToOps: inserting a NEW note (null id) → insert carrying the rebuilt flat block", () => {
  const prev = [{ id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(prev);
  doc.content.push({
    type: "note",
    attrs: { bpId: null, bpType: "note", label: "Fresh", lead: "Hot" },
    content: [{ type: "text", text: "new note body" }],
  });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(ins, "a new note inserts via the standard insert path");
  assert.equal(ins.block.type, "note");
  assert.equal(ins.block.label, "Fresh");
  assert.equal(ins.block.lead, "Hot");
  assert.equal(ins.block.text, "new note body");
  const folded = assertFolds(prev, doc, ops, "new note insert");
  assert.equal(folded.length, 2);
  assert.equal(folded[1].type, "note");
});

// ── ECHO (server-confirmed note own-echoes) ───────────────────────────────────
check("note reconcileServerEcho: an untouched note own-echoes (+ no idWrites)", () => {
  const server = [NOTE()];
  const liveDoc = runToTiptap(server);
  const { ownEcho, idWrites } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, true, "an unchanged note is its own echo");
  assert.equal(idWrites.length, 0);
});

check("note reconcileServerEcho: an EDITED note does NOT own-echo (external path → re-emit)", () => {
  const server = [NOTE()];
  const liveDoc = runToTiptap(server);
  liveDoc.content[0].attrs = { ...liveDoc.content[0].attrs, label: "changed" };
  const { ownEcho } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, false, "a label-edited note falls through to the external path");
});

// Carrier persistence: compare the COMPLETE folded tree, not only visible strings.
const richPara = (text) => ({
  id: "paragraph-id", type: "paragraph", custom: { keep: [null, 7] },
  content: [{ type: "link", href: "/kept", custom: "wrapper",
    children: [{ type: "code", value: text, custom: { leaf: true } }] }],
});
const carriedNote = () => ({ ...MAT_NOTE(), custom: { root: [1, null] },
  slots: { label: [richPara("alive")], lead: [richPara("Kept")],
    body: [richPara("the body")], unknown: [{ keep: true }] } });
const editNote = (doc, field, value) => {
  if (field === "body") doc.content[0].content = value ? [{ type: "text", text: value }] : [];
  else doc.content[0].attrs[field] = value || null;
};
function assertNoteEdit(before, field, value, expected) {
  const snapshot = structuredClone(before);
  const doc = runToTiptap([before]);
  assert.equal(doc.content[0].type, "note", "accepted carrier has actual controls");
  editNote(doc, field, value);
  const ops = runToOps([before], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  const folded = applyOps([before], ops);
  assert.deepEqual(folded, [expected], "complete persisted tree");
  assert.deepEqual(before, snapshot, "projection/diff did not mutate original");
  const reloaded = runToTiptap(folded);
  const node = reloaded.content[0];
  assert.equal(field === "body" ? (node.content || []).map(n => n.text).join("") : node.attrs[field] || "", value);
  assert.deepEqual(runToOps(folded, reloaded), [], "reload emits no normalization");
  assert.deepEqual(docToBlocks(reloaded), folded, "reconstruction keeps full carrier");
  assert.equal(reconcileServerEcho(folded, doc.content).ownEcho, true);
}

for (const field of ["label", "lead", "body"]) {
  const flat = field === "body" ? "text" : field;
  for (const shadow of [undefined, null, "", 7, "divergent", field === "label" ? "alive" : field === "lead" ? "Kept" : "the body"]) {
    for (const value of ["Meaningful edit", ""]) {
      check(`note materialized ${field}: full tree with shadow ${String(shadow)} → ${JSON.stringify(value)}`, () => {
        const before = carriedNote();
        if (shadow !== undefined) before[flat] = shadow;
        const expected = structuredClone(before);
        expected.slots[field][0].content[0].children[0].value = value;
        if (shadow === (field === "label" ? "alive" : field === "lead" ? "Kept" : "the body")) expected[flat] = value;
        assertNoteEdit(before, field, value, expected);
      });
    }
  }
}

for (const carrier of [{}, { label: null, lead: null, text: null }, { label: "", lead: "", text: "" },
  { label: 7, lead: 8, text: 9 }, { slots: null }, { slots: {} },
  { slots: { label: [], lead: [], body: [] } }]) {
  check(`note no-op and single-field edit preserve missing/null/empty/integer ${JSON.stringify(carrier)}`, () => {
    const before = { id: "shape", type: "note", custom: { keep: true }, ...carrier };
    const doc = runToTiptap([before]);
    assert.deepEqual(runToOps([before], doc), []);
    assert.deepEqual(docToBlocks(doc), [before]);
    assertNoteEdit(before, "label", "Edited", { ...before, label: "Edited" });
  });
}

for (const primary of [{}, { text: null }, { text: "" }, { slots: { body: [richPara("")] }, text: "dormant" }]) {
  check(`note direct content fallback edits and clears without changing primary ${JSON.stringify(primary)}`, () => {
    const before = { id: "content", type: "note", ...primary, content: richPara("Visible fallback").content, extra: true };
    assert.equal(runToTiptap([before]).content[0].content[0].text, "Visible fallback");
    for (const value of ["New content", ""]) {
      const expected = structuredClone(before);
      expected.content[0].children[0].value = value;
      assertNoteEdit(before, "body", value, expected);
    }
  });
}

check("note nested materialized edit uses the same carrier patch", () => {
  const before = [{ id: "section", type: "section", blocks: [carriedNote()] }];
  const doc = runToTiptap(before);
  doc.content[0].content[0].attrs.label = "Nested edit";
  const expected = structuredClone(before);
  expected[0].blocks[0].slots.label[0].content[0].children[0].value = "Nested edit";
  assert.deepEqual(applyOps(before, runToOps(before, doc)), expected);
});

for (const shape of [
  { slots: { body: [{ type: "paragraph", content: [{ type: "text", value: "one" }, { type: "text", value: "two" }] }] } },
  { slots: { label: [{ type: "paragraph", content: [{ type: "image", src: "kept" }] }] } },
  { slots: { body: [richPara("first"), richPara("second")] } },
  { text: "Primary", content: [{ type: "text", value: "Dormant fallback" }] },
  { content: "opaque scalar" },
]) {
  check(`note unsupported carrier is read-only and lossless ${JSON.stringify(shape)}`, () => {
    const before = { ...NOTE(), ...shape, extra: { untouched: true } };
    const doc = runToTiptap([before]);
    assert.equal(doc.content[0].type, "bpOpaque", "no editable control may save flattened or stale data");
    assert.deepEqual(doc.content[0].attrs.bpBlock, before);
    assert.notEqual(doc.content[0].attrs.bpBlock, before);
    assert.deepEqual(runToOps([before], doc), []);
    assert.deepEqual(docToBlocks(doc), [before]);
  });
}

for (const content of [undefined, null, [], "", [""], [{ type: "text", value: null, keep: 9 }]]) {
  check(`note empty terminal keeps paragraph/leaf keys when first authored ${JSON.stringify(content)}`, () => {
    const before = carriedNote();
    const paragraph = { id: "empty", type: "paragraph", extra: { keep: true } };
    if (content !== undefined) paragraph.content = content;
    before.slots.body = [paragraph];
    const doc = runToTiptap([before]);
    assert.equal(doc.content[0].type, "note");
    assert.deepEqual(runToOps([before], doc), []);
    assert.deepEqual(docToBlocks(doc), [before]);
    const expected = structuredClone(before);
    expected.slots.body[0].content = content == null || (Array.isArray(content) && !content.length)
      ? [{ type: "text", value: "First body" }]
      : typeof content === "string" ? "First body"
      : typeof content[0] === "string" ? ["First body"]
      : [{ ...content[0], value: "First body" }];
    assertNoteEdit(before, "body", "First body", expected);
  });
}

check("note multiple changed fields share a full slots map without losing siblings", () => {
  const before = carriedNote();
  const doc = runToTiptap([before]);
  editNote(doc, "label", "Changed label");
  editNote(doc, "lead", "");
  editNote(doc, "body", "Changed body");
  const expected = structuredClone(before);
  expected.slots.label[0].content[0].children[0].value = "Changed label";
  expected.slots.lead[0].content[0].children[0].value = "";
  expected.slots.body[0].content[0].children[0].value = "Changed body";
  const ops = runToOps([before], doc);
  assert.equal(ops.length, 1);
  assert.deepEqual(Object.keys(ops[0].patch), ["slots"]);
  assert.deepEqual(applyOps([before], ops), [expected]);
});

check("note structural section reconstruction retains original note carrier", () => {
  const before = [{ id: "parent", type: "section", blocks: [carriedNote()] }];
  const doc = runToTiptap(before);
  doc.content[0].content.push({ type: "paragraph", attrs: { bpId: null, bpType: "paragraph" }, content: [{ type: "text", text: "New child" }] });
  const folded = applyOps(before, runToOps(before, doc));
  assert.equal(folded[0].blocks.length, 2);
  assert.deepEqual(folded[0].blocks[0], before[0].blocks[0]);
});

check("note empty content fallback can be authored, cleared and reauthored without creating a competing primary", () => {
  let before = { id: "empty-content", type: "note", text: "", content: [{ type: "text", value: "", meta: true }] };
  for (const value of ["First content", "", "Retyped content"]) {
    const expected = structuredClone(before);
    expected.content[0].value = value;
    assertNoteEdit(before, "body", value, expected);
    before = expected;
  }
});
