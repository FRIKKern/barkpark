// __desk_saves_pending.test.mjs — window.__savesPending() on a desk page:
// true while an edit is on its way to the server, false once it is answered.
// The TanStack Studio's e2e rig waits on it before it resets its fixture
// documents (e2e/rig/targets.ts closeAndSettle, savesLanded). An edit is on
// its way while it is
//   - typed in a field of the document (an input named doc[...]) and not yet
//     sent (the field's phx-debounce has not fired), or
//   - sent and not yet answered (LiveView marks the element the event came
//     from with `data-phx-ref-loading` until the reply).
// It shares the unload guard's state (__desk_slice_unload.test.mjs) and
// differs from it in one case: a failed save makes the tab ask, and is not
// on its way, because no wait ends it.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_saves_pending.test.mjs
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
const FORM =
  `<form id="editor-form" phx-change="autosave">` +
  `<input type="text" id="title" name="doc[title]" value="Here">` +
  `<div id="w-author" phx-update="ignore"><input type="hidden" name="doc[author]"><input id="author" type="text"></div>` +
  `</form>`;
doc.body.innerHTML =
  `<div id="desk-panes">` +
  `<section class="pane-column dk-pane dk-doc" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing data-desk-save="" aria-label="Post">` +
  `<div class="pane-body">${FORM}</div>` +
  `<div class="dk-edit-footer"><button type="button" id="publish" phx-click="publish">Publish</button></div>` +
  `</section></div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });

assert.equal(window.__savesPending, undefined, "no desk on the page: no function");
hook.mounted();
assert.equal(typeof window.__savesPending, "function", "the desk defines window.__savesPending");

const pending = () => window.__savesPending();
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
// LiveView's own mark while an event is on its way, and its reply.
const send = (node) => node.setAttribute("data-phx-ref-loading", "1");
const answer = (node) => node.removeAttribute("data-phx-ref-loading");

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

// A click's event (Publish) and a hook's pushEvent mark their own element,
// not the form: the unload guard does not ask, and the event is on its way.
const publish = doc.getElementById("publish");
send(publish);
assert.equal(asks(), false, "a click on its way is not an unsaved edit");
assert.equal(pending(), true, "a click sent and not yet answered: on its way");
answer(publish);
assert.equal(pending(), false, "the click answered: nothing on its way");
send(el);
assert.equal(pending(), true, "a hook's pushEvent not yet answered: on its way");
answer(el);
assert.equal(pending(), false, "the hook's reply: nothing on its way");

// A failed save: the tab asks (the edit is not saved), and nothing is on its
// way, so a wait for it would never end.
pane().setAttribute("data-desk-save", "Save failed");
await settle();
assert.equal(asks(), true, "the last save failed: the tab asks");
assert.equal(pending(), false, "a failed save is not a save on its way");
pane().setAttribute("data-desk-save", "");

// Typed, then the document closes: no form is left to send it.
type("title");
assert.equal(pending(), true, "typed: on its way");
const body = doc.querySelector(".pane-body");
body.innerHTML = "";
assert.equal(pending(), false, "the form that was typed in left the page");
body.innerHTML = FORM;
send(form());
await settle();
answer(form());
await settle();
assert.equal(pending(), false, "a change sent from the new form: nothing left on its way");

// The desk leaving the page takes its function with it.
hook.destroyed();
assert.equal(window.__savesPending, undefined, "the desk gone: no function");

console.log("desk saves pending: ok");
