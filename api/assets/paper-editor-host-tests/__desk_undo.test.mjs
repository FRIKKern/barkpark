// __desk_undo.test.mjs — task-c25c112913859b11 (F7): the desk document's
// undo and redo keys. Mod+Z in the editor form (or with nothing focused, or
// on the editing pane's header) pushes `desk-undo` named for the document,
// after the typing still in a field's delay is sent; Shift+Mod+Z and Mod+Y
// push a redo. Only in a field the server keeps an undo for (the form's
// `data-desk-undo-keys`), a slug, a url, a number or a nested string typed
// in keeps the browser's own undo; a checkbox, a radio and a widget's own
// box (task-1a516c900a0996cb, task-1fd9b4ae6ec0069c) are the document's.
// Rich text, a dialog, the list pane's search and a key someone already took
// are left alone. The browser's own undo of a field is
// the document's too. The answer is __desk_undo_answer.test.mjs's, and a
// focus moved while it is on its way __desk_undo_focus.test.mjs's.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-undo.js under
// jsdom, on the page __desk_undo_page.mjs draws.
//
// Run: node ../paper-editor-host-tests/__desk_undo.test.mjs
import assert from "node:assert/strict";
import { $, check, doc, done, key, MARK, order, pushes, window } from "./__desk_undo_page.mjs";

await check("Mod+Z in a field pushes the document's undo, named, after the waiting typing", () => {
  const e = key($("title"), { key: "z", metaKey: true });
  assert.equal(e.defaultPrevented, true, "the browser's own undo of the field does not run");
  assert.deepEqual(pushes, [{ event: "desk-undo", payload: { redo: false, _bp_doc: MARK } }]);
  assert.deepEqual(order, ["flush", "push"]);
});

await check("Ctrl+Z works the same", () => {
  key($("excerpt"), { key: "z", ctrlKey: true });
  assert.equal(pushes[0].payload.redo, false);
});

await check("Shift+Mod+Z and Mod+Y redo", () => {
  key($("title"), { key: "Z", metaKey: true, shiftKey: true });
  key($("title"), { key: "y", ctrlKey: true });
  assert.deepEqual(
    pushes.map((p) => p.payload.redo),
    [true, true],
  );
});

await check("with nothing focused, or on the pane's header, it is the document's", () => {
  key(doc.body, { key: "z", metaKey: true });
  key($("kind"), { key: "z", metaKey: true });
  key($("menu"), { key: "z", metaKey: true });
  assert.equal(pushes.length, 3);
});

await check("rich text, a dialog, the list pane's search and a taken key are left alone", () => {
  const rich = key($("rich"), { key: "z", metaKey: true });
  assert.equal(rich.defaultPrevented, false);
  key($("dialog-input"), { key: "z", metaKey: true });
  key($("search"), { key: "z", metaKey: true });
  const taken = new window.KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true });
  taken.preventDefault();
  $("title").dispatchEvent(taken);
  key($("title"), { key: "z", metaKey: true, altKey: true });
  key($("title"), { key: "x", metaKey: true });
  key($("title"), { key: "z" });
  assert.deepEqual(pushes, []);
});

await check("a select, a list item's text and an object's nested text of a kept field are the document's", () => {
  for (const id of ["choice", "card-label", "street"]) {
    const e = key($(id), { key: "z", metaKey: true });
    assert.equal(e.defaultPrevented, true, `Mod+Z in #${id} is the document's`);
  }
  assert.equal(pushes.length, 3);
  // A number nested in a kept object is still the browser's.
  assert.equal(key($("floor"), { key: "z", metaKey: true }).defaultPrevented, false);
  assert.equal(pushes.length, 3);
});

await check("a field with no undo kept (slug, url, number, nested) keeps the browser's own undo", () => {
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

// task-1a516c900a0996cb: a ticked checkbox keeps the focus, and the
// browser has no undo of a tick: Mod+Z there is the document's, as
// TanStack's pane takes it anywhere.
await check("a focused checkbox or radio: Mod+Z is the document's", () => {
  for (const id of ["tag-a", "tag-b", "tone"]) {
    const e = key($(id), { key: "z", metaKey: true });
    assert.equal(e.defaultPrevented, true, `Mod+Z on #${id} is the document's`);
  }
  key($("tag-a"), { key: "z", metaKey: true, shiftKey: true });
  assert.deepEqual(
    pushes.map((p) => p.payload.redo),
    [false, false, false, true],
  );
});

// task-1fd9b4ae6ec0069c: a tree codelist's Remove puts the focus in its own
// search box. That box holds no document text: Mod+Z there is the
// document's, empty or typed in, as TanStack's.
await check("a widget's own box (a tree codelist's search), empty or typed in: Mod+Z is the document's", () => {
  const box = $("topic-search");
  assert.equal(key(box, { key: "z", metaKey: true }).defaultPrevented, true, "empty");
  box.value = "eur";
  try {
    assert.equal(key(box, { key: "z", ctrlKey: true }).defaultPrevented, true, "typed in");
    const h = new window.InputEvent("beforeinput", { inputType: "historyUndo", bubbles: true, cancelable: true });
    box.dispatchEvent(h);
    assert.equal(h.defaultPrevented, true, "the Edit menu's undo there is the document's too");
  } finally {
    box.value = "";
  }
  assert.equal(pushes.length, 3);
});

await check("another box in the pane's header is the document's, as TanStack's", () => {
  assert.equal(key($("pane-input"), { key: "z", metaKey: true }).defaultPrevented, true);
  assert.equal(pushes.length, 1);
});

await check("an image's part typed in, its undo not kept, keeps the browser's own undo", () => {
  assert.equal(key($("cover-alt"), { key: "z", metaKey: true }).defaultPrevented, false);
  assert.deepEqual(pushes, []);
});

await check("a disabled checkbox or a read-only search box (a locked view) is the browser's", () => {
  $("tag-a").disabled = true;
  $("topic-search").readOnly = true;
  try {
    assert.equal(key($("tag-a"), { key: "z", metaKey: true }).defaultPrevented, false);
    assert.equal(key($("topic-search"), { key: "z", metaKey: true }).defaultPrevented, false);
    assert.deepEqual(pushes, []);
  } finally {
    $("tag-a").disabled = false;
    $("topic-search").readOnly = false;
  }
});

await check("a kept field that is read-only now is the browser's", () => {
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

await check("a button in the form is not a field: the key is the document's", () => {
  const e = key($("add"), { key: "z", metaKey: true });
  assert.equal(e.defaultPrevented, true);
  assert.equal(pushes.length, 1);
});

await check("the editing pane folded to a strip: Mod+Z is the browser's, on BODY, the pane and a field", () => {
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

await check("the editor form hidden (focus mode, the narrow layout: display none): Mod+Z on BODY is the browser's", () => {
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

await check("no editor form on the desk: nothing is pushed", () => {
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

await check("the browser's own undo of a field (Edit menu) is the document's", () => {
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

done("desk undo keys");
