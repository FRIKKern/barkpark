import { applyOps } from "../smoke/reference-fold.mjs";

export const referenceFold = {
  name: "Reference fold (the JS mirror of patch.ex)",
  apply: async (blocks, ops) => applyOps(blocks, ops),
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
