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
  `<form id="editor-form" data-desk-undo-keys="doc[title] doc[excerpt] doc[choice] doc[cards] doc[address]" phx-value-_bp_doc='${MARK}'>` +
  `<input type="text" id="title" name="doc[title]" value="Fixture post 14">` +
  `<textarea id="excerpt" name="doc[excerpt]">Short.</textarea>` +
  `<input type="text" id="slug" name="doc[slug]" value="fixture-post-14">` +
  `<input type="url" id="site" name="doc[site]">` +
  `<input type="number" id="count" name="doc[count]">` +
  `<input type="text" id="alt" name="doc[image][alt]">` +
  `<select id="choice" name="doc[choice]"><option value="a">Alpha</option><option value="b">Beta</option><option value="c" selected>Gamma</option></select>` +
  `<div id="cards"><input type="text" id="card-label" name="doc[cards][0][label]" value="Two"></div>` +
  `<input type="text" id="street" name="doc[address][street]" value="Main 12">` +
  `<input type="number" id="floor" name="doc[address][floor]">` +
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

check("a select, a list item's text and an object's nested text of a kept field are the document's", () => {
  for (const id of ["choice", "card-label", "street"]) {
    const e = key($(id), { key: "z", metaKey: true });
    assert.equal(e.defaultPrevented, true, `Mod+Z in #${id} is the document's`);
  }
  assert.equal(pushes.length, 3);
  // A number nested in a kept object is still the browser's.
  assert.equal(key($("floor"), { key: "z", metaKey: true }).defaultPrevented, false);
  assert.equal(pushes.length, 3);
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

check("a pane drawn a strip wide whose mark the patch dropped is marked again, then opened as a click does", () => {
  const pane = $("pane");
  const root = $("desk-panes");
  const opened = [];
  // bp-desk.js `_openStrip`: only a pane marked a strip opens.
  const open = (e) => {
    const strip = e.target.closest("[data-pane-collapsed]");
    if (strip) {
      opened.push(strip.id);
      strip.removeAttribute("data-pane-collapsed");
    }
  };
  root.addEventListener("click", open, true);
  pane.getBoundingClientRect = () => ({ width: 52, height: 600, top: 0, left: 0, right: 52, bottom: 600 });
  try {
    $("excerpt").value = "Short. B";
    doc.body.focus();
    undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
    assert.deepEqual(opened, ["pane"]);
    assert.equal(pane.hasAttribute("data-pane-collapsed"), false);
    assert.equal(doc.activeElement, $("excerpt"));
  } finally {
    root.removeEventListener("click", open, true);
    delete pane.getBoundingClientRect;
  }
});

check("an open fold is left as it is", () => {
  $("set-toggle").setAttribute("aria-expanded", "true");
  toggled.length = 0;
  undone({ field: "doc[folded]", value: "Folded.", was: "Folded." });
  assert.deepEqual(toggled, []);
  assert.equal($("set-toggle").getAttribute("aria-expanded"), "true");
});

check("an undone select is set when it still shows the old option, and focused", () => {
  $("choice").value = "c";
  doc.body.focus();
  undone({ field: "doc[choice]", value: "b", was: "c" });
  assert.equal($("choice").value, "b");
  assert.equal(doc.activeElement, $("choice"));
  $("choice").value = "c";
});

check("an undone list (no input of its own) brings its first input into sight and focus", () => {
  doc.body.focus();
  undone({ field: "doc[cards]", value: null, was: null });
  assert.equal(doc.activeElement, $("card-label"));
  assert.equal($("card-label").value, "Two", "the server's render draws the list");
});

// A piece of form drawn for one check, taken away after it.
const drawIn = (html) => {
  const box = doc.createElement("div");
  box.innerHTML = html;
  $("editor-form").appendChild(box);
  return box;
};

// bp-desk-array-menu.js opens an item's dialog on a click on its preview.
doc.addEventListener("click", (e) => {
  const p = e.target.closest && e.target.closest("[data-desk-item-open]");
  if (p) doc.getElementById(p.getAttribute("data-desk-item-open")).setAttribute("open", "");
});

check("a list the undo emptied in a folded fieldset: its wrapper is found by path, unfolded and focused", () => {
  const box = drawIn(
    `<fieldset id="more" data-collapsible><legend><button type="button" class="object-toggle" id="more-toggle" aria-expanded="false">More</button></legend>` +
      `<fieldset class="bp-field" data-field-name="bits"><legend>Bits</legend><button type="button" id="bits-add">Add item</button></fieldset></fieldset>`
  );
  try {
    doc.body.focus();
    undone({ field: "doc[bits]", value: null, was: null, path: "bits" });
    assert.deepEqual(toggled, ["more-toggle"], "the fold is opened by its own button");
    assert.equal(doc.activeElement, $("bits-add"));
  } finally {
    box.remove();
  }
});

check("a field in a list item's closed dialog: the dialog opens as a click on the item does, then the field is set and focused", () => {
  const box = drawIn(
    `<ul><li><button type="button" id="prev1" data-desk-item-open="item-1-dialog">One</button>` +
      `<dialog id="item-1-dialog" data-desk-item-dialog><input type="text" id="note" name="doc[cards][0].note" value="N1 X1"></dialog></li></ul>`
  );
  try {
    $("prev1").focus();
    undone({ field: "doc[cards][0].note", value: "N1", was: "N1 X1", path: "cards" });
    assert.equal($("item-1-dialog").open, true, "the item's dialog is open");
    assert.equal($("note").value, "N1");
    assert.equal(doc.activeElement, $("note"));
    assert.deepEqual(pushes, []);
  } finally {
    box.remove();
  }
});

// task-c20e285ee18797c6: a redo here re-applied the change the press had just
// undone, and its own answer named the same dialog, so the writes chained.
check("a field in an item dialog that cannot be opened: one Mod+Z sends one undo and no redo; nothing is set or focused", () => {
  const box = drawIn(
    `<dialog id="lost-dialog" data-desk-item-dialog><input type="text" id="lost" name="doc[cards][1].note" value="N2 X2"></dialog>`
  );
  try {
    $("lost-dialog").showModal = () => {
      throw new Error("InvalidStateError");
    };
    $("title").focus();
    key($("title"), { key: "z", metaKey: true });
    undone({ field: "doc[cards][1].note", value: "N2", was: "N2 X2", path: "cards" });
    assert.equal($("lost-dialog").open, false);
    assert.equal($("lost").value, "N2 X2", "the field is not set");
    assert.equal(doc.activeElement, $("title"), "the focus stays");
    assert.deepEqual(pushes, [{ event: "desk-undo", payload: { redo: false, _bp_doc: MARK } }]);
  } finally {
    box.remove();
  }
});

check("a field the form does not have is ignored", () => {
  undone({ field: "doc[nope]", value: "x", was: "y" });
  undone({});
});

// A popover as the desk's menus are (`popover`, `:popover-open`, `toggle`):
// jsdom has none of it.
const popover = (menu) => {
  let open = false;
  const matches = menu.matches.bind(menu);
  menu.matches = (sel) => (sel === ":popover-open" ? open : matches(sel));
  menu.showPopover = () => {
    open = true;
  };
  menu.hidePopover = () => {
    open = false;
    const e = new window.Event("toggle");
    e.newState = "closed";
    menu.dispatchEvent(e);
  };
  return menu;
};

// task-a8e403cee723e5f6: the focus went into the field, the Doc menu stayed open.
check("Mod+Z from an item of the open Doc menu: the answer closes the menu as the focus goes into the field", () => {
  const box = doc.createElement("div");
  box.innerHTML =
    `<div class="dk-doc-menu-list dk-menu" id="doc-menu" popover role="menu">` +
    `<button type="button" role="menuitem" id="doc-menu-history">History</button></div>`;
  $("pane").querySelector("header").appendChild(box);
  const menu = popover($("doc-menu"));
  const closed = [];
  menu.addEventListener("toggle", (e) => closed.push(e.newState));
  try {
    menu.showPopover();
    $("doc-menu-history").focus();
    key($("doc-menu-history"), { key: "z", metaKey: true });
    assert.deepEqual(pushes, [{ event: "desk-undo", payload: { redo: false, _bp_doc: MARK } }]);
    undone({ field: "doc[title]", value: "Fixture post 14", was: "Fixture post 14" });
    assert.equal(menu.matches(":popover-open"), false, "the menu is closed");
    assert.deepEqual(closed, ["closed"], "by its own toggle");
    assert.equal(doc.activeElement, $("title"));
  } finally {
    box.remove();
  }
});

// task-9acc3246edf8cf2e: focus mode on another pane entered while the undo was
// on its way. The page draws none of the hidden panes, so the focus put in the
// field fell to BODY. The way out is the focused pane's own button, a round
// trip: the server takes the marks off.
async function checkAsync(name, fn) {
  reset();
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

const desk = $("desk-panes");
const later = (ms) => new Promise((done) => setTimeout(done, ms));

await checkAsync("focus mode entered on the read-only side while an undo is on its way is left, then the field is set and focused", async () => {
  const side = doc.createElement("section");
  side.id = "side";
  side.setAttribute("data-pane-index", "2");
  side.innerHTML = `<header><button type="button" class="dk-focus" id="side-focus" aria-pressed="false">Focus</button></header>`;
  desk.appendChild(side);
  const exits = [];
  $("side-focus").addEventListener("click", () => {
    exits.push("side-focus");
    setTimeout(() => {
      desk.removeAttribute("data-focus-mode");
      side.removeAttribute("data-desk-focused");
      side.querySelector(".dk-focus").setAttribute("aria-pressed", "false");
    }, 20);
  });
  const seen = [];
  const onFocus = () => seen.push(desk.hasAttribute("data-focus-mode"));
  $("title").addEventListener("focus", onFocus);
  try {
    $("title").value = "Fixture post 14 X";
    $("title").focus();
    key($("title"), { key: "z", metaKey: true });
    seen.length = 0;
    // The user enters focus mode on the other side before the answer.
    desk.setAttribute("data-focus-mode", "true");
    side.setAttribute("data-desk-focused", "true");
    $("side-focus").setAttribute("aria-pressed", "true");
    $("side-focus").focus();
    undone({ field: "doc[title]", value: "Fixture post 14", was: "Fixture post 14 X" });
    await later(80);
    assert.deepEqual(exits, ["side-focus"], "focus mode is left by its button");
    assert.equal(desk.hasAttribute("data-focus-mode"), false);
    assert.deepEqual(seen, [false], "the field takes the focus only once the panes are back");
    assert.equal(doc.activeElement, $("title"));
    assert.equal($("title").value, "Fixture post 14");
  } finally {
    $("title").removeEventListener("focus", onFocus);
    desk.removeAttribute("data-focus-mode");
    side.remove();
    $("title").value = "Fixture post 14";
  }
});

await checkAsync("a focus mode button pressed while the undo is on its way: its patch, after the answer, is waited for and left; then the field is set and focused", async () => {
  const side = doc.createElement("section");
  side.id = "side3";
  side.setAttribute("data-pane-index", "2");
  side.innerHTML = `<header><button type="button" class="dk-focus" id="side3-focus" aria-pressed="false">Focus</button></header>`;
  desk.appendChild(side);
  // The server's `desk-focus`: the patch toggles the marks, a round trip later.
  const turns = [];
  const button = $("side3-focus");
  button.addEventListener("click", () => {
    const on = !desk.hasAttribute("data-focus-mode");
    turns.push(on ? "enter" : "leave");
    setTimeout(() => {
      if (on) {
        desk.setAttribute("data-focus-mode", "true");
        side.setAttribute("data-desk-focused", "true");
      } else {
        desk.removeAttribute("data-focus-mode");
        side.removeAttribute("data-desk-focused");
      }
      button.setAttribute("aria-pressed", String(on));
    }, 20);
  });
  const seen = [];
  const onFocus = () => seen.push(desk.hasAttribute("data-focus-mode"));
  try {
    $("title").value = "Fixture post 14 X";
    $("title").focus();
    key($("title"), { key: "z", metaKey: true });
    $("side3-focus").focus();
    $("side3-focus").click();
    $("title").addEventListener("focus", onFocus);
    // The answer comes first, the focus mode patch after it.
    undone({ field: "doc[title]", value: "Fixture post 14", was: "Fixture post 14 X" });
    assert.deepEqual(seen, [], "not focused while the patch is on its way");
    await later(150);
    assert.deepEqual(turns, ["enter", "leave"]);
    assert.equal(desk.hasAttribute("data-focus-mode"), false);
    assert.deepEqual(seen, [false], "focused once, with the panes back");
    assert.equal(doc.activeElement, $("title"));
    assert.equal($("title").value, "Fixture post 14");
  } finally {
    $("title").removeEventListener("focus", onFocus);
    desk.removeAttribute("data-focus-mode");
    side.remove();
    $("title").value = "Fixture post 14";
  }
});

await checkAsync("while focus mode stays on, the field is neither set nor focused", async () => {
  const side = doc.createElement("section");
  side.id = "side2";
  side.setAttribute("data-pane-index", "2");
  side.setAttribute("data-desk-focused", "true");
  side.innerHTML = `<header><button type="button" class="dk-focus" id="side2-focus" aria-pressed="true">Focus</button></header>`;
  desk.appendChild(side);
  desk.setAttribute("data-focus-mode", "true");
  try {
    $("side2-focus").focus();
    $("title").value = "Fixture post 14 X";
    undone({ field: "doc[title]", value: "Fixture post 14", was: "Fixture post 14 X" });
    await later(30);
    assert.equal($("title").value, "Fixture post 14 X", "not set out of sight");
    assert.equal(doc.activeElement, $("side2-focus"), "the focus stays");
  } finally {
    desk.removeAttribute("data-focus-mode");
    side.remove();
    $("title").value = "Fixture post 14";
  }
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\ndesk undo: ok");
