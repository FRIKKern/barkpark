// __desk_slice_unload.test.mjs — B11 (unload-guard:35, :113): closing the tab
// asks first while an edit in the desk's editor has not reached the server,
// and not otherwise. An edit owes the server while it is
//   - typed in a field of the document (an input named doc[...]) and not yet
//     sent (the field's phx-debounce has not fired),
//   - sent and not yet answered (LiveView marks the form with
//     `data-phx-ref-loading` until the reply), or
//   - answered with a failed save (the edit pane's `data-desk-save`, the
//     server's save token).
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_unload.test.mjs
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
doc.body.innerHTML =
  `<input id="desk-search-input" type="search">` +
  `<div id="desk-panes">` +
  `<section class="pane-column dk-pane" id="p0" data-pane-index="0" data-pane-kind="list"><div class="pane-body"><input id="list-filter"></div></section>` +
  `<section class="pane-column dk-pane dk-doc" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing data-desk-save="" aria-label="Post">` +
  `<div class="pane-body"><form id="editor-form" phx-change="autosave">` +
  `<input type="text" id="title" name="doc[title]" value="Here">` +
  `<input type="date" id="day" name="doc[day]">` +
  `<div id="w-author" phx-update="ignore"><input type="hidden" name="doc[author]"><input id="author" type="text"></div>` +
  `</form></div></section></div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();

const settle = () => new Promise((resolve) => setImmediate(resolve));
const form = () => doc.getElementById("editor-form");
const pane = () => doc.getElementById("p1");
const type = (id) => doc.getElementById(id).dispatchEvent(new window.Event("input", { bubbles: true }));
// What a closing tab does: the browser asks only when a listener cancels the event.
const asks = () => {
  const e = new window.Event("beforeunload", { cancelable: true });
  window.dispatchEvent(e);
  return e.defaultPrevented;
};
// LiveView's own marks while a change event is on its way, and its reply.
const send = () => (form().setAttribute("data-phx-ref-loading", "1"), form().classList.add("phx-change-loading"));
const answer = () => (form().removeAttribute("data-phx-ref-loading"), form().classList.remove("phx-change-loading"));

assert.equal(asks(), false, "nothing typed: the tab closes");

type("title");
assert.equal(asks(), true, "typed, not yet sent (the debounce): asks");

send();
await settle();
assert.equal(asks(), true, "sent, not yet answered: asks");

answer();
await settle();
assert.equal(asks(), false, "answered: the tab closes");

// Typed while the last change was on its way: that change does not carry it.
send();
await settle();
type("title");
answer();
await settle();
assert.equal(asks(), true, "typed after the change went: still owed");
send();
await settle();
answer();
await settle();
assert.equal(asks(), false, "the next change carried it");

// A failed save: asks until a save lands.
pane().setAttribute("data-desk-save", "Save failed");
await settle();
assert.equal(asks(), true, "the last save failed: asks");
pane().setAttribute("data-desk-save", "Saved");
await settle();
assert.equal(asks(), false, "saved: the tab closes");

// Another field of the document counts like any.
type("day");
assert.equal(asks(), true, "a typed, unsent date: asks");
send();
await settle();
answer();
await settle();
assert.equal(asks(), false);

// A widget's own box with no field name (the reference picker's search,
// inside phx-update="ignore"): its text never goes through the form, so it
// is not an edit, or the tab would ask for ever (seen in a browser).
type("author");
assert.equal(asks(), false, "the reference picker's search box is not an edit");

// Typing outside the editor's form (the search box, a list filter) owes nothing.
type("desk-search-input");
type("list-filter");
assert.equal(asks(), false, "the search box and a list filter are not edits");

// A typed field whose pane went away (the document closed): nothing to ask about.
type("title");
pane().remove();
assert.equal(asks(), false, "no editor on the page: the tab closes");

// Destroyed: the listener goes with the hook.
hook.destroyed();
assert.equal(asks(), false);

console.log("desk unload guard: ok");
