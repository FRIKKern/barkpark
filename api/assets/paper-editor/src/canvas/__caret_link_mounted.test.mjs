// __caret_link_mounted.test.mjs — task-fbc0d0f2f0ab1329, as Sanity's: Link with only a
// caret (no selection) is enabled when the caret is in a word, and the link goes on that
// word; the caret stays where it was, and one undo takes it off. A caret touching no word
// (a space) has nothing to link. The studio's toolbar asks can()/run() exactly so.
// Run: node src/canvas/__caret_link_mounted.test.mjs   (or: npm test)
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
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");
const { TextSelection } = await import("@tiptap/pm/state");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
const twoFrames = async () => { await frame(); await frame(); };
const text = (value) => [{ type: "text", value }];
const BLOCKS = [
  { id: "p-1", type: "paragraph", content: text("Hello world") },
  { id: "p-2", type: "paragraph", content: text("Second line") },
  { id: "l-1", type: "list", items: [{ id: "li-0", text: "one" }, { id: "li-1", text: "two" }] },
];

async function mount({ vocabulary, editable } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  if (vocabulary) canvas.setAttribute("data-vocabulary", JSON.stringify(vocabulary));
  if (editable === false) canvas.setAttribute("editable", "false");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  const batches = [];
  const states = [];
  canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
  canvas.addEventListener("bp-selection-change", (event) => states.push(event.detail));
  document.body.appendChild(canvas);
  await sleep(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real editor is mounted");
  return { canvas, editor: canvas._editor, batches, states };
}
function posOfText(editor, needle) {
  let at = null;
  editor.state.doc.descendants((node, pos) => {
    if (at != null) return false;
    if (node.isText && node.text.includes(needle)) at = pos + node.text.indexOf(needle);
    return true;
  });
  assert.notEqual(at, null, `text ${needle} is in the doc`);
  return at;
}
const select = (editor, from, to = from) =>
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, from, to)));
const selectText = (editor, needle) => {
  const at = posOfText(editor, needle);
  select(editor, at, at + needle.length);
};
const topTypes = (editor) => { const t = []; editor.state.doc.forEach((n) => t.push(n.type.name)); return t; };
// The ops a command emitted: wait out the canvas's debounce (and history's 500 ms
// grouping, so the next command is its own undo step), then read them.
async function opsAfter(batches, run) {
  const before = batches.length;
  const result = run();
  await sleep(600);
  return { result, ops: batches.slice(before).flat() };
}
// The doc's content: node types, attrs and text, without the ids the canvas mints
// for new nodes outside history (an undone list item may keep its minted id).
const content = (json) => JSON.parse(JSON.stringify(json, (k, v) => (k === "bpId" || k === "bpType" ? undefined : v)));
// One undo step puts the doc back.
async function undoesInOneStep(editor, doc) {
  assert.equal(editor.commands.undo(), true, "undo applies");
  assert.deepEqual(content(editor.getJSON()), content(doc), "one undo puts the doc back");
  await sleep(450);
}

const { wordAtCaret } = await import("./host-commands.js");
const HREF = "https://example.com/g";

{
  const { canvas, editor, batches } = await mount();
  const doc = editor.getJSON();
  const at = posOfText(editor, "world") + 2; // wo|rld
  select(editor, at);
  assert.deepEqual(wordAtCaret(editor.state), { from: at - 2, to: at + 3 }, "the word around the caret");
  assert.equal(canvas.can("toggleMark", { mark: "link", href: HREF }), true, "a caret in a word: Link is enabled");
  const { result, ops } = await opsAfter(batches, () => canvas.toggleMark("link", { href: HREF }));
  assert.equal(result, true, "toggleMark links it");
  assert.equal(editor.state.selection.empty, true, "the caret stays a caret");
  assert.equal(editor.state.selection.from, at, "where it was");
  const linked = [];
  editor.state.doc.descendants((n) => {
    if (n.isText && n.marks.some((m) => m.type.name === "link" && m.attrs.href === HREF)) linked.push(n.text);
  });
  assert.deepEqual(linked, ["world"], "the link is on the word at the caret, nothing else");
  assert.equal(ops.length, 1, "one patch");
  await undoesInOneStep(editor, doc);

  // A caret at a word's end touches it; one between two spaces touches none.
  select(editor, posOfText(editor, "Hello") + 5); // Hello| world: touches "Hello"
  assert.equal(canvas.can("toggleMark", { mark: "link", href: HREF }), true, "a caret at a word's end touches it");
  const p2 = posOfText(editor, "Second line");
  editor.view.dispatch(editor.state.tr.insertText("  ", p2 + 6, p2 + 7)); // "Second  line"
  select(editor, p2 + 7); // Second |  ... between two spaces
  assert.equal(wordAtCaret(editor.state), null, "between two spaces: no word");
  assert.equal(canvas.can("toggleMark", { mark: "link", href: HREF }), false, "a caret touching no word: Link stays disabled");
  select(editor, posOfText(editor, "line") + 1);
  assert.equal(canvas.can("toggleMark", { mark: "link", href: "javascript:alert(1)" }), false, "in a word, an unsafe address is still refused");
  assert.equal(canvas.toggleMark("link", { href: "javascript:alert(1)" }), false, "and not applied");
  canvas.remove();
}

console.log("caret link: ok");
