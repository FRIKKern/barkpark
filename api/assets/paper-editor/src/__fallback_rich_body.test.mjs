// Mounted regression for fallback (canvas-off) rich bodies. These block types
// intentionally reuse the per-block editor's paragraph conversion: edits must
// emit canonical inline trees with marks/links intact and never leak immutable
// type or callout chrome into the body patch.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});

const { window } = dom;
for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "DOMParser",
  "Element",
  "Event",
  "EventTarget",
  "HTMLElement",
  "KeyboardEvent",
  "MutationObserver",
  "Node",
  "NodeFilter",
  "Selection",
  "Text",
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
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperEditor } = await import("./index.js");

const richInline = [
  {
    type: "link",
    href: "https://example.com/guide",
    children: [
      {
        type: "strong",
        children: [{ type: "text", value: "Read the guide" }],
      },
    ],
  },
  { type: "text", value: " before continuing." },
];

function bodyFor(type) {
  if (type === "list") return { ordered: false, items: [richInline] };
  return { content: richInline };
}

function inlineFromPatch(type, patch) {
  return type === "list" ? patch.items[0] : patch.content;
}

function inlineText(nodes) {
  return (nodes || [])
    .map((node) => node.value || inlineText(node.children))
    .join("");
}

try {
  for (const type of ["callout", "ingress", "pullquote", "blockquote", "list"]) {
    const block = {
      id: `fallback-${type}`,
      type,
      ...bodyFor(type),
    };
    if (type === "callout") {
      Object.assign(block, { tone: "warning", title: "Keep this chrome" });
    }
    if (type === "blockquote") {
      Object.assign(block, { cite: "Keep this attribution", source_note: "Keep metadata" });
    }

    const editor = document.createElement("bp-paper-editor");
    assert.ok(editor instanceof BpPaperEditor);
    editor.block = block;
    let emitted = null;
    editor.addEventListener("bp-op", (event) => {
      emitted = event.detail;
    });
    document.body.appendChild(editor);

    assert.ok(editor._editor, `${type} mounts the real TipTap editor`);
    editor._editor.view.dispatch(editor._editor.state.tr.insertText(" revised", 6));
    assert.equal(editor.flushPendingChanges(), true, `${type} flushes its pending edit`);
    assert.equal(emitted.op, "patch-block");
    assert.equal(emitted.id, block.id);
    assert.equal("type" in emitted.patch, false, `${type} patch excludes immutable type`);
    assert.equal("tone" in emitted.patch, false, `${type} body patch excludes callout chrome`);
    assert.equal("title" in emitted.patch, false, `${type} body patch excludes title chrome`);
    assert.equal("cite" in emitted.patch, false, `${type} body patch excludes attribution`);
    assert.equal("source_note" in emitted.patch, false, `${type} body patch excludes metadata`);

    const inline = inlineFromPatch(type, emitted.patch);
    assert.equal(inline[0].type, "link", `${type} retains the link wrapper`);
    assert.equal(inline[0].href, "https://example.com/guide");
    assert.equal(inline[0].children[0].type, "strong", `${type} retains nested strong`);
    assert.match(inlineText(inline), /revised/, `${type} emits the changed body text`);

    editor.remove();
  }

  console.log("mounted fallback rich-body regression passed");
} finally {
  window.close();
}
