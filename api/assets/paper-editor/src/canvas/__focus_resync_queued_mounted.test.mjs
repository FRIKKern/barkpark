// __focus_resync_queued_mounted.test.mjs — the same race as
// __focus_resync_keeps_caret_mounted, with the DOM caret already away from the canvas's
// caret when focus lands (as after a click or Tab), so every prosemirror-view version
// queues the resync. A move after focus must survive it; with no move, the canvas's caret
// ends where it was (jsdom shows that end state only: the resync's own write is masked by
// the flush, so this check does not pin it). On focus, prosemirror-view queues a 20 ms
// timer that writes its own selection over the DOM when the two differ. Under fast
// input Chrome runs key events first, so the timer can fire after an ArrowUp moved the
// DOM caret but before selectionchange told ProseMirror: the old caret came back and
// End+Backspace edited the wrong line (Barkever j06-plan "nested only",
// task-8ee0303670720913). The test holds that timer and lets it fire after the move.
// Run: node src/canvas/__focus_resync_queued_mounted.test.mjs   (or: npm test)
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

const RESYNC_MS = 20;
function holdingResync(run) {
  const held = [];
  const real = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms, ...args) => (ms === RESYNC_MS ? (held.push(() => fn(...args)), 0) : real(fn, ms, ...args));
  try {
    run();
  } finally {
    globalThis.setTimeout = real;
  }
  return held;
}
const lineOf = (node) => (node.nodeType === 1 ? node : node.parentElement).closest("p")?.textContent ?? null;

async function focusAwayThen(move) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("editable", "true");
  canvas.blocks = [
    { id: "p1", type: "paragraph", content: [{ type: "text", value: "x" }] },
    { id: "p2", type: "paragraph", content: [{ type: "text", value: "Buy packing tape" }] },
  ];
  document.body.appendChild(canvas);
  await tick(350);
  const editor = canvas._editor;
  const view = editor.view;
  view.dom.blur();
  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  const [above, below] = [...view.dom.querySelectorAll("p")].map((p) => p.firstChild);
  window.getSelection().collapse(below, 0);
  const held = holdingResync(() => view.dom.focus());
  move(view, above);
  for (const fire of held) fire();
  view.domObserver.flush();
  const out = { queued: held.length, dom: lineOf(window.getSelection().focusNode), canvas: editor.state.selection.$head.parent.textContent, offset: window.getSelection().focusOffset };
  canvas.remove();
  return out;
}

try {
  const moved = await focusAwayThen((view, above) => {
    view.dom.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }));
    window.getSelection().collapse(above, 1);
  });
  check("focus with the DOM caret elsewhere queued ProseMirror's resync", () => assert.equal(moved.queued > 0, true));
  check("a move after focus: the DOM caret stays on the line ArrowUp moved it to", () => assert.equal(moved.dom, "x"));
  check("a move after focus: the canvas's caret is there too", () => assert.equal(moved.canvas, "x"));
  const still = await focusAwayThen(() => {});
  check("no move after focus: the caret ends where the canvas had it (end of the second line)", () => assert.deepEqual([still.dom, still.offset], ["Buy packing tape", 16]));
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nfocus resync queued mounted: all checks passed");
  process.exit(0);
}
