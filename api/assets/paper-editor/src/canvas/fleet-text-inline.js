import { wirePaintedTextInline } from "./painted-text-inline.js";

// Authored text in server-painted fleet and data-viz blocks edits where the
// reader paints it (r2b click-to-edit census, task-bbfdcf4c80b8300d). Same
// contract as notes/cards/stats: the reader markup is decorated, never rebuilt;
// a run is wired only when it paints a stored STRING (a number or a derived
// readout stays panel-edited, so a typed edit never changes a stored type), and
// only when the painted rows line up one-to-one with the stored rows.
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const str = value => typeof value === "string" && value !== "";

// Wrap a run's leading bare text node (a label followed by a badge span) in a
// class-less span so it becomes its own host.
function leadText(el) {
  const text = el?.firstChild;
  if (!text || text.nodeType !== 3 || text.nodeValue.trim() === "") return null;
  const span = document.createElement("span");
  text.replaceWith(span);
  span.appendChild(text);
  return span;
}
// A class-less span around a run's trailing bare text node (after a swatch <i>).
function tailText(el) {
  const text = el?.lastChild;
  if (!text || text.nodeType !== 3 || text.nodeValue.trim() === "") return null;
  const span = document.createElement("span");
  text.replaceWith(span);
  span.appendChild(text);
  return span;
}
const rowsOf = (block, key) => (Array.isArray(block[key]) ? block[key] : []);
// One field per stored string key that has a painted element.
const keyed = (out, el, item, index, key, label) => {
  if (el && object(item) && str(item[key])) out.push({ el, item, index, key, label });
};
// An element of a string array on `owner` (the block or a row).
const arrayField = (out, el, owner, index, key, at, label) => {
  const list = owner?.[key];
  if (!el || !Array.isArray(list) || !str(list[at])) return;
  out.push({
    el, item: owner, index, label,
    read: item => item?.[key]?.[at],
    write: (item, value) => ({ ...item, [key]: item[key].map((v, i) => (i === at ? value : v)) }),
  });
};

