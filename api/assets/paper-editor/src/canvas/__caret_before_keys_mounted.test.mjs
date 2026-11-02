// __caret_before_keys_mounted.test.mjs — task-ae6d3d056711b076 in jsdom: a key pressed
// before ProseMirror has read a click's caret (it reads it on selectionchange) acts on
// the clicked caret, not on the one before the click. The click is a DOM caret moved
// without a selectionchange; the key is a keydown on the editor. It also pins what the
// fix stands on: prosemirror-view's view.domObserver.flush (an internal), that a
// composing keydown reads nothing, and that ProseMirror's 20 ms focus resync does not
// put the old caret back. The real-key half is src/__caret_before_keys_keys.mjs.
// Run: node src/canvas/__caret_before_keys_mounted.test.mjs   (or: npm test)
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
async function scene(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}

const p = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });

async function mount(blocks) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("editable", "true");
  canvas.blocks = blocks;
  document.body.appendChild(canvas);
  await tick(350);
  return canvas;
}

const lines = (editor) => {
  const out = [];
  editor.state.doc.forEach((node) => out.push(node.textContent));
  return out;
};
const textOf = (view, text) => [...view.dom.querySelectorAll("p")].find((el) => el.textContent === text).firstChild;
const key = (view, init) => {
  const event = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  if (init.keyCode) Object.defineProperty(event, "keyCode", { value: init.keyCode });
  view.dom.dispatchEvent(event);
};

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

await scene("prosemirror-view still has view.domObserver.flush, which the canvas reads a click's caret through", async () => {
  const canvas = await mount([p("p-a", "Alpha")]);
  try {
    const observer = canvas._editor.view.domObserver;
    assert.equal(typeof observer?.flush, "function",
      "prosemirror-view dropped view.domObserver.flush: canvas/caret-before-keys.js, _flushDomSelection and setRemoteSelections read the DOM caret through it and now silently read nothing; find its replacement before upgrading");
  } finally {
    canvas.remove();
  }
});

await scene("Enter after a click ProseMirror has not read yet splits at the clicked caret, and the next letter goes there", async () => {
  const canvas = await mount([p("p-a", "Alpha"), p("p-b", "Beta")]);
  try {
    const editor = canvas._editor, view = editor.view;
    view.dom.focus();
    editor.commands.setTextSelection(1);
    view.domObserver.flush();
    window.getSelection().collapse(textOf(view, "Beta"), 4);
    assert.equal(editor.state.selection.from, 1, "the click is still unread when the key goes down");
    key(view, { key: "Enter", keyCode: 13 });
    assert.deepEqual(lines(editor), ["Alpha", "Beta", ""], "the split is at the end of Beta");
    editor.commands.insertContent("x");
    assert.deepEqual(lines(editor), ["Alpha", "Beta", "x"]);
  } finally {
    canvas.remove();
  }
});

await scene("a composing keydown reads nothing (keyCode 229, isComposing, view.composing); the next plain key does", async () => {
  const canvas = await mount([p("p-a", "Alpha"), p("p-b", "Beta")]);
  try {
    const editor = canvas._editor, view = editor.view;
    view.dom.focus();
    editor.commands.setTextSelection(1);
    view.domObserver.flush();
    let reads = 0;
    const flush = view.domObserver.flush;
    view.domObserver.flush = function counted(...args) { reads += 1; return flush.apply(this, args); };
    window.getSelection().collapse(textOf(view, "Beta"), 2);
    key(view, { key: "Process", keyCode: 229 });
    key(view, { key: "a", isComposing: true });
    view.input.composing = true;
    key(view, { key: "b" });
    view.input.composing = false;
    assert.equal(reads, 0, "no read while composing");
    assert.equal(editor.state.selection.from, 1, "the caret is where ProseMirror had it");
    key(view, { key: "Shift", keyCode: 16 });
    assert.equal(reads >= 1, true, "a plain key reads the DOM caret");
    assert.equal(editor.state.selection.$from.parent.textContent, "Beta");
  } finally {
    canvas.remove();
  }
});

await scene("Enter on the click that focuses the canvas (focus, then the caret, as in Chrome): the split is at the clicked caret, and the 20 ms focus resync leaves it there", async () => {
  const canvas = await mount([p("p-a", "Alpha"), p("p-b", "Beta")]);
  try {
    const editor = canvas._editor, view = editor.view;
    view.dom.blur();
    editor.commands.setTextSelection(1);
    const held = holdingResync(() => view.dom.focus());
    assert.equal(held.length > 0, true, "focus queued ProseMirror's resync");
    window.getSelection().collapse(textOf(view, "Beta"), 4);
    key(view, { key: "Enter", keyCode: 13 });
    for (const fire of held) fire();
    view.domObserver.flush();
    assert.deepEqual(lines(editor), ["Alpha", "Beta", ""]);
    assert.equal(editor.state.selection.from, editor.state.doc.content.size - 1, "the caret is on the new line");
    const at = window.getSelection().focusNode;
    assert.equal((at.nodeType === 1 ? at : at.parentElement).closest("p") === view.dom.lastElementChild, true, "the DOM caret is on the new line too");
  } finally {
    canvas.remove();
  }
});

if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\ncaret before keys mounted: all checks passed");
process.exit(0);
