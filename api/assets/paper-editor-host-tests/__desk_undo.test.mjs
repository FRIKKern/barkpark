// __desk_undo.test.mjs — task-c25c112913859b11 (F7): the desk document's
// undo and redo keys. Mod+Z in the editor form (or with nothing focused, or
// on the editing pane's header) pushes `desk-undo` named for the document,
// after the typing still in a field's delay is sent; Shift+Mod+Z and Mod+Y
// push a redo. Only in a field the server keeps an undo for (the form's
// `data-desk-undo-keys`): a slug, a url, a number or a nested string keeps
// the browser's own undo. Rich text, a dialog, another input and a key
// someone already took are left alone. The browser's own undo of a field is the document's
// too. `desk:undone` sets the field that still shows the old value, opens
// the folds around it, puts the caret at the end of what changed, and the
// focus in the field.
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
  `<section id="pane" data-pane-index="1" data-pane-editing><header><span class="kind" id="kind">Post</span>` +
  `<button id="menu" type="button">…</button><input id="pane-input" type="text"></header>` +
  `<form id="editor-form" data-desk-undo-keys="doc[title] doc[excerpt]" phx-value-_bp_doc='${MARK}'>` +
  `<input type="text" id="title" name="doc[title]" value="Fixture post 14">` +
  `<textarea id="excerpt" name="doc[excerpt]">Short.</textarea>` +
  `<input type="text" id="slug" name="doc[slug]" value="fixture-post-14">` +
  `<input type="url" id="site" name="doc[site]">` +
  `<input type="number" id="count" name="doc[count]">` +
  `<input type="text" id="alt" name="doc[image][alt]">` +
  `<button type="button" id="add">Add</button>` +
  `<fieldset id="set" data-collapsible><legend><button type="button" class="object-toggle" id="set-toggle" aria-expanded="false">More</button></legend>` +
  `<textarea id="folded" name="doc[folded]">Folded.</textarea></fieldset>` +
  `<fieldset id="obj" data-collapsible><legend><button type="button" class="object-toggle" id="obj-toggle" aria-expanded="false">Obj</button></legend>` +
  `<div><fieldset id="inner" data-collapsible><legend><button type="button" class="object-toggle" id="inner-toggle" aria-expanded="false">Inner</button></legend>` +
  `<details id="det"><summary>More</summary><textarea id="deep" name="doc[deep]">Deep.</textarea></details></fieldset></div></fieldset>` +
  `<div contenteditable="true" id="rich">Body</div>` +
  `</form></section>` +
  `<dialog id="dialog" open><input id="dialog-input" type="text"></dialog></div>`;

// LiveView runs a fold button's own command on its click
// (`JS.toggle_attribute({"aria-expanded", "true", "false"})`, Desk.Fieldsets).
const toggled = [];
doc.addEventListener("click", (e) => {
  const b = e.target.closest && e.target.closest(".object-toggle");
  if (!b) return;
  toggled.push(b.id);
  b.setAttribute("aria-expanded", b.getAttribute("aria-expanded") === "true" ? "false" : "true");
});

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

check("a kept field that is read-only now is the browser's", () => {
  const title = $("title");
  title.readOnly = true;
  try {
    const e = key(title, { key: "z", metaKey: true });
    assert.equal(e.defaultPrevented, false);
    assert.deepEqual(pushes, []);
  } finally {
    title.readOnly = false;
  }
});

check("a button in the form is not a field: the key is the document's", () => {
  const e = key($("add"), { key: "z", metaKey: true });
  assert.equal(e.defaultPrevented, true);
  assert.equal(pushes.length, 1);
});

check("the editing pane folded to a strip: Mod+Z is the browser's, on BODY, the pane and a field", () => {
  const pane = $("pane");
  pane.setAttribute("data-pane-collapsed", "");
  try {
    for (const target of [doc.body, pane, $("kind"), $("title")]) {
      const e = key(target, { key: "z", metaKey: true });
      assert.equal(e.defaultPrevented, false, `Mod+Z on ${target.id || target.tagName} is the browser's`);
    }
    const h = new window.InputEvent("beforeinput", { inputType: "historyUndo", bubbles: true, cancelable: true });
    $("title").dispatchEvent(h);
    assert.equal(h.defaultPrevented, false);
    assert.deepEqual(pushes, []);
  } finally {
    pane.removeAttribute("data-pane-collapsed");
  }
});

