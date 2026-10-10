// __carry_caret_keys_mounted.test.mjs — task-0075081d540d1390 (P1 data loss from
// #22846). A field that declares a `callout` object block carries it as a bpOpaque
// block. With the caret at the end of the paragraph before it, End or
// Mod+ArrowRight NodeSelected the carry, and the next keystroke replaced it: the
// batch held remove-block for the callout. Now:
//
//   * a line jump at the edge of a textblock stays in that textblock when the block
//     beside it is a carry (End, Mod+ArrowRight; Home, Mod+ArrowLeft mirrored);
//   * typing over a NodeSelected carry never removes it: the text goes into a new
//     paragraph after the block;
//   * a paste or an IME composition over a NodeSelected carry lands in a new
//     paragraph after it the same way (Backspace/Delete stay a deliberate delete);
//   * plain ArrowRight still reaches the carry (control).
// Run: node src/canvas/__carry_caret_keys_mounted.test.mjs
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
const { NodeSelection, TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const DECLARED = {
  styles: ["normal"],
  of: [{
    name: "callout",
    title: "Callout",
    fields: [
      { name: "tone", title: "Tone", type: "string", options: { list: ["info", "warning"] } },
      { name: "text", title: "Text", type: "text" },
    ],
  }],
};
// The reported body: heading, paragraph, declared callout — plus a paragraph after
// it for the mirrored (Home / Mod+ArrowLeft) keys.
const BLOCKS = [
  { id: "h26", type: "heading", level: 2, content: [{ type: "text", value: "Post 26" }] },
  { id: "p26", type: "paragraph", content: [{ type: "text", value: "Body paragraph for post 26." }] },
  { id: "co26", type: "callout", tone: "info", text: "Mind the gap." },
  { id: "p27", type: "paragraph", content: [{ type: "text", value: "After." }] },
];

let ran = 0;
let failures = 0;
async function check(name, fn) {
  ran += 1;
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}
const EXPECTED = 11;

// ProseMirror's own arrow handling reads keyCode; Tiptap's "Mod" is Meta on a Mac.
const MAC = /Mac|iP(hone|[oa]d)/.test(navigator.platform);
const KEYCODE = { ArrowLeft: 37, ArrowRight: 39, ArrowDown: 40, End: 35, Home: 36 };
function key(el, name, extra = {}) {
  const event = new KeyboardEvent("keydown", { key: name, keyCode: KEYCODE[name] || 0, bubbles: true, cancelable: true, ...extra });
  el.dispatchEvent(event);
  return event;
}
const MOD = MAC ? { metaKey: true } : { ctrlKey: true };

const root = document.createElement("div");
root.className = "bp-paper-editor";
const canvas = document.createElement("bp-paper-canvas");
canvas.setAttribute("data-vocabulary", JSON.stringify(DECLARED));
canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
root.appendChild(canvas);
document.body.appendChild(root);
await tick(350);
const editor = canvas._editor;
const ops = [];
canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));

const posOf = (id) => canvas._topLevelPos(id);
const endOf = (id) => posOf(id) + editor.state.doc.nodeAt(posOf(id)).nodeSize - 1;
const startOf = (id) => posOf(id) + 1;
const caretAt = (pos) => editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, pos)));
const ids = () => { const out = []; editor.state.doc.forEach((n) => out.push(n.attrs.bpId || n.type.name)); return out; };
const isCarrySelected = () => editor.state.selection instanceof NodeSelection && editor.state.selection.node.attrs.bpId === "co26";
// The input path ProseMirror takes for a typed character.
// Each data-loss check starts from the reported body, so one red cannot feed the next.
async function reset() {
  canvas.applyServerBlocksIfIdle(JSON.parse(JSON.stringify(BLOCKS)));
  await tick(50);
  assert.deepEqual(ids(), ["h26", "p26", "co26", "p27"], "reset to the reported body");
}
function type(text) {
  const { view } = editor;
  for (const char of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, char));
    if (!handled) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}

