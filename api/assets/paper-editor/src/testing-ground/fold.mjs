import { applyOps } from "../smoke/reference-fold.mjs";

const isMap = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const listed = (value, walk) => (Array.isArray(value) ? walk(value) : []);
const ownId = (value) => (typeof value.id === "string" && value.id !== "" ? [value.id] : []);
const aliasIds = (container) => ["children", "blocks"].flatMap((key) => listed(container[key], authoredIds));

const nestedIds = {
  section: (block) => listed(block.blocks, authoredIds),
  expandable: aliasIds,
  terminal: aliasIds,
  columns: (block) => listed(block.columns, (columns) => columns.flatMap((column) => listed(column, authoredIds))),
  figure: (block) => (isMap(block.child) ? authoredBlockIds(block.child) : []),
  steps: (block) => listed(block.steps, (rows) => rows.filter(isMap).flatMap((row) => [...ownId(row), ...aliasIds(row)])),
  tabs: (block) => listed(block.tabs, (rows) => rows.filter(isMap).flatMap((row) => [...ownId(row), ...listed(row.blocks, authoredIds)])),
};

function authoredBlockIds(block) {
  if (!isMap(block)) return [];
  return [...ownId(block), ...(Object.hasOwn(nestedIds, block.type) ? nestedIds[block.type](block) : [])];
}

export const authoredIds = (blocks) => blocks.flatMap(authoredBlockIds);

const tally = (blocks) => authoredIds(blocks).reduce((counts, id) => counts.set(id, (counts.get(id) ?? 0) + 1), new Map());
const named = (op) => [op.after, op.afterId, op.id].filter((id) => typeof id === "string");

export const referenceFold = {
  name: "Reference fold (the JS mirror of patch.ex)",
  apply: async (blocks, ops) => {
    const start = tally(blocks);
    const repeated = (counts, id) => counts.get(id) > 1 && counts.get(id) > (start.get(id) ?? 0);
    const adder = new Map();
    let now = blocks;
    let counts = start;
    for (const op of ops) {
      const repeat = named(op).find((id) => repeated(counts, id));
      if (repeat) throw new Error(`${op.op}: duplicate id ${repeat}`);
      now = applyOps(now, [op]);
      const next = tally(now);
      for (const [id, n] of next) if (n > (counts.get(id) ?? 0)) adder.set(id, op.op);
      counts = next;
    }
    const left = [...counts.keys()].find((id) => repeated(counts, id));
    if (left) throw new Error(`${adder.get(left)}: duplicate id ${left}`);
    return now;
  },
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
