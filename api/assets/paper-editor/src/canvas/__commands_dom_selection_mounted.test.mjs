// __commands_dom_selection_mounted.test.mjs — a toolbar command acts on the selection
// the author sees. ProseMirror takes a DOM selection change on selectionchange, a
// task later; run/can/state read the pending DOM selection first, so a press right
// after Shift+Arrow covers the whole selection (barkpark-studio CI bolded "." of "1.";
// task-ee29b37ca1c6139d).
// Run: node src/canvas/__commands_dom_selection_mounted.test.mjs   (or: npm test)
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
  canvas.blocks = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "Body paragraph for post 1." }] }];
  document.body.appendChild(canvas);
  await tick(350);
  const editor = canvas._editor;
  editor.view.focus();
  const text = editor.view.dom.querySelector("p").firstChild;
  const len = text.data.length;
  // The caret at the end, as ProseMirror knows it.
  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  // The author extends it by two characters in the DOM; no selectionchange has run yet.
  window.getSelection().setBaseAndExtent(text, len, text, len - 2);

  check("state() reports the DOM selection, not the stale one", () => {
    assert.equal(canvas.state().selection.empty, false);
  });
  check("toggleMark covers the whole DOM selection", () => {
    assert.equal(canvas.toggleMark("strong"), true);
    const strong = [];
    editor.state.doc.descendants((n) => { if (n.isText && n.marks.some((m) => m.type.name === "bold")) strong.push(n.text); });
    assert.deepEqual(strong, ["1."]);
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ncommands dom selection mounted: all checks passed");
  process.exit(0);
}
