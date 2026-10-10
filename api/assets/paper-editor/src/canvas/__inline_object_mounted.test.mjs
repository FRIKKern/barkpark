// __inline_object_mounted.test.mjs — task-85fee859cf3bfef6 (inline objects, slice
// 3), in a real mounted field canvas whose vocabulary declares one inline kind
// (`chip`, Sanity's post-11 chip) under blocks.inline:
//
//   * PD → editor → PD keeps declared, undeclared and unknown inline nodes
//     byte-identical; the undeclared/unknown ones are inert atoms, never dropped;
//   * only the declared kind is offered for insertion; the slash pick opens the
//     dialog, Save puts the chip in the paragraph, and the op carries it;
//   * a required field blocks Save; Cancel inserts nothing;
//   * Enter on a selected chip edits it, keeping keys the dialog does not own;
//   * every atom is named "<kind title>: <label>"; Backspace removes a selected
//     chip and one undo restores it;
//   * a server refusal reopens the dialog with the reason on the field it names.
// Run: node src/canvas/__inline_object_mounted.test.mjs
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
const { docToBlocks } = await import("./run-convert.js");
const { slashItemsForVocabulary, parseVocabulary } = await import("./vocabulary.js");
const { NodeSelection } = await import("@tiptap/pm/state");
const { buildCommandRegistry } = await import("./command-palette.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);

const VOCAB = {
  styles: ["normal"],
  marks: ["strong"],
  inline: [{
    name: "chip",
    title: "Status chip",
    fields: [
      { name: "text", title: "Text", type: "string", validation: { required: true } },
      { name: "tone", title: "Tone", type: "string", options: { list: ["positive", "caution"] } },
    ],
  }],
};
const CHIP = { type: "chip", _key: "k1", text: "Reviewed", tone: "positive" };
const P_CHIP = {
  id: "p-chip", type: "paragraph",
  content: [{ type: "text", value: "Status " }, CHIP, { type: "text", value: ", written with Ada." }],
};
// An undeclared kind (no blocks.inline entry) and an unknown one with no text.
const P_OTHER = {
  id: "p-other", type: "paragraph",
  content: [
    { type: "text", value: "See " },
    { type: "badge", label: "Beta" },
    { type: "text", value: " and " },
    { type: "strong", children: [{ type: "future", size: 3 }] },
  ],
};
const BLOCKS = [P_CHIP, P_OTHER, { id: "p-end", type: "paragraph", content: [{ type: "text", value: "End" }] }];

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
    console.log(`      ${e.message.split("\n")[0]}`);
  }
}
const EXPECTED = 12;

const dialog = () => document.querySelector(".bp-inline-object-dialog");
const field = (name) => dialog().querySelector(`[data-field="${name}"]`);
function key(el, name, extra = {}) {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...extra }));
}