const DESCRIBE = {
  pipeline: { collection: "nodes", describe(body, block) {
    const nodes = rowsOf(block, "nodes");
    const cells = [...body.querySelectorAll(".bp-pnode")];
    if (!nodes.length || nodes.length !== cells.length || !nodes.every(object)) return [];
    return nodes.flatMap((node, i) => {
      const cell = cells[i], out = [];
      keyed(out, cell.querySelector(":scope > .bp-pnode__k"), node, i, "kind", "Stage kind");
      keyed(out, cell.querySelector(":scope > .bp-pnode__t"), node, i, "title", "Stage title");
      keyed(out, cell.querySelector(":scope > .bp-pnode__d"), node, i, "detail", "Stage detail");
      keyed(out, cell.querySelector(":scope > .bp-pnode__src"), node, i, "source", "Stage source");
      return out;
    });
  } },
  lineage: { collection: "nodes", describe(body, block) {
    const nodes = rowsOf(block, "nodes");
    const cells = [...body.querySelectorAll(".bp-lineage__node")];
    if (!nodes.length || nodes.length !== cells.length || !nodes.every(object)) return [];
    return nodes.flatMap((node, i) => {
      const cell = cells[i], out = [];
      keyed(out, cell.querySelector(":scope > .bp-lineage__overline"), node, i, "overline", "Entry kicker");
      keyed(out, cell.querySelector(":scope > .bp-lineage__title"), node, i, "title", "Entry title");
      keyed(out, cell.querySelector(":scope > .bp-lineage__body"), node, i, "body", "Entry body");
      const value = cell.querySelector(":scope > .bp-lineage__value");
      if (value) {
        keyed(out, value.querySelector(":scope > .bp-lineage__unit"), node, i, "unit", "Entry unit");
        if (str(node.value)) keyed(out, leadText(value), node, i, "value", "Entry value");
      }
      return out;
    });
  } },
  duel: { collection: "rows", describe(body, block) {
    const rows = rowsOf(block, "rows");
    const out = [];
    const heads = body.querySelectorAll(".bp-duel__table thead th[scope=col]");
    if (heads.length === 2) {
      keyed(out, heads[0], block, null, "legendA", "Legend A");
      keyed(out, heads[1], block, null, "legendB", "Legend B");
    }
    const trs = [...body.querySelectorAll(".bp-duel__table tbody tr.bp-duel__row")];
    if (rows.length !== trs.length || !rows.every(object)) return out;
    rows.forEach((row, i) => {
      const tr = trs[i];
      const label = tr.querySelector(":scope > .bp-duel__label");
      keyed(out, label?.querySelector(":scope > .bp-duel__delta"), row, i, "delta", "Row delta");
      if (str(row.label)) keyed(out, leadText(label), row, i, "label", "Row label");
      const vals = tr.querySelectorAll(":scope > td.bp-duel__val");
      if (vals.length === 2) {
        keyed(out, vals[0], row, i, "valueA", "Value A");
        keyed(out, vals[1], row, i, "valueB", "Value B");
      }
    });
    return out;
  } },
  heatmap: { describe(body, block) {
    const out = [];
    const cols = [...body.querySelectorAll(".bp-heat__grid > .bp-heat__cl")];
    const rows = [...body.querySelectorAll(".bp-heat__grid > .bp-heat__rl")].filter(el => el.textContent !== "");
    if (Array.isArray(block.colLabels) && cols.length === block.colLabels.length)
      cols.forEach((el, i) => arrayField(out, el, block, null, "colLabels", i, "Column label"));
    if (Array.isArray(block.rowLabels) && rows.length === block.rowLabels.length)
      rows.forEach((el, i) => arrayField(out, el, block, null, "rowLabels", i, "Row label"));
    return out;
  } },
  chart: { collection: "series", describe(body, block) {
    const out = [];
    keyed(out, body.querySelector(".bp-chart > .bp-chart__t"), block, null, "caption", "Chart caption");
    const series = rowsOf(block, "series");
    const keys = [...body.querySelectorAll(".bp-chart__legend > .bp-chart__key")];
    if (series.length === keys.length && series.every(object))
      series.forEach((s, i) => { if (str(s.label)) keyed(out, tailText(keys[i]), s, i, "label", "Series label"); });
    return out;
  } },
};
// form and questionnaire share the reader's question markup.
const questions = { collection: "questions", describe(body, block) {
  const qs = rowsOf(block, "questions");
  const sets = [...body.querySelectorAll(".bp-form > fieldset.bp-form-question")];
  if (!qs.length || qs.length !== sets.length || !qs.every(object)) return [];
  return qs.flatMap((q, i) => {
    const set = sets[i], out = [];
    keyed(out, set.querySelector(":scope > legend"), q, i, "prompt", "Question");
    keyed(out, set.querySelector(":scope > .bp-form-note"), q, i, "note", "Question note");
    if (Array.isArray(q.options)) {
      const spans = [...set.querySelectorAll(":scope > .bp-form-opts > .bp-form-opt > span")];
      if (spans.length === q.options.length) spans.forEach((el, at) => arrayField(out, el, q, i, "options", at, "Option"));
    }
    return out;
  });
} };
DESCRIBE.form = questions;
DESCRIBE.questionnaire = questions;

export const isFleetTextType = type => Object.hasOwn(DESCRIBE, type);

export function wireFleetTextInline(body, options, type) {
  const spec = DESCRIBE[type];
  const wired = wirePaintedTextInline(body, { ...options, collection: spec.collection || "items" }, spec.describe);
  // An option's text sits inside its <label>: a click there places the caret and
  // must not also check the painted radio.
  const onClick = event => {
    const host = event.target.closest?.("[role=textbox]");
    if (host && body.contains(host) && host.closest("label")) event.preventDefault();
  };
  body.addEventListener("click", onClick);
  return { ...wired, destroy: () => { body.removeEventListener("click", onClick); wired.destroy(); } };
}
