// __desk_slice_layout.test.mjs — the desk slice's pane layout
// (task-a77a5b0a1395a02f, /papers/desk-vertical-slice): panes that do not fit
// collapse to strips by the SAME rule as the TanStack Studio, a click on a
// strip opens it without touching the URL, and a LiveView patch that rewrites
// a pane's attributes does not undo the layout.
//
// REFERENCE below was produced by running the TanStack Studio's own function,
// `collapsed` in barkpark-studio app/src/lib/layout.ts (Sanity's algorithm),
// on these chains and widths. It is the other studio's answer, not this
// file's: if the two ever differ, the port in bp-desk.js is what moved.
//
// Run: node ../paper-editor-host-tests/__desk_slice_layout.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const URL_PATH = "/w/a/p/b/d/production/studio/_desk/utgivelser;uten-omslag;pub-1";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${URL_PATH}`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");
const { collapsed } = window.BarkparkDeskLayout;

const CHAINS = {
  four: ["types", "menu", "list", "doc"],
  three: ["types", "list", "doc"],
  five: ["types", "menu", "list", "doc", "doc"],
  lists: ["types", "menu", "list"],
};
const T = true;
const F = false;
const REFERENCE = {
  "four@1440": [T, F, F, F],
  "four@1200": [T, T, F, F],
  "four@1024": [T, T, F, F],
  "four@800": [T, T, T, F],
  "four@640": [T, T, T, F],
  "three@1440": [F, F, F],
  "three@1200": [T, F, F],
  "three@1024": [T, F, F],
  "three@800": [T, T, F],
  "three@640": [T, T, F],
  "five@1440": [T, T, T, F, F],
  "five@1200": [T, T, F, T, F],
  "five@1024": [T, T, T, T, F],
  "five@800": [T, T, T, T, F],
  "five@640": [T, T, T, T, F],
  "lists@1440": [F, F, F],
  "lists@1200": [F, F, F],
  "lists@1024": [F, F, F],
  "lists@800": [T, F, F],
  "lists@640": [T, T, F],
};

// ── The rule: the TanStack Studio's answer at every width ───────────────────
for (const [key, expected] of Object.entries(REFERENCE)) {
  const [chain, width] = key.split("@");
  assert.deepEqual(collapsed(CHAINS[chain], Number(width)), expected, key);
}
// A pane opened from its strip is the focus: it never collapses.
assert.deepEqual(collapsed(CHAINS.four, 1024, 1), [T, F, T, F], "four@1024 focus 1");
assert.deepEqual(collapsed(CHAINS.five, 1440, 0), [F, T, F, T, F], "five@1440 focus 0");

// ── The page: strips at 1024 px, a strip opens on click, a patch is survived ─
const pane = (index, kind) =>
  `<section class="pane-column dk-pane" id="p${index}" data-pane-index="${index}" data-pane-kind="${kind}"><div class="pane-header"><span class="pane-header-title">Pane ${index}</span></div><div class="pane-body"></div></section>`;
window.document.body.innerHTML = `<div id="desk-panes">${CHAINS.four.map((kind, i) => pane(i, kind)).join("")}</div>`;
const el = window.document.getElementById("desk-panes");
let width = 1024;
Object.defineProperty(el, "clientWidth", { get: () => width });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();

const strips = () => [...el.children].map((p) => p.hasAttribute("data-pane-collapsed"));
const sheet = () => window.document.getElementById("bp-desk-layout").textContent;
const tick = () => new Promise((r) => setTimeout(r, 0));

assert.deepEqual(strips(), [T, T, F, F], "four panes at 1024 px");
assert.match(sheet(), /\[data-pane-index="0"\][^{]*\{ width: 51px/);
assert.match(sheet(), /\[data-pane-index="1"\][^{]*\{ width: 51px/);
assert.doesNotMatch(sheet(), /\[data-pane-index="2"\]/, "an open pane has no strip rule");
assert.equal(el.children[0].getAttribute("role"), "button", "a strip is a button");
assert.equal(el.children[0].getAttribute("tabindex"), "0", "that the keyboard reaches");

// A click on a strip opens it; the URL does not move.
el.children[1].querySelector(".pane-header-title").dispatchEvent(
  new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }),
);
assert.deepEqual(strips(), [T, F, T, F], "the clicked strip is open, the list gave way");
assert.equal(window.location.pathname, URL_PATH, "opening a strip is not navigation");

// Enter on a focused strip does the same.
el.children[0].dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
assert.equal(strips()[0], F, "Enter opens the focused strip");

// A LiveView patch rewrites a pane's attributes: the layout comes back.
const before = strips();
const wiped = el.children[before.indexOf(T)];
wiped.removeAttribute("data-pane-collapsed");
wiped.removeAttribute("tabindex");
wiped.removeAttribute("role");
await tick();
assert.deepEqual(strips(), before, "the layout is put back after a patch wiped it");
assert.equal(wiped.getAttribute("role"), "button");

// The server closes a pane: what is left is laid out again.
el.removeChild(el.lastElementChild);
await tick();
assert.deepEqual(strips(), collapsed(CHAINS.lists, 1024), "three list panes fit at 1024 px");

// A new URL forgets the strip the editor opened.
el.insertAdjacentHTML("beforeend", pane(3, "doc"));
window.history.replaceState({}, "", URL_PATH + "x");
await tick();
assert.deepEqual(strips(), [T, T, F, F], "back to the rule's own focus: the last pane");

// Wide enough for all four: nothing is a strip, and no rule is left behind.
width = 2000;
hook._layout();
assert.deepEqual(strips(), [F, F, F, F]);
assert.doesNotMatch(sheet(), /width: 51px/, "no strip rule is left behind");

hook.destroyed();
console.log("desk slice layout: ok");
window.close();
