// __dataviz.test.mjs — pure-Node unit test for pd-ee-dataviz-editors (charter D3):
// the 7 DATA-VIZ kinds (stat / stats / stat-grid / heatmap / chart / duel /
// lineage — reader emitters in render/data_viz.ex) ride the canvas as
// SERVER-PAINTED bpFleet atoms (the whole block VERBATIM on bpBlock, display HTML
// pushed on bp:block-html — ONE producer, D8) with their authored payload edited
// in the bpFleet JSON edit ISLAND:
//   * stat            → config island (value / label / max / denom / spark /
//                       unit / body / source — jarl figure family)
//   * stats/stat-grid → items array island (the cards/notes precedent)
//   * heatmap         → config island (cells / rowLabels / colLabels / mode /
//                       marginals / values — v1 JSON escape hatch; the structured
//                       2D grid editor is pd-ee-dataviz-structured-editors)
//   * chart           → config island (series / axes — v1)
//   * duel            → config island (legendA / legendB / sourceDefault) +
//                       the STRUCTURED per-row grid (rows)
//   * lineage         → config island (sourceDefault) + the STRUCTURED per-stop
//                       grid (nodes)
//
// bp-studio-lineage-duel-editing: the jarl figure family's authored DATA no longer
// rides the raw-JSON island. `rows`/`nodes` moved OUT of the enumerated config keys
// into a structured per-datum editor whose four operations (edit / add / remove /
// reorder) are the two pure entry points tested below — datumEditorSet and
// datumEditorMove — plus the per-datum `source` (the «kilde» figure_refs/3 reads).
//
// Pure by construction: imports ONLY the DOM-free projector/diff from
// run-convert.js + the DOM-free island serialize/parse pair and helpers from
// embed-node.js (the Node.create schema loads in plain Node; its NodeView factory
// — the only `document` toucher — never runs here), + the CANVAS_SLASH_TYPES
// allowlist from slash-insert.js (D4: no slash insert for data-viz).
// Run: node src/__dataviz.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import {
  fleetChipLabel,
  fleetKindEditable,
  fleetEditorText,
  fleetEditorParse,
  datumEditorSpec,
  datumEditorRows,
  datumEditorSet,
  datumEditorMove,
  BP_FLEET_NODE_NAME,
} from "./canvas/embed-node.js";
import { CANVAS_SLASH_TYPES } from "./canvas/slash-insert.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const DATAVIZ_TYPES = ["stat", "stats", "stat-grid", "heatmap", "chart", "duel", "lineage"];

// Representative payloads shaped per data_viz.ex, so the verbatim-carry round-trip
// is exercised with real authored data (never empty fixtures).
const DATAVIZ_FIXTURES = [
  {
    id: "dv-a",
    type: "stat",
    value: "71",
    label: "tests green",
    max: 118,
    denom: "118",
    spark: [1, 3, 2, 5],
  },
  {
    id: "dv-b",
    type: "stats",
    items: [
      { value: "9", label: "open" },
      { value: "4", label: "done" },
    ],
  },
  { id: "dv-c", type: "stat-grid", items: [{ value: "12", label: "aliased" }] },
  {
    id: "dv-d",
    type: "heatmap",
    cells: [
      [1, 2, 3],
      [4, 5, 6],
    ],
    rowLabels: ["mon", "tue"],
    colLabels: ["a", "b", "c"],
  },
  {
    id: "dv-e",
    type: "chart",
    series: [{ label: "velocity", points: [1, 4, 2, 8] }],
    axes: { min: 0, xLabels: ["w1", "w4"] },
    caption: "A chart",
  },
  {
    id: "dv-f",
    type: "duel",
    legendA: "Med katalogen",
    legendB: "Bare hendene",
    sourceDefault: "commit:591fdcd53",
    rows: [{ label: "add-error-shape", delta: "−30 %", valueA: "1 478", valueB: "2 121" }],
  },
  {
    id: "dv-g",
    type: "lineage",
    sourceDefault: "paper:scaffy-benchmark",
    nodes: [
      { overline: "jan–sep 2025", title: "nextgen-go-cli", value: "335", unit: "commits" },
      { overline: "2026", title: "Navnebyttet", body: "Født på nytt." },
    ],
  },
];

