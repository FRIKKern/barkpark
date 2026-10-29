// Mounted: a host that saves locally (Barkever) gets other writers' blocks while
// the author types (liveRemote, 1.15.0), unread DOM typing is read before a
// flush or a server apply, Escape reaches the host, and a document-link click
// is an event.

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
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
window.Element.prototype.scrollIntoView ||= () => {};

const { TextSelection } = await import("@tiptap/pm/state");
await import("./index.js");
const { CONTRACT_VERSION } = await import("../contract.js");

const wait = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const paragraph = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });
const texts = (canvas) => {
  const out = [];
  canvas._editor.state.doc.forEach((node) => out.push([node.attrs.bpId, node.textContent]));
  return out;
};
const caret = (canvas) => {
  const { $head } = canvas._editor.state.selection;
  return { id: $head.node(1).attrs.bpId, offset: $head.parentOffset };
};

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures++;
    console.log(`not ok - ${name}`);
    console.log(error);
  }
}

// The Barkever host: ack at once, save locally, echo the saved blocks as its own.
async function mount(blocks, { liveRemote = true, echo = true } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.liveRemote = liveRemote;
  canvas.blocks = blocks;
  const batches = [];
  const held = [];
  canvas.addEventListener("bp-canvas-ops", (event) => {
    const { ops, seq } = event.detail;
    batches.push(ops);
    const requestId = `local-${seq}`;
    canvas.identifyOpsRequest(seq, requestId);
    canvas.acknowledgeOps(seq, true);
    const saved = structuredClone(canvas.blocks);
    if (echo) setTimeout(() => canvas.applyServerBlocks(saved, { mode: "own", requestId }), 0);
  });
  canvas.addEventListener("bp-canvas-remote-held", (event) => held.push(event.detail));
  document.body.appendChild(canvas);
  await wait(350);
  batches.length = 0;
  return { canvas, batches, held };
}

function placeCaret(canvas, id, offset) {
  const editor = canvas._editor;
  editor.view.focus();
  let at = null;
  editor.state.doc.forEach((node, pos) => {
    if (node.attrs.bpId === id) at = pos + 1 + offset;
  });
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
}

async function blur(canvas) {
  canvas._editor.view.dom.blur();
  await wait(30);
}

await check("contract version is 1.15.0", () => {
  assert.equal(CONTRACT_VERSION, "1.15.0");
});

await check("liveRemote: a remote edit to another block applies at once; caret, focus and history stay", async () => {
  const { canvas, batches } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo"), paragraph("c", "Charlie")]);
  placeCaret(canvas, "a", 3);
  const started = performance.now();
  canvas.applyServerBlocks([paragraph("a", "Alpha"), paragraph("b", "Bravo from the phone"), paragraph("c", "Charlie")]);
  const took = performance.now() - started;
  assert.deepEqual(texts(canvas), [["a", "Alpha"], ["b", "Bravo from the phone"], ["c", "Charlie"]]);
  assert.ok(took < 300, `applied in ${took.toFixed(1)} ms`);
  assert.deepEqual(caret(canvas), { id: "a", offset: 3 });
  assert.equal(canvas._editor.isFocused, true);
  assert.equal(canvas._editor.can().undo(), false, "the remote edit is not an undo step");
  await wait(350);
  assert.equal(batches.length, 0, "taking a remote block sends nothing back");
  assert.equal(canvas.hasPendingChanges(), false);
  canvas.remove();
});

await check("liveRemote: inserts and removals around the caret apply; the caret stays in its block", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo"), paragraph("c", "Charlie")]);
  placeCaret(canvas, "b", 2);
  canvas.applyServerBlocks([paragraph("n", "New first"), paragraph("b", "Bravo"), paragraph("c", "Charlie")]);
  assert.deepEqual(texts(canvas), [["n", "New first"], ["b", "Bravo"], ["c", "Charlie"]]);
  assert.deepEqual(caret(canvas), { id: "b", offset: 2 });
  canvas.remove();
});

