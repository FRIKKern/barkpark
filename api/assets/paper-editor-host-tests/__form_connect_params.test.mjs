// __form_connect_params.test.mjs — task-b656db94cc1dbd17: each LiveView join
// sends the document and form generation the editor was drawn at
// (`_bp_form`), so a socket that rejoins draws the page's widget wrapper ids
// (`RejoinForm`) and the editor keeps what was typed while it was down.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom and reads `window.BarkparkFormConnectParams`, which root.html.heex's
// LiveSocket `params` spreads on every join.
//
// Run: node ../paper-editor-host-tests/__form_connect_params.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "MouseEvent", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-array-focus.js");

const params = () => window.BarkparkFormConnectParams();
const doc = JSON.stringify(["production", "post", "p1"]);

assert.equal(typeof window.BarkparkFormConnectParams, "function", "bp-array-focus.js loaded");

// No editor on the page: nothing sent.
document.body.innerHTML = "<main></main>";
assert.deepEqual(params(), {});

// The form as `studio_editor_shell` draws it: its document and generation.
document.body.innerHTML = `<form id="editor-form" phx-value-_bp_doc='${doc}' data-bp-form-gen="3"></form>`;
assert.deepEqual(params(), { _bp_form: { doc, gen: "3" } });

// Read afresh on each join: a redraw moved the generation.
document.getElementById("editor-form").setAttribute("data-bp-form-gen", "4");
assert.deepEqual(params(), { _bp_form: { doc, gen: "4" } });

// A form with no document (or no generation) sends nothing.
document.body.innerHTML = `<form id="editor-form" data-bp-form-gen="2"></form>`;
assert.deepEqual(params(), {});
document.body.innerHTML = `<form id="editor-form" phx-value-_bp_doc='${doc}'></form>`;
assert.deepEqual(params(), {});

console.log("__form_connect_params: ok");
