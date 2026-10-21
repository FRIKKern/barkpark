// __picker_reference_hit_type_icon.test.mjs — task-835fe5219585ca80: Sanity
// draws a hit's type icon when the hit has no media. Studio stamps a
// {type => svg} map on the shell (`data-type-icons`); a hit with media keeps
// its thumbnail, a hit with no media draws its type's icon, and a type with
// no icon keeps the old row.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node src/__picker_reference_hit_type_icon.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const icons = { widget: '<svg data-desk-icon="basket"></svg>' };
const dom = new JSDOM(
  `<!doctype html><html><body><div data-type-icons='${JSON.stringify(icons)}'></div></body></html>`,
  { url: "http://localhost/" },
);
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;

globalThis.fetch = window.fetch = async () => ({
  ok: true,
  json: async () => ({
    documents: [
      { _id: "w1", _type: "widget", title: "With media", _preview: { media: "https://media.example/w1.jpg" } },
      { _id: "w2", _type: "widget", title: "No media", _preview: { subtitle: "Sub" } },
      { _id: "w3", _type: "widget", title: "No preview" },
      { _id: "g1", _type: "gadget", title: "No icon" },
    ],
  }),
});

await import("../../../priv/static/assets/bp-reference-picker.js");

try {
  const picker = document.createElement("bp-reference-picker");
  picker.setAttribute("ref-type", "widget,gadget");
  document.querySelector("[data-type-icons]").appendChild(picker);
  await new Promise((r) => setTimeout(r, 10));

  picker.querySelector(".bp-ref-search-input").focus();
  await picker._search("no");

  const items = [...picker.querySelectorAll(".bp-ref-dropdown-item")];
  assert.equal(items.length, 4);

  assert.ok(items[0].querySelector(".bp-ref-hit-media img"), "media keeps its thumbnail");
  assert.equal(items[0].querySelector(".bp-ref-hit-icon"), null, "no icon beside a thumbnail");

  for (const item of [items[1], items[2]]) {
    const icon = item.querySelector(".bp-ref-hit-media.bp-ref-hit-icon svg");
    assert.ok(icon, "a hit with no media draws its type's icon");
    assert.equal(icon.getAttribute("data-desk-icon"), "basket");
  }

  assert.equal(items[3].querySelector(".bp-ref-hit-media"), null, "a type with no icon keeps its row");
  assert.equal(items[3].classList.contains("bp-ref-hit"), false);

  console.log("reference picker hit type icon: all checks passed");
} finally {
  window.close();
}
