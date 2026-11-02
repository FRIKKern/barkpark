// task-be261d669280dc9e: Enter on an empty line added a block the canvas hid at once
// (an empty top-level paragraph the caret left is a resting scaffold), so six Enters
// showed one line, saved six invisible blocks and took six Backspaces to leave.
//
// Rule (resting-scaffolds.js): two empty prose lines never touch at the top level of
// a canvas that hides them. Enter keeps the caret where a person expects it: on an
// empty line it does nothing; at the end of a line above an empty one it moves the
// caret there. Every other door (a split, Enter over a range, a list exit, a paste,
// Backspace, a move) is collapsed after the person's own edit, which also heals a
// stored stack the first time someone edits next to it. Remote updates, undo and redo, and IME
// composition are left alone.
//
// Mounted: the real <bp-paper-canvas>, real Enter / Shift-Enter / Backspace keydowns,
// typing through handleTextInput, every batch folded through the patch.ex reference
// fold (applyOps); the doc, the visible lines and the saved blocks (texts and ids)
// must agree.
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
function select(editor, text, from, to) {
  let at = null;
  editor.state.doc.descendants((node, pos) => {
    if (at == null && node.isTextblock && node.textContent === text) at = pos + 1;
  });
  assert.notEqual(at, null, `a line reads "${text}"`);
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at + from, at + to)));
}
function top(editor) {
  const out = [];
  editor.state.doc.forEach((node) => out.push(node.textContent));
  return out;
}
function touching(editor) {
  const empty = (node) => ["paragraph", "ingress"].includes(node?.type.name) && node.content.size === 0;
  let pairs = 0;
  editor.state.doc.forEach((node, _pos, index) => { if (index && empty(node) && empty(editor.state.doc.child(index - 1))) pairs++; });
  return pairs;
}
function agrees(editor, state) {
  const ids = [];
  editor.state.doc.forEach((node) => ids.push(node.attrs.bpId));
  assert.deepEqual(ids, state.server.map((block) => block.id), "the canvas ids are the saved ids");
  state.server.forEach((block, i) => {
    if (Array.isArray(block.content)) assert.equal(editor.state.doc.child(i).textContent, texts([block])[0], `block ${i} reads as saved`);
  });
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

async function mount(blocks, { kind, lockedTail, shared } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = clone(blocks);
  if (lockedTail) canvas.setAttribute("data-locked-tail", "true");
  const store = shared || { blocks: clone(blocks), rev: 0 };
  const state = {
    get server() { return store.blocks; },
    batches: 0,
    refused: [],
    seen: store.rev,
    store,
  };
  canvas.addEventListener("bp-canvas-ops", (event) => {
    state.batches++;
    if (state.seen !== store.rev) {
      state.refused.push({ seq: event.detail.seq, rebaseSafe: canvas.rebaseSafe(event.detail.seq, clone(store.blocks)) });
      return;
    }
    store.blocks = applyOps(store.blocks, event.detail.ops);
    state.seen = ++store.rev;
    canvas.acknowledgeOps(event.detail.seq, true);
    canvas.applyServerBlocks(clone(store.blocks), { mode: "own" });
  });
  const wrapper = document.createElement("div");
  if (kind) wrapper.dataset.paperContainerKind = kind;
  wrapper.appendChild(canvas);
  document.body.appendChild(wrapper);
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
const STACK = [p("p-a", "Alpha"), p("p-e1", ""), p("p-e2", ""), p("p-b", "Beta"), p("p-c", "Gamma")];
const ingress = (id, value) => ({ id, type: "ingress", content: value ? [{ type: "text", value }] : [] });

async function within(blocks, options, fn) {
  const mounted = await mount(blocks, options);
  try {
    await fn(mounted);
  } finally {
    mounted.canvas.parentNode.remove();
  }
}

await scene("six Enters at the end of a line: one empty line in the doc, on screen and saved; one Backspace leaves it", () => within(RUN, {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "Alpha", 5);
  for (let i = 0; i < 6; i++) press(editor, "Enter");
  await saved(canvas);
  assert.deepEqual(lines(editor), ["Alpha", "", "Beta"], "one empty line in the doc");
  assert.equal(shown(canvas), 3, "and on screen");
  assert.deepEqual(texts(state.server), ["Alpha", "", "Beta"], "and saved");
  agrees(editor, state);
  press(editor, "Backspace");
  await saved(canvas);
  assert.deepEqual(lines(editor), ["Alpha", "Beta"], "one Backspace leaves the empty line");
  assert.deepEqual(texts(state.server), ["Alpha", "Beta"]);
  assert.equal(editor.state.selection.$from.parent.textContent, "Alpha", "the caret is back on the line above");
}));

await scene("six Enters on an empty line: nothing changes and nothing is sent", () => within(GAP, {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "", 0);
  for (let i = 0; i < 6; i++) press(editor, "Enter");
  await saved(canvas);
  assert.deepEqual(lines(editor), ["Alpha", "", "Beta"]);
  assert.equal(state.batches, 0, "no batch");
  assert.equal(shown(canvas), 3, "the empty line holding the caret shows");
  press(editor, "Backspace");
  await saved(canvas);
  assert.deepEqual(texts(state.server), ["Alpha", "Beta"], "one Backspace leaves it");
}));

