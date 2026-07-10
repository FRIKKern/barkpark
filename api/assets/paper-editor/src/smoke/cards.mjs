// smoke/cards.mjs — STEP 4 (composition-doctrine FINALE): the card WIDGET projection
// + round-trip + op-strategy gates (loop-epic/split-cards).
//
// The NEW slots-native `card` block projects to an EDITABLE `bpCard` content node
// (an inline body contentDOM + title/tone/media/action chrome attrs) — the callout
// precedent, slots-native. A grid `section` holds N of them. The op strategy mirrors
// the callout: an UNEDITED card emits ZERO ops; a body/tone/title/media/action edit
// emits ONE patch-block carrying the rebuilt {slots} + explicit {tone}; a cleared
// tone/title/media/action REMOVAL lands (whole-slots replace + explicit tone).
//
// distrust-vacuous-green: every zero-ops check ALSO asserts the projected doc carries
// a bpCard node with real body content (a vacuous "" projection would pass 0-ops but
// fail this), and every mutation check asserts EXACTLY ONE op carrying the changed
// field (a vacuously-[] change-detector would fail this).
//
// Pure Node — no editor mounted. run-convert.js references the bpCard TYPE only (never
// the NodeView), so this imports it headless.
import assert from "node:assert/strict";
import { check, assertFolds } from "./harness.mjs";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "../canvas/run-convert.js";
import { canvasDefaultBlock } from "../canvas/slash-insert.js";

// A card WIDGET fixture: tone + title + a one-paragraph body slot.
const CARD = (id = "cw-1") => ({
  id,
  type: "card",
  tone: "info",
  slots: {
    title: [{ type: "heading", text: "Card" }],
    body: [{ type: "paragraph", content: [{ type: "text", value: "body text" }] }],
  },
});

// A tone-less, title-less card (present-only chrome proof): ONLY a body slot.
const BARE_CARD = (id = "cw-b") => ({
  id,
  type: "card",
  slots: { body: [{ type: "paragraph", content: [{ type: "text", value: "x" }] }] },
});

// A grid section holding two cards (the model's real proof).
const SECTION_OF_CARDS = () => ({
  id: "s-1",
  type: "section",
  layout: { mode: "grid", tracks: 2 },
  blocks: [CARD("cw-a"), CARD("cw-b")],
});

// ── PROJECTION ───────────────────────────────────────────────────────────────
check("card runToTiptap: a top-level card → { type:'bpCard', content:[inline…] } (folds INTO a run)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    CARD(),
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3, "the card folds INTO the run (no split)");

  const card = doc.content[1];
  assert.equal(card.type, "bpCard", "the card projects to the bpCard node");
  assert.notEqual(card.type, "bpOpaque", "the card is NOT carried opaquely");
  assert.equal(card.attrs.bpId, "cw-1");
  assert.equal(card.attrs.bpType, "card");
  assert.equal(card.attrs.tone, "info", "tone rides node.attrs");
  assert.equal(card.attrs.title, "Card", "title rides node.attrs");
  assert.ok(card.content && card.content.length, "the body slot projects to inline contentDOM");
});

check("card runToTiptap: tone/title/media/action are PRESENT-ONLY (a bare card gains nothing)", () => {
  const node = runToTiptap([BARE_CARD()]).content[0];
  assert.equal(node.type, "bpCard");
  assert.ok(node.attrs.tone == null, "no tone attr on a tone-less card (must NOT gain 'info')");
  assert.ok(node.attrs.title == null, "no title attr on a title-less card");
  assert.ok(node.attrs.media == null, "no media attr when the slot is absent");
  assert.ok(node.attrs.action == null, "no action attr when the slot is absent");
});

// ── ZERO-OPS (anti-vacuous: the projected doc carries a real bpCard body) ─────
check("card runToOps: an untouched top-level card round-trips with ZERO ops (+ real body)", () => {
  const blocks = [CARD()];
  const doc = runToTiptap(blocks);
  // Anti-vacuous guard: the projected node is a bpCard with non-empty body content.
  assert.equal(doc.content[0].type, "bpCard");
  assert.ok(doc.content[0].content && doc.content[0].content.length, "body inline is non-empty");
  assert.equal(runToOps(blocks, doc).length, 0, "an untouched card emits ZERO ops");
});

