// task-92e2615cf6ec27e6: after a "+" create, focus stayed on the "+". The
// server now pushes `bp:focus-new-doc`; this listener (inline in
// root.html.heex) waits for that id's editor and focuses its first field.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
const start = root.indexOf("window.bpFocusNewDoc = function");
assert.ok(start > 0, "root.html.heex defines window.bpFocusNewDoc");
const end = root.indexOf("    let Hooks = {};", start);
const source = root.slice(start, end);

const dom = new JSDOM(
  `<main><button id="plus">+</button><input id="search" type="search"><div id="editor"></div></main>`,
  { runScripts: "outside-only" },
);
const { window } = dom;
const { document } = window;
window.eval(source);
const tick = (ms) => new Promise((r) => setTimeout(r, ms));
const push = (id) =>
  window.dispatchEvent(new window.CustomEvent("phx:bp:focus-new-doc", { detail: { id } }));
const editor = document.getElementById("editor");

// Classic: the form renders AFTER the push (the patch follows it). Hidden,
// read-only and other documents' fields are skipped.
document.getElementById("plus").focus();
push("quiz-1");
await tick(120);
editor.innerHTML =
  '<form><input type="hidden" id="doc-field-quiz-1-_id">' +
  '<input id="doc-field-other-title">' +
  '<input id="doc-field-quiz-1-slug" readonly>' +
  '<input id="doc-field-quiz-1-title"><textarea id="doc-field-quiz-1-prompt"></textarea></form>';
await tick(120);
assert.equal(document.activeElement.id, "doc-field-quiz-1-title", "focus lands on the first editable field");

// Paper: the canvas puts the caret in the title block through focusBlock. A
// bare focus() would leave ProseMirror's caret in the body block. The canvas
// answers false until its editor is ready; the listener keeps trying.
document.getElementById("plus").focus();
push("paper-1");
editor.innerHTML =
  '<div id="paper-editor-drafts.paper-1"><bp-paper-canvas><div class="ProseMirror" contenteditable="true">' +
  '<h1 data-bp-role="title" data-bp-id="tpl-title"></h1><p data-bp-type="paragraph"></p></div></bp-paper-canvas></div>';
const canvas = editor.querySelector("bp-paper-canvas");
const asked = [];
let ready = false;
canvas.focusBlock = (id) => {
  asked.push(id);
  if (!ready) return false;
  canvas.querySelector(".ProseMirror").focus();
  return true;
};
await tick(120);
assert.ok(asked.length > 0 && asked.every((id) => id === "tpl-title"), "it asks the canvas for the title block");
ready = true;
await tick(120);
assert.ok(document.activeElement.classList.contains("ProseMirror"), "the caret lands once the canvas is ready");
const asks = asked.length;

// The canvas re-mounted its editor after the first placement and restored
// focus with its own caret: the caret is put back in the title.
let placedAgain = asks;
canvas.focusBlock = () => {
  placedAgain++;
  return true;
};
await tick(250);
assert.ok(placedAgain > asks, "the caret is re-placed while the editor settles");
await tick(1100);
const settled = placedAgain;
await tick(250);
assert.equal(placedAgain, settled, "it stops after the settle window");

// A user who presses a key before the editor renders keeps their place.
editor.innerHTML = "";
const search = document.getElementById("search");
search.focus();
push("quiz-2");
search.dispatchEvent(new window.KeyboardEvent("keydown", { key: "a", bubbles: true }));
editor.innerHTML = '<form><input id="doc-field-quiz-2-title"></form>';
await tick(250);
assert.equal(document.activeElement.id, "search", "a typing user is left alone");

console.log("ok new doc focus: waits for the editor, first editable field, paper title, respects a typing user");
window.close();
