// task-0e3b9517b55fa3b9: the media library's asset inspector lists the
// documents that use the selected file ("Used in"), each a link that opens it
// in the Studio, and says "Not used anywhere" when none do.
// bp-asset-explorer-usage.js reads GET …/:id/usage.
// Run: node ../paper-editor-host-tests/__asset_explorer_usage.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  runScripts: "outside-only",
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
const BASE = "/w/agency/p/default/v1/media/production";
const STUDIO = "/w/agency/p/default/d/production/studio";

const hits = [0, 1].map((i) => ({
  id: `blob-${i}`,
  assetDocId: `asset-${i}`,
  originalName: `file-${i}.png`,
  mimeType: "image/png",
  thumbnailUrl: `/media/files/t-${i}.png`,
}));
const usage = {
  "blob-0": {
    documents: [
      { id: "spring", type: "paper", title: "Spring issue", draft: false, published: true },
      { id: "notes", type: "post", title: "Notes", draft: true, published: false },
    ],
    total: 2,
  },
  "blob-1": { documents: [], total: 0 },
};
const asked = [];
const json = (status, body) => ({ ok: status < 400, status, json: async () => body });
window.fetch = async (url) => {
  const path = String(url);
  const m = path.match(/\/(blob-\d)\/usage$/);
  if (m) {
    asked.push(path);
    return json(200, { result: usage[m[1]] });
  }
  if (path.includes("/collections")) return json(200, { result: { collections: [] } });
  if (/\/blob-\d(\?|\/relations)/.test(path)) return json(200, { result: {} });
  return json(200, { result: { hits, total: hits.length, facets: {} } });
};
window.requestAnimationFrame = (fn) => setTimeout(fn, 0);
// jsdom has no layout: selecting scrolls the card into view.
window.HTMLElement.prototype.scrollIntoView = () => {};
for (const file of [
  "bp-search-intel.js",
  "bp-modal-focus.js",
  "bp-asset-explorer-bulk.js",
  "bp-asset-explorer-usage.js",
  "bp-asset-explorer.js",
]) {
  window.eval(readFileSync(new URL(`../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}

const tick = (ms = 40) => new Promise((r) => setTimeout(r, ms));
const el = window.document.createElement("bp-asset-explorer");
el.setAttribute("scope-prefix", "/w/agency/p/default");
el.setAttribute("data-studio-path", STUDIO);
window.document.body.appendChild(el);
await tick(80);

// 1. A used file: one link per document, to the document in the Studio.
el._select(el._assets.find((a) => a._blobId === "blob-0"));
await tick();
assert.deepEqual(asked, [`${BASE}/blob-0/usage`], "the inspector asks the usage route once");
const section = el.querySelector(".bp-ae-inspector-body .bp-ae-usage");
assert.ok(section, "the inspector has a Used in section");
assert.equal(section.querySelector("h3").textContent, "Used in");
const links = Array.from(section.querySelectorAll("a.bp-ae-usage-link"));
assert.deepEqual(
  links.map((a) => [a.textContent, a.getAttribute("href")]),
  [
    ["Spring issue", `${STUDIO}/paper/spring`],
    ["Notes", `${STUDIO}/post/notes`],
  ],
);
const rows = Array.from(section.querySelectorAll("li")).map((li) => li.textContent);
assert.deepEqual(rows, ["Spring issue · paper · Published", "Notes · post · Draft"]);

// 2. An unused file says so, and the first file's list is gone.
el._select(el._assets.find((a) => a._blobId === "blob-1"));
await tick();
const sections = el.querySelectorAll(".bp-ae-inspector-body .bp-ae-usage");
assert.equal(sections.length, 1, "one Used in section per inspector");
assert.equal(sections[0].querySelector(".bp-ae-usage-body").textContent, "Not used anywhere");
assert.equal(sections[0].querySelectorAll("a").length, 0);

console.log("ok asset explorer usage: Used in lists linked documents; an unused file says so");
