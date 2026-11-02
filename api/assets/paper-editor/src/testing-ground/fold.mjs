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

const count = (ids, id) => ids.filter((x) => x === id).length;

function refuseDuplicateGrowth(before, after, op) {
  const was = authoredIds(before);
  const now = authoredIds(after);
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
