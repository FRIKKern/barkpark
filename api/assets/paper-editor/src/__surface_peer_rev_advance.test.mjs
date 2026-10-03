// A canvas edit and a table-cell edit made back to back must BOTH save. Found
// dogfooding the Studio canvas (2026-10-03): type in a canvas paragraph, then
// click straight into a table cell and type before the canvas save lands. The
// paragraph saves; the cell is sent with if_rev = the revision it was authored
// on, which the page's OWN canvas save has just superseded. The server answers
// {saved:false, conflict:true}, the editor shows "Save failed" with no way
// forward, and leaving the page drops the cell edit.
//
// The coordinator already advances a draft's base past the page's own save
// when one side is a PaperFieldBlock form (task-e9205d55fc79976e). Canvas runs
// and per-block editors also own disjoint blocks, so the same advance applies
// between them, in both directions. A pending external echo still blocks it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:peers" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-peers-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
      <div id="paper-ed-table" phx-hook="BarkparkPaperEditor"></div>
    </div>
  </main></body>`, { url: "http://localhost/" });
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const Hooks = window.BarkparkPaperEditorHooks;
const runEl = window.document.querySelector("#paper-canvas-peers-run-0");
const tableEl = window.document.querySelector("#paper-ed-table");
const canvas = runEl.querySelector("bp-paper-canvas");
canvas.acknowledgedSaves = true;
canvas.acknowledgeOps = () => {};
canvas.hasPendingChanges = () => false;
canvas.applyServerBlocks = () => {};

const canvasCalls = [];
const canvasReplies = [];
const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el: runEl,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    canvasCalls.push(payload);
    return new Promise((resolve) => canvasReplies.push(resolve));
  },
};
hook.mounted();
const coordinator = hook._exitCoordinator;
assert.ok(coordinator, "the canvas run joins the paper's exit coordinator");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const canvasBatch = (seq) => runEl.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "patch-block", id: "p-1", patch: { content: [] } }], seq },
}));
const tableWire = [];
const tableReplies = [];
const tableSave = () => coordinator.mutate(tableEl, {
  payload: { op: "patch-table-cells", id: "t-1" },
  send: (wire) => {
    tableWire.push(wire);
    return new Promise((resolve) => tableReplies.push(resolve));
  },
});

try {
  // ── canvas save in flight, table authored meanwhile, table sent after ──
  canvasBatch(1);
  assert.equal(canvasCalls.length, 1, "the canvas batch is sent");
  assert.equal(canvasCalls[0].if_rev, 7, "the canvas batch is based on the loaded revision");
  coordinator.markDirty(tableEl); // typing in the table cell while the canvas save is in flight
  canvasReplies.shift()({ saved: true, request_id: canvasCalls[0].request_id, rev: 8 });
  await tick();
  await tick();
  tableSave();
  assert.equal(tableWire.length, 1, "the table save is sent");
  assert.equal(tableWire[0].if_rev, 8,
    "the table cell rides the revision the page's own canvas save produced, not the superseded one");
  tableReplies.shift()({ saved: true, request_id: tableWire[0].request_id, rev: 9 });
  await tick();
  await tick();

  // ── the reverse: table save in flight, canvas authored meanwhile ──
  coordinator.markDirty(tableEl);
  tableSave();
  assert.equal(tableWire.length, 2);
  assert.equal(tableWire[1].if_rev, 9);
  coordinator.markDirty(runEl); // canvas typing while the table save is in flight
  tableReplies.shift()({ saved: true, request_id: tableWire[1].request_id, rev: 10 });
  await tick();
  await tick();
  canvasBatch(2);
  assert.equal(canvasCalls.length, 2, "the canvas batch is sent");
  assert.equal(canvasCalls[1].if_rev, 10,
    "the canvas batch rides the revision the page's own table save produced");
  canvasReplies.shift()({ saved: true, request_id: canvasCalls[1].request_id, rev: 11 });
  await tick();
} finally {
  hook.destroyed?.();
  window.close();
}

console.log("surface peer revision advance: back-to-back canvas and table edits both save");
