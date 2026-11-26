// __desk_leave.test.mjs: the browser half of the desk's question before it
// leaves a document with a held field (bp-desk-leave.js, `Desk.LeaveGuard`,
// task-33cbb6269c8823ad, #28408 review r2).
//
//   - A plain click on a desk link while a field is held is held back and
//     sent (`desk-leave`); with nothing held it goes.
//   - A link in rich text (contenteditable) or anywhere in the editor form
//     is not held back: a click there places the caret.
//   - A search hit clicked while held closes the modal search first, so the
//     question is not drawn under it; Stay opens the search again with what
//     was typed.
//   - Stay puts the pane's scroll back, and the caret.
//   - The dialog's Leave marks the desk as leaving (no second `beforeunload`).
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-leave.js
// under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_leave.test.mjs
import assert from "node:assert/strict";
import { JSDOM, VirtualConsole } from "./jsdom.mjs";

// A link that is not held back navigates, which jsdom does not do: quiet.
const virtualConsole = new VirtualConsole();
virtualConsole.on("jsdomError", (err) => {
  if (!/navigation/.test(err.message)) throw err;
});

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/lg;lg-2",
  pretendToBeVisual: true,
  virtualConsole,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk-leave.js");
assert.ok(window.BarkparkDeskLeave, "the script registers itself");

const doc = window.document;
const DESK = "/w/a/p/b/d/production/studio/_desk/";
doc.body.innerHTML =
  `<div id="desk-panes">` +
  `<a id="row" href="${DESK}lg;lg-3" data-phx-link="patch">Doc 3</a>` +
  `<a id="same" href="${DESK}lg;lg-2#x" data-phx-link="patch">here</a>` +
  `<a id="away" href="https://elsewhere.example/x">away</a>` +
  `<a id="dslash" href="http://localhost//x">x</a><a id="dotslash" href="/.//x">x</a>` +
  `<div id="pane" data-pane-editing data-desk-held="Not saved: Title.">` +
  `<div id="body" style="overflow:auto"><form id="editor-form">` +
  `<input id="t" name="doc[title]" value="Doc 2 FAIL">` +
  `<div id="rt" contenteditable="true">Body with <a id="rt-link" href="/docs/x">a local link</a> in it.</div>` +
  `<a id="form-link" href="${DESK}lg;lg-4">a reference</a>` +
  `<textarea id="notes" name="doc[notes]">notes</textarea>` +
  `</form></div></div>` +
  `</div>` +
  `<dialog id="dk-search-dialog"><input id="desk-search-input" value="Doc 4">` +
  `<a id="hit" href="${DESK}lg;lg-4" data-phx-link="patch" data-desk-hit>Doc 4</a></dialog>` +
  `<div id="dk-leave-host"><a id="go" href="/papers" data-desk-leave-go>Leave</a></div>`;

const root = doc.getElementById("desk-panes");
const pushes = [];
root.bpPush = (event, payload) => pushes.push([event, payload]);

// jsdom draws no dialog: open and close by the attribute, as a browser does.
const search = doc.getElementById("dk-search-dialog");
search.showModal = () => search.setAttribute("open", "");
search.close = () => search.removeAttribute("open");

const click = (id, init = {}) => {
  const e = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init });
  doc.getElementById(id).dispatchEvent(e);
  return e;
};
const frame = () => new Promise((r) => window.requestAnimationFrame(() => setTimeout(r, 0)));

// A held field: a row is held back and sent.
let e = click("row");
assert.ok(e.defaultPrevented, "a row click is held back while a field is held");
assert.deepEqual(pushes.pop(), ["desk-leave", { href: `${DESK}lg;lg-3`, kind: "patch" }]);

// Not held back: rich text, the editor form, a modified click, another site, the same page.
for (const [id, init, why] of [
  ["rt-link", {}, "a link in rich text places the caret"],
  ["form-link", {}, "a link in the editor form"],
  ["row", { metaKey: true }, "a modified click"],
  ["away", {}, "another site"],
  ["same", {}, "the same page"],
  // A "//" path is not one the server takes as this site's
  // (LeaveGuard.local?/1): the link goes (task-5455fd7fe69eb386).
  ["dslash", {}, "a same-site path that starts //"],
  ["dotslash", {}, "a path that is // after its dot segments"],
]) {
  e = click(id, init);
  assert.ok(!e.defaultPrevented, `${why}: not held back`);
  assert.equal(pushes.length, 0, `${why}: nothing sent`);
}

// Nothing held: a row goes.
doc.getElementById("pane").removeAttribute("data-desk-held");
e = click("row");
assert.ok(!e.defaultPrevented && pushes.length === 0, "nothing held, nothing held back");
doc.getElementById("pane").setAttribute("data-desk-held", "Not saved: Title.");

// A search hit while held: the search closes before the question opens; Stay
// opens it again with what was typed.
search.showModal();
e = click("hit");
assert.ok(e.defaultPrevented, "the hit is held back");
assert.equal(search.hasAttribute("open"), false, "the modal search is closed before the question");
assert.deepEqual(pushes.pop(), ["desk-leave", { href: `${DESK}lg;lg-4`, kind: "patch" }]);
window.dispatchEvent(new window.Event("phx:bp:desk-leave-stayed"));
await frame();
assert.equal(search.hasAttribute("open"), true, "Stay opens the search again");
assert.equal(doc.getElementById("desk-search-input").value, "Doc 4", "with what was typed");
assert.equal(doc.activeElement.id, "desk-search-input", "its box has the focus");
search.close();

// Stay puts the scroll back (the dialog opening reset it) and the caret.
const body = doc.getElementById("body");
const notes = doc.getElementById("notes");
body.scrollTop = 333;
notes.scrollTop = 120;
notes.focus();
notes.setSelectionRange(3, 4);
notes.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true }));
click("row");
assert.equal(pushes.pop()[0], "desk-leave");
body.scrollTop = 0;
notes.scrollTop = 0;
doc.getElementById("go").focus();
window.dispatchEvent(new window.Event("phx:bp:desk-leave-stayed"));
await frame();
assert.equal(body.scrollTop, 333, "Stay puts the pane's scroll back");
assert.equal(notes.scrollTop, 120, "and the textarea's");
assert.equal(doc.activeElement, notes, "the caret goes back to its field");
assert.deepEqual([notes.selectionStart, notes.selectionEnd], [3, 4], "at its offsets");

// Leave marks the desk as leaving, and is not held back.
e = click("go");
assert.ok(!e.defaultPrevented && pushes.length === 0, "Leave goes");
assert.equal(root.bpLeaving, true, "the desk is leaving: beforeunload does not ask again");

console.log("desk leave: ok");
