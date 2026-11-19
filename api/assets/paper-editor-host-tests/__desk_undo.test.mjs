// __desk_undo.test.mjs — task-c25c112913859b11 (F7): the desk document's
// undo and redo keys. Mod+Z in the editor form (or with nothing focused, or
// on the editing pane's header) pushes `desk-undo` named for the document,
// after the typing still in a field's delay is sent; Shift+Mod+Z and Mod+Y
// push a redo. Only in a field the server keeps an undo for (the form's
// `data-desk-undo-keys`): a slug, a url, a number or a nested string keeps
// the browser's own undo. Rich text, a dialog, another input and a key
// someone already took are left alone. The browser's own undo of a field is the document's
// too. `desk:undone` sets the field that still shows the old value, puts the
// caret at the end of what changed, and the focus in the field.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-undo.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_undo.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;

const doc = window.document;
const MARK = '["production","post","post-14"]';
doc.body.innerHTML =
  `<div id="desk-panes">` +
  `<section id="list" data-pane-kind="list"><input id="search" type="search"></section>` +
  `<section id="pane" data-pane-editing><header><span class="kind" id="kind">Post</span>` +
  `<button id="menu" type="button">…</button><input id="pane-input" type="text"></header>` +
  `<form id="editor-form" data-desk-undo-keys="doc[title] doc[excerpt]" phx-value-_bp_doc='${MARK}'>` +
  `<input type="text" id="title" name="doc[title]" value="Fixture post 14">` +
  `<textarea id="excerpt" name="doc[excerpt]">Short.</textarea>` +
  `<input type="text" id="slug" name="doc[slug]" value="fixture-post-14">` +
  `<input type="url" id="site" name="doc[site]">` +
  `<input type="number" id="count" name="doc[count]">` +
  `<input type="text" id="alt" name="doc[image][alt]">` +
  `<button type="button" id="add">Add</button>` +
  `<div contenteditable="true" id="rich">Body</div>` +
  `</form></section>` +
  `<dialog id="dialog" open><input id="dialog-input" type="text"></dialog></div>`;

const pushes = [];
const order = [];
doc.getElementById("desk-panes").bpPush = (event, payload) => {
  order.push("push");
  pushes.push({ event, payload });
};
window.BarkparkFormLeave = () => order.push("flush");
window.BarkparkDocMark = () => doc.getElementById("editor-form").getAttribute("phx-value-_bp_doc");

await import("../../priv/static/assets/bp-desk-undo.js");
assert.ok(window.BarkparkDeskUndo, "bp-desk-undo.js did not load");

const $ = (id) => doc.getElementById(id);
const key = (target, init) => {
  const e = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(e);
  return e;
};
const reset = () => {
  pushes.length = 0;
  order.length = 0;
};

let failures = 0;
function check(name, fn) {
  reset();
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

check("Mod+Z in a field pushes the document's undo, named, after the waiting typing", () => {
  const e = key($("title"), { key: "z", metaKey: true });
  assert.equal(e.defaultPrevented, true, "the browser's own undo of the field does not run");
  assert.deepEqual(pushes, [{ event: "desk-undo", payload: { redo: false, _bp_doc: MARK } }]);
  assert.deepEqual(order, ["flush", "push"]);
});

check("Ctrl+Z works the same", () => {
  key($("excerpt"), { key: "z", ctrlKey: true });
  assert.equal(pushes[0].payload.redo, false);
});

check("Shift+Mod+Z and Mod+Y redo", () => {
  key($("title"), { key: "Z", metaKey: true, shiftKey: true });
  key($("title"), { key: "y", ctrlKey: true });
  assert.deepEqual(
    pushes.map((p) => p.payload.redo),
    [true, true],
  );
});

check("with nothing focused, or on the pane's header, it is the document's", () => {
  key(doc.body, { key: "z", metaKey: true });
  key($("kind"), { key: "z", metaKey: true });
  key($("menu"), { key: "z", metaKey: true });
  assert.equal(pushes.length, 3);
});

check("rich text, a dialog, another input and a taken key are left alone", () => {
  const rich = key($("rich"), { key: "z", metaKey: true });
  assert.equal(rich.defaultPrevented, false);
  key($("dialog-input"), { key: "z", metaKey: true });
  key($("search"), { key: "z", metaKey: true });
  key($("pane-input"), { key: "z", metaKey: true });
  const taken = new window.KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true });
  taken.preventDefault();
  $("title").dispatchEvent(taken);
  key($("title"), { key: "z", metaKey: true, altKey: true });
  key($("title"), { key: "x", metaKey: true });
  key($("title"), { key: "z" });
  assert.deepEqual(pushes, []);
});

