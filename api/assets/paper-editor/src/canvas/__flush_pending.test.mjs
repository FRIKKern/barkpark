// Mounted regression for the edit -> view save boundary. The public flush seam
// must synchronously emit rich-text input that is still inside the 300 ms debounce,
// and must commit Markdown source input before the element can be disconnected.

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

const { BpPaperEditor } = await import("../index.js");
const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);
assert.equal(customElements.get("bp-paper-editor"), BpPaperEditor);

const paragraph = (id, value) => ({
  id,
  type: "paragraph",
  content: [{ type: "text", value }],
});

function mountCanvas(id, value) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [paragraph(id, value)];
  document.body.appendChild(canvas);
  return canvas;
}

const rich = mountCanvas("rich-1", "Before");
const richBatches = [];
rich.addEventListener("bp-canvas-ops", (event) => richBatches.push(event.detail.ops));

const source = mountCanvas("source-1", "Original");
const sourceBatches = [];
source.addEventListener("bp-canvas-ops", (event) => sourceBatches.push(event.detail.ops));

const legacy = document.createElement("bp-paper-editor");
legacy.block = paragraph("legacy-1", "Legacy before");
const legacyOps = [];
legacy.addEventListener("bp-op", (event) => legacyOps.push(event.detail));
document.body.appendChild(legacy);

try {
  // Let any mount-time normalization settle so only deliberate user edits remain.
  await new Promise((resolve) => setTimeout(resolve, 350));
  richBatches.length = 0;
  sourceBatches.length = 0;
  legacyOps.length = 0;

  rich._editor.commands.focus("end");
  rich._editor.view.dispatch(
    rich._editor.state.tr.insertText(" final typed text"),
  );

  assert.equal(richBatches.length, 0, "the edit is still inside the debounce window");
  assert.equal(rich.flushPendingChanges(), true, "flush reports an emitted rich batch");
  assert.equal(richBatches.length, 1, "the final rich text emits synchronously");
  assert.deepEqual(richBatches[0], [{
    op: "patch-block",
    id: "rich-1",
    patch: { content: [{ type: "text", value: "Before final typed text" }] },
  }]);
  assert.equal(rich.flushPendingChanges(), false, "a repeated rich flush is a no-op");
  assert.equal(richBatches.length, 1, "a repeated rich flush emits no duplicate batch");

  source.toggleSourceMode();
  const textarea = source.querySelector(".bp-canvas-source");
  assert.ok(textarea, "source mode mounts the real Markdown textarea");
  textarea.value = "Source mode final text";
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));

  assert.equal(sourceBatches.length, 0, "source input is local until explicitly flushed");
  assert.equal(source.flushPendingChanges(), true, "flush reports an emitted source batch");
  assert.deepEqual(sourceBatches, [[{
    op: "patch-block",
    id: "source-1",
    patch: { content: [{ type: "text", value: "Source mode final text" }] },
  }]], "the source edit emits synchronously with its original block id");
  assert.equal(source._mode, "rich", "flush commits source text into the live rich document");
  assert.equal(source.querySelector(".bp-canvas-source"), null, "the source textarea is consumed");
  assert.equal(
    source._editor.getJSON().content[0].content[0].text,
    "Source mode final text",
    "the committed source edit survives in the mounted editor",
  );
  assert.equal(source.flushPendingChanges(), false, "a repeated source flush is a no-op");
  assert.equal(sourceBatches.length, 1, "a repeated source flush emits no duplicate batch");

  legacy._editor.commands.focus("end");
  legacy._editor.view.dispatch(
    legacy._editor.state.tr.insertText(" final typed text"),
  );
  assert.equal(legacyOps.length, 0, "the legacy edit is still inside its debounce window");
  assert.equal(legacy.flushPendingChanges(), true, "legacy flush reports an emitted patch");
  assert.equal(legacyOps.length, 1, "legacy final text emits synchronously");
  assert.equal(legacyOps[0].id, "legacy-1");
  assert.deepEqual(legacyOps[0].patch.content, [
    { type: "text", value: "Legacy before final typed text" },
  ]);
  assert.equal(legacy.flushPendingChanges(), false, "a repeated legacy flush is a no-op");
  assert.equal(legacyOps.length, 1, "a repeated legacy flush emits no duplicate patch");

  console.log("mounted pending-change flush regression passed");
} finally {
  rich.remove();
  source.remove();
  legacy.remove();
  window.close();
}
