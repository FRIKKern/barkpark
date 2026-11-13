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

// The panes: the desk also keeps a separator after each open pane but the last.
const panesOf = () => [...el.children].filter((p) => p.hasAttribute("data-pane-index"));
const strips = () => panesOf().map((p) => p.hasAttribute("data-pane-collapsed"));
const sheet = () => window.document.getElementById("bp-desk-layout").textContent;
const tick = () => new Promise((r) => setTimeout(r, 0));

assert.deepEqual(strips(), [T, T, F, F], "four panes at 1024 px");
assert.match(sheet(), /\[data-pane-index="0"\][^{]*\{ width: 51px/);
assert.match(sheet(), /\[data-pane-index="1"\][^{]*\{ width: 51px/);
assert.doesNotMatch(sheet(), /\[data-pane-index="2"\]/, "an open pane has no strip rule");
assert.equal(panesOf()[0].getAttribute("role"), "button", "a strip is a button");
assert.equal(panesOf()[0].getAttribute("tabindex"), "0", "that the keyboard reaches");
assert.equal(panesOf()[0].getAttribute("aria-label"), "Expand Pane 0", "named for what a press on it does");
assert.equal(panesOf()[0].getAttribute("aria-expanded"), "false");
assert.equal(panesOf()[2].getAttribute("aria-label"), null, "an open pane keeps the name the server gave it");

// One separator, after the open pane that is not the last: the TanStack
// Studio's PaneResizer (role, name, value), reachable by Tab.
const separators = () => [...el.querySelectorAll(':scope > [role="separator"]')];
assert.equal(separators().length, 1, "strips and the last pane have none");
assert.equal(separators()[0].previousElementSibling, panesOf()[2]);
assert.equal(separators()[0].getAttribute("aria-label"), "Resize pane");
assert.equal(separators()[0].getAttribute("aria-orientation"), "vertical");
assert.equal(separators()[0].getAttribute("aria-valuemin"), "320");
assert.equal(separators()[0].getAttribute("aria-valuenow"), "320");
assert.equal(separators()[0].getAttribute("tabindex"), "0");
// ArrowRight widens the pane on its left by 16 px, ArrowLeft narrows it, never under 320.
// (1200 px: the same strips, and room to widen.)
width = 1200;
hook._layout();
const arrow = (key) => {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
  separators()[0].dispatchEvent(event);
  return event;
};
assert.ok(arrow("ArrowRight").defaultPrevented);
arrow("ArrowRight");
assert.match(sheet(), /\[data-pane-index="2"\][^{]*\{ width: 352px; min-width: 352px; flex: 0 0 352px; \}/);
assert.equal(separators()[0].getAttribute("aria-valuenow"), "352", "the separator says its value");
arrow("ArrowLeft"); arrow("ArrowLeft"); arrow("ArrowLeft");
assert.match(sheet(), /\[data-pane-index="2"\][^{]*\{ width: 320px;/, "never under 320 px");
assert.equal(separators()[0].getAttribute("aria-valuenow"), "320");
assert.ok(!arrow("ArrowDown").defaultPrevented, "other keys are not the separator's");
// Nor so wide that another pane is pushed off screen: of 1200 px two strips
// take 102 and the document needs 600, which leaves 498 for this one.
assert.equal(separators()[0].getAttribute("aria-valuemax"), "498", "the most the pane can be");
for (let i = 0; i < 30; i++) arrow("ArrowRight");
assert.equal(separators()[0].getAttribute("aria-valuenow"), "498", "never past its maximum");
for (let i = 0; i < 30; i++) arrow("ArrowLeft");
assert.equal(separators()[0].getAttribute("aria-valuenow"), "320");
// A patch that re-draws the panes drops the separators. The focused one comes
// back in the same place, with the focus.
separators()[0].focus();
assert.equal(window.document.activeElement, separators()[0]);
const dropped = separators()[0];
el.removeChild(dropped);
assert.equal(window.document.activeElement, window.document.body, "the focus went with it");
await tick();
assert.notEqual(separators()[0], dropped, "a new separator is in its place");
assert.equal(window.document.activeElement, separators()[0], "and has the focus again");
separators()[0].blur();
width = 1024;
hook._layout();

// A click on a strip opens it; the URL does not move.
panesOf()[1].querySelector(".pane-header-title").dispatchEvent(
  new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }),
);
assert.deepEqual(strips(), [T, F, T, F], "the clicked strip is open, the list gave way");
assert.equal(window.location.pathname, URL_PATH, "opening a strip is not navigation");
assert.equal(panesOf()[1].getAttribute("aria-label"), "Pane 1", "open again: its own name is back");
assert.equal(panesOf()[1].getAttribute("aria-expanded"), null);
assert.equal(panesOf()[2].getAttribute("aria-label"), "Expand Pane 2");

// Enter on a focused strip does the same, and the pane it becomes keeps the
// focus (a strip is a button; the open pane is not, and would drop it).
panesOf()[0].focus();
panesOf()[0].dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
assert.equal(strips()[0], F, "Enter opens the focused strip");
assert.equal(window.document.activeElement, panesOf()[0], "the opened pane has the focus");
assert.equal(panesOf()[0].getAttribute("tabindex"), "-1", "without becoming a Tab stop");
// A patch rewrites the pane's attributes and the focus falls to <body>: it
// comes back. jsdom leaves the focus on an element that lost its tabindex (a
// browser does not), so the page is told the focus is on <body>.
{
  const held = panesOf()[0];
  await tick(); // the open's own changes are seen first: only the patch below is under test
  let focused = 0;
  const focus = held.focus.bind(held);
  held.focus = (o) => { focused++; focus(o); };
  Object.defineProperty(window.document, "activeElement", { configurable: true, get: () => window.document.body });
  held.removeAttribute("tabindex");
  await new Promise((r) => setTimeout(r, 0));
  delete window.document.activeElement;
  delete held.focus;
  assert.equal(held.getAttribute("tabindex"), "-1", "the pane can hold the focus again after a patch");
  assert.ok(focused >= 1, "and is given it back");
}
// The focus moves on: the opened pane is an ordinary pane again, with no
// tabindex of its own left behind.
{
  const opened = panesOf()[0];
  const other = window.document.createElement("button");
  panesOf()[3].appendChild(other);
  other.focus();
  assert.equal(window.document.activeElement, other);
  assert.equal(opened.getAttribute("tabindex"), null, "no tabindex once the focus has left the opened pane");
  await tick();
  assert.equal(opened.getAttribute("tabindex"), null, "and none comes back with the next layout");
  other.remove();
}
// Space opens a focused strip, as Enter does.
{
  const at = strips().indexOf(T);
  panesOf()[at].focus();
  panesOf()[at].dispatchEvent(new window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
  assert.equal(strips()[at], F, "Space opens the focused strip");
  assert.equal(window.document.activeElement, panesOf()[at], "the opened pane has the focus");
  panesOf()[at].blur();
  await tick();
}

// A focused strip that opens because the window widened (no press) is lent a
// tabindex too, and gives it back the same way once the focus has left it.
{
  const at = strips().indexOf(T);
  const strip = panesOf()[at];
  strip.focus();
  width = 2000;
  hook._layout();
  assert.equal(strip.hasAttribute("data-pane-collapsed"), false, "wide enough: the strip opened by itself");
  assert.equal(strip.getAttribute("tabindex"), "-1", "it had the focus, so it can still hold it");
  const other = window.document.createElement("button");
  panesOf()[3].appendChild(other);
  other.focus();
  assert.equal(strip.getAttribute("tabindex"), null, "no tabindex once the focus has left the widened pane");
  other.remove();
  width = 1024;
  hook._layout();
  await tick();
}

// A LiveView patch rewrites a pane's attributes: the layout comes back.
const before = strips();
const wiped = panesOf()[before.indexOf(T)];
wiped.removeAttribute("data-pane-collapsed");
wiped.removeAttribute("tabindex");
wiped.removeAttribute("role");
await tick();
assert.deepEqual(strips(), before, "the layout is put back after a patch wiped it");
assert.equal(wiped.getAttribute("role"), "button");

// The server closes a pane: what is left is laid out again.
el.removeChild(panesOf()[3]);
await tick();
assert.equal(el.lastElementChild, panesOf()[2], "no separator is left after the last pane");
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
assert.equal(separators().length, 3, "every open pane but the last has a separator");

// The editor pane has no header of its own: as a strip it shows its title, not a slice of its form.
el.insertAdjacentHTML("beforeend", `<section class="pane-column dk-pane dk-doc dk-edit" id="p4" data-pane-index="4" data-pane-kind="doc" data-pane-editing aria-label="Post one"><form>fields</form></section>`);
await tick();
hook._focus = { path: window.location.pathname, index: 2 };
width = 1024;
hook._layout();
assert.equal(strips()[4], T, "the editor gave way to the pane the editor opened");
assert.match(sheet(), /\[data-pane-index="4"\][^{]*> :not\(\.pane-header\)[^{]*\{ display: none; \}/, "its form is hidden");
assert.match(sheet(), /\[data-pane-index="4"\][^{]*\[data-pane-editing\]::before \{ content: attr\(data-desk-name\)/, "its title is shown");
assert.equal(panesOf()[4].getAttribute("data-desk-name"), "Post one");
assert.equal(panesOf()[4].getAttribute("aria-label"), "Expand Post one");

hook.destroyed();
console.log("desk slice layout: ok");
window.close();
