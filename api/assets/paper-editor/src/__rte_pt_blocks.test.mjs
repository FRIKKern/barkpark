// __rte_pt_blocks.test.mjs — task-19392d1e6fc661e6: the Classic rich-text
// editor's custom Portable Text blocks (a mediaModule, a quote). A block box
// opens its fields (click, Enter), "Insert block" puts a placeholder after the
// block the caret is in and asks for a new block, the server's answer replaces
// the placeholder, and a saved block's box is redrawn. The post never carries
// the attributes the editor adds to make a box a button.
//
// Runs the TRACKED static asset under jsdom.
// Run: node src/__rte_pt_blocks.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "MouseEvent", "KeyboardEvent", "Node", "MutationObserver", "CSS"]) {
  if (window[name]) globalThis[name] = window[name];
}
if (!globalThis.CSS) globalThis.CSS = { escape: (s) => String(s).replace(/["\\]/g, "\\$&") };
globalThis.window = window;
window.document.execCommand = () => true;
await import("../../../priv/static/assets/bp-rich-text-editor.js");

const box = (key, type, text) =>
  `<div data-pt-block="${key}" data-pt-type="${type}" class="bp-pt-block" contenteditable="false"><strong>${type}</strong> ${text}</div>`;
const html = `<p>Første</p>${box("a11bc9226269", "quote", "Anna")}<p>Andre</p>`;

function mount(attrs = {}) {
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", html);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  document.body.appendChild(el);
  return el;
}

function collect(el, name) {
  const seen = [];
  el.addEventListener(name, (e) => seen.push(e.detail));
  return seen;
}

let passed = 0;
const check = (label, fn) => {
  fn();
  passed += 1;
  console.log("PASS ", label);
};

check("a block box is a named, focusable button", () => {
  const el = mount();
  const b = el.querySelector(".bp-pt-block");
  assert.equal(b.getAttribute("role"), "button");
  assert.equal(b.getAttribute("tabindex"), "0");
  assert.match(b.getAttribute("aria-label"), /Edit block: quote/);
  el.remove();
});

check("clicking a box asks to open that block, and the post is the server's markup", () => {
  const el = mount();
  const opens = collect(el, "bp-pt-block-open");
  el.querySelector(".bp-pt-block strong").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.equal(opens.length, 1);
  assert.equal(opens[0].key, "a11bc9226269");
  assert.equal(opens[0].html, html);
  assert.equal(el.value, html);
  el.remove();
});

check("Enter on a focused box opens it", () => {
  const el = mount();
  const opens = collect(el, "bp-pt-block-open");
  el.querySelector(".bp-pt-block").dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  assert.equal(opens.length, 1);
  el.remove();
});

check("no declared block types, no Insert block menu", () => {
  const el = mount();
  assert.equal(el.querySelector(".bp-rte-insert"), null);
  el.remove();
});

check("Insert block puts a placeholder after the caret's block; the answer replaces it", () => {
  const types = JSON.stringify([{ name: "mediaModule", title: "Mediamodul" }, { name: "quote", title: "Sitat" }]);
  const el = mount({ "data-block-types": types });
  const menu = el.querySelector(".bp-rte-insert");
  assert.deepEqual([...menu.options].map((o) => o.value), ["", "mediaModule", "quote"]);
  assert.equal(menu.options[1].textContent, "Mediamodul");

  // the caret is in the first paragraph
  const first = el.querySelector(".bp-rte-body > p");
  const range = document.createRange();
  range.setStart(first.firstChild, 2);
  el._lastRange = range;

  const inserts = collect(el, "bp-pt-block-insert");
  const changes = collect(el, "bp-change");
  menu.value = "mediaModule";
  menu.dispatchEvent(new window.Event("change", { bubbles: true }));

  assert.equal(inserts.length, 1);
  assert.equal(inserts[0].type, "mediaModule");
  const ph = el.querySelector("[data-pt-pending]");
  assert.equal(ph.previousElementSibling, first);
  assert.match(ph.getAttribute("data-pt-block"), /^__pending-/);
  assert.match(inserts[0].html, /data-pt-pending/);
  assert.equal(changes.length, 0, "the placeholder is not posted on its own");

  el.ptBlockReady(inserts[0].pending, "e78e658ad2ee", box("e78e658ad2ee", "mediaModule", ""));
  assert.equal(el.querySelector("[data-pt-pending]"), null);
  const added = el.querySelector('[data-pt-block="e78e658ad2ee"]');
  assert.equal(added.previousElementSibling, first);
  assert.equal(added.getAttribute("role"), "button");
  assert.equal(changes.length, 1);
  assert.doesNotMatch(changes[0].value, /role=|tabindex=|data-pt-decorated/);
  el.remove();
});

check("a refused insert removes the placeholder", () => {
  const el = mount({ "data-block-types": JSON.stringify([{ name: "quote" }]) });
  const inserts = collect(el, "bp-pt-block-insert");
  const menu = el.querySelector(".bp-rte-insert");
  menu.value = "quote";
  menu.dispatchEvent(new window.Event("change", { bubbles: true }));
  el.ptBlockReady(inserts[0].pending, null, "");
  assert.equal(el.querySelector("[data-pt-pending]"), null);
  el.remove();
});

check("a saved block's box shows its new summary", () => {
  const el = mount();
  el.ptBlockUpdate("a11bc9226269", box("a11bc9226269", "quote", "Et kortere sitat"));
  const b = el.querySelector('[data-pt-block="a11bc9226269"]');
  assert.match(b.textContent, /Et kortere sitat/);
  assert.equal(b.getAttribute("role"), "button");
  el.remove();
});

console.log(`\nall ${passed} rich-text block checks passed`);
