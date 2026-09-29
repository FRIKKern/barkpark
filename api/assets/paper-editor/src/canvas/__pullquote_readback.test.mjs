// task-7f5c6a3c94ab82cc — typing into a pullquote stored the WHOLE quote wrapped
// in `em`. The pullquote paints the reader's role italic as an inline
// `style="font-style:italic"` on its <p>. When ProseMirror reads its own DOM back
// from above the textblock (which native typing after some clicks does), the
// schema's Italic style rule turned that role styling into an Italic mark.
// Reading the editor's own DOM must reproduce the document it painted; pasted
// HTML must still honour an inline italic style.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver",
  "Node", "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { DOMParser: PMDOMParser } = await import("@tiptap/pm/model");
await import("./index.js");

const text = (value) => ({ type: "text", value });
const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [
  { id: "t-ingress", type: "ingress", content: [text("The lead sets the frame.")] },
  { id: "t-pullquote", type: "pullquote", content: [text("The block is the unit of meaning.")] },
  {
    id: "t-mixed", type: "pullquote",
    content: [text("Plain start, "), { type: "em", children: [text("authored")] }, text(" end.")],
  },
];
document.body.appendChild(canvas);

try {
  const view = canvas._editor.view;
  const quote = view.dom.querySelector('[data-bp-id="t-pullquote"]');
  assert.equal(quote.style.fontStyle, "italic", "the pullquote still paints the reader's role italic");

  // Exactly the parser ProseMirror's readDOMChange uses for its own DOM.
  const readback = view.someProp("domParser") || PMDOMParser.fromSchema(view.state.schema);
  const reread = readback.parse(view.dom);
  const italic = (node) => {
    const found = [];
    node.descendants((child) => {
      if (child.isText && child.marks.some((mark) => mark.type.name === "italic")) found.push(child.text);
    });
    return found;
  };
  assert.deepEqual(italic(reread.child(1)), [],
    "reading the painted pullquote back adds no italic mark");
  assert.deepEqual(italic(reread.child(2)), ["authored"],
    "an authored em inside a pullquote survives the read-back");

  // Pasted HTML keeps the full schema parser: an inline italic span is italic.
  const pasteParser = view.someProp("clipboardParser") || view.someProp("domParser") ||
    PMDOMParser.fromSchema(view.state.schema);
  const holder = document.createElement("div");
  holder.innerHTML = '<p>Docs <span style="font-style:italic">slanted</span> text</p>';
  assert.deepEqual(italic(pasteParser.parse(holder)), ["slanted"],
    "a pasted inline font-style italic still becomes an italic mark");
  console.log("PASS pullquote read-back: role italic stays styling, authored em and pasted italic stay marks");
} finally {
  canvas.remove();
  window.close();
}