const para = (id, text = "hi") => ({
  id,
  type: "paragraph",
  content: [{ type: "text", text }],
});

// ── projection: every data-viz block → ONE bpFleet node carrying the block verbatim ─

check("runToTiptap: each data-viz kind projects to a bpFleet node with the whole block on bpBlock", () => {
  for (const block of DATAVIZ_FIXTURES) {
    const doc = runToTiptap([block]);
    assert.equal(doc.content.length, 1, `${block.type}: one node`);
    const node = doc.content[0];
    assert.equal(node.type, BP_FLEET_NODE_NAME, `${block.type}: node type is bpFleet`);
    assert.equal(node.attrs.bpId, block.id, `${block.type}: bpId stamped`);
    assert.equal(node.attrs.bpType, block.type, `${block.type}: bpType stamped`);
    assert.deepEqual(node.attrs.bpBlock, block, `${block.type}: whole block carried verbatim`);
    // Deep-cloned, not shared — mutating the node's carried block must not touch source.
    node.attrs.bpBlock.__poke = 1;
    assert.equal(block.__poke, undefined, `${block.type}: bpBlock is a deep clone`);
  }
});

check("a data-viz kind is NOT the generic bpOpaque placeholder (it folds into the run, not the catch-all)", () => {
  for (const block of DATAVIZ_FIXTURES) {
    const node = runToTiptap([block]).content[0];
    assert.notEqual(node.type, "bpOpaque", `${block.type} must not degrade to bpOpaque`);
  }
});

// ── D3 byte-stability: an UN-edited data-viz doc emits ZERO ops ─────────────────

check("runToOps: an unedited run of data-viz + prose blocks emits ZERO ops (D3 byte-stability)", () => {
  const blocks = [para("p0"), ...DATAVIZ_FIXTURES, para("p1")];
  const ops = runToOps(blocks, runToTiptap(blocks));
  assert.deepEqual(ops, [], "a doc that isn't edited produces zero ops");
});

// ── editability: all 5 kinds carry an edit island ───────────────────────────────

check("fleetKindEditable: every data-viz kind is editable in-canvas", () => {
  for (const type of DATAVIZ_TYPES) {
    assert.ok(fleetKindEditable(type), `${type} must be island-editable`);
  }
  // The v1 read-only kinds stay read-only (ratified scope-narrowing, D12).
  assert.ok(!fleetKindEditable("status-legend"), "status-legend stays read-only");
  assert.ok(!fleetKindEditable("asciicast"), "asciicast stays read-only");
});

// ── the island's pure serialize/parse pair (the exact logic the node-view uses) ──

check("fleetEditorText(stat): serializes ONLY the present config keys (no null padding)", () => {
  const text = fleetEditorText(DATAVIZ_FIXTURES[0]);
  const parsed = JSON.parse(text);
  assert.deepEqual(parsed, {
    value: "71",
    label: "tests green",
    max: 118,
    denom: "118",
    spark: [1, 3, 2, 5],
  });
  // A sparse stat serializes sparse — absent keys never appear as null.
  const sparse = JSON.parse(fleetEditorText({ type: "stat", value: "9" }));
  assert.deepEqual(sparse, { value: "9" });
});

check("fleetEditorParse(stat): edits config keys, deletes removed ones, never clobbers id/type", () => {
  const block = DATAVIZ_FIXTURES[0];
  const next = fleetEditorParse(
    block,
    JSON.stringify({ value: "80", label: "tests green", spark: [1, 2] })
  );
  assert.equal(next.value, "80", "edited value lands");
  assert.deepEqual(next.spark, [1, 2], "edited spark lands");
  assert.equal(next.max, undefined, "an enumerated key absent from the JSON is DELETED");
  assert.equal(next.denom, undefined, "denom removed too");
  assert.equal(next.id, "dv-a", "id preserved");
  assert.equal(next.type, "stat", "type preserved");
  // A non-enumerated key in the text is ignored — the island cannot write arbitrary keys.
  const sneaky = fleetEditorParse(block, JSON.stringify({ value: "1", locked: true }));
  assert.equal(sneaky.locked, undefined, "unknown keys are dropped");
});

