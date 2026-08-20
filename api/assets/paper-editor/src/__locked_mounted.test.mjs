// Mounted jsdom regression for the doctrine lock veto. Unlike __locked.test.mjs,
// this imports and mounts the real <bp-paper-canvas>, dispatches a browser keydown
// through its ProseMirror DOM, and therefore fails if bpLockVeto stops registering
// its filterTransaction plugin.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});

const { window } = dom;
for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "DOMParser",
  "Element",
  "Event",
  "EventTarget",
  "HTMLElement",
  "KeyboardEvent",
  "MutationObserver",
  "Node",
  "NodeFilter",
  "Selection",
  "Text",
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
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperCanvas } = await import("./canvas/index.js");
const { TextSelection } = await import("@tiptap/pm/state");
const { Fragment } = await import("@tiptap/pm/model");

assert.equal(
  customElements.get("bp-paper-canvas"),
  BpPaperCanvas,
  "the real canvas entrypoint registers its exported custom element",
);

const title = {
  id: "tpl-title",
  type: "heading",
  level: 1,
  role: "title",
  locked: true,
  text: "Doctrine",
};
const body = {
  id: "tpl-body",
  type: "paragraph",
  content: [{ type: "text", value: "Body." }],
};
const controlTitle = {
  id: "control-title",
  type: "heading",
  level: 1,
  text: "Unlocked",
};
const controlBody = {
  id: "control-body",
  type: "paragraph",
  content: [{ type: "text", value: "Control body." }],
};

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [title, body];
// A locked featured image follows this prose run in the real doctrine layout.
// The host stamps this attribute so Enter cannot grow the run and displace it.
canvas.setAttribute("data-locked-tail", "true");
let opsEvents = 0;
canvas.addEventListener("bp-canvas-ops", () => opsEvents++);
document.body.appendChild(canvas);
const controlCanvas = document.createElement("bp-paper-canvas");
controlCanvas.blocks = [controlTitle, controlBody];
let controlOpsEvents = 0;
controlCanvas.addEventListener("bp-canvas-ops", () => controlOpsEvents++);
document.body.appendChild(controlCanvas);
// TipTap's initial content normalization may schedule the normal 300 ms diff
// debounce. Let that mount-only work settle so the assertions below observe only
// the user transactions driven by this regression.
await new Promise((resolve) => setTimeout(resolve, 350));
opsEvents = 0;
controlOpsEvents = 0;

try {
  const { _editor: editor } = canvas;
  assert.ok(editor, "mount creates the real TipTap editor");
  const proseMirror = canvas.querySelector(".ProseMirror");
  assert.ok(proseMirror, "mount creates the real ProseMirror DOM");

  const original = editor.getJSON();
  const titleEnd = editor.state.doc.child(0).nodeSize - 1;
  editor.view.dispatch(
    editor.state.tr.setSelection(TextSelection.create(editor.state.doc, titleEnd)),
  );

  const enter = new window.KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  });
  proseMirror.dispatchEvent(enter);
  assert.deepEqual(
    editor.getJSON(),
    original,
    "Enter at the locked title end is a calm no-op (no local split)",
  );

  const beforeDelete = editor.getJSON();
  const deleteLockedTitle = editor.state.tr.delete(
    0,
    editor.state.doc.child(0).nodeSize,
  );
  editor.view.dispatch(deleteLockedTitle);
  assert.deepEqual(
    editor.getJSON(),
    beforeDelete,
    "a real transaction cannot delete the mounted locked title",
  );

  const beforeMove = editor.getJSON();
  const moved = Fragment.fromArray([
    editor.state.doc.child(1),
    editor.state.doc.child(0),
  ]);
  editor.view.dispatch(
    editor.state.tr.replaceWith(0, editor.state.doc.content.size, moved),
  );
  assert.deepEqual(
    editor.getJSON(),
    beforeMove,
    "a real transaction cannot move the mounted locked title",
  );
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(opsEvents, 0, "vetoed edits emit no canvas operation event");

  const contentEditAt = editor.state.doc.child(0).nodeSize - 1;
  editor.view.dispatch(editor.state.tr.insertText("!", contentEditAt));
  assert.equal(
    editor.getJSON().content[0].content[0].text,
    "Doctrine!",
    "content editing inside the locked title remains allowed",
  );

  const controlEditor = controlCanvas._editor;
  assert.ok(controlEditor, "the unlocked control mounts the real TipTap editor");
  const controlProseMirror = controlCanvas.querySelector(".ProseMirror");
  assert.ok(controlProseMirror, "the unlocked control mounts real ProseMirror DOM");
  const controlBeforeCount = controlEditor.state.doc.childCount;
  const controlTitleEnd = controlEditor.state.doc.child(0).nodeSize - 1;
  controlEditor.view.dispatch(
    controlEditor.state.tr.setSelection(
      TextSelection.create(controlEditor.state.doc, controlTitleEnd),
    ),
  );
  controlProseMirror.dispatchEvent(
    new window.KeyboardEvent("keydown", {
      key: "Enter",
      code: "Enter",
      keyCode: 13,
      bubbles: true,
      cancelable: true,
    }),
  );
  assert.equal(
    controlEditor.state.doc.childCount,
    controlBeforeCount + 1,
    "Enter grows the unlocked no-tail document by one top-level node",
  );
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.ok(
    controlOpsEvents > 0,
    "the accepted unlocked Enter emits the normal canvas operation event",
  );

  console.log("mounted locked-editor jsdom regression passed");
} finally {
  canvas.remove();
  controlCanvas.remove();
  window.close();
}
