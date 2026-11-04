// fleet-model.js — pure data contracts for the shared Fleet canvas node.

// ── pdd-t8: the fleet SERVER-PAINTED read-only atom (`bpFleet`) ────────────────
//
// The component-fleet blocks (tasks / task-board / roadmap / cards / pipeline /
// notes / status-legend / form / asciicast / …) ride the canvas as READ-ONLY atoms
// — structurally IDENTICAL to sheet/embed (the WHOLE block rides verbatim on
// bpBlock; ZERO value/content ops; structural-only participation) — but with two
// differences: (1) ALL fleet kinds share the ONE `bpFleet` node (the specific kind
// rides bpType, like bpField multiplexes the field-* kinds), and (2) the node-view
// paints the reader's OWN pushed HTML rather than a client-computed chip.
//
// THE ONE-PRODUCER CONTRACT (rule 3 / D8): the editor NEVER hand-renders a fleet
// block. The node-view emits an EMPTY paint hole (`[data-bp-fleet-body]`, a
// `.bp-paper-surface` sink so the canonical stylesheet styles it identically to
// /papers) carrying the block id; the Studio hook (root.html.heex, `bp:block-html`)
// injects the server-rendered HTML keyed by `data-bp-fleet-id`. Until that HTML
// arrives the hole shows an honest loading CHIP (the block's human label) — never a
// blank strip (mirrors the loading/empty/error honesty of task_block_preview/1).
export const BP_FLEET_NODE_NAME = "bpFleet";

// The human label for the loading chip, derived from the fleet block's kind. A
// terse, capitalized noun ("Task board", "Cards", …) so the pre-paint fallback
// reads as an intentional placeholder, not a broken block. Unknown kinds fall back
// to the raw type so a never-seen fleet kind still shows SOMETHING legible.
const FLEET_KIND_LABELS = {
  // Static reader receivers used to mount as opaque carried blocks. Keep their
  // established placeholder text while the server paint is loading.
  arrayOf: "↪ arrayOf",
  codelist: "↪ codelist",
  composite: "↪ composite",
  localizedText: "↪ localizedText",
  "paper-links": "↪ paper-links",
  "pre-gate-badge": "↪ pre-gate-badge",
  "api-endpoint": "API endpoint",
  "bar-chart": "Bar chart",
  "code-tabs": "Code tabs",
  "criteria-progress": "Criteria progress",
  "gauge-list": "Gauge list",
  route: "Route",
  tasks: "Task list",
  "task-list": "Task list",
  "task-detail": "Task detail",
  "task-board": "Task board",
  roadmap: "Roadmap",
  notes: "Notes",
  cards: "Cards",
  pipeline: "Pipeline",
  "status-legend": "Status legend",
  asciicast: "Terminal cast",
  form: "Form",
  questionnaire: "Questionnaire",
  // pd-ee-dataviz-editors: the 7 data-viz kinds ride the same bpFleet paint.
  stat: "Stat",
  stats: "Stats",
  "stat-grid": "Stat grid",
  heatmap: "Heatmap",
  chart: "Chart",
  duel: "Duel",
  lineage: "Lineage",
};

export function fleetChipLabel(block) {
  const type = (block && block.type) || "";
  return FLEET_KIND_LABELS[type] || (type ? `Block · ${type}` : "Block");
}

// ── pd-ee-fleet-editors: the fleet EDIT ISLAND ────────────────────────────────
//
// A fleet block's AUTHORED content is editable in-canvas via a STRUCTURED ISLAND —
// the SAME contract as the code / task-list islands: a non-PM control tree kept
// invisible to ProseMirror by the node-view's stopEvent/ignoreMutation. The island is
// a SIBLING of the server-paint hole, so the `bp:block-html` hook's innerHTML write
// (into [data-bp-fleet-body]) never touches it. It mutates the carried `bpBlock` (the
// D8 single source): an edit → setNodeMarkup(bpBlock) → run-convert emits ONE
// patch-block{items|nodes|query} → the server REPAINTS the hole. The editor NEVER
// hand-renders fleet markup — the preview stays 100% server-painted (D8 / rule 3).

