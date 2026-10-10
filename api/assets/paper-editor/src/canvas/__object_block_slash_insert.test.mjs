// Mounted regression (task-96fce87b7b71c288): a field canvas whose vocabulary
// declares a custom object block (`{name, fields}` in blocks.of) inserts it from
// the slash menu, and the insert reaches the server as a block of that type.

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
// Typing "/" opens the slash menu, which scrolls its active row (jsdom has no layout).
window.HTMLElement.prototype.scrollIntoView ||= () => {};

await import("../index.js");

const canvas = document.createElement("bp-paper-canvas");
canvas.setAttribute(
  "data-vocabulary",
  JSON.stringify({
    styles: ["normal"],
    of: [{ name: "factBox", title: "Faktaboks", fields: [{ name: "body", type: "text" }] }],
  }),
);
canvas.blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "Intro." }] }];
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap editor is mounted");

  // A "/" line under the intro, as after typing "/fakt".
  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  editor.commands.splitBlock();
  editor.commands.insertContent("/fakt");
  const before = editor.state.doc.childCount;

  canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
  // A declared object block with fields asks for them first (task-aebfe6c1b3c3f881).
  const dialog = document.querySelector(".bp-inline-object-dialog");
  assert.ok(dialog, "the field dialog opened");
  dialog.querySelector('[data-field="body"]').value = "Fakta.";
  dialog.querySelector("form").dispatchEvent(new window.Event("submit", { cancelable: true }));

  let carried = null;
  editor.state.doc.forEach((node) => {
    if (node.type.name === "bpOpaque" && node.attrs.bpType === "factBox") carried = node;
  });
  assert.ok(carried, "the declared object block is in the run (the vocabulary veto let it in)");
  assert.equal(editor.state.doc.childCount, before, "it REPLACED the slash line");
  assert.ok(!editor.state.doc.textContent.includes("/fakt"), "the slash line is gone");

  assert.equal(canvas.flushPendingChanges(), true);
  const ops = batches.flat();
  const insert = ops.find((op) => op.block && op.block.type === "factBox");
  assert.ok(insert, `the insert reaches the server as a factBox block: ${JSON.stringify(ops)}`);
  assert.equal(insert.block.body, "Fakta.", "the dialog's value rides the insert");
  assert.equal(typeof insert.block.id, "string");

  console.log("PASS object_block_slash_insert: a declared object block inserts as a block of its type");
} finally {
  canvas.remove();
  dom.window.close();
}
