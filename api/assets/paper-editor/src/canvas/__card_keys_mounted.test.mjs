// __card_keys_mounted.test.mjs — a selected card's keys on a block-cards canvas, as Sanity's
// Portable Text editor (cards sweep 2026-10-19): ArrowDown/Up go card to card with no extra
// stop; Enter opens a new paragraph after the card (no dialog); Delete removes it and leaves
// the caret at the end of the text before. Without block-cards, Enter still edits an object block.
// Run: node src/canvas/__card_keys_mounted.test.mjs   (or: npm test)
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

const { NodeSelection, TextSelection } = await import("@tiptap/pm/state");
const VOCAB = {
  styles: ["normal"],
  of: ["image", { name: "callout", title: "Callout", fields: [{ name: "tone", type: "string" }, { name: "text", type: "text" }] }],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Before." }] },
  { id: "i1", type: "image", src: "/w/a/p/default/media/files/d/ds/2026/10/pic-cbf5348f.png", alt: "A picture" },
  { id: "co1", type: "callout", tone: "info", content: [{ type: "text", value: "A custom block." }] },
  { id: "p2", type: "paragraph", content: [{ type: "text", value: "After." }] },
];
async function mount(cards = true) {
  const canvas = document.createElement("bp-paper-canvas");
  if (cards) canvas.setAttribute("block-cards", "");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  document.body.appendChild(canvas);
  await tick(350);
  return { canvas, view: canvas._editor.view, batches };
}
const key = (view, k) => view.someProp("handleKeyDown", (f) => f(view, new window.KeyboardEvent("keydown", { key: k })));
const selectAt = (canvas, view, id) => view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, canvas._topLevelPos(id))));
const selectedId = (view) => (view.state.selection instanceof NodeSelection ? view.state.selection.node.attrs.bpId : null);

{
  const { canvas, view, batches } = await mount();
  selectAt(canvas, view, "i1");
  assert.equal(key(view, "ArrowDown"), true, "ArrowDown from the image is handled");
  assert.equal(selectedId(view), "co1", "and selects the callout next to it: no stop between two cards");
  assert.ok(!key(view, "ArrowDown"), "from the last card, ArrowDown is ProseMirror's (to the text after)");
  assert.equal(key(view, "ArrowUp"), true);
  assert.equal(selectedId(view), "i1", "ArrowUp goes back to the image");

  // Enter on a selected card: a new paragraph after it, the caret in it, no dialog.
  selectAt(canvas, view, "co1");
  batches.length = 0;
  assert.equal(key(view, "Enter"), true, "Enter on a selected card is handled");
  const sel = view.state.selection;
  assert.ok(sel instanceof TextSelection && sel.empty, "a caret");
  assert.equal(sel.$from.parent.type.name, "paragraph");
  assert.equal(sel.$from.parent.textContent, "", "in a new, empty paragraph");
  assert.equal(sel.$from.index(0), view.state.doc.childCount - 2, "right after the callout");
  assert.equal(document.querySelector(".bp-inline-object-dialog, [role=dialog]"), null, "no dialog opened");
  assert.equal(canvas.undo(), true, "one undo takes it back");

  // Delete on a selected card: gone, the caret at the end of the text before.
  selectAt(canvas, view, "i1");
  batches.length = 0;
  assert.equal(key(view, "Delete"), true);
  canvas.flushPendingChanges();
  await tick(50);
  assert.deepEqual(batches.flat(), [{ op: "remove-block", id: "i1" }], "one remove-block");
  const after = view.state.selection;
  assert.ok(after instanceof TextSelection && after.empty, "a caret");
  assert.equal(after.$from.parent.textContent, "Before.", "in the paragraph before");
  assert.equal(after.$from.parentOffset, "Before.".length, "at its end");
  canvas.remove();
}

{
  // Without block-cards nothing changes: the keys are ProseMirror's and the canvas's own.
  const { canvas, view } = await mount(false);
  selectAt(canvas, view, "i1");
  assert.ok(!view.someProp("handleKeyDown", (f) => (f.name === "handleKeyDown" ? f(view, new window.KeyboardEvent("keydown", { key: "ArrowDown" })) : false)), "no card keys without block-cards");
  selectAt(canvas, view, "co1");
  key(view, "Enter");
  assert.ok(document.querySelector(".bp-inline-object-dialog, [role=dialog]"), "Enter still edits an object block there");
  document.querySelector(".bp-inline-object-dialog, [role=dialog]")?.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  canvas.remove();
}

console.log("card keys: ok");