await scene("Enter at the start of a line under an empty line does nothing", () => within(GAP, {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "Beta", 0);
  press(editor, "Enter");
  await saved(canvas);
  assert.deepEqual(lines(editor), ["Alpha", "", "Beta"]);
  assert.equal(state.batches, 0);
  type(editor, "Very ");
  await saved(canvas);
  assert.deepEqual(texts(state.server), ["Alpha", "", "Very Beta"], "the caret stayed at the start of Beta");
}));

await scene("Enter at the end of a line above an empty line moves the caret into it", () => within(GAP, {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "Alpha", 5);
  press(editor, "Enter");
  await saved(canvas);
  assert.deepEqual(lines(editor), ["Alpha", "", "Beta"], "no new block");
  assert.equal(state.batches, 0);
  assert.equal(shown(canvas), 3, "the empty line opens under the caret");
  type(editor, "Gamma");
  await saved(canvas);
  assert.deepEqual(texts(state.server), ["Alpha", "Gamma", "Beta"]);
}));

await scene("Enter in the middle of a line beside an empty line splits it (Alpha@2, Beta@2)", async () => {
  await within(GAP, {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Alpha", 2);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Al", "pha", "", "Beta"]);
    agrees(editor, state);
  });
  await within(GAP, {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Beta", 2);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "Be", "ta"]);
    agrees(editor, state);
  });
});

await scene("a heading at its end follows the move; an empty heading under an empty line still splits", async () => {
  await within([{ id: "h-a", type: "heading", level: 2, text: "Alpha" }, p("p-e", ""), p("p-b", "Beta")], {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Alpha", 5);
    press(editor, "Enter");
    type(editor, "Gamma");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "Gamma", "Beta"]);
    assert.equal(state.server.length, 3);
  });
  await within([p("p-a", "Alpha"), p("p-e", ""), { id: "h-b", type: "heading", level: 2, text: "" }, p("p-b", "Beta")], {}, async ({ canvas, editor, state }) => {
    let at = null;
    editor.state.doc.forEach((node, pos) => { if (node.type.name === "heading") at = pos + 1; });
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
    press(editor, "Enter");
    await saved(canvas);
    assert.equal(state.server.length, 5, "Enter added a line");
    assert.equal(touching(editor), 0);
    agrees(editor, state);
  });
});

await scene("an ingress: six Enters at its end leave one empty line; Enter in an empty ingress does nothing", async () => {
  await within([ingress("i-a", "The lead."), p("p-b", "Beta")], {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "The lead.", 9);
    for (let i = 0; i < 6; i++) press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["The lead.", "", "Beta"]);
    agrees(editor, state);
  });
  await within([ingress("i-a", ""), p("p-b", "Beta")], {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "", 0);
    for (let i = 0; i < 6; i++) press(editor, "Enter");
    await saved(canvas);
    assert.equal(state.batches, 0, "no batch");
    assert.deepEqual(top(editor), ["", "Beta"]);
  });
});

