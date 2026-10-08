// task-bd90e61ae5f1abd2: the inspector's "Add to collection…" select had no
// accessible name — its first option is a visual placeholder, not a label.
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
await new Promise((r) => setTimeout(r, 80));

el._collections = [{ id: "col-1", title: "Covers", kind: "folder" }];
el._renderAssetInspector({ _id: "asset-1", title: "fjord-test.png", bp_asset_kind: "image" });
await new Promise((r) => setTimeout(r, 20));

const select = el.querySelector(".bp-ae-add-collection");
assert.ok(select, "the inspector offers Add to collection");
assert.equal(select.getAttribute("aria-label"), "Add to collection");

console.log("PASS asset_explorer_add_collection_name: the add-to-collection select is named");
dom.window.close();
