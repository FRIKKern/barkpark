// __desk_reference_card.test.mjs — LOOKS PR 5b: in the desk's edit pane a
// picked reference is the TanStack Studio's card (RefInput.tsx): the type's
// tile, the title, the type under it, and one "Reference actions" menu with
// Clear and Replace. Outside the desk the pill with Change and Remove stays.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_reference_card.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "EventTarget",
  "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.sessionStorage = window.sessionStorage;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.CSS ||= { escape: (value) => String(value) };

const fetchMock = async (url, options = {}) => {
  if (options.method === "POST") return { ok: true, json: async () => ({}) };
  if (String(url).includes("/v1/data/doc/")) {
    return { ok: true, json: async () => ({ result: { _id: "author-berg", _type: "author", title: "Ola Berg" } }) };
  }
  return {
    ok: true,
    json: async () => ({ searchEventId: "e1", documents: [{ _id: "author-ness", _type: "author", title: "Ingrid Ness" }] }),
  };
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../priv/static/assets/bp-search-intel.js");
globalThis.BpSearchIntel = window.BpSearchIntel;
await import("../../priv/static/assets/bp-reference-picker.js");

const tick = (ms = 50) => new Promise((r) => setTimeout(r, ms));
// A pointer click (detail 1); el.click() is a keyboard one (detail 0).
const press = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 1 }));
const key = (el, k) =>
  el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));

// The desk's edit pane: the shell stamps the type words and icons.
document.body.innerHTML =
  `<div data-type-labels='{"author":"Author"}' data-type-icons='{"*":"<svg data-icon=\\"doc\\"></svg>"}'>` +
  `<section class="dk-edit"><div id="desk"></div></section><div id="studio"></div></div>`;

function mount(where) {
  const picker = document.createElement("bp-reference-picker");
  picker.setAttribute("ref-type", "author");
  picker.setAttribute("value", "author-berg");
  document.getElementById(where).appendChild(picker);
  const emitted = [];
  picker.addEventListener("bp-change", (e) => emitted.push(e.detail.value));
  return { picker, emitted };
}

try {
  // ── The card ──────────────────────────────────────────────────────────────
  const { picker, emitted } = mount("desk");
  await tick();
  const card = picker.querySelector(".ref-box.ref-row");
  assert.ok(card, "the desk draws the card");
  assert.equal(picker.querySelector(".ref-selected"), null, "not the pill");
  assert.ok(card.querySelector(".dk-media svg[data-icon=doc]"), "the type's tile");
  assert.equal(card.querySelector(".t").textContent, "Ola Berg", "the title");
  assert.equal(card.querySelector(".s").textContent, "Author", "the type under it");
  const actions = card.querySelector('button[aria-label="Reference actions"]');
  assert.ok(actions, "one Reference actions button");
  assert.equal(actions.getAttribute("aria-haspopup"), "menu");
  assert.equal(
    [...card.querySelectorAll("button")].filter((b) => /Change|Remove/.test(b.textContent)).length,
    0,
    "no Change or Remove buttons beside it"
  );

  // ── The menu: keyboard opens it on its first item; arrows; Escape returns ──
  const menu = card.querySelector('[role="menu"]');
  assert.equal(menu.hidden, true);
  actions.focus();
  key(actions, "ArrowDown");
  assert.equal(menu.hidden, false, "ArrowDown opens the menu");
  assert.equal(actions.getAttribute("aria-expanded"), "true");
  const items = [...menu.querySelectorAll('[role="menuitem"]')];
  assert.deepEqual(items.map((i) => i.textContent), ["Clear", "Replace"]);
  assert.equal(document.activeElement, items[0], "on Clear");
  key(items[0], "ArrowDown");
  assert.equal(document.activeElement, items[1], "ArrowDown moves to Replace");
  key(items[1], "ArrowDown");
  assert.equal(document.activeElement, items[0], "and wraps");
  key(items[0], "Escape");
  assert.equal(menu.hidden, true, "Escape closes it");
  assert.equal(document.activeElement, actions, "and gives the focus back to the button");

  // ── Replace: the search, with the focus; Escape brings the pick back ──────
  press(actions);
  assert.equal(document.activeElement, menu, "a pointer click focuses the menu, no item lit");
  [...menu.querySelectorAll('[role="menuitem"]')][1].click();
  const input = picker.querySelector(".bp-ref-search-input");
  assert.equal(document.activeElement, input, "Replace focuses the search");
  key(input, "Escape");
  await tick();
  assert.ok(picker.querySelector(".ref-box"), "Escape brings the card back");
  assert.equal(
    document.activeElement,
    picker.querySelector('button[aria-label="Reference actions"]'),
    "with the focus on its menu button"
  );
  assert.deepEqual(emitted, [], "nothing changed");

  // ── Replace, then a pick: the card shows it, focus on its button ───────────
  picker.querySelector('button[aria-label="Reference actions"]').click();
  picker.querySelectorAll('[role="menuitem"]')[1].click();
  const search = picker.querySelector(".bp-ref-search-input");
  search.value = "in";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick(500);
  picker.querySelector('[role="option"]').click();
  await tick();
  assert.equal(picker.querySelector(".ref-box .t").textContent, "Ingrid Ness");
  assert.deepEqual(emitted, ["author-ness"], "the pick is sent");
  assert.equal(document.activeElement, picker.querySelector('button[aria-label="Reference actions"]'));

  // ── Clear: the value goes, the search takes the focus ─────────────────────
  picker.querySelector('button[aria-label="Reference actions"]').click();
  picker.querySelectorAll('[role="menuitem"]')[0].click();
  assert.deepEqual(emitted, ["author-ness", ""], "Clear sends the empty value");
  assert.equal(picker.querySelector(".ref-box"), null);
  assert.equal(document.activeElement, picker.querySelector(".bp-ref-search-input"), "the search has the focus");

  // ── A click outside closes an open menu ───────────────────────────────────
  const other = mount("desk").picker;
  await tick();
  const b2 = other.querySelector('button[aria-label="Reference actions"]');
  b2.click();
  document.body.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
  assert.equal(other.querySelector('[role="menu"]').hidden, true, "a click outside closes it");

  // ── Control: outside the desk, the pill with Change and Remove ────────────
  const studio = mount("studio").picker;
  await tick();
  assert.equal(studio.querySelector(".ref-box"), null, "no card outside the desk");
  assert.ok(studio.querySelector(".ref-selected"), "the pill");
  assert.deepEqual(
    [...studio.querySelectorAll("button")].map((b) => b.textContent),
    ["Change", "Remove"]
  );

  console.log("desk reference card: ok");
  process.exit(0);
} catch (e) {
  console.error(e);
  process.exit(1);
}
