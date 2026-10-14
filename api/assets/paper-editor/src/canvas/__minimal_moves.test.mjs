// __minimal_moves.test.mjs — task-d20a8200b28f0d7a. runToOps' move pass emits
// the FEWEST move-block ops: the longest run of blocks already in order stays
// put, and only the others move. Dragging one block anywhere is ONE move-block
// for that block. (A greedy walk used to re-anchor every block the dragged one
// passed: [a, X, b, c] → [a, b, c, X] emitted moves for b and c.)
//
// Every batch is folded here exactly as patch.ex folds move-block (lift the id,
// splice it right after `after`, or at the head when `after` is null), and the
// fold must reproduce the target order.
// Run: node src/canvas/__minimal_moves.test.mjs
import assert from "node:assert/strict";
import { runToOps, runToTiptap } from "./run-convert.js";

let ran = 0;
let failures = 0;
function check(name, fn) {
  ran += 1;
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message.split("\n").slice(0, 4).join(" | ")}`);
  }
}
const EXPECTED = 6;

const para = (id) => ({ id, type: "paragraph", content: [{ type: "text", value: `Block ${id}.` }] });
const byId = (ids) => ids.map(para);
function opsFor(prevIds, nextIds, nextBlocks = byId(nextIds)) {
  return runToOps(byId(prevIds), runToTiptap(nextBlocks));
}
// patch.ex move-block, folded left to right.
function fold(ids, ops) {
  const out = ids.slice();
  for (const op of ops) {
    if (op.op !== "move-block") continue;
    out.splice(out.indexOf(op.id), 1);
    out.splice(op.after == null ? 0 : out.indexOf(op.after) + 1, 0, op.id);
  }
  return out;
}
function lisLength(seq) {
  const tails = [];
  for (const x of seq) {
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (tails[mid] < x) lo = mid + 1; else hi = mid; }
    tails[lo] = x;
  }
  return tails.length;
}

check("dragging one block DOWN is one move-block, for that block", () => {
  const ops = opsFor(["a", "x", "b", "c"], ["a", "b", "c", "x"]);
  assert.deepEqual(ops, [{ op: "move-block", id: "x", after: "c" }]);
});

check("dragging one block UP is one move-block, for that block", () => {
  const ops = opsFor(["a", "b", "x", "c"], ["x", "a", "b", "c"]);
  assert.deepEqual(ops, [{ op: "move-block", id: "x", after: null }]);
});

check("an interior edit with no reorder emits no move", () => {
  const next = byId(["a", "b", "c"]);
  next[1] = { ...next[1], content: [{ type: "text", value: "Edited." }] };
  const ops = opsFor(["a", "b", "c"], ["a", "b", "c"], next);
  assert.deepEqual(ops.filter((o) => o.op === "move-block"), []);
});

check("a full reversal of n blocks is n-1 moves and folds to the target", () => {
  const prev = ["a", "b", "c", "d", "e"];
  const next = prev.slice().reverse();
  const ops = opsFor(prev, next);
  assert.equal(ops.length, prev.length - 1);
  assert.deepEqual(fold(prev, ops), next);
});

check("200 seeded random permutations: exactly n − LIS moves, and every batch folds to the target", () => {
  let seed = 7;
  const rand = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  for (let run = 0; run < 200; run++) {
    const n = 2 + Math.floor(rand() * 9);
    const prev = Array.from({ length: n }, (_, i) => `b${i}`);
    const next = prev.slice();
    for (let i = n - 1; i > 0; i--) { const j = Math.floor(rand() * (i + 1)); [next[i], next[j]] = [next[j], next[i]]; }
    const ops = opsFor(prev, next);
    const want = n - lisLength(next.map((id) => prev.indexOf(id)));
    assert.equal(ops.filter((o) => o.op === "move-block").length, want, `${prev} → ${next}: ${JSON.stringify(ops)}`);
    assert.deepEqual(fold(prev, ops), next, `${prev} → ${next}`);
  }
});

check("a LOCKED block never moves, and the batch still folds to the target", () => {
  const prev = ["a", "lk", "b", "c"];
  const next = ["c", "lk", "b", "a"];
  const nextBlocks = byId(next).map((b) => (b.id === "lk" ? { ...b, locked: true } : b));
  const prevBlocks = byId(prev).map((b) => (b.id === "lk" ? { ...b, locked: true } : b));
  const ops = runToOps(prevBlocks, runToTiptap(nextBlocks));
  assert.deepEqual(ops.filter((o) => o.op === "move-block" && o.id === "lk"), [], JSON.stringify(ops));
  assert.deepEqual(fold(prev, ops), next, JSON.stringify(ops));
});

if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\nminimal moves: all checks passed");
process.exit(0);
