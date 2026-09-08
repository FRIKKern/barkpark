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
const { DEBOUNCE_MS } = await import("../contract.js");

const paragraph = (id, value) => ({
  id,
  type: "paragraph",
  content: [{ type: "text", value }],
});
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function mount(id, value = "Original") {
  const firstColumn = document.createElement("section");
  const secondColumn = document.createElement("section");
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [paragraph(id, value)];
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail));
  document.body.append(firstColumn, secondColumn);
  firstColumn.appendChild(canvas);
  return { canvas, firstColumn, secondColumn, batches };
}

function move({ canvas, secondColumn }) {
  secondColumn.appendChild(canvas);
}

function close(mounted) {
  mounted.firstColumn.remove();
  mounted.secondColumn.remove();
}

try {
  const focused = mount("focused");
  focused.canvas._editor.commands.setTextSelection("end");
  focused.canvas._editor.view.focus();
  focused.canvas._editor.view.dispatch(
    focused.canvas._editor.state.tr.insertText(
      " responsive draft",
      focused.canvas._editor.state.doc.content.size - 1,
    ),
  );
  const editor = focused.canvas._editor;
  const selection = editor.state.selection.from;
  const history = undoDepth(editor.state);
  assert.equal(editor.isFocused, true);
  assert.equal(focused.canvas.hasPendingChanges(), true);

  editor.view.dom.blur();
  assert.equal(editor.isFocused, false,
    "the regression includes Blink's blur-before-disconnect ordering");
  move(focused);
  assert.equal(document.activeElement, document.body,
    "the responsive DOM move drops native focus before the lifecycle microtask");
  await tick();

  assert.equal(focused.canvas._editor, editor,
    "responsive reparenting retains the same editor instance");
  assert.equal(editor.view.hasFocus(), true,
    "a canvas focused before the move regains native focus after reconnecting");
  assert.equal(editor.state.selection.from, selection,
    "focus restoration preserves the user's caret");
  assert.equal(undoDepth(editor.state), history,
    "focus restoration adds no history transaction");
  assert.equal(focused.canvas.hasPendingChanges(), true,
    "focus restoration leaves the pending save armed");
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS * 4));
  assert.equal(focused.batches.length, 1,
    "the draft still reaches persistence after focus restoration");
  assert.equal(focused.batches[0].ops[0].patch.content[0].value,
    "Original responsive draft");
  close(focused);

  const unfocused = mount("unfocused");
  unfocused.canvas._editor.view.focus();
  unfocused.canvas._editor.view.dom.blur();
  assert.equal(unfocused.canvas._editor.isFocused, false);
  await tick();
  move(unfocused);
  await tick();
  assert.equal(document.activeElement, document.body,
    "an unfocused canvas does not claim focus after reparenting");
  close(unfocused);

  const otherButton = document.createElement("button");
  otherButton.textContent = "Other control";
  document.body.appendChild(otherButton);
  const otherFocused = mount("other-focused");
  otherButton.focus();
  move(otherFocused);
  await tick();
  assert.equal(document.activeElement, otherButton,
    "reparenting never steals focus that already belongs to another control");
  close(otherFocused);

  const racedTarget = document.createElement("button");
  racedTarget.textContent = "Responsive target";
  document.body.appendChild(racedTarget);
  const focusRace = mount("focus-race");
  focusRace.canvas._editor.commands.setTextSelection("end");
  focusRace.canvas._editor.view.focus();
  move(focusRace);
  racedTarget.focus();
  await tick();
  assert.equal(document.activeElement, racedTarget,
    "a target focused between the move and microtask keeps focus");
  close(focusRace);

  const inert = mount("inert");
  inert.canvas._editor.commands.setTextSelection("end");
  inert.canvas._editor.view.focus();
  inert.secondColumn.setAttribute("inert", "");
  move(inert);
  await tick();
  assert.equal(document.activeElement, document.body,
    "a canvas moved under inert content does not restore focus");
  close(inert);

  const source = mount("source");
  source.canvas.toggleSourceMode();
  assert.equal(document.activeElement, source.canvas._sourceEl,
    "source mode begins with its textarea focused");
  move(source);
  await tick();
  assert.equal(document.activeElement, document.body,
    "responsive focus restoration is intentionally limited to the rich editor");
  close(source);

  const removed = mount("removed");
  removed.canvas._editor.commands.setTextSelection("end");
  removed.canvas._editor.view.focus();
  removed.canvas.remove();
  await tick();
  assert.equal(removed.canvas._editor, null,
    "a true removal tears down instead of restoring focus");
  assert.equal(document.activeElement, document.body);
  close(removed);

  console.log("responsive canvas focus restoration and non-stealing guards passed");
} finally {
  window.close();
}
