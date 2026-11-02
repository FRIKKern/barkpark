// Mounted: focusSelection() (1.22.0) moves focus into the editing surface and
// keeps the selection where it was, on <bp-paper-canvas> and <bp-paper-editor>.
// Hosts used to focus [contenteditable] or .ProseMirror inside the element for
// this (Studio, Barkdown, Barkever, barkpark-studio); an unmounted element answers
// false.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body><button id=\"away\">away</button></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");

const text = (value) => [{ type: "text", value }];
const away = document.getElementById("away");
const settle = () => new Promise((resolve) => setTimeout(resolve, 50));

const canvas = document.createElement("bp-paper-canvas");
assert.equal(canvas.focusSelection(), false, "an unmounted canvas answers false");
canvas.blocks = [
  { id: "p-1", type: "paragraph", content: text("First.") },
  { id: "p-2", type: "paragraph", content: text("Second.") },
];
document.body.appendChild(canvas);
await settle();
canvas._editor.commands.setTextSelection(12);
away.focus();
assert.equal(document.activeElement, away);
assert.equal(canvas.focusSelection(), true, "the canvas reports focus");
assert.ok(canvas.contains(document.activeElement), "focus is inside the canvas");
assert.equal(canvas._editor.state.selection.from, 12, "the canvas keeps its selection");

const editor = document.createElement("bp-paper-editor");
assert.equal(editor.focusSelection(), false, "an unmounted editor answers false");
editor.setAttribute("data-block", JSON.stringify({ id: "e-1", type: "paragraph", content: text("Only block.") }));
document.body.appendChild(editor);
await settle();
editor._editor.commands.setTextSelection(5);
away.focus();
assert.equal(editor.focusSelection(), true, "the editor reports focus");
assert.ok(editor.contains(document.activeElement), "focus is inside the editor");
assert.equal(editor._editor.state.selection.from, 5, "the editor keeps its selection");

canvas.remove();
assert.equal(canvas.focusSelection(), false, "a removed canvas answers false");

console.log("focusSelection: both elements focus their surface and keep the selection; unmounted answers false");
