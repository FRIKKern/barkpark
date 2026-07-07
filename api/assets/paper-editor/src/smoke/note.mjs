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
import { check, assertFolds } from "./harness.mjs";
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

check("note byte-align: the FLAT form and its MATERIALIZED slots twin project to the SAME node", () => {
  const flat = runToTiptap([NOTE()]).content[0];
  const mat = runToTiptap([MAT_NOTE()]).content[0];
  assert.deepEqual(mat, flat, "both encodings of the same note project byte-identical (the byte-align claim)");
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
  // The materialized twin round-trips to the FLAT wire form (note persists flat; slots
  // are the additive server-side encoding). Its three strings are preserved.
  assert.deepEqual(docToBlocks(runToTiptap([MAT_NOTE()])), [NOTE()], "the slots twin projects to the flat wire form");
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
