// __field_binding_mounted.test.mjs — contract 1.13.0: on a canvas whose host sets
// data-field-caps (its type's Expectation, {fieldName: max|null}), a BOUND field block
// shows LiveView Beta's binding: the n/max badge (is-at-cap when full) and an unbind x
// that makes it a free block in one patch-block {fieldName: null}, undone in one step.
// The count follows the other blocks; without the attribute nothing shows; a read-only
// canvas offers no unbind.
// Run: node src/canvas/__field_binding_mounted.test.mjs   (or: npm test)
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

const BLOCKS = [
  { id: "t1", type: "field-string", label: "Title", fieldName: "title", value: "Hello" },
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Free." }] },
  { id: "k1", type: "field-string", label: "Kicker", fieldName: "kicker", value: "News" },
  { id: "k2", type: "field-string", label: "Kicker", fieldName: "kicker", value: "More" },
  { id: "f1", type: "field-string", label: "Loose", value: "free field" },
];

function mount({ caps = '{"title":1,"kicker":3}', editable = true } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  if (caps) canvas.setAttribute("data-field-caps", caps);
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  document.body.appendChild(canvas);
  return { canvas, batches };
}
const fieldOf = (canvas, id) => canvas._editor.view.nodeDOM(canvas._topLevelPos(id));
const binding = (canvas, id) => fieldOf(canvas, id).querySelector(".bp-canvas-field-binding");

const { canvas, batches } = mount();
await tick(350);
assert.equal(binding(canvas, "t1").hidden, false, "a bound block shows its binding");
assert.equal(binding(canvas, "t1").querySelector(".bp-canvas-field-badge").textContent, "1/1");
assert.ok(binding(canvas, "t1").querySelector(".bp-canvas-field-badge").classList.contains("is-at-cap"), "1/1 is at its cap");
assert.equal(binding(canvas, "k1").querySelector(".bp-canvas-field-badge").textContent, "2/3", "the count is every block bound to the name");
assert.equal(binding(canvas, "f1").hidden, true, "a free field block shows none");
const unbind = binding(canvas, "k2").querySelector(".bp-canvas-field-unbind");
assert.equal(unbind.getAttribute("aria-label"), "Unbind property");

batches.length = 0;
unbind.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
canvas.flushPendingChanges();
await tick(50);
assert.deepEqual(batches.flat(), [{ op: "patch-block", id: "k2", patch: { fieldName: null } }], "unbind is one patch-block {fieldName: null}");
assert.equal(binding(canvas, "k2").hidden, true, "the unbound block is free: no binding");
assert.equal(fieldOf(canvas, "k2").querySelector("input").value, "More", "its value stays");
assert.equal(binding(canvas, "k1").querySelector(".bp-canvas-field-badge").textContent, "1/3", "the other block's count follows");
assert.equal(canvas.undo(), true, "one undo step");
await tick(50);
assert.equal(binding(canvas, "k2").hidden, false, "brings the binding back");
assert.equal(binding(canvas, "k1").querySelector(".bp-canvas-field-badge").textContent, "2/3");
canvas.remove();

const plain = mount({ caps: null });
await tick(350);
assert.equal(binding(plain.canvas, "t1").hidden, true, "without data-field-caps nothing shows (D01)");
plain.canvas.remove();

const ro = mount({ editable: false });
await tick(350);
assert.equal(binding(ro.canvas, "t1").hidden, false);
assert.equal(binding(ro.canvas, "t1").querySelector(".bp-canvas-field-unbind").hidden, true, "a read-only canvas offers no unbind");
ro.canvas.remove();

console.log("field binding: ok");
