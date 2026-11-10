// __desk_slice_tips.test.mjs — the desk's tooltips (task-b0aee855263e29e8,
// /papers/desk-vertical-slice, journey J57): a close link, a strip and the
// separator name what they do in a tooltip, shown after about 400 ms on the
// pointer or on keyboard focus, hidden on leave, blur, Escape, a click, a
// scroll, and when the anchor or the URL goes. Any element in the desk marked
// data-tip="…" (and data-tip-keys="Ctrl+K") gets one with no script change.
// The reference is the TanStack Studio's Tip.tsx (IconTips).
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom,
// on a fake clock (the hook's timers are window.setTimeout).
//
// Run: node ../paper-editor-host-tests/__desk_slice_tips.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post;a`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;

// A fake clock for every timer the hook sets.
let now = 0;
let seq = 0;
const timers = new Map();
window.setTimeout = (fn, ms = 0) => (timers.set(++seq, { fn, at: now + ms }), seq);
window.clearTimeout = (id) => timers.delete(id);
const tick = (ms) => {
  const end = now + ms;
  for (;;) {
    const due = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
    if (!due) break;
    timers.delete(due[0]);
    now = due[1].at;
    due[1].fn();
  }
  now = end;
};
// MutationObserver callbacks are microtasks: let earlier ones run before an assertion.
const settle = () => new Promise((resolve) => setImmediate(resolve));

await import("../../priv/static/assets/bp-desk.js");

const doc = window.document;
doc.body.innerHTML =
  `<button id="outside" data-tip="Not the desk's">x</button>` +
  `<div id="desk-panes">` +
  `<section class="pane-column dk-pane" id="p0" data-pane-index="0" data-pane-kind="types" aria-label="Content"><div class="pane-header"><span class="pane-header-title">Content</span></div><div class="pane-body">` +
  `<a href="${BASE}/post" class="pane-item" aria-current="true" data-desk-row data-desk-opens="list"><span class="pane-item-label">Posts</span></a></div></section>` +
  `<section class="pane-column dk-pane" id="p1" data-pane-index="1" data-pane-kind="list" aria-label="Posts"><div class="pane-header"><span class="pane-header-title">Posts</span>` +
  `<a class="dk-close" href="${BASE}" aria-label="Close Posts"><span aria-hidden="true">×</span></a></div><div class="pane-body">` +
  `<a href="${BASE}/post;a" class="pane-item" data-desk-row data-desk-opens="doc"><span class="pane-item-label">Alpha</span></a>` +
  `<button type="button" id="more" aria-label="More" aria-describedby="hint" data-tip="Show more" data-tip-keys="Ctrl+K">…</button></div></section>` +
  `<section class="pane-column dk-pane dk-doc" id="p2" data-pane-index="2" data-pane-kind="doc" data-pane-editing aria-label="Alpha">` +
  `<a class="dk-close dk-edit-close" href="${BASE}/post" aria-label="Close Alpha"><span aria-hidden="true">×</span></a><div class="pane-body"></div></section>` +
  `</div>`;

const el = doc.getElementById("desk-panes");
let width = 1440;
Object.defineProperty(el, "clientWidth", { get: () => width });
// jsdom lays nothing out: a tip is 80 × 20, and an anchor is where a test puts it.
for (const [name, px] of [["offsetWidth", 80], ["offsetHeight", 20]]) {
  Object.defineProperty(window.HTMLElement.prototype, name, {
    configurable: true,
    get() {
      return this.classList.contains("hover-tip") ? px : 0;
    },
  });
}
const rect = (left, top, w = 24, h = 24) => ({ left, top, right: left + w, bottom: top + h, width: w, height: h, x: left, y: top });
const at = (node, box) => (node.getBoundingClientRect = () => box);

const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();
window.addEventListener("click", (e) => e.preventDefault());

let close = doc.querySelector("#p1 .dk-close");
const editClose = doc.querySelector("#p2 .dk-edit-close");
const tips = () => doc.querySelectorAll('[role="tooltip"]');
const tip = () => tips()[0] || null;
const pointer = (type, target, init = {}) => {
  const e = new window.MouseEvent(type, { bubbles: true, cancelable: true, ...init });
  Object.defineProperty(e, "pointerType", { value: init.pointerType || "mouse" });
  target.dispatchEvent(e);
  return e;
};
const hover = (target, init) => pointer("pointerover", target, init);
const away = (target, to) => pointer("pointerout", target, { relatedTarget: to || doc.body });
const key = (name) => {
  const e = new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true });
  (doc.activeElement || doc.body).dispatchEvent(e);
  return e;
};
const shown = async (anchor, how = hover) => {
  how(anchor);
  tick(400);
  await settle();
  return tip();
};
// Between steps the pointer leaves every control and the focus goes to the page.
const reset = async () => {
  for (const node of doc.querySelectorAll("[data-tip], a.dk-close")) away(node);
  if (doc.activeElement && doc.activeElement !== doc.body) doc.activeElement.blur();
  await settle();
  tick(1000);
  assert.equal(tips().length, 0, "nothing shown between steps");
};