// Item-array editors: cards/notes/pipeline carry an authored array the author edits.
// Each descriptor names the block's AUTHORITATIVE array key — the exact key the reader
// emitter reads (render/components.ex: cards_html/notes_html read "items"; pipeline_html
// reads "nodes"), so an edit lands on the SAME key the server repaints from. Items are
// objects (card {title,text,tone}; note {label,lead,text}; pipeline node
// {kind,title,detail,files,source}), edited as structured JSON in ONE <textarea> island
// (the code-node textarea pattern): add / remove / reorder / edit are ALL expressed by
// editing text — NO edit-only <button> chrome (rule 6 / __atom_chrome guard).
export const FLEET_ITEM_EDITORS = {
  cards: { arrayKey: "items" },
  notes: { arrayKey: "items" },
  pipeline: { arrayKey: "nodes" },
  // pd-ee-dataviz-editors: stats + its stat-grid alias carry an authored array of
  // stat-cell objects on `items` — the exact key stats_html reads (data_viz.ex).
  stats: { arrayKey: "items" },
  "stat-grid": { arrayKey: "items" },
};

// task-* kinds edit their QUERY (filter label) + optional id ref, not an item array.
const FLEET_QUERY_KINDS = new Set([
  "tasks",
  "task-list",
  "task-detail",
  "task-board",
  "roadmap",
]);

// pd-ee-dataviz-editors: CONFIG-OBJECT island kinds — the authored payload is a
// flat set of top-level keys on the block itself (not one array, not a query).
// Each descriptor enumerates EXACTLY the keys its reader emitter consumes
// (data_viz.ex: stat_html reads value/label/max/denom/spark; heatmap_html reads
// cells/rowLabels/colLabels/mode/marginals/values; chart_html reads series/axes —
// series/axes only in v1, the structured grid/series editors are deferred to
// pd-ee-dataviz-structured-editors). The island edits those keys as ONE JSON
// object; parse writes ONLY the enumerated keys (present → set, absent → delete),
// so id/type/anything-else can never be clobbered from the island.
export const FLEET_CONFIG_EDITORS = {
  stat: { keys: ["value", "label", "max", "denom", "spark", "unit", "body", "source"] },
  heatmap: { keys: ["cells", "rowLabels", "colLabels", "mode", "marginals", "values"] },
  chart: { keys: ["series", "axes"] },
  // jdf-bl-historiene-renderer-reconciliation: the jarl figure family. The
  // SCALAR config (legends + the fallback kilde) edits here; the per-datum
  // ARRAY (duel `rows` / lineage `nodes`) is NOT an enumerated key — it belongs
  // to the STRUCTURED grid below (FLEET_DATUM_EDITORS), so the two editors never
  // write the same key and a stale textarea can never revert a row edit. A key
  // the descriptor does not enumerate is left untouched by fleetEditorParse, so
  // rows/nodes ride every config commit verbatim.
  duel: { keys: ["legendA", "legendB", "sourceDefault"] },
  lineage: { keys: ["sourceDefault"] },
};

// ── the STRUCTURED per-datum editor (duel rows / lineage nodes) ───────────────
//
// The config island above edits a block's SCALARS as JSON. The jarl figure family
// also carries an ARRAY of authored DATA — a duel row, a lineage stop — each with
// its own `source` (the per-datum «kilde» data_viz.ex's figure_refs/3 reads, falling
// back to `sourceDefault`). Hand-editing that array as raw JSON is the thing this
// editor replaces: each datum gets one labelled <input> per field, so add / edit /
// reorder / remove are all done on real controls instead of inside a JSON blob.
//
// NO <button> anywhere (rule 6 / __atom_chrome guard — this file is on
// LEAF_ATOM_FILES). The four operations ride native form controls instead:
//   * EDIT    — type into the field's <input>.
//   * ADD     — one always-present TRAILING BLANK datum; typing into any of its
//               fields appends a new datum (the resting-scaffold pattern).
//   * REMOVE  — clear every field of a datum and it drops out of the array.
//   * REORDER — each datum carries a position <select> (1…N); picking a new
//               position moves it.
//
// Field lists are the reader's own contract, in reader order: data_viz.ex
// duel_row_html/1 reads label/valueA/valueB/delta/unit and lineage_node_html/1
// reads overline/title/value/unit/body — plus `source` on both, read by
// figure_refs/3. A field this editor does not name is never touched.
const FLEET_DATUM_EDITORS = {
  duel: {
    arrayKey: "rows",
    itemNoun: "row",
    fields: [
      { key: "label", label: "Label" },
      { key: "valueA", label: "Value A" },
      { key: "valueB", label: "Value B" },
      { key: "delta", label: "Delta" },
      { key: "unit", label: "Unit" },
      { key: "source", label: "Kilde" },
    ],
  },
  lineage: {
    arrayKey: "nodes",
    itemNoun: "stop",
    fields: [
      { key: "overline", label: "Overline" },
      { key: "title", label: "Title" },
      { key: "value", label: "Value" },
      { key: "unit", label: "Unit" },
      { key: "body", label: "Body" },
      { key: "source", label: "Kilde" },
    ],
  },
};