await scene("Enter over a range collapses to one empty line, the caret's own (GAP Beta, RUN Alpha, GAP pha, empty line to Be)", async () => {
  await within(GAP, {}, async ({ canvas, editor, state }) => {
    select(editor, "Beta", 0, 4);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", ""]);
    assert.equal(editor.state.selection.$from.index(0), 1, "the caret is on the line that stayed");
    agrees(editor, state);
  });
  await within(RUN, {}, async ({ canvas, editor, state }) => {
    select(editor, "Alpha", 0, 5);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["", "Beta"]);
    agrees(editor, state);
  });
  await within(GAP, {}, async ({ canvas, editor, state }) => {
    select(editor, "Alpha", 2, 5);
    press(editor, "Enter");
    type(editor, "x");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Al", "x", "Beta"], "the caret stayed where Enter put it");
    agrees(editor, state);
  });
  await within(GAP, {}, async ({ canvas, editor, state }) => {
    let from = null;
    editor.state.doc.forEach((node, pos) => { if (from == null && node.content.size === 0) from = pos + 1; });
    let to = null;
    editor.state.doc.forEach((node, pos) => { if (node.textContent === "Beta") to = pos + 3; });
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, from, to)));
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "ta"], "a range that starts on an empty line is still deleted and split");
    agrees(editor, state);
  });
});

await scene("leaving a list onto an empty line collapses to one", () => within([{ id: "l-1", type: "list", style: "bullet", items: ["One"] }, p("p-e", ""), p("p-b", "Beta")], {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "One", 3);
  press(editor, "Enter");
  press(editor, "Enter");
  type(editor, "Two");
  await saved(canvas);
  assert.deepEqual(top(editor), ["One", "Two", "Beta"]);
  assert.equal(state.server.length, 3);
  agrees(editor, state);
}));

await scene("pasting empty paragraphs leaves no two touching", () => within(RUN, {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "Alpha", 5);
  editor.view.pasteHTML("<p>One</p><p></p><p></p><p></p><p>Two</p>", new window.Event("paste"));
  await saved(canvas);
  assert.equal(touching(editor), 0);
  assert.deepEqual(top(editor), ["AlphaOne", "", "Two", "Beta"], "one of the three pasted empty lines stays");
  agrees(editor, state);
}));

await scene("Backspace that empties a line between empty lines keeps the caret's line and the caret", () => within([p("p-a", "Alpha"), p("p-e1", ""), p("p-x", "B"), p("p-e2", ""), p("p-c", "Gamma")], {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "B", 1);
  const { from } = editor.state.selection;
  editor.view.dispatch(editor.state.tr.delete(from - 1, from));
  type(editor, "Beta");
  await saved(canvas);
  assert.deepEqual(texts(state.server), ["Alpha", "Beta", "Gamma"]);
  assert.equal(state.server[1].id, "p-x", "the caret's line stayed");
  agrees(editor, state);
}));

await scene("moving a line out from between empty lines collapses them, keeping the first", () => within([p("p-a", "Alpha"), p("p-e1", ""), p("p-b", "Beta"), p("p-e2", ""), p("p-c", "Gamma")], {}, async ({ canvas, editor, state }) => {
  const { doc } = editor.state;
  let from = null;
  doc.forEach((node, pos) => { if (node.textContent === "Beta") from = pos; });
  const beta = doc.nodeAt(from);
  const tr = editor.state.tr.delete(from, from + beta.nodeSize);
  editor.view.dispatch(tr.insert(tr.doc.content.size, beta).setMeta("uiEvent", "drop"));
  await saved(canvas);
  assert.deepEqual(texts(state.server), ["Alpha", "", "Gamma", "Beta"]);
  assert.equal(state.server[1].id, "p-e1");
  agrees(editor, state);
}));

await scene("a stored stack heals on the first edit next to it, not on load and not on an edit elsewhere; text is never removed", async () => {
  await within(STACK, {}, async ({ canvas, editor, state }) => {
    assert.deepEqual(top(editor), ["Alpha", "", "", "Beta", "Gamma"], "loading leaves it");
    caretAt(editor, "Gamma", 5);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "", "Beta", "Gamma!"], "an edit away from it leaves it");
    const { from } = editor.state.selection;
    assert.equal(editor.state.applyTransaction(editor.state.tr.insertText("?", from)).transactions.length, 1, "and appends no transaction");
    caretAt(editor, "Beta", 4);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "Beta!", "Gamma!"], "an edit beside it heals it");
    assert.equal(state.server[1].id, "p-e1", "the first line stays");
    agrees(editor, state);
  });
  await within([p("p-e1", ""), p("p-e2", ""), p("p-a", "Alpha"), p("p-m", "Mid"), p("p-b", "Beta"), p("p-e3", ""), p("p-e4", "")], {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Mid", 3);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["", "", "Alpha", "Mid!", "Beta", "", ""], "stacks at the doc's edges stay until an edit beside them");
  });
  await within([p("p-a", "Alpha"), p("p-e1", ""), p("p-e2", ""), p("p-b", "Beta"), p("p-e3", ""), p("p-e4", ""), p("p-c", "Gamma")], {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Beta", 4);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "Beta!", "", "Gamma"], "one edit between two stacks heals both");
    assert.deepEqual(state.server.map((block) => block.id), ["p-a", "p-e1", "p-b", "p-e3", "p-c"]);
    agrees(editor, state);
  });
});

