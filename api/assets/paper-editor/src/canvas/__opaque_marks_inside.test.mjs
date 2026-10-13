// __opaque_marks_inside.test.mjs — task-87c8c9503e4f6028, in the mounted canvas.
// Run: node src/canvas/__opaque_marks_inside.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
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
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("../index.js");
const { docToBlocks } = await import("./run-convert.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
// A word whose flat mark is keyed `_type` (not `type`), and an inline code leaf
// carrying its own marks. #22209 kept both through a load and an edit elsewhere;
// typing INSIDE them re-serialized the leaf and dropped those marks
// (task-87c8c9503e4f6028).
const UNDERSCORE = { type: "text", value: "Ibsen", marks: [{ _type: "smallcaps" }] };
const CODE = { type: "code", value: "mix test", marks: [{ type: "annotation", attrs: { id: "a2" } }] };
const P = {
  id: "p1",
  type: "paragraph",
  content: [{ type: "text", value: "Read " }, UNDERSCORE, { type: "text", value: " and " }, CODE, { type: "text", value: "." }],
};
let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message.split("\n")[0]}`); } }

const root = document.createElement("div");
root.className = "bp-paper-editor";
const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = JSON.parse(JSON.stringify([P]));
root.appendChild(canvas);
document.body.appendChild(root);
await tick(350);
const editor = canvas._editor;
const start = canvas._topLevelPos("p1") + 1;

async function typeAt(offset, text) {
  const ops = [];
  const on = (e) => ops.push(...(e.detail.ops || []));
  canvas.addEventListener("bp-canvas-ops", on);
  editor.chain().setTextSelection(start + offset).insertContent(text).run();
  canvas.flushPendingChanges();
  await tick(50);
  canvas.removeEventListener("bp-canvas-ops", on);
  if (canvas._inflightOps) canvas.acknowledgeOps(canvas._inflightOps.seq, true);
  const patch = ops.find((op) => op.id === "p1");
  return (patch && patch.patch && patch.patch.content) || [];
}

// "Read " is 5 characters: "Ib|sen" is offset 7.
let content = await typeAt(7, "x");
check("typing inside a _type-keyed marked word keeps the mark", () => {
  const leaf = content.find((n) => n.value === "Ibxsen");
  assert.ok(leaf, JSON.stringify(content));
  assert.deepEqual(leaf.marks, [{ _type: "smallcaps" }], JSON.stringify(leaf));
});

// "Read Ibxsen and " is 16 characters: "mix |test" is offset 20.
content = await typeAt(20, "y");
check("typing inside an inline code leaf keeps the leaf's own marks", () => {
  const leaf = content.find((n) => n.type === "code");
  assert.ok(leaf, JSON.stringify(content));
  assert.deepEqual(leaf, { type: "code", value: "mix ytest", marks: [{ type: "annotation", attrs: { id: "a2" } }] });
});
check("the earlier word keeps its mark through the second edit", () => {
  const leaf = content.find((n) => n.value === "Ibxsen");
  assert.ok(leaf && JSON.stringify(leaf.marks) === JSON.stringify([{ _type: "smallcaps" }]), JSON.stringify(content));
});

canvas.remove();
if (failures) { console.log(`${failures} failing`); process.exit(1); }
console.log("opaque_marks_inside: ok");
process.exit(0);
