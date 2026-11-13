// __desk_slice_narrow.test.mjs — the desk slice in a narrow window, and pane
// resize (task-03fac17d0c33cd32, /papers/desk-vertical-slice).
//
// Below 600 px the desk shows one pane, the last, whose close link (the URL
// without it) reads as Back: the TanStack Studio's NARROW rule. Above it, the
// right edge of an open pane drags to resize it, never under 320 px.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_narrow.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post;post-a`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const KINDS = ["types", "list", "doc"];
const pane = (index, kind) =>
  `<section class="pane-column dk-pane" id="p${index}" data-pane-index="${index}" data-pane-kind="${kind}"><div class="pane-header"><span class="pane-header-title">Pane ${index}</span>` +
  (index > 0 ? `<a class="dk-close" href="${BASE}${index === 2 ? "/post" : ""}"><span>×</span></a>` : "") +
  `</div><div class="pane-body"></div></section>`;
window.document.body.innerHTML = `<div id="desk-panes">${KINDS.map((k, i) => pane(i, k)).join("")}</div>`;
const el = window.document.getElementById("desk-panes");
let width = 590;
Object.defineProperty(el, "clientWidth", { get: () => width });
// jsdom lays nothing out: give each pane a box, 320 px wide, side by side.
const panesOf = () => [...el.children].filter((p) => p.hasAttribute("data-pane-index"));
const edge = (i) => panesOf()[i].nextElementSibling;
panesOf().forEach((p, i) => {
  p.getBoundingClientRect = () => ({ left: i * 320, right: (i + 1) * 320, width: 320, top: 0, bottom: 800, height: 800 });
});
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();
const sheet = () => window.document.getElementById("bp-desk-layout").textContent;

// ── Narrow: one pane, the last, with its close link as the way back ─────────
assert.ok(el.hasAttribute("data-narrow"), "590 px is narrow");
assert.match(sheet(), /#desk-panes > \[data-pane-index\] \{ display: none; \}/, "every pane is hidden…");
assert.match(sheet(), /\[data-pane-index="2"\] \{ display: flex; width: 100%/, "…but the last");
assert.match(sheet(), /\[data-pane-index="2"\] \.dk-close \{ order: -1/, "its close link leads the header");
assert.equal(el.querySelector('[data-pane-index="2"] .dk-close').getAttribute("href"), `${BASE}/post`, "and goes to the URL without the pane");
assert.equal(el.querySelectorAll("[data-pane-collapsed]").length, 0, "nothing is a strip when narrow");

// A drag does nothing when narrow.
const down = (target, x) => target.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, cancelable: true, button: 0, clientX: x }));
const move = (x) => window.dispatchEvent(new window.MouseEvent("pointermove", { clientX: x }));
const up = () => window.dispatchEvent(new window.MouseEvent("pointerup", {}));
assert.equal(el.querySelector('[role="separator"]'), null, "no separator when narrow");
down(panesOf()[1], 638); move(700); up();
assert.doesNotMatch(sheet(), /width: \d+px; min-width: \d+px; flex: 0 0 \d{3}px/);

// A patch rewrites the desk's own attributes: narrow is marked again.
el.removeAttribute("data-narrow");
await new Promise((r) => setTimeout(r, 0));
assert.ok(el.hasAttribute("data-narrow"), "data-narrow comes back after a patch wiped it");
assert.match(sheet(), /\[data-pane-index="2"\] > \.pane-header \{ justify-content: flex-start/, "Back and the title sit together at the start");

// ── The TanStack Studio's panes at five widths (scorecard row 7) ─────────────
// From 600 px up a document beside the strips takes what is left, under its
// 600 px too, as TanStack's: at 640 two strips and a 538 px document, not the
// document alone. The want is TanStack's own rule (barkpark-studio
// app/src/lib/layout.ts `collapsed` and NARROW) run for the same panes:
// "s" a strip, "o" open, "narrow" one pane.
const shapeAt = (w) => {
  width = w;
  hook._layout();
  if (el.hasAttribute("data-narrow")) return "narrow";
  return panesOf().map((p) => (p.hasAttribute("data-pane-collapsed") ? "s" : "o")).join("");
};
const TANSTACK = { 500: "narrow", 640: "sso", 768: "sso", 1000: "soo", 1440: "ooo" };
for (const [w, want] of Object.entries(TANSTACK)) assert.equal(shapeAt(Number(w)), want, `post;post-01 at ${w} px`);
for (const w of [600, 620, 701]) assert.equal(shapeAt(w), "sso", `${w} px: two strips and the document`);
// The document beside a reference: four panes.
el.insertAdjacentHTML("beforeend", pane(3, "doc"));
panesOf()[3].getBoundingClientRect = () => ({ left: 960, right: 1280, width: 320, top: 0, bottom: 800, height: 800 });
const TANSTACK4 = { 500: "narrow", 640: "ssso", 768: "ssso", 1000: "ssso", 1440: "ssoo" };
for (const [w, want] of Object.entries(TANSTACK4)) assert.equal(shapeAt(Number(w)), want, `post;post-01;author at ${w} px`);
panesOf()[3].remove();
shapeAt(702);

// ── 600 to 639 px with lists only: the panes are laid out, never blank ──────
// The Studio shell's phone bucket hides every pane but one there; the desk
// shows its own again.
const doc = panesOf()[2];
el.removeChild(doc);
width = 620;
hook._layout();
assert.ok(!el.hasAttribute("data-narrow"), "two lists fit at 620 px (a strip and a list)");
assert.match(sheet(), /html\[data-width-bucket="phone"\] #desk-panes > \[data-pane-index\]:not\(\[data-desk-leaving\]\) \{ display: flex; \}/, "the shell's phone rule is answered");
assert.doesNotMatch(sheet(), /#desk-panes > \[data-pane-index\] \{ display: none; \}/, "no pane is hidden");
el.appendChild(doc);

// ── Wide again: all panes, an edge to drag ──────────────────────────────────
width = 1440;
hook._layout();
assert.ok(!el.hasAttribute("data-narrow"));
assert.doesNotMatch(sheet(), /display: none/);
assert.match(sheet(), /cursor: col-resize/, "an open pane that is not the last has an edge to drag");

// A press in the middle of a pane is not a drag.
down(panesOf()[1], 480); move(600); up();
assert.doesNotMatch(sheet(), /\[data-pane-index="1"\][^{]*\{ width:/);

// A press on the separator after it is: 80 px right widens the list to 400.
assert.equal(edge(1).getAttribute("role"), "separator");
down(edge(1), 638); move(718);
assert.match(sheet(), /\[data-pane-index="1"\][^{]*\{ width: 400px; min-width: 400px; max-width: none; flex: 0 0 400px; \}/);
// Dragged far left it stops at the minimum.
move(100); up();
assert.match(sheet(), /\[data-pane-index="1"\][^{]*\{ width: 320px;/, "never under 320 px");
// After the release the pointer no longer resizes.
move(900);
assert.match(sheet(), /\[data-pane-index="1"\][^{]*\{ width: 320px;/);

// The last pane has no edge of its own.
assert.equal(edge(2), null);
down(panesOf()[2], 958); move(1100); up();
assert.doesNotMatch(sheet(), /\[data-pane-index="2"\][^{]*\{ width:/);

hook.destroyed();
console.log("desk slice narrow: ok");
window.close();
