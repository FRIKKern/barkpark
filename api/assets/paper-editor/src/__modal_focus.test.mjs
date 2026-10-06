// task-0ad7fed4370a5978: Studio's role=dialog modals are aria-modal, yet none
// took focus, so Tab walked the page behind them. Hooks.ModalFocus (inline in
// root.html.heex) moves focus in, keeps Tab inside, and gives it back on close.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
const start = root.indexOf("Hooks.ModalFocus = {");
assert.ok(start > 0, "root.html.heex defines Hooks.ModalFocus");
const end = root.indexOf("\n    };", start);
const source = root.slice(start + "Hooks.ModalFocus = ".length, end + "\n    }".length);

const dom = new JSDOM(`<main><button id="trigger">Share</button><button id="behind">Behind</button></main>`, {
  runScripts: "outside-only",
});
const { window } = dom;
const { document } = window;
const hookDef = window.eval(`(${source})`);
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

console.log("ok modal focus: focus in, preferred control, Tab wraps, restored on close");
window.close();
