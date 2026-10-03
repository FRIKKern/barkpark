// Tab past the last cell of a Studio table adds a row, and the caret lands in it.
//
// Found dogfooding the Studio paper canvas (2026-10-03): in the per-block table
// editor (<bp-paper-editor data-editor-mode="table">) Tab in the last cell asks the
// server for a new row. The editor goes read-only while that structure save is in
// flight, which drops focus, and nothing put it back: the row appeared, but
// document.activeElement was BODY and the author's next keystrokes ("three", Tab,
// "3") went nowhere.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "FormData", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");

const clone = (value) => JSON.parse(JSON.stringify(value));
const projection = {
  id: "table-tab",
  type: "table",
  shape: {
    v: 1,
    head: { state: "row", row: { kind: "array", cells: ["inline-array", "inline-array"] } },
    rows: [
      { kind: "array", cells: ["inline-array", "inline-array"] },
      { kind: "array", cells: ["inline-array", "inline-array"] },
    ],
  },
  head: [[{ type: "text", value: "Name" }], [{ type: "text", value: "Value" }]],
  rows: [
    [[{ type: "text", value: "one" }], [{ type: "text", value: "1" }]],
    [[{ type: "text", value: "two" }], [{ type: "text", value: "2" }]],
  ],
};

const host = document.createElement("bp-paper-editor");
host.setAttribute("data-editor-mode", "table");
host.block = clone(projection);
const ops = [];
host.addEventListener("bp-op", (event) => ops.push(clone(event.detail)));
document.body.appendChild(host);

try {
  const editor = host._editor;
  assert.ok(editor, "the table editor is mounted");

  // Caret at the end of the last cell ("2"), editor focused.
  let lastCellEnd = null;
  editor.state.doc.descendants((node, pos) => {
    if (node.type.name === "bpTableCell") lastCellEnd = pos + 1 + node.content.size;
    return true;
  });
  editor.chain().focus().setTextSelection(lastCellEnd).run();
  editor.view.focus();
  assert.equal(editor.view.hasFocus(), true, "the table editor has focus before Tab");

  // Tab, as the browser delivers it.
  const tab = new window.KeyboardEvent("keydown", { key: "Tab", code: "Tab", keyCode: 9, bubbles: true, cancelable: true });
  editor.view.dom.dispatchEvent(tab);
  const structure = ops.find((op) => op.op === "patch-table-structure");
  assert.ok(structure, `Tab past the last cell asks for a row: ${JSON.stringify(ops)}`);
  assert.equal(structure.action, "add-row");
  // A browser drops focus from an element that stops being contenteditable;
  // jsdom does not, so do what the browser does.
  assert.equal(editor.view.dom.getAttribute("contenteditable"), "false",
    "the table is read-only while the row is saved");
  editor.view.dom.blur();
  assert.equal(editor.view.hasFocus(), false);

  // The server saves the row and echoes the new shape.
  host.trackTableMutation(structure, "structure-1");
  host.tableMutationResult(structure, true, { request_id: "structure-1" });
  const ack = clone(projection);
  ack.shape.rows.push({ kind: "array", cells: ["inline-array", "inline-array"] });
  ack.rows.push([[], []]);
  host.applyTableProjection(ack, { requestId: "structure-1" });

  assert.equal(editor.isEditable, true, "the table is editable again");
  assert.equal(editor.view.hasFocus(), true, "focus is back in the table editor");
  const { $from } = editor.state.selection;
  assert.equal($from.parent.type.name, "bpTableCell", "the caret is in a cell");
  const table = editor.state.doc.firstChild;
  assert.equal($from.index($from.depth - 2), table.childCount - 1, "the caret is in the new (last) row");
  assert.equal($from.index($from.depth - 1), 0, "the caret is in its first cell");

  editor.commands.insertContent("three");
  const rows = editor.getJSON().content[0].content;
  assert.equal(rows.at(-1).content[0].content?.[0]?.text, "three", "typing lands in the new row");

  console.log("PASS table_tab_new_row_focus: Tab past the last cell adds a row and keeps the caret in it");
} finally {
  host.remove();
  dom.window.close();
}
