// __desk_search_light.test.mjs — the desk search box's lit hit moves in the
// browser (task-b78cdd98252bb9fe, /papers/desk-vertical-slice).
//
// ArrowDown and ArrowUp move the light (aria-selected, aria-activedescendant)
// at once, with nothing sent to the server; the form's `lit` field carries
// the lit index for Enter. A patch that re-draws the same hits keeps the
// light where the keys left it; new hits start again at the first, as the
// server draws them.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_search_light.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

// The server's drawing: the first hit lit.
const options = (ids) =>
  ids
    .map((id, i) => `<a href="${BASE}/post;${id}" id="desk-search-hit-${i}" role="option" aria-selected="${i === 0}" data-desk-hit>${id}</a>`)
    .join("");
const search = (ids) =>
  `<form id="desk-search-form"><input id="desk-search-input" type="search" name="value" role="combobox" aria-activedescendant="desk-search-hit-0" /><input type="hidden" id="desk-search-lit" name="lit" value="0" /></form>` +
  `<div id="desk-search-hits"><div id="desk-search-options" role="listbox">${options(ids)}</div></div>`;

window.document.body.innerHTML =
  `<div class="dk-search" role="search">${search(["a", "b", "c"])}</div><div id="desk-panes"></div>`;
const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const pushed = [];
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent: (...a) => pushed.push(a) });
hook.mounted();

const $ = (id) => window.document.getElementById(id);
const tick = () => new Promise((r) => setTimeout(r, 0));
const lit = () => ({
  active: $("desk-search-input").getAttribute("aria-activedescendant"),
  selected: [...window.document.querySelectorAll('[role="option"]')].map((o) => o.getAttribute("aria-selected")),
  field: $("desk-search-lit").value,
});
const key = (k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  $("desk-search-input").dispatchEvent(e);
  return e;
};
$("desk-search-input").focus();

// ── The arrows move the light at once, and send nothing ─────────────────────
const down = key("ArrowDown");
assert.ok(down.defaultPrevented, "ArrowDown is the box's, not the caret's");
assert.deepEqual(lit(), { active: "desk-search-hit-1", selected: ["false", "true", "false"], field: "1" });
key("ArrowDown");
key("ArrowDown");
assert.equal(lit().active, "desk-search-hit-2", "the light stops at the last hit");
key("ArrowUp");
assert.deepEqual(lit(), { active: "desk-search-hit-1", selected: ["false", "true", "false"], field: "1" });
assert.deepEqual(pushed, [], "no key went to the server");

// ── A patch that re-draws the same hits keeps the light ─────────────────────
$("desk-search-options").innerHTML = options(["a", "b", "c"]);
$("desk-search-input").setAttribute("aria-activedescendant", "desk-search-hit-0");
$("desk-search-lit").setAttribute("value", "0");
await tick();
assert.deepEqual(lit(), { active: "desk-search-hit-1", selected: ["false", "true", "false"], field: "1" });

// Enter sends the lit index with the form.
$("desk-search-lit").value = "0";
key("Enter");
assert.equal($("desk-search-lit").value, "1", "Enter's form carries the lit hit");

// ── New hits: the first is lit again ────────────────────────────────────────
$("desk-search-options").innerHTML = options(["x", "y"]);
$("desk-search-input").setAttribute("aria-activedescendant", "desk-search-hit-0");
$("desk-search-lit").setAttribute("value", "0");
await tick();
assert.deepEqual(lit(), { active: "desk-search-hit-0", selected: ["true", "false"], field: "0" });
key("ArrowDown");
assert.equal(lit().active, "desk-search-hit-1");

// Other keys are the box's own.
assert.ok(!key("a").defaultPrevented);

// ── The search is a dialog (LOOKS A4) ───────────────────────────────────────
// jsdom draws no dialogs: open/close are the attribute, as a browser keeps
// it, and close hands the focus back to what had it at showModal, as a
// browser does.
const proto = window.HTMLDialogElement.prototype;
proto.showModal = function () { this._was = window.document.activeElement; this.setAttribute("open", ""); };
proto.close = function () { this.removeAttribute("open"); if (this._was && this._was.focus) this._was.focus(); };
Object.defineProperty(proto, "open", { get() { return this.hasAttribute("open"); }, configurable: true });
const dialog = window.document.createElement("dialog");
dialog.id = "dk-search-dialog";
dialog.appendChild(window.document.querySelector(".dk-search"));
window.document.body.prepend(dialog);
const opener = window.document.createElement("button");
opener.setAttribute("data-desk-search-open", "");
window.document.body.prepend(opener);
const bodyKey = (k, mods = {}) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...mods });
  window.document.body.dispatchEvent(e);
  return e;
};
window.document.body.focus();

// "/" outside a text field opens it with the box focused.
assert.ok(bodyKey("/").defaultPrevented, '"/" opens the search');
assert.ok(dialog.open, "the dialog is open");
assert.equal(window.document.activeElement, $("desk-search-input"));
// "/" typed in the box is a character.
assert.ok(!key("/").defaultPrevented, '"/" in the box is the box\'s');
// A submitted search (Enter) puts the dialog away, and the focus goes on
// with what it opens, not back to where "/" was pressed.
$("desk-search-form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
assert.ok(!dialog.open, "Enter's form closes the dialog");
assert.equal(window.document.activeElement, window.document.body);

// The navbar's button opens it.
opener.focus();
opener.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
assert.ok(dialog.open, "the search button opens the dialog");
// A hit puts it away. (The page's link is not followed here: jsdom has no
// navigation; the window hears the click last, after the desk's handlers.)
window.addEventListener("click", (e) => e.preventDefault());
const focusAsked = [];
hook._focusNewDoc = (e) => focusAsked.push(e.detail.id);
$("desk-search-hit-0").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
assert.ok(!dialog.open, "a hit closes the dialog");
// The browser would hand the focus back to the button; the opened pane takes
// it instead (the page has it until the patch lands).
assert.equal(window.document.activeElement, window.document.body, "a hit leaves the focus to the opened pane");
assert.deepEqual(focusAsked, ["x"], "the hit's document's first field is asked for, as Enter's open asks");

// Escape in the box puts it away (a search field's own Escape only empties it).
opener.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
assert.ok(dialog.open);
assert.ok(key("Escape").defaultPrevented, "Escape is the dialog's");
assert.ok(!dialog.open, "Escape closes the dialog");

// Cmd+K opens it too; a bare letter does not.
window.document.body.focus();
assert.ok(!bodyKey("k").defaultPrevented);
assert.ok(!dialog.open);
assert.ok(bodyKey("k", { metaKey: true }).defaultPrevented);
assert.ok(dialog.open, "Cmd+K opens the dialog");

// Cmd+K and Ctrl+K typed in a field are the field's (Ctrl+K deletes to the end
// of a line on a Mac; Cmd+K is the rich text's link key): neither opens it.
dialog.close();
for (const tag of ["input", "textarea"]) {
  const field = window.document.createElement(tag);
  window.document.body.append(field);
  field.focus();
  for (const mods of [{ metaKey: true }, { ctrlKey: true }]) {
    const e = new window.KeyboardEvent("keydown", { key: "k", bubbles: true, cancelable: true, ...mods });
    field.dispatchEvent(e);
    assert.ok(!e.defaultPrevented, `${Object.keys(mods)[0]}+K in a ${tag} is the field's`);
    assert.ok(!dialog.open, `${Object.keys(mods)[0]}+K in a ${tag} opens nothing`);
  }
  field.remove();
}

console.log("ok — __desk_search_light");
