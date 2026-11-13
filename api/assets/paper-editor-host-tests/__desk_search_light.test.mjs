// __desk_search_light.test.mjs — the desk search box's lit hit moves in the
// browser (task-b78cdd98252bb9fe, /papers/desk-vertical-slice).
//
// ArrowDown and ArrowUp move the light (aria-selected, aria-activedescendant)
// at once, with nothing sent to the server; the form's `lit` field carries
// the lit index for Enter. A patch that re-draws the same hits keeps the
// light where the keys left it; new hits start again at the first, as the
// server draws them.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_search_light.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

// The server's drawing: the first hit lit.
const options = (ids) =>
  ids
    .map((id, i) => `<a href="${BASE}/post;${id}" id="desk-search-hit-${i}" role="option" aria-selected="${i === 0}" data-desk-hit>${id}</a>`)
    .join("");
const search = (ids) =>
  `<form id="desk-search-form"><input id="desk-search-input" type="search" name="value" role="combobox" aria-activedescendant="desk-search-hit-0" /><input type="hidden" id="desk-search-lit" name="lit" value="0" /></form>` +
  `<div id="desk-search-hits"><div id="desk-search-options" role="listbox">${options(ids)}</div></div>`;

window.document.body.innerHTML =
  `<div class="dk-search" role="search">${search(["a", "b", "c"])}</div><div id="desk-panes"></div>`;
const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const pushed = [];
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent: (...a) => pushed.push(a) });
hook.mounted();

const $ = (id) => window.document.getElementById(id);
const tick = () => new Promise((r) => setTimeout(r, 0));
const lit = () => ({
  active: $("desk-search-input").getAttribute("aria-activedescendant"),
  selected: [...window.document.querySelectorAll('[role="option"]')].map((o) => o.getAttribute("aria-selected")),
  field: $("desk-search-lit").value,
});
const key = (k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  $("desk-search-input").dispatchEvent(e);
  return e;
};
$("desk-search-input").focus();

// ── The arrows move the light at once, and send nothing ─────────────────────
const down = key("ArrowDown");
assert.ok(down.defaultPrevented, "ArrowDown is the box's, not the caret's");
assert.deepEqual(lit(), { active: "desk-search-hit-1", selected: ["false", "true", "false"], field: "1" });
key("ArrowDown");
key("ArrowDown");
assert.equal(lit().active, "desk-search-hit-2", "the light stops at the last hit");
key("ArrowUp");
assert.deepEqual(lit(), { active: "desk-search-hit-1", selected: ["false", "true", "false"], field: "1" });
assert.deepEqual(pushed, [], "no key went to the server");

// ── A patch that re-draws the same hits keeps the light ─────────────────────
$("desk-search-options").innerHTML = options(["a", "b", "c"]);
$("desk-search-input").setAttribute("aria-activedescendant", "desk-search-hit-0");
$("desk-search-lit").setAttribute("value", "0");
await tick();
assert.deepEqual(lit(), { active: "desk-search-hit-1", selected: ["false", "true", "false"], field: "1" });

// Enter sends the lit index with the form.
$("desk-search-lit").value = "0";
key("Enter");
assert.equal($("desk-search-lit").value, "1", "Enter's form carries the lit hit");

// ── New hits: the first is lit again ────────────────────────────────────────
$("desk-search-options").innerHTML = options(["x", "y"]);
$("desk-search-input").setAttribute("aria-activedescendant", "desk-search-hit-0");
$("desk-search-lit").setAttribute("value", "0");
await tick();
assert.deepEqual(lit(), { active: "desk-search-hit-0", selected: ["true", "false"], field: "0" });
key("ArrowDown");
assert.equal(lit().active, "desk-search-hit-1");

// Other keys are the box's own.
assert.ok(!key("a").defaultPrevented);

console.log("ok — __desk_search_light");
