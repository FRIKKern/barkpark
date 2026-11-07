import assert from "node:assert/strict";
import test from "node:test";
import { runToOps, runToTiptap } from "./run-convert.js";

const para = (id) => ({ id, type: "paragraph", content: [{ type: "text", value: id }] });

function shuffled(seq, random) {
  const out = seq.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function mulberry(seed) {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test("a block typed next to any order of blocks, as after a collaborator's move, sends no op for an untouched block", () => {
  for (let seed = 1; seed <= 500; seed++) {
    const random = mulberry(seed);
    const ids = shuffled(["a", "b", "c", "d", "e", "f", "g"].slice(0, 2 + Math.floor(random() * 6)), random);
    const blocks = ids.map(para);
    const doc = runToTiptap(blocks);
    const at = Math.floor(random() * (ids.length + 1));
    doc.content.splice(at, 0, { type: "paragraph", attrs: { bpId: null, bpType: null }, content: [{ type: "text", text: "new" }] });
    const ops = runToOps(blocks, doc);
    const inserted = ops.find((o) => o.op === "insert-after" || o.op === "insert-at-end")?.block?.id;
    assert.ok(inserted, `seed ${seed}: no insert in ${JSON.stringify(ops)}`);
    const touched = ops.filter((o) => (o.id ?? o.block?.id) !== inserted);
    assert.deepEqual(touched, [], `seed ${seed}: ${ids} + new at ${at}`);
    const order = ids.slice();
    for (const o of ops) {
      const id = o.id ?? o.block.id;
      if (o.op === "move-block") order.splice(order.indexOf(id), 1);
      const after = o.op === "move-block" ? o.after : o.afterId;
      order.splice(after == null ? (o.op === "move-block" ? 0 : order.length) : order.indexOf(after) + 1, 0, id);
    }
    const expected = ids.slice();
    expected.splice(at, 0, inserted);
    assert.deepEqual(order, expected, `seed ${seed}: the batch does not fold to the doc: ${JSON.stringify(ops)}`);
  }
});
