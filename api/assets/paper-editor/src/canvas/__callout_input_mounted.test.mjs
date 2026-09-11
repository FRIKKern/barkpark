import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true, url: "http://localhost/",
});
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

// Exercise the mounted input-rule chain for EACH keystroke, not a whole-string
// insert that bypasses StarterKit's competing quote rule at the first space.
function typeText(editor, text) {
  for (const char of text) {
    const { view, state } = editor;
    const { from, to } = state.selection;
    const handled = view.someProp("handleTextInput", handler => handler(view, from, to, char));
    if (!handled) view.dispatch(state.tr.insertText(char, from, to));
  }
}

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [{ id: "start", type: "paragraph", content: [] }];
const batches = [];
canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
document.body.appendChild(canvas);
try {
  const editor = canvas._editor;
  editor.commands.setTextSelection(1);
  typeText(editor, "> [!note] ");
  assert.equal(editor.state.doc.firstChild.type.name, "callout",
    "typing the standard spaced shorthand must create a supported callout");
  assert.equal(editor.state.doc.firstChild.attrs.tone, "info");
  typeText(editor, "The evidence stays intact.");
  assert.ok(editor.state.doc.textContent.includes("The evidence stays intact."));
  assert.equal(editor.commands.undo(), true);
  assert.equal(editor.commands.redo(), true);
  assert.equal(editor.state.doc.firstChild.type.name, "callout");
  assert.equal(editor.state.doc.textContent, "The evidence stays intact.");
  assert.equal(canvas.flushPendingChanges(), true);
  const inserted = batches.flat().find(op => op.block?.type === "callout");
  assert.ok(inserted, "flush emits the real PortableDoc callout, never an empty native quote");
  assert.deepEqual(inserted.block.content, [{ type: "text", value: "The evidence stays intact." }]);
  assert.equal(inserted.block.tone, "info");
  assert.equal(inserted.block.collapsible, true);
  assert.equal(batches.flat().some(op => op.block?.type === "blockquote"), false);
  console.log("mounted typed callout, undo/redo and lossless save passed");
} finally {
  canvas.remove();
}

try {
  for (const [trigger, tone, collapsed] of [
    ["> [!warning]- ", "warning", true],
    [">[!success]+ ", "success", false],
  ]) {
    const host = document.createElement("bp-paper-canvas");
    host.blocks = [{ id: "origin", type: "paragraph", content: [] }];
    const ops = [];
    host.addEventListener("bp-canvas-ops", event => ops.push(...event.detail.ops));
    document.body.appendChild(host);
    try {
      typeText(host._editor, trigger);
      assert.equal(host._editor.state.doc.firstChild.type.name, "callout");
      assert.equal(host._editor.state.doc.firstChild.attrs.tone, tone);
      assert.equal(host._editor.state.doc.firstChild.attrs.collapsed, collapsed);
      typeText(host._editor, "Preserved body");
      host.flushPendingChanges();
      const block = ops.find(op => op.block?.type === "callout").block;
      assert.deepEqual(block.content, [{ type: "text", value: "Preserved body" }]);
      assert.equal(block.tone, tone);
      assert.equal(block.collapsed === true, collapsed);
    } finally { host.remove(); }
  }

  for (const tag of ["bp-paper-canvas", "bp-paper-editor"]) {
    const host = document.createElement(tag);
    const original = { id: "literal", type: "paragraph", content: [] };
    if (tag === "bp-paper-canvas") host.blocks = [original];
    else host.block = original;
    const ops = [];
    host.addEventListener(tag === "bp-paper-canvas" ? "bp-canvas-ops" : "bp-op",
      event => ops.push(...(event.detail.ops || [event.detail])));
    document.body.appendChild(host);
    try {
      assert.equal(host._editor.commands.toggleBlockquote, undefined,
        "unsupported native quote commands cannot create an empty saved block");
      typeText(host._editor, "> Keep this quote intact");
      assert.equal(host._editor.state.doc.firstChild.type.name, "paragraph");
      host.flushPendingChanges();
      assert.deepEqual(ops, [{ op: "patch-block", id: "literal", patch: {
        content: [{ type: "text", value: "> Keep this quote intact" }],
      } }]);
    } finally { host.remove(); }
  }

  const single = document.createElement("bp-paper-editor");
  single.block = { id: "single", type: "paragraph", content: [] };
  const insertions = [];
  single.addEventListener("bp-slash-insert", event => insertions.push(event.detail));
  document.body.appendChild(single);
  try {
    typeText(single._editor, "> [!warning]- ");
    assert.deepEqual(insertions, [{ type: "callout", afterId: "single",
      tone: "warning", collapsible: true, collapsed: true }]);
    assert.equal(single._editor.state.doc.textContent, "", "trigger is consumed exactly once");
  } finally { single.remove(); }
  console.log("mounted callout variants, literal quote preservation and single-block input passed");
} finally { window.close(); }
