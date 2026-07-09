// __table_parity.test.mjs — W1.2 table edit-DOM binding gate.
//
// The editable table (canvas/table-node.js: bpTable > bpTableRow >
// bpTableHeaderCell|bpTableCell) must bind the SAME shared classes the /papers
// article reader emits so the byte-locked `.bp-table` / `.bp-table__th` /
// `.bp-table__td` CSS applies on both surfaces. The existing __table.test.mjs
// proves only the block ⇄ ops ROUND-TRIP (it imports run-convert.js, never
// table-node.js) — nothing asserts table-node.js still emits those classes, and
// nothing JUSTIFIES its two documented deltas from the reader:
//   (1) the thead-drop — the reader splits header/body into <thead>/<tbody>
//       (walk.ex table/3:920-951); the edit table puts ALL rows in the SINGLE
//       <tbody> contentDOM (table-node.js ~L50-55). Invisible: no CSS targets
//       thead/tbody — styling rides the cell classes.
//   (2) the .bp-canvas-table / .bp-canvas-table__cols edit chrome
//       (table-node.js ~L269-277) — add/remove row/col + toggle-header rails
//       that live OUTSIDE the contentDOM and never exist in the reader.
// This gate freezes the shared bindings (spec-level via renderHTML, the
// __divider_parity.test.mjs technique) and justifies the two deltas as edit-only
// ISLANDS (source-level, the __callout_parity.test.mjs technique — the node-view
// builds DOM only inside addNodeView, which cannot mount headless; no jsdom).
//
// Reader target — Barkpark.PortableDoc.Render.Walk.table/3 (:article)
// (walk.ex:908-952):
//   <table role="presentation" class="bp-table">
//     <thead><tr><th class="bp-table__th">…</th></tr></thead>?   (head opt-in)
//     <tbody><tr><td class="bp-table__td">…</td></tr></tbody>
//   </table>
//
// KNOWN a11y-only delta (NOT this slice's scope, flagged for the lead): the
// reader stamps role="presentation" on <table>; the edit table omits it. It
// affects no CSS (styling rides the classes), so parity is intact; tracked
// separately rather than asserted here.
//
// Run: node src/__table_parity.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  BpTable,
  BpTableRow,
  BpTableCell,
  BpTableHeaderCell,
} from "./canvas/table-node.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(__dirname, "canvas/table-node.js"), "utf8");

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

// ── (a) SHARED reader class bindings — spec-level via renderHTML ──────────────

const tableSpec = BpTable.config.renderHTML({
  HTMLAttributes: { "data-bp-id": "t1", "data-bp-type": "table" },
});

check("bpTable renderHTML emits <table class=\"bp-table\"> (reader walk.ex table/3)", () => {
  assert.equal(tableSpec[0], "table");
  assert.ok(
    String(tableSpec[1].class).split(/\s+/).includes("bp-table"),
    "bpTable dropped the shared .bp-table class — the reader's table rule would " +
      "stop applying on the edit surface.",
  );
});

check("bpTable schema fallback carries the bp-attrs stamp on the <table>", () => {
  assert.equal(tableSpec[1]["data-bp-type"], "table");
  assert.equal(tableSpec[1]["data-bp-id"], "t1");
});