try {
  await check("the declared callout is a carried block", () => {
    assert.equal(editor.state.doc.nodeAt(posOf("co26")).type.name, "bpOpaque");
  });

  for (const [label, name, extra] of [["End", "End", {}], ["Mod+ArrowRight", "ArrowRight", MOD]]) {
    await check(`${label} at the end of the paragraph before the callout keeps the caret in the paragraph`, () => {
      caretAt(endOf("p26"));
      const event = key(editor.view.dom, name, extra);
      assert.ok(!isCarrySelected(), "the callout was NodeSelected");
      assert.ok(event.defaultPrevented, "the browser was left to move the caret onto the callout");
      assert.equal(editor.state.selection.head, endOf("p26"));
    });
  }

  for (const [label, name, extra] of [["Home", "Home", {}], ["Mod+ArrowLeft", "ArrowLeft", MOD]]) {
    await check(`${label} at the start of the paragraph after the callout keeps the caret in the paragraph`, () => {
      caretAt(startOf("p27"));
      const event = key(editor.view.dom, name, extra);
      assert.ok(!isCarrySelected(), "the callout was NodeSelected");
      assert.ok(event.defaultPrevented, "the browser was left to move the caret onto the callout");
      assert.equal(editor.state.selection.head, startOf("p27"));
    });
  }

  await check("control: plain ArrowRight at the end of the paragraph still reaches the callout", () => {
    caretAt(endOf("p26"));
    key(editor.view.dom, "ArrowRight");
    assert.ok(isCarrySelected(), `selection is ${JSON.stringify(editor.state.selection.toJSON())}`);
  });

  await check("control: End in the middle of a paragraph is left to the browser", () => {
    caretAt(startOf("p26") + 3);
    const event = key(editor.view.dom, "End");
    assert.ok(!event.defaultPrevented);
  });

  await check("typing over the selected callout keeps it: the batch has no remove-block, the text lands in a new paragraph after it", async () => {
    await reset();
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, posOf("co26"))));
    ops.length = 0;
    type(" AAA");
    canvas.flushPendingChanges();
    await tick(20);
    assert.ok(ops.length > 0, "the typing emitted ops");
    assert.deepEqual(ops.filter((op) => op.op === "remove-block" || op.type === "remove-block"), [], JSON.stringify(ops));
    const order = ids();
    const at = order.indexOf("co26");
    assert.ok(at >= 0, `the callout is gone: ${JSON.stringify(order)}`);
    const next = editor.state.doc.child(at + 1);
    assert.equal(next.type.name, "paragraph");
    assert.equal(next.textContent, " AAA");
    assert.deepEqual(order.filter((id) => ["h26", "p26", "co26", "p27"].includes(id)), ["h26", "p26", "co26", "p27"], "nothing moved");
  });

  const selectCarry = () => editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, posOf("co26"))));
  const afterCarry = () => editor.state.doc.child(ids().indexOf("co26") + 1);
  const removes = () => ops.filter((op) => op.op === "remove-block");

  for (const [label, clip] of [
    ["plain text", { text: "Pasted plain" }],
    ["HTML", { html: "<p>Pasted <strong>rich</strong></p>", text: "Pasted rich" }],
  ]) {
    await check(`a ${label} paste over the selected callout keeps it and lands in a new paragraph after it`, async () => {
      await reset();
      selectCarry();
      ops.length = 0;
      const event = new Event("paste", { bubbles: true, cancelable: true });
      Object.defineProperty(event, "clipboardData", { value: { types: clip.html ? ["text/html", "text/plain"] : ["text/plain"], getData: (t) => (t === "text/html" ? clip.html || "" : t === "text/plain" ? clip.text : ""), files: [] } });
      editor.view.dom.dispatchEvent(event);
      await tick(20);
      canvas.flushPendingChanges();
      await tick(20);
      assert.ok(ops.length > 0, "the paste emitted ops");
      assert.deepEqual(removes(), [], JSON.stringify(ops));
      assert.ok(ids().includes("co26"), `the callout is gone: ${JSON.stringify(ids())}`);
      assert.equal(afterCarry().textContent, clip.text);
    });
  }

  await check("an IME composition over the selected callout starts in a new paragraph after it and keeps it", async () => {
    await reset();
    selectCarry();
    ops.length = 0;
    editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
    assert.ok(ids().includes("co26"), `the composition start removed the callout: ${JSON.stringify(ids())}`);
    assert.ok(!(editor.state.selection instanceof NodeSelection), "the composition would replace the callout");
    assert.equal(editor.state.selection.$head.parent.type.name, "paragraph");
    assert.equal(afterCarry().textContent, "", "the composition starts in an empty paragraph after the callout");
    // The committed composition, as ProseMirror reads it back.
    editor.view.dispatch(editor.state.tr.insertText("\u3042"));
    editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: "\u3042" }));
    canvas.flushPendingChanges();
    await tick(20);
    assert.deepEqual(removes(), [], JSON.stringify(ops));
    assert.ok(ids().includes("co26"));
    assert.equal(afterCarry().textContent, "\u3042");
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ncarry caret keys mounted: all checks passed");
  process.exit(0);
}
