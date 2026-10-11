// Run-8 narrow-width pass. At 390px the document actions collapse into
// <bp-overflow-menu>'s "•••" menu, which only a mouse could use: Enter opened
// it with focus left on the trigger, the arrows did nothing, and Tab walked
// past it (the popover sits at the end of <body>). Choosing an item that opens
// a dialog (Slett) then lost focus to <body> on close: the opener was blurred
// by the patch before ModalFocus mounted, and detached when it closed.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const menuSrc = read("../../../priv/static/assets/bp-overflow-menu.js");
const focusSrc = read("../../../priv/static/assets/bp-modal-focus.js");

const dom = new JSDOM(`<main><button id="before">Before</button><div id="slot"></div><button id="after">After</button></main>`, {
  runScripts: "outside-only",
  pretendToBeVisual: true,
});
const { window } = dom;
const { document } = window;
window.ResizeObserver = class { observe() {} disconnect() {} };
window.eval(menuSrc);
window.eval(focusSrc);

const tick = () => new Promise((r) => window.setTimeout(r, 0));
const frame = () => new Promise((r) => window.requestAnimationFrame(() => r()));
const key = (el, k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  el.dispatchEvent(e);
  return e.defaultPrevented;
};
const label = (el) => el && (el.getAttribute("aria-label") || el.id || el.tagName);

// ── The menu ───────────────────────────────────────────────────────────────
const host = document.createElement("bp-overflow-menu");
host.setAttribute("data-label", "Flere handlinger");
const clicked = [];
let activeAtClick = null;
for (const name of ["Publiser", "Dupliser", "Slett"]) {
  const b = document.createElement("button");
  b.setAttribute("aria-label", name);
  b.addEventListener("click", () => {
    clicked.push(name);
    activeAtClick = document.activeElement;
  });
  host.appendChild(b);
}
document.getElementById("slot").appendChild(host);
await tick();

// JSDOM has no layout, so a real _reflow measures 0px and clears every mark.
// Let the one scheduled on connect run, stop further ones, then mark the two
// rightmost as collapsed, as _reflow would at 390px.
await frame();
await frame();
host._scheduleReflow = () => {};
const [, dup, del] = host.querySelectorAll("button[aria-label]");
dup.setAttribute("data-overflowed", "true");
del.setAttribute("data-overflowed", "true");
const trigger = host.querySelector(".bp-overflow-trigger");
assert.ok(trigger, "the host builds its ••• trigger");

trigger.focus();
trigger.click();
await tick();
let pop = document.querySelector(".bp-overflow-popover");
assert.equal(pop.getAttribute("role"), "menu");
assert.equal(label(document.activeElement), "Dupliser", "opening the menu focuses its first item");
assert.equal(document.activeElement.getAttribute("role"), "menuitem");
assert.equal(document.activeElement.getAttribute("tabindex"), "-1", "items rove; Tab does not stop on each");

assert.ok(key(document.activeElement, "ArrowDown"));
assert.equal(label(document.activeElement), "Slett", "ArrowDown moves to the next item");
key(document.activeElement, "ArrowDown");
assert.equal(label(document.activeElement), "Dupliser", "ArrowDown wraps to the first");
key(document.activeElement, "ArrowUp");
assert.equal(label(document.activeElement), "Slett", "ArrowUp wraps to the last");
key(document.activeElement, "Home");
assert.equal(label(document.activeElement), "Dupliser", "Home goes to the first");
key(document.activeElement, "End");
assert.equal(label(document.activeElement), "Slett", "End goes to the last");

key(document.activeElement, "Escape");
assert.equal(document.querySelector(".bp-overflow-popover"), null, "Escape closes the menu");
assert.equal(document.activeElement, trigger, "Escape gives focus back to the trigger");
assert.equal(trigger.getAttribute("aria-expanded"), "false");

assert.ok(key(trigger, "ArrowDown"), "ArrowDown on the trigger is handled");
assert.equal(label(document.activeElement), "Dupliser", "ArrowDown on the trigger opens on the first item");
key(document.activeElement, "Escape");
key(trigger, "ArrowUp");
assert.equal(label(document.activeElement), "Slett", "ArrowUp on the trigger opens on the last item");

assert.equal(key(document.activeElement, "Tab"), false, "Tab is left to the browser");
assert.equal(document.querySelector(".bp-overflow-popover"), null, "Tab closes the menu");
assert.equal(document.activeElement, trigger, "Tab leaves from the trigger, so it moves on in page order");

key(trigger, "ArrowDown");
key(document.activeElement, "ArrowDown");
document.activeElement.click();
assert.deepEqual(clicked, ["Slett"], "an item forwards to its original");
assert.equal(activeAtClick, trigger, "focus is on the trigger, not <body>, when the action runs");

// ── ModalFocus gives focus back to an opener that the patch moved ──────────
const hookDef = window.BarkparkModalFocus;
const openDialog = () => {
  const el = document.createElement("div");
  el.setAttribute("role", "dialog");
  el.setAttribute("aria-modal", "true");
  el.innerHTML = '<button id="cancel" data-modal-focus>Avbryt</button>';
  document.body.appendChild(el);
  const hook = Object.assign(Object.create(hookDef), { el });
  hook.mounted();
  return hook;
};
const closeDialog = (hook) => {
  hook.el.remove();
  hook.destroyed();
};

// Blurred on the way in: focus is on <body> when the dialog mounts.
trigger.focus();
trigger.blur();
assert.equal(document.activeElement, document.body);
let hook = openDialog();
assert.equal(document.activeElement.id, "cancel");
assert.equal(hook._returnTo, trigger, "with focus lost to <body>, the opener is the last focus outside a dialog");

// Detached on the way out: the closing patch strips the trigger and its
// owner puts the same node back a moment later.
trigger.remove();
closeDialog(hook);
assert.equal(document.activeElement, document.body, "nothing to focus while the opener is detached");
host.appendChild(trigger);
await frame();
await frame();
assert.equal(document.activeElement, trigger, "focus returns to the opener once it is back");

// The retry never steals focus that went somewhere on purpose.
trigger.focus();
hook = openDialog();
trigger.remove();
closeDialog(hook);
document.getElementById("after").focus();
host.appendChild(trigger);
await frame();
await frame();
assert.equal(document.activeElement.id, "after", "focus moved meanwhile stays where it went");

console.log("overflow menu keyboard + ModalFocus opener: ok");