await check("liveRemote: a remote edit to the caret block with nothing unsaved applies; the caret maps", async () => {
  const { canvas, held } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo")]);
  placeCaret(canvas, "a", 5);
  canvas.applyServerBlocks([paragraph("a", "Alpha, edited elsewhere"), paragraph("b", "Bravo")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha, edited elsewhere"], ["b", "Bravo"]]);
  assert.equal(caret(canvas).id, "a");
  assert.equal(caret(canvas).offset, 5, "text appended after the caret leaves it where it was");
  assert.equal(held.length, 0);
  canvas.remove();
});

await check("liveRemote: the caret block with unsaved typing keeps the author's text; the remote block is reported", async () => {
  const { canvas, batches, held } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo"), paragraph("c", "Charlie")]);
  placeCaret(canvas, "a", 5);
  canvas._editor.view.dispatch(canvas._editor.state.tr.insertText(" typed"));
  canvas.applyServerBlocks([paragraph("a", "Alpha other"), paragraph("b", "Bravo"), paragraph("c", "Charlie remote")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha typed"], ["b", "Bravo"], ["c", "Charlie remote"]]);
  assert.deepEqual(caret(canvas), { id: "a", offset: 11 });
  assert.deepEqual(held, [{ blockId: "a", remote: paragraph("a", "Alpha other") }]);
  canvas.applyServerBlocks([paragraph("a", "Alpha other"), paragraph("b", "Bravo"), paragraph("c", "Charlie remote")]);
  assert.equal(held.length, 1, "the same held version is reported once");
  assert.equal(canvas.flushPendingChanges(), true);
  assert.deepEqual(batches, [[{ op: "patch-block", id: "a", patch: { content: [{ type: "text", value: "Alpha typed" }] } }]],
    "only the author's block goes out, with every keystroke");
  canvas.remove();
});

await check("liveRemote: a held block takes the host's merged echo once the typing is saved", async () => {
  const { canvas, held } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo")], { echo: false });
  placeCaret(canvas, "a", 5);
  canvas._editor.view.dispatch(canvas._editor.state.tr.insertText("!"));
  canvas.applyServerBlocks([paragraph("a", "Alpha?"), paragraph("b", "Bravo")]);
  assert.equal(held.length, 1);
  canvas.flushPendingChanges();
  // Before the host's own echo, the saved block stays pinned.
  canvas.applyServerBlocks([paragraph("a", "Alpha?"), paragraph("b", "Bravo")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha!"], ["b", "Bravo"]]);
  // The host merged both writers and echoes it under the batch's request id.
  const seq = canvas._opsSeq;
  canvas.applyServerBlocks([paragraph("a", "Alpha!"), paragraph("k", "Alpha?"), paragraph("b", "Bravo")], { mode: "own", requestId: `local-${seq}` });
  await wait(0);
  assert.deepEqual(texts(canvas), [["a", "Alpha!"], ["k", "Alpha?"], ["b", "Bravo"]]);
  assert.equal(canvas._pendingServerBlocks, null, "nothing left held");
  canvas.remove();
});

await check("liveRemote: typing in one block, then moving the caret, still protects the typed block", async () => {
  const { canvas, held } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo")]);
  placeCaret(canvas, "a", 5);
  canvas._editor.view.dispatch(canvas._editor.state.tr.insertText("1"));
  placeCaret(canvas, "b", 0);
  canvas.applyServerBlocks([paragraph("a", "Alpha 2"), paragraph("b", "Bravo")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha1"], ["b", "Bravo"]]);
  assert.equal(held[0].blockId, "a");
  canvas.remove();
});

await check("liveRemote: a held block applies at blur once the author's text is saved and nothing newer arrived", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo")]);
  placeCaret(canvas, "b", 5);
  canvas.applyServerBlocks([paragraph("a", "Alpha"), paragraph("b", "Bravo")]);
  // The caret block is removed remotely while the author is in it: kept until blur.
  canvas.applyServerBlocks([paragraph("a", "Alpha")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha"], ["b", "Bravo"]]);
  assert.deepEqual(caret(canvas), { id: "b", offset: 5 });
  await blur(canvas);
  assert.deepEqual(texts(canvas), [["a", "Alpha"]]);
  canvas.remove();
});

await check("default (no liveRemote): a focused canvas still defers remote blocks until blur", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo")], { liveRemote: false });
  placeCaret(canvas, "a", 2);
  canvas.applyServerBlocks([paragraph("a", "Alpha"), paragraph("b", "Bravo remote")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha"], ["b", "Bravo"]]);
  await blur(canvas);
  assert.deepEqual(texts(canvas), [["a", "Alpha"], ["b", "Bravo remote"]]);
  canvas.remove();
});

// Typing the browser has put in the DOM but ProseMirror has not read yet.
function typeIntoDom(canvas, id, suffix) {
  const block = [...canvas._editor.view.dom.children].find((el) => el.textContent.length && canvas._editor.view.posAtDOM(el, 0) >= 0 &&
    canvas._editor.state.doc.resolve(canvas._editor.view.posAtDOM(el, 0)).node(1)?.attrs.bpId === id);
  const walker = document.createTreeWalker(block, window.NodeFilter.SHOW_TEXT);
  const text = walker.nextNode();
  text.data += suffix;
}

await check("typing then blur in one task, then flushPendingChanges, saves the typed text", async () => {
  const { canvas, batches } = await mount([paragraph("a", "Alpha")], { liveRemote: false });
  placeCaret(canvas, "a", 5);
  typeIntoDom(canvas, "a", " unread");
  canvas._editor.view.dom.blur();
  assert.equal(canvas.flushPendingChanges(), true, "the flush found the unread typing");
  assert.deepEqual(batches, [[{ op: "patch-block", id: "a", patch: { content: [{ type: "text", value: "Alpha unread" }] } }]]);
  canvas.remove();
});

await check("typing then blur in one task, then hasPendingChanges, reports it", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha")], { liveRemote: false });
  placeCaret(canvas, "a", 5);
  typeIntoDom(canvas, "a", "?");
  canvas._editor.view.dom.blur();
  assert.equal(canvas.hasPendingChanges(), true);
  canvas.remove();
});

await check("typing then blur in one task, then applyServerBlocks, keeps the typed text", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha"), paragraph("b", "Bravo")]);
  placeCaret(canvas, "a", 5);
  typeIntoDom(canvas, "a", " kept");
  canvas._editor.view.dom.blur();
  canvas.applyServerBlocks([paragraph("a", "Alpha"), paragraph("b", "Bravo remote")]);
  assert.deepEqual(texts(canvas), [["a", "Alpha kept"], ["b", "Bravo remote"]]);
  canvas.remove();
});

function escape(target) {
  const event = new window.KeyboardEvent("keydown", { key: "Escape", keyCode: 27, bubbles: true, cancelable: true });
  target.dispatchEvent(event);
  return event;
}

await check("Escape with no canvas menu open bubbles to the host, not default-prevented", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha")], { liveRemote: false });
  placeCaret(canvas, "a", 1);
  let seen = null;
  const onKey = (event) => { seen = event; };
  document.addEventListener("keydown", onKey);
  const event = escape(canvas._editor.view.dom);
  document.removeEventListener("keydown", onKey);
  assert.equal(seen, event, "the host's document listener got it");
  assert.equal(event.defaultPrevented, false);
  canvas.remove();
});

await check("Escape that closes a canvas menu stays the canvas's", async () => {
  const { canvas } = await mount([paragraph("a", "Alpha")], { liveRemote: false });
  placeCaret(canvas, "a", 1);
  canvas._openPalette();
  assert.equal(canvas._palette.isOpen(), true);
  const event = escape(canvas._editor.view.dom);
  assert.equal(event.defaultPrevented, true);
  assert.equal(canvas._palette.isOpen(), false);
  canvas.remove();
});

await check("a click on a document link emits bp-canvas-wikilink-click with its docId", async () => {
  const { canvas } = await mount([{ id: "a", type: "paragraph", content: [
    { type: "text", value: "See " },
    { type: "wikilink", target: "Other note", docId: "note-2", children: [{ type: "text", value: "Other note" }] },
  ] }], { liveRemote: false });
  const seen = [];
  canvas.addEventListener("bp-canvas-wikilink-click", (event) => { seen.push(event.detail); event.preventDefault(); });
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true });
  canvas.querySelector("span[data-wikilink]").dispatchEvent(click);
  assert.deepEqual(seen, [{ docId: "note-2", target: "Other note", alias: null, metaKey: true, ctrlKey: false, shiftKey: false, altKey: false }]);
  assert.equal(click.defaultPrevented, true, "a handled click prevents the click's default");
  canvas.querySelector("p").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(seen.length, 1, "a click elsewhere emits nothing");
  canvas.remove();
});

if (failures) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log("live remote: all passed");
process.exit(0);
