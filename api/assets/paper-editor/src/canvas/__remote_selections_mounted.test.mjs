// Mounted: shared carets (task-d47c05259837093f).
//
// OUT — bp-canvas-selection carries the local selection as { anchor, head } Points
// ({ blockId, path?, offset }, offset in UTF-16 units), one per animation frame,
// and null on blur.
// IN — setRemoteSelections(list) paints each remote as a caret + name label and a
// range when anchor != head. Decorations only: no ops, no undo entry, the local
// caret unmoved. They map through local typing, survive applyServerBlocks
// (in place and a whole-run reorder), and a point whose block or path is gone is
// dropped. [] clears.

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
const rect = { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 };
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => rect;
window.Element.prototype.getClientRects = () => [];
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");
const { TextSelection } = await import("@tiptap/pm/state");
const { remoteSelectionsState } = await import("./remote-selections.js");

const text = (value) => [{ type: "text", value }];
const cellT = text;
const tableBlock = {
  id: "t1", type: "table",
  head: [cellT("A"), cellT("B")],
  rows: [[cellT("a1"), cellT("b1")], [cellT("a2"), cellT("b2")]],
};
const listBlock = (items) => ({ id: "l-1", type: "list", items: items.map((t, i) => ({ id: `li-${i}`, text: t })) });
const BLOCKS = [
  { id: "p-1", type: "paragraph", content: text("Hello world") },
  listBlock(["one", "two", "three"]),
  tableBlock,
  { id: "p-emoji", type: "paragraph", content: text("a\u{1F600}b") },
  { id: "p-2", type: "paragraph", content: text("Tail") },
];

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = BLOCKS;
const batches = [];
const selections = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
canvas.addEventListener("bp-canvas-selection", (event) => selections.push(event.detail));
// Set before mount: waits for the editor.
canvas.setRemoteSelections([
  { id: "pre", name: "Early", color: "#123456", anchor: { blockId: "p-2", offset: 1 }, head: { blockId: "p-2", offset: 1 } },
]);
document.body.appendChild(canvas);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
const twoFrames = async () => { await frame(); await frame(); };

// The doc position of (blockId, textblock child walk) found by text.
function posOfText(editor, needle) {
  let at = null;
  editor.state.doc.descendants((node, pos) => {
    if (at != null) return false;
    if (node.isText) {
      const i = node.text.indexOf(needle);
      if (i !== -1) at = pos + i;
    }
    return true;
  });
  assert.notEqual(at, null, `text ${needle} is in the doc`);
  return at;
}
const select = (editor, from, to = from) =>
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, from, to)));

