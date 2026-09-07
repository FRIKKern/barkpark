import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

for (const path of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(path, import.meta.url), "utf8");
  assert.match(css, /\[data-bp-text-boundary\]\s*\{[^}]*border-inline-start:/,
    "both the standalone editor and the public/Studio shell distinguish the notice from authored prose");
}

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true, url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element",
  "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("../index.js");

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [{ id: "list", type: "list", ordered: false,
  items: [[{ type: "text", value: "Alpha" }], [{ type: "text", value: "Beta" }]],
  metadata: { preserve: true } }];
const batches = [];
canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
document.body.appendChild(canvas);
try {
  const editor = canvas._editor;
  let betaPosition;
  editor.state.doc.descendants((node, pos) => {
    if (node.isText && node.text === "Beta") betaPosition = pos;
  });
  editor.commands.setTextSelection(betaPosition);
  const original = editor.getJSON();
  editor.commands.sinkListItem("listItem");
  assert.deepEqual(editor.getJSON(), original, "unsupported indentation leaves both items intact");
  assert.match(canvas.querySelector('[role="status"]').textContent, /Nested lists/);
  assert.equal(canvas.flushPendingChanges(), false);
  assert.deepEqual(batches, [], "rejected indentation cannot emit a destructive save");

  editor.commands.setHardBreak();
  assert.deepEqual(editor.getJSON(), original, "Shift-Enter's command cannot create a disappearing break");
  assert.match(canvas.querySelector('[role="status"]').textContent, /line breaks/);
  assert.equal(canvas.flushPendingChanges(), false);

  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", { value: {
    types: ["text/html", "text/plain"], files: [],
    getData: type => type === "text/html"
      ? "<ul><li>Parent<ul><li>Child</li></ul></li></ul>" : "Parent\nChild",
  } });
  editor.view.dom.dispatchEvent(paste);
  assert.deepEqual(editor.getJSON(), original, "nested HTML paste is rejected as a whole, never partially saved");
  assert.equal(canvas.flushPendingChanges(), false);

  editor.commands.setTextSelection(betaPosition + 2);
  editor.commands.splitListItem("listItem");
  assert.equal(editor.state.doc.firstChild.childCount, 3, "ordinary Enter still splits list items");
  assert.equal(canvas.querySelector('[data-bp-text-boundary]'), null, "successful edits clear the explanation");
  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(editor.getJSON(), original, "rejected changes never pollute undo history");
  assert.equal(editor.commands.redo(), true);
  assert.equal(canvas.flushPendingChanges(), true);
  assert.deepEqual(batches, [[{ op: "patch-block", id: "list", patch: {
    ordered: false,
    items: [[{ type: "text", value: "Alpha" }], [{ type: "text", value: "Be" }],
      [{ type: "text", value: "ta" }]],
  } }]], "only canonical list fields are saved; opaque metadata is untouched");
  assert.equal(canvas.flushPendingChanges(), false);

  const single = document.createElement("bp-paper-editor");
  single.block = { id: "paragraph", type: "paragraph", content: [{ type: "text", value: "BeforeAfter" }] };
  const singleOps = [];
  single.addEventListener("bp-op", event => singleOps.push(event.detail));
  document.body.appendChild(single);
  try {
    const initial = single._editor.getJSON();
    single._editor.commands.setTextSelection(7);
    single._editor.commands.setHardBreak();
    assert.deepEqual(single._editor.getJSON(), initial, "per-block editing uses the same lossless boundary");
    assert.match(single.querySelector('[role="status"]').textContent, /line breaks/);
    single.flushPendingChanges();
    assert.deepEqual(singleOps, [{ op: "patch-block", id: "paragraph", patch: {
      content: [{ type: "text", value: "BeforeAfter" }],
    } }], "the per-block explicit flush retains the exact original text");
  } finally {
    single.remove();
  }
  console.log("mounted list losslessness regression passed");
} finally {
  canvas.remove();
  window.close();
}
