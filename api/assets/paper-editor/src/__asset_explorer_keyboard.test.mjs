// task-6553d48bdfa3035d: Upload was <label><input type=file hidden></label>.
// A hidden input takes no focus, so Tab skipped it and a keyboard user could
// not upload. The library toggles showed their state only as a CSS class.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  runScripts: "outside-only",
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
window.fetch = async () => ({
  ok: true,
  status: 200,
  json: async () => ({ result: { assets: [], collections: [{ id: "col-1", title: "Covers" }] } }),
});
for (const file of ["bp-search-intel.js", "bp-asset-explorer.js"]) {
  window.eval(readFileSync(new URL(`../../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}

const el = window.document.createElement("bp-asset-explorer");
el.setAttribute("scope-prefix", "/w/agency/p/default");
window.document.body.appendChild(el);
const tick = (ms = 50) => new Promise((r) => setTimeout(r, ms));
await tick();

const pressed = (sel) =>
  Array.from(el.querySelectorAll(sel)).map((b) => `${b.textContent.trim()}=${b.getAttribute("aria-pressed")}`);

// Upload is a real, focusable button that opens the file input.
const upload = el.querySelector(".bp-ae-upload");
assert.equal(upload.tagName, "BUTTON", "Upload is a button, so Tab reaches it");
upload.focus();
assert.equal(window.document.activeElement, upload);
const input = el.querySelector(".bp-ae-upload-input");
let opened = 0;
input.click = () => opened++;
upload.click();
assert.equal(opened, 1, "activating Upload opens the file chooser");

// Choosing files still goes through the same uploader.
const sent = [];
el._uploadFiles = (files) => sent.push(files.map((f) => f.name));
Object.defineProperty(input, "files", {
  configurable: true,
  value: [new window.File(["x"], "a.png", { type: "image/png" })],
});
input.dispatchEvent(new window.Event("change"));
assert.equal(JSON.stringify(sent), JSON.stringify([["a.png"]]), "choosing a file still uploads it");

// Toggles expose their state, and it follows a change.
assert.deepEqual(pressed(".bp-ae-view-btn"), ["Grid=true", "List=false"]);
el.querySelector(".bp-ae-view-list").click();
assert.deepEqual(pressed(".bp-ae-view-btn"), ["Grid=false", "List=true"]);

assert.equal(pressed(".bp-ae-filter")[0], "All=true");
assert.ok(pressed(".bp-ae-filter").slice(1).every((p) => p.endsWith("=false")));
el.querySelector('.bp-ae-filter[data-kind="image"]').click();
await tick();
assert.equal(el.querySelector('.bp-ae-filter[data-kind="image"]').getAttribute("aria-pressed"), "true");
assert.equal(el.querySelector('.bp-ae-filter[data-kind="all"]').getAttribute("aria-pressed"), "false");

assert.deepEqual(pressed(".bp-ae-collection"), ["All assets=true", "Covers=false"]);
el.querySelector('.bp-ae-collection[data-id="col-1"]').click();
await tick();
assert.deepEqual(pressed(".bp-ae-collection"), ["All assets=false", "Covers=true"]);

assert.equal(el.querySelector(".bp-ae-new-collection").getAttribute("aria-label"), "New folder");

console.log("ok asset explorer keyboard: Upload is a button, toggles carry aria-pressed, + is named");
window.close();
