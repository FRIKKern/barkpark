// task-e0987185b4de61e3 — two tabs on one paper: A edits the first paragraph and B
// the last at the same moment. The server took B's save first and refused A's on
// the old revision; A's canvas showed "Save paused" (or, with nothing queued yet,
// offered only Use latest, which threw A's paragraph away), so only B's edit lived.
//
// A batch whose id-keyed ops touch nothing the other session changed is now
// resent on the newer revision with no banner, and a peer's echo that leaves the
// local draft untouched raises no conflict. An edit to the SAME field of the SAME
// block is still held and shown (Keep mine / Use latest), and the resend is bounded.
import assert from "node:assert/strict";
import { opsRebaseSafe } from "./canvas/run-convert.js";

// ── opsRebaseSafe: the pure rule ────────────────────────────────────────────────
const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const base = [para("p1", "one"), para("p2", "two"), para("p3", "three")];
const mine = [{ op: "patch-block", id: "p3", patch: { content: [{ type: "text", value: "three!" }] } }];
const theirsOther = [para("p1", "ONE"), para("p2", "two"), para("p3", "three")];
const theirsSame = [para("p1", "one"), para("p2", "two"), para("p3", "THREE")];
const theirsInserted = [para("p1", "one"), para("pX", "new"), para("p2", "two"), para("p3", "three")];

assert.equal(opsRebaseSafe(mine, base, theirsOther), true, "different paragraphs rebase");
assert.equal(opsRebaseSafe(mine, base, theirsSame), false, "the same paragraph's text is a conflict");
assert.equal(opsRebaseSafe(mine, base, theirsInserted), false, "a peer insert in the run changes its shape");
assert.equal(
  opsRebaseSafe([{ op: "insert-after", afterId: "p2", block: para("p4", "four") }], base, theirsOther),
  true,
  "an insert anchored on a block the newer version still holds rebases",
);
assert.equal(
  opsRebaseSafe([{ op: "move-block", id: "p3", afterId: "p1" }], base, theirsOther),
  false,
  "a move is never rebased blind",
);
assert.equal(
  opsRebaseSafe([{ op: "remove-block", id: "p1" }], base, theirsOther),
  false,
  "removing a paragraph the peer just edited is a conflict",
);