// ── A close link on the pointer: after 400 ms, its own name, on <body> ───────
at(close, rect(100, 50));
hover(close.firstElementChild);
tick(399);
assert.equal(tip(), null, "not before about 400 ms");
tick(1);
assert.ok(tip(), "shown 400 ms after the pointer arrived");
assert.equal(tip().textContent, "Close Posts", "the tip says what the link does (its aria-label)");
assert.equal(tip().parentNode, doc.body, "drawn on <body>: a pane's scroll box never clips it");
assert.ok(tip().classList.contains("hover-tip"));
assert.equal(tip().style.position, "fixed");
assert.ok(tip().id, "the tip has an id");
assert.equal(close.getAttribute("data-tip"), "Close Posts", "the close link carries data-tip, from its aria-label");
// Placed 4 px under the anchor, centred on it.
assert.equal(tip().style.left, "72px");
assert.equal(tip().style.top, "78px");
// The tip says what the name says: it is not read a second time (Tip.tsx IconTips).
assert.equal(close.getAttribute("aria-describedby"), null);
// Moving within the link keeps it; leaving hides it.
away(close.firstElementChild, close);
assert.ok(tip(), "moving onto the link's own child is not leaving");
away(close);
assert.equal(tip(), null, "leaving the link hides the tip");
tick(1000);
assert.equal(tip(), null, "and it does not come back");

// ── Placement: above near the bottom, kept 4 px inside the window ───────────
at(close, rect(100, 700));
assert.equal((await shown(close)).style.top, `${700 - 4 - 20}px`, "near the bottom it sits 4 px over the anchor");
await reset();
at(close, rect(1000, 50));
assert.equal((await shown(close)).style.left, `${1024 - 4 - 80}px`, "at the right edge it stays 4 px inside the window");
await reset();
at(close, rect(-10, 50));
assert.equal((await shown(close)).style.left, "4px", "at the left edge too");
await reset();
at(close, rect(100, 50));

// ── Keyboard focus shows it; Escape hides it and does nothing else ─────────
close.focus();
tick(400);
assert.equal(tip()?.textContent, "Close Posts", "keyboard focus shows the tip");
const esc = key("Escape");
assert.equal(tip(), null, "Escape hides it");
assert.ok(!esc.defaultPrevented, "Escape is not taken from the page");
assert.equal(doc.activeElement, close, "the focus stays where it was");
assert.ok(doc.getElementById("p1"), "the pane is still open");
tick(1000);
assert.equal(tip(), null);
close.blur();
await settle();
// Blur hides it.
close.focus();
tick(400);
assert.ok(tip());
close.blur();
assert.equal(tip(), null, "blur hides the tip");
// Focus a click gave is not keyboard focus (jsdom matches :focus-visible on every focus).
const own = close.matches;
close.matches = function (selector) {
  return selector === ":focus-visible" ? false : own.call(this, selector);
};
close.focus();
tick(1000);
assert.equal(tip(), null, "focus from a click shows no tip");
close.matches = own;
await reset();

// Put away by Escape, it stays away while the pointer is still on the link.
await shown(close);
key("Escape");
hover(close.firstElementChild);
tick(1000);
assert.equal(tip(), null, "dismissed: moving over the link does not bring it back");
away(close);
assert.ok(await shown(close), "after leaving, the next hover shows it again");
await reset();

// ── A press, a click, a scroll hide it; a press cancels one on its way ───────
await shown(close);
pointer("pointerdown", close);
assert.equal(tip(), null, "a press hides the tip");
await reset();
await shown(close);
close.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
assert.equal(tip(), null, "a click (Enter on the link) hides it");
await reset();
hover(close);
tick(200);
pointer("pointerdown", close);
tick(1000);
assert.equal(tip(), null, "a press before the 400 ms cancels the tip");
await reset();
await shown(close);
doc.querySelector("#p1 .pane-body").dispatchEvent(new window.Event("scroll"));
assert.equal(tip(), null, "a scroll inside the desk hides it");
await reset();

// ── Never for a finger ──────────────────────────────────────────────────────
hover(close, { pointerType: "touch" });
tick(1000);
assert.equal(tip(), null, "a touch pointer gets no tip");

// ── The anchor leaves the page, or the URL changes ──────────────────────────
at(editClose, rect(900, 50));
assert.equal((await shown(editClose)).textContent, "Close Alpha", "the editor pane's close link has one too");
const p2 = doc.getElementById("p2");
p2.remove();
await settle();
assert.equal(tip(), null, "its pane closed: the tip goes with it");
el.appendChild(p2);
await settle();
await reset();
await shown(close);
window.history.pushState({}, "", `${BASE}/post`);
window.dispatchEvent(new window.Event("popstate"));
assert.equal(tip(), null, "the URL changed (Back): the tip is gone");
await reset();
await shown(close);
window.history.replaceState({}, "", `${BASE}/post;a`);
window.dispatchEvent(new window.Event("phx:page-loading-stop"));
assert.equal(tip(), null, "the URL changed (a patch): the tip is gone");
await reset();
hover(close);
doc.getElementById("p1").remove();
await settle();
tick(1000);
assert.equal(tip(), null, "an anchor that left before the 400 ms shows nothing");

