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
editor.remove();
outside.remove();
console.log("PASS Table controls retain keyboard focus through authoritative repaints");