// The LIVE editor overrides renderHTML with an addNodeView that builds the <table>
// element in JS (the schema spec above is only the non-editable / pure-Node export
// path). Source-assert the node-view paints the SAME shared .bp-table class on the
// real table element, or the live edit table would drift from the reader.
check("bpTable node-view paints the shared .bp-table class on the live <table> element", () => {
  assert.ok(
    /table\.className\s*=\s*["']bp-table["']/.test(src),
    "the bpTable node-view no longer sets table.className='bp-table' — the LIVE edit " +
      "table element would stop matching the reader's .bp-table rule (the schema-fallback " +
      "spec is bypassed by addNodeView in the editor).",
  );
});

check("bpTable content hole nests under a single <tbody> — the thead-drop, structurally", () => {
  // The schema fallback nests the row content hole inside ONE ["tbody", 0]; there
  // is NO thead branch. This IS the documented thead-drop, proven at the spec.
  const child = tableSpec[2];
  assert.deepEqual(
    child,
    ["tbody", 0],
    "bpTable renderHTML no longer nests its rows under a single [\"tbody\", 0] — the " +
      "edit table keeps ALL rows (header + body) in one <tbody> (the documented " +
      "thead-drop); a thead branch here would diverge from the coarse round-trip.",
  );
});

const cellSpec = BpTableCell.config.renderHTML();
check("bpTableCell renderHTML emits <td class=\"bp-table__td\"> (reader shared class)", () => {
  assert.equal(cellSpec[0], "td");
  assert.ok(
    String(cellSpec[1].class).split(/\s+/).includes("bp-table__td"),
    "bpTableCell dropped .bp-table__td — the reader paints every body cell with it.",
  );
  assert.equal(cellSpec[cellSpec.length - 1], 0, "bpTableCell lost its inline* content hole.");
});

const headSpec = BpTableHeaderCell.config.renderHTML();
check("bpTableHeaderCell renderHTML emits <th class=\"bp-table__th\"> (reader shared class)", () => {
  assert.equal(headSpec[0], "th");
  assert.ok(
    String(headSpec[1].class).split(/\s+/).includes("bp-table__th"),
    "bpTableHeaderCell dropped .bp-table__th — the reader paints every header cell with it.",
  );
  assert.equal(headSpec[headSpec.length - 1], 0, "bpTableHeaderCell lost its inline* content hole.");
});

check("bpTableRow renderHTML emits a bare <tr> with a content hole (no class chrome)", () => {
  const rowSpec = BpTableRow.config.renderHTML();
  assert.equal(rowSpec[0], "tr");
  assert.equal(rowSpec[rowSpec.length - 1], 0);
});

// ── (b) JUSTIFY the thead-drop as an edit-only island (source-level) ─────────

check("the thead-drop justification comment is present (walk.ex splits thead/tbody; edit keeps one tbody)", () => {
  assert.ok(
    /thead DROP/i.test(src),
    "table-node.js lost the documented \"thead DROP\" justification — the delta from " +
      "the reader's <thead>/<tbody> split must stay explained where a future editor reads it.",
  );
  assert.ok(
    /NO CSS targets\s*\n?\s*\/\/?\s*thead\/tbody|NO CSS targets thead\/tbody/i.test(src) ||
      /no CSS targets/i.test(src),
    "table-node.js dropped the note that NO CSS targets thead/tbody — the thead-drop is " +
      "only invisible BECAUSE styling rides the .bp-table* cell classes; that reasoning must stay.",
  );
});

// ── (c) JUSTIFY the .bp-canvas-table chrome as an edit-only island ───────────

check("the edit chrome is namespaced .bp-canvas-table* (never a reader .bp-table* class)", () => {
  // The add/remove/toggle rails ride bp-canvas-table / __cols / __rows / __btn —
  // all under the edit-only `bp-canvas-` namespace, disjoint from the reader's
  // shared `bp-table` classes. That prefix boundary IS what keeps the chrome an
  // edit-only island the reader never paints.
  assert.ok(/bp-canvas-table__cols/.test(src), "table-node.js dropped the .bp-canvas-table__cols col rail.");
  assert.ok(/bp-canvas-table__rows/.test(src), "table-node.js dropped the .bp-canvas-table__rows row rail.");
  assert.ok(
    !/["']bp-canvas-table[^"'_]*__(th|td)/.test(src),
    "table-node.js gave a CELL a bp-canvas-* class — cells MUST carry only the shared " +
      "reader .bp-table__th/.bp-table__td so View ≡ Edit; chrome stays on the wrapper rails.",
  );
});

check("chrome rails are contentEditable=false and live OUTSIDE the contentDOM (tbody)", () => {
  assert.ok(
    /colRail\.contentEditable\s*=\s*["']false["']/.test(src),
    "the col rail is no longer contentEditable=false — an editable chrome rail could " +
      "capture typing and leak edit-only DOM into the saved content.",
  );
  assert.ok(
    /rowRail\.contentEditable\s*=\s*["']false["']/.test(src),
    "the row rail is no longer contentEditable=false.",
  );
  assert.ok(
    /contentDOM:\s*tbody/.test(src),
    "the contentDOM is no longer the <tbody> — the shared reader cells must be the ONLY " +
      "content; if the chrome rails entered the contentDOM they would round-trip into blocks.",
  );
});

check("chrome events are swallowed (stopEvent on the rails) — the island never becomes content", () => {
  assert.ok(
    /stopEvent:\s*\(event\)\s*=>\s*\{[\s\S]*colRail\.contains[\s\S]*rowRail\.contains/.test(src),
    "table-node.js no longer swallows chrome-rail events via stopEvent — a rail click must " +
      "NEVER become a PM transaction, or the edit-only chrome stops being an inert island.",
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
