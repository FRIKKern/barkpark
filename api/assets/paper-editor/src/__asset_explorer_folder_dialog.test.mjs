// task-3713c75065d471d4: the media library's New folder dialog (role=dialog,
// aria-modal) dropped focus to <body> on close, answered Escape only from its
// text input, let Tab walk out into the page behind it, and titled itself h3
// under the page's h1. Run: node src/__asset_explorer_folder_dialog.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  runScripts: "outside-only",
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
window.fetch = async (url) => ({
  ok: true,
  status: 200,
  json: async () =>
    String(url).includes("/collections") ? { result: { collections: [] } } : { result: { hits: [], total: 0, facets: {} } },
});
window.requestAnimationFrame = (fn) => setTimeout(fn, 0);
for (const file of ["bp-search-intel.js", "bp-asset-explorer.js"]) {
  window.eval(readFileSync(new URL(`../../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}

const tick = (ms = 10) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

const el = window.document.createElement("bp-asset-explorer");
el.setAttribute("scope-prefix", "/w/agency/p/default");
window.document.body.appendChild(el);
await tick(80);

const doc = window.document;
const opener = el.querySelector(".bp-ae-new-collection");
const modal = el.querySelector(".bp-ae-modal");
const key = (target, k, shift = false) =>
  target.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, shiftKey: shift, bubbles: true, cancelable: true }));

async function open() {
  opener.focus();
  opener.click();
  await tick();
  assert.equal(modal.hidden, false, "the dialog opens");
}

await check("the dialog title is an h2", () => {
  assert.equal(el.querySelector("#bp-ae-modal-title").tagName, "H2");
});

await check("Escape from the input closes and returns focus to Ny mappe", async () => {
  await open();
  key(doc.activeElement, "Escape");
  assert.equal(modal.hidden, true);
  assert.equal(doc.activeElement, opener);
});

await check("Escape from Avbryt closes too, and Avbryt returns focus", async () => {
  await open();
  const cancel = el.querySelector(".bp-ae-modal-cancel");
  cancel.focus();
  key(cancel, "Escape");
  assert.equal(modal.hidden, true, "Escape off the input closes the dialog");
  assert.equal(doc.activeElement, opener);
  await open();
  el.querySelector(".bp-ae-modal-cancel").click();
  assert.equal(doc.activeElement, opener);
});

await check("Tab and Shift+Tab stay inside the dialog", async () => {
  await open();
  const input = el.querySelector(".bp-ae-modal-input");
  const submit = el.querySelector(".bp-ae-modal-submit");
  submit.focus();
  key(submit, "Tab");
  assert.equal(doc.activeElement, input, "Tab from the last control wraps to the first");
  key(input, "Tab", true);
  assert.equal(doc.activeElement, submit, "Shift+Tab from the first wraps to the last");
  key(submit, "Escape");
});

console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
