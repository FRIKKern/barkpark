// Mounted regression (task-089f8a89b1f274ce): inserting a block never destroys the
// author's text.
//
// A palette "Insert <block>" with the caret in a paragraph that holds text REPLACED that
// paragraph, so the text was gone (probed: code, callout, heading, divider). Now a block
// that holds text keeps it and the new block lands after it; an empty paragraph is still
// replaced, and a slash pick still replaces its own "/query" line. One undo restores the
// exact prior document.
// Run: node src/canvas/__insert_keeps_text_mounted.test.mjs

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node",
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
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");
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
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return canvas;
}
const unmount = (canvas) => canvas.closest(".bp-paper-editor").remove();
const para = (id, text) => ({ id, type: "paragraph", content: text ? [{ type: "text", value: text }] : [] });
const top = (editor) => {
  const out = [];
  editor.state.doc.forEach((node) => out.push(node));
  return out;
};

// Every client-side palette insert: one per block type, the starters and the presets.
// (Terminal and Stage go through the server and never touch the block.)
const probe = await mount([para("p-0", "")]);
const INSERTS = buildCommandRegistry(probe._editor)
  .filter((c) => ["Insert", "Starters", "Presets"].includes(c.group))
  .map((c) => c.id);
unmount(probe);

try {
  await check("the palette offers the block kinds the bug was probed on", () => {
    for (const id of ["insert-code", "insert-callout", "insert-heading", "insert-divider"]) {
      assert.ok(INSERTS.includes(id), id);
    }
  });

  for (const id of INSERTS) {
    const canvas = await mount([para("p-1", "Precious text"), para("p-2", "Below")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 4)));
    editor.view.focus();
    const before = editor.getJSON();
    buildCommandRegistry(editor).find((c) => c.id === id).run(editor);
    const blocks = top(editor);
    await check(`palette ${id} keeps the paragraph's text and lands after it`, () => {
      assert.equal(blocks[0].type.name, "paragraph");
      assert.equal(blocks[0].textContent, "Precious text");
      assert.ok(blocks.length > 2, `something was inserted (${blocks.map((b) => b.type.name).join(", ")})`);
      assert.ok(!(blocks[1].type.name === "paragraph" && blocks[1].textContent === "Below"), "the new block sits right after the paragraph");
      assert.equal(blocks.at(-1).textContent, "Below");
    });
    editor.commands.undo();
    await check(`undo after palette ${id} restores the exact prior document`, () => {
      assert.deepEqual(editor.getJSON(), before);
    });
    unmount(canvas);
  }

  {
    const canvas = await mount([para("p-1", ""), para("p-2", "Below")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 1)));
    buildCommandRegistry(editor).find((c) => c.id === "insert-code").run(editor);
    await check("an empty paragraph is still replaced by the inserted block", () => {
      assert.deepEqual(top(editor).map((b) => b.type.name), ["bpCode", "paragraph"]);
    });
    unmount(canvas);
  }

  for (const type of ["code", "callout", "heading", "divider"]) {
    const canvas = await mount([para("p-1", `/${type}`), para("p-2", "Below")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 2 + type.length)));
    canvas._chooseSlash(canvas._slashItems?.find?.((it) => it.type === type) || { type });
    await check(`a slash pick of ${type} still replaces its own "/${type}" line`, () => {
      const blocks = top(editor);
      assert.ok(!blocks.some((b) => b.textContent.startsWith("/")), blocks.map((b) => b.textContent).join(" | "));
      assert.equal(blocks.at(-1).textContent, "Below");
    });
    unmount(canvas);
  }
} catch (error) {
  failures += 1;
  console.log(`FAIL  harness: ${error.stack}`);
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall insert-keeps-text checks passed");
process.exit(0);
