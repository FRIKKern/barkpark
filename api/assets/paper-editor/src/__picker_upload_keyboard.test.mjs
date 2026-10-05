// __picker_upload_keyboard.test.mjs — task-5e189863d35ccd80: Upload is reachable
// and operable by keyboard.
//
// Found dogfooding (run7 lane-studio, 2026-10-05): Upload rendered as a <label>
// around a [hidden] file input, neither of which is focusable, so Tab skipped
// it. With an image set it is the only way to choose a new file, so a keyboard
// user had to Remove the image (and its alt/focal metadata) first.
//
// Mounts the TRACKED static asset api/priv/static/assets/bp-media-picker.js in
// jsdom with an image already set, then presses Enter and Space on Upload and
// counts clicks on the file input.
//
// Run: node src/__picker_upload_keyboard.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "Event",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "Node",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.fetch = window.fetch = async () => ({ ok: false, json: async () => ({}) });

await import("../../../priv/static/assets/bp-media-picker.js");

const picker = document.createElement("bp-media-picker");
picker.setAttribute("value", JSON.stringify({ url: "/media/cover.png", assetId: "a1" }));
document.body.appendChild(picker);

const upload = picker.querySelector(".bp-mp-upload");
const input = picker.querySelector('input[type="file"]');
assert.ok(upload, "the default chrome renders Upload");
assert.ok(picker.querySelector(".bp-mp-preview-img, img"), "precondition: an image is set");

assert.equal(upload.tabIndex, 0, "Upload is in the tab order");
assert.equal(upload.getAttribute("role"), "button", "Upload is announced as a button");

let clicks = 0;
input.addEventListener("click", (e) => {
  clicks++;
  e.preventDefault();
});

for (const key of ["Enter", " "]) {
  upload.focus();
  assert.equal(document.activeElement, upload, "Upload takes focus");
  const ev = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
  upload.dispatchEvent(ev);
  assert.ok(ev.defaultPrevented, `${JSON.stringify(key)} is consumed (Space must not scroll)`);
}
assert.equal(clicks, 2, "Enter and Space each open the file dialog");

const tab = new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
upload.dispatchEvent(tab);
assert.equal(clicks, 2, "other keys do not open the dialog");

console.log("PASS  Upload is focusable and Enter/Space open the file dialog");
