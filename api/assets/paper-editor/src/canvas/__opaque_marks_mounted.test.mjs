// __opaque_marks_mounted.test.mjs — task-6d27394284ce6cff (silent data loss), in the
// real mounted editors: a text leaf with a flat mark the editor has no UI for
// ({type:"smallcaps"}, an annotation) keeps it through the TipTap schema, so a
// load with no edit and an edit to other text in the same paragraph both save it
// back. Covers <bp-paper-canvas> and the per-block <bp-paper-editor>.
// Run: node src/canvas/__opaque_marks_mounted.test.mjs
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
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("../index.js");
const { docToBlocks } = await import("./run-convert.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const MARKED = {
  type: "text",
  value: "Ibsen",
  marks: [{ type: "strong" }, { type: "smallcaps" }, { type: "annotation", attrs: { id: "a1" } }],
};
const P2 = {
  id: "p2",
  type: "paragraph",
  content: [{ type: "text", value: "Read " }, MARKED, { type: "text", value: " today." }],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro" }] },
  P2,
];
let ran = 0;
let failures = 0;
function check(name, fn) { ran += 1; try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message.split("\n")[0]}`); } }

try {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  const editor = canvas._editor;

  check("canvas: the schema holds the unknown marks", () => {
    const run = editor.getJSON().content[1].content.find((n) => n.text === "Ibsen");
    assert.deepEqual(run.marks.filter((m) => m.type === "bpOpaqueMark").map((m) => m.attrs.mark),
      [{ type: "smallcaps" }, { type: "annotation", attrs: { id: "a1" } }], JSON.stringify(run));
  });

  check("canvas: a load with no edit saves the marked leaf byte-identical", () => {
    const saved = docToBlocks(editor.getJSON()).find((b) => b.id === "p2");
    assert.equal(JSON.stringify(saved), JSON.stringify(P2));
  });

  editor.chain().setTextSelection(canvas._topLevelPos("p2") + 1).insertContent("Do ").run();
  canvas.flushPendingChanges();
  await tick(50);

  check("canvas: an edit to other text in the paragraph keeps the marks", () => {
    const patch = ops.find((op) => op.id === "p2");
    assert.ok(patch, JSON.stringify(ops));
    const content = (patch.patch && patch.patch.content) || [];
    assert.equal(content[0].value, "Do Read ");
    assert.ok(content.some((n) => JSON.stringify(n) === JSON.stringify(MARKED)), JSON.stringify(content));
  });

  // Type INSIDE the marked word: the edited leaf is re-serialized, not reused.
  ops.length = 0;
  editor.chain().setTextSelection(canvas._topLevelPos("p2") + 1 + "Do Read Ib".length).insertContent("x").run();
  canvas.flushPendingChanges();
  await tick(50);

  check("canvas: an edit inside the marked text keeps every mark in its stored order", () => {
    const patch = ops.find((op) => op.id === "p2");
    assert.ok(patch, JSON.stringify(ops));
    const content = (patch.patch && patch.patch.content) || [];
    const marked = content.filter((n) => n.marks);
    assert.equal(marked.map((n) => n.value).join(""), "Ibxsen", JSON.stringify(content));
    for (const n of marked) assert.deepEqual(n.marks, MARKED.marks, JSON.stringify(content));
  });

  const block = document.createElement("bp-paper-editor");
  block.block = JSON.parse(JSON.stringify(P2));
  let emitted = null;
  block.addEventListener("bp-op", (e) => { emitted = e.detail; });
  document.body.appendChild(block);
  const ed = block._editor;

  check("per-block editor: the schema holds the unknown marks", () => {
    const run = ed.getJSON().content[0].content.find((n) => n.text === "Ibsen");
    assert.deepEqual(run.marks.filter((m) => m.type === "bpOpaqueMark").map((m) => m.attrs.mark),
      [{ type: "smallcaps" }, { type: "annotation", attrs: { id: "a1" } }], JSON.stringify(run));
  });

  ed.view.dispatch(ed.state.tr.insertText("Do ", 1));
  block.flushPendingChanges();

  check("per-block editor: an edit to other text in the paragraph keeps the marks", () => {
    assert.ok(emitted && emitted.op === "patch-block", JSON.stringify(emitted));
    const content = emitted.patch.content;
    assert.equal(content[0].value, "Do Read ");
    assert.ok(content.some((n) => JSON.stringify(n) === JSON.stringify(MARKED)), JSON.stringify(content));
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.message}`);
} finally {
  if (ran !== 6) { failures += 1; console.log(`FAIL  ran ${ran} of 6 checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nopaque marks mounted: all checks passed");
  process.exit(0);
}
