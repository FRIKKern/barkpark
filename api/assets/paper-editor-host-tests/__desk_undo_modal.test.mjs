// __desk_undo_modal.test.mjs — task-c291650f9285acb5: Mod+Z with a modal
// open (Delete, Unpublish) changes no field behind it. The browser's own
// undo is the page's, not the focused field's: from the modal's button it
// took back the title behind the modal, and the autosave wrote it. The key
// is no one's then but a modal field's, and the browser's undo of a field
// behind the modal (the Edit menu's too) is refused. Nothing is pushed.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-undo.js under
// jsdom, with the browser's undo played by the page (jsdom has none).
//
// Run: node ../paper-editor-host-tests/__desk_undo_modal.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;

const doc = window.document;
doc.body.innerHTML =
  `<div id="desk-panes"><section id="pane" data-pane-index="1" data-pane-editing>` +
  `<form id="editor-form" data-desk-undo-keys="doc[title]">` +
  `<input type="text" id="title" name="doc[title]" value="Fixture post 14 X"></form></section></div>` +
  `<div id="delete" role="dialog" aria-modal="true" hidden>` +
  `<input type="text" id="confirm" value="post-14 typed"><button type="button" id="cancel">Cancel</button></div>`;

const $ = (id) => doc.getElementById(id);
const pushes = [];
$("desk-panes").bpPush = (event, payload) => pushes.push({ event, payload });

// The form's autosave: every input event in it is a write.
const autosaves = [];
$("editor-form").addEventListener("input", (e) => autosaves.push(e.target.id));

// The browser's undo, after the page's listeners: it takes back the last
// typing in the page (`last`, the title's, else the field the key is in), as
// Chrome's does, unless the key or its beforeinput was refused.
const undoes = { title: "Fixture post 14", confirm: "post-14" };
let last = "title";
window.addEventListener("keydown", (e) => {
  if (e.defaultPrevented || !(e.metaKey || e.ctrlKey) || String(e.key).toLowerCase() !== "z") return;
  browserUndo($(last));
});
function browserUndo(field) {
  const before = new window.InputEvent("beforeinput", { inputType: "historyUndo", bubbles: true, cancelable: true });
  if (!field.dispatchEvent(before)) return;
  field.value = undoes[field.id];
  field.dispatchEvent(new window.InputEvent("input", { inputType: "historyUndo", bubbles: true }));
}

await import("../../priv/static/assets/bp-desk-undo.js");
assert.ok(window.BarkparkDeskUndo, "bp-desk-undo.js did not load");

const key = (target) => {
  const e = new window.KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true });
  target.dispatchEvent(e);
  return e;
};

let failures = 0;
function check(name, fn) {
  pushes.length = 0;
  autosaves.length = 0;
  last = "title";
  $("title").value = "Fixture post 14 X";
  $("confirm").value = "post-14 typed";
  $("delete").hidden = false;
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  } finally {
    $("delete").hidden = true;
  }
}

check("Mod+Z on the modal's button changes no field behind it, and no autosave is sent", () => {
  $("cancel").focus();
  const e = key($("cancel"));
  assert.equal(e.defaultPrevented, true, "the browser's own undo does not run");
  assert.equal($("title").value, "Fixture post 14 X");
  assert.deepEqual(autosaves, []);
  assert.deepEqual(pushes, [], "nor the document's");
});

check("Mod+Z with nothing focused, or in the field behind the modal: the same", () => {
  for (const target of [doc.body, $("title")]) {
    assert.equal(key(target).defaultPrevented, true, `from ${target.id || target.tagName}`);
  }
  assert.equal($("title").value, "Fixture post 14 X");
  assert.deepEqual(autosaves, []);
  assert.deepEqual(pushes, []);
});

check("the browser's undo of the field behind the modal (the Edit menu) is refused", () => {
  browserUndo($("title"));
  assert.equal($("title").value, "Fixture post 14 X");
  assert.deepEqual(autosaves, []);
  assert.deepEqual(pushes, []);
});

check("a field in the modal keeps the browser's own undo of its typing", () => {
  last = "confirm";
  $("confirm").focus();
  assert.equal(key($("confirm")).defaultPrevented, false);
  assert.equal($("confirm").value, "post-14");
  assert.equal($("title").value, "Fixture post 14 X");
  assert.deepEqual(pushes, []);
});

check("from a field in the modal, the browser's undo of the field behind it is still refused", () => {
  $("confirm").focus();
  assert.equal(key($("confirm")).defaultPrevented, false);
  assert.equal($("title").value, "Fixture post 14 X");
  assert.deepEqual(autosaves, []);
});

check("the modal closed, Mod+Z is the document's again", () => {
  $("delete").hidden = true;
  $("title").focus();
  assert.equal(key($("title")).defaultPrevented, true);
  assert.equal(pushes.length, 1);
  assert.equal($("title").value, "Fixture post 14 X", "the server's undo, not the browser's");
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\ndesk undo under a modal: ok");
