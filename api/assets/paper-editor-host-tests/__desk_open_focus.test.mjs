// __desk_open_focus.test.mjs — task-88ab82fdaeb39c10: a document opened from a
// desk list (a row clicked or Entered, a reference followed) takes the focus into
// its form once its editor is in, as the TanStack Studio's focusIntoForm does: its
// first group tab, All fields, or with no groups its first field's actions. On
// main only a page load did; a followed row kept the focus on the row.
//
// Runs the TRACKED asset api/priv/static/assets/bp-tab-keys.js under jsdom, with
// LiveView's `phx:navigate` event and the desk's pane markup (editor_host.ex:
// the edit pane is a section with data-pane-editing and data-pane="doc:<id>").
//
// Run: node ../paper-editor-host-tests/__desk_open_focus.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "http://localhost/w/default/p/default/d/e2e/studio/_desk";
const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: `${BASE}/post` });
const { window } = dom;
for (const name of ["document", "Element", "Event", "CustomEvent", "KeyboardEvent", "HTMLElement", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-tab-keys.js");
const { openedBy, formStart } = window.BarkparkTabKeys;

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
  // Whatever is still armed ends, as a key ends it in the page.
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Shift", bubbles: true }));
}

const tick = () => new Promise((r) => setTimeout(r, 0));
// LiveView's event for a patch or a history step; the URL moves with it.
function navigate(path, extra = {}) {
  window.history.pushState({}, "", `${BASE}/${path}`);
  window.dispatchEvent(new window.CustomEvent("phx:navigate", { detail: { href: `${BASE}/${path}`, patch: true, pop: false, direction: "forward", ...extra } }));
}
const list = () =>
  `<div id="desk-panes"><section data-pane-index="1" data-pane-kind="list">` +
  `<input id="search" role="combobox" />` +
  `<a class="pane-item" id="row-02" href="/post;post-02">Fixture post 02</a>` +
  `<a class="pane-item" id="row-03" href="/post;post-03">Fixture post 03</a>` +
  `</section><div id="slot"></div></div>`;
const groups = (id, { disabled = false } = {}) =>
  `<section data-pane-index="2" data-pane-kind="doc" data-pane="doc:${id}" data-pane-editing>` +
  `<button type="button" id="share-${id}" aria-label="Share document">Share</button>` +
  `<div class="bp-tab-bar" role="tablist">` +
  `<button type="button" role="tab" id="all-${id}" aria-selected="false" tabindex="-1"${disabled ? " disabled" : ""}>All fields</button>` +
  `<button type="button" role="tab" id="content-${id}" aria-selected="true" tabindex="0"${disabled ? " disabled" : ""}>Content</button>` +
  `</div><div id="editor-tabpanel"><form id="editor-form">` +
  `<div class="field"><div class="field-actions"><button type="button" id="actions-title-${id}">…</button></div>` +
  `<input type="text" id="title" /></div></form></div></section>`;
const plain = (id) =>
  `<section data-pane-index="2" data-pane-kind="doc" data-pane="doc:${id}" data-pane-editing>` +
  `<button type="button" id="share-${id}" aria-label="Share document">Share</button>` +
  `<form id="editor-form"><input type="hidden" name="_bp_seen" />` +
  `<div role="menu" popover id="shared-menu"><button type="button" role="menuitem" id="copy">Copy field</button></div>` +
  `<div class="field"><div class="field-actions"><button type="button" id="actions-name-${id}">…</button></div>` +
  `<input type="text" id="name" /></div></form></section>`;
const slot = () => document.getElementById("slot");
const active = () => document.activeElement && document.activeElement.id;

// Where a check starts: the URL it is on (a Back to it opens nothing) and the list.
function start(path) {
  navigate(path, { pop: true, direction: "backward" });
  document.body.innerHTML = list();
}

await check("a row clicked from the list: All fields takes the focus once the editor is in", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  assert.equal(active(), "row-02", "nothing moves before the editor is drawn");
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "all-post-02");
});

await check("the editor already drawn when the URL lands: it takes the focus at once", async () => {
  start("post");
  slot().innerHTML = groups("post-02");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  assert.equal(active(), "all-post-02");
});

await check("another row while a document is open: the new one takes it, not the old one's form", async () => {
  start("post;post-03");
  slot().innerHTML = groups("post-03");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  await tick();
  assert.equal(active(), "row-02", "the old document's editor is not the one opened");
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "all-post-02");
});

await check("an open the next one replaces places nothing late", async () => {
  start("post");
  slot().innerHTML = groups("post-03");
  navigate("post;post-03");
  assert.equal(active(), "all-post-03");
  document.getElementById("row-02").focus(); // queues a placement for post-03
  navigate("post;post-02");
  await tick();
  await tick();
  assert.equal(active(), "row-02");
});

await check("the row the desk focuses again after the patch gives the focus back to the form", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  slot().innerHTML = groups("post-02");
  await tick();
  document.getElementById("row-02").focus(); // bp-desk.js's _giveFocusBack
  await tick();
  await tick();
  assert.equal(active(), "all-post-02");
});

await check("a form re-drawn that drops the focus to the page gets it placed again", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  slot().innerHTML = groups("post-02");
  await tick();
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "all-post-02");
});

