// __remote_selections_keep_dom_selection_mounted.test.mjs — another person's caret
// arriving must not undo the author's Shift+Arrow. ProseMirror takes a DOM selection
// change on selectionchange, a task later; a setRemoteSelections in between changed
// the decorations, ProseMirror wrote its old selection back over the DOM and the keys
// were lost (barkpark-studio CI: one key lost bolded "." of "1.", two left nothing;
// task-4bef7c60f0791d15).
// Run: node src/canvas/__remote_selections_keep_dom_selection_mounted.test.mjs   (or: npm test)
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
  // Another editor's caret arrives in the same paragraph.
  canvas.setRemoteSelections([{ id: "other", name: "Other", color: "#123456", anchor: { blockId: "p1", offset: 4 }, head: { blockId: "p1", offset: 4 } }]);

  check("the DOM still holds the author's selection", () => {
    assert.equal(window.getSelection().toString(), "1.");
  });
  check("the canvas's selection is the author's", () => {
    const { from, to } = editor.state.selection;
    assert.equal(editor.state.doc.textBetween(from, to), "1.");
  });
  check("the remote caret is painted", () => {
    assert.ok(editor.view.dom.querySelector(".bp-remote-caret"));
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nremote selections keep dom selection mounted: all checks passed");
  process.exit(0);
}
