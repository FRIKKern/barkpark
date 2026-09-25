// __ime_composition.test.mjs — an open IME composition holds the ops debounce (Barkdown row 15).
// ProseMirror reads the IME's candidate text into the doc while the composition is open; the canvas
// must not emit that half-composed run as a patch. With `compositionstart` seen on the editable, a
// change waits past the debounce; `compositionend` releases exactly one batch carrying the full run.
// Run: node src/canvas/__ime_composition.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "CompositionEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (v) => String(v) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);
const { DEBOUNCE_MS } = await import("../contract.js");

let failures = 0;
async function check(name, fn) { try { await fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e && e.stack ? e.stack.split("\n").slice(0, 3).join("\n      ") : e}`); } }
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

async function mount() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "CJK: " }] }];
  document.body.appendChild(canvas);
  await tick(0);
  assert.ok(canvas._editor, "editor mounted");
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(JSON.parse(JSON.stringify(e.detail?.ops || e.detail || []))));
  return { canvas, batches };
}
const textOf = (batch) => JSON.stringify(batch);
const composeStart = (canvas) => canvas._editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
const composeEnd = (canvas, data) => canvas._editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data }));

await check("compositionstart on the editable sets ProseMirror's composing flag", async () => {
  const { canvas } = await mount();
  composeStart(canvas);
  assert.equal(canvas._editor.view.composing, true);
  composeEnd(canvas, "");
  canvas.remove();
});

await check("a change made while composing is NOT emitted past the debounce; compositionend releases one batch with the whole run", async () => {
  const { canvas, batches } = await mount();
  composeStart(canvas);
  canvas._editor.commands.setTextSelection(canvas._editor.state.doc.content.size - 1);
  canvas._editor.commands.insertContent("に");
  await tick(DEBOUNCE_MS + 150);
  assert.equal(batches.length, 0, `emitted mid-composition: ${textOf(batches)}`);
  canvas._editor.commands.insertContent("ほん");
  await tick(DEBOUNCE_MS + 150);
  assert.equal(batches.length, 0, `emitted mid-composition (second update): ${textOf(batches)}`);
  // The IME commits: ProseMirror clears `composing` on compositionend (after its own settle), then the
  // canvas's one-shot listener re-arms the debounce and the run lands once.
  composeEnd(canvas, "にほん");
  await tick(DEBOUNCE_MS + 250);
  assert.equal(batches.length, 1, `expected one batch after compositionend: ${textOf(batches)}`);
  const patch = batches[0].find((op) => op.op === "patch-block");
  assert.ok(patch, "a patch-block");
  assert.equal(patch.patch.content.map((n) => n.value).join(""), "CJK: にほん");
  canvas.remove();
});

await check("without a composition the debounce behaves as before (one batch after DEBOUNCE_MS)", async () => {
  const { canvas, batches } = await mount();
  canvas._editor.commands.setTextSelection(canvas._editor.state.doc.content.size - 1);
  canvas._editor.commands.insertContent("x");
  await tick(DEBOUNCE_MS + 150);
  assert.equal(batches.length, 1, textOf(batches));
  canvas.remove();
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