// The descriptor for a block kind, or null when the kind carries no per-datum array.
export function datumEditorSpec(type) {
  return FLEET_DATUM_EDITORS[type] || null;
}

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

// The CURRENT data of a block's per-datum array: a fresh array of the authored
// objects, or null when this kind has no datum editor OR the array holds something
// the structured grid cannot represent (a string, a nested array, a null). Refusing
// rather than coercing is what keeps the editor LOSSLESS: a payload it cannot show
// faithfully is left to the JSON escape hatch instead of being silently rewritten.
export function datumEditorRows(block) {
  const spec = datumEditorSpec((block && block.type) || "");
  if (!spec) return null;
  const raw = block && block[spec.arrayKey];
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) return null;
  if (!raw.every(isPlainObject)) return null;
  return raw.map((d) => ({ ...d }));
}

// A datum is EMPTY when not one of its own keys holds a non-blank scalar — the
// predicate behind remove-by-clearing. Checks the datum's OWN keys, not just the
// named fields, so a datum carrying only an unnamed key (a `tone`, say) is never
// dropped out from under the author.
function datumIsEmpty(datum) {
  return !Object.keys(datum || {}).some((k) => {
    const v = datum[k];
    if (v === undefined || v === null) return false;
    if (typeof v === "string") return v.trim() !== "";
    return true;
  });
}

function withArray(block, spec, arr) {
  const next = cloneFleetBlock(block) || {};
  next[spec.arrayKey] = arr;
  return next;
}

// Write ONE field of ONE datum. Returns a mutated block clone, or null for "nothing
// to commit" (an unrepresentable array, an out-of-range index, or a blank keystroke
// in the trailing scaffold). Three behaviours in one entry point:
//   index < length     → set the field (a blank value DELETES the key); when that
//                        leaves the datum entirely empty, the datum is REMOVED.
//   index === length   → the trailing blank scaffold: a non-blank value APPENDS a
//                        new datum carrying just that field.
//   anything else      → null.
export function datumEditorSet(block, index, key, value) {
  const spec = datumEditorSpec((block && block.type) || "");
  if (!spec) return null;
  if (!spec.fields.some((f) => f.key === key)) return null;
  const rows = datumEditorRows(block);
  if (rows === null) return null;
  if (!Number.isInteger(index) || index < 0 || index > rows.length) return null;
  const text = typeof value === "string" ? value : value == null ? "" : String(value);
  const blank = text.trim() === "";

  if (index === rows.length) {
    if (blank) return null;
    rows.push({ [key]: text });
    return withArray(block, spec, rows);
  }

  const datum = { ...rows[index] };
  if (blank) delete datum[key];
  else datum[key] = text;
  if (datumIsEmpty(datum)) rows.splice(index, 1);
  else rows[index] = datum;
  return withArray(block, spec, rows);
}

