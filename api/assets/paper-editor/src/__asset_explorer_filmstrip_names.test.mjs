// task-d4619e875ace82ca: each filmstrip item was a button holding only an
// <img alt="">, so it had no accessible name and no selected state.
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
  json: async () => ({ result: { assets: [], collections: [] } }),
});
for (const file of ["bp-search-intel.js", "bp-asset-explorer.js"]) {
  window.eval(readFileSync(new URL(`../../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}

const el = window.document.createElement("bp-asset-explorer");
el.setAttribute("scope-prefix", "/w/agency/p/default");
window.document.body.appendChild(el);
await new Promise((r) => setTimeout(r, 50));

const docs = [
  { _id: "drafts.asset-1", title: "fjord-test.png", bp_asset_kind: "image" },
  { _id: "drafts.asset-2", fileInfo: { originalName: "notes.pdf" }, bp_asset_kind: "document" },
];
el._selected = docs[1];
el._renderFilmstrip(docs);

const items = Array.from(el.querySelectorAll(".bp-ae-strip-item"));
assert.equal(items.length, 2, "the filmstrip rendered both assets");
assert.deepEqual(
  items.map((b) => `${b.getAttribute("aria-label")}=${b.getAttribute("aria-pressed")}`),
  ["fjord-test.png=false", "notes.pdf=true"],
  "each item is named by its asset and says whether it is selected",
);

// A name with markup in it is text, not HTML.
el._renderFilmstrip([{ _id: "a3", title: '"><img src=x onerror=1>', bp_asset_kind: "image" }]);
const evil = el.querySelector(".bp-ae-strip-item");
assert.equal(evil.getAttribute("aria-label"), '"><img src=x onerror=1>');
assert.equal(evil.querySelectorAll("img").length, 1, "the title did not inject an element");

console.log("PASS asset_explorer_filmstrip_names: filmstrip items carry the asset name and selected state");
dom.window.close();