let failed = false;
try {
  await sleep(350);
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real editor is mounted");
  assert.equal(typeof canvas.setRemoteSelections, "function");

  // ── pre-mount list applied on mount ────────────────────────────────────────
  assert.deepEqual(remoteSelectionsState(editor).map((r) => r.id), ["pre"], "a list set before mount is painted on mount");

  // ── OUT: the event ─────────────────────────────────────────────────────────
  editor.view.dom.focus();
  assert.equal(editor.isFocused, true, "the editor takes focus");
  await twoFrames();
  selections.length = 0;

  // rAF-coalesced: three synchronous moves, one event, the last one.
  const hello = posOfText(editor, "Hello");
  select(editor, hello + 1);
  select(editor, hello + 2);
  select(editor, hello + 3, hello + 5);
  assert.equal(selections.length, 0, "nothing is emitted before the frame");
  await twoFrames();
  assert.deepEqual(selections, [
    { anchor: { blockId: "p-1", offset: 3 }, head: { blockId: "p-1", offset: 5 } },
  ], "one event per frame carrying the latest selection as Points");

  // An unchanged selection emits nothing new.
  select(editor, hello + 3, hello + 5);
  await twoFrames();
  assert.equal(selections.length, 1, "an unchanged selection is not re-emitted");

  // Inside a list: path names the item.
  select(editor, posOfText(editor, "three") + 2);
  await twoFrames();
  assert.deepEqual(selections.at(-1), {
    anchor: { blockId: "l-1", path: "items[2]", offset: 2 },
    head: { blockId: "l-1", path: "items[2]", offset: 2 },
  }, "a list caret names its item");

  // Inside a table: rows (head row included) then cells.
  select(editor, posOfText(editor, "a2"), posOfText(editor, "b2") + 1);
  await twoFrames();
  assert.deepEqual(selections.at(-1), {
    anchor: { blockId: "t1", path: "rows[2].cells[0]", offset: 0 },
    head: { blockId: "t1", path: "rows[2].cells[1]", offset: 1 },
  }, "a table caret names its row and cell");

  // UTF-16 offsets: the emoji is two units.
  const emoji = posOfText(editor, "a\u{1F600}b");
  select(editor, emoji + 4);
  await twoFrames();
  assert.deepEqual(selections.at(-1).head, { blockId: "p-emoji", offset: 4 }, "offset counts UTF-16 units");

  // Blur → null.
  editor.view.dom.blur();
  await twoFrames();
  assert.equal(editor.isFocused, false, "the editor is blurred");
  assert.equal(selections.at(-1), null, "blur emits null");

  // ── IN: remote selections ──────────────────────────────────────────────────
  editor.view.dom.focus();
  select(editor, posOfText(editor, "Tail") + 2);
  await twoFrames();
  const eventsBefore = selections.length;
  const localBefore = editor.state.selection.toJSON();
  const undoBefore = editor.can().undo();

  canvas.setRemoteSelections([
    { id: "u2", name: "Bob", color: "#e11d48", anchor: { blockId: "p-1", offset: 0 }, head: { blockId: "p-1", offset: 5 } },
    { id: "u3", name: "Cy", color: "hsl(200 80% 40%)", anchor: { blockId: "l-1", path: "items[1]", offset: 1 }, head: { blockId: "l-1", path: "items[1]", offset: 1 } },
    { id: "gone", name: "Ghost", color: "red", anchor: { blockId: "nope", offset: 0 }, head: { blockId: "nope", offset: 0 } },
    { id: "half", name: "Hal", color: "red", anchor: { blockId: "p-1", offset: 0 }, head: { blockId: "nope", offset: 0 } },
    { id: "bad-path", name: "Pat", color: "red", anchor: { blockId: "l-1", path: "items[9]", offset: 0 }, head: { blockId: "l-1", path: "items[9]", offset: 0 } },
    { id: "evil", name: "<b>x</b>", color: "red;background:url(x)", anchor: { blockId: "p-2", offset: 0 }, head: { blockId: "p-2", offset: 0 } },
  ]);

  const carets = [...editor.view.dom.querySelectorAll(".bp-remote-caret")];
  assert.deepEqual(carets.map((c) => c.getAttribute("data-remote-id")).sort(), ["evil", "u2", "u3"],
    "one caret per live remote; vanished block and path are dropped silently");
  const bob = carets.find((c) => c.getAttribute("data-remote-id") === "u2");
  assert.equal(bob.querySelector(".bp-remote-caret__label").textContent, "Bob", "the caret carries the name label");
  assert.equal(bob.style.getPropertyValue("--bp-remote-color"), "#e11d48", "in the remote's color");
  assert.ok(bob.closest('[data-bp-id="p-1"]'), "Bob's caret sits in p-1");
  const evil = carets.find((c) => c.getAttribute("data-remote-id") === "evil");
  assert.equal(evil.querySelector(".bp-remote-caret__label").innerHTML, "&lt;b&gt;x&lt;/b&gt;", "a name is text, never markup");
  assert.equal(evil.style.getPropertyValue("--bp-remote-color"), "#888", "a color that is not plain color syntax falls back");
  const range = editor.view.dom.querySelectorAll('.bp-remote-selection[data-remote-id="u2"]');
  assert.ok(range.length >= 1, "anchor != head paints a range");
  assert.equal(range[0].textContent, "Hello", "the range covers the remote's selection");
  assert.equal(editor.view.dom.querySelectorAll('.bp-remote-selection[data-remote-id="u3"]').length, 0, "a caret has no range");

  assert.deepEqual(editor.state.selection.toJSON(), localBefore, "the local caret did not move");
  assert.equal(editor.can().undo(), undoBefore, "setting remotes adds no history entry");
  await twoFrames();
  assert.equal(selections.length, eventsBefore, "setting remotes emits no bp-canvas-selection");

  // ── local typing maps them ─────────────────────────────────────────────────
  editor.view.dispatch(editor.state.tr.insertText("XX", posOfText(editor, "Hello")));
  let st = remoteSelectionsState(editor);
  assert.deepEqual(st.find((r) => r.id === "u2").anchor, { blockId: "p-1", offset: 2 }, "typing before a remote shifts it");
  assert.deepEqual(st.find((r) => r.id === "u2").head, { blockId: "p-1", offset: 7 });
  assert.equal(editor.view.dom.querySelector('.bp-remote-selection[data-remote-id="u2"]').textContent, "Hello",
    "the range still covers the same text");

  // Undo removes the typing, and only that: the remotes are not history.
  editor.commands.undo();
  st = remoteSelectionsState(editor);
  assert.equal(editor.state.doc.textBetween(0, 20).startsWith("Hello"), true, "undo removed the typing");
  assert.deepEqual(st.find((r) => r.id === "u2").anchor, { blockId: "p-1", offset: 0 }, "the remote maps back with the undo");
  assert.deepEqual(st.map((r) => r.id).sort(), ["evil", "u2", "u3"], "undo neither drops nor restores remotes");

  // ── applyServerBlocks: in place, then a reorder (whole-run re-seed) ────────
  editor.view.dom.blur();
  await sleep(450); // let the debounced ops of the typing settle
  const opsAfterTyping = batches.length;

  canvas.applyServerBlocks([
    { id: "p-1", type: "paragraph", content: text("Hello world, again") },
    listBlock(["one", "two", "three"]),
    tableBlock,
    { id: "p-emoji", type: "paragraph", content: text("a\u{1F600}b") },
    { id: "p-2", type: "paragraph", content: text("Tail") },
  ]);
  st = remoteSelectionsState(editor);
  assert.deepEqual(st.find((r) => r.id === "u2").head, { blockId: "p-1", offset: 5 }, "an in-place server patch keeps the remote");

  canvas.applyServerBlocks([
    { id: "p-2", type: "paragraph", content: text("Tail") },
    { id: "p-1", type: "paragraph", content: text("Hello world, again") },
    listBlock(["one", "two", "three"]),
    tableBlock,
    { id: "p-emoji", type: "paragraph", content: text("a\u{1F600}b") },
  ]);
  st = remoteSelectionsState(editor);
  assert.deepEqual(st.find((r) => r.id === "u2"), {
    id: "u2", name: "Bob", color: "#e11d48",
    anchor: { blockId: "p-1", offset: 0 }, head: { blockId: "p-1", offset: 5 },
  }, "a reorder re-resolves the remote in its own block");
  assert.ok(editor.view.dom.querySelector('.bp-remote-caret[data-remote-id="u2"]').closest('[data-bp-id="p-1"]'),
    "the caret is painted in p-1 after the reorder");
  assert.deepEqual(st.find((r) => r.id === "u3").anchor, { blockId: "l-1", path: "items[1]", offset: 1 });

  // ── vanished: a block removed, a list item removed ─────────────────────────
  canvas.applyServerBlocks([
    { id: "p-2", type: "paragraph", content: text("Tail") },
    listBlock(["one"]),
    tableBlock,
    { id: "p-emoji", type: "paragraph", content: text("a\u{1F600}b") },
  ]);
  st = remoteSelectionsState(editor);
  assert.deepEqual(st.map((r) => r.id), ["evil"], "a remote whose block or path vanished is dropped");
  assert.equal(editor.view.dom.querySelectorAll('.bp-remote-caret[data-remote-id="u2"]').length, 0);

  // ── [] clears ──────────────────────────────────────────────────────────────
  canvas.setRemoteSelections([]);
  assert.equal(editor.view.dom.querySelectorAll(".bp-remote-caret, .bp-remote-selection").length, 0, "[] clears");

  await sleep(450);
  assert.equal(batches.length, opsAfterTyping, "remote selections never emit ops");

  console.log("PASS remote_selections: Points out, remote carets in, mapped and dropped, never ops or history");
} catch (error) {
  failed = true;
  throw error;
} finally {
  canvas.remove();
  dom.window.close();
  if (failed) process.exitCode = 1;
}
