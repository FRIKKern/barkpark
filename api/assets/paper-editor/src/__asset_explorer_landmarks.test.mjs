// task-0374792cb435a2e3: axe on the media library reported landmark-unique — the
// asset explorer's sidebar <aside>, its three <nav>s and the inspector <aside>
// carried no accessible name, so a screen reader's landmark list could not tell
// them apart. Each now takes the name its visible title gives it, in the Studio
// language (the same data-strings map as the rest of bp-asset-explorer).
// Run: node src/__asset_explorer_landmarks.test.mjs
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

async function mount(strings) {
  const el = window.document.createElement("bp-asset-explorer");
  el.setAttribute("scope-prefix", "/w/agency/p/default");
  if (strings) el.setAttribute("data-strings", JSON.stringify(strings));
  window.document.body.appendChild(el);
  await new Promise((r) => setTimeout(r, 80));
  return el;
}

const landmarks = (el) =>
  [...el.querySelectorAll("aside, nav")].map((n) => ({ role: n.tagName === "NAV" ? "navigation" : "complementary", name: n.getAttribute("aria-label") }));

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

const nb = await mount({ Library: "Bibliotek", Refine: "Avgrens", Collections: "Samlinger", "Asset details": "Fildetaljer" });
const en = await mount(null);

check("every aside and nav in the explorer has a name, distinct within its role", () => {
  for (const el of [nb, en]) {
    const marks = landmarks(el);
    assert.equal(marks.length, 5, `two asides and three navs: ${JSON.stringify(marks)}`);
    for (const m of marks) assert.ok(m.name, `unnamed ${m.role}: ${JSON.stringify(marks)}`);
    for (const role of ["navigation", "complementary"]) {
      const names = marks.filter((m) => m.role === role).map((m) => m.name);
      assert.equal(new Set(names).size, names.length, `${role} names must differ: ${names}`);
    }
  }
});

check("the names follow the Studio language and fall back to English", () => {
  assert.deepEqual(landmarks(nb).map((m) => m.name), ["Bibliotek", "Bibliotek", "Avgrens", "Samlinger", "Fildetaljer"]);
  assert.deepEqual(landmarks(en).map((m) => m.name), ["Library", "Library", "Refine", "Collections", "Asset details"]);
});

console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
