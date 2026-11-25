// __array_focus.test.mjs — task-278c7992ed05a30b: after an array row button
// (+ Add, ▲, ▼, ×) round-trips, focus lands where the keyboard user expects —
// the new row, the next row, the moved item — never on <body> and never on the
// neighbour that took the moved item's place.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom (its document-level listener), on a fieldset shaped like ArrayField's
// render, and replays what the LiveView patch does to the rows.
//
// Run: node ../paper-editor-host-tests/__array_focus.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "MouseEvent", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-array-focus.js");
assert.equal(typeof window.BarkparkArrayRowFocusTarget, "function", "bp-array-focus.js loaded");

const row = (i, value, count) =>
  `<li class="bp-array-row" data-row-index="${i}">` +
  `<div class="bp-array-row-body"><input type="text" class="bp-input" aria-label="Stikkord ${i + 1}" value="${value}"></div>` +
  `<div class="bp-array-row-actions">` +
  `<button type="button" class="bp-array-btn bp-array-btn-up" phx-value-action="move_up" phx-value-index="${i}"${i === 0 ? " disabled" : ""}>▲</button>` +
  `<button type="button" class="bp-array-btn bp-array-btn-down" phx-value-action="move_down" phx-value-index="${i}"${i === count - 1 ? " disabled" : ""}>▼</button>` +
  `<button type="button" class="bp-array-btn bp-array-btn-remove" phx-value-action="remove_row" phx-value-index="${i}">×</button>` +
  `</div></li>`;

// The server render of `values`, replacing the rows the way a patch does.
function render(fieldset, values) {
  fieldset.querySelector("ol.bp-array-rows").innerHTML = values.map((v, i) => row(i, v, values.length)).join("");
}

