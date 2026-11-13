// __desk_slice_doc_keys.test.mjs — keyboard.spec:51 and :178: Sanity's
// document shortcuts, Ctrl+Alt+P (Publish) and Ctrl+Alt+D (Delete), act from
// inside the edit pane only. Each presses the document menu's own item, so a
// key does only what the menu offers; typing still in a field's debounce is
// sent first (a blur), and the focus stays where it was.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_doc_keys.test.mjs
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
const item = (where, action, label) =>
  `<button type="button" role="menuitem" tabindex="-1" id="${where}-${action}" data-desk-doc-action="${action}" phx-click="${action}">${label}</button>`;
const menu = (where) =>
  `<div class="dk-doc-menu"><button type="button" id="${where}-button" aria-haspopup="menu">…</button>` +
  `<div id="${where}" popover role="menu">` +
  item(where, "publish", "Publish") + item(where, "show-history", "History") + item(where, "delete-doc", "Delete") +
  `</div></div>`;
doc.body.innerHTML =
  `<div id="desk-panes">` +
  `<section class="pane-column dk-pane" id="p0" data-pane-index="0" data-pane-kind="list">` +
  `<div class="pane-body"><a id="row" class="pane-item" href="${BASE}/post;post-a">Post A</a></div></section>` +
  `<section class="pane-column dk-pane dk-doc" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing aria-label="Post A">` +
  `<div class="pane-header">${menu("head")}</div>` +
  `<div class="pane-body"><form id="editor-form"><input type="text" id="title" name="doc[title]" value="Post A"></form></div>` +
  `<div class="dk-edit-footer">${menu("foot")}</div></section></div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();

const seen = [];
for (const b of doc.querySelectorAll("[data-desk-doc-action]")) b.addEventListener("click", () => seen.push(`click ${b.id}`));
const title = doc.getElementById("title");
title.addEventListener("blur", () => seen.push("blur title"));

// macOS: Alt changes the letter (π, ∂); the key's place does not change.
const press = (id, code, init = {}) => {
  const e = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, code, key: "π", ctrlKey: true, altKey: true, ...init });
  doc.getElementById(id).dispatchEvent(e);
  return e.defaultPrevented;
};

// In the pane: Publish. The field's pending typing goes first, the focus stays.
title.focus();
assert.equal(press("title", "KeyP"), true, "Ctrl+Alt+P in the pane is handled");
assert.deepEqual(seen, ["blur title", "click head-publish"], "the field's typing is sent, then the menu's Publish, once");
assert.equal(doc.activeElement, title, "the focus stays in the field");

// In the pane: Delete asks (the menu's item opens the Studio's dialog).
seen.length = 0;
assert.equal(press("title", "KeyD"), true, "Ctrl+Alt+D in the pane is handled");
assert.deepEqual(seen, ["blur title", "click head-delete-doc"]);

// From the pane's own header (a button focused): the same, no field to send.
doc.getElementById("head-button").focus();
seen.length = 0;
assert.equal(press("head-button", "KeyP"), true);
assert.deepEqual(seen, ["click head-publish"]);

// From a list row: nothing, as Sanity's.
seen.length = 0;
assert.equal(press("row", "KeyP"), false, "from the list: not handled");
assert.equal(press("row", "KeyD"), false);
assert.deepEqual(seen, [], "from the list: nothing pressed");

// Not the shortcut: Shift or Meta added, another key.
seen.length = 0;
press("title", "KeyP", { shiftKey: true });
press("title", "KeyD", { metaKey: true });
press("title", "KeyX");
assert.deepEqual(seen, [], "other chords press nothing");

// The menu does not offer it (a singleton has no Delete; a document with no
// draft has no Publish): the key does nothing and the browser keeps it.
doc.getElementById("head-delete-doc").remove();
doc.getElementById("foot-delete-doc").remove();
seen.length = 0;
assert.equal(press("title", "KeyD"), false, "no Delete in the menu: not handled");
assert.deepEqual(seen, []);

// A published document: the menu offers Unpublish, and Publish only once the
// typing's save has made a draft. Ctrl+Alt+P right after typing sends the
// typing, waits for the save's answer to bring Publish, then presses it.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
for (const w of ["head", "foot"]) doc.getElementById(`${w}-publish`).remove();
title.focus();
title.dispatchEvent(new window.Event("input", { bubbles: true })); // typed, not yet sent
seen.length = 0;
assert.equal(press("title", "KeyP"), true, "typed in a published document: handled");
assert.deepEqual(seen, ["blur title"], "the typing is sent; nothing to press yet");
const form = doc.getElementById("editor-form");
form.setAttribute("data-phx-ref-loading", ""); // LiveView: the save is out
await wait(20);
doc.getElementById("head").insertAdjacentHTML("afterbegin", item("head", "publish", "Publish"));
doc.getElementById("head-publish").addEventListener("click", () => seen.push("click head-publish"));
await wait(250);
assert.deepEqual(seen, ["blur title"], "not while the save is unanswered");
form.removeAttribute("data-phx-ref-loading"); // answered
await wait(250);
assert.deepEqual(seen, ["blur title", "click head-publish"], "Publish once the save is answered, once");
await wait(250);
assert.deepEqual(seen, ["blur title", "click head-publish"], "and only once");

// Nothing typed and no Publish (published, no draft): the key does nothing.
doc.getElementById("head-publish").remove();
seen.length = 0;
assert.equal(press("title", "KeyP"), false, "nothing to publish: not handled");
await wait(250);
assert.deepEqual(seen, []);

console.log("desk slice doc keys: ok");
