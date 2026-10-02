// Mounted regression for task-a4a6773110a20b23: typing into a freshly hydrated canvas must never
// replace the whole run.
//
// Studio mounts <bp-paper-canvas> empty and assigns `blocks` afterwards. The empty mount starts
// with an AllSelection, and a whole-document setContent maps an AllSelection to itself, so the
// canvas rested with the ENTIRE run selected. Any focus that arrives without a fresh DOM caret
// then typed over the run:
//   - keyboard focus (Tab into the canvas): ProseMirror's focus handler writes the state
//     selection into the DOM, so the whole run is highlighted and the first key replaces it;
//   - a click followed by a key before Chrome delivers the click's selectionchange (about 36 ms
//     headed, measured): ProseMirror's keypress handler sees a non-text selection and inserts
//     over it. A Playwright click + End + type hits this window; the End key itself is inert.
// Either way the batch was remove-block for every block in the run plus one append-block
// holding the typed text.
//
// The gesture below types the way a browser does: keydown, keypress, and, when ProseMirror does
// not take the key, the browser's default insertion at the DOM caret.

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
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
// jsdom has no layout; ProseMirror's scrollToSelection only needs rects to exist.
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });

const { AllSelection } = await import("@tiptap/pm/state");
await import("./index.js");
const { DEBOUNCE_MS } = await import("../contract.js");

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const RUN = [
  { id: "bc-h", type: "heading", level: 1, text: "Canvas end check" },
  { id: "bc-p", type: "paragraph", content: [{ type: "text", value: "Intro paragraph." }] },
];

// Studio's order: mount first, hydrate the run afterwards.
async function mountHydrated() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail));
  document.body.appendChild(canvas);
  await wait(20);
  canvas.blocks = RUN.map((block) => structuredClone(block));
  await wait(20);
  return { canvas, batches, view: canvas._editor.view };
}

function textNodeAtCaret() {
  const sel = window.getSelection();
  let node = sel.focusNode;
  let offset = sel.focusOffset;
  if (node && node.nodeType !== 3) {
    const child = node.childNodes[offset] || node.childNodes[offset - 1];
    if (child && child.nodeType === 3) {
      offset = child === node.childNodes[offset] ? 0 : child.data.length;
      node = child;
    }
  }
  assert.ok(node && node.nodeType === 3, `the DOM caret sits in a text node (focus ${sel.focusNode && sel.focusNode.nodeName}:${sel.focusOffset}, ${sel.focusNode && sel.focusNode.outerHTML || sel.focusNode && sel.focusNode.data})`);
  return { node, offset };
}

async function typeLikeBrowser(view, text) {
  for (const ch of text) {
    const init = { key: ch, keyCode: ch.charCodeAt(0), charCode: ch.charCodeAt(0), bubbles: true, cancelable: true };
    const down = new window.KeyboardEvent("keydown", { ...init, charCode: 0 });
    view.dom.dispatchEvent(down);
    if (down.defaultPrevented) continue;
    const press = new window.KeyboardEvent("keypress", init);
    view.dom.dispatchEvent(press);
    if (press.defaultPrevented) continue;
    const { node, offset } = textNodeAtCaret();
    node.insertData(offset, ch);
    window.getSelection().collapse(node, offset + 1);
    await wait(0);
  }
}

function describe(batches) {
  return JSON.stringify(batches.map((batch) => batch.ops));
}

function assertNothingRemoved(batches, label) {
  const ops = batches.flatMap((batch) => batch.ops);
  assert.ok(ops.length > 0, `${label}: the typing emitted a batch`);
  assert.deepEqual(ops.filter((op) => op.op === "remove-block"), [], `${label}: no block is removed; batches ${describe(batches)}`);
  assert.deepEqual(ops.filter((op) => op.op === "append-block" || op.op === "insert-after"), [], `${label}: no block is added; batches ${describe(batches)}`);
}

let failed = 0;
async function check(name, fn) {
  try { await fn(); console.log(`PASS ${name}`); }
  catch (error) { failed += 1; console.log(`FAIL ${name}\n  ${error.message}`); }
}

await check("a hydrated canvas does not rest with the whole run selected", async () => {
  const { canvas } = await mountHydrated();
  try {
    const selection = canvas._editor.state.selection;
    assert.equal(selection instanceof AllSelection, false, `resting selection is ${JSON.stringify(selection.toJSON())}`);
    assert.equal(selection.empty, true, "the resting selection is a collapsed caret");
  } finally { canvas.remove(); }
});

await check("click at the end of a paragraph, then type before selectionchange: the text lands at the click", async () => {
  const { canvas, batches, view } = await mountHydrated();
  try {
    // The click: Chrome moves the DOM caret and focuses the editor; its selectionchange has not
    // been delivered yet when the first key arrives (the race a fast synthetic driver wins).
    const intro = [...view.dom.querySelectorAll("p")].find((p) => p.textContent === "Intro paragraph.");
    const text = intro.firstChild;
    view.dom.focus();
    window.getSelection().collapse(text, text.data.length);
    await typeLikeBrowser(view, " X");
    await wait(DEBOUNCE_MS + 100);
    assertNothingRemoved(batches, "click-then-type");
    const patches = batches.flatMap((batch) => batch.ops).filter((op) => op.op === "patch-block");
    assert.deepEqual(patches.map((op) => op.id), ["bc-p"], `only the clicked paragraph changes; batches ${describe(batches)}`);
    assert.equal(patches[0].patch.content.map((node) => node.value).join(""), "Intro paragraph. X");
  } finally { canvas.remove(); }
});

await check("Tab into the canvas, then type: nothing is removed and the text lands at the caret", async () => {
  const { canvas, batches, view } = await mountHydrated();
  try {
    window.getSelection().removeAllRanges();
    view.dom.focus();
    // ProseMirror's focus handler writes the state selection into the DOM 20 ms after focus.
    await wait(60);
    assert.equal(window.getSelection().isCollapsed, true, `focus does not highlight the run: "${window.getSelection()}"`);
    await typeLikeBrowser(view, " X");
    await wait(DEBOUNCE_MS + 100);
    assertNothingRemoved(batches, "tab-then-type");
    const blocks = canvas._editor.getJSON().content.map((node) => (node.content || []).map((t) => t.text).join(""));
    assert.deepEqual(blocks, [" XCanvas end check", "Intro paragraph."], "the text lands at the resting caret, the run's start");
  } finally { canvas.remove(); }
});

if (failed) {
  console.log(`${failed} resting-selection check(s) failed`);
  process.exit(1);
}
console.log("PASS resting selection: typing into a hydrated canvas never replaces the run");
process.exit(0);
