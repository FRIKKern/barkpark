// __boundary_focus.test.mjs — task-f92354b415b486f5: after the server builds an
// image or equation from a canvas pick it pushes `bp:focus-boundary` {id}; the
// BarkparkPaperCanvas hook hands it to window.BarkparkFocusBoundary, which puts
// the caret in that block's boundary editor once it is in the DOM.
// Run: node src/__boundary_focus.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(
  '<main><div id="paper-canvas-run-0" phx-hook="BarkparkPaperCanvas"><bp-paper-canvas></bp-paper-canvas></div><div id="slot"></div></main>',
  { pretendToBeVisual: true },
);
const { window } = dom;
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => new Promise(() => {}) },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const focusBoundary = window.BarkparkFocusBoundary;
assert.equal(typeof focusBoundary, "function", "the hooks file exposes BarkparkFocusBoundary");

const slot = window.document.getElementById("slot");

// 1. The equation form is ALREADY in the DOM: its textarea takes the caret.
slot.innerHTML =
  '<form id="equation-form-eq-1"><input type="hidden" name="block_id" value="eq-1"><textarea name="tex"></textarea></form>';
assert.equal(await focusBoundary("eq-1"), true);
assert.equal(window.document.activeElement, slot.querySelector("textarea"), "the TeX textarea has the caret");

// 2. The editor arrives a few frames AFTER the push (patch / WC paint): the
//    retry still finds it.
slot.innerHTML = "";
const pending = focusBoundary("img-1");
setTimeout(() => {
  slot.innerHTML = '<div id="paper-fld-img-1"><label>Image</label><button type="button">Upload</button></div>';
}, 40);
assert.equal(await pending, true);
assert.equal(window.document.activeElement.textContent, "Upload", "the image editor's first control has the caret");

// 3. An id that never renders gives up quietly.
assert.equal(await focusBoundary("never", 3), false);

// 4. The canvas hook routes the server push to it.
const handlers = new Map();
const hook = Object.create(window.BarkparkPaperEditorHooks.BarkparkPaperCanvas);
hook.el = window.document.getElementById("paper-canvas-run-0");
hook.handleEvent = (name, fn) => handlers.set(name, fn);
hook.pushEvent = () => {};
hook.pushEventTo = () => {};
try {
  hook.mounted();
} catch (_e) {
  // The hook wires much more than this test feeds it; only the handler matters.
}
assert.equal(typeof handlers.get("bp:focus-boundary"), "function", "the canvas hook listens for bp:focus-boundary");
slot.innerHTML = '<form id="equation-form-eq-2"><textarea name="tex"></textarea></form>';
handlers.get("bp:focus-boundary")({ id: "eq-2" });
await new Promise((r) => setTimeout(r, 30));
assert.equal(window.document.activeElement, slot.querySelector("textarea"));

console.log("boundary focus: the caret lands in the boundary editor the server built");
