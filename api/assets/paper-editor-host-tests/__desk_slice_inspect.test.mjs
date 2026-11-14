// __desk_slice_inspect.test.mjs — J28 / keyboard:158: Ctrl+Alt+I opens the
// Inspect dialog as soon as a document is open, as Sanity's: a click on a list
// row leaves the focus on the row, and the key still asks for it. With no
// document open it asks for nothing.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_inspect.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post;post-a`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const doc = window.document;
const list =
  `<section class="pane-column dk-pane" id="p0" data-pane-index="0" data-pane-kind="list">` +
  `<div class="pane-body"><a id="row" class="pane-item" href="${BASE}/post;post-a">Post A</a></div></section>`;
const editPane =
  `<section class="pane-column dk-pane dk-doc" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing aria-label="Post A">` +
  `<div class="pane-body"><form id="editor-form"><input type="text" id="title" name="doc[title]" value="Post A"></form></div></section>`;
doc.body.innerHTML = `<div id="desk-panes">${list}${editPane}</div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const pushed = [];
const hook = Object.assign(Object.create(window.BarkparkDesk), {
  el,
  pushEvent(name, payload) { pushed.push([name, payload]); },
});
hook.mounted();

const press = (id, init = {}) => {
  const e = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, code: "KeyI", key: "ˆ", ctrlKey: true, altKey: true, ...init });
  doc.getElementById(id).dispatchEvent(e);
  return e.defaultPrevented;
};
const inspects = () => pushed.filter(([name]) => name === "desk-inspect");

assert.equal(press("title"), true, "from the form: handled");
assert.deepEqual(inspects(), [["desk-inspect", { open: true }]], "from the form: asks for Inspect");

pushed.length = 0;
assert.equal(press("row"), true, "from the list row that opened the document: handled");
assert.deepEqual(inspects(), [["desk-inspect", { open: true }]], "from the list row: asks for Inspect");

// Not the shortcut: Shift added, or another key.
pushed.length = 0;
press("row", { shiftKey: true });
press("row", { code: "KeyP" });
assert.deepEqual(inspects(), [], "Ctrl+Alt+Shift+I and Ctrl+Alt+P ask for nothing");

// The dialog opens when the page draws it, in its pane, with show() (no
// modal: that would lift it over the page). jsdom has no show: counted here.
const shown = [];
window.HTMLDialogElement.prototype.show = function () { shown.push(this.id); this.setAttribute("open", ""); };
window.HTMLDialogElement.prototype.showModal = function () { throw new Error("Inspect is no modal"); };
const tick = () => new Promise((r) => setTimeout(r, 0));
const draw = (id) => {
  doc.getElementById("p1").insertAdjacentHTML("beforeend", `<dialog id="${id}" data-desk-inspect><h2>Inspecting Post A</h2></dialog>`);
  return doc.getElementById(id);
};

// LiveView's phx-mounted dispatched on a detached copy (the key's pushEvent
// locks the desk): no desk:show-modal reaches the page. It opens anyway, once.
draw("insp-1");
await tick();
assert.deepEqual(shown, ["insp-1"], "drawn with no desk:show-modal: it opens");

// Escape shut it; the page is told and has not taken it out yet. Another patch
// in the desk does not open it again.
doc.getElementById("insp-1").removeAttribute("open");
doc.getElementById("p1").insertAdjacentHTML("beforeend", "<span>patched</span>");
await tick();
assert.deepEqual(shown, ["insp-1"], "closed by the user: a later patch leaves it shut");

// phx-mounted reached the page: desk:show-modal and the drawing open it once.
doc.getElementById("insp-1").remove();
const second = draw("insp-2");
second.dispatchEvent(new window.CustomEvent("desk:show-modal", { bubbles: true }));
await tick();
assert.deepEqual(shown, ["insp-1", "insp-2"], "with desk:show-modal too: opened once");
second.remove();

// No document open: nothing to inspect.
doc.getElementById("p1").remove();
pushed.length = 0;
assert.equal(press("row"), false, "no document open: not handled");
assert.deepEqual(inspects(), [], "no document open: asks for nothing");

console.log("desk slice inspect: ok");
