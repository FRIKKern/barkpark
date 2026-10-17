// __image_card_mounted.test.mjs — contract 1.11.0 `block-cards`, in a real mounted canvas:
// an image block is a card as Sanity's block object. Its head names the file (a Barkpark
// media URL loses its 8-hex suffix), and its … menu offers Edit (the image's own inputs)
// and Remove (the block out, one `remove-block`). A read-only canvas shows no menu.
// Run: node src/canvas/__image_card_mounted.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
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

const { imageFileName } = await import("./image-node.js");
await import("./index.js");
const tick = (ms = 25) => new Promise((resolve) => setTimeout(resolve, ms));

assert.equal(imageFileName("/w/a/p/default/media/files/d/ds/2026/10/fixture-image-cbf5348f.png", "x"), "fixture-image.png",
  "a Barkpark media URL shows the uploaded name, without the 8-hex suffix");
assert.equal(imageFileName("https://example.com/pics/My%20photo-cbf5348f.jpg?w=200#x", null), "My photo-cbf5348f.jpg",
  "another URL shows its last segment, decoded, and keeps what looks like a suffix");
assert.equal(imageFileName(null, "paste-image"), "paste-image", "an upload in flight shows its alt");
assert.equal(imageFileName("blob:http://localhost/1", null), "Image", "no name at all: Image");

const SRC = "/w/a/p/default/media/files/d/ds/2026/10/fixture-image-cbf5348f.png";
function mount(editable = true) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("block-cards", "");
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.blocks = [
    { id: "p1", type: "paragraph", content: [{ type: "text", value: "Start." }] },
    { id: "i1", type: "image", src: SRC, alt: "A picture" },
    { id: "p2", type: "paragraph", content: [{ type: "text", value: "After." }] },
  ];
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  document.body.appendChild(canvas);
  return { canvas, batches };
}

const { canvas, batches } = mount();
await tick();
const card = canvas.querySelector('[data-test-id="paper-image"]');
assert.ok(card, "the image block is mounted");
assert.equal(card.querySelector(".bp-canvas-image-name").textContent, "fixture-image.png", "the head names the file");
const more = card.querySelector(".bp-canvas-image-more");
assert.equal(more.hidden, false, "an editable card offers its menu");
assert.equal(more.getAttribute("aria-haspopup"), "menu");
assert.equal(more.getAttribute("aria-label"), "Open menu", "Sanity's label, not the block handle's Block options");

// Edit: the image's own inputs, the caret in its alt.
more.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
let menu = document.querySelector(".bp-canvas-image-menu");
assert.ok(menu, "the … opens a menu");
assert.equal(more.getAttribute("aria-expanded"), "true");
assert.deepEqual([...menu.querySelectorAll("[role=menuitem]")].map((b) => b.textContent), ["Edit", "Remove"],
  "Edit and Remove, as Sanity's block object menu");
assert.equal(document.activeElement, menu.querySelector("[data-action=edit]"), "the first item takes the focus");
menu.querySelector("[data-action=edit]").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.equal(document.querySelector(".bp-canvas-image-menu"), null, "a pick closes the menu");
assert.equal(document.activeElement, card.querySelector(".bp-canvas-image-alt"), "Edit puts the caret in the alt text");
assert.ok(card.classList.contains("bp-canvas-image--focused"), "and shows the inputs (CSS keeps them shut otherwise)");

// A click on the head selects the card, as Sanity's.
card.querySelector(".bp-canvas-image-name").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.ok(card.classList.contains("ProseMirror-selectednode"), "a click on the head selects the card");

// Escape closes the menu and gives the focus back to the button.
more.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
menu = document.querySelector(".bp-canvas-image-menu");
menu.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
assert.equal(document.activeElement, menu.querySelector("[data-action=remove]"), "ArrowDown moves to Remove");
menu.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
assert.equal(document.querySelector(".bp-canvas-image-menu"), null, "Escape closes it");
assert.equal(document.activeElement, more, "and the focus is back on the …");

// Remove: the block goes, one remove-block.
batches.length = 0;
more.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
document.querySelector(".bp-canvas-image-menu [data-action=remove]").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
canvas.flushPendingChanges();
await tick();
assert.equal(canvas.querySelector('[data-test-id="paper-image"]'), null, "Remove takes the image out");
assert.deepEqual(batches.flat(), [{ op: "remove-block", id: "i1" }], "as one remove-block");
assert.equal(canvas.undo(), true, "one undo step");
assert.ok(canvas.querySelector('[data-test-id="paper-image"]'), "brings it back");
canvas.remove();

// Read-only: the name, no menu.
const ro = mount(false);
await tick();
assert.equal(ro.canvas.querySelector(".bp-canvas-image-name").textContent, "fixture-image.png");
assert.equal(ro.canvas.querySelector(".bp-canvas-image-more").hidden, true, "a read-only card has no menu");
ro.canvas.remove();

console.log("image card: ok");