try {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  const editor = canvas._editor;
  const atoms = () => {
    const out = [];
    editor.state.doc.descendants((node, pos) => { if (node.type.name === "bpInlineOpaque") out.push({ node, pos }); });
    return out;
  };
  const atomOf = (type) => atoms().find((a) => a.node.attrs.node.type === type);
  const select = (type) => editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, atomOf(type).pos)));

  await check("PD → editor → PD keeps declared, undeclared and unknown inline nodes byte-identical", () => {
    const saved = docToBlocks(editor.getJSON());
    assert.equal(canonical(saved.find((b) => b.id === "p-chip")), canonical(P_CHIP));
    assert.equal(canonical(saved.find((b) => b.id === "p-other")), canonical(P_OTHER));
  });

  await check("every atom is shown, inert, and named '<kind title>: <label>'", () => {
    const named = [...editor.view.dom.querySelectorAll(".bp-inline-opaque")].map((el) => [
      el.getAttribute("role"), el.getAttribute("aria-label"), el.getAttribute("contenteditable"), el.textContent,
    ]);
    assert.deepEqual(named, [
      ["img", "Status chip: Reviewed", "false", "Reviewed"],
      ["img", "badge: Beta", "false", "Beta"],
      ["img", "future: [future]", "false", "[future]"],
    ]);
  });

  await check("only the declared kind is offered for insertion", () => {
    const rows = slashItemsForVocabulary([], parseVocabulary(JSON.stringify(VOCAB))).filter((r) => r.inline);
    assert.deepEqual(rows.map((r) => [r.inline, r.label, r.group]), [["chip", "Status chip", "Inline"]]);
    const vocab = canvas.inlineObjectVocabulary();
    const palette = buildCommandRegistry(editor, { inlineObjects: vocab.inlineObjects, onInlineInsert() {} });
    assert.deepEqual(palette.filter((c) => c.group === "Inline").map((c) => c.id), ["inline-chip"]);
  });

  // A "/chip" line at the end, then the slash pick.
  const endPos = () => editor.state.doc.content.size - 1;
  editor.commands.setTextSelection(endPos());
  editor.commands.splitBlock();
  editor.commands.insertContent("/chip");

  await check("a required field blocks Save, and Cancel inserts nothing", async () => {
    canvas._chooseSlash({ group: "Inline", type: "inline:chip", label: "Status chip", inline: "chip" });
    assert.ok(dialog(), "the dialog opened");
    assert.equal(dialog().getAttribute("role"), "dialog");
    assert.equal(dialog().querySelector("h2").textContent, "Edit Status chip");
    assert.equal(document.activeElement, field("text"), "focus lands on the first field");
    dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
    assert.ok(dialog(), "Save with an empty required field keeps the dialog open");
    assert.equal(field("text").getAttribute("aria-invalid"), "true");
    assert.equal(document.getElementById(field("text").getAttribute("aria-describedby")).textContent, "Required");
    key(dialog(), "Escape");
    assert.equal(dialog(), null, "Escape closes it");
    assert.equal(atoms().length, 3, "Cancel inserted nothing");
    assert.ok(!editor.state.doc.textContent.includes("/chip"), "the slash text is gone");
  });

  await check("the slash pick + Save puts the chip in the paragraph and the op carries it", async () => {
    ops.length = 0;
    editor.commands.insertContent("Now ");
    canvas._chooseSlash({ group: "Inline", type: "inline:chip", label: "Status chip", inline: "chip" });
    field("text").value = "Shipped";
    field("tone").value = "caution";
    dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
    assert.equal(dialog(), null);
    assert.equal(atoms().length, 4);
    canvas.flushPendingChanges();
    await tick(20);
    const added = ops.flatMap((op) => (op.block ? [op.block] : op.patch ? [op.patch] : []))
      .flatMap((b) => b.content || [])
      .find((n) => n.type === "chip" && n.text === "Shipped");
    assert.deepEqual(added, { type: "chip", text: "Shipped", tone: "caution" }, JSON.stringify(ops));
  });

  await check("Enter on a selected chip edits it and keeps the keys the dialog does not own", async () => {
    ops.length = 0;
    select("chip");
    key(editor.view.dom, "Enter");
    assert.ok(dialog(), "Enter opened the dialog");
    assert.equal(field("text").value, "Reviewed");
    assert.equal(field("tone").value, "positive");
    field("text").value = "Approved";
    dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
    canvas.flushPendingChanges();
    await tick(20);
    const patch = ops.find((op) => op.id === "p-chip");
    assert.ok(patch, JSON.stringify(ops));
    assert.deepEqual(patch.patch.content[1], { type: "chip", _key: "k1", text: "Approved", tone: "positive" });
  });

  await check("Enter on an undeclared atom opens no dialog", () => {
    select("badge");
    key(editor.view.dom, "Enter");
    assert.equal(dialog(), null);
    editor.commands.undo();
    assert.ok(atomOf("badge"), "the badge is still there after undoing whatever Enter did");
  });

  await check("the chip is reached by the arrow keys in reading order", () => {
    const { pos } = atomOf("chip");
    editor.commands.setTextSelection(pos);
    key(editor.view.dom, "ArrowRight", { keyCode: 39 });
    const sel = editor.state.selection;
    assert.ok(sel instanceof NodeSelection && sel.from === pos, `ArrowRight before the chip selects it (got ${sel.toJSON().type} ${sel.from})`);
  });

  await check("Backspace removes a selected chip and one undo restores it", () => {
    const before = atoms().length;
    select("chip");
    key(editor.view.dom, "Backspace");
    assert.equal(atoms().length, before - 1, "Backspace removed it");
    editor.commands.undo();
    assert.equal(atoms().length, before, "one undo restored it");
    assert.equal(atomOf("chip").node.attrs.node.text, "Approved");
  });

  await check("Delete removes a selected chip and one undo restores it", () => {
    const before = atoms().length;
    select("chip");
    key(editor.view.dom, "Delete");
    assert.equal(atoms().length, before - 1);
    editor.commands.undo();
    assert.equal(atoms().length, before);
  });

  await check("a double-click on a chip opens the dialog", () => {
    const { pos, node } = atomOf("chip");
    const handled = editor.view.someProp("handleDoubleClickOn", (f) => f(editor.view, pos, node, pos, null, true));
    assert.equal(handled, true);
    assert.ok(dialog());
    key(dialog(), "Escape");
  });

  await check("a server refusal reopens the dialog with the reason on the field it names", async () => {
    canvas.flushPendingChanges();
    await tick(20);
    canvas.acknowledgedSaves = true;
    let seq = null;
    canvas.addEventListener("bp-canvas-ops", (e) => { seq = e.detail.seq; }, { once: true });
    select("chip");
    key(editor.view.dom, "Enter");
    field("tone").value = "caution";
    dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
    canvas.flushPendingChanges();
    await tick(20);
    assert.ok(seq != null, "the save went out as an acknowledged batch");
    assert.equal(canvas.discardInflightOps(seq, { reason: "paragraph/content/1/tone: must be one of positive" }), true);
    assert.ok(dialog(), "the dialog reopened");
    assert.equal(field("tone").getAttribute("aria-invalid"), "true");
    assert.equal(
      document.getElementById(field("tone").getAttribute("aria-describedby")).textContent,
      "must be one of positive",
    );
    key(dialog(), "Escape");
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ninline object mounted: all checks passed");
  process.exit(0);
}
