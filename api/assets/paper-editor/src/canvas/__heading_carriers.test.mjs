import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { tiptapToBlock } from "../convert.js";
import "../__heading_carriers.test.mjs";

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

const source = { id: "heading", type: "heading", level: 1, content: [{ type: "strong", children: [{ type: "text", value: "Visible title" }] }], text: "stale fallback" };
for (const mode of ["canvas", "single"]) {
  const host = document.createElement(mode === "canvas" ? "bp-paper-canvas" : "bp-paper-editor");
  if (mode === "canvas") host.blocks = [source]; else host.block = source;
  document.body.appendChild(host);
  try {
    const editor = host._editor;
    assert.equal(editor.getText(), "Visible title");
    assert.doesNotMatch(editor.getHTML(), /bpHeadingSource|stale fallback/);
    assert.deepEqual(tiptapToBlock(editor.getJSON(), "heading", "heading"), { level: 1, content: source.content, text: source.text });
    editor.commands.setTextSelection({ from: 1, to: 14 });
    editor.commands.insertContent("Changed title");
    assert.equal(tiptapToBlock(editor.getJSON(), "heading", "heading").content[0].children[0].value, "Changed title");
    assert.equal(editor.commands.undo(), true);
    assert.deepEqual(tiptapToBlock(editor.getJSON(), "heading", "heading"), { level: 1, content: source.content, text: source.text });
  } finally { host.remove(); }
}
dom.window.close();
console.log("mounted canvas and single heading carriers passed");
