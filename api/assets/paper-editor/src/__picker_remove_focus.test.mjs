// __picker_remove_focus.test.mjs — task-c7f121e3d5cb763b: pressing the media
// picker's Remove button left focus on nothing. The button hides itself once
// the field is empty, so focus fell to <body> and a keyboard user was thrown to
// the top of the page. It now lands on the empty-state card, as the context
// menu's Remove already did.
//
// Mounts the TRACKED static asset api/priv/static/assets/bp-media-picker.js in
// jsdom with an image set, focuses Remove and clicks it.
//
// Run: node src/__picker_remove_focus.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.fetch = window.fetch = async () => ({ ok: false, json: async () => ({}) });

await import("../../../priv/static/assets/bp-media-picker.js");

try {
  const picker = document.createElement("bp-media-picker");
  picker.setAttribute("value", JSON.stringify({ url: "/media/cover.png", assetId: "a1" }));
  document.body.appendChild(picker);

  const remove = picker.querySelector(".bp-mp-clear");
  assert.ok(remove && remove.style.display !== "none", "precondition: an image is set and Remove shows");

  let changed = 0;
  picker.addEventListener("bp-change", () => changed++);

  remove.focus();
  assert.equal(document.activeElement, remove);
  remove.click();

  assert.equal(remove.style.display, "none", "Remove hides once the field is empty");
  assert.ok(changed >= 1, "the value was cleared");
  const card = picker.querySelector(".bp-mp-empty");
  assert.ok(card, "the empty-state card renders");
  assert.notEqual(document.activeElement, document.body, "focus never falls to body");
  assert.equal(document.activeElement, card, "focus lands on the empty-state card");

  console.log("picker remove focus: all checks passed");
} finally {
  window.close();
}
