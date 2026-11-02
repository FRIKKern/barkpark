import { applyOps } from "../smoke/reference-fold.mjs";
import { idsAtAnyDepth } from "./traps.mjs";

const count = (ids, id) => ids.filter((x) => x === id).length;

function refuseDuplicateGrowth(before, after, op) {
  const was = idsAtAnyDepth(before);
  const now = idsAtAnyDepth(after);
  const grown = now.find((id) => count(now, id) > 1 && count(now, id) > count(was, id));
  if (grown) throw new Error(`${op.op}: duplicate id ${grown}`);
}

export const referenceFold = {
  name: "Reference fold (the JS mirror of patch.ex)",
  apply: async (blocks, ops) => ops.reduce((before, op) => {
    const after = applyOps(before, [op]);
    refuseDuplicateGrowth(before, after, op);
    return after;
  }, blocks),
};

export const serverFold = (name) => ({
  name,
  apply: async (blocks, ops) => {
    const res = await fetch("/fold", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ blocks, ops }) });
    const body = await res.json();
    if (!res.ok) throw new Error(body.error);
    return body.blocks;
  },
});