check("fleetEditorParse: a mid-edit invalid JSON returns null (keep the last good state)", () => {
  assert.equal(fleetEditorParse(DATAVIZ_FIXTURES[0], '{"value": '), null);
  assert.equal(fleetEditorParse(DATAVIZ_FIXTURES[0], "[1,2]"), null, "config must be an object");
  assert.equal(fleetEditorParse(DATAVIZ_FIXTURES[1], '{"not":"array"}'), null, "items must be an array");
});

check("fleetEditorText/Parse(stats + stat-grid): the items array island round-trips (cards precedent)", () => {
  for (const block of [DATAVIZ_FIXTURES[1], DATAVIZ_FIXTURES[2]]) {
    const text = fleetEditorText(block);
    assert.deepEqual(JSON.parse(text), block.items, `${block.type}: island shows the items array`);
    const next = fleetEditorParse(block, JSON.stringify([{ value: "1", label: "new" }]));
    assert.deepEqual(next.items, [{ value: "1", label: "new" }], `${block.type}: edited items land`);
    assert.equal(next.id, block.id, `${block.type}: id preserved`);
  }
});

check("fleetEditorText/Parse(heatmap): the v1 JSON island covers cells/rowLabels/colLabels/mode/marginals/values", () => {
  const block = DATAVIZ_FIXTURES[3];
  assert.deepEqual(JSON.parse(fleetEditorText(block)), {
    cells: [
      [1, 2, 3],
      [4, 5, 6],
    ],
    rowLabels: ["mon", "tue"],
    colLabels: ["a", "b", "c"],
  });
  const next = fleetEditorParse(
    block,
    JSON.stringify({ cells: [[7]], mode: "calendar", marginals: true, values: true })
  );
  assert.deepEqual(next.cells, [[7]], "edited cells land");
  assert.equal(next.mode, "calendar", "mode is island-writable");
  assert.equal(next.marginals, true, "marginals flag is island-writable");
  assert.equal(next.values, true, "values flag is island-writable");
  assert.equal(next.rowLabels, undefined, "labels removed from the JSON are deleted");
});

check("fleetEditorText/Parse(chart): the v1 JSON island covers series/axes", () => {
  const block = DATAVIZ_FIXTURES[4];
  assert.deepEqual(JSON.parse(fleetEditorText(block)), {
    series: [{ label: "velocity", points: [1, 4, 2, 8] }],
    axes: { min: 0, xLabels: ["w1", "w4"] },
  });
  const next = fleetEditorParse(
    block,
    JSON.stringify({ series: [{ label: "burn", points: [3, 2, 1] }] })
  );
  assert.deepEqual(next.series, [{ label: "burn", points: [3, 2, 1] }], "edited series lands");
  assert.equal(next.axes, undefined, "axes removed from the JSON is deleted");
  assert.equal(next.caption, "A chart", "non-island keys (caption) ride untouched");
});

// ── island edit → ONE patch-block round-trip (what the node-view emits) ─────────

// Project a data-viz block to a doc, apply an ISLAND edit to the (sole) fleet node —
// EXACTLY what the node-view does (fleetEditorParse → setNodeMarkup writing the
// mutated block onto attrs.bpBlock) — then diff. Returns the ops.
function islandEdit(block, text) {
  const doc = runToTiptap([block]);
  const next = fleetEditorParse(doc.content[0].attrs.bpBlock, text);
  assert.notEqual(next, null, `${block.type}: the island edit must parse`);
  doc.content[0].attrs.bpBlock = next;
  return runToOps([block], doc);
}

check("runToOps: a stat config island edit emits ONE patch-block carrying the edited config", () => {
  const ops = islandEdit(
    DATAVIZ_FIXTURES[0],
    JSON.stringify({ value: "99", label: "tests green", max: 118, denom: "118", spark: [1, 3, 2, 5] })
  );
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block");
  assert.equal(patches[0].id, "dv-a", "keyed by the block id");
  assert.equal(patches[0].patch.value, "99", "the edited value rides the patch");
  // The immutable id/type are NEVER in the patch (patch.ex re-pins them).
  assert.equal(patches[0].patch.id, undefined, "id is not patched");
  assert.equal(patches[0].patch.type, undefined, "type is not patched");
});

