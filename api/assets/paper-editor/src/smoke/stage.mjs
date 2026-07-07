// smoke/stage.mjs — the `stage` WIDGET projection + round-trip + op-strategy gates
// (loop-epic/pipeline-widget).
//
// The stage is the editable per-node twin of ONE legacy `pipeline` node. It projects to
// an EDITABLE `bpStage` CONTROL-ATOM node (five scalar attrs, no contentDOM) — the
// action-node precedent, slots-aware for kind/title/detail. The op strategy mirrors the
// card: an UNEDITED stage emits ZERO ops; a field edit emits ONE patch-block carrying
// the present-or-null field set; a cleared field / unchecked source REMOVAL lands.
//
// distrust-vacuous-green: every zero-ops check ALSO asserts the projected doc carries a
// bpStage node with real attrs, and every mutation check asserts EXACTLY ONE op carrying
// the changed field (a vacuously-[] change-detector would fail this).
//
// Pure Node — no editor mounted. run-convert.js references the bpStage TYPE only (never
// the NodeView), so this imports it headless.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "../canvas/run-convert.js";

// A WIRE-canonical (scalar) stage fixture: kind + title + detail + source flag.
const STAGE = (id = "st-1") => ({
  id,
  type: "stage",
  kind: "source",
  title: "emit",
  detail: "reads the queue",
  source: true,
});

// A minimal stage: ONLY the required title (present-only chrome proof).
const BARE_STAGE = (id = "st-b") => ({ id, type: "stage", title: "gate" });

// A SLOTS-materialized stage carrying the SAME plain text as STAGE's scalars — the
// additive slots encoding. Its text-runs carry a MARK that must be DROPPED on read, so
// the reconstructed scalar stays plain (byte-identity with the escaped-plain reader).
const SLOTS_STAGE = (id = "st-s") => ({
  id,
  type: "stage",
  source: true,
  slots: {
    kind: [{ type: "paragraph", content: [{ type: "text", value: "source" }] }],
    title: [{ type: "paragraph", content: [{ type: "text", value: "emit" }] }],
    detail: [
      {
        type: "paragraph",
        content: [
          { type: "strong", children: [{ type: "text", value: "reads " }] },
          { type: "text", value: "the queue" },
        ],
      },
    ],
  },
});

// A section holding two stages (the pipeline-flow model).
const SECTION_OF_STAGES = () => ({
  id: "sec-1",
  type: "section",
  blocks: [STAGE("st-a"), STAGE("st-b")],
});

// ── PROJECTION ───────────────────────────────────────────────────────────────
check("stage runToTiptap: a top-level stage → { type:'bpStage', attrs:{…} } (folds INTO a run)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    STAGE(),
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3, "the stage folds INTO the run (no split)");

  const st = doc.content[1];
  assert.equal(st.type, "bpStage", "the stage projects to the bpStage node");
  assert.notEqual(st.type, "bpOpaque", "the stage is NOT carried opaquely");
  assert.equal(st.attrs.bpId, "st-1");
  assert.equal(st.attrs.bpType, "stage");
  assert.equal(st.attrs.kind, "source");
  assert.equal(st.attrs.title, "emit");
  assert.equal(st.attrs.detail, "reads the queue");
  assert.equal(st.attrs.source, true, "source rides node.attrs");
});

check("stage runToTiptap: every field is PRESENT-ONLY (a bare stage gains nothing but title)", () => {
  const node = runToTiptap([BARE_STAGE()]).content[0];
  assert.equal(node.type, "bpStage");
  assert.equal(node.attrs.title, "gate");
  assert.ok(node.attrs.kind == null, "no kind attr on a kind-less stage");
  assert.ok(node.attrs.detail == null, "no detail attr on a detail-less stage");
  assert.ok(node.attrs.files == null, "no files attr when absent");
  assert.ok(node.attrs.source == null, "no source attr when absent (must NOT gain false)");
});

