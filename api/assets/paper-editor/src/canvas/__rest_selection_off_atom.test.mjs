// __rest_selection_off_atom.test.mjs — task-f24549dea0618da2, in a real mounted canvas:
// a doc whose first block is a bound field atom (field-string title) must not rest with a
// NodeSelection on it — the first keystroke after a click that never reached the editor
// state replaced the bound title. After mount, after a server update and after a third
// mount in one page the selection is a text cursor, and typing keeps every block.
// Run: node src/canvas/__rest_selection_off_atom.test.mjs
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
const { NodeSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const BLOCKS = [
  { id: "st-title", type: "field-string", label: "Title", value: "Story one" },
  { id: "st-kicker", type: "paragraph", content: [{ type: "text", value: "Kicker" }] },
  { id: "st-p2", type: "paragraph", content: [{ type: "text", value: "Body" }] },
];
async function mount() {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "mounted");
  return canvas;
}
const ids = (editor) => { const out = []; editor.state.doc.forEach((n) => out.push(n.attrs.bpId)); return out; };
let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

try {
  let canvas;
  for (let n = 1; n <= 3; n++) {
    if (canvas) canvas.closest(".bp-paper-editor").remove();
    canvas = await mount();
    check(`mount ${n}: the canvas does not rest with the bound title node-selected`, () => {
      assert.ok(!(canvas._editor.state.selection instanceof NodeSelection), canvas._editor.state.selection.toJSON().type);
    });
  }
  const editor = canvas._editor;
  canvas.applyServerBlocksIfIdle([{ ...BLOCKS[0], value: "Story one (edited in Classic)" }, BLOCKS[1], BLOCKS[2]]);
  await tick(50);
  check("after a server update the selection is still a text cursor", () => {
    assert.ok(!(editor.state.selection instanceof NodeSelection));
  });
  editor.commands.insertContent(" X");
  check("typing at rest keeps the bound title block", () => {
    assert.deepEqual(ids(editor).slice(0, 1), ["st-title"]);
    assert.ok(ids(editor).includes("st-p2"));
  });
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nrest selection: all checks passed");
  process.exit(0);
}
