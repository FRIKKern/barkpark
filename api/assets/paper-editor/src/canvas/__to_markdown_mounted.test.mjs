// Mounted: toMarkdown() (1.23.0) reads the run as it is on screen, typing the
// canvas has not sent yet included, and sends nothing. Given `blocks` it converts
// those instead, on an element that was never mounted too. A read-only canvas
// exports the same way.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/w/a/p/b/studio",
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
const settle = () => new Promise((resolve) => setTimeout(resolve, 50));
const blocks = [
  { id: "h-1", type: "heading", level: 2, text: "Why" },
  { id: "p-1", type: "paragraph", content: [...text("A "), { type: "strong", children: text("bold") }, ...text(" start.")] },
  { id: "c-1", type: "code", lang: "elixir", value: ":ok" },
  { id: "i-1", type: "image", src: "/media/a.png", alt: "A" },
];
const saved = "## Why\n\nA **bold** start.\n\n```elixir\n:ok\n```\n\n![A](http://localhost/media/a.png)";

// Never mounted: the blocks it was given, or the blocks it holds.
const spare = document.createElement("bp-paper-canvas");
assert.equal(spare.toMarkdown({ blocks: [{ type: "divider" }] }), "---");
assert.equal(spare.toMarkdown(), "", "an empty, unmounted canvas is an empty string");
spare.blocks = blocks;
assert.equal(spare.toMarkdown(), saved, "before mount it converts the blocks it holds");

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = blocks;
const sent = [];
canvas.addEventListener("bp-canvas-ops", (event) => sent.push(event.detail));
document.body.appendChild(canvas);
await settle();
assert.equal(canvas.toMarkdown(), saved, "the mounted run");

// Typing that has not been sent is in the export, and exporting sends nothing.
canvas._editor.commands.insertContentAt(canvas._editor.state.doc.child(0).nodeSize + 1, "Typed. ");
assert.equal(sent.length, 0, "the edit is still waiting on its debounce");
assert.match(canvas.toMarkdown(), /^## Why\n\nTyped\. A \*\*bold\*\* start\./, "unsent typing is exported");
assert.equal(sent.length, 0, "toMarkdown sends no ops");
assert.equal(canvas.hasPendingChanges(), true, "and leaves the pending edit pending");
assert.equal(canvas.toMarkdown({ blocks: [{ type: "chart" }], placeholder: "%{block}: utelatt" }), "> [Chart: utelatt]");
assert.equal(canvas.toMarkdown({ baseUrl: "https://example.com/x/" }).includes("![A](https://example.com/media/a.png)"), true, "baseUrl resolves a relative address");

// A canvas that cannot be edited exports the same way.
const reader = document.createElement("bp-paper-canvas");
reader.setAttribute("editable", "false");
reader.blocks = blocks;
document.body.appendChild(reader);
await settle();
assert.equal(reader.toMarkdown(), saved, "a read-only canvas exports");

console.log("toMarkdown: the live run, unsent typing included; given blocks on any element; read-only too; no ops");
