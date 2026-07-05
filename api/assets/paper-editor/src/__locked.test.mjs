// __locked.test.mjs — pure-Node unit test for the pdd-t2 doctrine template locks
// in the continuous canvas. Covers the THREE guarantees this slice adds, all in
// plain Node (no DOM / TipTap / ProseMirror):
//
//   1. ROUND-TRIP (both directions): a locked title heading + featured image
//      carry `locked`/`role` through blocks → nodes → blocks, and an UNLOCKED
//      block round-trips WITHOUT any locked/role key (D3 byte-fidelity).
//   2. DIFF GUARD: runToOps never emits remove-block / move-block for a locked id,
//      even when the edited doc drops or reorders it (belt-and-braces over the
//      server backstop + the live filterTransaction veto).
//   3. THE VETO PREDICATE: transactionVetoesLock rejects a tx that deletes or
//      moves a locked node, and passes a content edit / a lock-free doc.
//
// Run: node src/__locked.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import {
  transactionVetoesLock,
  lockedNodeId,
  lockedIndexMap,
} from "./canvas/locks.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.stack || e.message}`);
  }
}

// The forced initial block set (mirrors Content.Papers.Template.template_blocks).
const lockedTitle = {
  id: "tpl-title",
  type: "heading",
  level: 1,
  role: "title",
  locked: true,
  text: "Doctrine",
};
const lockedFeatured = {
  id: "tpl-featured",
  type: "image",
  role: "featured",
  locked: true,
};
const body = {
  id: "tpl-body",
  type: "paragraph",
  content: [{ type: "text", value: "Body." }],
};

// The canvas reconstruction path a live getJSON round-trip drives: the nodes
// runToTiptap emits carry attrs.locked/role (BpAttrs would preserve them across
// setContent->getJSON); docToBlocks classifies + reconstructs each node back to a
// block. So docToBlocks(runToTiptap(blocks)) is the pure analogue of the live
// blocks ⇄ node ⇄ blocks round-trip.
const roundTrip = (blocks) => docToBlocks(runToTiptap(blocks));

// ── 1) round-trip both directions ────────────────────────────────────────────

check("locked title (prose) round-trips locked + role", () => {
  const [out] = roundTrip([lockedTitle]);
  assert.equal(out.id, "tpl-title");
  assert.equal(out.type, "heading");
  assert.equal(out.text, "Doctrine");
  assert.equal(out.level, 1);
  assert.equal(out.locked, true);
  assert.equal(out.role, "title");
});

check("locked featured image (opaque) round-trips locked + role verbatim", () => {
  const [out] = roundTrip([lockedFeatured]);
  assert.deepEqual(out, lockedFeatured);
});

check("stamped node carries locked/role on its attrs (feeds the live veto)", () => {
  const doc = runToTiptap([lockedTitle]);
  const attrs = doc.content[0].attrs;
  assert.equal(attrs.locked, true);
  assert.equal(attrs.role, "title");
  assert.equal(attrs.bpId, "tpl-title");
});

check("UNLOCKED prose block round-trips with NO locked/role key (D3)", () => {
  const plain = { id: "p1", type: "paragraph", content: [{ type: "text", value: "hi" }] };
  const [out] = roundTrip([plain]);
  assert.equal("locked" in out, false, "no `locked` key on an unlocked block");
  assert.equal("role" in out, false, "no `role` key on an unlocked block");
  assert.deepEqual(out.content, plain.content);
});

check("UNLOCKED prose node carries no locked/role attrs (D3 stamp is additive)", () => {
  const plain = { id: "p1", type: "paragraph", content: [{ type: "text", value: "hi" }] };
  const attrs = runToTiptap([plain]).content[0].attrs || {};
  assert.equal("locked" in attrs, false);
  assert.equal("role" in attrs, false);
});

// ── 2) diff guard: never remove/move a locked id ─────────────────────────────

const isRemove = (op, id) => op.op === "remove-block" && op.id === id;
const isMove = (op, id) => op.op === "move-block" && op.id === id;

check("a locked title MISSING from the edited doc emits NO remove-block", () => {
  const prev = [lockedTitle, lockedFeatured, body];
  // The live doc lost the locked title (an anomaly filterTransaction prevents) —
  // the diff must NOT try to remove it (the server would reject + halt the batch).
  const nextDoc = runToTiptap([lockedFeatured, body]);
  const ops = runToOps(prev, nextDoc);
  assert.equal(ops.some((op) => isRemove(op, "tpl-title")), false);
  // And it emits no remove for the OTHER locked block either, obviously present.
  assert.equal(ops.some((op) => isRemove(op, "tpl-featured")), false);
});

