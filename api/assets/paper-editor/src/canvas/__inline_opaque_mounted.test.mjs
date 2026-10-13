// __inline_opaque_mounted.test.mjs — task-a110126ce9111388 (P1 data loss), in a
// real mounted canvas: a paragraph holding a `chip` (an inline node the editor
// has no UI for) shows it as an inert atom, and an edit to another block, or to
// other text in the same paragraph, never drops it from what the canvas saves.
// Run: node src/canvas/__inline_opaque_mounted.test.mjs
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
await import("./index.js");
const { docToBlocks } = await import("./run-convert.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
// Canonical JSON (sorted keys): the mounted editor re-serializes this untouched
// paragraph (the wikilink's docId key moves after children; jsonb keeps no key
// order) — which is exactly the path that dropped the chip. Values and array
// order are compared exactly.
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);
const CHIP = { type: "chip", text: "Reviewed", tone: "positive" };
const P2 = {
  id: "p2",
  type: "paragraph",
  content: [
    { type: "text", value: "Status " },
    CHIP,
    { type: "text", value: ", written with " },
    { type: "wikilink", target: "Ada", docId: "author-ada", children: [{ type: "text", value: "Ada" }] },
  ],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro" }] },
  P2,
  { id: "p3", type: "paragraph", content: [{ type: "text", value: "Outro" }] },
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
  const p2Dom = () => editor.view.nodeDOM(canvas._topLevelPos("p2"));

  check("the chip renders as an inert atom with its label", () => {
    const atom = p2Dom().querySelector(".bp-inline-opaque");
    assert.ok(atom, p2Dom().innerHTML);
    assert.equal(atom.getAttribute("contenteditable"), "false");
    assert.equal(atom.textContent, "Reviewed");
    assert.equal(atom.getAttribute("data-bp-inline-type"), "chip");
  });

  check("a load with no edit saves the chip paragraph byte-identical", () => {
    const saved = docToBlocks(editor.getJSON()).find((b) => b.id === "p2");
    assert.equal(canonical(saved), canonical(P2), JSON.stringify(saved));
  });

  // Type into ANOTHER block (the J11 case: the author edits elsewhere).
  const endOf = (id) => canvas._topLevelPos(id) + editor.state.doc.nodeAt(canvas._topLevelPos(id)).nodeSize - 1;
  editor.chain().setTextSelection(endOf("p3")).insertContent("!").run();
  canvas.flushPendingChanges();
  await tick(50);

  check("an edit in another block emits no op that touches the chip paragraph", () => {
    assert.ok(ops.length > 0, "the edit emitted ops");
    const touching = ops.filter((op) => op.id === "p2" || (op.block && op.block.id === "p2"));
    assert.deepEqual(touching, [], JSON.stringify(ops));
  });

  // Now edit OTHER text in the chip's own paragraph.
  ops.length = 0;
  editor.chain().setTextSelection(canvas._topLevelPos("p2") + 1).insertContent("New ").run();
  canvas.flushPendingChanges();
  await tick(50);

  check("an edit to other text in the same paragraph keeps the chip verbatim", () => {
    const patch = ops.find((op) => op.id === "p2");
    assert.ok(patch, JSON.stringify(ops));
    const content = (patch.patch && patch.patch.content) || [];
    assert.ok(content.some((n) => JSON.stringify(n) === JSON.stringify(CHIP)), JSON.stringify(content));
    assert.equal(content[0].value, "New Status ");
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.message}`);
} finally {
  if (ran !== 4) { failures += 1; console.log(`FAIL  ran ${ran} of 4 checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ninline opaque mounted: all checks passed");
  process.exit(0);
}
