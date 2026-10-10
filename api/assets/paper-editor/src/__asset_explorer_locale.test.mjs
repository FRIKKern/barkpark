// task-114329329fc3bd37: the media library formatted file sizes with toFixed and
// dates with a bare toLocaleString(), so an nb-NO Studio showed "33.1 KB" and
// "06/10/2026, 05:59:23" in the browser's locale. Sizes, dates and counts now read
// in the page's language (<html lang>), the date in the shape Hooks.LocalTime gives
// the history list. An English page keeps its decimal point.
process.env.TZ = "Europe/Oslo";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const SOURCE = ["bp-search-intel.js", "bp-asset-explorer.js"].map((file) =>
  readFileSync(new URL(`../../../priv/static/assets/${file}`, import.meta.url), "utf8"),
);
const UPDATED = "2026-10-06T03:59:23Z";
const DATE_SHAPE = {
  day: "2-digit", month: "short", year: "numeric",
  hour: "2-digit", minute: "2-digit", second: "2-digit",
};
const DOC = {
  _id: "a1",
  title: "cover.jpg",
  _updatedAt: UPDATED,
  bp_asset_kind: "image",
  fileInfo: { size: 33894, mimeType: "image/jpeg", originalName: "cover.jpg" },
};

async function explorer(lang) {
  const dom = new JSDOM(`<!doctype html><html lang="${lang}"><body></body></html>`, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    url: "http://localhost/",
  });
  const { window } = dom;
  window.fetch = async (url) => ({
    ok: true,
    status: 200,
    json: async () =>
      String(url).includes("/collections")
        ? { result: { collections: [] } }
        : { result: { hits: [], total: 0, facets: {} } },
  });
  window.requestAnimationFrame = (fn) => setTimeout(fn, 0);
  for (const src of SOURCE) window.eval(src);
  const el = window.document.createElement("bp-asset-explorer");
  el.setAttribute("scope-prefix", "/w/agency/p/default");
  window.document.body.appendChild(el);
  await new Promise((r) => setTimeout(r, 80));
  await el._renderAssetInspector(DOC);
  const meta = {};
  const dl = el.querySelector(".bp-ae-meta");
  const dts = Array.from(dl.querySelectorAll("dt"));
  dts.forEach((dt) => (meta[dt.textContent] = dt.nextElementSibling.textContent));
  return { el, meta };
}

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

try {
  const nb = await explorer("nb-NO");
  const en = await explorer("en");

  check("an nb-NO page shows the size with a decimal comma", () => {
    assert.equal(nb.meta.Size, "33,1 KB");
  });
  check("an nb-NO page shows the date in the history list's shape", () => {
    assert.equal(nb.meta.Updated, new Intl.DateTimeFormat("nb-NO", DATE_SHAPE).format(new Date(UPDATED)));
    assert.match(nb.meta.Updated, /okt\./);
  });
  check("an English page keeps the decimal point", () => {
    assert.equal(en.meta.Size, "33.1 KB");
    assert.equal(en.meta.Updated, new Intl.DateTimeFormat("en", DATE_SHAPE).format(new Date(UPDATED)));
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  harness: ${e.stack}`);
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall asset explorer locale checks passed");
process.exit(0);