await check("tabs that wait (disabled) take it once they are enabled", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  slot().innerHTML = groups("post-02", { disabled: true });
  await tick();
  assert.equal(active(), "row-02");
  slot().querySelectorAll("[role=tab]").forEach((t) => t.removeAttribute("disabled"));
  await tick();
  assert.equal(active(), "all-post-02");
});

await check("no groups: the first field's actions, not a hidden input or the shared menu", async () => {
  start("author");
  document.getElementById("row-02").focus();
  navigate("author;author-alan");
  slot().innerHTML = plain("author-alan");
  await tick();
  assert.equal(active(), "actions-name-author-alan");
});

await check("Back moves nothing", async () => {
  start("post;post-02;author-alan");
  slot().innerHTML = groups("post-02");
  document.getElementById("row-03").focus();
  window.history.pushState({}, "", `${BASE}/post;post-02`);
  window.dispatchEvent(new window.CustomEvent("phx:navigate", { detail: { href: `${BASE}/post;post-02`, patch: true, pop: true, direction: "backward" } }));
  await tick();
  assert.equal(active(), "row-03");
});

await check("Back to a document that was not the last one moves nothing either", async () => {
  start("post;post-03");
  slot().innerHTML = groups("post-02");
  document.getElementById("row-03").focus();
  navigate("post;post-02", { pop: true, direction: "backward" });
  await tick();
  assert.equal(active(), "row-03");
});

await check("Forward opens as a click does", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02", { pop: true, direction: "forward" });
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "all-post-02");
});

await check("a pane closed, a revision or an inspector of the same document move nothing", async () => {
  start("post;post-02;author-alan");
  slot().innerHTML = groups("post-02");
  document.getElementById("row-03").focus();
  navigate("post;post-02");
  await tick();
  navigate("post;post-02,rev=abc");
  await tick();
  navigate("post;post-02,inspect=sanity%2Fstructure%2Fhistory");
  await tick();
  assert.equal(active(), "row-03");
});

await check("a remote save or a presence change (a patch, no URL) moves nothing", async () => {
  start("post;post-02");
  slot().innerHTML = groups("post-02");
  document.getElementById("title").focus();
  slot().innerHTML = groups("post-02");
  await tick();
  document.getElementById("row-03").focus();
  slot().querySelector("[role=tab]").setAttribute("data-x", "1");
  await tick();
  assert.equal(active(), "row-03");
});

await check("a focus in a box being typed in stays", async () => {
  start("post");
  document.getElementById("search").focus();
  navigate("post;post-02");
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "search");
});

await check("a focus in a dialog stays", async () => {
  start("post");
  slot().insertAdjacentHTML("beforebegin", `<div role="dialog"><button type="button" id="hit">Hit</button></div>`);
  document.getElementById("hit").focus();
  navigate("post;post-02");
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "hit");
});

await check("a focus already in the opened pane (a field it placed) stays", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  slot().innerHTML = groups("post-02");
  document.getElementById("share-post-02").focus();
  await tick();
  assert.equal(active(), "share-post-02");
});

await check("a key before the editor is in ends it", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "row-02");
});

await check("a press before the editor is in ends it", async () => {
  start("post");
  document.getElementById("row-02").focus();
  navigate("post;post-02");
  document.dispatchEvent(new window.Event("pointerdown", { bubbles: true }));
  slot().innerHTML = groups("post-02");
  await tick();
  assert.equal(active(), "row-02");
});

await check("openedBy: the last pane's document when the URL before named another there", () => {
  assert.equal(typeof openedBy, "function", "bp-tab-keys.js exports openedBy");
  assert.equal(openedBy("/_desk/post", "/_desk/post;post-02"), "post-02");
  assert.equal(openedBy("/_desk/post;post-03", "/_desk/post;post-02"), "post-02");
  assert.equal(openedBy("/structure/post;post-01", "/structure/post;post-01;author-alan,type=author,parentRefPath=author"), "author-alan");
  assert.equal(openedBy("/_desk/post;post-02;author-alan", "/_desk/post;post-02"), null, "a pane closed");
  assert.equal(openedBy("/_desk/post;post-02", "/_desk/post;post-02,rev=abc"), null, "a revision");
  assert.equal(openedBy("/_desk/post", "/_desk/author"), null, "a list");
  assert.equal(openedBy("/_desk", "/_desk/post"), null, "a list");
  assert.equal(openedBy("/_desk/post", "/_desk/post;caf%C3%A9"), "café");
});

await check("formStart: none while the bar's tabs wait; the first tab, not the one selected", () => {
  assert.equal(typeof formStart, "function", "bp-tab-keys.js exports formStart");
  document.body.innerHTML = groups("x", { disabled: true });
  assert.equal(formStart(document.querySelector("[data-pane-editing]")), null);
  document.body.innerHTML = groups("x");
  assert.equal(formStart(document.querySelector("[data-pane-editing]")).id, "all-x");
  assert.equal(formStart(null), null);
});

dom.window.close();
if (failures) {
  console.log(`${failures} failure(s)`);
  process.exit(1);
}
console.log("desk open focus passed");
