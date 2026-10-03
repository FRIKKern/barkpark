// Mounted regression: the host's post-mount seed (`canvas.blocks = …`, which is
// how the Studio hook hands a run to an already-connected canvas) is the run's
// STARTING POINT, not an edit. It must not enter the user's undo history.
//
// Found live (r4-lane-c dogfood, real Chrome): open any paper, click into the
// body, press Cmd+Z before typing anything — the undo inverts the seed's
// whole-document replace back to the empty pre-seed doc, ProseMirror throws
// `RangeError: Invalid content for node doc: <>`, and any edit undone in the
// same keystroke burst never reaches the server (the view shows it undone, a
// reload brings it back).

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

const errors = [];
window.addEventListener("error", (event) => errors.push(event.error || event.message));

// Mount EMPTY, then seed — the order the Studio hook uses.
const canvas = document.createElement("bp-paper-canvas");
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  // The seed is not an edit, so it must not emit an editor update: an update
  // schedules a save. tiptap 3 made setContent emit by default, so the seed
  // passes { emitUpdate: false } explicitly.
  let seedUpdates = 0;
  const countUpdate = () => { seedUpdates += 1; };
  canvas._editor.on("update", countUpdate);
  canvas.blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "Seeded one." }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "Seeded two." }] },
  ];
  await new Promise((resolve) => setTimeout(resolve, 50));
  canvas._editor.off("update", countUpdate);
  assert.equal(seedUpdates, 0, "the post-mount seed emits no editor update");

  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap editor is mounted");
  assert.equal(editor.state.doc.textContent, "Seeded one.Seeded two.");

  assert.equal(editor.can().undo(), false,
    "the post-mount seed is not an undoable step — nothing has been edited yet");

  let undone;
  assert.doesNotThrow(() => { undone = editor.commands.undo(); },
    "Cmd+Z on an untouched run must not invert the seed into an empty doc");
  assert.equal(undone, false);
  assert.equal(editor.state.doc.textContent, "Seeded one.Seeded two.",
    "the seeded content survives an undo with nothing to undo");

  // A real edit is still undoable, and undoing it stops at the seed.
  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  editor.commands.insertContent(" Typed.");
  assert.equal(editor.state.doc.textContent, "Seeded one.Seeded two. Typed.");
  assert.equal(editor.commands.undo(), true, "a real edit is undoable");
  assert.equal(editor.state.doc.textContent, "Seeded one.Seeded two.");
  assert.doesNotThrow(() => editor.commands.undo(), "a second undo stops at the seed");
  assert.equal(editor.state.doc.textContent, "Seeded one.Seeded two.");

  assert.deepEqual(errors, [], "no uncaught editor errors");
  console.log("PASS seed_history: the post-mount seed stays out of undo history");
} finally {
  canvas.remove();
  dom.window.close();
}