check("stage runToTiptap: a SLOTS-form stage reads through the slot API + DROPS marks (plain text)", () => {
  const node = runToTiptap([SLOTS_STAGE()]).content[0];
  assert.equal(node.type, "bpStage");
  assert.equal(node.attrs.kind, "source", "kind slot → plain scalar");
  assert.equal(node.attrs.title, "emit", "title slot → plain scalar");
  // The strong mark is FLATTENED away — plain text only (byte-identity with the reader).
  assert.equal(node.attrs.detail, "reads the queue", "detail slot marks DROPPED (plain)");
});

// ── ZERO-OPS (anti-vacuous: the projected doc carries a real bpStage node) ─────
check("stage runToOps: an untouched top-level stage round-trips with ZERO ops (+ real attrs)", () => {
  const blocks = [STAGE()];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content[0].type, "bpStage");
  assert.equal(doc.content[0].attrs.title, "emit", "the projected node carries real attrs");
  assert.equal(runToOps(blocks, doc).length, 0, "an untouched stage emits ZERO ops");
});

check("stage runToOps: a SLOTS-form stage round-trips with ZERO ops (slots read is stable)", () => {
  const blocks = [SLOTS_STAGE()];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content[0].type, "bpStage");
  assert.equal(runToOps(blocks, doc).length, 0, "an untouched slots-form stage emits ZERO ops");
});

check("stage runToOps: an untouched SECTION-OF-STAGES round-trips with ZERO ops (+ real bpStage children)", () => {
  const blocks = [SECTION_OF_STAGES()];
  const doc = runToTiptap(blocks);
  const sec = doc.content[0];
  assert.equal(sec.type, "bpSection");
  assert.equal(sec.content.length, 2, "two stage children");
  assert.equal(sec.content[0].type, "bpStage");
  assert.equal(sec.content[1].type, "bpStage");
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched section-of-stages emits ZERO ops");
  const folded = assertFolds(blocks, doc, ops, "section-of-stages round-trip");
  assert.deepEqual(folded[0], SECTION_OF_STAGES(), "the whole section survives byte-identical");
});

check("stage docToBlocks: a scalar stage round-trips blocks→node→docToBlocks BYTE-EQUAL", () => {
  assert.deepEqual(docToBlocks(runToTiptap([STAGE()])), [STAGE()], "the scalar stage round-trips byte-identical");
  assert.deepEqual(docToBlocks(runToTiptap([BARE_STAGE()])), [BARE_STAGE()], "a bare stage round-trips byte-identical");
});

// ── SOURCE VERBATIM (byte-fidelity of the truthy chrome flag — risk #4) ───────
check("stage docToBlocks: a hand-authored source:'true' (string) round-trips VERBATIM (not coerced to bool)", () => {
  const strSrc = { id: "st-str", type: "stage", title: "x", source: "true" };
  assert.deepEqual(docToBlocks(runToTiptap([strSrc])), [strSrc], "source:'true' string survives byte-identical");
  const oneSrc = { id: "st-one", type: "stage", title: "x", source: 1 };
  assert.deepEqual(docToBlocks(runToTiptap([oneSrc])), [oneSrc], "source:1 survives byte-identical");
  // ... and both still round-trip with ZERO ops (truthy carry does not churn).
  assert.equal(runToOps([strSrc], runToTiptap([strSrc])).length, 0, "source:'true' emits ZERO ops");
});

// ── NON-VACUOUS MUTATION (each edit → EXACTLY ONE patch carrying the change) ──
check("stage runToOps: editing the TITLE → ONE patch-block carrying the new title (others preserved)", () => {
  const blocks = [STAGE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, title: "RENAMED" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op (not vacuously [])");
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "st-1");
  assert.equal(ops[0].patch.title, "RENAMED", "the new title persists");
  assert.equal(ops[0].patch.kind, "source", "the untouched kind rides the patch");
  const folded = assertFolds(blocks, doc, ops, "stage title edit");
  assert.equal(folded[0].title, "RENAMED");
  assert.equal(folded[0].kind, "source");
});

