// __desk_who_menu.test.mjs — who is here by keyboard, and closed by a pick
// (task-78fe37a4f2bfc752, review of #27884). The desk's who-is-here menu
// (Desk.WhoMenu) gave every row tabindex=-1 and no script: the arrows did
// nothing and no row was ever focused, while the old bar's avatars were
// buttons Tab reached. And a picked row opened its document under a menu
// that stayed open. TanStack's MenuPopover focuses its first item, moves with
// the arrows, closes on Tab, and its row closes the menu (onDone).
// bp-desk-navbar.js now does the same.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-navbar.js under
// jsdom on a menu shaped like Desk.WhoMenu's render.
//
// Run: node ../paper-editor-host-tests/__desk_who_menu.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/post",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
// The script asks for a newer build every minute and follows the system's
// appearance; neither is under test here.
globalThis.setInterval = () => 0;
window.matchMedia = () => ({ matches: false, addEventListener() {} });
// jsdom has no popovers: an open one carries data-open.
const matches = window.Element.prototype.matches;
window.Element.prototype.matches = function (selector) {
  if (selector === ":popover-open") return this.hasAttribute("data-open");
  return matches.call(this, selector);
};

const row = (name, doc) =>
  `<button type="button" role="menuitem" tabindex="-1" class="dk-menu-item who-row presence-user-wrap"` +
  (doc ? ` phx-click="jump-to-user" phx-value-type="post" phx-value-doc-id="p-${name}">` : ` disabled title="Not in a document">`) +
  `<span class="avatar" aria-hidden="true">${name[0]}</span><span class="who-name">${name}</span>` +
  `<span class="who-doc">${doc || "Not in a document"}</span></button>`;

const doc = window.document;
doc.body.innerHTML = `<header class="navbar"><div class="menu-wrap dk dk-who">
  <button id="dk-who" type="button" class="icon-btn who" popovertarget="dk-who-menu" aria-label="Global presence" aria-haspopup="menu">U</button>
  <div id="dk-who-menu" popover role="menu" aria-labelledby="dk-who" class="dk-menu who-menu">
    ${row("Grace Hopper", "Post one")}${row("Margaret Hamilton-Smith", null)}${row("Linus", "Post two")}${row("Ada", "Post three")}
  </div></div>
  <button type="button" class="nav-search" aria-label="Search">⌕</button>
</header>`;

await import("../../priv/static/assets/bp-desk-navbar.js");
assert.equal(typeof window.BarkparkDeskNavbar, "object", "bp-desk-navbar.js loaded");

const menu = doc.getElementById("dk-who-menu");
const button = doc.getElementById("dk-who");
const focused = () => doc.activeElement.querySelector(".who-name")?.textContent || doc.activeElement.id;
let hidden = 0;
menu.hidePopover = () => {
  hidden += 1;
  menu.removeAttribute("data-open");
};
// `toggle` as the browser fires it on a popover (it does not bubble).
const toggle = (state) => {
  if (state === "open") menu.setAttribute("data-open", "");
  const e = new window.Event("toggle", { bubbles: false });
  e.newState = state;
  menu.dispatchEvent(e);
};
const key = (k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  doc.activeElement.dispatchEvent(e);
  return e.defaultPrevented;
};

// Opened from its button, the first person has the focus.
button.focus();
toggle("open");
assert.equal(focused(), "Grace Hopper", "opened, the first person has the focus");

// The arrows move between the people one can go to, skipping someone in no document.
assert.equal(key("ArrowDown"), true, "ArrowDown is the menu's");
assert.equal(focused(), "Linus", "ArrowDown skips the disabled row");
key("ArrowDown");
assert.equal(focused(), "Ada", "ArrowDown moves on");
key("ArrowDown");
assert.equal(focused(), "Grace Hopper", "and wraps from the last to the first");
key("ArrowUp");
assert.equal(focused(), "Ada", "ArrowUp wraps to the last");
key("Home");
assert.equal(focused(), "Grace Hopper", "Home goes to the first");
key("End");
assert.equal(focused(), "Ada", "End goes to the last");
assert.equal(key("a"), false, "other keys are left alone");

// Tab leaves it closed.
key("Tab");
assert.equal(hidden, 1, "Tab closes the menu");
toggle("closed");

// A pick opens the document (the row's phx-click) and closes the menu.
toggle("open");
const linus = [...menu.querySelectorAll(".who-row")].find((b) => b.textContent.includes("Linus"));
linus.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
assert.equal(hidden, 2, "picking a person closes the menu");
assert.equal(linus.getAttribute("phx-click"), "jump-to-user", "the row still opens their document");

// A click elsewhere in the bar leaves a closed menu alone.
doc.querySelector(".nav-search").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.equal(hidden, 2, "a click outside the menu does not call hidePopover");

// Nobody to go to: opening leaves the focus on the button.
menu.innerHTML = `<div class="who-empty"><p>No one else is here</p></div>`;
button.focus();
toggle("open");
assert.equal(doc.activeElement, button, "an empty menu leaves the focus on its button");
assert.equal(key("ArrowDown"), false, "and the arrows have nothing to move to");

console.log("desk who menu: ok");
