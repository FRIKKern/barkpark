// task-e73be8429cfa08af: a dataset picked in the scope switcher navigates, and
// focus landed on <body>. root.html.heex arms a one-shot flag on the pick and
// focuses the scope trigger once the navigation lands.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url), "utf8");
const start = root.indexOf("const BP_SCOPE_FOCUS_KEY");
assert.ok(start > 0, "root.html.heex carries the scope-switch focus block");
const source = root.slice(start, root.indexOf("    let Hooks = {};", start));

const page = (body) => {
  const dom = new JSDOM(`<!doctype html><html><body>${body}</body></html>`, {
    runScripts: "outside-only",
    url: "http://localhost/",
  });
  dom.window.eval(source);
  return dom.window;
};
const chrome = `<button class="scope-title">Agency · Default · production</button>
  <div id="scope-menu" role="group"><button phx-click="scope-menu-ws">Agency</button>
  <button phx-click="scope-open" phx-value-ds="staging">staging</button></div><main><a href="#x">Doc</a></main>`;
const landed = (w) => w.dispatchEvent(new w.Event("phx:page-loading-stop"));

// A dataset pick, then the navigation lands: the trigger has focus, once.
let w = page(chrome);
w.document.querySelector('[phx-value-ds="staging"]').click();
assert.equal(w.sessionStorage.getItem("bp:focus-scope-after-switch"), "1", "a pick arms the flag");
landed(w);
assert.equal(w.document.activeElement, w.document.querySelector(".scope-title"), "the scope trigger has focus after the switch");
assert.equal(w.sessionStorage.getItem("bp:focus-scope-after-switch"), null, "the flag is spent");

// The new view's join re-renders the header right after: the NEW trigger gets
// focus, because focus fell to <body> with the old one.
const tick = (ms) => new Promise((r) => setTimeout(r, ms));
w = page(chrome);
w.document.querySelector('[phx-value-ds="staging"]').click();
landed(w);
const fresh = w.document.createElement("button");
fresh.className = "scope-title";
w.document.querySelector(".scope-title").replaceWith(fresh);
await tick(120);
assert.equal(w.document.activeElement, fresh, "the re-rendered trigger is focused");
// …but a user who moves on inside the window is left alone.
w.document.querySelector("main a").focus();
await tick(120);
assert.equal(w.document.activeElement.tagName, "A", "a user who moved is not pulled back");
await tick(1000);

// The next navigation (no pick) leaves focus alone.
w.document.querySelector("main a").focus();
landed(w);
assert.equal(w.document.activeElement.tagName, "A", "a later navigation does not move focus");

// A workspace preview is not a pick; neither is an ordinary page load.
w = page(chrome);
w.document.querySelector('[phx-click="scope-menu-ws"]').click();
landed(w);
assert.equal(w.document.activeElement, w.document.body, "previewing a workspace arms nothing");

console.log("ok scope switch focus: a dataset pick lands focus on the scope trigger, once");