// Move a datum from one position to another. Returns a mutated block clone, or null
// when there is nothing to move (no datum editor, an unrepresentable array, an index
// out of range, or from === to — a no-op must emit no op, D3 byte-stability).
export function datumEditorMove(block, from, to) {
  const spec = datumEditorSpec((block && block.type) || "");
  if (!spec) return null;
  const rows = datumEditorRows(block);
  if (rows === null) return null;
  const n = rows.length;
  if (!Number.isInteger(from) || !Number.isInteger(to)) return null;
  if (from < 0 || from >= n || to < 0 || to >= n || from === to) return null;
  const [moved] = rows.splice(from, 1);
  rows.splice(to, 0, moved);
  return withArray(block, spec, rows);
}

// Is this fleet kind editable in-canvas? (status-legend has no authored data;
// asciicast/form/questionnaire are ref/complex config, left read-only in v1.)
export function fleetKindEditable(type) {
  return (
    !!FLEET_ITEM_EDITORS[type] ||
    !!FLEET_CONFIG_EDITORS[type] ||
    FLEET_QUERY_KINDS.has(type)
  );
}

// A canvas-editor local deep clone (the carried block is plain JSON, so a round-trip
// is exact and dependency-free — keeps embed-node.js importable in pure Node).
function cloneFleetBlock(b) {
  return b == null ? b : JSON.parse(JSON.stringify(b));
}

// ── the island's PURE serialize/parse pair (exported for the pure-Node tests) ──
//
// Serialize the current block → the island textarea's text representation.
// Three shapes, keyed by the block's kind:
//   * item kinds (cards/notes/pipeline/stats/stat-grid) → the authored array,
//     pretty JSON;
//   * config kinds (stat/heatmap/chart) → ONE object holding exactly the
//     descriptor keys PRESENT on the block, pretty JSON (absent keys stay absent —
//     never rendered as null);
//   * query kinds (task-*) → the query object, pretty JSON.
export function fleetEditorText(block) {
  const type = (block && block.type) || "";
  const itemEditor = FLEET_ITEM_EDITORS[type];
  if (itemEditor) {
    const arr = Array.isArray(block[itemEditor.arrayKey])
      ? block[itemEditor.arrayKey]
      : [];
    return JSON.stringify(arr, null, 2);
  }
  const configEditor = FLEET_CONFIG_EDITORS[type];
  if (configEditor) {
    const cfg = {};
    for (const key of configEditor.keys) {
      if (block && block[key] !== undefined) cfg[key] = block[key];
    }
    return JSON.stringify(cfg, null, 2);
  }
  // query kind
  const q =
    block && block.query && typeof block.query === "object" && !Array.isArray(block.query)
      ? block.query
      : {};
  return JSON.stringify(q, null, 2);
}

// Parse the island text → a mutated clone of `initialBlock`, or null when the text
// is not yet valid (a mid-edit JSON) — null means "don't commit, keep the last good
// state". Config kinds write ONLY the descriptor's enumerated keys: a key present
// in the parsed object is set, an enumerated key absent from it is DELETED (so
// removing `"max"` from the JSON really drops the stat's bar mode), and any
// non-enumerated key in the text is ignored — id/type can never be clobbered.
export function fleetEditorParse(initialBlock, text) {
  const type = (initialBlock && initialBlock.type) || "";
  const next = cloneFleetBlock(initialBlock) || { type };
  const itemEditor = FLEET_ITEM_EDITORS[type];
  if (itemEditor) {
    let arr;
    try {
      arr = JSON.parse(text);
    } catch (_) {
      return null;
    }
    if (!Array.isArray(arr)) return null;
    next[itemEditor.arrayKey] = arr;
    return next;
  }
  const configEditor = FLEET_CONFIG_EDITORS[type];
  if (configEditor) {
    let cfg;
    try {
      cfg = text.trim() === "" ? {} : JSON.parse(text);
    } catch (_) {
      return null;
    }
    if (cfg == null || typeof cfg !== "object" || Array.isArray(cfg)) return null;
    for (const key of configEditor.keys) {
      if (cfg[key] !== undefined) next[key] = cfg[key];
      else delete next[key];
    }
    return next;
  }
  // query kind
  let q;
  try {
    q = text.trim() === "" ? {} : JSON.parse(text);
  } catch (_) {
    return null;
  }
  if (q == null || typeof q !== "object" || Array.isArray(q)) return null;
  next.query = Object.keys(q).length ? q : null;
  return next;
}
