// __object_block_row_mounted.test.mjs — a declared object block is drawn as Sanity's
// block object row: full width (.bp-canvas-object-row, [data-object-type]), an icon,
// the kind title and a preview line, each its own element a host can style. Its
// text and accessible name still read "Title · value"; an edit repaints the row;
// an undeclared carried block keeps the plain "↪ type" chip.
// Run: node src/canvas/__object_block_row_mounted.test.mjs   (or: npm test)
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
  of: [{ name: "factBox", title: "Faktaboks", fields: [{ name: "body", title: "Body", type: "text" }, { name: "tone", type: "string" }] }],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro." }] },
  { id: "fb1", type: "factBox", body: "Old fact.", tone: "info" },
  { id: "fb2", type: "factBox" },
  { id: "c1", type: "composite", parts: [] },
];
let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}

try {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  document.body.appendChild(canvas);
  await tick(350);
  const editor = canvas._editor;
  const domOf = (id) => editor.view.nodeDOM(canvas._topLevelPos(id));

  check("a declared object block is a row: icon, title and preview as separate elements", () => {
    const row = domOf("fb1");
    assert.ok(row.classList.contains("bp-canvas-object-row"));
    assert.equal(row.getAttribute("data-object-type"), "factBox");
    const chip = row.querySelector(".bp-canvas-readonly-chip");
    assert.equal(chip.querySelector(".bp-canvas-object-icon").getAttribute("aria-hidden"), "true");
    assert.equal(chip.querySelector(".bp-canvas-object-title").textContent, "Faktaboks");
    assert.equal(chip.querySelector(".bp-canvas-object-preview").textContent, "Old fact.");
  });

  check("its text and name still read 'Title · value'", () => {
    assert.equal(domOf("fb1").querySelector(".bp-canvas-readonly-chip").textContent, "Faktaboks · Old fact.");
    assert.equal(domOf("fb1").getAttribute("aria-label"), "Faktaboks · Old fact.");
  });

  check("an empty one shows the title alone, no preview line", () => {
    const chip = domOf("fb2").querySelector(".bp-canvas-readonly-chip");
    assert.equal(chip.querySelector(".bp-canvas-object-preview"), null);
    assert.equal(chip.textContent, "Faktaboks");
  });

  check("an edit repaints the row", () => {
    const pos = canvas._topLevelPos("fb1");
    const node = editor.state.doc.nodeAt(pos);
    editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...node.attrs, bpBlock: { ...node.attrs.bpBlock, body: "New fact." } }));
    assert.equal(domOf("fb1").querySelector(".bp-canvas-object-preview").textContent, "New fact.");
  });

  check("an undeclared carried block keeps the plain chip", () => {
    const dom = domOf("c1");
    assert.ok(!dom.classList.contains("bp-canvas-object-row"));
    assert.equal(dom.getAttribute("data-object-type"), null);
    assert.equal(dom.querySelector(".bp-canvas-readonly-chip").textContent, "↪ composite");
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nobject block row mounted: all checks passed");
  process.exit(0);
}
