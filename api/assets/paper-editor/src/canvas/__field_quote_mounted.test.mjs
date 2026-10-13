// __field_quote_mounted.test.mjs — task-071f8c843336d12e, in a real mounted canvas:
// in a field whose vocabulary has the blockquote STYLE, `> ` and the slash menu's
// Quote make a pullquote (the block that style means), and the ops carry it; on a
// paper canvas (no vocabulary) `> ` still makes the plain blockquote.
// Run: node src/canvas/__field_quote_mounted.test.mjs
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

await import("./index.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const BLOCKS = [{ id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] }];
const VOCAB = JSON.stringify({ styles: ["normal", "h2", "blockquote"], lists: ["bullet"], marks: ["strong", "em"] });

async function mount(vocabulary) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  if (vocabulary) canvas.setAttribute("data-vocabulary", vocabulary);
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the canvas editor is mounted");
  return canvas;
}
function newLineAfterFirst(editor, text) {
  const first = editor.state.doc.child(0);
  editor.chain().focus().setTextSelection(first.nodeSize - 1).splitBlock().insertContent(text).run();
}
const nodeTypes = (editor) => { const t = []; editor.state.doc.forEach((n) => t.push(n.type.name)); return t; };
const opsBlocks = (events) => events.flatMap((ops) => ops).filter((op) => op.block).map((op) => op.block.type);

let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS  ${name}`); } catch (error) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${error.message}`); }
}

try {
  {
    const canvas = await mount(VOCAB);
    const editor = canvas._editor, ops = [];
    canvas.addEventListener("bp-canvas-ops", (e) => ops.push(e.detail.ops));
    newLineAfterFirst(editor, "> ");
    canvas._maybeBlockShorthand();
    editor.commands.insertContent("Quoted");
    canvas.flushPendingChanges();
    await tick(400);
    check("in a blockquote-style field, `> ` makes a pullquote with the text in it", () => {
      assert.deepEqual(nodeTypes(editor), ["paragraph", "pullquote"]);
      assert.equal(editor.state.doc.child(1).textContent, "Quoted");
    });
    check("the field ops carry a pullquote block, the type the field-ops route accepts", () => {
      assert.ok(opsBlocks(ops).includes("pullquote"), JSON.stringify(ops));
      assert.ok(!opsBlocks(ops).includes("blockquote"));
    });
    canvas.closest(".bp-paper-editor").remove();
  }
  {
    const canvas = await mount(VOCAB);
    const editor = canvas._editor;
    newLineAfterFirst(editor, "/quote");
    const row = canvas._slash?.isOpen() ? canvas._slash._items.find((i) => i.type === "blockquote") : null;
    check("the field's slash menu offers Quote", () => assert.ok(row, "a Quote row"));
    if (row) canvas._chooseSlash(row);
    check("choosing Quote in that field makes a pullquote and drops the /quote text", () => {
      assert.deepEqual(nodeTypes(editor), ["paragraph", "pullquote"]);
      assert.ok(!editor.state.doc.textContent.includes("/quote"));
    });
    canvas.closest(".bp-paper-editor").remove();
  }
  {
    const canvas = await mount(null);
    const editor = canvas._editor;
    newLineAfterFirst(editor, "> ");
    canvas._maybeBlockShorthand();
    check("on a paper canvas `> ` still makes the plain blockquote", () => {
      assert.deepEqual(nodeTypes(editor), ["paragraph", "blockquote"]);
    });
    canvas.closest(".bp-paper-editor").remove();
  }
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nfield quote: all checks passed");
  process.exit(0);
}
