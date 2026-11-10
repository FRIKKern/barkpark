// __desk_slice_keys.test.mjs — the desk slice's list keys
// (task-65be8b75b621b8c2, /papers/desk-vertical-slice): ArrowDown / ArrowUp
// move the focus from row to row, Home / End jump to the ends, Enter is left
// to the link, and a row that had the focus when it was followed gets it back
// after the patch re-drew its pane.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_keys.test.mjs
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

const row = (href, title) =>
  `<a href="${BASE}/${href}" class="pane-item" data-desk-row data-desk-opens="doc"><span class="pane-item-label">${title}</span></a>`;
const list = () =>
  `<section class="pane-column dk-pane" id="p1" data-pane-index="1" data-pane-kind="list"><div class="pane-header"><a class="dk-close" href="${BASE}">×</a></div><div class="pane-body">` +
  row("post;a", "Alpha") + `<div class="pane-divider"></div>` + row("post;b", "Beta") + row("post;c", "Gamma") +
  `</div></section>`;
window.document.body.innerHTML =
  `<div id="desk-panes"><section class="pane-column dk-pane" id="p0" data-pane-index="0" data-pane-kind="types"><div class="pane-body">` +
  `<a href="${BASE}/post" class="pane-item selected" aria-current="true" data-desk-row data-desk-opens="list"><span class="pane-item-label">Posts</span></a>` +
  `</div></section>${list()}</div>`;

const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();
window.addEventListener("click", (e) => e.preventDefault());

const rowTo = (href) => window.document.querySelector(`a[href="${BASE}/${href}"]`);
const focused = () => window.document.activeElement?.textContent;
const key = (name, init = {}) => {
  const event = new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...init });
  window.document.activeElement.dispatchEvent(event);
  return event;
};

// ── Arrow keys walk the rows of one pane, past dividers, and stop at the ends ─
rowTo("post;a").focus();
assert.ok(key("ArrowDown").defaultPrevented, "the page does not scroll under the key");
assert.equal(focused(), "Beta", "ArrowDown moves one row, over the divider");
key("ArrowDown");
assert.equal(focused(), "Gamma");
key("ArrowDown");
assert.equal(focused(), "Gamma", "the last row is the end; the focus never leaves the pane");
key("ArrowUp");
assert.equal(focused(), "Beta");
key("Home");
assert.equal(focused(), "Alpha");
key("ArrowUp");
assert.equal(focused(), "Alpha", "the first row is the top");
key("End");
assert.equal(focused(), "Gamma");

// ── Enter, Tab and modified arrows are not the hook's ───────────────────────
assert.ok(!key("Enter").defaultPrevented, "Enter is the link's own: it follows the href");
assert.ok(!key("Tab").defaultPrevented);
assert.ok(!key("ArrowUp", { altKey: true }).defaultPrevented, "Alt+Arrow is the browser's (history)");
assert.equal(focused(), "Gamma");

// A key on something that is not a row does nothing.
window.document.querySelector(".dk-close").focus();
assert.ok(!key("ArrowDown").defaultPrevented);

// ── A followed row keeps the focus through the patch that re-draws its pane ──
rowTo("post;b").focus();
rowTo("post;b").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
// The patch: the server's pane replaces this one, and the focus falls to <body>.
window.document.getElementById("p1").remove();
window.document.querySelector("[data-desk-skeleton]")?.remove();
el.insertAdjacentHTML("beforeend", list());
assert.equal(window.document.activeElement, window.document.body, "the re-drawn row lost the focus (the defect)");
window.history.replaceState({}, "", `${BASE}/post;b`);
window.dispatchEvent(new window.Event("phx:page-loading-stop"));
assert.equal(focused(), "Beta", "the row with the same href takes the focus back");

// A focus the patch placed on purpose is not taken away.
rowTo("post;c").focus();
rowTo("post;c").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
window.document.querySelector(".dk-close").focus();
window.history.replaceState({}, "", `${BASE}/post;c`);
window.dispatchEvent(new window.Event("phx:page-loading-stop"));
assert.equal(window.document.activeElement, window.document.querySelector(".dk-close"));

// A mouse click on a row that did not have the focus moves no focus.
window.document.activeElement.blur();
rowTo("post;a").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
window.history.replaceState({}, "", `${BASE}/post;a`);
window.dispatchEvent(new window.Event("phx:page-loading-stop"));
assert.equal(window.document.activeElement, window.document.body);

hook.destroyed();
console.log("desk slice keys: ok");
window.close();
