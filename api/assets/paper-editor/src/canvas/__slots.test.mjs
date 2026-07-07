// __slots.test.mjs — loop-epic/widget-slots (STEP 3): the callout SLOT-MODEL
// compat guard. Proves that the additive `body` slot encoding
// ({ slots:{ body:[{ type:"paragraph", content:[…] }] } }) and the legacy inline
// encoding ({ content:[…] }) of the SAME body project to the IDENTICAL canvas node
// — so a slot-form callout round-trips byte-for-byte through the run pipeline and a
// legacy callout loaded from disk emits ZERO ops (no phantom dirty / no mass churn).
//
// Pure-Node: imports run-convert.js directly (no browser, no TipTap mount) and
// drives the PUBLIC pipeline (runToTiptap = blockToNode → calloutBlockToNode;
// runToOps = calloutNodeChanged/calloutNodeToPatch), so it exercises the real
// projection + diff path, not a reimplementation.
//
// Run: node src/canvas/__slots.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps } from "./run-convert.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// A shared body: inline runs with a bold mark, to prove the mark survives the slot
// indirection exactly as a paragraph's would.
const BODY = [
  { type: "text", value: "Be " },
  { type: "strong", children: [{ type: "text", value: "careful" }] },
];

// The legacy inline encoding.
const legacy = (extra = {}) => ({
  id: "c-1",
  type: "callout",
  tone: "warning",
  content: BODY,
  ...extra,
});

// The materialized slot encoding of the SAME body (one implicit paragraph).
const slotted = (extra = {}) => ({
  id: "c-1",
  type: "callout",
  tone: "warning",
  slots: { body: [{ type: "paragraph", content: BODY }] },
  ...extra,
});

const wrap = (callout) => [
  { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
  callout,
  { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
];

// ── (a) EQUIVALENCE, not identity — the DISTRUST-VACUOUS-GREEN guard ──────────
// The two source blocks genuinely DIFFER (one has `content`, one has `slots`), yet
// they project to an IDENTICAL callout node. A test that passed on equal inputs
// would prove nothing; asserting `notDeepEqual` first makes the equivalence real.
check("slot-form and legacy-form callout project to the IDENTICAL node (equivalence, not identity)", () => {
  const L = legacy();
  const S = slotted();
  assert.notDeepEqual(L, S, "the two SOURCE encodings must genuinely differ");

  const ln = runToTiptap(wrap(L)).content[1];
  const sn = runToTiptap(wrap(S)).content[1];

  assert.equal(ln.type, "callout");
  assert.equal(sn.type, "callout");
  // Body inline is byte-identical (the load-bearing invariant).
  assert.deepEqual(sn.content, ln.content, "slot-form body must project identically to legacy body");
  assert.deepEqual(ln.content, [
    { type: "text", text: "Be " },
    { type: "text", text: "careful", marks: [{ type: "bold" }] },
  ]);
  // Chrome rides attrs, OUTSIDE the slot, identically for both.
  assert.deepEqual(sn.attrs, ln.attrs, "chrome attrs identical for both encodings");
  assert.equal(ln.attrs.tone, "warning");
});

// ── (b) ZERO-OP-ON-LOAD — a slot-form callout loaded from the server is clean ──
// runToOps projects each server block through the SAME calloutBlockToNode to build
// prevNode, then diffs against the live node. Loading (runToTiptap) then diffing
// must yield ZERO ops for BOTH encodings — otherwise every legacy callout would
// autosave a rewrite (mass byte churn).
check("a loaded slot-form callout emits ZERO ops (no phantom dirty)", () => {
  const blocks = wrap(slotted());
  const doc = runToTiptap(blocks);
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched slot-form callout must emit zero ops");
});

check("a loaded legacy-form callout emits ZERO ops (compat path exercised)", () => {
  const blocks = wrap(legacy());
  const doc = runToTiptap(blocks);
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched legacy callout must emit zero ops");
});

// A callout stored as slot-form on the server, whose live node came from the legacy
// projection of the SAME body, must ALSO be a no-op — because both collapse to the
// same node. This is the cross-encoding zero-op (calloutNodeChanged === false).
check("slot-stored server block vs legacy-derived live node → ZERO ops (cross-encoding)", () => {
  const serverBlocks = wrap(slotted());
  // Live doc built from the LEGACY encoding of the same body.
  const liveDoc = runToTiptap(wrap(legacy()));
  const ops = runToOps(serverBlocks, liveDoc);
  assert.equal(ops.length, 0, "slot vs legacy of the same body must diff EQUAL");
});

// ── (c) FULL ROUND-TRIP — content→node→ops→block preserves body + chrome ──────
// Editing a slot-form callout's body emits exactly ONE patch-block whose patch
// carries the NEW body inline AND the preserved tone/title/collapsed chrome.
check("editing a slot-form callout body → one patch-block preserving tone+title+collapsed", () => {
  const server = wrap(
    slotted({ title: "Heads up", collapsible: true, collapsed: true }),
  );
  const doc = runToTiptap(server);
  // Edit the callout body in the live editor (new inline text).
  doc.content[1].content = [{ type: "text", text: "edited" }];

  const ops = runToOps(server, doc);
  const patches = ops.filter((o) => o.op === "patch-block" && o.id === "c-1");
  assert.equal(patches.length, 1, "exactly one patch-block for the edited callout");

  const p = patches[0].patch;
  assert.deepEqual(p.content, [{ type: "text", value: "edited" }], "new body inline in patch");
  assert.equal(p.tone, "warning", "tone preserved");
  assert.equal(p.title, "Heads up", "title preserved");
  assert.equal(p.collapsible, true, "collapsible preserved");
  assert.equal(p.collapsed, true, "collapsed preserved");
});

// ── (d) EMPTY-BODY FIDELITY — content:[] and an empty slot both omit node.content
check("empty-body callout: slot-form and legacy-form both omit node.content and diff EQUAL", () => {
  const legacyEmpty = { id: "c-1", type: "callout", tone: "info", content: [] };
  const slotEmpty = {
    id: "c-1",
    type: "callout",
    tone: "info",
    slots: { body: [{ type: "paragraph", content: [] }] },
  };
  const ln = runToTiptap(wrap(legacyEmpty)).content[1];
  const sn = runToTiptap(wrap(slotEmpty)).content[1];
  assert.ok(!("content" in ln), "empty legacy body omits node.content (precedent)");
  assert.ok(!("content" in sn), "empty slot body omits node.content (precedent)");
  assert.deepEqual(sn, ln, "empty slot-form and legacy-form project identically");

  // And both load clean.
  assert.equal(runToOps(wrap(slotEmpty), runToTiptap(wrap(slotEmpty))).length, 0);
});

if (failures) {
  console.log(`\n${failures} FAILED`);
  process.exit(1);
}
console.log("\nall slot-model checks passed");
