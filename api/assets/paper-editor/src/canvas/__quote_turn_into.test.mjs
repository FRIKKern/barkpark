// Mounted regression: a paragraph turns into a quote and back, keeping its id.
//
// Owner ruling 2026-10-03 #62 (Barkdown FRIKKern/barkdown#16): the plain quote block
// works end to end — `> ` makes a quote, `> [!note] ` still makes a callout, the slash
// menu offers Quote, and turn-into goes both ways. On main the `> ` shorthand, the
// callout gesture and the slash/palette Quote existed, but the block menu and the
// command palette had no "Turn into Quote", and Backspace at the start of a quote
// joined it into the block above instead of turning it back into text.
//
//   1. Block menu: TURN_INTO lists Quote; turnTopLevelInto(quote) makes a blockquote
//      with the same text and the same block id; turnTopLevelInto(paragraph) turns it
//      back, same id. The save is a same-id replace-block, never remove + insert.
//   2. Palette: Turn into Quote exists and works.
//   3. Backspace at the start of a quote turns it into a paragraph (the pullquote rule).
//   4. `> ` still makes a quote and `> [!note] ` inside it still makes a callout.

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
const { TextSelection } = await import("@tiptap/pm/state");
const { TURN_INTO, turnTopLevelInto } = await import("./block-handle.js");
const { buildCommandRegistry } = await import("./command-palette.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

async function mount(blocks) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return { canvas, batches };
}

const para = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });

function typeText(editor, text) {
  const { view } = editor;
  for (const ch of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, ch, () => view.state.tr.insertText(ch, from, to)));
    if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to));
  }
}

try {
  await check("the block menu's Turn into lists Quote", () => {
    assert.ok(TURN_INTO.some((t) => t.kind === "quote" && t.label === "Quote"));
  });

  {
    const { canvas, batches } = await mount([para("p-a", "Alpha"), para("p-b", "Quoted words")]);
    const editor = canvas._editor;
    await check("Turn into Quote makes a blockquote with the same text and id", () => {
      assert.equal(turnTopLevelInto(editor, 1, "quote"), true);
      const node = editor.state.doc.child(1);
      assert.equal(node.type.name, "blockquote");
      assert.equal(node.textContent, "Quoted words");
      assert.equal(node.attrs.bpId, "p-b");
    });
    canvas.flushPendingChanges();
    await check("the save is a same-id replace-block to a blockquote", () => {
      const ops = batches.flat();
      assert.ok(!ops.some((op) => op.op === "remove-block"), JSON.stringify(ops));
      const replace = ops.find((op) => op.id === "p-b");
      assert.ok(replace, JSON.stringify(ops));
      assert.equal((replace.block || replace.patch || {}).type, "blockquote", JSON.stringify(replace));
    });
    batches.length = 0;
    await check("Turn into Text turns the quote back, same id", () => {
      assert.equal(turnTopLevelInto(editor, 1, "paragraph"), true);
      const node = editor.state.doc.child(1);
      assert.equal(node.type.name, "paragraph");
      assert.equal(node.textContent, "Quoted words");
      assert.equal(node.attrs.bpId, "p-b");
    });
    canvas.flushPendingChanges();
    await check("and that save is a same-id replace too", () => {
      const ops = batches.flat();
      assert.ok(!ops.some((op) => op.op === "remove-block"), JSON.stringify(ops));
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  {
    const { canvas } = await mount([para("p-a", "Palette me")]);
    const editor = canvas._editor;
    const registry = buildCommandRegistry(editor);
    const cmd = registry.find((c) => c.id === "turn-quote");
    await check("the palette offers Turn into Quote", () => assert.ok(cmd));
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 2)));
    cmd?.run(editor);
    await check("Turn into Quote from the palette makes a blockquote", () => {
      assert.equal(editor.state.doc.child(0).type.name, "blockquote");
      assert.equal(editor.state.doc.child(0).attrs.bpId, "p-a");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  {
    const { canvas } = await mount([para("p-a", "Above"), { id: "q-1", type: "blockquote", content: [{ type: "text", value: "A quote" }] }]);
    const editor = canvas._editor;
    const start = editor.state.doc.child(0).nodeSize + 1;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, start)));
    editor.view.focus();
    canvas.querySelector(".ProseMirror").dispatchEvent(new window.KeyboardEvent("keydown", { key: "Backspace", keyCode: 8, bubbles: true, cancelable: true }));
    await check("Backspace at the start of a quote turns it into a paragraph, not a join", () => {
      assert.equal(editor.state.doc.childCount, 2, "no join into the block above");
      assert.equal(editor.state.doc.child(1).type.name, "paragraph");
      assert.equal(editor.state.doc.child(1).textContent, "A quote");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  {
    const { canvas } = await mount([para("p-a", "Intro"), { id: "p-b", type: "paragraph", content: [] }]);
    const editor = canvas._editor;
    const start = editor.state.doc.child(0).nodeSize + 1;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, start)));
    editor.view.focus();
    typeText(editor, "> ");
    await check("`> ` makes a quote", () => {
      assert.equal(editor.state.doc.child(1).type.name, "blockquote");
    });
    typeText(editor, "[!note] ");
    await check("`> [!note] ` still makes a callout", () => {
      assert.equal(editor.state.doc.child(1).type.name, "callout");
    });
    canvas.closest(".bp-paper-editor").remove();
  }
} finally {
  dom.window.close();
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nquote_turn_into: quote and paragraph turn into each other, same id");
process.exit(0);
