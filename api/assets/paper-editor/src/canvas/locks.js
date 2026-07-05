// locks.js — pdd-t2: the PURE doctrine template-lock predicates for the canvas.
//
// A mandated template block (the locked title @0, featured image @1) can never be
// DELETED or MOVED in the canvas — the FELT half of the server backstop
// (patch.ex:192-274). The editor enforces it at the TRANSACTION layer via
// filterTransaction, but the DECISION is pure: given the doc before + after a
// transaction, is a locked node deleted or moved? Splitting that decision into
// this DOM-free, ProseMirror-free module lets it unit-test in plain Node (index.js
// itself calls customElements.define at load and can't be imported DOM-free).
//
// The only structural assumption is a ProseMirror-shaped top-level doc node with a
// `.forEach((node, offset, index) => …)` over its DIRECT children — which both the
// real PM doc and a test fixture satisfy.
//
// Locked-ness rides node attrs: a prose/field node carries attrs.locked (BpAttrs /
// Field declare it, so it survives the setContent->getJSON round-trip); the
// featured image is a bpOpaque node carrying the whole block on attrs.bpBlock, so
// its lock lives at attrs.bpBlock.locked.

// The bpId of a top-level node IFF it is template-locked, else null. A locked node
// with no bpId (never produced by the seed path) yields null — it is not tracked
// here (still protected by the server + the runToOps diff guard).
export function lockedNodeId(node) {
  const a = node && node.attrs;
  if (!a) return null;
  const locked = a.locked === true || (a.bpBlock && a.bpBlock.locked === true);
  if (!locked) return null;
  return a.bpId != null ? a.bpId : null;
}

// Map every locked top-level node's bpId → its index among the doc's children.
export function lockedIndexMap(doc) {
  const map = new Map();
  if (!doc || typeof doc.forEach !== "function") return map;
  doc.forEach((node, _offset, index) => {
    const id = lockedNodeId(node);
    if (id != null) map.set(id, index);
  });
  return map;
}

// Top-level child count of a ProseMirror-shaped doc (real PM docs expose
// `childCount`; a test fixture may only offer `forEach`).
function childCount(doc) {
  if (!doc) return 0;
  if (typeof doc.childCount === "number") return doc.childCount;
  let n = 0;
  if (typeof doc.forEach === "function") doc.forEach(() => n++);
  return n;
}

// True when a transaction would DELETE a locked node (its id vanishes) or MOVE it
// (its index changes). Additive (D3): a doc with NO locked blocks is never vetoed,
// so papers without a template behave byte-identically. A pure content edit keeps
// the locked node's id + index, so it passes. A selection-only tx (no doc change)
// passes immediately.
//
// `lockedTail` (pdd-t2): the run's host tells the veto that the block DIRECTLY
// AFTER this run in the full document is template-locked. This matters because
// the veto is RUN-scoped: in the real Studio layout the locked featured image is
// a non-canvas boundary block, so the locked title sits ALONE in run 0 and this
// veto cannot see the featured block a run-growing edit would displace. When
// lockedTail is set, GROWING the run (Enter at the end of the locked title, a
// multi-paragraph paste) is vetoed too — any new top-level node in this run
// pushes the locked follower down in the full doc, which the server invariant
// (patch.ex check_locked_placement) would reject anyway; vetoing here keeps it a
// calm local no-op instead of a failed save. Shrinking (a merge/delete inside
// the run) never displaces a FOLLOWING block and stays allowed.
export function transactionVetoesLock(tr, state, lockedTail = false) {
  if (!tr || !tr.docChanged) return false;
  const stateDoc = state && state.doc;
  if (lockedTail && childCount(tr.doc) > childCount(stateDoc)) return true;
  const before = lockedIndexMap(stateDoc);
  if (before.size === 0) return false;
  const after = lockedIndexMap(tr.doc);
  for (const [id, idx] of before) {
    const next = after.get(id);
    if (next === undefined) return true; // locked node deleted
    if (next !== idx) return true; // locked node moved
  }
  return false;
}
