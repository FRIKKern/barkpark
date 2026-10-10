// Mounted regression: an author can EMBED A SHEET from the canvas.
//
// Found live (r4-lane-c dogfood): "/" → typing "sheet" answered "No blocks match",
// and "+ Add block" offered no sheet either — a sheet embed could only be written
// through the API. A slash/palette "Sheet" now inserts an empty sheet REFERENCE;
// its read-only atom mounts the existing reference picker (the retarget control),
// so the author picks the sheet right on the chip and the server hydrates the
// snapshot on save.

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
globalThis.fetch = async () => ({ ok: true, json: async () => ({ documents: [] }) });
window.fetch = globalThis.fetch;
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");
const { insertSlashTypeAtSelection } = await import("./command-palette.js");
// The block holds the slash's own "/query", so the pick replaces it.
const SLASH_PICK = { replaceText: true };

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "Intro." }] }];
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap editor is mounted");

  // The caret at the end of the paragraph, as after typing "/sheet".
  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  assert.equal(insertSlashTypeAtSelection(editor, "sheet", undefined, SLASH_PICK), true, "Sheet is insertable");

  let sheet = null;
  editor.state.doc.forEach((node) => {
    if (node.attrs?.bpType === "sheet" || node.type.name === "bpSheet") sheet = node;
  });
  assert.ok(sheet, "a sheet node is in the run");

  await new Promise((resolve) => setTimeout(resolve, 50));
  const picker = canvas.querySelector('[data-test-id="paper-sheet-retarget"]');
  assert.ok(picker, "the inserted sheet chip mounts its reference picker, so the author can pick the sheet");

  assert.equal(canvas.flushPendingChanges(), true);
  const ops = batches.flat();
  const insert = ops.find((op) => op.block && op.block.type === "sheet");
  assert.ok(insert, `the insert reaches the server as a sheet block: ${JSON.stringify(ops)}`);
  assert.equal(insert.block.ref, "", "an empty reference, chosen next on the chip");

  console.log("PASS sheet_slash_insert: Sheet inserts an empty reference whose chip mounts the picker");
} finally {
  canvas.remove();
  dom.window.close();
}
