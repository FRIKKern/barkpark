// __editor_form_leave.test.mjs — task-8908b6e031268f77: an edit of the editor
// form that has not been posted yet is posted before the pane opens another
// document. The inputs post after a delay (phx-debounce); LiveView posts a
// waiting input at once on its `blur`. A hidden input never blurs, and a text
// input does not when the pane changes with the focus in it (browser Back).
// The page gives each input that changed that `blur` when a LiveView
// navigation starts or something outside the form is pressed.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom. A `blur` listener on each input stands in for LiveView's.
//
// Run: node ../paper-editor-host-tests/__editor_form_leave.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "MouseEvent", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-array-focus.js");

const blurred = [];
function mount() {
  blurred.length = 0;
  document.body.innerHTML =
    `<a id="row" href="#">Another document</a><button id="open" type="button">Open</button>` +
    `<form id="editor-form">` +
    `<input type="text" name="doc[title]" phx-debounce="40">` +
    `<input type="hidden" name="doc[at]" phx-debounce="40">` +
    `<input type="text" name="doc[plain]">` +
    `<button id="inside" type="button">Add row</button></form>` +
    `<form id="other-form"><input type="text" name="q" phx-debounce="40"></form>`;
  const els = {
    title: document.querySelector('[name="doc[title]"]'),
    at: document.querySelector('[name="doc[at]"]'),
    plain: document.querySelector('[name="doc[plain]"]'),
    q: document.querySelector('[name="q"]'),
    row: document.getElementById("row"),
    open: document.getElementById("open"),
    inside: document.getElementById("inside"),
  };
  for (const key of ["title", "at", "plain", "q"]) {
    els[key].addEventListener("blur", () => blurred.push(key));
  }
  return els;
}

const edit = (el) => el.dispatchEvent(new window.Event("input", { bubbles: true }));
const click = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const fire = (name) => window.dispatchEvent(new window.CustomEvent(name, { detail: {} }));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

await check("a press on a row outside the form posts the edits that wait, before the click goes on", () => {
  const els = mount();
  const order = [];
  els.at.addEventListener("blur", () => order.push("post"));
  window.addEventListener("click", () => order.push("liveview click"), { once: true });
  edit(els.title);
  edit(els.at);
  click(els.row);
  assert.deepEqual(blurred.sort(), ["at", "title"]);
  assert.deepEqual(order, ["post", "liveview click"]);
});

await check("a LiveView patch started by the page posts them", () => {
  const els = mount();
  edit(els.at);
  fire("phx:page-loading-start");
  assert.deepEqual(blurred, ["at"]);
});

await check("browser Back or Forward (phx:navigate) posts them", () => {
  const els = mount();
  edit(els.title);
  fire("phx:navigate");
  assert.deepEqual(blurred, ["title"]);
});

await check("an edit is posted once: a second leave finds nothing waiting", () => {
  const els = mount();
  edit(els.at);
  click(els.open);
  fire("phx:page-loading-start");
  click(els.row);
  assert.deepEqual(blurred, ["at"]);
});

await check("a press inside the form leaves the delay alone", () => {
  const els = mount();
  edit(els.title);
  click(els.inside);
  click(els.title);
  assert.deepEqual(blurred, []);
});

await check("an input with no delay, and one of another form, are not touched", () => {
  const els = mount();
  edit(els.plain);
  edit(els.q);
  click(els.row);
  assert.deepEqual(blurred, []);
});

await check("an input whose own delay has posted it is not blurred later", async () => {
  const els = mount();
  edit(els.at);
  await sleep(400);
  click(els.row);
  fire("phx:navigate");
  assert.deepEqual(blurred, []);
});

await check("an input that left the page is not blurred", () => {
  const els = mount();
  edit(els.at);
  els.at.remove();
  click(els.row);
  assert.deepEqual(blurred, []);
});

await check("with nothing waiting a press does nothing", () => {
  mount();
  click(document.getElementById("row"));
  fire("phx:page-loading-start");
  assert.deepEqual(blurred, []);
});

window.close();
if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\neditor form leave: all checks passed");
