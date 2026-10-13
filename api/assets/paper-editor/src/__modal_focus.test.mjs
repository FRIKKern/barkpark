// task-0ad7fed4370a5978: Studio's role=dialog modals are aria-modal, yet none
// took focus, so Tab walked the page behind them. Hooks.ModalFocus moves focus
// in, keeps Tab inside, and gives it back on close. It lives in
// /assets/bp-modal-focus.js (run-8 dialog sweep), registered by both the
// Studio root layout and the paper layout.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const helper = readFileSync(
  new URL("../../../priv/static/assets/bp-modal-focus.js", import.meta.url),
  "utf8",
);
const root = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
assert.ok(
  root.includes("Hooks.ModalFocus = window.BarkparkModalFocus;"),
  "root.html.heex registers the shared helper as Hooks.ModalFocus",
);

const dom = new JSDOM(`<main><button id="trigger">Share</button><button id="behind">Behind</button></main>`, {
  runScripts: "outside-only",
});
const { window } = dom;
const { document } = window;
window.eval(helper);
const hookDef = window.BarkparkModalFocus;
assert.ok(hookDef && typeof hookDef.mounted === "function", "bp-modal-focus.js defines window.BarkparkModalFocus");
const tab = (shiftKey = false) => {
  const e = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey, bubbles: true, cancelable: true });
  document.activeElement.dispatchEvent(e);
  return e.defaultPrevented;
};
const open = (inner) => {
  const el = document.createElement("div");
  el.setAttribute("role", "dialog");
  el.innerHTML = inner;
  document.body.appendChild(el);
  const hook = Object.assign(Object.create(hookDef), { el });
  hook.mounted();
  return hook;
};

// A destructive dialog opens on its marked Cancel, not on Delete.
document.getElementById("trigger").focus();
let hook = open(
  '<button id="x">×</button><button id="cancel" data-modal-focus>Cancel</button><button id="del">Delete</button>',
);
assert.equal(document.activeElement.id, "cancel", "focus lands on the marked control");

// Tab and Shift+Tab wrap inside; a Tab from outside comes back in.
document.getElementById("del").focus();
assert.ok(tab());
assert.equal(document.activeElement.id, "x", "Tab from the last control wraps to the first");
assert.ok(tab(true));
assert.equal(document.activeElement.id, "del", "Shift+Tab from the first wraps to the last");
document.getElementById("cancel").focus();
assert.equal(tab(), false, "a Tab between inner controls is left to the browser");
document.getElementById("behind").focus();
assert.ok(tab());
assert.equal(document.activeElement.id, "x", "a Tab from behind the dialog comes back in");

// Close: focus returns to the trigger.
hook.el.remove();
hook.destroyed();
assert.equal(document.activeElement.id, "trigger", "closing gives focus back to the trigger");
assert.equal(tab(), false, "the Tab trap is gone after close");

// No marker: the first control. A re-render that drops the focused control
// lands inside again. A trigger LiveView replaced meanwhile is found by id.
hook = open('<button id="close">×</button><form hidden><input id="ghost"></form><input id="email">');
assert.equal(document.activeElement.id, "close", "with no marker, the first control (hidden ones skipped)");
document.getElementById("email").focus();
hook.el.innerHTML = '<button id="close">×</button><input id="link" readonly>';
hook.updated();
assert.equal(document.activeElement.id, "close", "a re-render that removed the focused control lands inside");
const old = document.getElementById("trigger");
const fresh = old.cloneNode(true);
old.replaceWith(fresh);
hook.el.remove();
hook.destroyed();
assert.equal(document.activeElement, fresh, "a replaced trigger is found by its id");

// task-69ef8a4632161f8e: a restore re-renders the editor header, so the id-less
// Historikk button is a new node when the history dialog closes. It is found by its
// phx-click and aria-label, never by a look-alike that says something else.
document.body.insertAdjacentHTML(
  "beforeend",
  '<header><button phx-click="show-history" aria-label="Annet">A</button>' +
    '<button phx-click="show-history" aria-label="Historikk">H</button></header>',
);
document.querySelector('[aria-label="Historikk"]').focus();
hook = open('<button id="restore">Gjenopprett</button>');
assert.equal(document.activeElement.id, "restore");
const header = document.querySelector("header");
const rebuilt = header.cloneNode(true);
header.replaceWith(rebuilt);
hook.el.remove();
hook.destroyed();
assert.equal(
  document.activeElement,
  rebuilt.querySelector('[aria-label="Historikk"]'),
  "a replaced id-less trigger is found by its phx-click and aria-label",
);

// Run-8 dialog sweep: the chat palette's own hook (ChatPalette, on the overlay)
// focuses its input BEFORE ModalFocus mounts on the inner card, so the element
// focused at mount is inside the dialog. Close still returns to the opener.
document.getElementById("trigger").focus();
const overlay = document.createElement("div");
overlay.setAttribute("role", "dialog");
overlay.setAttribute("aria-modal", "true");
overlay.innerHTML = '<div id="card"><input id="palette-input" /></div>';
document.body.appendChild(overlay);
document.getElementById("palette-input").focus();
hook = Object.assign(Object.create(hookDef), { el: overlay.querySelector("#card") });
hook.mounted();
overlay.remove();
hook.destroyed();
assert.equal(
  document.activeElement.id,
  "trigger",
  "focus returns to the opener even when a parent hook moved focus inside first",
);

console.log("ok modal focus: focus in, preferred control, Tab wraps, restored on close");
window.close();