check("card runToOps: an untouched grid SECTION-OF-CARDS round-trips with ZERO ops (+ real bpCard children)", () => {
  const blocks = [SECTION_OF_CARDS()];
  const doc = runToTiptap(blocks);
  const sec = doc.content[0];
  assert.equal(sec.type, "bpSection");
  assert.equal(sec.content.length, 2, "two card children");
  assert.equal(sec.content[0].type, "bpCard");
  assert.equal(sec.content[1].type, "bpCard");
  assert.ok(sec.content[0].content && sec.content[0].content.length, "card child body is non-empty");
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched section-of-cards emits ZERO ops");
  const folded = assertFolds(blocks, doc, ops, "section-of-cards round-trip");
  assert.deepEqual(folded[0], SECTION_OF_CARDS(), "the whole grid section survives byte-identical");
});

// ── THE AUTHORING DEFAULT (cd-8: /card + palette insert) ─────────────────────
//
// canvasDefaultBlock("card") is what a slash/palette pick inserts. It must be
// CONSISTENT with cardNodeToBlock's persisted shape ({type:"card",slots:{title,body}},
// present-only chrome) and, once persisted (the canonical reconstruction), round-trip
// at ZERO ops on the next load — or every fresh card would emit a spurious op forever.
check("card default: canvasDefaultBlock('card') projects to bpCard and reconstructs to the cardNodeToBlock shape", () => {
  const def = canvasDefaultBlock("card");
  assert.equal(def.type, "card");
  assert.equal(def.id, null, "id:null — the new-block signal (runToOps mints)");
  // Projection: a real bpCard carrying the default title, NO tone/media/action
  // (present-only chrome — a fresh card must not gain a modifier).
  const node = runToTiptap([def]).content[0];
  assert.equal(node.type, "bpCard", "projects to the bpCard node");
  assert.equal(node.attrs.title, "New card", "default title rides node.attrs");
  assert.ok(node.attrs.tone == null, "no tone attr (present-only)");
  assert.ok(node.attrs.media == null, "no media attr");
  assert.ok(node.attrs.action == null, "no action attr");
  // Reconstruction (what the server persists on insert): the cardNodeToBlock shape —
  // the empty inline run normalizes to content:[] (the callout/paragraph precedent).
  const ops = runToOps([], { type: "doc", content: [node] });
  assert.equal(ops.length, 1, "one append (the insert)");
  const { id, ...persisted } = ops[0].block;
  assert.ok(id != null, "a minted id");
  assert.deepEqual(
    persisted,
    {
      type: "card",
      slots: {
        title: [{ type: "heading", text: "New card" }],
        body: [{ type: "paragraph", content: [] }],
      },
    },
    "the persisted default card is exactly the cardNodeToBlock slots-native shape",
  );
});

check("card default: the PERSISTED default card round-trips at ZERO ops (+ real bpCard)", () => {
  // The canonical persisted form (the fixed point the insert lands): title slot +
  // empty-paragraph body slot, with a server id.
  const persisted = {
    id: "cw-new",
    type: "card",
    slots: {
      title: [{ type: "heading", text: "New card" }],
      body: [{ type: "paragraph", content: [] }],
    },
  };
  const blocks = [persisted];
  const doc = runToTiptap(blocks);
  // Anti-vacuous: the projection is a REAL bpCard carrying the title.
  assert.equal(doc.content[0].type, "bpCard");
  assert.equal(doc.content[0].attrs.title, "New card");
  assert.equal(runToOps(blocks, doc).length, 0, "an untouched fresh card emits ZERO ops");
  assert.deepEqual(docToBlocks(doc), blocks, "and docToBlocks returns it byte-identical");
});

check("card docToBlocks: a card round-trips blocks→node→docToBlocks BYTE-EQUAL", () => {
  const back = docToBlocks(runToTiptap([CARD()]));
  assert.deepEqual(back, [CARD()], "the card round-trips byte-identical (slots preserved)");
  // And a bare card (present-only chrome) round-trips byte-identical too.
  assert.deepEqual(docToBlocks(runToTiptap([BARE_CARD()])), [BARE_CARD()]);
});

// ── NON-VACUOUS MUTATION (each edit → EXACTLY ONE patch carrying the change) ──
check("card runToOps: editing the BODY → ONE patch-block{slots} carrying the new body (title preserved)", () => {
  const blocks = [CARD()];
  const doc = runToTiptap(blocks);
  doc.content[0].content = [{ type: "text", text: "EDITED body" }];
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op (not vacuously [])");
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "cw-1");
  assert.equal(ops[0].patch.slots.body[0].content[0].value, "EDITED body");
  // The whole-slots replace preserves the untouched title.
  assert.equal(ops[0].patch.slots.title[0].text, "Card");
  const folded = assertFolds(blocks, doc, ops, "card body edit");
  assert.equal(folded[0].slots.body[0].content[0].value, "EDITED body");
  assert.equal(folded[0].slots.title[0].text, "Card");
});