function mount(values) {
  document.body.innerHTML =
    `<fieldset class="bp-field bp-field-array" id="bp-array-tags"><legend>Stikkord</legend>` +
    `<ol class="bp-array-rows"></ol>` +
    `<button type="button" class="bp-array-btn bp-array-btn-add" phx-value-action="add_row">+ Legg til</button>` +
    `</fieldset>`;
  const el = document.getElementById("bp-array-tags");
  render(el, values);
  return { el, hook: { destroyed() {} } };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function press(el, selector, nextValues) {
  const button = el.querySelector(selector);
  button.focus();
  button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  render(el, nextValues);
  await settle();
  return document.activeElement;
}

try {
  {
    const { el, hook } = mount(["dikt", "fjell"]);
    const active = await press(el, ".bp-array-btn-add", ["dikt", "fjell", ""]);
    assert.equal(active.getAttribute("aria-label"), "Stikkord 3", "add puts focus in the new row");
    hook.destroyed();
  }

  {
    const { el, hook } = mount(["a", "b", "c"]);
    const active = await press(el, 'li[data-row-index="1"] .bp-array-btn-remove', ["a", "c"]);
    assert.notEqual(active, document.body, "remove never drops focus to body");
    assert.equal(active.value, "c", "remove focuses the row that took its place");
    hook.destroyed();
  }

  {
    const { el, hook } = mount(["a", "b"]);
    const active = await press(el, 'li[data-row-index="1"] .bp-array-btn-remove', ["a"]);
    assert.equal(active.value, "a", "removing the last row focuses the row before it");
    hook.destroyed();
  }

  {
    const { el, hook } = mount(["only"]);
    const active = await press(el, ".bp-array-btn-remove", []);
    assert.ok(active.matches(".bp-array-btn-add"), "removing the only row focuses Add");
    hook.destroyed();
  }

  {
    const { el, hook } = mount(["a", "b", "c"]);
    const active = await press(el, 'li[data-row-index="0"] .bp-array-btn-down', ["b", "a", "c"]);
    assert.ok(active.matches(".bp-array-btn-down"), "move down keeps focus on Move down");
    assert.equal(active.closest("li").dataset.rowIndex, "1", "…of the moved item at its new position");
    hook.destroyed();
  }

  {
    const { el, hook } = mount(["a", "b"]);
    const active = await press(el, 'li[data-row-index="0"] .bp-array-btn-down', ["b", "a"]);
    assert.ok(active.matches(".bp-array-btn-up"), "moved to the end: its Move down is disabled, so Move up");
    assert.equal(active.closest("li").dataset.rowIndex, "1");
    hook.destroyed();
  }

  {
    // A press whose patch has not landed moves nothing.
    const { el, hook } = mount(["a", "b"]);
    const button = el.querySelector(".bp-array-btn-add");
    button.focus();
    button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
    el.querySelector("legend").setAttribute("data-x", "1");
    await settle();
    assert.equal(document.activeElement, button, "no row change, no focus move");
    hook.destroyed();
  }

  {
    // task-7f47b7ad78b08048: a row's open state is the person's; the server
    // only opens one, by giving it `data-row-finding`.
    document.body.innerHTML =
      `<details class="bp-array-item" id="bp-item-s0"><summary>Row</summary><input id="s0-note"></details>` +
      `<details class="bp-array-item" id="bp-item-s1" open data-row-finding><summary>Row</summary></details>`;
    const [s0, s1] = [document.getElementById("bp-item-s0"), document.getElementById("bp-item-s1")];
    s0.setAttribute("data-row-finding", "");
    await settle();
    assert.equal(s0.open, true, "a closed row that comes to carry a finding opens");
    s1.open = false;
    s1.setAttribute("data-row-index", "1");
    await settle();
    assert.equal(s1.open, false, "a row the person closed stays closed while its finding is unchanged");
    const other = document.createElement("details");
    document.body.append(other);
    other.setAttribute("data-row-finding", "");
    await settle();
    assert.equal(other.open, false, "only array rows are opened");
  }

  // task-bc277388a704d276: an array of several member types adds through a
  // type menu. The patch closes the menu and hides the pressed button.
  {
    const typedRow = (i, heading, open, count) =>
      `<li class="bp-array-row bp-array-row-item" data-row-index="${i}" data-member-type="sec">` +
      `<div class="bp-array-row-body"><details class="bp-array-item"${open ? " open" : ""}>` +
      `<summary>Section</summary>` +
      `<div class="bp-composite"><input type="text" name="doc[sections][${i}].heading" value="${heading}"></div>` +
      `</details></div>` +
      `<div class="bp-array-row-actions">` +
      `<button type="button" class="bp-array-btn bp-array-btn-up" phx-value-action="move_up" phx-value-index="${i}"${i === 0 ? " disabled" : ""}>▲</button>` +
      `<button type="button" class="bp-array-btn bp-array-btn-down" phx-value-action="move_down" phx-value-index="${i}"${i === count - 1 ? " disabled" : ""}>▼</button>` +
      `<button type="button" class="bp-array-btn bp-array-btn-remove" phx-value-action="remove_row" phx-value-index="${i}">×</button>` +
      `</div></li>`;
    const menu =
      `<details class="bp-array-add-menu" data-add-member-menu>` +
      `<summary class="bp-array-btn bp-array-btn-add">+ Add item</summary>` +
      `<ul class="bp-array-add-members" role="list">` +
      `<li><button type="button" class="bp-array-add-member" phx-value-action="add_row" phx-value-member="sec">Section</button></li>` +
      `</ul></details>`;
    // The server render: rows as given ([heading, open]), the menu closed.
    const renderTyped = (fieldset, rows) => {
      fieldset.querySelector("ol.bp-array-rows").innerHTML = rows
        .map(([h, open], i) => typedRow(i, h, open, rows.length))
        .join("");
      fieldset.querySelector("details.bp-array-add-menu").outerHTML = menu;
    };
    const mountTyped = (rows) => {
      document.body.innerHTML =
        `<fieldset class="bp-field bp-field-array" data-typed-array id="bp-array-sections"><legend>Sections</legend>` +
        `<ol class="bp-array-rows"></ol>${menu}</fieldset>`;
      const el = document.getElementById("bp-array-sections");
      renderTyped(el, rows);
      return el;
    };

    {
      const el = mountTyped([["One", false]]);
      el.querySelector("details.bp-array-add-menu").open = true;
      const button = el.querySelector(".bp-array-add-member");
      button.focus();
      button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      renderTyped(el, [["One", false], ["", true]]);
      await settle();
      assert.notEqual(document.activeElement, document.body, "Add from the type menu never drops focus to body");
      assert.equal(
        document.activeElement.getAttribute("name"),
        "doc[sections][1].heading",
        "Add from the type menu puts focus in the new row's first field"
      );
    }

    {
      // The new row drawn closed: its first field cannot take focus, so its summary.
      const el = mountTyped([["One", false]]);
      const button = el.querySelector(".bp-array-add-member");
      button.focus();
      button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      renderTyped(el, [["One", false], ["Two", false]]);
      await settle();
      assert.equal(document.activeElement.tagName, "SUMMARY", "a closed new row: focus on its summary");
      assert.equal(document.activeElement.closest("li").dataset.rowIndex, "1");
    }

    {
      // No rows left: the type menu's summary is the field's Add.
      const el = mountTyped([["Only", false]]);
      const button = el.querySelector(".bp-array-btn-remove");
      button.focus();
      button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      renderTyped(el, []);
      await settle();
      assert.ok(document.activeElement.matches("details.bp-array-add-menu > summary"), "removing the only row focuses the type menu");
    }
  }

  // The desk's rows (ArrayStringRow, ArrayItemDialog): Remove is an item of
  // the row's "…" menu, not a row button. The row and its menu go with the
  // press; focus went to <body>.
  {
    const deskRow = (i, value, count) =>
      `<li class="bp-array-row dk-array-row dk-string-row" data-row-index="${i}" data-item-path="highlights[${i}]">` +
      `<button type="button" class="icon-btn dk-drag-handle" aria-label="Move item ${i + 1}" data-desk-item-handle${count < 2 ? " disabled" : ""}></button>` +
      `<div class="dk-string-value"><input type="text" class="bp-input" id="highlights[${i}]" value="${value}"></div>` +
      `<div class="dk-item-actions"><button type="button" id="highlights[${i}]-menuButton" class="icon-btn dk-item-menu-button"></button>` +
      `<div id="highlights[${i}]-menu" popover role="menu" data-desk-item-menu>` +
      `<button type="button" role="menuitem" tabindex="-1" phx-click="array_op" phx-value-action="remove_row" phx-value-index="${i}" data-desk-item-action="remove">Remove</button>` +
      `<button type="button" role="menuitem" tabindex="-1" phx-click="desk-item-copy" phx-value-index="${i}" data-desk-item-action="copy">Copy</button>` +
      `</div></div></li>`;
    const renderDesk = (fieldset, values) => {
      fieldset.querySelector("ol.bp-array-rows").innerHTML = values.map((v, i) => deskRow(i, v, values.length)).join("");
    };
    const mountDesk = (values, add) => {
      document.body.innerHTML =
        `<fieldset class="bp-field bp-field-array" id="bp-array-highlights" data-array-path="doc[highlights]" data-desk-items>` +
        `<legend>Highlights</legend><ol class="bp-array-rows" id="highlights"></ol>${add}</fieldset>`;
      const el = document.getElementById("bp-array-highlights");
      renderDesk(el, values);
      return el;
    };
    const ADD = `<button type="button" class="bp-array-btn bp-array-btn-add" phx-value-action="add_row">+ Add item</button>`;
    const pressMenu = async (el, i, action, next) => {
      const item = el.querySelector(`li[data-row-index="${i}"] [data-desk-item-action="${action}"]`);
      item.focus();
      item.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      renderDesk(el, next);
      await settle();
      return document.activeElement;
    };

    {
      const el = mountDesk(["a", "b", "c"], ADD);
      const active = await pressMenu(el, 1, "remove", ["a", "c"]);
      assert.notEqual(active, document.body, "the menu's Remove never drops focus to body");
      assert.equal(active.closest("li").dataset.rowIndex, "1", "…it focuses the row now in that place");
      assert.ok(active.matches("[data-desk-item-handle]"), "…on its first control, the handle");
    }

    {
      const el = mountDesk(["a", "b", "c"], ADD);
      const active = await pressMenu(el, 2, "remove", ["a", "b"]);
      assert.equal(active.closest("li").dataset.rowIndex, "1", "removing the last row focuses the row before it");
    }

    {
      // One row left: its handle is disabled, so the input.
      const el = mountDesk(["a", "b"], ADD);
      const active = await pressMenu(el, 0, "remove", ["b"]);
      assert.equal(active.id, "highlights[0]", "one row left: focus in its input");
    }

    {
      const el = mountDesk(["only"], ADD);
      const active = await pressMenu(el, 0, "remove", []);
      assert.ok(active.matches(".bp-array-btn-add"), "removing the only row from its menu focuses Add item");
    }

    {
      // An array of several item types adds through the desk's "Add item" menu.
      const typedAdd =
        `<div class="dk-add-item"><button type="button" id="bp-array-highlights-add" class="bp-array-btn bp-array-btn-add" aria-haspopup="menu">+ Add item</button>` +
        `<div popover role="menu" data-desk-item-menu></div></div>`;
      const el = mountDesk(["only"], typedAdd);
      const active = await pressMenu(el, 0, "remove", []);
      assert.equal(active.id, "bp-array-highlights-add", "no rows left: the desk's Add item menu button");
    }

    {
      // Copy writes nothing and changes no row: no focus move.
      const el = mountDesk(["a", "b"], ADD);
      const item = el.querySelector('li[data-row-index="0"] [data-desk-item-action="copy"]');
      item.focus();
      item.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
      await settle();
      assert.equal(document.activeElement, item, "Copy moves no focus");
    }
  }

  // task-e070cb99b86100be: another editor's save is drawn into the field B
  // rests in (bp:form-remote-values) while B's selection covers letters that
  // save replaced. The selection was carried onto the other's new letters, so
  // B's next key replaced them, and the post read as B's own edit.
  {
    const remote = (input, was, value) => {
      window.dispatchEvent(
        new window.CustomEvent("phx:bp:form-remote-values", {
          detail: { values: { [input.name]: { value, was } } },
        }),
      );
    };
    const typed = (input, text) => input.setRangeText(text, input.selectionStart, input.selectionEnd, "end");
    const field = (value) => {
      document.body.innerHTML =
        `<form id="editor-form"><input type="hidden" name="_bp_seen" value="{}">` +
        `<input type="text" name="doc[title]" value="${value}"></form>`;
      const input = document.querySelector('[name="doc[title]"]');
      input.focus();
      return input;
    };

    {
      // B selects the o of "two"; A's save replaces it with A.
      const input = field("one two three");
      input.setSelectionRange(6, 7);
      remote(input, "one two three", "one twA three");
      assert.equal(input.value, "one twA three");
      typed(input, "B");
      assert.equal(input.value, "one twAB three", "B's key goes after A's letter, never over it");
    }

    {
      // A inserts inside B's selection.
      const input = field("one two three");
      input.setSelectionRange(4, 7);
      remote(input, "one two three", "one twXo three");
      typed(input, "B");
      assert.ok(input.value.includes("X"), `A's insert survives B's key: ${input.value}`);
    }

    {
      // A selection the other's change does not touch keeps its text.
      const input = field("one two three");
      input.setSelectionRange(8, 13);
      remote(input, "one two three", "ONE two three");
      assert.equal(input.value.slice(input.selectionStart, input.selectionEnd), "three");
    }

    {
      // A caret keeps its place in the text around the other's change.
      const input = field("one two three");
      input.setSelectionRange(7, 7);
      remote(input, "one two three", "one twA three");
      assert.equal(input.selectionStart, 7);
      assert.equal(input.selectionEnd, 7);
    }
  }

  console.log("array focus: all checks passed");
} finally {
  window.close();
}
