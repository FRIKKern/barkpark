// __link_pill_mounted.test.mjs — contract 1.14.0: on a block-cards canvas the link card is
// Sanity's annotation pill. It follows the caret (not the pointer): a caret in a link shows it
// above the link, labelled with the annotation's schema title ("Link", or Sanity's start-cased
// "Internal Link" for a document link), with Edit and Remove, and Open for a document link
// only; Remove drops the link in one step. Without block-cards the hover card is unchanged.
// Run: node src/canvas/__link_pill_mounted.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement",
  "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Option", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const { TextSelection } = await import("@tiptap/pm/state");
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "See the " }, { type: "link", href: "https://example.com/docs", children: [{ type: "text", value: "docs" }] }, { type: "text", value: " here." }] },
  { id: "p2", type: "paragraph", content: [{ type: "text", value: "By " }, { type: "wikilink", target: "author-ada", docId: "author-ada", children: [{ type: "text", value: "Ada" }] }, { type: "text", value: " today." }] },
];
async function mount({ cards = true, vocab } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  if (cards) canvas.setAttribute("block-cards", "");
  if (vocab) canvas.setAttribute("data-vocabulary", JSON.stringify(vocab));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  document.body.appendChild(canvas);
  await tick(350);
  return { canvas, editor: canvas._editor, batches };
}
const caretIn = (editor, word) => {
  let at = null;
  editor.state.doc.descendants((n, pos) => { if (at == null && n.isText && n.text.includes(word)) at = pos + n.text.indexOf(word) + 1; return at == null; });
  editor.commands.focus();
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
};
const pill = () => [...document.querySelectorAll(".bp-link-pill")].find((p) => p.style.display !== "none") || null;

{
  const { canvas, editor, batches } = await mount();
  caretIn(editor, "docs");
  await tick(20);
  const p = pill();
  assert.ok(p, "a caret in a link shows the pill");
  assert.equal(p.querySelector(".bp-link-pill__label").textContent, "Link", "named by the annotation's title");
  assert.equal(p.querySelector(".bp-link-preview__open").style.display, "none", "a plain link has no Open");
  assert.equal(p.querySelector(".bp-link-preview__edit").getAttribute("aria-label"), "Edit annotation");
  assert.equal(p.querySelector(".bp-link-preview__remove").getAttribute("aria-label"), "Remove annotation");
  assert.equal(p.querySelector(".bp-link-preview__remove").title, "Remove annotation", "with a tooltip");

  caretIn(editor, "Ada");
  await tick(20);
  assert.equal(pill().querySelector(".bp-link-pill__label").textContent, "Internal Link", "a document link: Sanity's start-cased name");
  const open = pill().querySelector(".bp-link-preview__open");
  assert.notEqual(open.style.display, "none", "a document link has Open (D06)");
  assert.equal(open.getAttribute("aria-label"), "Open");
  assert.equal(open.title, "Open");

  caretIn(editor, "today");
  await tick(20);
  assert.equal(pill(), null, "out of the link, the pill goes");

  // Hover does not show it (it follows the caret).
  canvas._linkPreview._handleOver({ target: editor.view.dom.querySelector("a[href]") });
  await tick(400);
  assert.equal(pill(), null, "no hover pill");
  assert.equal(document.querySelector(".bp-link-preview")?.style.display !== "block", true, "and no hover card");

  // Remove drops the link in one step.
  caretIn(editor, "docs");
  await tick(20);
  batches.length = 0;
  pill().querySelector(".bp-link-preview__remove").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  canvas.flushPendingChanges();
  await tick(50);
  assert.equal(editor.view.dom.querySelector("a[href]"), null, "the link is gone");
  assert.ok(editor.view.dom.textContent.includes("See the docs here."), "its words stay");
  assert.equal(batches.flat().length, 1, "one patch");
  canvas.remove();
}

{
  // A schema title names it.
  const { canvas, editor } = await mount({ vocab: { styles: ["normal"], annotations: [{ name: "link", title: "Web address" }, { name: "wikilink" }] } });
  caretIn(editor, "docs");
  await tick(20);
  assert.equal(pill().querySelector(".bp-link-pill__label").textContent, "Web address");
  canvas.remove();
}

{
  // Without block-cards: no pill on the caret; the hover card as before.
  const { canvas, editor } = await mount({ cards: false });
  caretIn(editor, "docs");
  await tick(20);
  assert.equal(pill(), null, "no pill without block-cards");
  assert.equal(canvas._linkPreview.showFor(editor.view.dom.querySelector("a[href]")), true);
  assert.equal(document.querySelector(".bp-link-preview").style.display, "block", "the hover card shows");
  canvas.remove();
}

console.log("link pill: ok");
