// __host_commands_mounted.test.mjs — the toolbar commands a host runs on
// <bp-paper-canvas> (EMBED-CONTRACT "Toolbar commands"): toggleMark, setBlockStyle,
// toggleList, insertBlock and run, with can(), state() and bp-selection-change.
//
// Mounts the real canvas in jsdom (the __remote_selections_mounted pattern). For
// each command: it applies to the selection, the doc and the emitted ops show it,
// one undo puts it back, state() reports it, and can() refuses what the field's
// vocabulary forbids (the veto would drop it silently).
//
// Run: node src/canvas/__host_commands_mounted.test.mjs   (or: npm test)

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

let failed = false;
const mounts = [];
try {
  // ── a paper canvas (no vocabulary) ──────────────────────────────────────────
  const m = await mount();
  mounts.push(m.canvas);
  const { canvas, editor, batches, states } = m;
  for (const name of ["run", "toggleMark", "setBlockStyle", "toggleList", "insertBlock", "can", "state"])
    assert.equal(typeof canvas[name], "function", `${name} is public`);
  editor.view.dom.focus();

  // toggleMark: strong, em, code, underline, strike, highlight.
  for (const [mark, tiptap, pd] of [["strong", "bold", "strong"], ["em", "italic", "em"], ["code", "code", "code"], ["underline", "underline", "underline"], ["strike", "strike", "strikethrough"], ["highlight", "highlight", "highlight"]]) {
    selectText(editor, "Hello");
    const doc = editor.getJSON();
    assert.equal(canvas.can("toggleMark", { mark }), true, `can toggleMark ${mark}`);
    const { result, ops } = await opsAfter(batches, () => canvas.toggleMark(mark));
    assert.equal(result, true, `toggleMark ${mark} applied`);
    assert.ok(editor.isActive(tiptap), `${mark} is on the selection`);
    assert.ok(canvas.state().marks.includes(mark), `state().marks has ${mark}`);
    assert.ok(JSON.stringify(ops).includes(`"${pd}"`), `the ${mark} mark is on the wire (${pd})`);
    await undoesInOneStep(editor, doc);
  }

  // toggleMark('link'): set with an href, read back, clear without one.
  selectText(editor, "world");
  assert.equal(canvas.can("toggleMark", { mark: "link" }), false, "no link to clear and no href: cannot");
  const beforeLink = editor.getJSON();
  const linked = await opsAfter(batches, () => canvas.toggleMark("link", { href: "https://example.com/a" }));
  assert.equal(linked.result, true, "link set");
  assert.deepEqual(canvas.state().link, { href: "https://example.com/a" }, "state().link has the href");
  assert.ok(canvas.state().marks.includes("link"), "state().marks has link");
  assert.ok(JSON.stringify(linked.ops).includes("https://example.com/a"), "the link is on the wire");
  selectText(editor, "world");
  assert.equal((await opsAfter(batches, () => canvas.toggleMark("link"))).result, true, "link cleared without an href");
  assert.equal(canvas.state().link, null, "state().link is null again");
  editor.commands.undo();
  await undoesInOneStep(editor, beforeLink);

  // setBlockStyle: h2, back to normal, blockquote (same block id, text kept).
  select(editor, posOfText(editor, "Second") + 2);
  let doc = editor.getJSON();
  let step = await opsAfter(batches, () => canvas.setBlockStyle("h2"));
  assert.equal(step.result, true, "setBlockStyle h2 applied");
  assert.equal(editor.state.selection.$from.parent.type.name, "heading");
  assert.equal(canvas.state().blockStyle, "h2", "state().blockStyle is h2");
  assert.ok(step.ops.some((op) => op.block && op.block.type === "heading" && op.block.level === 2), "a level-2 heading is on the wire");
  await undoesInOneStep(editor, doc);
  select(editor, posOfText(editor, "Second") + 2);
  doc = editor.getJSON();
  step = await opsAfter(batches, () => canvas.setBlockStyle("blockquote"));
  assert.equal(step.result, true, "setBlockStyle blockquote applied");
  assert.equal(editor.state.doc.child(1).type.name, "blockquote", "the block is a quote");
  assert.equal(editor.state.doc.child(1).attrs.bpId, "p-2", "the quote keeps the block's id");
  assert.equal(editor.state.doc.child(1).textContent, "Second line", "and its text");
  assert.equal(canvas.state().blockStyle, "blockquote");
  assert.equal((await opsAfter(batches, () => canvas.setBlockStyle("normal"))).result, true, "back to a paragraph");
  assert.equal(editor.state.doc.child(1).type.name, "paragraph");
  assert.equal(editor.state.doc.child(1).attrs.bpId, "p-2", "still the same block");
  editor.commands.undo();
  await undoesInOneStep(editor, doc);
  assert.equal(canvas.can("setBlockStyle", { style: "h7" }), false, "an unknown style cannot");

  // toggleList: bullet on a paragraph, number keeps the list's id, number again lifts it out.
  select(editor, posOfText(editor, "Second") + 2);
  doc = editor.getJSON();
  step = await opsAfter(batches, () => canvas.toggleList("bullet"));
  assert.equal(step.result, true, "toggleList bullet applied");
  assert.equal(canvas.state().list, "bullet", "state().list is bullet");
  assert.ok(step.ops.some((op) => op.block && op.block.type === "list"), "a list is on the wire");
  await undoesInOneStep(editor, doc);
  select(editor, posOfText(editor, "two") + 1);
  doc = editor.getJSON();
  assert.equal((await opsAfter(batches, () => canvas.toggleList("number"))).result, true, "the list becomes numbered");
  assert.equal(editor.state.doc.child(2).type.name, "orderedList");
  assert.equal(editor.state.doc.child(2).attrs.bpId, "l-1", "the numbered list keeps the list's id");
  assert.equal(canvas.state().list, "number");
  select(editor, posOfText(editor, "two") + 1);
  assert.equal((await opsAfter(batches, () => canvas.toggleList("number"))).result, true, "the same kind again lifts the item out");
  assert.equal(canvas.state().list, null, "no longer in a list");
  editor.commands.undo();
  await undoesInOneStep(editor, doc);

  // insertBlock: a callout after the caret's block, one undo step.
  select(editor, posOfText(editor, "Hello") + 1);
  doc = editor.getJSON();
  assert.equal(canvas.can("insertBlock", { type: "callout" }), true, "can insert a callout");
  assert.equal(canvas.can("insertBlock", { type: "no-such-type" }), false, "an unknown type cannot");
  step = await opsAfter(batches, () => canvas.insertBlock("callout"));
  assert.equal(step.result, true, "insertBlock callout applied");
  assert.equal(topTypes(editor)[1], "callout", "the callout lands after the caret's block");
  assert.equal(editor.state.doc.child(0).textContent, "Hello world", "the caret's block keeps its text");
  assert.ok(step.ops.some((op) => op.block && op.block.type === "callout"), "a callout is on the wire");
  await undoesInOneStep(editor, doc);
  select(editor, posOfText(editor, "Hello") + 1);
  doc = editor.getJSON();
  assert.equal(canvas.insertBlock("heading", { level: 3 }), true, "insertBlock heading with a level");
  assert.equal(editor.state.doc.child(1).type.name, "heading");
  assert.equal(editor.state.doc.child(1).attrs.level, 3, "at the level asked for");
  await undoesInOneStep(editor, doc);

  // run(command, args) is the same dispatch.
  selectText(editor, "Hello");
  doc = editor.getJSON();
  assert.equal(canvas.run("toggleMark", { mark: "strong" }), true, "run toggleMark");
  assert.ok(editor.isActive("bold"));
  await undoesInOneStep(editor, doc);
  assert.equal(canvas.run("nope", {}), false, "an unknown command is false");

  // state() and bp-selection-change: one event per frame, detail = state().
  await twoFrames();
  states.length = 0;
  select(editor, posOfText(editor, "Hello") + 1);
  select(editor, posOfText(editor, "Second") + 1);
  select(editor, posOfText(editor, "one") + 1);
  assert.equal(states.length, 0, "nothing before the frame");
  await twoFrames();
  assert.equal(states.length, 1, "one event for three synchronous moves");
  assert.deepEqual(states[0], canvas.state(), "detail equals state()");
  assert.deepEqual(states[0], { marks: [], blockStyle: "normal", list: "bullet", link: null, selection: { empty: true, inBlockType: "list" } });
  select(editor, posOfText(editor, "one") + 1);
  await twoFrames();
  assert.equal(states.length, 1, "an unchanged state is not re-emitted");
  editor.commands.toggleBold(); // a stored mark: no selection change, still a state change
  await twoFrames();
  assert.equal(states.length, 2, "a stored mark is a state change");
  assert.deepEqual(states[1].marks, ["strong"]);
  assert.ok(states[1].selection && states[1].selection.empty === true);

  // ── a field canvas: can() answers the vocabulary ────────────────────────────
  const f = await mount({ vocabulary: { styles: ["normal", "h2", "blockquote"], lists: ["bullet"], marks: ["strong"] } });
  mounts.push(f.canvas);
  selectText(f.editor, "Hello");
  assert.equal(f.canvas.can("toggleMark", { mark: "strong" }), true, "a declared mark can");
  assert.equal(f.canvas.can("toggleMark", { mark: "em" }), false, "an undeclared mark cannot");
  doc = f.editor.getJSON();
  assert.equal(f.canvas.toggleMark("em"), false, "and does not apply");
  assert.deepEqual(f.editor.getJSON(), doc, "the doc is unchanged");
  assert.equal(f.canvas.can("setBlockStyle", { style: "h2" }), true);
  assert.equal(f.canvas.can("setBlockStyle", { style: "h1" }), false, "an undeclared heading level cannot");
  assert.equal(f.canvas.can("toggleList", { kind: "bullet" }), true);
  assert.equal(f.canvas.can("toggleList", { kind: "number" }), false, "an undeclared list kind cannot");
  assert.equal(f.canvas.can("insertBlock", { type: "callout" }), false, "a block the field does not declare cannot be inserted");
  // A field's blockquote style is the pullquote (quoteTypeFor), as `> ` makes.
  select(f.editor, posOfText(f.editor, "Second") + 2);
  assert.equal(f.canvas.setBlockStyle("blockquote"), true);
  assert.equal(f.editor.state.doc.child(1).type.name, "pullquote", "the field's quote is its pullquote");
  assert.equal(f.editor.state.doc.child(1).attrs.bpId, "p-2", "same block");
  assert.equal(f.canvas.state().blockStyle, "blockquote");

  // ── read-only and unmounted: false ──────────────────────────────────────────
  const r = await mount({ editable: false });
  mounts.push(r.canvas);
  selectText(r.editor, "Hello");
  assert.equal(r.canvas.can("toggleMark", { mark: "strong" }), false, "read-only: cannot");
  assert.equal(r.canvas.toggleMark("strong"), false, "read-only: does nothing");
  const loose = document.createElement("bp-paper-canvas");
  assert.equal(loose.toggleMark("strong"), false, "unmounted: false");
  assert.deepEqual(loose.state(), { marks: [], blockStyle: null, list: null, link: null, selection: { empty: true, inBlockType: null } }, "unmounted: the empty state");

  console.log("PASS host_commands: toggleMark, setBlockStyle, toggleList, insertBlock, run; can() honours the vocabulary; state() and bp-selection-change");
} catch (error) {
  failed = true;
  throw error;
} finally {
  for (const c of mounts) c.remove();
  dom.window.close();
  if (failed) process.exitCode = 1;
}
