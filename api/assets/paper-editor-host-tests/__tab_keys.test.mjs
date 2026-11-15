// __tab_keys.test.mjs — task-9bf415c3d78b42d6: the Studio editor's group tab bar said
// role=tab, but ArrowRight on a focused tab did nothing. Runs the TRACKED static asset
// api/priv/static/assets/bp-tab-keys.js under jsdom on a bar shaped like editor.ex's,
// with a click handler standing in for select-group's round-trip.
//
// Run: node ../paper-editor-host-tests/__tab_keys.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "KeyboardEvent", "HTMLElement", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-tab-keys.js");
assert.equal(typeof window.BarkparkTabKeys, "object", "bp-tab-keys.js loaded");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const groups = ["brief", "work", "close", "system"];
document.body.innerHTML =
  `<div class="bp-tab-bar" role="tablist">` +
  groups
    .map(
      (g, i) =>
        `<button type="button" id="bp-group-tab-${g}" role="tab" aria-selected="${i === 0}" ` +
        `aria-controls="editor-form" tabindex="${i === 0 ? 0 : -1}" phx-value-group="${g}">${g}</button>`,
    )
    .join("") +
  `</div><form id="editor-form" role="tabpanel"></form>` +
  `<div role="tablist"><button role="tab" id="other">other</button><button role="tab" id="other2">other2</button></div>`;

const tabs = [...document.querySelectorAll(".bp-tab-bar [role=tab]")];
const selected = [];
// select-group's round-trip, in miniature: the server moves aria-selected/tabindex.
tabs.forEach((tab) =>
  tab.addEventListener("click", () => {
    selected.push(tab.id);
    tabs.forEach((t) => {
      t.setAttribute("aria-selected", String(t === tab));
      t.tabIndex = t === tab ? 0 : -1;
    });
  }),
);
const key = (el, k) => el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true }));

check("ArrowRight focuses and selects the next group", () => {
  tabs[0].focus();
  key(tabs[0], "ArrowRight");
  assert.equal(document.activeElement, tabs[1]);
  assert.deepEqual(selected, ["bp-group-tab-work"]);
  assert.equal(tabs[1].getAttribute("aria-selected"), "true");
});

check("ArrowLeft wraps; End and Home jump", () => {
  key(tabs[1], "ArrowLeft");
  assert.equal(document.activeElement, tabs[0]);
  key(tabs[0], "ArrowLeft");
  assert.equal(document.activeElement, tabs[3]);
  key(tabs[3], "Home");
  assert.equal(document.activeElement, tabs[0]);
  key(tabs[0], "End");
  assert.equal(document.activeElement, tabs[3]);
});

check("other keys pass through and select nothing", () => {
  const before = selected.length;
  key(tabs[3], "a");
  key(tabs[3], "Enter");
  assert.equal(selected.length, before);
});

check("a tablist outside .bp-tab-bar is left alone", () => {
  const other = document.getElementById("other");
  other.focus();
  key(other, "ArrowRight");
  assert.equal(document.activeElement, other);
});

check("an object field's group strip (.bp-obj-tabs) moves and selects too", () => {
  document.body.innerHTML =
    `<div class="bp-field-body"><div class="bp-obj-tabs" role="tablist">` +
    `<button type="button" class="bp-obj-tab" role="tab" data-group="a" aria-selected="true" tabindex="0">A</button>` +
    `<button type="button" class="bp-obj-tab" role="tab" data-group="b" aria-selected="false" tabindex="-1">B</button>` +
    `</div></div>`;
  const [a, b] = document.querySelectorAll(".bp-obj-tab");
  let picked = null;
  b.addEventListener("click", () => (picked = "b"));
  a.focus();
  key(a, "ArrowRight");
  assert.equal(document.activeElement, b);
  assert.equal(picked, "b");
});

// A desk document opened by its URL: the focus goes to the first group tab
// (keyboard.spec.ts J19, task-e7e5aa7938cd5581).
const deskBar =
  `<div data-pane-editing><div class="bp-tab-bar" role="tablist">` +
  `<button type="button" role="tab" id="all" aria-selected="false" tabindex="-1">All fields</button>` +
  `<button type="button" role="tab" id="content" aria-selected="true" tabindex="0">Content</button>` +
  `</div></div>`;
const tick = () => new Promise((r) => setTimeout(r, 0));
async function acheck(name, fn) {
  let stop = null;
  try {
    stop = await fn((s) => (stop = s));
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
  if (typeof stop === "function") stop();
}
const open = () => window.BarkparkTabKeys.openFocus(document, window);
const blur = () => document.activeElement && document.activeElement.blur && document.activeElement.blur();

await acheck("open: the first tab takes the page's focus, whichever is selected", async () => {
  document.body.innerHTML = deskBar;
  blur();
  const stop = open();
  assert.equal(document.activeElement.id, "all");
  return stop;
});

await acheck("open: a bar drawn later takes it; a re-drawn bar takes it again", async () => {
  document.body.innerHTML = "";
  blur();
  const stop = open();
  assert.equal(document.activeElement, document.body);
  document.body.innerHTML = deskBar;
  await tick();
  assert.equal(document.activeElement.id, "all");
  document.body.innerHTML = deskBar;
  await tick();
  assert.equal(document.activeElement.id, "all");
  return stop;
});

await acheck("open: a focus someone holds is left alone", async () => {
  document.body.innerHTML = `<input id="search" />`;
  document.getElementById("search").focus();
  const stop = open();
  document.body.insertAdjacentHTML("beforeend", deskBar);
  await tick();
  assert.equal(document.activeElement.id, "search");
  return stop;
});

await acheck("open: a key ends it", async () => {
  document.body.innerHTML = "";
  blur();
  const stop = open();
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
  document.body.innerHTML = deskBar;
  await tick();
  assert.equal(document.activeElement, document.body);
  return stop;
});

await acheck("open: the old Studio's bar (no edit pane round it) is left alone", async () => {
  document.body.innerHTML = `<div class="bp-tab-bar" role="tablist"><button type="button" role="tab" id="old">Content</button></div>`;
  blur();
  const stop = open();
  await tick();
  assert.equal(document.activeElement, document.body);
  return stop;
});

dom.window.close();
if (failures) {
  console.log(`${failures} failure(s)`);
  process.exit(1);
}
console.log("tab keys passed");
