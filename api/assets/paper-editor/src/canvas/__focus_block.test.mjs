// Mounted regression: focusBlock(id) puts the caret in a top-level block, so an
// EMPTY paragraph the host just added (Add block, the Ingress ghost) opens
// instead of resting collapsed. Found live (r4-lane-c dogfood): clicking the
// Ingress ghost or "+ Add block → Paragraph" created the block server-side, the
// canvas painted it as a hidden resting scaffold, focus stayed on the button,
// and everything typed next went nowhere.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
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
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");

const text = (value) => [{ type: "text", value }];
const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [
  { id: "p-1", type: "paragraph", content: text("First.") },
  { id: "p-empty", type: "paragraph", content: [] },
];
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

const blockAtCaret = (editor) => {
  const { $from } = editor.state.selection;
  return $from.depth >= 1 ? $from.node(1).attrs.bpId : null;
};

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap editor is mounted");

  assert.equal(typeof canvas.focusBlock, "function", "the canvas exposes focusBlock(id)");

  // 1. A block already in the run: the caret lands inside it.
  assert.equal(canvas.focusBlock("p-empty"), true);
  assert.equal(blockAtCaret(editor), "p-empty", "the caret sits in the requested block");

  // 2. A block that has not arrived yet: remembered, then focused on the next
  //    external apply (the host's run update lands after the request).
  assert.equal(canvas.focusBlock("p-new"), false, "an absent block is not focused yet");
  canvas.blocks = [
    { id: "p-1", type: "paragraph", content: text("First.") },
    { id: "p-empty", type: "paragraph", content: [] },
    { id: "p-new", type: "paragraph", content: [] },
  ];
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(blockAtCaret(canvas._editor), "p-new",
    "the remembered block is focused once it arrives");

  // 3. Unknown / blank ids are a calm no-op.
  assert.equal(canvas.focusBlock(""), false);
  assert.equal(canvas.focusBlock(null), false);

  // 4. Focusing never edits: no ops, no undo step.
  assert.equal(canvas._editor.can().undo(), false, "focusing adds no history entry");
  await new Promise((resolve) => setTimeout(resolve, 900));
  assert.deepEqual(batches, [], "focusing emits no ops");

  console.log("PASS focus_block: the caret lands in a new block, now or on arrival");
} finally {
  canvas.remove();
  dom.window.close();
}
