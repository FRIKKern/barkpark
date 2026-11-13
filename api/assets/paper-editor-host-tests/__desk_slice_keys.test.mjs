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
  `<button type="button" class="dk-more">Show more</button></div></section>`;
window.document.body.innerHTML =
  `<input id="desk-search-input" type="search" /><div id="desk-panes"><section class="pane-column dk-pane" id="p0" data-pane-index="0" data-pane-kind="types"><div class="pane-body">` +
  `<a href="${BASE}/post" class="pane-item selected" aria-current="true" data-desk-row data-desk-opens="list"><span class="pane-item-label">Posts</span></a>` +
  `</div></section>${list()}</div>`;

const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
// jsdom lays nothing out: every element in the page counts as drawn.
window.HTMLElement.prototype.getClientRects = function () {
  return this.isConnected ? [{}] : [];
};
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

// ── Enter and modified arrows are not the hook's ────────────────────────────
assert.ok(!key("Enter").defaultPrevented, "Enter is the link's own: it follows the href");
assert.ok(!key("ArrowUp", { altKey: true }).defaultPrevented, "Alt+Arrow is the browser's (history)");
assert.ok(!key("ArrowUp", { shiftKey: true }).defaultPrevented, "Shift+Arrow is not a row step");
assert.equal(focused(), "Gamma");

// ── A list is one Tab stop: Tab from any row leaves the list ────────────────
rowTo("post;a").focus();
assert.ok(key("Tab").defaultPrevented, "Tab from a row is the hook's");
assert.equal(focused(), "Show more", "to the first control after the rows, not to the next row");
rowTo("post;b").focus();
key("Tab", { shiftKey: true });
assert.equal(window.document.activeElement, window.document.querySelector("#p1 .dk-close"), "Shift+Tab goes to the last control before the rows");
// From the first pane's row, Tab goes on to what follows the pane: its separator.
rowTo("post").focus();
key("Tab");
assert.equal(window.document.activeElement.getAttribute("role"), "separator");
assert.equal(window.document.activeElement.previousElementSibling.id, "p0");
// ── One Tab stop coming in: the selected row, never the last ────────────────
// (task-1b35e2d6b0c3f242: Shift+Tab back into the root landed on "…Rest".)
const more = window.document.querySelector(".dk-more");
const above = window.document.querySelector("#p1 .dk-close");
rowTo("post;b").classList.add("selected");
more.focus();
assert.ok(key("Tab", { shiftKey: true }).defaultPrevented, "Shift+Tab into a list is the hook's");
assert.equal(focused(), "Beta", "Shift+Tab from below lands on the selected row, not the last");
above.focus();
assert.ok(key("Tab").defaultPrevented);
assert.equal(focused(), "Beta", "Tab from above lands on the selected row too");
rowTo("post;b").classList.remove("selected");
more.focus();
key("Tab", { shiftKey: true });
assert.equal(focused(), "Alpha", "with none selected, Shift+Tab lands on the first row");
above.focus();
assert.ok(!key("Tab").defaultPrevented, "Tab from above onto the first row is the browser's own");
window.document.getElementById("desk-search-input").focus();
assert.ok(!key("Tab").defaultPrevented, "the search box onto the root's selected first row: the browser's own");

// Nothing after the rows (the last pane): the focus leaves for the page, and nothing is left behind.
window.document.querySelector(".dk-more").remove();
rowTo("post;b").focus();
const spans = window.document.querySelectorAll("body > span").length;
assert.ok(key("Tab").defaultPrevented);
assert.equal(window.document.activeElement, window.document.body, "past the last control the focus is the page's");
assert.equal(window.document.querySelectorAll("body > span").length, spans);
assert.ok(!(() => { window.document.querySelector(".dk-close").focus(); return key("Tab"); })().defaultPrevented, "Tab from anything but a row is the browser's");

// ── Cmd+K / Ctrl+K: the search box, unless something else took the key ──────
const box = window.document.getElementById("desk-search-input");
rowTo("post;a").focus();
assert.ok(key("k", { metaKey: true }).defaultPrevented);
assert.equal(window.document.activeElement, box, "Cmd+K focuses the search box");
rowTo("post;a").focus();
key("K", { ctrlKey: true });
assert.equal(window.document.activeElement, box, "Ctrl+K too");
rowTo("post;a").focus();
assert.ok(!key("k").defaultPrevented, "a bare k is a letter");
assert.ok(!key("k", { metaKey: true, shiftKey: true }).defaultPrevented);
const taken = (e) => e.preventDefault();
el.addEventListener("keydown", taken);
key("k", { metaKey: true });
assert.equal(focused(), "Alpha", "a key another handler took is left alone");
el.removeEventListener("keydown", taken);
rowTo("post;c").focus();

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

// ── A pane closed from the keyboard: the focus stays in the desk ────────────
window.history.replaceState({}, "", `${BASE}/post`);
window.dispatchEvent(new window.Event("phx:page-loading-stop"));
const close = window.document.querySelector("#p1 .dk-close");
close.focus();
key("Enter");
close.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
// The patch: the list is gone, and with it the link that had the focus.
window.document.getElementById("p1").remove();
window.history.replaceState({}, "", BASE);
window.dispatchEvent(new window.Event("phx:page-loading-stop"));
assert.equal(window.document.activeElement, window.document.getElementById("p0"), "the pane that is last now has the focus, not <body>");
assert.equal(window.document.getElementById("p0").getAttribute("tabindex"), "-1");

