// __datum_grid_mounted.test.mjs — bp-studio-lineage-duel-editing.
//
// The pure half of the per-datum editor (datumEditorSet / datumEditorMove) is
// driven by __dataviz.test.mjs. THIS arm mounts the real canvas custom element and
// drives the real CONTROLS — an <input> per field, a <select> per position — so the
// claim "a lineage stop and a duel row can be added, edited and reordered in the
// editor, including their source refs" is proven by the DOM the author touches, not
// only by the functions behind it. A mounted arm is the only thing that can catch a
// grid that is never built, never wired, or wired to the wrong index.
//
// Run: node src/canvas/__datum_grid_mounted.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("../index.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.stack || e.message}`);
  }
}

function mount(block) {
  const host = document.createElement("bp-paper-canvas");
  host.blocks = [JSON.parse(JSON.stringify(block))];
  const ops = [];
  host.addEventListener("bp-canvas-ops", (e) => ops.push(...e.detail.ops));
  document.body.appendChild(host);
  const grid = host.querySelector(`[data-test-id="paper-fleet-datum-${block.type}"]`);
  return { host, ops, grid };
}

const field = (grid, index, key) =>
  grid.querySelector(`input[data-bp-datum-index="${index}"][data-bp-datum-field="${key}"]`);

function type(input, text) {
  input.value = text;
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

// One patch-block, keyed by the block id — the shape the server repaints from.
function patchOf(host, ops) {
  host.flushPendingChanges();
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, `exactly one patch-block, got ${JSON.stringify(ops)}`);
  return patches[0].patch;
}

const DUEL = {
  id: "duel-1",
  type: "duel",
  legendA: "Med katalogen",
  legendB: "Bare hendene",
  sourceDefault: "commit:591fdcd53",
  rows: [
    { label: "add-error-shape", valueA: "1 478", valueB: "2 121" },
    { label: "rename", valueA: "12", valueB: "40" },
  ],
};

const LINEAGE = {
  id: "lin-1",
  type: "lineage",
  sourceDefault: "paper:scaffy-benchmark",
  nodes: [
    { overline: "jan–sep 2025", title: "nextgen-go-cli", value: "335", unit: "commits" },
    { overline: "2026", title: "Navnebyttet", body: "Født på nytt." },
  ],
};

check("the grid MOUNTS on both kinds: one control per reader field, plus an add scaffold", () => {
  for (const [block, keys, arrayKey] of [
    [DUEL, ["label", "valueA", "valueB", "delta", "unit", "source"], "rows"],
    [LINEAGE, ["overline", "title", "value", "unit", "body", "source"], "nodes"],
  ]) {
    const { grid, host } = mount(block);
    assert.ok(grid, `${block.type}: the per-datum grid is built`);
    const n = block[arrayKey].length;
    // rows.length + 1 DOM rows — the trailing one is the ADD scaffold.
    assert.equal(
      grid.querySelectorAll("[data-bp-datum-index]").length > 0,
      true,
      `${block.type}: rows are indexed`,
    );
    assert.equal(
      grid.querySelectorAll('[data-bp-datum-scaffold="true"]').length,
      1,
      `${block.type}: exactly one add scaffold`,
    );
    for (const key of keys) {
      assert.ok(field(grid, 0, key), `${block.type}: datum 0 has a ${key} control`);
      assert.ok(field(grid, n, key), `${block.type}: the scaffold has a ${key} control`);
    }
    // The reorder control is a native <select> over the real positions — no <button>.
    const sel = grid.querySelectorAll("select.bp-fleet-datum-pos");
    assert.equal(sel.length, n, `${block.type}: one position control per existing datum`);
    assert.equal(sel[0].options.length, n, `${block.type}: positions 1…${n}`);
    assert.equal(grid.querySelectorAll("button").length, 0, `${block.type}: no button chrome (rule 6)`);
    host.remove();
  }
});

check("EDIT: typing in a duel row's field emits ONE patch-block with just that field changed", () => {
  const { host, ops, grid } = mount(DUEL);
  type(field(grid, 0, "valueA"), "1 200");
  const patch = patchOf(host, ops);
  assert.equal(patch.rows[0].valueA, "1 200", "the typed value lands");
  assert.equal(patch.rows[0].valueB, "2 121", "the sibling field is untouched");
  assert.deepEqual(patch.rows[1], DUEL.rows[1], "the other row is untouched");
  assert.equal(patch.legendA, "Med katalogen", "the scalar config rides along");
  host.remove();
});