check("the editor form hidden (focus mode, the narrow layout: display none): Mod+Z on BODY is the browser's", () => {
  const proto = window.HTMLElement.prototype;
  proto.checkVisibility = function () {
    return !$("pane").contains(this);
  };
  try {
    const e = key(doc.body, { key: "z", metaKey: true });
    assert.equal(e.defaultPrevented, false);
    assert.deepEqual(pushes, []);
  } finally {
    delete proto.checkVisibility;
  }
  key(doc.body, { key: "z", metaKey: true });
  assert.equal(pushes.length, 1, "drawn again, the key is the document's");
});

check("a modal open anywhere in the page (Delete, Unpublish): Mod+Z is the browser's", () => {
  const m = doc.createElement("div");
  m.setAttribute("role", "dialog");
  m.setAttribute("aria-modal", "true");
  doc.body.appendChild(m);
  try {
    for (const target of [doc.body, $("title"), $("kind")]) {
      const e = key(target, { key: "z", metaKey: true });
      assert.equal(e.defaultPrevented, false, `Mod+Z on ${target.id || target.tagName} under a modal`);
    }
    const h = new window.InputEvent("beforeinput", { inputType: "historyUndo", bubbles: true, cancelable: true });
    $("title").dispatchEvent(h);
    assert.equal(h.defaultPrevented, false);
    assert.deepEqual(pushes, []);
    m.hidden = true;
    key(doc.body, { key: "z", metaKey: true });
    assert.equal(pushes.length, 1, "a hidden modal is not open");
  } finally {
    m.remove();
  }
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

check("a field drawn with the new value already (its tab was switched to) takes the focus and the caret", () => {
  const excerpt = $("excerpt");
  excerpt.value = "Short.";
  $("title").focus();
  undone({ field: "doc[excerpt]", value: "Short.", was: "Short. E1" });
  assert.equal(excerpt.value, "Short.");
  assert.equal(doc.activeElement, excerpt);
  assert.equal(excerpt.selectionStart, "Short.".length);
});

check("a field in a fieldset folded since (by the user) is opened by its own button, then focused", () => {
  const folded = $("folded");
  folded.value = "Folded. X2";
  $("set-toggle").setAttribute("aria-expanded", "false");
  $("set-toggle").focus();
  toggled.length = 0;
  undone({ field: "doc[folded]", value: "Folded.", was: "Folded. X2" });
  assert.equal(folded.value, "Folded.");
  assert.equal($("set-toggle").getAttribute("aria-expanded"), "true");
  assert.deepEqual(toggled, ["set-toggle"]);
  assert.equal(doc.activeElement, folded);
});

check("a field drawn in a fieldset that starts folded (its tab was switched to) is opened too", () => {
  $("set-toggle").setAttribute("aria-expanded", "false");
  $("folded").value = "Folded.";
  $("add").focus();
  undone({ field: "doc[folded]", value: "Folded.", was: "Folded. X1" });
  assert.equal($("set-toggle").getAttribute("aria-expanded"), "true");
  assert.equal(doc.activeElement, $("folded"));
});

check("nested folds (a fieldset in a folded object, a closed details) all open, outermost first", () => {
  toggled.length = 0;
  $("deep").value = "Deep. X";
  undone({ field: "doc[deep]", value: "Deep.", was: "Deep. X" });
  assert.deepEqual(toggled, ["obj-toggle", "inner-toggle"]);
  assert.equal($("obj-toggle").getAttribute("aria-expanded"), "true");
  assert.equal($("inner-toggle").getAttribute("aria-expanded"), "true");
  assert.equal($("det").open, true);
  assert.equal(doc.activeElement, $("deep"));
});

check("the pane folded to a strip while the undo was on its way is opened as a click on it does, then focused", () => {
  const pane = $("pane");
  const root = $("desk-panes");
  // bp-desk.js `_openStrip`: a click on a strip opens its pane.
  const open = (e) => {
    const strip = e.target.closest("[data-pane-collapsed]");
    if (strip) strip.removeAttribute("data-pane-collapsed");
  };
  root.addEventListener("click", open, true);
  pane.setAttribute("data-pane-collapsed", "");
  try {
    $("excerpt").value = "Short. B";
    doc.body.focus();
    undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
    assert.equal(pane.hasAttribute("data-pane-collapsed"), false);
    assert.equal($("excerpt").value, "Short.");
    assert.equal(doc.activeElement, $("excerpt"));
  } finally {
    root.removeEventListener("click", open, true);
    pane.removeAttribute("data-pane-collapsed");
  }
});

check("an open fold is left as it is", () => {
  $("set-toggle").setAttribute("aria-expanded", "true");
  toggled.length = 0;
  undone({ field: "doc[folded]", value: "Folded.", was: "Folded." });
  assert.deepEqual(toggled, []);
  assert.equal($("set-toggle").getAttribute("aria-expanded"), "true");
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
