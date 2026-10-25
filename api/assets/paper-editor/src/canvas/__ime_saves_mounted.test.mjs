// __ime_saves_mounted.test.mjs — task-39cb3d6e4709054e. An open IME composition held EVERY save
// (_scheduleEmit re-armed while composing): continuous Japanese typing stored 0 characters in
// 12.5 s, and leaving the page mid-composition lost the paragraphs already committed. Now the
// debounce sends the committed text with only the composing run left out, a committed phrase
// is sent at its compositionend, pagehide sends what is committed at once, and an open
// composition counts as unsaved for the page's exit guard. __ime_composition.test.mjs keeps the
// other half: the half-composed run itself is never sent.
// Run: node src/canvas/__ime_saves_mounted.test.mjs   (or: npm test)
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

await import("./index.js");
const { DEBOUNCE_MS } = await import("../contract.js");

let failures = 0;
async function check(name, fn) { try { await fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e && e.stack ? e.stack.split("\n").slice(0, 3).join("\n      ") : e}`); } }
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

async function mount() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [
    { id: "p1", type: "paragraph", content: [{ type: "text", value: "One." }] },
    { id: "p2", type: "paragraph", content: [{ type: "text", value: "CJK: " }] },
  ];
  document.body.appendChild(canvas);
  await tick(0);
  assert.ok(canvas._editor, "editor mounted");
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(JSON.parse(JSON.stringify(e.detail.ops))));
  return { canvas, batches };
}
// What the server holds for a block: its content in the last batch that patched it.
function stored(batches, id) {
  for (let i = batches.length - 1; i >= 0; i--) {
    const op = batches[i].find((o) => o.op === "patch-block" && o.id === id && o.patch?.content);
    if (op) return op.patch.content.map((n) => n.value).join("");
  }
  return null;
}
const endOf = (canvas, index) => {
  let end = 0;
  canvas._editor.state.doc.forEach((node, offset, i) => { if (i === index) end = offset + node.nodeSize - 1; });
  return end;
};
// A real IME: the caret sits where the run will go, compositionstart, the candidate text grows
// in place (ProseMirror reads it into the doc), compositionend commits it.
const composeStart = (canvas) => canvas._editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
const composeEnd = (canvas, data) => canvas._editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data }));
const candidate = (canvas, text) => canvas._editor.commands.insertContent(text);

await check("text committed before a composition is saved while it stays open; the composing run is not", async () => {
  const { canvas, batches } = await mount();
  canvas._editor.commands.setTextSelection(endOf(canvas, 0));
  canvas._editor.commands.insertContent(" Two.");
  canvas._editor.commands.setTextSelection(endOf(canvas, 1));
  canvas._editor.commands.insertContent("abc");
  composeStart(canvas);
  candidate(canvas, "に");
  await tick(DEBOUNCE_MS + 100);
  candidate(canvas, "ほん");
  assert.equal(stored(batches, "p1"), "One. Two.");
  assert.equal(stored(batches, "p2"), "CJK: abc", JSON.stringify(batches));
  assert.equal(canvas.hasPendingChanges(), true, "the open composition is unsaved for the exit guard");
  composeEnd(canvas, "にほん");
  await tick(DEBOUNCE_MS + 150);
  assert.equal(stored(batches, "p2"), "CJK: abcにほん");
  assert.equal(canvas.hasPendingChanges(), false);
  canvas.remove();
});

await check("continuous typing: every committed phrase is saved at its compositionend, before the debounce", async () => {
  const { canvas, batches } = await mount();
  canvas._editor.commands.setTextSelection(endOf(canvas, 1));
  let text = "CJK: ";
  for (const phrase of ["日本", "語を", "書く"]) {
    composeStart(canvas);
    candidate(canvas, phrase[0]);
    candidate(canvas, phrase[1]);
    composeEnd(canvas, phrase);
    text += phrase;
    // The next phrase starts well inside DEBOUNCE_MS: the old hold never saved anything.
    await tick(Math.min(120, DEBOUNCE_MS / 2));
    assert.equal(stored(batches, "p2"), text, `after "${phrase}"`);
  }
  canvas.remove();
});

await check("leaving the page mid-composition sends what is committed at once", async () => {
  const { canvas, batches } = await mount();
  canvas._editor.commands.setTextSelection(endOf(canvas, 0));
  canvas._editor.commands.insertContent(" Kept.");
  canvas._editor.commands.setTextSelection(endOf(canvas, 1));
  composeStart(canvas);
  candidate(canvas, "途中");
  assert.equal(batches.length, 0);
  window.dispatchEvent(new window.Event("pagehide"));
  assert.equal(batches.length, 1, "sent synchronously on pagehide");
  assert.equal(stored(batches, "p1"), "One. Kept.");
  assert.equal(stored(batches, "p2"), null, "the composing run stays out");
  assert.equal(canvas.hasPendingChanges(), true, "the host still keeps the composing run");
  composeEnd(canvas, "途中");
  await tick(DEBOUNCE_MS + 150);
  canvas.remove();
});

await check("a composition in a paragraph that still needs its id waits for compositionend (no stamp mid-composition)", async () => {
  const { canvas, batches } = await mount();
  canvas._editor.commands.setTextSelection(endOf(canvas, 1));
  canvas._editor.commands.splitBlock();
  const before = canvas._editor.state.doc.childCount;
  composeStart(canvas);
  candidate(canvas, "新");
  await tick(DEBOUNCE_MS + 100);
  assert.equal(batches.length, 0, JSON.stringify(batches));
  assert.equal(canvas._editor.state.doc.childCount, before);
  composeEnd(canvas, "新");
  await tick(DEBOUNCE_MS + 150);
  const insert = batches.flat().find((op) => op.op === "insert-after" && op.block?.content?.[0]?.value === "新");
  assert.ok(insert, JSON.stringify(batches));
  assert.notEqual(insert.block.id, "p2", "the new paragraph gets its own id");
  canvas.remove();
});

await check("a composition over a selection (the IME replaces it) cannot tell the run apart and holds", async () => {
  const { canvas, batches } = await mount();
  canvas._editor.commands.setTextSelection({ from: 1, to: 4 });
  composeStart(canvas);
  candidate(canvas, "壱");
  await tick(DEBOUNCE_MS + 100);
  assert.equal(batches.length, 0, JSON.stringify(batches));
  composeEnd(canvas, "壱");
  await tick(DEBOUNCE_MS + 150);
  assert.equal(stored(batches, "p1"), "壱.");
  canvas.remove();
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