check("SOURCE: the per-datum kilde is editable from the grid on both kinds", () => {
  const d = mount(DUEL);
  type(field(d.grid, 1, "source"), "commit:deadbeef");
  assert.equal(patchOf(d.host, d.ops).rows[1].source, "commit:deadbeef");
  d.host.remove();

  const l = mount(LINEAGE);
  type(field(l.grid, 0, "source"), "paper:annen-kilde");
  const patch = patchOf(l.host, l.ops);
  assert.equal(patch.nodes[0].source, "paper:annen-kilde", "the stop carries its own kilde");
  assert.equal(patch.sourceDefault, "paper:scaffy-benchmark", "the block default is untouched");
  l.host.remove();
});

check("ADD: typing in the trailing scaffold appends a stop and regrows the scaffold", () => {
  const { host, ops, grid } = mount(LINEAGE);
  type(field(grid, 2, "title"), "Tredje");
  const patch = patchOf(host, ops);
  assert.equal(patch.nodes.length, 3, "a third stop was appended");
  assert.deepEqual(patch.nodes[2], { title: "Tredje" }, "it carries just the typed field");
  // The grid rebuilt: the new stop is a real datum (it has a position control) and a
  // FRESH scaffold sits behind it, so the next add needs no other affordance.
  assert.equal(grid.querySelectorAll("select.bp-fleet-datum-pos").length, 3, "three positions now");
  assert.ok(field(grid, 3, "title"), "a fresh scaffold is waiting at index 3");
  host.remove();
});

check("REMOVE: clearing a duel row's only non-blank fields drops it from the array", () => {
  const { host, ops, grid } = mount({
    id: "duel-2",
    type: "duel",
    legendA: "A",
    legendB: "B",
    rows: [{ label: "gone" }, { label: "stays" }],
  });
  type(field(grid, 0, "label"), "");
  const patch = patchOf(host, ops);
  assert.deepEqual(patch.rows, [{ label: "stays" }], "the emptied row is removed");
  assert.equal(grid.querySelectorAll("select.bp-fleet-datum-pos").length, 1, "one datum left in the grid");
  host.remove();
});

check("REORDER: picking a position on the <select> moves the stop and repaints the grid", () => {
  const { host, ops, grid } = mount(LINEAGE);
  const sel = grid.querySelector('select.bp-fleet-datum-pos[data-bp-datum-index="1"]');
  // FOCUS the control first — the real gesture. Focus inside the grid makes the
  // node-view's echo refresh stand down (it must never repaint out from under an
  // edit), so the reorder's OWN repaint is the only thing that can reseat the
  // fields; without it the author is left looking at a stale order.
  sel.focus();
  assert.ok(grid.contains(document.activeElement), "the position control has focus");
  sel.value = "0";
  sel.dispatchEvent(new Event("change", { bubbles: true }));
  const patch = patchOf(host, ops);
  assert.deepEqual(
    patch.nodes.map((n) => n.title),
    ["Navnebyttet", "nextgen-go-cli"],
    "the second stop moved to the front",
  );
  // The repaint reseats the fields at their NEW indices (a stale grid would still
  // show the old order and the next edit would land on the wrong stop).
  assert.equal(field(grid, 0, "title").value, "Navnebyttet");
  assert.equal(field(grid, 1, "title").value, "nextgen-go-cli");
  host.remove();
});

check("NO-OP: mounting, and re-picking a datum's own position, emit ZERO ops (D3)", () => {
  const { host, ops, grid } = mount(DUEL);
  host.flushPendingChanges();
  assert.deepEqual(ops, [], "a mounted, untouched figure emits nothing");
  const sel = grid.querySelector('select.bp-fleet-datum-pos[data-bp-datum-index="0"]');
  sel.value = "0";
  sel.dispatchEvent(new Event("change", { bubbles: true }));
  host.flushPendingChanges();
  assert.deepEqual(ops, [], "moving a datum to where it already is emits no op");
  host.remove();
});

check("the JSON island stays as the scalar escape hatch — and no longer shows the array", () => {
  const { host, grid } = mount(DUEL);
  const area = host.querySelector('[data-test-id="paper-fleet-editor-duel"] textarea');
  assert.ok(area, "the config island is still mounted");
  const cfg = JSON.parse(area.value);
  assert.deepEqual(cfg, {
    legendA: "Med katalogen",
    legendB: "Bare hendene",
    sourceDefault: "commit:591fdcd53",
  });
  assert.ok(!("rows" in cfg), "the authored rows left the JSON blob for the grid");
  assert.ok(grid, "…and the grid is where they went");
  host.remove();
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall mounted per-datum grid checks passed");
