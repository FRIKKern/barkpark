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

  // Chronicle-shaped run: editing the lead must not rewrite the title, byline,
  // neighboring body or opaque metadata. Exercise history before the debounce.
  const chronicle = document.createElement("bp-paper-canvas");
  const blocks = [
    { id: "title", type: "heading", level: 1, text: "The month in review", qa: { keep: true } },
    { id: "lead", type: "ingress", content: [{ type: "text", value: "Lead " }], qa: { keep: "lead" } },
    { id: "byline", type: "byline", items: ["Barkpark", "August 2026"] },
    { id: "body", type: "paragraph", content: [{ type: "text", value: "Unchanged body." }] },
  ];
  chronicle.blocks = structuredClone(blocks);
  const leadBatches = [];
  chronicle.addEventListener("bp-canvas-ops", (event) => leadBatches.push(event.detail.ops));
  document.body.appendChild(chronicle);
  try {
    await new Promise((resolve) => setTimeout(resolve, 350));
    assert.deepEqual(leadBatches, [], "mounting the Chronicle does not rewrite authored content");
    const leadEditor = chronicle._editor;
    const leadEnd = leadEditor.state.doc.firstChild.nodeSize + 1 + "Lead ".length;
    leadEditor.commands.setTextSelection(leadEnd);
    leadEditor.commands.insertContent({ type: "text", text: "proof", marks: [{ type: "bold" }] });
    assert.equal(leadEditor.commands.undo(), true);
    assert.equal(leadEditor.state.doc.child(1).textContent, "Lead ");
    assert.equal(leadEditor.commands.redo(), true);
    assert.equal(leadEditor.state.doc.child(1).textContent, "Lead proof");
    assert.equal(chronicle.flushPendingChanges(), true);
    assert.equal(leadBatches.length, 1);
    assert.equal(leadBatches[0].length, 1, "only the edited introduction is patched");
    const [patch] = leadBatches[0];
    assert.equal(patch.op, "patch-block");
    assert.equal(patch.id, "lead");
    assert.deepEqual(Object.keys(patch.patch), ["content"], "unknown metadata is not overwritten");
    assert.deepEqual(patch.patch.content, [
      { type: "text", value: "Lead " },
      { type: "strong", children: [{ type: "text", value: "proof" }] },
    ]);
    assert.equal(chronicle.flushPendingChanges(), false, "immediate second flush cannot duplicate edits");
  } finally {
    chronicle.remove();
  }

  for (const [type, hint] of Object.entries({
    eyebrow: "Add a kicker…", byline: "Add names, separated by · …",
    ingress: "Write the introduction…", pullquote: "Write the highlighted quote…",
  })) {
    const empty = document.createElement("bp-paper-canvas");
    empty.blocks = [{ id: `empty-${type}`, type, content: [], text: "", items: [] }];
    document.body.appendChild(empty);
    try {
      assert.equal(empty.querySelector("[data-placeholder]")?.getAttribute("data-placeholder"), hint,
        `${type}: an empty editable line explains its role`);
      assert.equal(empty._editor.state.doc.textContent, "", "the hint is not authored content");
      assert.equal(empty.flushPendingChanges(), false, "showing the hint emits no edit");
    } finally {
      empty.remove();
    }
  }

  console.log("mounted paste, undo, redo, and flush payload regression passed");
} finally {
  canvas.remove();
  window.close();
}