await scene("a remote update is never collapsed; the next local edit beside it is, and the ids match the fold", () => within(RUN, {}, async ({ canvas, editor, state }) => {
  editor.view.dom.blur();
  await tick(50);
  state.store.blocks = [p("p-a", "Alpha"), p("p-r1", ""), p("p-r2", ""), p("p-b", "Beta")];
  state.seen = ++state.store.rev;
  canvas.applyServerBlocks(clone(state.server));
  await tick(350);
  assert.deepEqual(top(editor), ["Alpha", "", "", "Beta"], "the remote stack stays as sent");
  assert.equal(state.batches, 0, "nothing sent");
  editor.view.focus();
  caretAt(editor, "Alpha", 5);
  type(editor, "!");
  await saved(canvas);
  assert.deepEqual(top(editor), ["Alpha!", "", "Beta"]);
  assert.deepEqual(state.server.map((block) => block.id), ["p-a", "p-r1", "p-b"]);
  agrees(editor, state);
}));

await scene("undo takes back the edit and its collapse in one step, without a new collapse; redo still works", async () => {
  await within(RUN, {}, async ({ canvas, editor, state }) => {
    select(editor, "Alpha", 0, 5);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(top(editor), ["", "Beta"]);
    editor.commands.undo();
    await saved(canvas);
    assert.deepEqual(top(editor), ["Alpha", "Beta"], "one undo");
    editor.commands.redo();
    await saved(canvas);
    assert.deepEqual(top(editor), ["", "Beta"], "one redo");
    agrees(editor, state);
  });
  await within(STACK, {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Alpha", 5);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(top(editor), ["Alpha!", "", "Beta", "Gamma"]);
    editor.commands.undo();
    await saved(canvas);
    assert.deepEqual(top(editor), ["Alpha", "", "", "Beta", "Gamma"], "undo brings the stored stack back and leaves it");
    editor.commands.redo();
    await saved(canvas);
    assert.deepEqual(top(editor), ["Alpha!", "", "Beta", "Gamma"], "redo heals it again");
    agrees(editor, state);
  });
});

await scene("no collapse while an IME composes; the first edit after it collapses", () => within(STACK, {}, async ({ canvas, editor, state }) => {
  caretAt(editor, "Alpha", 5);
  editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
  assert.equal(editor.view.composing, true);
  editor.view.dispatch(editor.state.tr.insertText("x"));
  assert.deepEqual(top(editor), ["Alphax", "", "", "Beta", "Gamma"], "composing: left alone");
  editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: "x" }));
  await tick(50);
  assert.equal(editor.view.composing, false);
  type(editor, "y");
  await saved(canvas);
  assert.deepEqual(texts(state.server), ["Alphaxy", "", "Beta", "Gamma"]);
  agrees(editor, state);
}));

await scene("a collapse that would move a locked block is dropped and the edit lands; a run that only shrinks above a locked tail collapses", async () => {
  await within([p("p-a", "Alpha"), p("p-e1", ""), p("p-e2", ""), { ...p("p-l", "Locked"), locked: true }], {}, async ({ canvas, editor, state }) => {
    caretAt(editor, "Alpha", 5);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha!", "", "", "Locked"], "the typing lands, the stack stays");
    agrees(editor, state);
  });
  await within(STACK.slice(0, 3), { lockedTail: true }, async ({ canvas, editor, state }) => {
    caretAt(editor, "Alpha", 5);
    type(editor, "!");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha!", ""]);
    agrees(editor, state);
  });
});

