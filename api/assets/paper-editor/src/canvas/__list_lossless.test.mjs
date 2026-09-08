import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { tiptapToBlock } from "../convert.js";
import "../__list_carriers.test.mjs";

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
    single._editor.commands.splitBlock();
    assert.deepEqual(single._editor.getJSON(), initial,
      "a single-block field must not show a second paragraph that its save would drop");
    single._editor.commands.toggleBulletList();
    assert.deepEqual(single._editor.getJSON(), initial,
      "a paragraph field cannot silently become a list that its serializer discards");
  } finally {
    single.remove();
  }
  console.log("mounted list losslessness regression passed");
  for (const tag of ["bp-paper-canvas", "bp-paper-editor"]) {
    const host = document.createElement(tag);
    const source = { id: "carrier-list", type: "list", ordered: false, items: [
      { id: "alpha", content: [{ type: "text", value: "Alpha" }], audit: { keep: 1 } },
      { id: "beta", text: "Beta", audit: { keep: 2 } },
    ] };
    const ops = [];
    if (tag === "bp-paper-canvas") {
      host.blocks = [source];
      host.addEventListener("bp-canvas-ops", e => ops.push(...e.detail.ops));
    } else {
      host.block = source;
      host.addEventListener("bp-op", e => ops.push(e.detail));
    }
    document.body.appendChild(host);
    try {
      const ed = host._editor;
      assert.equal(ed.state.doc.textContent, "AlphaBeta", `${tag}: reader-shaped maps show their text`);
      assert.equal(host.querySelector('[data-bp-list-source]'), null, "source metadata never enters HTML");
      let pos;
      ed.state.doc.descendants((node, at) => { if (node.isText && node.text === "Alpha") pos = at; });
      ed.commands.setTextSelection(pos + 2);
      ed.commands.splitListItem("listItem");
      host.flushPendingChanges();
      const saved = ops.at(-1).patch.items;
      assert.deepEqual(saved, [
        { ...source.items[0], content: [{ type: "text", value: "Al" }] },
        [{ type: "text", value: "pha" }],
        source.items[1],
      ], `${tag}: split retains the original ID once and leaves sibling carriers untouched`);
      assert.equal(ed.commands.undo(), true);
      host.flushPendingChanges();
      assert.deepEqual(tiptapToBlock(ed.getJSON(), source.id, "list").items, source.items,
        `${tag}: undo restores exact source carriers`);
    } finally { host.remove(); }
  }
  console.log("mounted list carrier identity and split preservation passed");
} finally {
  canvas.remove();
  window.close();
}
