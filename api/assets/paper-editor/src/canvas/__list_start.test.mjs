import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

// An ordered list's first number (`start`) in the canvas, the edit twin of the
// reader's <ol start="N"> (walk.ex list_start_attr/1): it mounts as TipTap's
// orderedList `start` attr, paints <ol start="5">, comes back on save, and an
// untouched list writes nothing. Absent or 1 numbers from 1 and keeps its bytes.
const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
const fetchMock = async () => ({ ok: true, json: async () => ({ documents: [] }) });
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

const { blockToTiptap, tiptapToBlock } = await import("../convert.js");
const { runToTiptap, runToOps } = await import("./run-convert.js");
await import("../index.js");

const text = (value) => ({ type: "text", value });
const items = [[text("five")], [text("six")]];
const list = (extra) => ({ id: "l1", type: "list", ordered: true, items, ...extra });

// ── convert: mount and save ────────────────────────────────────────────────
const five = blockToTiptap(list({ start: 5 })).content[0];
assert.equal(five.type, "orderedList");
assert.equal(five.attrs.start, 5, "start 5 mounts as the orderedList start attr");
assert.deepEqual(tiptapToBlock(blockToTiptap(list({ start: 5 })), "l1", "list"), { ordered: true, items, start: 5 },
  "an untouched start-5 list saves start 5");
for (const extra of [{}, { start: 1 }]) {
  const doc = blockToTiptap(list(extra));
  assert.equal(doc.content[0].attrs?.start, undefined, `${JSON.stringify(extra)} mounts numbering from 1`);
  assert.deepEqual(tiptapToBlock(doc, "l1", "list"), { ordered: true, items }, `${JSON.stringify(extra)} saves no start`);
}
assert.equal(blockToTiptap(list({ ordered: false, start: 5 })).content[0].attrs?.start, undefined, "a bullet list shows no start");
assert.equal(blockToTiptap(list({ start: "5" })).content[0].attrs?.start, undefined, "a string start is not a start");

// A nested ordered list keeps its own start, and an edit elsewhere leaves it be.
const nestedBlock = list({ items: [{ content: [text("outer")], children: [list({ id: undefined, start: 3 })] }] });
const nested = blockToTiptap(nestedBlock);
assert.equal(nested.content[0].content[0].content[1].attrs.start, 3, "the nested list mounts its start");
nested.content[0].content[0].content[0].content[0].text = "outer edited";
const savedNested = tiptapToBlock(nested, "l1", "list");
assert.equal(savedNested.items[0].children[0].start, 3, "editing the parent keeps the nested start");
nested.content[0].content[0].content[1].attrs.start = 1;
assert.equal(Object.hasOwn(tiptapToBlock(nested, "l1", "list").items[0].children[0], "start"), false,
  "a nested list set back to 1 drops its stored start");

// ── runToOps: the canvas diff ──────────────────────────────────────────────
const prev = [list({ start: 5 })];
const same = runToTiptap(prev);
assert.deepEqual(runToOps(prev, same), [], "an untouched start-5 list emits no op");
const renumbered = runToTiptap(prev);
renumbered.content[0].attrs.start = 7;
assert.deepEqual(runToOps(prev, renumbered).map((o) => [o.op, o.patch && o.patch.start]), [["patch-block", 7]],
  "a new first number alone is a patch carrying it");
const fromOne = runToTiptap(prev);
fromOne.content[0].attrs.start = 1;
assert.deepEqual(runToOps(prev, fromOne).map((o) => [o.op, o.patch && o.patch.start]), [["patch-block", null]],
  "numbering back from 1 clears the stored start (start:null on the shallow merge)");
const edited = runToTiptap(prev);
edited.content[0].content[0].content[0].content[0].text = "five!";
const [op] = runToOps(prev, edited);
assert.equal(op.patch.start, 5, "a text edit keeps the list's start");

// ── mounted canvas: the painted list and no write on mount ─────────────────
const host = document.createElement("bp-paper-canvas");
host.setAttribute("data-dataset", "production");
const batches = [];
host.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail));
document.body.appendChild(host);
host.blocks = [list({ start: 5 }), { id: "l2", type: "list", ordered: true, items }];
try {
  host.flushPendingChanges();
  const ols = [...host.querySelectorAll("ol")];
  assert.equal(ols.length, 2, "both ordered lists paint");
  assert.equal(ols[0].getAttribute("start"), "5", "the start-5 list paints <ol start=\"5\"> like the reader");
  assert.equal(ols[1].hasAttribute("start"), false, "a list from 1 paints a bare <ol> like the reader");
  assert.deepEqual(batches.flatMap((b) => b.ops), [], "mounting writes nothing");
} finally {
  host.remove();
  window.close();
}
console.log("list start: mounts, paints, saves and diffs the first number; absent/1 unchanged");
