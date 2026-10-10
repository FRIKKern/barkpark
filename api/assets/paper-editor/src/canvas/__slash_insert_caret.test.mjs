// Mounted regression: the first keystroke after a slash pick lands in the block
// the author picked.
//
// Found dogfooding the Studio canvas (2026-10-03):
//   * "/heading" landed "New heading" with a collapsed caret at its start, so
//     typing a title stored "My titleNew heading".
//   * "/code", "/diagram", "/action" landed the atom
//     NodeSelection-ed. Typing over a NodeSelection replaces the node, so the
//     first keystroke deleted the picked block and the text was stored as a
//     plain paragraph. (The ``` fence already handed the code textarea the caret;
//     the slash menu, palette and Mod-Shift-8 did not.)

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
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
globalThis.fetch = async () => ({ ok: true, json: async () => ({ documents: [] }) });
window.fetch = globalThis.fetch;
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");
const { insertSlashTypeAtSelection } = await import("./command-palette.js");
// The block holds the slash's own "/query", so the pick replaces it.
const SLASH_PICK = { replaceText: true };

const tick = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms));
const canvases = [];
const mount = async () => {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "Intro." }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "/" }] },
  ];
  document.body.appendChild(canvas);
  canvases.push(canvas);
  await tick(350);
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap editor is mounted");
  editor.commands.focus();
  editor.commands.setTextSelection(editor.state.doc.content.size - 1); // after the "/"
  return { canvas, editor };
};

try {
  // ── heading: the default text is selected, so typing overtypes it ──
  {
    const { canvas, editor } = await mount();
    assert.equal(insertSlashTypeAtSelection(editor, "heading", undefined, SLASH_PICK), true);
    const { selection } = editor.state;
    const picked = editor.state.doc.textBetween(selection.from, selection.to);
    assert.equal(picked, "New heading",
      "the heading's default text is selected after the pick, not a caret before it");
    editor.commands.insertContent("My title");
    const heading = editor.state.doc.lastChild;
    assert.equal(heading.type.name, "heading");
    assert.equal(heading.textContent, "My title", "typing replaces the default text");
    canvas.remove();
  }

  // ── atoms with an editing island: the island's text control takes the caret ──
  // The block's MAIN entry control, not merely the first one in the DOM: the code
  // body, not the language box. (Image and equation are left alone: the server
  // re-renders them as boundary editors right after the insert.)
  const expected = {
    code: ".bp-canvas-code-area",
    diagram: ".bp-canvas-diagram-area",
    action: ".bp-canvas-action-href",
  };
  for (const [type, selector] of Object.entries(expected)) {
    const { canvas, editor } = await mount();
    assert.equal(insertSlashTypeAtSelection(editor, type, undefined, SLASH_PICK), true, `${type} is insertable`);
    await tick(40);
    const active = document.activeElement;
    const blockDom = editor.view.nodeDOM(editor.state.selection.from);
    assert.ok(
      active && active.matches(selector) && blockDom?.contains(active),
      `${type}: ${selector} in the inserted block has focus (got ${active?.tagName}.${active?.className})`,
    );
    if (type === "diagram") {
      assert.equal(active.closest("details")?.open, true, "the diagram's source editor is opened");
    }
    canvas.remove();
  }

  // ── a divider: the caret lands on the line below, so typing keeps the divider ──
  {
    const { canvas, editor } = await mount();
    assert.equal(insertSlashTypeAtSelection(editor, "divider", undefined, SLASH_PICK), true);
    await tick(40);
    editor.commands.insertContent("After the rule");
    const types = [];
    editor.state.doc.forEach((node) => types.push(`${node.type.name}:${node.textContent}`));
    assert.deepEqual(types.slice(-2), ["divider:", "paragraph:After the rule"],
      `typing after a divider pick keeps the divider (got ${types.join(" | ")})`);
    canvas.remove();
  }

  console.log("PASS slash_insert_caret: the first keystroke after a slash pick lands in the picked block");
} finally {
  canvases.forEach((canvas) => canvas.remove());
  dom.window.close();
}