check("stage runToOps: editing the DETAIL → ONE patch-block carrying the new detail", () => {
  const blocks = [STAGE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, detail: "writes the log" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.detail, "writes the log");
  const folded = assertFolds(blocks, doc, ops, "stage detail edit");
  assert.equal(folded[0].detail, "writes the log");
});

check("stage runToOps: toggling SOURCE off → ONE patch-block carrying source:null (accent drops)", () => {
  const blocks = [STAGE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, source: null };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "toggling source emits a patch");
  assert.equal(ops[0].patch.source, null, "source:null is EXPLICIT (patch-block can't delete a key)");
  const folded = assertFolds(blocks, doc, ops, "stage source off");
  assert.ok(!folded[0].source, "the source flag is falsy after the toggle");
});

// ── REMOVALS LAND (present-or-null field set — the card `tone:null` precedent) ─
check("stage runToOps: CLEARING the detail → patch emits detail:null EXPLICITLY (removal lands)", () => {
  const blocks = [STAGE()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, detail: null };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.detail, null, "detail:null is explicit");
  const folded = assertFolds(blocks, doc, ops, "stage detail clear");
  assert.ok(!folded[0].detail, "the detail reverts to empty, not the stale value");
});

// ── FINE-GRAINED: a stage INSIDE a section → patch-block{childId} (stable seq) ─
check("stage runToOps: editing a stage child in a section → ONE patch-block{childId} (not replace-block)", () => {
  const blocks = [SECTION_OF_STAGES()];
  const doc = runToTiptap(blocks);
  doc.content[0].content[0].attrs = { ...doc.content[0].content[0].attrs, title: "EDITED child" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op");
  assert.equal(ops[0].op, "patch-block", "a fine-grained patch, NOT a coarse replace-block");
  assert.equal(ops[0].id, "st-a", "keyed by the NESTED stage child id");
  assert.ok(!ops.some((o) => o.op === "replace-block"), "no replace-block");
  const folded = assertFolds(blocks, doc, ops, "section stage child edit");
  assert.equal(folded[0].blocks[0].title, "EDITED child");
  assert.equal(folded[0].blocks[1].id, "st-b", "the untouched sibling stage survives");
});

// ── INSERT: a NEW stage (null id) reconstructs the WIRE-canonical scalar block ─
check("stage runToOps: inserting a NEW stage (null id) → insert carrying the present-only scalar block", () => {
  const prev = [{ id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(prev);
  doc.content.push({
    type: "bpStage",
    attrs: { bpId: null, bpType: "stage", kind: "gate", title: "Fresh", source: true },
  });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(ins, "a new stage inserts via the standard insert path");
  assert.equal(ins.block.type, "stage");
  assert.equal(ins.block.kind, "gate");
  assert.equal(ins.block.title, "Fresh");
  assert.equal(ins.block.source, true);
  assert.ok(!("detail" in ins.block), "an absent field is NOT reconstructed (present-only)");
  const folded = assertFolds(prev, doc, ops, "new stage insert");
  assert.equal(folded.length, 2);
  assert.equal(folded[1].type, "stage");
});

// ── ECHO (server-confirmed stage own-echoes) ──────────────────────────────────
check("stage reconcileServerEcho: an untouched stage own-echoes (+ no idWrites)", () => {
  const server = [STAGE()];
  const liveDoc = runToTiptap(server);
  const { ownEcho, idWrites } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, true, "an unchanged stage is its own echo");
  assert.equal(idWrites.length, 0);
});

check("stage reconcileServerEcho: an EDITED stage does NOT own-echo (external path → re-emit)", () => {
  const server = [STAGE()];
  const liveDoc = runToTiptap(server);
  liveDoc.content[0].attrs = { ...liveDoc.content[0].attrs, title: "changed" };
  const { ownEcho } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, false, "a title-edited stage falls through to the external path");
});
