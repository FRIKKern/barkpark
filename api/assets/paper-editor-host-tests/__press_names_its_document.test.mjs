// __press_names_its_document.test.mjs — task-8908b6e031268f77: a press that
// writes the open document without posting the editor form (a list's Add,
// Remove and Move, Generate on a slug, a tree codelist's pick and Remove, a
// field's Revert) names the document it was pressed in. The page puts the editor
// form's own mark on the pressed control, read at the press, before
// LiveView's listener reads the control's `phx-value-`s.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom. A bubble-phase listener on window stands in for LiveView's.
//
// Run: node ../paper-editor-host-tests/__press_names_its_document.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "CustomEvent", "MouseEvent", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-array-focus.js");

const MARK = "phx-value-_bp_doc";
const A = '["production","post","o\'dd \\"id\\" <b> & é"]';
const B = '["production","post","b"]';
const esc = (value) => value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");

function mount(doc) {
  const form = doc === null ? "" : `<form id="editor-form" ${MARK}="${esc(doc)}">` +
    `<button id="add" type="button" phx-click="array_op" phx-value-action="add_row"><span id="plus">+</span> Add</button>` +
    `<button id="slug" type="button" phx-click="slug-generate" phx-value-field="slug">Generate</button>` +
    `<button id="js" type="button" phx-click='[["push",{"event":"tree_node_clear","target":3}]]'>Remove</button>` +
    `<button id="other" type="button" phx-click="toggle-diff">Diff</button>` +
    `</form>`;
  document.body.innerHTML = form +
    `<div id="pick" phx-click="tree_node_select" phx-value-code="p2" phx-target="3">Kari</div>` +
    `<button id="revert" type="button" phx-click="desk-field-revert" phx-value-field="cover">Revert</button>` +
    // No write is a form's submit today; the page names one all the same.
    `<form id="write-form" phx-submit="slug-generate" phx-value-field="slug"></form>` +
    `<form id="search" phx-submit="desk-search"></form>` +
    `<button id="publish" type="button" phx-click="publish">Publish</button>`;
}

// What LiveView would send: the control's mark as its own listener sees it.
function seen(type, el, binding) {
  let value;
  const read = (e) => {
    const from = e.target.closest(`[${binding}]`);
    value = from ? from.getAttribute(MARK) : undefined;
  };
  window.addEventListener(type, read, { once: true });
  const Kind = type === "click" ? window.MouseEvent : window.Event;
  el.dispatchEvent(new Kind(type, { bubbles: true, cancelable: true }));
  return value;
}
const press = (id) => seen("click", document.getElementById(id), "phx-click");
const submit = (id) => seen("submit", document.getElementById(id), "phx-submit");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

check("each press that writes the document carries the form's mark, whatever the id holds", () => {
  mount(A);
  for (const id of ["add", "plus", "slug", "js", "pick", "revert"]) assert.equal(press(id), A, id);
  assert.equal(submit("write-form"), A);
});

check("the mark is the form's at the press: the same control pressed in the next document carries that one", () => {
  mount(A);
  assert.equal(press("pick"), A);
  document.getElementById("editor-form").setAttribute(MARK, B);
  assert.equal(press("pick"), B);
  assert.equal(press("add"), B);
});

check("with no editor form on the page a press carries an empty mark: never the last one, never none", () => {
  mount(A);
  assert.equal(press("pick"), A);
  document.getElementById("editor-form").remove();
  assert.equal(press("pick"), "");
  assert.equal(submit("write-form"), "");
});

check("a control drawn after the page loaded, in the form or in a component outside it, is named too", () => {
  mount(A);
  const form = document.getElementById("editor-form");
  form.insertAdjacentHTML("beforeend", `<ol><li><button id="late" type="button" phx-click="array_op" phx-target="3" phx-value-action="remove_row">x</button></li></ol>`);
  document.body.insertAdjacentHTML("beforeend", `<div data-phx-component="7"><div id="late-pick" phx-click="tree_node_select" phx-target="7"><img id="late-img"></div></div>`);
  assert.equal(press("late"), A);
  assert.equal(press("late-img"), A);
});

check("a press or a submit that is not one of these is left as it is", () => {
  mount(A);
  assert.equal(press("other"), null);
  assert.equal(submit("search"), null);
});

// task-176bd529276ff8b3: the document's actions. Their controls are outside
// the form: the header, a menu in the top layer, a dialog.
const ACTIONS = ["publish", "unpublish", "confirm-unpublish", "delete-doc", "confirm-delete", "discard-draft",
  "confirm-discard", "duplicate-doc", "restore-revision", "paper-publish"];

function actions() {
  document.body.insertAdjacentHTML("beforeend",
    ACTIONS.map((name) => `<button id="act-${name}" type="button" phx-click="${name}"><svg id="glyph-${name}"></svg></button>`).join("") +
    `<div popover id="menu"><button id="menu-publish" type="button" phx-click='[["push",{"event":"publish"}],["focus",{"to":"#x"}]]'>Publish</button></div>` +
    `<div role="dialog"><button id="dialog-delete" type="button" phx-click="confirm-delete" phx-value-disconnect="true">Delete</button></div>`);
}

check("each document action carries the form's mark: by name, as JS commands, in a menu, in a dialog", () => {
  mount(A);
  actions();
  for (const name of ACTIONS) assert.equal(press(`glyph-${name}`), A, name);
  assert.equal(press("menu-publish"), A);
  assert.equal(press("dialog-delete"), A);
  assert.equal(window.BarkparkDocMark(), A);
});

check("a page with no editor form (a sheet, a paper) names its document on #bp-doc; the form's wins", () => {
  mount(null);
  actions();
  assert.equal(press("act-publish"), "");
  document.body.insertAdjacentHTML("beforeend", `<span id="bp-doc" hidden data-bp-doc="${esc(B)}"></span>`);
  assert.equal(press("act-publish"), B);
  assert.equal(press("dialog-delete"), B);
  assert.equal(window.BarkparkDocMark(), B);
  document.body.insertAdjacentHTML("afterbegin", `<form id="editor-form" ${MARK}="${esc(A)}"></form>`);
  assert.equal(press("act-publish"), A);
});

window.close();
if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\npress names its document: all checks passed");
