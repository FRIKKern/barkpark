// __object_card_mounted.test.mjs — contract 1.12.0 `block-cards`: a declared object block
// (the body's callout) is a card as Sanity's block object: a tile with Sanity's
// DocumentIcon, its preview title, and a "…" (Open menu) whose menu offers Edit (the
// block's own dialog) and Remove (one remove-block, one undo step); a click selects it.
// selectBlock(id) selects a card; text typed onto a selected card keeps it. A read-only
// canvas opens no menu.
// Run: node src/canvas/__object_card_mounted.test.mjs   (or: npm test)
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

const VOCAB = {
  styles: ["normal"],
  of: [{ name: "callout", title: "Callout", fields: [{ name: "tone", type: "string" }, { name: "text", type: "text" }] }],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro." }] },
  { id: "co1", type: "callout", tone: "info", content: [{ type: "text", value: "A custom block." }] },
];

function mount(editable = true) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("block-cards", "");
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  document.body.appendChild(canvas);
  return { canvas, batches };
}

const { canvas, batches } = mount();
await tick(350);
const row = canvas.querySelector('[data-object-type="callout"]');
assert.ok(row && row.classList.contains("bp-canvas-object-row"), "the declared callout is an object row");
assert.ok(row.querySelector(".bp-canvas-object-media svg.bp-canvas-object-doc"), "a tile with Sanity's DocumentIcon");
assert.equal(row.querySelector(".bp-canvas-object-preview").textContent, "info", "its preview title");
assert.equal(row.getAttribute("aria-label"), "Callout · info", "its name still reads Title · value");
const more = row.querySelector(".bp-canvas-object-more");
assert.equal(more.getAttribute("aria-label"), "Open menu");

more.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
let menu = document.querySelector(".bp-canvas-object-menu");
assert.ok(menu, "the … opens a menu");
assert.deepEqual([...menu.querySelectorAll("[role=menuitem]")].map((b) => b.textContent), ["Edit", "Remove"]);
menu.querySelector("[data-action=edit]").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.equal(document.querySelector(".bp-canvas-object-menu"), null, "a pick closes it");
const dialog = document.querySelector(".bp-inline-object-dialog, [role=dialog]");
assert.ok(dialog, "Edit opens the block's own dialog");
dialog.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
await tick(50);

row.querySelector(".bp-canvas-object-preview").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.ok(row.classList.contains("ProseMirror-selectednode"), "a click selects the card");

// selectBlock: the card, as a click selects it; not a text block.
assert.equal(canvas.selectBlock("p1"), false, "a text block is not a card");
assert.equal(canvas.selectBlock("co1"), true);
assert.ok(row.classList.contains("ProseMirror-selectednode"), "selectBlock selects the card");
// Typing onto the selected card keeps it (no remove-block for one key).
batches.length = 0;
{
  const view = canvas._editor.view;
  const { from, to } = view.state.selection;
  const handled = view.someProp("handleTextInput", (f) => f(view, from, to, "x"));
  if (!handled) view.dispatch(view.state.tr.insertText("x", from, to));
  canvas.flushPendingChanges();
  await tick(50);
  assert.ok(canvas.querySelector('[data-object-type="callout"]'), "a key typed onto the selected card keeps it");
  assert.ok(!batches.flat().some((o) => o.op === "remove-block"), "no remove-block");
}

batches.length = 0;
more.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
document.querySelector(".bp-canvas-object-menu [data-action=remove]").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
canvas.flushPendingChanges();
await tick(50);
assert.equal(canvas.querySelector('[data-object-type="callout"]'), null, "Remove takes it out");
assert.deepEqual(batches.flat(), [{ op: "remove-block", id: "co1" }], "as one remove-block");
assert.equal(canvas.undo(), true, "one undo step");
assert.ok(canvas.querySelector('[data-object-type="callout"]'), "brings it back");
canvas.remove();

const ro = mount(false);
await tick(350);
ro.canvas.querySelector(".bp-canvas-object-more").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.equal(document.querySelector(".bp-canvas-object-menu"), null, "a read-only card opens no menu");
ro.canvas.remove();

console.log("object card: ok");
