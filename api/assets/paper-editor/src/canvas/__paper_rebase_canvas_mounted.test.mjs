// task-e0987185b4de61e3 — the canvas side of the concurrent-edit rebase: whether
// an in-flight batch, or a draft not yet sent, can ride on a newer version of the
// run that another session stored (a different paragraph: yes; the same one: no).
// Run: node src/canvas/__paper_rebase_canvas_mounted.test.mjs

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

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const BLOCKS = [para("p1", "one"), para("p2", "two"), para("p3", "three")];

async function mount() {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail));
  return { canvas, batches };
}

// Type at the end of paragraph p3 (the third top-level block).
function typeInLast(canvas, text) {
  const editor = canvas._editor;
  let end = 0;
  editor.state.doc.forEach((node, offset, index) => { if (index === 2) end = offset + node.nodeSize - 1; });
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, end)));
  editor.view.dispatch(editor.state.tr.insertText(text));
}

const theirsOther = [para("p1", "ONE"), para("p2", "two"), para("p3", "three")];
const theirsSame = [para("p1", "one"), para("p2", "two"), para("p3", "THREE")];

try {
  {
    const { canvas, batches } = await mount();
    typeInLast(canvas, "!");
    canvas.flushPendingChanges();
    const seq = batches[0] && batches[0].seq;
    await check("the in-flight batch rebases over a peer edit to another paragraph", () => {
      assert.ok(seq != null, "a batch was dispatched with a seq");
      assert.equal(canvas.rebaseSafe(seq, theirsOther), true);
    });
    await check("it does not rebase over a peer edit to the same paragraph", () => {
      assert.equal(canvas.rebaseSafe(seq, theirsSame), false);
    });
    await check("a stale sequence is never rebased", () => {
      assert.equal(canvas.rebaseSafe(seq + 1, theirsOther), false);
    });
    canvas.closest(".bp-paper-editor").remove();
  }
  {
    const { canvas } = await mount();
    typeInLast(canvas, "?");
    await check("an unsent draft rides over a peer edit to another paragraph", () => {
      assert.equal(canvas.localEditsRebaseSafe(theirsOther), true);
    });
    await check("an unsent draft conflicts with a peer edit to the same paragraph", () => {
      assert.equal(canvas.localEditsRebaseSafe(theirsSame), false);
    });
    canvas.closest(".bp-paper-editor").remove();
  }
} catch (error) {
  failures += 1;
  console.log(`FAIL  harness: ${error.stack}`);
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall paper rebase canvas checks passed");
process.exit(0);
