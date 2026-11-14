// __desk_saves_pending.test.mjs — window.__savesPending() (bp-desk-saves.js):
// true while an edit of the page is on its way to the server, false once it
// is answered. The TanStack Studio's e2e rig waits on it before it resets its
// fixture documents (e2e/rig/targets.ts closeAndSettle, savesLanded). An edit
// is on its way while it is
//   - typed in a field of the document (an input named doc[...]) and not yet
//     sent (the field's phx-debounce has not fired), or
//   - sent and not yet answered (LiveView marks the element the event came
//     from with `data-phx-ref-loading` until the reply).
// A refused save is not on its way: no wait ends it.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-saves.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_saves_pending.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/post;post-a",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk-saves.js");

const doc = window.document;
const FORM =
  `<form id="editor-form" phx-change="autosave">` +
  `<input type="text" id="title" name="doc[title]" value="Here">` +
  `<div id="w-author" phx-update="ignore"><input type="hidden" name="doc[author]"><input id="author" type="text"></div>` +
  `</form>`;
doc.body.innerHTML =
  `<div id="desk-panes">` +
  `<section id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing data-desk-save="">` +
  `<div class="pane-body">${FORM}</div>` +
  `<div class="dk-edit-footer"><button type="button" id="publish" phx-click="publish">Publish</button></div>` +
  `</section></div>`;

assert.equal(typeof window.__savesPending, "function", "bp-desk-saves.js defines window.__savesPending");
const pending = () => window.__savesPending();
const settle = () => new Promise((resolve) => setImmediate(resolve));
const form = () => doc.getElementById("editor-form");
const type = (id) => doc.getElementById(id).dispatchEvent(new window.Event("input", { bubbles: true }));
// LiveView's own mark while an event is on its way, and its reply.
const send = (el) => el.setAttribute("data-phx-ref-loading", "1");
const answer = (el) => el.removeAttribute("data-phx-ref-loading");

assert.equal(pending(), false, "nothing typed, nothing sent: no save is on its way");

// An autosave: typed, sent after the debounce, answered.
type("title");
assert.equal(pending(), true, "typed, not yet sent (the debounce): a save is on its way");
send(form());
await settle();
assert.equal(pending(), true, "sent, not yet answered: still on its way");
answer(form());
await settle();
assert.equal(pending(), false, "answered: the save has landed");

// Typed again while the first change is out: its reply does not pay for it.
type("title");
send(form());
await settle();
type("title");
answer(form());
await settle();
assert.equal(pending(), true, "typed after the change went out: a second save is on its way");
send(form());
await settle();
answer(form());
await settle();
assert.equal(pending(), false, "the second answer: landed");

// A widget's own box (the reference picker's search) is not a field of the document.
type("author");
assert.equal(pending(), false, "a box that is not doc[...] sends no save");

// A click's event (Publish) and a hook's pushEvent mark their own element.
const publish = doc.getElementById("publish");
send(publish);
assert.equal(pending(), true, "a click sent and not yet answered: on its way");
answer(publish);
assert.equal(pending(), false, "the click answered: nothing on its way");
const panes = doc.getElementById("desk-panes");
send(panes);
assert.equal(pending(), true, "a hook's pushEvent not yet answered: on its way");
answer(panes);
assert.equal(pending(), false, "the hook's reply: nothing on its way");

// A refused save is not on its way: waiting would never end.
doc.getElementById("p1").setAttribute("data-desk-save", "Save failed");
assert.equal(pending(), false, "a refused save is not a save on its way");
doc.getElementById("p1").setAttribute("data-desk-save", "");

// Typed, then another document opens in the form's place: the old form owes nothing.
type("title");
assert.equal(pending(), true, "typed: on its way");
doc.querySelector(".pane-body").innerHTML = FORM;
assert.equal(pending(), false, "the form that was typed in left the page");
type("title");
assert.equal(pending(), true, "typed in the new form: on its way");
send(form());
await settle();
answer(form());
await settle();
assert.equal(pending(), false, "the new form's save landed");

console.log("desk saves pending: ok");