check("runToOps: a stats/stat-grid items island edit emits patch-block{items}", () => {
  for (const block of [DATAVIZ_FIXTURES[1], DATAVIZ_FIXTURES[2]]) {
    const ops = islandEdit(block, JSON.stringify([{ value: "42", label: "answered" }]));
    const patch = ops.find((o) => o.op === "patch-block");
    assert.ok(patch, `${block.type}: a patch-block is emitted`);
    assert.deepEqual(
      patch.patch.items,
      [{ value: "42", label: "answered" }],
      `${block.type}: the edited items array rides the patch verbatim`
    );
  }
});

check("runToOps: a heatmap island edit emits patch-block with the edited grid", () => {
  const ops = islandEdit(
    DATAVIZ_FIXTURES[3],
    JSON.stringify({ cells: [[9, 9]], rowLabels: ["all"], colLabels: ["a", "b"] })
  );
  const patch = ops.find((o) => o.op === "patch-block");
  assert.ok(patch, "a patch-block is emitted");
  assert.deepEqual(patch.patch.cells, [[9, 9]], "the edited cells ride the patch");
});

check("runToOps: a chart island edit emits patch-block with the edited series", () => {
  const ops = islandEdit(
    DATAVIZ_FIXTURES[4],
    JSON.stringify({ series: [{ label: "burn", points: [3, 1] }], axes: { min: 0 } })
  );
  const patch = ops.find((o) => o.op === "patch-block");
  assert.ok(patch, "a patch-block is emitted");
  assert.deepEqual(patch.patch.series, [{ label: "burn", points: [3, 1] }]);
});

check("runToOps: an UNEDITED data-viz block (re-projected) emits ZERO patch-block (D3)", () => {
  for (const block of DATAVIZ_FIXTURES) {
    const doc = runToTiptap([block]); // no mutation
    const ops = runToOps([block], doc);
    assert.ok(
      !ops.some((o) => o.op === "patch-block"),
      `${block.type}: an untouched block still emits no patch-block`
    );
  }
});

// ── docToBlocks: the live-doc → blocks projection round-trips verbatim ──────────

check("docToBlocks: reconstructs each data-viz block byte-identically from its bpFleet node", () => {
  const round = docToBlocks(runToTiptap(DATAVIZ_FIXTURES));
  assert.deepEqual(round, DATAVIZ_FIXTURES, "the data-viz run round-trips through the live-doc projection");
});

// ── structural ops ───────────────────────────────────────────────────────────────

check("runToOps: removing a data-viz block emits remove-block (structural)", () => {
  const chart = DATAVIZ_FIXTURES[4];
  const prev = [para("p0"), chart, para("p1")];
  const nextDoc = runToTiptap([para("p0"), para("p1")]);
  const ops = runToOps(prev, nextDoc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "dv-e" }]
  );
});

// ── the loading-chip labels ──────────────────────────────────────────────────────

check("fleetChipLabel: each data-viz kind has a terse human label for the loading chip", () => {
  assert.equal(fleetChipLabel({ type: "stat" }), "Stat");
  assert.equal(fleetChipLabel({ type: "stats" }), "Stats");
  assert.equal(fleetChipLabel({ type: "stat-grid" }), "Stat grid");
  assert.equal(fleetChipLabel({ type: "heatmap" }), "Heatmap");
  assert.equal(fleetChipLabel({ type: "chart" }), "Chart");
});

// ── D4: no slash insert — CANVAS_SLASH_TYPES untouched at 33 (23 + checklist + quote + image + toggle + steps + tabs + equation + footnotes + contents + video) ──

check("D4: data-viz kinds are NOT slash-insertable and CANVAS_SLASH_TYPES stays at 33", () => {
  for (const type of DATAVIZ_TYPES) {
    assert.ok(!CANVAS_SLASH_TYPES.has(type), `${type} must not be slash-insertable (D4)`);
  }
  assert.equal(CANVAS_SLASH_TYPES.size, 33, "the slash allowlist must stay at 33 types (23 + checklist + the plain quote + image + toggle + steps + tabs + equation + footnotes + contents + video)");
});


