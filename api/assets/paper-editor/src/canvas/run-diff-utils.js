import { listStart } from "../convert.js";
import { canonicalJSON } from "./projection-json.js";

// A deferred remote edit is not part of the author's visible baseline. Allow
// independent fields (and convergent values), but never silently patch over a
// different remote value or remove a remotely changed block. The host owns review.
export function hasOverlappingOps(ops, baseline, remote) {
  if (!Array.isArray(remote)) return false;
  const beforeById = new Map(baseline.map((block) => [block.id, block]));
  const remoteById = new Map(remote.map((block) => [block.id, block]));
  return ops.some((op) => {
    if (op.op !== "patch-block" && op.op !== "remove-block") return false;
    const before = beforeById.get(op.id);
    const latest = remoteById.get(op.id);
    if (!before || !latest) return false;
    if (op.op === "remove-block") return canonicalJSON(before) !== canonicalJSON(latest);
    if (before.type !== latest.type) return true;
    return Object.entries(op.patch || {}).some(([key, value]) =>
      canonicalJSON(before[key]) !== canonicalJSON(latest[key]) &&
      canonicalJSON(value) !== canonicalJSON(latest[key]));
  });
}

// Whether a batch of id-keyed ops authored against `baseline` can be resent on
// a NEWER stored version `server` of the same run without losing either writer's
// edit (task-e0987185b4de61e3). Two tabs editing different paragraphs of one
// paper must both land. Safe when the other writer left the run's block list as
// it was (no insert, remove or move there), every op is one that addresses a
// block by id that the newer version still holds, and no op touches a field the
// other writer changed. Anything else is held for the author to decide.
export function opsRebaseSafe(ops, baseline, server) {
  if (!Array.isArray(ops) || !ops.length || !Array.isArray(baseline) || !Array.isArray(server)) {
    return false;
  }
  const order = (blocks) => blocks.map((block) => (block && block.id) || "").join("\n");
  if (order(baseline) !== order(server)) return false;
  const known = new Set(server.map((block) => block && block.id));
  for (const op of ops) {
    if (op.op === "insert-after" || op.op === "append-block") {
      if (op.block && op.block.id) known.add(op.block.id);
    }
  }
  const addressable = ops.every((op) => {
    switch (op.op) {
      case "patch-block":
      case "remove-block":
        return known.has(op.id);
      case "insert-after":
        return op.afterId == null || known.has(op.afterId);
      case "append-block":
        return true;
      default:
        return false;
    }
  });
  return addressable && !hasOverlappingOps(ops, baseline, server);
}

// The fewest moves of blocks already here that fold `running` into nextSeq's order,
// or null when the batch would not reproduce it. Stable = the longest increasing
// subsequence of those blocks' running positions in nextSeq order, plus every locked
// id (a locked block never moves). A new block moves unless its insert placed it. Each other id moves right after its nextSeq predecessor, left to
// right: nothing is ever spliced between a moved id and its predecessor, so the
// fold lands exactly on nextSeq. The fold is simulated to prove it.
function minimalMoves(running, nextSeq, lockedIds, prevIndex) {
  const ids = nextSeq.map((e) => e.id);
  if (running.length !== ids.length) return null;
  const pos = new Map(running.map((id, i) => [id, i]));
  if (ids.some((id) => !pos.has(id))) return null;
  // Only blocks that were already here can stay put. A new block sits wherever its
  // insert anchored it, so counting it could make an untouched block the one that moves.
  const kept = ids.filter((id) => prevIndex.has(id));
  const seq = kept.map((id) => pos.get(id));
  // Longest increasing subsequence of `seq` (patience sorting, O(n log n)).
  const tails = [];
  const prev = new Array(seq.length).fill(-1);
  for (let i = 0; i < seq.length; i++) {
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (seq[tails[mid]] < seq[i]) lo = mid + 1;
      else hi = mid;
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    tails[lo] = i;
  }
  const stable = new Set(lockedIds);
  for (let i = tails.length ? tails[tails.length - 1] : -1; i !== -1; i = prev[i]) stable.add(kept[i]);
  const ops = [];
  const order = running.slice();
  for (let i = 0; i < ids.length; i++) {
    const id = ids[i];
    if (stable.has(id)) continue;
    const after = i === 0 ? null : ids[i - 1];
    if (order.indexOf(id) === (after == null ? 0 : order.indexOf(after) + 1)) continue;
    ops.push({ op: "move-block", id, after });
    order.splice(order.indexOf(id), 1);
    order.splice(after == null ? 0 : order.indexOf(after) + 1, 0, id);
  }
  return order.every((id, i) => id === ids[i]) ? ops : null;
}

// Back to left on a block the BASELINE holds centred or flushed right: the node's source
// only carries `align` when the block mounted with one, and a block aligned earlier in this
// session and acknowledged since has a baseline with the key but a source without it - so
// tiptapToBlock drops the key from the patch and the server would keep the old alignment.
// The baseline is the truth the patch merges onto; when it has an alignment the node no
// longer shows, the patch says align:null (the shallow merge then drops it).
function withAlignDrop(patch, node, prevBlock) {
  if (!patch || typeof patch !== "object" || !prevBlock) return patch;
  const prev = prevBlock.align;
  if (prev !== "center" && prev !== "right") return patch;
  const now = node && node.attrs && node.attrs.textAlign;
  if (now === "center" || now === "right") return patch;
  if (Object.hasOwn(patch, "align")) return patch;
  return { ...patch, align: null };
}

// The same for an ordered list's first number: tiptapToBlock carries `start` only
// while the canvas numbers from something other than 1, so an ordered list the
// author set back to 1 would keep the baseline's start on the shallow merge. When the
// baseline has a start and the node is an ordered list that no longer shows one, the
// patch says start:null. A bullet list keeps whatever the baseline holds.
function withListStartDrop(patch, node, prevBlock) {
  if (!patch || typeof patch !== "object" || !prevBlock) return patch;
  if (!node || node.type !== "orderedList" || Object.hasOwn(patch, "start")) return patch;
  if (listStart(prevBlock) === null) return patch;
  return { ...patch, start: null };
}

export { minimalMoves, withAlignDrop, withListStartDrop };
