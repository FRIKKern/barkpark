import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const styles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
assert.match(styles, /\.bp-canvas-table__controls \{ position: absolute; opacity: 0; pointer-events: none;/);
assert.match(styles, /\.bp-canvas-table:hover > \.bp-canvas-table__controls, \.bp-canvas-table:focus-within > \.bp-canvas-table__controls, \.bp-canvas-table__controls\[open\] \{ position: relative; opacity: 1; pointer-events: auto;/,
  "visible controls must reserve space below the table, including keyboard focus");
assert.doesNotMatch(styles, /\.bp-canvas-table__cols \{ bottom: 100%/,
  "column controls must not float over a preceding heading");

const { window } = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const cell = (value) => [{ type: "text", value }];
const rowShape = { kind: "array", cells: ["inline-array", "inline-array"] };
const projection = {
  id: "table-focus", type: "table",
  shape: { v: 1, head: { state: "absent" }, rows: [rowShape, rowShape] },
  head: null,
  rows: [[cell("One"), cell("Two")], [cell("Three"), cell("Four")]],
};
const editor = document.createElement("bp-paper-editor");
editor.setAttribute("data-editor-mode", "table");
editor.block = structuredClone(projection);
document.body.appendChild(editor);
const control = (action) => editor.querySelector(`[data-table-action="${action}"]`);

const cellPositions = [];
editor._editor.state.doc.descendants((node, pos) => {
  if (node.type.name === "bpTableCell") cellPositions.push(pos + 1);
});
const tab = (position, shiftKey = false) => {
  editor._editor.commands.setTextSelection(position);
  const event = new window.KeyboardEvent("keydown", {
    key: "Tab", code: "Tab", shiftKey, bubbles: true, cancelable: true,
  });
  editor._editor.view.dom.dispatchEvent(event);
  return event;
};
assert.equal(tab(cellPositions[0], true).defaultPrevented, false,
  "Shift-Tab in the first cell allows native focus to leave the table");
assert.equal(tab(cellPositions[0]).defaultPrevented, true,
  "Tab between cells remains an editor navigation command");
assert.equal(editor._editor.state.selection.from, cellPositions[1]);
assert.equal(tab(cellPositions[1], true).defaultPrevented, true);
assert.equal(editor._editor.state.selection.from, cellPositions[0]);

const table = editor.querySelector(".bp-table");
const controls = editor.querySelector("details.bp-canvas-table__controls");
assert.ok(controls, "Table structure uses an explicit native disclosure");
assert.equal(table.nextElementSibling, controls, "controls follow the table rather than covering its neighbors");
assert.equal(controls.open, false, "Table controls start closed");
assert.equal(controls.querySelector("summary").textContent, "Configure table");
assert.equal(controls.querySelector('[aria-label="Table columns"]').getAttribute("role"), "group");
assert.equal(controls.querySelector('[aria-label="Table rows"]').getAttribute("role"), "group");
assert.equal(controls.contentEditable, "false");
controls.open = true;

control("add-row").focus();
editor.block = { ...structuredClone(projection), rows: [[cell("Changed"), cell("Two")], projection.rows[1]] };
assert.equal(document.activeElement, control("add-row"),
  "an authoritative cell repaint retains the focused structural control");
assert.equal(controls.open, true, "authoritative repaint retains the explicit open state");

control("remove-row:1").focus();
editor.block = {
  ...structuredClone(projection),
  shape: { ...projection.shape, rows: [rowShape] },
  rows: [projection.rows[0]],
};
assert.equal(document.activeElement, control("add-row"),
  "removing the focused row leaves keyboard focus in its row controls");

editor.block = structuredClone(projection);
control("remove-column:1").focus();
editor.block = {
  ...structuredClone(projection),
  shape: { ...projection.shape, rows: projection.rows.map(() => ({
    kind: "array", cells: ["inline-array"],
  })) },
  rows: projection.rows.map((row) => [row[0]]),
};
assert.equal(document.activeElement, control("add-column"),
  "removing the focused column leaves keyboard focus in its column controls");

editor.block = structuredClone(projection);
control("add-header").focus();
editor.block = {
  ...structuredClone(projection),
  shape: { ...projection.shape, head: { state: "row", row: rowShape } },
  head: [cell("First"), cell("Second")],
};
assert.equal(document.activeElement, control("add-row"),
  "a replaced header action leaves focus on an enabled row control");

const outside = document.createElement("button");
document.body.appendChild(outside);
outside.focus();
editor.block = structuredClone(projection);
assert.equal(document.activeElement, outside, "a background Table echo never steals focus");

// Tab in the LAST cell grows the table by a body row — what @tiptap/extension-table does,
// and how an author builds a table from the keyboard. Keyboard reach to the controls
// stays: Shift-Tab out of the first cell (above), and the disclosure follows the table in
// the tab order. In this table-field host the row is an action the host applies and
// echoes, so the keystroke must emit the same structure op as the "+ row" control rather
// than edit the doc. Last, because the request leaves the editor awaiting that echo.
const structureOps = [];
editor.addEventListener("bp-op", (e) => { if (e.detail?.op === "patch-table-structure") structureOps.push(e.detail); });
assert.equal(tab(cellPositions.at(-1)).defaultPrevented, true,
  "Tab in the last cell is an editor command: it requests a new row");
assert.equal(structureOps.length, 1, "Tab in the last cell emits one table structure op");
assert.equal(structureOps[0].action, "add-row", "the op adds a row");
editor.remove();
outside.remove();
console.log("PASS Table controls retain keyboard focus through authoritative repaints");