// ── Publish by Enter: the answer takes the button away, the "…" beside it gets the focus ──
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const menuButton = (id) => `<div class="dk-doc-menu"><button type="button" id="${id}" aria-haspopup="menu">…</button></div>`;
el.insertAdjacentHTML(
  "beforeend",
  `<section class="pane-column dk-pane" id="p2" data-pane-index="2" data-pane-kind="doc" data-pane-editing>` +
    `<div class="pane-header">${menuButton("p2-actions-button")}</div>` +
    `<bp-overflow-menu><button type="button" id="pub">Publish</button></bp-overflow-menu>` +
    `<div class="dk-edit-footer">${menuButton("p2-footer-actions-button")}</div></section>`,
);
const publishButton = () => window.document.getElementById("pub");
const footer = () => window.document.getElementById("p2-footer-actions-button");
const answer = () => publishButton().replaceWith(Object.assign(window.document.createElement("button"), { id: "pub", textContent: "Unpublish" }));
// The patch keeps the element and makes it Unpublish: the focus stayed on it,
// and a second Enter unpublished.
publishButton().focus();
key("Enter");
publishButton().setAttribute("aria-label", "Unpublish");
publishButton().textContent = "Unpublish";
await tick();
assert.equal(window.document.activeElement, footer(), "Publish became Unpublish: the last \"…\" in the pane has the focus");
publishButton().removeAttribute("aria-label");
publishButton().textContent = "Publish";
// The answer takes the button away.
publishButton().focus();
key("Enter");
answer();
await tick();
assert.equal(window.document.activeElement, footer(), "Publish went away: the last \"…\" in the pane has the focus, not <body>");
publishButton().textContent = "Publish";
// A button the answer disables, the same.
publishButton().focus();
key("Enter");
publishButton().disabled = true;
await tick();
assert.equal(window.document.activeElement, footer(), "a disabled Publish hands the focus on too");
publishButton().disabled = false;
// A focus moved meanwhile stays where it went.
publishButton().focus();
key("Enter");
window.document.getElementById("p2-actions-button").focus();
answer();
await tick();
assert.equal(window.document.activeElement.id, "p2-actions-button", "a focus placed elsewhere is not taken away");
// A key that presses nothing moves nothing.
publishButton().focus();
key("a");
answer();
await tick();
assert.equal(window.document.activeElement, window.document.body, "only Enter or Space counts as a press");

// ── J41: ArrowDown past the last row while the list reads more is kept ───────
// (big-list.spec.ts, the ArrowDown walk: 110 steps from row 1 of 100 end on row 111.)
const item = (n) => `<div role="listitem" aria-posinset="${n}">${row(`big;b${n}`, `Big ${n}`)}</div>`;
const big = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => item(from + i)).join("");
el.insertAdjacentHTML("beforeend", `<section class="pane-column dk-pane" id="p3" data-pane-index="1" data-pane-kind="list"><div class="pane-body"><div role="list">${big(1, 3)}</div><div class="dk-list-more" aria-hidden="true"></div></div></section>`);
const bigList = window.document.querySelector("#p3 [role=list]");
rowTo("big;b3").focus();
for (let i = 0; i < 4; i++) assert.ok(key("ArrowDown").defaultPrevented);
assert.equal(focused(), "Big 3", "the last row keeps the focus while the rest reads");
// The patch adds the rows below; the row with focus is the same element.
bigList.insertAdjacentHTML("beforeend", big(4, 10));
await tick();
assert.equal(focused(), "Big 7", "the four steps owed are taken once the rows land");
// With nothing more to read, no step is owed.
window.document.querySelector("#p3 .dk-list-more").remove();
rowTo("big;b10").focus();
key("ArrowDown");
bigList.insertAdjacentHTML("beforeend", big(11, 12));
await tick();
assert.equal(focused(), "Big 10", "no room for more: the last row is the end");
// A held key owes at most 50 steps, however long it is held.
bigList.insertAdjacentHTML("afterend", `<div class="dk-list-more" aria-hidden="true"></div>`);
rowTo("big;b12").focus();
for (let i = 0; i < 80; i++) key("ArrowDown");
bigList.insertAdjacentHTML("beforeend", big(13, 200));
await tick();
assert.equal(focused(), "Big 62", "80 presses at the end owe 50 steps, not 80");
// The focus leaving the row drops what it owed, even when it comes back.
rowTo("big;b200").focus();
key("ArrowDown");
key("ArrowDown");
rowTo("big;b1").focus();
rowTo("big;b200").focus();
bigList.insertAdjacentHTML("beforeend", big(201, 210));
await tick();
assert.equal(focused(), "Big 200", "steps owed before the focus left are not taken");
window.document.getElementById("p3").remove();
window.document.getElementById("p2").remove();

// ── A document opened from the keys (a search hit's Enter, a "+") takes the
// focus in its first field. The edit pane is the view's id plus "-editor".
el.insertAdjacentHTML(
  "beforeend",
  `<section class="pane-column dk-pane" id="desk-pane-2-doc:post-12-editor" data-pane-editing>` +
    `<form id="editor-form"><div class="field"><input type="hidden" id="_id"></div>` +
    `<div class="field"><input id="title"></div><div class="field"><textarea id="summary"></textarea></div></form></section>`
);
window.document.getElementById("desk-search-input").focus();
window.dispatchEvent(new window.CustomEvent("phx:bp:focus-new-doc", { detail: { id: "post-12" } }));
await tick();
assert.equal(window.document.activeElement?.id, "title", "the opened document's first field has the focus");
window.document.getElementById("desk-pane-2-doc:post-12-editor").remove();

hook.destroyed();
assert.equal(el.querySelector('[role="separator"]'), null, "destroyed() takes the separators with it");
box.blur();
window.document.body.dispatchEvent(new window.KeyboardEvent("keydown", { key: "k", metaKey: true, bubbles: true, cancelable: true }));
assert.notEqual(window.document.activeElement, box, "and the Cmd+K listener");
console.log("desk slice keys: ok");
window.close();