// ── bp-studio-lineage-duel-editing: the STRUCTURED per-datum editor ────────────

const DUEL = DATAVIZ_FIXTURES[5];
const LINEAGE = DATAVIZ_FIXTURES[6];

check("the datum array left the JSON config island — the scalars stayed", () => {
  // duel: legends + the fallback kilde are still island-editable JSON …
  assert.deepEqual(JSON.parse(fleetEditorText(DUEL)), {
    legendA: "Med katalogen",
    legendB: "Bare hendene",
    sourceDefault: "commit:591fdcd53",
  });
  assert.deepEqual(JSON.parse(fleetEditorText(LINEAGE)), {
    sourceDefault: "paper:scaffy-benchmark",
  });
  // … and `rows`/`nodes` are NOT enumerated keys any more, so a config commit that
  // does not mention them leaves the authored data untouched (never deleted).
  const afterDuel = fleetEditorParse(DUEL, JSON.stringify({ legendA: "A", legendB: "B" }));
  assert.deepEqual(afterDuel.rows, DUEL.rows, "duel rows survive a config-island commit");
  assert.equal(afterDuel.sourceDefault, undefined, "an enumerated key absent from the JSON is still deleted");
  const afterLin = fleetEditorParse(LINEAGE, JSON.stringify({ sourceDefault: "x" }));
  assert.deepEqual(afterLin.nodes, LINEAGE.nodes, "lineage nodes survive a config-island commit");
  // The JSON island cannot write the datum array either — it is not enumerated.
  const sneaky = fleetEditorParse(DUEL, JSON.stringify({ legendA: "A", rows: [] }));
  assert.deepEqual(sneaky.rows, DUEL.rows, "the JSON island cannot clobber the datum array");
});

check("datumEditorSpec: duel edits rows, lineage edits nodes, and nothing else has a grid", () => {
  assert.equal(datumEditorSpec("duel").arrayKey, "rows");
  assert.equal(datumEditorSpec("lineage").arrayKey, "nodes");
  // The reader's own field contract, in reader order (data_viz.ex duel_row_html/1,
  // lineage_node_html/1) plus the per-datum `source` figure_refs/3 reads.
  assert.deepEqual(
    datumEditorSpec("duel").fields.map((f) => f.key),
    ["label", "valueA", "valueB", "delta", "unit", "source"]
  );
  assert.deepEqual(
    datumEditorSpec("lineage").fields.map((f) => f.key),
    ["overline", "title", "value", "unit", "body", "source"]
  );
  for (const type of ["stat", "stats", "stat-grid", "heatmap", "chart", "cards", "notes"]) {
    assert.equal(datumEditorSpec(type), null, `${type} carries no per-datum grid`);
  }
});

check("datumEditorRows: reads the authored data, and REFUSES a shape it cannot show", () => {
  assert.deepEqual(datumEditorRows(DUEL), DUEL.rows);
  assert.deepEqual(datumEditorRows(LINEAGE), LINEAGE.nodes);
  assert.deepEqual(datumEditorRows({ type: "duel" }), [], "an absent array reads as empty");
  assert.equal(datumEditorRows({ type: "duel", rows: "nope" }), null, "a non-array refuses");
  assert.equal(datumEditorRows({ type: "duel", rows: ["a"] }), null, "a string datum refuses");
  assert.equal(datumEditorRows({ type: "duel", rows: [null] }), null, "a null datum refuses");
  assert.equal(datumEditorRows({ type: "stat", value: "1" }), null, "a kind with no grid refuses");
  // A read is a COPY — mutating it can never reach the block.
  datumEditorRows(DUEL)[0].label = "poked";
  assert.equal(DUEL.rows[0].label, "add-error-shape", "datumEditorRows returns clones");
});

check("datumEditorSet: EDIT one field of one datum, leaving its siblings alone", () => {
  const next = datumEditorSet(DUEL, 0, "valueA", "1 200");
  assert.equal(next.rows[0].valueA, "1 200", "the edited field lands");
  assert.equal(next.rows[0].valueB, "2 121", "a sibling field is untouched");
  assert.equal(next.legendA, "Med katalogen", "the scalars ride untouched");
  assert.equal(next.id, "dv-f", "id preserved");
  assert.equal(DUEL.rows[0].valueA, "1 478", "the source block is never mutated");
  // lineage's per-stop body edits the same way.
  const lin = datumEditorSet(LINEAGE, 1, "body", "Ny tekst.");
  assert.equal(lin.nodes[1].body, "Ny tekst.");
  assert.equal(lin.nodes[0].title, "nextgen-go-cli", "the other stop is untouched");
});

