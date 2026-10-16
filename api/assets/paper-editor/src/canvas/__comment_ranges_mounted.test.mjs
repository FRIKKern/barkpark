// Mounted: comment ranges (task-58497c55c1705d63).
//
// setCommentRanges(list) paints each comment's span; decorations only (no ops, no
// undo entry, the local caret unmoved). A range maps inward: typing at its edges
// stays outside, typing inside grows it, and an edit that moves it fires
// bp-canvas-comment-ranges with the new Points. Deleting its text drops it. A
// click inside fires bp-canvas-comment-click; commentsInSelection() names the
// ranges a selection overlaps. A reorder re-resolves by Point. [] clears.

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
const { commentRangesKey } = await import("./comment-ranges.js");

const text = (value) => [{ type: "text", value }];
const BLOCKS = [
  { id: "p-1", type: "paragraph", content: text("The quick brown fox") },
  { id: "l-1", type: "list", items: [{ id: "li-0", text: "one" }, { id: "li-1", text: "second item" }] },
  { id: "p-2", type: "paragraph", content: text("Tail") },
];

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = BLOCKS;
const batches = [];
const moves = [];
const clicks = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
canvas.addEventListener("bp-canvas-comment-ranges", (event) => moves.push(event.detail));
canvas.addEventListener("bp-canvas-comment-click", (event) => clicks.push(event.detail));
// Set before mount: waits for the editor. "quick" in p-1.
canvas.setCommentRanges([
  { id: "c1", anchor: { blockId: "p-1", offset: 4 }, head: { blockId: "p-1", offset: 9 } },
]);
document.body.appendChild(canvas);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
const twoFrames = async () => { await frame(); await frame(); };
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
const painted = (editor, id) =>
  [...editor.view.dom.querySelectorAll(`.bp-comment-range[data-comment-id="${id}"]`)].map((el) => el.textContent).join("");

