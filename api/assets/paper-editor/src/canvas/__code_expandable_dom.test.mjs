import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const jsdom = new JSDOM("<!doctype html><body></body>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = jsdom;
for (const name of [
  "CustomEvent",
  "document",
  "Event",
  "HTMLElement",
  "KeyboardEvent",
  "MutationObserver",
  "Node",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });

const { Code } = await import("./code-node.js");
const { Expandable } = await import("./expandable-node.js");

function mount(extension, attrs) {
  const current = { type: { name: extension.name }, attrs, nodeSize: 1 };
  const editor = {
    isEditable: true,
    state: { doc: { nodeAt: () => current } },
    chain: () => ({ command() { return this; }, run: () => true }),
  };
  const view = extension.config.addNodeView()({ node: current, editor, getPos: () => 0 });
  document.body.appendChild(view.dom);
  return view;
}

const codeValue = "def hello do\n  :world\nend";
const code = mount(Code, { value: codeValue, lang: "elixir" });
assert.equal(code.dom.tagName, "PRE");
assert.ok(code.dom.classList.contains("bp-codeblock"), "the mounted root carries the reader class");
assert.equal(code.dom.getAttribute("style"),
  "border:0;border-radius:var(--bp-codeblock-radius, 0);padding:var(--bp-codeblock-pad, 0.9rem 1.1rem);margin:var(--bp-codeblock-margin, 1.2rem 0);font-family:var(--paper-font-mono, ui-monospace,Menlo,monospace);font-size:var(--bp-codeblock-size, 0.9rem);line-height:var(--bp-codeblock-lh, 1.5);overflow-x:auto;white-space:pre");
assert.equal(code.dom.querySelector(":scope > textarea.bp-canvas-code-area")?.value, codeValue,
  "the direct edit island is the authoritative reader text after chrome removal");
assert.ok(code.dom.querySelector(":scope > input.bp-canvas-code-lang"), "the language input remains mounted");
assert.ok(code.dom.querySelector(":scope > code.bp-canvas-code-hl"), "the highlight layer remains mounted");
code.update({ type: { name: Code.name }, attrs: { value: "next", lang: "  js  " } });
assert.equal(code.dom.querySelector(":scope > textarea.bp-canvas-code-area").value, "next");
assert.equal(code.dom.getAttribute("data-lang"), "js", "reader language metadata follows updates");

const expandable = mount(Expandable, { summary: "Show the full trace", open: false });
assert.equal(expandable.dom.tagName, "DETAILS");
assert.ok(expandable.dom.classList.contains("bp-expandable"));
assert.equal(expandable.dom.open, true, "the authoring body remains expanded");
const summary = expandable.dom.querySelector(":scope > summary");
assert.ok(summary, "the summary is the native direct child of details");
assert.equal(summary.querySelector("input[data-test-id='paper-expandable-summary']")?.value,
  "Show the full trace", "the existing summary input remains the edit island");
assert.equal(expandable.contentDOM, expandable.dom.querySelector(":scope > .bp-expandable__body"));
assert.equal(expandable.stopEvent({ target: summary }), true,
  "native summary folding is isolated from ProseMirror");
expandable.dom.open = false;
expandable.update({ type: { name: Expandable.name }, attrs: { summary: "Updated", open: false } });
assert.equal(expandable.dom.open, false, "a local native fold survives an attribute repaint");
assert.equal(summary.querySelector("input").value, "Updated");

for (const view of [code, expandable]) {
  view.destroy?.();
  view.dom.remove();
}
window.close();

console.log("canvas code and expandable use reader-native production roots: ok");