check("datumEditorSet: the per-datum KILDE is editable on both kinds", () => {
  const d = datumEditorSet(DUEL, 0, "source", "commit:deadbeef");
  assert.equal(d.rows[0].source, "commit:deadbeef", "a duel row carries its own source");
  assert.equal(d.sourceDefault, "commit:591fdcd53", "the block default is untouched");
  const l = datumEditorSet(LINEAGE, 0, "source", "paper:annen-kilde");
  assert.equal(l.nodes[0].source, "paper:annen-kilde", "a lineage stop carries its own source");
  // Clearing a source drops the key (falls back to sourceDefault), it never writes "".
  const cleared = datumEditorSet(d, 0, "source", "   ");
  assert.ok(!("source" in cleared.rows[0]), "a blanked field is DELETED, not stored empty");
});

check("datumEditorSet: ADD — typing in the trailing scaffold appends a datum", () => {
  const next = datumEditorSet(DUEL, 1, "label", "new-row");
  assert.equal(next.rows.length, 2, "one datum appended");
  assert.deepEqual(next.rows[1], { label: "new-row" }, "the new datum carries just the typed field");
  assert.deepEqual(next.rows[0], DUEL.rows[0], "the existing datum is untouched");
  // A blank keystroke in the scaffold is a NO-OP (null) — never an empty datum.
  assert.equal(datumEditorSet(DUEL, 1, "label", "   "), null, "a blank scaffold commits nothing");
  // An empty block grows its first datum from the scaffold at index 0.
  const fresh = datumEditorSet({ id: "x", type: "lineage" }, 0, "title", "Først");
  assert.deepEqual(fresh.nodes, [{ title: "Først" }]);
});

check("datumEditorSet: REMOVE — clearing the last non-blank field drops the datum", () => {
  const one = { id: "z", type: "duel", rows: [{ label: "only" }, { label: "keep" }] };
  const next = datumEditorSet(one, 0, "label", "");
  assert.deepEqual(next.rows, [{ label: "keep" }], "the emptied datum is removed");
  // A datum still holding ANY other value survives the clear — including a field
  // this editor does not name (the reader's optional `tone`), so nothing is dropped
  // out from under the author.
  const toned = { id: "z", type: "lineage", nodes: [{ title: "t", tone: "warn" }] };
  const kept = datumEditorSet(toned, 0, "title", "");
  assert.deepEqual(kept.nodes, [{ tone: "warn" }], "an unnamed key keeps the datum alive");
});

check("datumEditorMove: REORDER by position, and a no-op move emits nothing", () => {
  const three = {
    id: "m",
    type: "lineage",
    nodes: [{ title: "a" }, { title: "b" }, { title: "c" }],
  };
  assert.deepEqual(
    datumEditorMove(three, 2, 0).nodes.map((n) => n.title),
    ["c", "a", "b"],
    "the last stop moves to the front"
  );
  assert.deepEqual(
    datumEditorMove(three, 0, 2).nodes.map((n) => n.title),
    ["b", "c", "a"],
    "the first stop moves to the end"
  );
  assert.deepEqual(three.nodes.map((n) => n.title), ["a", "b", "c"], "the source is never mutated");
  assert.equal(datumEditorMove(three, 1, 1), null, "from === to is a no-op (D3: no op emitted)");
  assert.equal(datumEditorMove(three, 3, 0), null, "an out-of-range index is a no-op");
  assert.equal(datumEditorMove(three, -1, 0), null, "a negative index is a no-op");
  assert.equal(datumEditorMove({ type: "stat" }, 0, 1), null, "a kind with no grid is a no-op");
});