// ── data-tip on anything in the desk; keys as <kbd>; only one tip ───────────
el.insertBefore(
  doc.createRange().createContextualFragment(
    `<section class="pane-column dk-pane" id="p1" data-pane-index="1" data-pane-kind="list" aria-label="Posts"><div class="pane-header"><span class="pane-header-title">Posts</span>` +
      `<a class="dk-close" href="${BASE}" aria-label="Close Posts"><span aria-hidden="true">×</span></a></div><div class="pane-body">` +
      `<a href="${BASE}/post;a" class="pane-item" data-desk-row data-desk-opens="doc"><span class="pane-item-label">Alpha</span></a>` +
      `<button type="button" id="more" aria-label="More" aria-describedby="hint" data-tip="Show more" data-tip-keys="Ctrl+K">…</button></div></section>`
  ),
  doc.getElementById("p2")
);
await settle();
const more = doc.getElementById("more");
at(more, rect(300, 300));
const t = await shown(more);
assert.equal(t.querySelector(".tip-line").firstChild.textContent, "Show more", "a data-tip button needs no script of its own");
assert.deepEqual([...t.querySelectorAll("kbd")].map((k) => k.textContent), ["Ctrl", "K"], "its keys are <kbd> parts");
assert.equal(more.getAttribute("aria-describedby"), `hint ${t.id}`, "a tip that says more than the name describes the button");
close = doc.querySelector("#p1 .dk-close");
at(close, rect(100, 50));
hover(close);
tick(400);
assert.equal(tips().length, 1, "one tip at a time");
assert.equal(more.getAttribute("aria-describedby"), "hint", "and the one before let go of its button");
await reset();
hover(doc.getElementById("outside"));
tick(1000);
assert.equal(tip(), null, "outside the desk is not the desk's");

// ── A strip and the separator ───────────────────────────────────────────────
const sep = el.querySelector(".pane-resizer");
assert.ok(sep, "a separator is laid out");
at(sep, rect(400, 60, 6, 700));
assert.equal((await shown(sep)).textContent, "Resize pane", "the separator says what it does");
const was = tip().style.left;
at(sep, rect(416, 60, 6, 700));
hook._layout();
assert.equal(parseFloat(tip().style.left), parseFloat(was) + 16, "a separator moved by the keys takes its tip along");
await reset();
width = 800;
hook._layout();
await settle();
const strip = doc.querySelector("#desk-panes > [data-pane-collapsed]");
assert.ok(strip, "at 800 px a pane is a strip");
at(strip, rect(0, 60, 51, 700));
assert.equal((await shown(strip)).textContent, "Expand Content", "a strip says it expands");
const right = tip();
assert.ok(parseFloat(right.style.left) >= 51 + 4 && parseFloat(right.style.top) >= 4, "beside the strip, inside the window");
await reset();
// Reached by the keyboard and opened with Enter: the strip's tip goes with the strip.
strip.focus();
tick(400);
assert.equal(tip()?.textContent, "Expand Content", "keyboard focus on a strip shows its tip");
strip.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
await settle();
assert.equal(tip(), null, "Enter opened the strip: its tip is gone");
width = 1440;
hook._layout();
await settle();
assert.equal(strip.hasAttribute("data-tip"), false, "an open pane is not an anchor");
hover(strip.querySelector("a[data-desk-row]"));
tick(1000);
assert.equal(tip(), null, "so a row inside it shows no strip tip");

// ── The tip reads in both themes: tokens only ───────────────────────────────
const css = doc.getElementById("bp-desk-layout").textContent;
const rule = css.split("\n").find((line) => line.includes(".hover-tip {"));
assert.ok(rule, "the tip's rules ride the desk's own stylesheet");
assert.match(rule, /background: var\(--/);
assert.match(rule, /color: var\(--/);
assert.doesNotMatch(rule, /#[0-9a-f]{3,6}\b|rgb\(/i, "no hand-picked colour");

// ── destroyed() leaves nothing behind ──────────────────────────────────────
await shown(close);
hook.destroyed();
assert.equal(tips().length, 0, "the tip goes with the hook");
hook.mounted();
hover(more);
hook.destroyed();
tick(1000);
assert.equal(tips().length, 0, "and a tip on its way never lands");
hover(close);
close.focus();
tick(1000);
assert.equal(tips().length, 0, "no listener is left");
console.log("desk slice tips: ok");
window.close();
