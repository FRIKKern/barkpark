// __desk_focus_mode.test.mjs — J26, focus mode's layout (task-23cce2d91220d4ca,
// /papers/desk-vertical-slice).
//
// The server marks the desk (`data-focus-mode`) and its focused pane
// (`data-desk-focused`); the panes it hides stay in the page. bp-desk.js
// lays out the focused pane alone, the whole width: no strips, no dividers.
// When the marks go, the panes are laid out as before.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_focus_mode.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post;a|post;b`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const KINDS = ["types", "list", "doc", "doc"];
const pane = (index, kind) =>
  `<section class="pane-column dk-pane" id="p${index}" data-pane-index="${index}" data-pane-kind="${kind}"><div class="pane-header"><span class="pane-header-title">Pane ${index}</span></div><div class="pane-body"></div></section>`;
window.document.body.innerHTML = `<div id="desk-panes">${KINDS.map((k, i) => pane(i, k)).join("")}</div>`;
const el = window.document.getElementById("desk-panes");
let width = 1300;
Object.defineProperty(el, "clientWidth", { get: () => width });
const panesOf = () => [...el.children].filter((p) => p.hasAttribute("data-pane-index"));
panesOf().forEach((p, i) => {
  p.getBoundingClientRect = () => ({ left: i * 320, right: (i + 1) * 320, width: 320, top: 0, bottom: 800, height: 800 });
});
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();
const sheet = () => window.document.getElementById("bp-desk-layout").textContent;
const tick = () => new Promise((r) => setTimeout(r, 0));
const separators = () => el.querySelectorAll('[role="separator"]').length;
const strips = () => panesOf().map((p) => p.hasAttribute("data-pane-collapsed"));

// Before: two documents need room, so the root is a strip, and there are dividers.
const before = { strips: strips(), separators: separators() };
assert.ok(before.strips[0], "the root is a strip at 1300 px");
assert.ok(before.separators > 0, "open panes have dividers");

// ── On: the first document of the split alone, though it is not the last ────
el.setAttribute("data-focus-mode", "");
panesOf()[2].setAttribute("data-desk-focused", "");
await tick();
assert.match(sheet(), /#desk-panes > \[data-pane-index\] \{ display: none; \}/, "every pane is hidden…");
assert.match(sheet(), /\[data-pane-index="2"\] \{ display: flex; width: 100%/, "…but the focused one, the whole width");
assert.doesNotMatch(sheet(), /\[data-pane-index="3"\] \{ display: flex/, "the last pane is not the one shown");
assert.deepEqual(strips(), [false, false, false, false], "nothing is a strip");
assert.equal(separators(), 0, "no dividers");
assert.ok(!el.hasAttribute("data-narrow"), "a wide desk is not narrow in focus mode");

// Narrow too: the focused pane, not the last, is the one shown.
width = 500;
hook._layout();
assert.ok(el.hasAttribute("data-narrow"));
assert.match(sheet(), /\[data-pane-index="2"\] \{ display: flex; width: 100%/);

// ── Off: laid out as before ─────────────────────────────────────────────────
width = 1300;
el.removeAttribute("data-focus-mode");
panesOf()[2].removeAttribute("data-desk-focused");
await tick();
assert.doesNotMatch(sheet(), /#desk-panes > \[data-pane-index\] \{ display: none; \}/, "the panes show again");
assert.deepEqual(strips(), before.strips, "the same strips");
assert.equal(separators(), before.separators, "the same dividers");

console.log("ok — __desk_focus_mode");
