// __field_block_focus.test.mjs — task-13abe9408c006c96, in a real mounted canvas:
// focusBlock(id) on a canvas field block (an atom whose node view holds its own
// control) focuses that control; on a divider (no control) it does not.
// Run: node src/canvas/__field_block_focus.test.mjs
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

await import("./index.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const BLOCKS = [
  { id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] },
  { id: "f-str", type: "field-string", label: "Title", value: "" },
  { id: "f-sel", type: "field-select", label: "Kind", value: "", options: ["a", "b"] },
  { id: "f-bool", type: "field-boolean", label: "Ready", value: false },
  { id: "d-1", type: "divider" },
];
let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

try {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const blockDom = (id) => canvas._editor.view.nodeDOM(canvas._topLevelPos(id));
  for (const [id, tag] of [["f-str", "INPUT"], ["f-sel", "SELECT"], ["f-bool", "INPUT"]]) {
    const placed = canvas.focusBlock(id);
    const active = document.activeElement;
    check(`focusBlock(${id}) focuses the field's own control`, () => {
      assert.equal(placed, true);
      assert.equal(active && active.tagName, tag, active && active.outerHTML.slice(0, 80));
      assert.ok(blockDom(id).contains(active), "the control inside that block's node view");
    });
  }
  canvas.focusBlock("p-a");
  canvas.focusBlock("d-1");
  check("focusBlock on a divider focuses no control", () => {
    const active = document.activeElement;
    assert.ok(!["INPUT", "SELECT", "TEXTAREA", "BUTTON"].includes(active && active.tagName), active && active.tagName);
  });
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nfield block focus: all checks passed");
  process.exit(0);
}
