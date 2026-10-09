// __tab_keys.test.mjs — task-9bf415c3d78b42d6: the Studio editor's group tab bar said
// role=tab, but ArrowRight on a focused tab did nothing. Runs the TRACKED static asset
// api/priv/static/assets/bp-tab-keys.js under jsdom on a bar shaped like editor.ex's,
// with a click handler standing in for select-group's round-trip.
//
// Run: node src/__tab_keys.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "KeyboardEvent", "HTMLElement", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../../priv/static/assets/bp-tab-keys.js");
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

dom.window.close();
if (failures) {
  console.log(`${failures} failure(s)`);
  process.exit(1);
}
console.log("tab keys passed");
