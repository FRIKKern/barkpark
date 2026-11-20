// __desk_undo_answer.test.mjs — task-c25c112913859b11 (F7): the answer to
// the desk's undo (`desk:undone`). It sets the field that still shows the old
// value, opens the folds, the strip and the item dialog around it, closes an
// open desk menu, puts the caret at the end of what changed, and the focus in
// the field. A dialog that cannot be opened leaves the page as it is.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-undo.js under
// jsdom, on the page __desk_undo_page.mjs draws.
//
// Run: node ../paper-editor-host-tests/__desk_undo_answer.test.mjs
import assert from "node:assert/strict";
import { $, check, doc, done, key, MARK, pushes, toggled, undone, window } from "./__desk_undo_page.mjs";

check("desk:undone sets the focused field that shows the old value; the caret goes to the change", () => {
  const title = $("title");
  title.value = "bbb Fixture post 14 A aaa";
  title.focus();
  undone({ field: "doc[title]", value: "bbb Fixture post 14 A", was: "bbb Fixture post 14 A aaa" });
  assert.equal(title.value, "bbb Fixture post 14 A");
  assert.equal(doc.activeElement, title);
  assert.equal(title.selectionStart, "bbb Fixture post 14 A".length);
});

await check("an undo in another field moves the focus there, as TanStack's", () => {
  const excerpt = $("excerpt");
  excerpt.value = "Short. B";
  doc.body.focus();
  undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
  assert.equal(excerpt.value, "Short.");
  assert.equal(doc.activeElement, excerpt);
});

await check("a field showing other text keeps it, and still takes the focus", () => {
  const title = $("title");
  title.value = "typed on";
  $("excerpt").focus();
  undone({ field: "doc[title]", value: "Fixture post 14", was: "Fixture post 14 A" });
  assert.equal(title.value, "typed on");
  assert.equal(doc.activeElement, title);
});

await check("a field drawn with the new value already (its tab was switched to) takes the focus and the caret", () => {
  const excerpt = $("excerpt");
  excerpt.value = "Short.";
  $("title").focus();
  undone({ field: "doc[excerpt]", value: "Short.", was: "Short. E1" });
  assert.equal(excerpt.value, "Short.");
  assert.equal(doc.activeElement, excerpt);
  assert.equal(excerpt.selectionStart, "Short.".length);
});

await check("a field in a fieldset folded since (by the user) is opened by its own button, then focused", () => {
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

await check("a field drawn in a fieldset that starts folded (its tab was switched to) is opened too", () => {
  $("set-toggle").setAttribute("aria-expanded", "false");
  $("folded").value = "Folded.";
  $("add").focus();
  undone({ field: "doc[folded]", value: "Folded.", was: "Folded. X1" });
  assert.equal($("set-toggle").getAttribute("aria-expanded"), "true");
  assert.equal(doc.activeElement, $("folded"));
});

await check("nested folds (a fieldset in a folded object, a closed details) all open, outermost first", () => {
  toggled.length = 0;
  $("deep").value = "Deep. X";
  undone({ field: "doc[deep]", value: "Deep.", was: "Deep. X" });
  assert.deepEqual(toggled, ["obj-toggle", "inner-toggle"]);
  assert.equal($("obj-toggle").getAttribute("aria-expanded"), "true");
  assert.equal($("inner-toggle").getAttribute("aria-expanded"), "true");
  assert.equal($("det").open, true);
  assert.equal(doc.activeElement, $("deep"));
});

await check("the pane folded to a strip while the undo was on its way is opened as a click on it does, then focused", () => {
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

await check("a pane drawn a strip wide whose mark the patch dropped is marked again, then opened as a click does", () => {
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

await check("an open fold is left as it is", () => {
  $("set-toggle").setAttribute("aria-expanded", "true");
  toggled.length = 0;
  undone({ field: "doc[folded]", value: "Folded.", was: "Folded." });
  assert.deepEqual(toggled, []);
  assert.equal($("set-toggle").getAttribute("aria-expanded"), "true");
});

await check("an undone select is set when it still shows the old option, and focused", () => {
  $("choice").value = "c";
  doc.body.focus();
  undone({ field: "doc[choice]", value: "b", was: "c" });
  assert.equal($("choice").value, "b");
  assert.equal(doc.activeElement, $("choice"));
  $("choice").value = "c";
});

await check("an undone list (no input of its own) brings its first input into sight and focus", () => {
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

await check("a list the undo emptied in a folded fieldset: its wrapper is found by path, unfolded and focused", () => {
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

await check("a field in a list item's closed dialog: the dialog opens as a click on the item does, then the field is set and focused", () => {
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
await check("a field in an item dialog that cannot be opened: one Mod+Z sends one undo and no redo; nothing is set or focused", () => {
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

await check("a field the form does not have is ignored", () => {
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
await check("Mod+Z from an item of the open Doc menu: the answer closes the menu as the focus goes into the field", () => {
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

done("desk undo answer");
