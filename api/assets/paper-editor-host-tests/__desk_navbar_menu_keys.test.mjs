// __desk_navbar_menu_keys.test.mjs — the desk navbar's Help and user menus by
// keyboard (task-63b405b1f1ad08a0, found reviewing #27884). Enter opened them,
// but the focus stayed on the button, ArrowDown did nothing and Tab went past
// every item: no item could be reached. TanStack's menus (focus-scope.ts,
// `menu`) open on their first item and move with the arrows, Home and End.
// bp-desk-navbar.js now gives every navbar menu one rule: the perspective
// menu, who is here, Help and the user menu.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-navbar.js under
// jsdom on menus shaped like Desk.HelpMenu's, Desk.UserMenu's and
// Desk.PerspectivePicker's renders.
//
// Run: node ../paper-editor-host-tests/__desk_navbar_menu_keys.test.mjs
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

const doc = window.document;
doc.body.innerHTML = `<header class="navbar">
  <div class="menu-wrap dk" id="dk-perspective">
    <button id="dk-perspective-button" type="button" popovertarget="dk-perspective-menu" aria-haspopup="menu">Drafts</button>
    <div id="dk-perspective-menu" popover role="menu" class="dk-menu perspective-menu">
      <a role="menuitemradio" aria-checked="false" tabindex="-1" href="?perspective=published">Published</a>
      <a role="menuitemradio" aria-checked="true" tabindex="-1" href="?perspective=drafts">Drafts</a>
    </div>
  </div>
  <div class="menu-wrap help dk" id="dk-help">
    <button id="help-menu" type="button" class="icon-btn" popovertarget="dk-help-menu" aria-label="Help and resources" aria-haspopup="menu">?</button>
    <div id="dk-help-menu" popover role="menu" aria-labelledby="help-menu" class="dk-menu help-menu">
      <a class="dk-menu-item" href="https://example.org/issues" role="menuitem" tabindex="-1">Report a problem</a>
      <hr class="dk-menu-separator">
      <button type="button" role="menuitem" tabindex="-1" class="dk-menu-item studio-version" data-desk-version>Barkpark Studio</button>
      <hr class="dk-menu-separator">
      <a class="dk-menu-item" href="https://example.org#readme" role="menuitem" tabindex="-1">Documentation</a>
      <a class="dk-menu-item" href="https://example.org/changelog" role="menuitem" tabindex="-1">Changelog</a>
      <button type="button" role="menuitem" tabindex="-1" class="dk-menu-item" data-desk-nav-dialog="dk-whats-new">What's new</button>
    </div>
  </div>
  <div class="editor dk" id="dk-user">
    <div class="menu-wrap">
      <button id="user-menu" type="button" class="icon-btn user-btn" popovertarget="dk-user-menu" aria-label="Open user menu" aria-haspopup="menu">A</button>
      <div id="dk-user-menu" popover role="menu" aria-labelledby="user-menu" class="dk-menu user-menu">
        <div class="user-head">Ada</div>
        <hr class="dk-menu-separator">
        <button type="button" role="menuitemradio" aria-checked="false" tabindex="-1" class="dk-menu-item check" data-desk-appearance="system" aria-label="System">System</button>
        <button type="button" role="menuitemradio" aria-checked="false" tabindex="-1" class="dk-menu-item check" data-desk-appearance="light" aria-label="Light">Light</button>
        <button type="button" role="menuitemradio" aria-checked="false" tabindex="-1" class="dk-menu-item check" data-desk-appearance="dark" aria-label="Dark">Dark</button>
        <hr class="dk-menu-separator">
        <form class="dk-user-signout" method="post" action="/logout">
          <button type="submit" role="menuitem" tabindex="-1" class="dk-menu-item spread">Sign out</button>
        </form>
      </div>
    </div>
  </div>
  <button type="button" class="nav-search" aria-label="Search">⌕</button>
</header>`;

await import("../../priv/static/assets/bp-desk-navbar.js");
assert.equal(typeof window.BarkparkDeskNavbar, "object", "bp-desk-navbar.js loaded");

const focused = () => (doc.activeElement.getAttribute("aria-label") || doc.activeElement.textContent).trim();
const key = (k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  doc.activeElement.dispatchEvent(e);
  return e.defaultPrevented;
};

// One menu as a keyboard user meets it: Enter on its button opens it, the
// arrows, Home and End move, and Tab leaves it closed.
const walk = (id, buttonId, items) => {
  const menu = doc.getElementById(id);
  let hidden = 0;
  menu.hidePopover = () => {
    hidden += 1;
    menu.removeAttribute("data-open");
  };
  doc.getElementById(buttonId).focus();
  // `toggle` as the browser fires it on a popover (it does not bubble).
  menu.setAttribute("data-open", "");
  const open = new window.Event("toggle", { bubbles: false });
  open.newState = "open";
  menu.dispatchEvent(open);

  const [first, second] = items;
  const last = items[items.length - 1];
  assert.equal(focused(), first, `${id}: opened, the first item has the focus`);
  assert.equal(key("ArrowDown"), true, `${id}: ArrowDown is the menu's`);
  assert.equal(focused(), second, `${id}: ArrowDown moves to the next item`);
  key("ArrowUp");
  key("ArrowUp");
  assert.equal(focused(), last, `${id}: ArrowUp wraps to the last item`);
  key("Home");
  assert.equal(focused(), first, `${id}: Home goes to the first item`);
  key("End");
  assert.equal(focused(), last, `${id}: End goes to the last item`);
  assert.equal(key("x"), false, `${id}: other keys are left alone`);
  key("Tab");
  assert.equal(hidden, 1, `${id}: Tab closes the menu`);
};

walk("dk-help-menu", "help-menu", ["Report a problem", "Barkpark Studio", "Documentation", "Changelog", "What's new"]);
walk("dk-user-menu", "user-menu", ["System", "Light", "Dark", "Sign out"]);

// The perspective menu keeps opening on the perspective in use, and now has
// the same keys.
{
  const menu = doc.getElementById("dk-perspective-menu");
  menu.hidePopover = () => menu.removeAttribute("data-open");
  doc.getElementById("dk-perspective-button").focus();
  menu.setAttribute("data-open", "");
  const open = new window.Event("toggle", { bubbles: false });
  open.newState = "open";
  menu.dispatchEvent(open);
  assert.equal(focused(), "Drafts", "the perspective menu opens on the one in use");
  key("ArrowDown");
  assert.equal(focused(), "Published", "ArrowDown wraps to the first");
  key("End");
  assert.equal(focused(), "Drafts", "End goes to the last");
  key("Home");
  assert.equal(focused(), "Published", "Home goes to the first");
}

// A key in a popover that is not a navbar menu is left alone.
doc.body.insertAdjacentHTML("beforeend", `<div id="other" popover role="menu"><button role="menuitem">One</button><button role="menuitem">Two</button></div>`);
doc.querySelector("#other button").focus();
assert.equal(key("ArrowDown"), false, "another page's menu is not the navbar's to move");

console.log("desk navbar menu keys: ok");
