// __desk_search_dialog.test.mjs — the desk's search is TanStack's dialog
// (LOOKS C2, `Desk.Search`).
//
// Cmd+K or the opener shows the dialog modal with the focus in its box. It
// shuts when a hit is followed: by a click on the hit, or by Enter (the
// server's bp:focus-new-doc). A press on the dimmed page around it shuts it;
// a press inside it does not.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
// jsdom has no showModal, so the dialog's open and close are stubbed to set
// and drop `open`, as a browser does.
//
// Run: node ../paper-editor-host-tests/__desk_search_dialog.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const shown = [];
window.HTMLDialogElement.prototype.showModal = function () {
  shown.push("modal");
  this.setAttribute("open", "");
};
window.HTMLDialogElement.prototype.close = function () {
  this.removeAttribute("open");
};

window.document.body.innerHTML =
  `<div class="dk-search"><button type="button" data-desk-search-open><span>Search documents</span></button></div>` +
  `<dialog id="desk-search-dialog"><div class="dk-search-bar">` +
  `<form id="desk-search-form"><input id="desk-search-input" type="search" name="value" value="ab" role="combobox" aria-activedescendant="desk-search-hit-0" />` +
  `<input type="hidden" id="desk-search-lit" name="lit" value="0" /></form></div>` +
  `<div id="desk-search-hits"><div id="desk-search-options" role="listbox">` +
  `<a href="${BASE}/post;a" id="desk-search-hit-0" role="option" aria-selected="true" data-desk-hit>a</a>` +
  `</div></div></dialog>` +
  `<div id="desk-panes"></div>`;
// jsdom does not navigate; the page's own patch is not under test.
window.addEventListener("click", (e) => e.preventDefault());
const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent: () => {} });
hook.mounted();

const $ = (id) => window.document.getElementById(id);
const dialog = $("desk-search-dialog");
const isOpen = () => dialog.hasAttribute("open");
Object.defineProperty(dialog, "getBoundingClientRect", {
  value: () => ({ left: 320, right: 1120, top: 108, bottom: 500 }),
});
const press = (target, x, y) =>
  target.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }));

// ── The opener shows it modal, the focus in the box ─────────────────────────
press(window.document.querySelector("[data-desk-search-open] span"), 10, 10);
assert.ok(isOpen(), "the opener opens the dialog");
assert.deepEqual(shown, ["modal"], "it opens modal, over a dimmed page");
assert.equal(window.document.activeElement, $("desk-search-input"), "the focus is in the box");

// ── A press inside it leaves it open; one on the page around shuts it ───────
press(dialog, 400, 120);
assert.ok(isOpen(), "a press on the dialog's own padding keeps it open");
press(dialog, 40, 40);
assert.ok(!isOpen(), "a press on the dimmed page shuts it");

// ── Cmd+K and Ctrl+K open it ────────────────────────────────────────────────
for (const mod of [{ metaKey: true }, { ctrlKey: true }]) {
  $("desk-panes").focus();
  const e = new window.KeyboardEvent("keydown", { key: "k", bubbles: true, cancelable: true, ...mod });
  window.document.body.dispatchEvent(e);
  assert.ok(e.defaultPrevented, "the key is the desk's");
  assert.ok(isOpen(), "Cmd/Ctrl+K opens the dialog");
  assert.equal(window.document.activeElement, $("desk-search-input"));
  dialog.close();
}

// ── Following a hit shuts it: by Enter (the server's event) … ───────────────
dialog.showModal();
window.dispatchEvent(new window.CustomEvent("phx:bp:focus-new-doc", { detail: { id: "a" } }));
assert.ok(!isOpen(), "the server opening the lit hit shuts the dialog");

// … and by a click on the hit.
dialog.showModal();
press($("desk-search-hit-0"), 400, 140);
assert.ok(!isOpen(), "a click on a hit shuts the dialog");

hook.destroyed();
console.log("__desk_search_dialog: ok");
