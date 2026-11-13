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

  console.log("array focus: all checks passed");
} finally {
  window.close();
}
