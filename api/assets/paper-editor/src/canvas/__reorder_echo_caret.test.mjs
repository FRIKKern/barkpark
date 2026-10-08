// __reorder_echo_caret.test.mjs — task-b2abe773242241f8: a REORDERED document
// that lands while the author is typing (the host re-setting `blocks` after its
// save, or an idle server apply) keeps the caret in the block it was in. Before,
// the whole-doc replace dropped it at offset 0 of the first block — after a
// "Move up" that is the moved callout, so Enter and "/" went into the callout.
// Run: node src/canvas/__reorder_echo_caret.test.mjs
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
const { TextSelection } = await import("@tiptap/pm/state");
const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const callout = { id: "c-1", type: "callout", tone: "note", content: [{ type: "text", value: "Note body" }] };
let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

async function mounted(blocks) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  return { root, canvas };
}

// Put the caret at the END of block `id` and focus the editor.
function caretAtEnd(canvas, id) {
  const { state, view } = canvas._editor;
  const pos = canvas._topLevelPos(id);
  const node = state.doc.nodeAt(pos);
  view.focus();
  view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, pos + node.nodeSize - 1)));
}

function caretBlock(canvas) {
  const { $head } = canvas._editor.state.selection;
  return { id: $head.node(1)?.attrs?.bpId, offset: $head.parentOffset };
}

try {
  for (const [label, apply] of [
    ["host re-sets blocks", (canvas, blocks) => { canvas.blocks = blocks; }],
    ["idle server apply", (canvas, blocks) => canvas.applyServerBlocksIfIdle(blocks)],
  ]) {
    const { root, canvas } = await mounted([para("p-a", "Alpha"), callout, para("p-b", "Beta tail")]);
    caretAtEnd(canvas, "p-a");
    check(`${label}: setup — caret at the end of the paragraph`, () => {
      assert.deepEqual(caretBlock(canvas), { id: "p-a", offset: 5 });
    });
    // "Move up": the callout now sits first; the echo/host data carries that order.
    apply(canvas, JSON.parse(JSON.stringify([callout, para("p-a", "Alpha"), para("p-b", "Beta tail")])));
    check(`${label}: the caret stays at the end of the paragraph after the reorder lands`, () => {
      assert.deepEqual(caretBlock(canvas), { id: "p-a", offset: 5 });
    });
    root.remove();
  }
} finally {
  dom.window.close();
}
if (failures) { console.log(`${failures} failure(s)`); process.exit(1); }
console.log("reorder echo keeps the caret passed");
