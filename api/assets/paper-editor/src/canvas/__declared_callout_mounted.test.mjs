// __declared_callout_mounted.test.mjs — task-5bc7771edf30199a. A field that
// DECLARES an object block named `callout` (Sanity's `{tone, text}`) means its
// own callout, not the canvas's built-in one:
//
//   * a stored declared callout projects as a carried block, round-trips
//     byte-identical, and Enter opens the field dialog with exactly its declared
//     fields, tone limited to the declared options;
//   * the slash menu offers the declared callout, not the built-in one, and the
//     pick opens the dialog;
//   * a canvas with no such declaration keeps the built-in callout unchanged.
// Run: node src/canvas/__declared_callout_mounted.test.mjs
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
const { docToBlocks, runToTiptap } = await import("./run-convert.js");
const vocabularyModule = await import("./vocabulary.js");
const { NodeSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);

const DECLARED = {
  styles: ["normal"],
  of: [{
    name: "callout",
    title: "Callout",
    fields: [
      { name: "tone", title: "Tone", type: "string", options: { list: ["info", "warning", "danger"] } },
      { name: "text", title: "Text", type: "text" },
    ],
  }],
};
const CALLOUT = { id: "c1", type: "callout", tone: "info", text: "Mind the gap." };
const PARA = { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro." }] };

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
    console.log(`      ${e.message.split("\n").slice(0, 4).join(" | ")}`);
  }
}
const EXPECTED = 6;

const dialog = () => document.querySelector(".bp-inline-object-dialog");
function key(el, name, extra = {}) {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...extra }));
}

async function mount(vocab) {
  const canvas = document.createElement("bp-paper-canvas");
  if (vocab) canvas.setAttribute("data-vocabulary", JSON.stringify(vocab));
  canvas.blocks = JSON.parse(JSON.stringify([CALLOUT, PARA]));
  document.body.appendChild(canvas);
  await tick(350);
  return canvas;
}
const topNodes = (editor) => {
  const out = [];
  editor.state.doc.forEach((node, pos) => out.push({ node, pos }));
  return out;
};

try {
  const declared = await mount(DECLARED);
  const editor = declared._editor;
  const calloutNode = () => topNodes(editor).find((n) => n.node.attrs.bpId === "c1");

  await check("a declared callout projects as a carried block and round-trips byte-identical", () => {
    assert.equal(calloutNode().node.type.name, "bpOpaque");
    assert.equal(canonical(docToBlocks(editor.getJSON()).find((b) => b.id === "c1")), canonical(CALLOUT));
  });

  await check("Enter opens the dialog with exactly the declared fields, tone limited to the declared options", () => {
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, calloutNode().pos)));
    key(editor.view.dom, "Enter");
    assert.ok(dialog(), "the field dialog opened");
    const fields = [...dialog().querySelectorAll("[data-field]")].map((el) => el.dataset.field);
    assert.deepEqual(fields, ["tone", "text"]);
    const tone = dialog().querySelector('[data-field="tone"]');
    assert.equal(tone.tagName, "SELECT");
    assert.deepEqual([...tone.options].map((o) => o.value), ["", "info", "warning", "danger"]);
    assert.equal(tone.value, "info");
    assert.equal(dialog().querySelector('[data-field="text"]').value, "Mind the gap.");
    key(dialog(), "Escape");
  });

  await check("the slash menu offers the declared callout, not the built-in one, and the pick opens the dialog", () => {
    const { slashItemsForVocabulary, parseVocabulary } = vocabularyModule;
    const offered = slashItemsForVocabulary(
      [{ group: "Text", type: "callout", label: "Callout", desc: "warn or info card" }, { group: "Text", type: "paragraph", label: "Paragraph" }],
      parseVocabulary(JSON.stringify(DECLARED)),
    );
    const callouts = offered.filter((r) => r.type === "callout");
    assert.equal(callouts.length, 1, JSON.stringify(offered));
    assert.equal(callouts[0].object, true, "the declared row, not the built-in one");
    editor.commands.setTextSelection(editor.state.doc.content.size - 1);
    editor.commands.splitBlock();
    editor.commands.insertContent("/call");
    declared._chooseSlash(callouts[0]);
    assert.ok(dialog(), "the pick opened the field dialog");
    key(dialog(), "Escape");
  });

  declared.remove();
  const builtin = await mount(null);
  const bEditor = builtin._editor;

  await check("with no declaration the callout is the built-in node, unchanged", () => {
    const node = topNodes(bEditor).find((n) => n.node.attrs.bpId === "c1").node;
    assert.equal(node.type.name, "callout");
    assert.equal(node.attrs.tone, "info");
  });

  await check("with no declaration Enter on it opens no field dialog", () => {
    const at = topNodes(bEditor).find((n) => n.node.attrs.bpId === "c1").pos;
    bEditor.view.dispatch(bEditor.state.tr.setSelection(NodeSelection.create(bEditor.state.doc, at)));
    key(bEditor.view.dom, "Enter");
    assert.equal(dialog(), null);
  });

  await check("two canvases do not share the override (the scope ends with each call)", async () => {
    const again = await mount(DECLARED);
    assert.equal(topNodes(again._editor).find((n) => n.node.attrs.bpId === "c1").node.type.name, "bpOpaque");
    assert.equal(topNodes(bEditor).find((n) => n.node.attrs.bpId === "c1").node.type.name, "callout");
    assert.equal(canonical(runToTiptap([CALLOUT]).content[0].type), canonical("callout"), "a bare projection is unaffected");
    again.remove();
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ndeclared callout mounted: all checks passed");
  process.exit(0);
}