await scene("two writers: A types into an empty line that B's edit beside it collapses; B's stale save is refused and cannot rebase, A's text stays", async () => {
  const shared = { blocks: clone(GAP), rev: 0 };
  const a = await mount(GAP, { shared });
  const b = await mount(GAP, { shared });
  try {
    a.editor.view.focus();
    caretAt(a.editor, "", 0);
    type(a.editor, "hi");
    await saved(a.canvas);
    assert.deepEqual(texts(shared.blocks), ["Alpha", "hi", "Beta"]);
    b.editor.view.focus();
    select(b.editor, "Beta", 0, 4);
    press(b.editor, "Backspace");
    await saved(b.canvas);
    assert.deepEqual(top(b.editor), ["Alpha", ""], "B collapsed the line A typed into");
    assert.equal(b.state.refused.length, 1, "B's save was refused on the old revision");
    assert.equal(b.state.refused[0].rebaseSafe, false, "and cannot be resent on A's version");
    assert.equal(b.canvas.localEditsRebaseSafe(clone(shared.blocks)), false, "so B is shown a conflict");
    assert.deepEqual(texts(shared.blocks), ["Alpha", "hi", "Beta"], "A's text stays");
  } finally {
    a.canvas.parentNode.remove();
    b.canvas.parentNode.remove();
  }
});

await scene("in Studio the document canvas and a section's own canvas both follow the rule; nested lines keep their Enter", async () => {
  await within(RUN, { kind: "document" }, async ({ canvas, editor, state }) => {
    caretAt(editor, "Alpha", 5);
    for (let i = 0; i < 6; i++) press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Alpha", "", "Beta"]);
  });
  await within([p("p-day", "Left at six.")], { kind: "section" }, async ({ canvas, editor, state }) => {
    caretAt(editor, "Left at six.", 12);
    for (let i = 0; i < 6; i++) press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(texts(state.server), ["Left at six.", ""]);
    caretAt(editor, "Left at six.", 0);
    assert.equal(shown(canvas), 1, "the section canvas hides the empty line too");
  });
  await within([{ id: "s-day", type: "section", title: "Day", blocks: [p("p-day", "Left at six.")] }], {}, async ({ canvas, editor }) => {
    caretAt(editor, "Left at six.", 12);
    press(editor, "Enter");
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Left at six.", "", ""], "a nested empty line is shown, so Enter adds lines there");
  });
});

await scene("untouched: Enter at the start under text adds one line, at the doc's first and last line splits, Shift-Enter breaks, a list's second Enter leaves it", async () => {
  await within(RUN, {}, async ({ canvas, editor }) => {
    caretAt(editor, "Alpha", 0);
    press(editor, "Enter");
    caretAt(editor, "Beta", 4);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["", "Alpha", "Beta", ""], "a line above the first and below the last");
  });
  await within(RUN, {}, async ({ canvas, editor }) => {
    caretAt(editor, "Beta", 0);
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "", "Beta"], "one line above Beta");
    caretAt(editor, "Alpha", 2);
    press(editor, "Enter", { shiftKey: true });
    await saved(canvas);
    assert.equal(editor.state.doc.child(0).child(1).type.name, "hardBreak", "Shift-Enter inserts a line break");
  });
  await within([p("p-a", "Alpha"), { id: "l-1", type: "list", style: "bullet", items: ["One"] }], {}, async ({ canvas, editor }) => {
    caretAt(editor, "One", 3);
    press(editor, "Enter");
    press(editor, "Enter");
    await saved(canvas);
    assert.deepEqual(lines(editor), ["Alpha", "One", ""], "the second Enter leaves the list for a new paragraph");
    assert.equal(editor.state.doc.lastChild.type.name, "paragraph");
  });
});

await scene("cost: the collapse check on a 200-block doc", () => within(Array.from({ length: 200 }, (_, i) => p(`p-${i}`, i % 3 === 2 ? "" : `Line ${i}`)), {}, async ({ editor }) => {
  const plugin = editor.state.plugins.find((pl) => String(pl.spec.appendTransaction).includes("collapseTouchingEmptyLines"));
  const state = editor.state;
  let at = null;
  state.doc.forEach((node, pos, index) => { if (index === 100) at = pos + 2; });
  const tr = state.tr.insertText("x", at);
  const next = state.apply(tr);
  const runs = [];
  for (let i = 0; i < 2000; i++) {
    const t0 = performance.now();
    plugin.spec.appendTransaction([tr], state, next);
    runs.push(performance.now() - t0);
  }
  runs.sort((x, y) => x - y);
  const median = runs[1000] * 1000;
  console.log(`      median ${median.toFixed(1)} µs, p99 ${(runs[1980] * 1000).toFixed(1)} µs per keystroke`);
  assert.ok(median < 1000);
}));

if (failures) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log("\nTwo empty lines never touch");
process.exit(0);
