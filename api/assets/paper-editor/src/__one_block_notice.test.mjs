// Mounted regression: Enter in a one-block editor explains the way on.
//
// Found live (r4-lane-c dogfood): in Studio's Beta editor for a POST, Enter in
// a body paragraph is refused (each editor owns one block) with the notice "Add
// separate blocks in the Paper canvas instead" — but a post has no Paper canvas;
// the canvas is gated to the paper pane. The editor the user is looking at
// offers "+ Add block", so the notice names that.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const key of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) {
  globalThis[key] = window[key];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const host = document.createElement("bp-paper-editor");
host.block = { id: "p1", type: "paragraph", content: [{ type: "text", value: "Body line" }] };
document.body.appendChild(host);

try {
  const ed = host._editor;
  ed.commands.setTextSelection(ed.state.doc.content.size - 1);
  ed.commands.splitBlock();

  assert.equal(ed.state.doc.childCount, 1, "the split is refused: this editor owns one block");
  const notice = host.querySelector("[data-bp-text-boundary]");
  assert.ok(notice, "the refusal explains itself");
  assert.match(notice.textContent, /\+ Add block/, "the notice names the control on screen");
  assert.doesNotMatch(notice.textContent, /Paper canvas/, "a non-paper document has no Paper canvas to send the user to");

  console.log("PASS one_block_notice: Enter in a one-block editor points at + Add block");
} finally {
  host.remove();
  dom.window.close();
}
