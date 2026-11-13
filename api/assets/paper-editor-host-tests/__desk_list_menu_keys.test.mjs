// __desk_list_menu_keys.test.mjs — a list's "List options" menu by keyboard
// (task-c662ced8d313341d). Feel walk 2026-11-13 on guerrilla: Enter opened the
// list's "…" menu but the focus stayed on the button and the arrows did
// nothing, while the edit pane's Share and "…" menus focus their first item
// and move with the arrows. bp-desk.js now treats the list's menu as it does
// the document's: opened, the first item has the focus and the button says it
// is expanded; ArrowDown, ArrowUp, Home and End move; Tab closes it.
//
// Run: node ../paper-editor-host-tests/__desk_list_menu_keys.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/post",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

// The list pane as ListMenu draws it (the button, then its popover menu).
const MENU_ID = "desk-pane-1-list:post-menu";
window.document.body.innerHTML = `<div id="desk-panes">
  <section class="pane-column dk-pane" data-pane-index="1" data-pane-kind="list"><div class="pane-header">
    <span class="pane-header-title">Post</span>
    <button type="button" class="dk-list-options" id="${MENU_ID}-button" aria-label="List options" aria-haspopup="menu" aria-expanded="false" popovertarget="${MENU_ID}">…</button>
    <div id="${MENU_ID}" popover role="menu" aria-label="List options" class="dk-list-menu">
      <div class="menu-label">Actions</div>
      <button type="button" role="menuitemradio" aria-checked="false" class="menu-item">Sort by Title</button>
      <button type="button" role="menuitemradio" aria-checked="false" class="menu-item">Sort by Last Edited</button>
      <button type="button" role="menuitemradio" aria-checked="false" class="menu-item">Default sort</button>
    </div>
  </div></section></div>`;
const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();

const doc = window.document;
const menu = doc.getElementById(MENU_ID);
const button = doc.getElementById(`${MENU_ID}-button`);
const items = [...menu.querySelectorAll('[role="menuitemradio"]')];
const focused = () => doc.activeElement && doc.activeElement.textContent.trim();
let hidden = 0;
menu.hidePopover = () => { hidden += 1; };

// `toggle` as the browser fires it on a popover (it does not bubble).
const toggle = (state) => {
  const e = new window.Event("toggle", { bubbles: false });
  e.newState = state;
  menu.dispatchEvent(e);
};
const key = (k) => doc.activeElement.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));

button.focus();
toggle("open");
assert.equal(button.getAttribute("aria-expanded"), "true", "the button says the menu is open");
assert.equal(focused(), "Sort by Title", "opened, the first item has the focus");

key("ArrowDown");
assert.equal(focused(), "Sort by Last Edited", "ArrowDown moves to the next item");
key("ArrowDown");
key("ArrowDown");
assert.equal(focused(), "Sort by Title", "and wraps from the last to the first");
key("ArrowUp");
assert.equal(focused(), "Default sort", "ArrowUp wraps to the last");
key("Home");
assert.equal(focused(), "Sort by Title", "Home goes to the first");
key("End");
assert.equal(focused(), "Default sort", "End goes to the last");

key("Tab");
assert.equal(hidden, 1, "Tab closes the menu");
toggle("closed");
assert.equal(button.getAttribute("aria-expanded"), "false", "closed, the button says so");

hook.destroyed();
console.log("desk list menu keys: ok");
window.close();
