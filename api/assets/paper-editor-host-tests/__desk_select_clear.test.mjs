// __desk_select_clear.test.mjs: a radio list's Clear on the desk
// (bp-desk-select.js, `Fields.DeskSelect`), the TanStack Studio's
// SelectInput reset.
//
// Clear turns on the list's hidden input (off until then), fires its input
// so the form posts "" for the field (the hidden input is last, so it wins
// over the checked radio), and turns it off again. The focus goes to the
// first option before the redraw takes the button away. A button outside a
// radio list is left alone.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-select.js
// under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_select_clear.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/post;post-05",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
globalThis.Event = window.Event;
await import("../../priv/static/assets/bp-desk-select.js");
assert.ok(window.BarkparkDeskSelect, "the script registers itself");

const doc = window.document;
doc.body.innerHTML =
  `<form id="editor-form"><div class="radio-box" data-direction="horizontal"><div role="group" id="stage" aria-label="Stage">` +
  ["idea", "writing"].map((v) => `<div class="radio-row"><label class="radio"><input type="radio" name="doc[stage]" value="${v}"${v === "writing" ? " checked" : ""}><span>${v}</span></label></div>`).join("") +
  `</div><button type="button" aria-label="Clear" data-radio-clear><svg><path d=""/></svg></button>` +
  `<input type="hidden" name="doc[stage]" value="" disabled data-radio-cleared></div>` +
  `<button type="button" id="other" data-radio-clear>other</button></form>`;

const form = doc.getElementById("editor-form");
const hidden = doc.querySelector("[data-radio-cleared]");
const seen = [];
form.addEventListener("input", (e) => {
  seen.push({ target: e.target, disabled: e.target.disabled, posted: new window.FormData(form).getAll("doc[stage]") });
});

const click = (el) => {
  const e = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  el.dispatchEvent(e);
  return e;
};

const e = click(doc.querySelector('.radio-box [data-radio-clear] path'));
assert.equal(seen.length, 1, "Clear fires one input");
assert.equal(seen[0].target, hidden, "on the hidden input");
assert.equal(seen[0].disabled, false, "which is on while the form reads it");
assert.deepEqual(seen[0].posted, ["writing", ""], "the form posts the hidden \"\" last, so it wins");
assert.equal(hidden.disabled, true, "and off again after");
assert.ok(e.defaultPrevented);
assert.equal(doc.activeElement, doc.querySelector('input[value="idea"]'), "the focus goes to the first option");

click(doc.getElementById("other"));
assert.equal(seen.length, 1, "a button outside a radio list is left alone");

console.log("desk select clear: ok");