check("a locked block REORDERED in the edited doc emits NO move-block", () => {
  const prev = [lockedTitle, lockedFeatured, body];
  // Title dragged to the middle (again, an anomaly the live veto prevents).
  const nextDoc = runToTiptap([lockedFeatured, lockedTitle, body]);
  const ops = runToOps(prev, nextDoc);
  assert.equal(ops.some((op) => isMove(op, "tpl-title")), false);
  assert.equal(ops.some((op) => isMove(op, "tpl-featured")), false);
});

check("the guard is SURGICAL — an unlocked block still removes normally", () => {
  const prev = [lockedTitle, lockedFeatured, body];
  const nextDoc = runToTiptap([lockedTitle, lockedFeatured]); // body deleted
  const ops = runToOps(prev, nextDoc);
  assert.equal(ops.some((op) => isRemove(op, "tpl-body")), true);
});

check("no spurious ops when a locked doc is edited-in-place (title text patched)", () => {
  const prev = [lockedTitle, lockedFeatured, body];
  const editedTitle = { ...lockedTitle, text: "Doctrine v2" };
  const nextDoc = runToTiptap([editedTitle, lockedFeatured, body]);
  const ops = runToOps(prev, nextDoc);
  // Exactly one op: a patch-block on the title's text (locked CONTENT is editable).
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "tpl-title");
  assert.equal(ops[0].patch.text, "Doctrine v2");
  // The patch never carries the immutable template keys.
  assert.equal("locked" in ops[0].patch, false);
  assert.equal("role" in ops[0].patch, false);
});

// ── 3) the veto predicate ─────────────────────────────────────────────────────

// A ProseMirror-shaped doc: forEach((node, offset, index)) over direct children.
const mkDoc = (nodes) => ({
  forEach: (cb) => nodes.forEach((n, i) => cb(n, 0, i)),
});
const node = (bpId, extra = {}) => ({ attrs: { bpId, ...extra } });
const lockedN = (bpId) => node(bpId, { locked: true });
const opaqueLockedN = (bpId) => node(bpId, { bpBlock: { id: bpId, locked: true } });

check("lockedNodeId detects prose/field lock and opaque-image lock", () => {
  assert.equal(lockedNodeId(lockedN("t")), "t");
  assert.equal(lockedNodeId(opaqueLockedN("f")), "f");
  assert.equal(lockedNodeId(node("p")), null);
});

check("lockedIndexMap indexes only locked nodes", () => {
  const doc = mkDoc([lockedN("t"), opaqueLockedN("f"), node("b")]);
  const map = lockedIndexMap(doc);
  assert.equal(map.get("t"), 0);
  assert.equal(map.get("f"), 1);
  assert.equal(map.has("b"), false);
});

check("veto: deleting a locked node is rejected", () => {
  const state = { doc: mkDoc([lockedN("t"), node("b")]) };
  const tr = { docChanged: true, doc: mkDoc([node("b")]) };
  assert.equal(transactionVetoesLock(tr, state), true);
});

check("veto: moving a locked node (index change) is rejected", () => {
  const state = { doc: mkDoc([lockedN("t"), node("b")]) };
  const tr = { docChanged: true, doc: mkDoc([node("b"), lockedN("t")]) };
  assert.equal(transactionVetoesLock(tr, state), true);
});

check("veto: opaque featured-image move is rejected", () => {
  const state = { doc: mkDoc([lockedN("t"), opaqueLockedN("f"), node("b")]) };
  // featured pushed from index 1 to index 2.
  const tr = { docChanged: true, doc: mkDoc([lockedN("t"), node("b"), opaqueLockedN("f")]) };
  assert.equal(transactionVetoesLock(tr, state), true);
});

check("veto PASSES a content edit inside the locked node (title text editable)", () => {
  const state = { doc: mkDoc([lockedN("t"), node("b")]) };
  // Same id, same index — only interior content changed.
  const tr = { docChanged: true, doc: mkDoc([lockedN("t"), node("b")]) };
  assert.equal(transactionVetoesLock(tr, state), false);
});

check("veto PASSES on a doc with NO locked blocks (D3 additive)", () => {
  const state = { doc: mkDoc([node("a"), node("b")]) };
  const tr = { docChanged: true, doc: mkDoc([node("b")]) };
  assert.equal(transactionVetoesLock(tr, state), false);
});

check("veto PASSES a selection-only transaction (no doc change)", () => {
  const state = { doc: mkDoc([lockedN("t"), node("b")]) };
  const tr = { docChanged: false, doc: mkDoc([node("b")]) };
  assert.equal(transactionVetoesLock(tr, state), false);
});

// ── done ──────────────────────────────────────────────────────────────────────
if (failures > 0) {
  console.log(`\n${failures} FAILED`);
  process.exit(1);
}
console.log("\nall locked-doctrine tests passed");
