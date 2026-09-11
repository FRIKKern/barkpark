import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { tiptapToBlock } from "../convert.js";
import "../__paragraph_carriers.test.mjs";

const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("../index.js");

const source = { id: "p", type: "paragraph", text: "Legacy paragraph", audit: { keep: true } };
for (const mode of ["canvas", "single"]) {
  const host = document.createElement(mode === "canvas" ? "bp-paper-canvas" : "bp-paper-editor");
  const ops = [];
  if (mode === "canvas") {
    host.blocks = [source];
    host.addEventListener("bp-canvas-ops", e => ops.push(...e.detail.ops));
  } else {
    host.block = source;
    host.addEventListener("bp-op", e => ops.push(e.detail));
  }
  document.body.appendChild(host);
  try {
    const editor = host._editor;
    assert.equal(editor.getText(), source.text);
    assert.doesNotMatch(editor.getHTML(), /bpParagraphSource|audit/);
    editor.commands.setTextSelection({ from: 1, to: source.text.length + 1 });
    editor.commands.insertContent("Changed paragraph");
    host.flushPendingChanges();
    assert.deepEqual(ops.at(-1).patch, { text: "Changed paragraph" });
    assert.equal(editor.commands.undo(), true);
    assert.deepEqual(tiptapToBlock(editor.getJSON(), "p", "paragraph"), { text: source.text });
    if (mode === "canvas") {
      editor.commands.setTextSelection(7);
      editor.commands.splitBlock();
      const nodes = editor.getJSON().content;
      assert.deepEqual(tiptapToBlock({ content: [nodes[0]] }, "p", "paragraph"), { text: "Legacy" });
      assert.deepEqual(tiptapToBlock({ content: [nodes[1]] }, null, "paragraph"), { text: " paragraph" });
      host.flushPendingChanges();
      const inserted = ops.find(op => op.op === "insert-after");
      assert.ok(inserted, "native split emits a new block rather than overwriting the original");
    }
  } finally { host.remove(); }
}
dom.window.close();
console.log("mounted paragraph carrier editing and split preservation passed");
