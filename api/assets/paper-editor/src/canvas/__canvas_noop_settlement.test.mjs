// A canvas edit that cancels itself out must not leave the page claiming
// unsaved changes. Found dogfooding the Studio canvas (2026-10-03): type into a
// paragraph, press Cmd+Z inside the save debounce, and the edit is gone and
// nothing is saved, as it should be. But every later reload or tab close
// raised "Changes you made may not be saved" for good.
//
// The cause sits between the two halves. The exit coordinator marks the canvas
// run dirty on the native `input` event, and only a save cleared it. A
// cancelled edit produces zero ops, so no save is ever sent. The fix: the
// canvas announces the zero-op emit as `bp-noop`, and the canvas hook settles
// the run with the newest dirty token, but only when its queue is empty and
// nothing is sending or pending.
//
// Real <bp-paper-canvas> and the real hooks bundle; the server is a stub
// pushEvent whose replies the test resolves by hand.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const BLOCKS = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "Alpha" }] }];
const dom = new JSDOM(`<!doctype html><html><head></head><body>
  <main data-paper-doc-key="production:paper:canvas-noop" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-noop-run-0" phx-hook="BarkparkPaperCanvas"
           data-canvas-blocks='${JSON.stringify(BLOCKS)}'><bp-paper-canvas></bp-paper-canvas></div>
    </div>
  </main></body></html>`, { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });

await import("./index.js");

const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: window.customElements,
});
vm.runInContext(
  readFileSync(new URL("../../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const Hooks = window.BarkparkPaperEditorHooks;
const el = window.document.querySelector("#paper-canvas-noop-run-0");
const canvas = el.querySelector("bp-paper-canvas");
canvas.blocks = BLOCKS;
const calls = [];
const replies = [];
const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    calls.push(payload);
    return new Promise((resolve) => replies.push(resolve));
  },
};
hook.mounted();

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const guarded = () => {
  const event = new window.Event("beforeunload", { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
};
const editor = () => canvas._editor;
// What the browser does on a keystroke: the native input event (which the exit
// coordinator hears) and the ProseMirror transaction (which the canvas hears).
const typeText = (text) => {
  const tiptap = editor();
  tiptap.view.dispatch(tiptap.state.tr.insertText(text, tiptap.state.doc.content.size - 1));
  tiptap.view.dom.dispatchEvent(new window.Event("input", { bubbles: true, composed: true }));
};
const undo = () => editor().commands.undo();

try {
  assert.ok(editor(), "the canvas mounted a real editor");
  assert.equal(guarded(), false, "a freshly opened run has nothing unsaved");

  // ── 1. type, undo inside the debounce: nothing to save, nothing to warn ──
  typeText(" typed");
  assert.equal(guarded(), true, "a live edit is unsaved until it settles");
  undo();
  assert.equal(editor().getText(), "Alpha", "the undo cancelled the edit");
  assert.equal(canvas.flushPendingChanges(), false, "the cancelled edit produces no batch");
  assert.equal(calls.length, 0, "no write reaches the server");
  assert.equal(guarded(), false,
    "a cancelled edit settles the run: leaving the page does not warn about unsaved changes");

  // ── 2. control: a real edit still warns until its save is acknowledged ──
  typeText(" kept");
  assert.equal(canvas.flushPendingChanges(), true, "a real edit is sent");
  assert.equal(calls.length, 1);
  assert.equal(guarded(), true, "an in-flight save keeps the warning");

  // ── 3. a cancelled edit while a save is in flight cannot clear the guard ──
  typeText("!");
  undo();
  canvas.flushPendingChanges();
  assert.equal(guarded(), true, "a no-op during an in-flight save does not settle the run");

  replies.shift()({ saved: true, request_id: calls[0].request_id, rev: 8 });
  await tick();
  await tick();
  canvas.flushPendingChanges();
  await tick();
  assert.equal(guarded(), false, "once the real save is acknowledged the run is clean");
} finally {
  hook.destroyed?.();
  window.close();
}

console.log("canvas no-op settlement: a cancelled edit clears the exit guard; a real one keeps it until saved");