check("datumEditorSet: refuses a field the reader does not read, and an unshowable array", () => {
  assert.equal(datumEditorSet(DUEL, 0, "legendA", "x"), null, "a scalar key is not a datum field");
  assert.equal(datumEditorSet(DUEL, 0, "tone", "warn"), null, "an unnamed field is not writable here");
  assert.equal(datumEditorSet(DUEL, 9, "label", "x"), null, "an index past the scaffold is a no-op");
  assert.equal(datumEditorSet({ type: "duel", rows: ["s"] }, 0, "label", "x"), null,
    "an unrepresentable array commits nothing");
});

// ── the grid edit → ONE patch-block, the exact node-view path ───────────────────

// The node-view writes the mutated block onto attrs.bpBlock and the diff turns it
// into ONE patch-block. Same harness as islandEdit, driven by the datum entry points.
function datumEdit(block, mutate) {
  const doc = runToTiptap([block]);
  const next = mutate(doc.content[0].attrs.bpBlock);
  assert.notEqual(next, null, `${block.type}: the datum edit must commit`);
  doc.content[0].attrs.bpBlock = next;
  return runToOps([block], doc);
}

check("runToOps: a duel row edit emits ONE patch-block carrying the whole edited rows array", () => {
  const ops = datumEdit(DUEL, (b) => datumEditorSet(b, 0, "valueA", "1 200"));
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block");
  assert.equal(patches[0].id, "dv-f", "keyed by the block id");
  assert.equal(patches[0].patch.rows[0].valueA, "1 200", "the edited row rides the patch");
  assert.equal(patches[0].patch.legendA, "Med katalogen", "the scalars ride along unchanged");
  assert.equal(patches[0].patch.id, undefined, "id is not patched");
  assert.equal(patches[0].patch.type, undefined, "type is not patched");
});

check("runToOps: an added lineage stop, a per-stop kilde, and a reorder each emit ONE patch-block", () => {
  const added = datumEdit(LINEAGE, (b) => datumEditorSet(b, 2, "title", "Tredje"));
  const addPatch = added.find((o) => o.op === "patch-block");
  assert.equal(addPatch.patch.nodes.length, 3, "the appended stop rides the patch");
  assert.deepEqual(addPatch.patch.nodes[2], { title: "Tredje" });

  const kilde = datumEdit(LINEAGE, (b) => datumEditorSet(b, 0, "source", "paper:x"));
  assert.equal(
    kilde.find((o) => o.op === "patch-block").patch.nodes[0].source,
    "paper:x",
    "the per-stop kilde rides the patch"
  );

  const moved = datumEdit(LINEAGE, (b) => datumEditorMove(b, 1, 0));
  const movePatch = moved.find((o) => o.op === "patch-block");
  assert.deepEqual(
    movePatch.patch.nodes.map((n) => n.title),
    ["Navnebyttet", "nextgen-go-cli"],
    "the reordered stops ride the patch"
  );
  assert.equal(moved.filter((o) => o.op === "patch-block").length, 1, "one patch, not two");
});

check("runToOps: a duel row REMOVED via the grid emits ONE patch-block with the shorter array", () => {
  const two = {
    id: "dv-f2",
    type: "duel",
    legendA: "A",
    legendB: "B",
    rows: [{ label: "gone" }, { label: "stays" }],
  };
  const ops = datumEdit(two, (b) => datumEditorSet(b, 0, "label", ""));
  const patch = ops.find((o) => o.op === "patch-block");
  assert.deepEqual(patch.patch.rows, [{ label: "stays" }], "the cleared row is gone from the patch");
});

check("the structured grid builds NO <button> (rule 6) and mounts on both kinds", () => {
  // The DOM half of the grid lives in embed-node.js, which __atom_chrome.test.mjs
  // guards for <button>. This arm pins the POSITIVE half the guard cannot see: the
  // grid really does build its reorder control, as a native <select>, for both kinds.
  const src = readFileSync(new URL("./canvas/embed-node.js", import.meta.url), "utf8");
  assert.ok(/createElement\(\s*["']select["']\s*\)/.test(src),
    "the per-datum grid must build a native <select> reorder control");
  assert.ok(!/createElement\(\s*["']button["']\s*\)/.test(src),
    "embed-node.js must build no <button> — rule 6 / __atom_chrome");
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall data-viz canvas checks passed");
