// Mounted editing regression: exercise ProseMirror's real DOM paste handler,
// then TipTap history commands, before flushing the resulting PortableDoc op.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const expectedOps = JSON.parse(readFileSync(new URL(
  "../../../../test/support/fixtures/paper-editor/paste-redo-ops.json",
  import.meta.url,
), "utf8"));

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

await import("./index.js");

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [{
  id: "paragraph-1",
  type: "paragraph",
  content: [{ type: "text", value: "Start " }],
}];
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;

  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap editor is mounted");
  assert.equal(editor.commands.setTextSelection(editor.state.doc.content.size - 1), true);

  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: {
      types: ["text/html", "text/plain"],
      files: [],
      getData: (type) => {
        if (type === "text/html") return "<strong>Bold</strong> and <em>italic</em>";
        if (type === "text/plain") return "Bold and italic";
        return "";
      },
    },
  });
  assert.equal(editor.view.dom.dispatchEvent(paste), false,
    "ProseMirror's mounted clipboard handler consumes the paste event");
  assert.equal(editor.state.doc.textContent, "Start Bold and italic");

  assert.equal(editor.commands.undo(), true, "the actual paste is one undoable history step");
  assert.equal(editor.state.doc.textContent, "Start ");
  assert.equal(editor.commands.redo(), true, "redo restores the pasted slice");
  assert.equal(editor.state.doc.textContent, "Start Bold and italic");
  assert.equal(batches.length, 0, "the normal debounce has not emitted before explicit flush");

  assert.equal(canvas.flushPendingChanges(), true);
  assert.deepEqual(batches, [expectedOps],
    "flush emits the canonical redone paste with its text and marks intact");
  assert.equal(canvas.flushPendingChanges(), false, "a second flush is a no-op");

  console.log("mounted paste, undo, redo, and flush payload regression passed");
} finally {
  canvas.remove();
  window.close();
}