let failed = false;
try {
  await sleep(350);
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real editor is mounted");
  assert.deepEqual(canvas.commentRanges(), [
    { id: "c1", anchor: { blockId: "p-1", offset: 4 }, head: { blockId: "p-1", offset: 9 }, text: "quick" },
  ], "a list set before mount is live on mount");
  assert.equal(painted(editor, "c1"), "quick", "the span is painted");

  // ── set: decorations only ──────────────────────────────────────────────────
  editor.view.dom.focus();
  select(editor, posOfText(editor, "Tail") + 1);
  const localBefore = editor.state.selection.toJSON();
  const undoBefore = editor.can().undo();
  canvas.setCommentRanges([
    // head before anchor: ordered on the way in.
    { id: "c1", anchor: { blockId: "p-1", offset: 9 }, head: { blockId: "p-1", offset: 4 }, active: true },
    { id: "c2", anchor: { blockId: "l-1", path: "items[1]", offset: 0 }, head: { blockId: "l-1", path: "items[1]", offset: 6 } },
    { id: "empty", anchor: { blockId: "p-2", offset: 1 }, head: { blockId: "p-2", offset: 1 } },
    { id: "gone", anchor: { blockId: "nope", offset: 0 }, head: { blockId: "nope", offset: 2 } },
  ]);
  assert.deepEqual(canvas.commentRanges().map((r) => [r.id, r.text]), [["c1", "quick"], ["c2", "second"]],
    "empty and unresolvable spans are skipped; the rest in document order");
  assert.ok(editor.view.dom.querySelector('.bp-comment-range--active[data-comment-id="c1"]'), "active marks the open thread");
  assert.equal(editor.view.dom.querySelector('.bp-comment-range--active[data-comment-id="c2"]'), null);
  assert.deepEqual(editor.state.selection.toJSON(), localBefore, "the local caret did not move");
  assert.equal(editor.can().undo(), undoBefore, "setting ranges adds no history entry");

  // ── selection overlap ──────────────────────────────────────────────────────
  const quick = posOfText(editor, "quick");
  select(editor, quick - 2, quick + 1);
  assert.deepEqual(canvas.commentsInSelection(), ["c1"], "a selection reaching into a range overlaps it");
  select(editor, quick - 2, quick);
  assert.deepEqual(canvas.commentsInSelection(), [], "touching the edge is not overlap");
  select(editor, quick + 2);
  assert.deepEqual(canvas.commentsInSelection(), ["c1"], "a caret inside counts");

  // ── click ──────────────────────────────────────────────────────────────────
  const click = (pos) => commentRangesKey.get(editor.state).props.handleClick(editor.view, pos, new window.MouseEvent("click"));
  click(quick + 2);
  click(posOfText(editor, "Tail"));
  assert.deepEqual(clicks, [{ id: "c1" }], "a click inside a range names it; outside, nothing");

  // ── typing maps inward ─────────────────────────────────────────────────────
  await twoFrames();
  moves.length = 0;
  editor.view.dispatch(editor.state.tr.insertText("very ", posOfText(editor, "quick")));
  assert.equal(painted(editor, "c1"), "quick", "typing at the start stays outside");
  const end = posOfText(editor, "quick") + 5;
  editor.view.dispatch(editor.state.tr.insertText("!", end));
  assert.equal(painted(editor, "c1"), "quick", "typing at the end stays outside");
  editor.view.dispatch(editor.state.tr.insertText("-ish", posOfText(editor, "quick") + 3));
  assert.equal(canvas.commentRanges()[0].text, "qui-ishck", "typing inside grows it");
  assert.equal(moves.length, 0, "the moved event waits for the frame");
  await twoFrames();
  assert.equal(moves.length, 1, "three edits, one bp-canvas-comment-ranges");
  assert.deepEqual(moves[0][0], {
    id: "c1", anchor: { blockId: "p-1", offset: 9 }, head: { blockId: "p-1", offset: 18 }, text: "qui-ishck",
  }, "the event carries the new Points");

  // Undo maps it back; the ranges are not history.
  for (let i = 0; i < 3 && editor.can().undo(); i++) editor.commands.undo();
  assert.equal(editor.state.doc.textBetween(0, 40).startsWith("The quick"), true, "undo removed the typing");
  assert.equal(canvas.commentRanges()[0].text, "quick", "the range maps back with the undo");

  // ── a reorder re-resolves by Point ─────────────────────────────────────────
  editor.view.dom.blur();
  await sleep(450);
  canvas.applyServerBlocks([BLOCKS[2], BLOCKS[0], BLOCKS[1]]);
  assert.deepEqual(canvas.commentRanges().map((r) => [r.id, r.text]), [["c1", "quick"], ["c2", "second"]],
    "a whole-run reorder keeps both ranges on their text");

  // ── deleting the text drops it ─────────────────────────────────────────────
  editor.view.dom.focus();
  const second = posOfText(editor, "second");
  editor.view.dispatch(editor.state.tr.delete(second, second + 6));
  assert.deepEqual(canvas.commentRanges().map((r) => r.id), ["c1"], "a range whose text is gone is dropped");
  await twoFrames();
  assert.deepEqual(moves.at(-1).map((r) => r.id), ["c1"], "and the host hears it");

  // ── [] clears ──────────────────────────────────────────────────────────────
  canvas.setCommentRanges([]);
  assert.equal(editor.view.dom.querySelectorAll(".bp-comment-range").length, 0, "[] clears");
  assert.deepEqual(commentRangesKey.getState(editor.state).ranges, []);

  // Ops only ever carry the typing, never the ranges.
  editor.view.dom.blur();
  await sleep(450);
  assert.ok(batches.flat().every((op) => !JSON.stringify(op).includes("comment")), "ranges never reach ops");

  console.log("PASS comment_ranges: painted, mapped inward, emitted, clicked, overlap, dropped, never ops or history");
} catch (error) {
  failed = true;
  throw error;
} finally {
  canvas.remove();
  dom.window.close();
  if (failed) process.exitCode = 1;
}