check("card runToOps: swapping the TONE → ONE patch-block carrying the new tone", () => {
  const blocks = [CARD()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, tone: "warn" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.tone, "warn", "the new tone persists");
  const folded = assertFolds(blocks, doc, ops, "card tone swap");
  assert.equal(folded[0].tone, "warn");
});

check("card runToOps: editing the TITLE → ONE patch-block{slots} carrying the new title", () => {
  const blocks = [CARD()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, title: "Renamed" };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.slots.title[0].text, "Renamed");
  const folded = assertFolds(blocks, doc, ops, "card title edit");
  assert.equal(folded[0].slots.title[0].text, "Renamed");
});

// ── REMOVALS LAND (whole-slots replace + explicit tone — the callout precedent) ─
check("card runToOps: CLEARING the tone → patch-block emits tone:null EXPLICITLY (removal lands)", () => {
  const blocks = [CARD()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, tone: null };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "clearing the tone emits a patch");
  assert.equal(ops[0].patch.tone, null, "tone:null is EXPLICIT (patch-block can't delete a key)");
  const folded = assertFolds(blocks, doc, ops, "card tone clear");
  assert.equal(folded[0].tone, null, "the tone reverts to no-modifier, not the stale value");
});

check("card runToOps: CLEARING the title → the whole-slots replace DROPS the title slot (removal lands)", () => {
  const blocks = [CARD()];
  const doc = runToTiptap(blocks);
  doc.content[0].attrs = { ...doc.content[0].attrs, title: null };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.ok(!("title" in ops[0].patch.slots), "the rebuilt slots has NO title key (cleared)");
  const folded = assertFolds(blocks, doc, ops, "card title clear");
  assert.ok(folded[0].slots.title == null, "the title slot is gone after the whole-slots replace");
});

// ── FINE-GRAINED: a card INSIDE a grid section → patch-block{childId} (stable seq) ─
check("card runToOps: editing a card child's body in a grid section → ONE patch-block{childId} (not replace-block)", () => {
  const blocks = [SECTION_OF_CARDS()];
  const doc = runToTiptap(blocks);
  // Edit ONLY the first card child's body (child-id sequence unchanged).
  doc.content[0].content[0].content = [{ type: "text", text: "EDITED child" }];
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op");
  assert.equal(ops[0].op, "patch-block", "a fine-grained patch, NOT a coarse replace-block");
  assert.equal(ops[0].id, "cw-a", "keyed by the NESTED card child id");
  assert.ok(!ops.some((o) => o.op === "replace-block"), "no replace-block");
  const folded = assertFolds(blocks, doc, ops, "grid card child edit");
  assert.equal(folded[0].blocks[0].slots.body[0].content[0].value, "EDITED child");
  assert.equal(folded[0].blocks[1].id, "cw-b", "the untouched sibling card survives");
});

// ── INSERT: a NEW card (null id) reconstructs the full slots-native block ─────
check("card runToOps: inserting a NEW card (null id) → insert carrying the rebuilt slots-native block", () => {
  const prev = [{ id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(prev);
  doc.content.push({
    type: "bpCard",
    attrs: { bpId: null, bpType: "card", tone: "danger", title: "Fresh" },
    content: [{ type: "text", text: "new body" }],
  });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(ins, "a new card inserts via the standard insert path");
  assert.equal(ins.block.type, "card");
  assert.equal(ins.block.tone, "danger");
  assert.equal(ins.block.slots.title[0].text, "Fresh");
  assert.equal(ins.block.slots.body[0].content[0].value, "new body");
  const folded = assertFolds(prev, doc, ops, "new card insert");
  assert.equal(folded.length, 2);
  assert.equal(folded[1].type, "card");
});

// ── ECHO (server-confirmed card own-echoes) ──────────────────────────────────
check("card reconcileServerEcho: an untouched card own-echoes (+ no idWrites)", () => {
  const server = [CARD()];
  const liveDoc = runToTiptap(server);
  const { ownEcho, idWrites } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, true, "an unchanged card is its own echo");
  assert.equal(idWrites.length, 0);
});

check("card reconcileServerEcho: an EDITED card does NOT own-echo (external path → re-emit)", () => {
  const server = [CARD()];
  const liveDoc = runToTiptap(server);
  liveDoc.content[0].content = [{ type: "text", text: "changed" }];
  const { ownEcho } = reconcileServerEcho(server, liveDoc.content);
  assert.equal(ownEcho, false, "a body-edited card falls through to the external path");
});