check("a field with no undo kept (slug, url, number, nested) keeps the browser's own undo", () => {
  for (const id of ["slug", "site", "count", "alt"]) {
    const e = key($(id), { key: "z", metaKey: true });
    assert.equal(e.defaultPrevented, false, `Mod+Z in #${id} is the browser's`);
    const r = key($(id), { key: "z", metaKey: true, shiftKey: true });
    assert.equal(r.defaultPrevented, false, `Shift+Mod+Z in #${id} is the browser's`);
    const h = new window.InputEvent("beforeinput", { inputType: "historyUndo", bubbles: true, cancelable: true });
    $(id).dispatchEvent(h);
    assert.equal(h.defaultPrevented, false, `historyUndo in #${id} is the browser's`);
  }
  assert.deepEqual(pushes, []);
});

check("a button in the form is not a field: the key is the document's", () => {
  const e = key($("add"), { key: "z", metaKey: true });
  assert.equal(e.defaultPrevented, true);
  assert.equal(pushes.length, 1);
});

check("no editor form on the desk: nothing is pushed", () => {
  const form = $("editor-form");
  const parent = form.parentNode;
  parent.removeChild(form);
  try {
    key(doc.body, { key: "z", metaKey: true });
    assert.deepEqual(pushes, []);
  } finally {
    parent.appendChild(form);
  }
});

check("the browser's own undo of a field (Edit menu) is the document's", () => {
  const e = new window.InputEvent("beforeinput", { inputType: "historyUndo", bubbles: true, cancelable: true });
  $("title").dispatchEvent(e);
  assert.equal(e.defaultPrevented, true);
  const r = new window.InputEvent("beforeinput", { inputType: "historyRedo", bubbles: true, cancelable: true });
  $("title").dispatchEvent(r);
  const typed = new window.InputEvent("beforeinput", { inputType: "insertText", bubbles: true, cancelable: true });
  $("title").dispatchEvent(typed);
  assert.equal(typed.defaultPrevented, false);
  assert.deepEqual(
    pushes.map((p) => p.payload.redo),
    [false, true],
  );
});

const undone = (detail) => window.dispatchEvent(new window.CustomEvent("phx:desk:undone", { detail }));

check("desk:undone sets the focused field that shows the old value; the caret goes to the change", () => {
  const title = $("title");
  title.value = "bbb Fixture post 14 A aaa";
  title.focus();
  undone({ field: "doc[title]", value: "bbb Fixture post 14 A", was: "bbb Fixture post 14 A aaa" });
  assert.equal(title.value, "bbb Fixture post 14 A");
  assert.equal(doc.activeElement, title);
  assert.equal(title.selectionStart, "bbb Fixture post 14 A".length);
});

check("an undo in another field moves the focus there, as TanStack's", () => {
  const excerpt = $("excerpt");
  excerpt.value = "Short. B";
  doc.body.focus();
  undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
  assert.equal(excerpt.value, "Short.");
  assert.equal(doc.activeElement, excerpt);
});

check("a field showing other text keeps it, and still takes the focus", () => {
  const title = $("title");
  title.value = "typed on";
  $("excerpt").focus();
  undone({ field: "doc[title]", value: "Fixture post 14", was: "Fixture post 14 A" });
  assert.equal(title.value, "typed on");
  assert.equal(doc.activeElement, title);
});

check("a field the form does not have is ignored", () => {
  undone({ field: "doc[nope]", value: "x", was: "y" });
  undone({});
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\ndesk undo: ok");
