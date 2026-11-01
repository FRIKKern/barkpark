// task-be261d669280dc9e: Enter on an empty line added a block the canvas hid at once
// (an empty top-level paragraph the caret left is a resting scaffold), so six Enters
// showed one line, saved six invisible blocks and took six Backspaces to leave.
//
// Rule (resting-scaffolds.js): Enter never makes two empty prose lines touch at the
// top level. On an empty line it does nothing; at the start of a line under an empty
// one it does nothing; at the end of a line above an empty one it moves the caret
// there. Lists, nested blocks and Shift-Enter keep their Enter.
//
// Mounted: the real <bp-paper-canvas>, real Enter / Shift-Enter / Backspace keydowns,
// typing through handleTextInput, every batch folded through the patch.ex reference
// fold (applyOps); the doc, the visible lines and the saved blocks must agree.
//
// Run: node src/canvas/__enter_empty_line_mounted.test.mjs

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
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const { applyOps } = await import("../smoke/harness.mjs");
const { TextSelection } = await import("@tiptap/pm/state");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const clone = (value) => JSON.parse(JSON.stringify(value));
const p = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });

function lines(editor) {
  const out = [];
  editor.state.doc.descendants((node) => { if (node.isTextblock) out.push(node.textContent); });
  return out;
}
function shown(canvas) {
  return [...canvas._editor.view.dom.children].filter((el) => !el.classList.contains("bp-resting-scaffold") && !el.classList.contains("bp-scaffold-control")).length;
}
function texts(blocks) {
  return blocks.map((block) => (Array.isArray(block.content) ? block.content.map((n) => n.value || "").join("") : block.type));
}
function caretAt(editor, text, offset) {
  let at = null;
  editor.state.doc.descendants((node, pos) => {
    if (at == null && node.isTextblock && node.textContent === text) at = pos + 1 + offset;
  });
  assert.notEqual(at, null, `a line reads "${text}"`);
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
}
function press(editor, key, init = {}) {
  editor.view.dom.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
}
function type(editor, chars) {
  const { view } = editor;
  for (const char of chars) {
    const { from, to } = view.state.selection;
    if (!view.someProp("handleTextInput", (f) => f(view, from, to, char))) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}

async function mount(blocks) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = clone(blocks);
  const state = { server: clone(blocks), batches: 0 };
  canvas.addEventListener("bp-canvas-ops", (event) => {
    state.batches++;
    state.server = applyOps(state.server, event.detail.ops);
    canvas.acknowledgeOps(event.detail.seq, true);
    canvas.applyServerBlocks(clone(state.server), { mode: "own" });
  });
  document.body.appendChild(canvas);
  await tick(350);
  canvas._editor.view.focus();
  return { canvas, editor: canvas._editor, state };
}
async function saved(canvas) {
  canvas.flushPendingChanges();
  await tick(350);
}

let failures = 0;
async function scene(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

const RUN = [p("p-a", "Alpha"), p("p-b", "Beta")];
const GAP = [p("p-a", "Alpha"), p("p-e", ""), p("p-b", "Beta")];

await scene("six Enters at the end of a line: one empty line in the doc, on screen and saved; one Backspace leaves it", async () => {
  const { canvas, editor, state } = await mount(RUN);
  try {
    caretAt(editor, "Alpha", 5);
    for (let i = 0; i < 6; i++) press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "", "Beta"], "one empty line in the doc");
    assert.equal(shown(canvas), 3, "and on screen");
    assert.deepEqual(texts(state.server), ["Alpha", "", "Beta"], "and saved");
    press(editor, "Backspace");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "Beta"], "one Backspace leaves the empty line");
    assert.deepEqual(texts(state.server), ["Alpha", "Beta"]);
    assert.equal(editor.state.selection.$from.parent.textContent, "Alpha", "the caret is back on the line above");
  } finally {
    canvas.remove();
  }
});

await scene("six Enters on an empty line: nothing changes and nothing is sent", async () => {
  const { canvas, editor, state } = await mount(GAP);
  try {
    caretAt(editor, "", 0);
    for (let i = 0; i < 6; i++) press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "", "Beta"]);
    assert.equal(state.batches, 0, "no batch");
    assert.equal(shown(canvas), 3, "the empty line holding the caret shows");
    press(editor, "Backspace");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "Beta"], "one Backspace leaves it");
  } finally {
    canvas.remove();
  }
});

await scene("Enter at the start of a line under an empty line does nothing", async () => {
  const { canvas, editor, state } = await mount(GAP);
  try {
    caretAt(editor, "Beta", 0);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "", "Beta"]);
    assert.equal(state.batches, 0);
    type(editor, "Very ");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "Very Beta"], "the caret stayed at the start of Beta");
  } finally {
    canvas.remove();
  }
});

await scene("Enter at the end of a line above an empty line moves the caret into it", async () => {
  const { canvas, editor, state } = await mount(GAP);
  try {
    caretAt(editor, "Alpha", 5);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "", "Beta"], "no new block");
    assert.equal(state.batches, 0);
    assert.equal(shown(canvas), 3, "the empty line opens under the caret");
    type(editor, "Gamma");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "Gamma", "Beta"]);
  } finally {
    canvas.remove();
  }
});

await scene("a heading follows the same rule", async () => {
  const { canvas, editor, state } = await mount([{ id: "h-a", type: "heading", level: 2, text: "Alpha" }, p("p-e", ""), p("p-b", "Beta")]);
  try {
    caretAt(editor, "Alpha", 5);
    press(editor, "Enter");
    type(editor, "Gamma");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "Gamma", "Beta"]);
    assert.equal(state.server.length, 3);
  } finally {
    canvas.remove();
  }
});

await scene("untouched: Enter mid-text splits, Enter at the start under text adds one line, Shift-Enter breaks, lists and sections keep their Enter", async () => {
  const flat = await mount(RUN);
  try {
    caretAt(flat.editor, "Alpha", 2);
    press(flat.editor, "Enter");
    caretAt(flat.editor, "Beta", 0);
    press(flat.editor, "Enter");
    await saved(flat.canvas);
    assert.deepEqual(lines(flat.editor), ["Al", "pha", "", "Beta"], "mid-text split, and one line above Beta");
    caretAt(flat.editor, "Al", 2);
    press(flat.editor, "Enter", { shiftKey: true });
    await saved(flat.canvas);
    assert.equal(flat.editor.state.doc.child(0).lastChild.type.name, "hardBreak", "Shift-Enter inserts a line break");
  } finally {
    flat.canvas.remove();
  }
  const list = await mount([p("p-a", "Alpha"), { id: "l-1", type: "list", style: "bullet", items: ["One"] }]);
  try {
    caretAt(list.editor, "One", 3);
    press(list.editor, "Enter");
    press(list.editor, "Enter");
    await saved(list.canvas);
    assert.deepEqual(lines(list.editor), ["Alpha", "One", ""], "the second Enter leaves the list for a new paragraph");
    assert.equal(list.editor.state.doc.lastChild.type.name, "paragraph");
  } finally {
    list.canvas.remove();
  }
  const section = await mount([{ id: "s-day", type: "section", title: "Day", blocks: [p("p-day", "Left at six.")] }]);
  try {
    caretAt(section.editor, "Left at six.", 12);
    press(section.editor, "Enter");
    press(section.editor, "Enter");
    await saved(section.canvas);
    assert.deepEqual(lines(section.editor), ["Left at six.", "", ""], "a nested empty line is shown, so Enter adds lines there");
  } finally {
    section.canvas.remove();
  }
});

if (failures) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log("\nEnter never stacks invisible empty lines");
process.exit(0);
