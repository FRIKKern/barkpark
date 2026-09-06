import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

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

control("add-row").focus();
editor.block = { ...structuredClone(projection), rows: [[cell("Changed"), cell("Two")], projection.rows[1]] };
assert.equal(document.activeElement, control("add-row"),
  "an authoritative cell repaint retains the focused structural control");

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
