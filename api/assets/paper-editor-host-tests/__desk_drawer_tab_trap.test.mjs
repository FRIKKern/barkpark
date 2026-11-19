// __desk_drawer_tab_trap.test.mjs — the desk's phone drawer keeps Tab inside
// (task-ebfdab3ce89e4300, review of #27492). The drawer is a modal <dialog>
// opened with showModal(); Chrome alone lets Shift+Tab from "Close menu" stop
// on the dialog box and then on BODY, and Tab from "Sign out" do the same.
// TanStack's drawer wraps Tab in its focus scope. bp-desk-navbar.js now does:
// Tab on the last control goes to the first, Shift+Tab on the first to the
// last, and a Tab from outside the drawer (the dialog box, BODY) goes back in.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-navbar.js under
// jsdom on a drawer shaped like Desk.NavDrawer's render.
//
// Run: node ../paper-editor-host-tests/__desk_drawer_tab_trap.test.mjs
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
// jsdom lays nothing out: a control is drawn unless it is hidden.
window.HTMLElement.prototype.getClientRects = function () {
  return this.closest("[hidden]") ? [] : [{}];
};

const doc = window.document;
doc.body.innerHTML = `<header class="navbar">
  <div class="dk nav-drawer-wrap" id="dk-drawer-wrap">
    <button type="button" id="dk-drawer-open" class="icon-btn nav-drawer-btn" aria-label="Open menu" aria-haspopup="dialog" aria-expanded="false" aria-controls="dk-drawer" data-desk-drawer-open>≡</button>
    <dialog id="dk-drawer" class="nav-drawer" aria-label="Menu" tabindex="-1">
      <div class="drawer-head"><span class="drawer-who">Ada</span>
        <button type="button" aria-label="Close menu" data-desk-drawer-close>×</button></div>
      <nav aria-label="Tools">
        <a class="drawer-item on" aria-current="page" href="/structure" data-desk-drawer-pick>Structure</a>
        <a class="drawer-item" href="/media" data-desk-drawer-pick>Media</a>
      </nav>
      <div class="drawer-foot">
        <button type="button" class="drawer-item" data-desk-drawer-help>Help and resources</button>
        <button type="button" data-desk-appearance="light" aria-pressed="true">Light</button>
        <button type="button" data-desk-appearance="dark" aria-pressed="false">Dark</button>
        <form method="post" action="/logout"><button type="submit" class="drawer-item">Sign out</button></form>
        <div hidden><button type="button">Network shares</button></div>
      </div>
    </dialog>
  </div>
  <button type="button" class="nav-search" aria-label="Search">⌕</button>
</header>`;

await import("../../priv/static/assets/bp-desk-navbar.js");
assert.equal(typeof window.BarkparkDeskNavbar, "object", "bp-desk-navbar.js loaded");

const drawer = doc.getElementById("dk-drawer");
const name = (el) => (el === doc.body ? "BODY" : el === drawer ? "DIALOG" : el.getAttribute("aria-label") || el.textContent.trim());
const at = () => name(doc.activeElement);
const byName = (n) => [...drawer.querySelectorAll("a, button")].find((el) => name(el) === n);
const tab = (shift = false) => {
  const e = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey: shift, bubbles: true, cancelable: true });
  (doc.activeElement || doc.body).dispatchEvent(e);
  return e.defaultPrevented;
};

// Shut: Tab is the browser's.
byName("Close menu").focus();
assert.equal(tab(true), false, "a shut drawer leaves Tab alone");

drawer.setAttribute("open", "");

// Shift+Tab on the first control wraps to the last drawn one (not the hidden one).
byName("Close menu").focus();
assert.equal(tab(true), true, "Shift+Tab on Close menu is the drawer's");
assert.equal(at(), "Sign out", "Shift+Tab on Close menu goes to Sign out, not the DIALOG or BODY");

// Tab on the last control wraps to the first.
assert.equal(tab(), true, "Tab on Sign out is the drawer's");
assert.equal(at(), "Close menu", "Tab on Sign out goes to Close menu, not the DIALOG or BODY");

// In between, the browser moves the focus as usual.
byName("Media").focus();
assert.equal(tab(), false, "Tab inside the drawer is the browser's");
assert.equal(tab(true), false, "Shift+Tab inside the drawer is the browser's");

// The focus on the dialog box itself goes back in.
drawer.focus();
assert.equal(at(), "DIALOG");
tab();
assert.equal(at(), "Close menu", "Tab from the dialog box goes to the first control");
drawer.focus();
tab(true);
assert.equal(at(), "Sign out", "Shift+Tab from the dialog box goes to the last control");

// The focus outside (BODY, the bar behind) goes back in.
doc.activeElement.blur();
assert.equal(at(), "BODY");
tab();
assert.equal(at(), "Close menu", "Tab from BODY goes into the drawer");
doc.querySelector(".nav-search").focus();
tab(true);
assert.equal(at(), "Sign out", "Shift+Tab from behind the drawer goes to its last control");

console.log("ok - __desk_drawer_tab_trap");
