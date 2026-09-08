import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { undoDepth } from "@tiptap/pm/history";

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
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");

const paragraph = (id, value = "Draft") => ({
  id,
  type: "paragraph",
  content: [{ type: "text", value }],
});
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function mount(id, { editable = true } = {}) {
  const root = document.createElement("section");
  root.id = `paper-editor-${id}`;
  root.className = "bp-paper-editor";
  root.setAttribute("data-paper-doc-key", `production:paper:${id}`);
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-paper-doc-key", `production:paper:${id}`);
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.blocks = [paragraph(id)];
  root.appendChild(canvas);
  document.body.appendChild(root);
  return { root, canvas, editor: canvas._editor };
}

function focusRich({ editor }) {
  editor.commands.setTextSelection("end");
  editor.view.focus();
  assert.equal(editor.view.hasFocus(), true);
}

function close(mounted) {
  mounted.root.remove();
}

try {
  const resumed = mount("resume-focused");
  focusRich(resumed);
  const selection = resumed.editor.state.selection.from;
  const history = undoDepth(resumed.editor.state);
  assert.equal(resumed.canvas.captureResumeFocus(), true);
  assert.equal(resumed.canvas.captureResumeFocus(), true,
    "repeated capture keeps the original armed intent");
  resumed.root.setAttribute("inert", "");
  resumed.editor.view.dom.blur();
  assert.equal(document.activeElement, document.body,
    "freeze-induced blur leaves no competing focus target");
  document.body.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }));
  resumed.root.removeAttribute("inert");
  assert.equal(resumed.canvas.restoreResumeFocus(), true);
  assert.equal(resumed.editor.view.hasFocus(), true);
  assert.equal(resumed.editor.state.selection.from, selection,
    "restoring native focus preserves the ProseMirror selection");
  assert.equal(undoDepth(resumed.editor.state), history,
    "restoring native focus does not add an undo transaction");
  assert.equal(resumed.canvas.restoreResumeFocus(), false,
    "the reconnect focus intent is consumed once");
  close(resumed);

  const replaced = mount("resume-replaced-root");
  focusRich(replaced);
  const replacedSelection = replaced.editor.state.selection.from;
  const replacedHistory = undoDepth(replaced.editor.state);
  assert.equal(replaced.canvas.captureResumeFocus(), true);
  replaced.root.setAttribute("inert", "");
  replaced.editor.view.dom.blur();
  const replacementRoot = document.createElement("section");
  replacementRoot.id = replaced.root.id;
  replacementRoot.className = replaced.root.className;
  replacementRoot.setAttribute(
    "data-paper-doc-key",
    replaced.root.getAttribute("data-paper-doc-key"),
  );
  replacementRoot.setAttribute("inert", "");
  document.body.appendChild(replacementRoot);
  replacementRoot.appendChild(replaced.canvas);
  replaced.root.remove();
  await tick();
  assert.equal(replaced.canvas._editor, replaced.editor,
    "a same-id/document ancestor replacement retains the editor instance");
  replacementRoot.removeAttribute("inert");
  assert.equal(replaced.canvas.restoreResumeFocus(), true,
    "logical root identity survives LiveView replacing the outer editor element");
  assert.equal(replaced.editor.state.selection.from, replacedSelection);
  assert.equal(undoDepth(replaced.editor.state), replacedHistory);
  replacementRoot.remove();

  const recoveryButton = document.createElement("button");
  recoveryButton.textContent = "Download recovery";
  document.body.appendChild(recoveryButton);
  const cancelled = mount("resume-cancelled");
  focusRich(cancelled);
  assert.equal(cancelled.canvas.captureResumeFocus(), true);
  cancelled.root.setAttribute("inert", "");
  recoveryButton.focus();
  assert.equal(document.activeElement, recoveryButton);
  cancelled.root.removeAttribute("inert");
  recoveryButton.blur();
  focusRich(cancelled);
  assert.equal(cancelled.canvas.captureResumeFocus(), false,
    "repeated capture cannot refresh an intent cancelled by deliberate focus");
  cancelled.editor.view.dom.blur();
  assert.equal(cancelled.canvas.restoreResumeFocus(), false,
    "a recovery control keeps focus ownership after unfreeze");
  close(cancelled);
  recoveryButton.remove();

  const blurred = mount("resume-blurred");
  assert.equal(blurred.canvas.captureResumeFocus(), false,
    "a canvas that was not focused does not arm restoration");
  close(blurred);

  const controlFocused = mount("resume-control");
  const innerButton = document.createElement("button");
  controlFocused.canvas.appendChild(innerButton);
  innerButton.focus();
  assert.equal(controlFocused.canvas.captureResumeFocus(), false,
    "a native control inside the canvas is not rich-editor focus intent");
  close(controlFocused);

  const source = mount("resume-source");
  source.canvas.toggleSourceMode();
  assert.equal(document.activeElement, source.canvas._sourceEl);
  assert.equal(source.canvas.captureResumeFocus(), false,
    "source mode keeps ownership of its textarea");
  close(source);

  const readOnly = mount("resume-readonly", { editable: false });
  readOnly.editor.view.focus();
  assert.equal(readOnly.canvas.captureResumeFocus(), false,
    "read-only canvases never arm reconnect focus");
  close(readOnly);

  const switched = mount("resume-doc-one");
  focusRich(switched);
  assert.equal(switched.canvas.captureResumeFocus(), true);
  switched.root.setAttribute("inert", "");
  switched.editor.view.dom.blur();
  switched.root.setAttribute("data-paper-doc-key", "production:paper:resume-doc-two");
  switched.root.removeAttribute("inert");
  assert.equal(switched.canvas.restoreResumeFocus(), false,
    "a document identity change invalidates the captured intent");
  close(switched);

  const changedRootId = mount("resume-root-id-one");
  focusRich(changedRootId);
  assert.equal(changedRootId.canvas.captureResumeFocus(), true);
  changedRootId.root.setAttribute("inert", "");
  changedRootId.editor.view.dom.blur();
  changedRootId.root.id = "paper-editor-resume-root-id-two";
  changedRootId.root.removeAttribute("inert");
  assert.equal(changedRootId.canvas.restoreResumeFocus(), false,
    "a different outer editor id cannot inherit focus intent");
  close(changedRootId);

  const removed = mount("resume-removed");
  focusRich(removed);
  assert.equal(removed.canvas.captureResumeFocus(), true);
  removed.root.remove();
  await tick();
  assert.equal(removed.canvas._editor, null,
    "true disconnect tears down the editor");
  assert.equal(removed.canvas.restoreResumeFocus(), false,
    "true disconnect also clears the reconnect focus listener and intent");

  console.log("canvas reconnect focus restoration and cancellation guards passed");
} finally {
  window.close();
}
