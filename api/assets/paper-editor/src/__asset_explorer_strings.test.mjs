// task-2bc7975ad3bdb737: the media library (bp-asset-explorer) rendered every
// word in English whatever the workspace's Studio language. It now reads a
// `data-strings` map keyed by the English text (the server stamps
// StudioLocale.component_strings(:asset_explorer)); a key it lacks, or a host
// that stamps nothing, reads the English unchanged.
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
    String(url).includes("/collections")
      ? { result: { collections: [] } }
      : { result: { hits: [], total: 0, facets: {} } },
});
window.requestAnimationFrame = (fn) => setTimeout(fn, 0);
for (const file of ["bp-search-intel.js", "bp-asset-explorer.js"]) {
  window.eval(readFileSync(new URL(`../../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}

const NB = {
  Library: "Bibliotek",
  All: "Alle",
  Images: "Bilder",
  Collections: "Samlinger",
  "All assets": "Alle filer",
  "No folders yet — click + to create one.": "Ingen mapper ennå — klikk + for å opprette en.",
  Upload: "Last opp",
  "Search assets": "Søk i filer",
  "Find assets…  (/ to focus)": "Finn filer …  (/ for å fokusere)",
  "Newest first": "Nyeste først",
  "No assets yet — upload a file to get started.": "Ingen filer ennå — last opp en fil for å komme i gang.",
  "Enter a collection name": "Skriv inn et navn på samlingen",
  "%{count} assets": "%{count} filer",
  "Search: %{value}": "Søk: %{value}",
  // A translation that carries markup must land as text.
  "Select an asset or collection": "<b>Velg</b> en fil",
};

async function mount(strings) {
  const el = window.document.createElement("bp-asset-explorer");
  el.setAttribute("scope-prefix", "/w/agency/p/default");
  if (strings) el.setAttribute("data-strings", JSON.stringify(strings));
  window.document.body.appendChild(el);
  await new Promise((r) => setTimeout(r, 80));
  return el;
}

const text = (el, sel) => (el.querySelector(sel) || {}).textContent;
let ran = 0;
let failures = 0;
function check(name, fn) {
  ran += 1;
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

try {
  const nb = await mount(NB);
  const en = await mount(null);

  check("toolbar and sidebar read the stamped words", () => {
    assert.equal(text(nb, ".bp-ae-sidebar-title"), "Bibliotek");
    assert.equal(text(nb, ".bp-ae-collections-title"), "Samlinger");
    assert.equal(text(nb, ".bp-ae-upload"), "Last opp");
    assert.equal(nb.querySelector(".bp-ae-search").getAttribute("aria-label"), "Søk i filer");
    assert.equal(nb.querySelector(".bp-ae-search").getAttribute("placeholder"), "Finn filer …  (/ for å fokusere)");
    assert.equal(nb.querySelector(".bp-ae-sort option[value='created-desc']").textContent, "Nyeste først");
  });

  check("kind filters and the All assets folder read the stamped words", () => {
    const filters = Array.from(nb.querySelectorAll(".bp-ae-filter")).map((b) => b.textContent);
    assert.deepEqual(filters.slice(0, 2), ["Alle", "Bilder"]);
    // A key the map lacks reads the English.
    assert.equal(filters[2], "Video");
    assert.equal(text(nb, ".bp-ae-collection"), "Alle filer");
    assert.equal(text(nb, ".bp-ae-collections-empty"), "Ingen mapper ennå — klikk + for å opprette en.");
  });

  check("the empty state and the count read the stamped words", () => {
    assert.equal(text(nb, ".bp-ae-empty"), "Ingen filer ennå — last opp en fil for å komme i gang.");
    assert.equal(text(nb, ".bp-ae-count"), "0 filer");
  });

  check("a toast reads the stamped word", () => {
    nb._modalInput.value = "   ";
    nb._submitCollectionModal();
    assert.equal(text(nb, ".bp-ae-toast"), "Skriv inn et navn på samlingen");
  });

  check("a %{slot} is filled with its value", () => {
    assert.equal(nb._pillLabel("q", "fjord"), "Søk: fjord");
  });

  check("a translation with markup is text, not HTML", () => {
    const empty = nb.querySelector(".bp-ae-inspector-empty");
    assert.equal(empty.textContent, "<b>Velg</b> en fil");
    assert.equal(empty.querySelectorAll("b").length, 0);
  });

  // task-9b39b33f9b4e63c2: closed-set facet values (processing, visibility,
  // status) read in the viewer's language; tags and MIME types are data.
  check("closed-set facet values read the stamped words; data facets stay as stored", () => {
    const facets = {
      processing: { ready: 2 },
      visibility: { public: 2 },
      status: { draft: 2 },
      mimeType: { "image/png": 1 },
    };
    const words = (el) => {
      el._facets = facets;
      el._renderFacets();
      return Array.from(el.querySelectorAll(".bp-ae-facet")).map((b) => b.firstChild.textContent.trim());
    };
    nb._strings = null;
    nb.setAttribute("data-strings", JSON.stringify({ ...NB, ready: "klar", public: "offentlig", draft: "utkast" }));
    assert.deepEqual(words(nb).sort(), ["image/png", "klar", "offentlig", "utkast"]);
    assert.deepEqual(words(en).sort(), ["draft", "image/png", "public", "ready"]);
  });

  check("with no data-strings every word is the English", () => {
    assert.equal(text(en, ".bp-ae-sidebar-title"), "Library");
    assert.equal(text(en, ".bp-ae-upload"), "Upload");
    assert.equal(en.querySelector(".bp-ae-search").getAttribute("placeholder"), "Find assets…  (/ to focus)");
    assert.deepEqual(
      Array.from(en.querySelectorAll(".bp-ae-filter")).map((b) => b.textContent),
      ["All", "Images", "Video", "Audio", "Documents", "Other"],
    );
    assert.equal(text(en, ".bp-ae-empty"), "No assets yet — upload a file to get started.");
    assert.equal(text(en, ".bp-ae-count"), "0 assets");
    assert.equal(en._pillLabel("q", "fjord"), "Search: fjord");
    assert.equal(en._countLabel(), "0 assets");
  });

  check("a malformed data-strings reads the English", () => {
    en._strings = null;
    en.setAttribute("data-strings", "{not json");
    assert.equal(en._t("Library"), "Library");
    assert.equal(en._t("%{count} assets", { count: 3 }), "3 assets");
  });

  // task-8d8dabe8b693031d: the lock badge names the holder with the server's
  // fixed words ("you", "another editor") or a display name. The fixed words
  // read in the viewer's language; a name reads as written.
  function lockBadge(el, label) {
    const body = window.document.createElement("div");
    body.innerHTML =
      '<div class="bp-ae-checkout-row"></div><button class="bp-ae-checkout"></button><button class="bp-ae-undo-checkout"></button>';
    el._inspectorBody = body;
    el._assetDetail = { asset: { checkedOutBy: "user:1" }, checkoutLabel: label };
    el._updateCheckoutUI(null);
    return body.querySelector(".bp-ae-checkout-row").textContent.trim();
  }

  check("the lock holder's fixed words are translated, a display name is not", () => {
    const lock = {
      "Checked out by %{who}": "Sjekket ut av %{who}",
      you: "deg",
      "another editor": "en annen redaktør",
    };
    nb._strings = null;
    nb.setAttribute("data-strings", JSON.stringify({ ...NB, ...lock }));
    assert.match(lockBadge(nb, "you"), /Sjekket ut av deg/);
    assert.match(lockBadge(nb, "another editor"), /Sjekket ut av en annen redaktør/);
    assert.match(lockBadge(nb, "Kari Admin"), /Sjekket ut av Kari Admin/);
    en._strings = null;
    en.removeAttribute("data-strings");
    assert.match(lockBadge(en, "you"), /Checked out by you/);
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.message}`);
} finally {
  if (ran !== 10) {
    failures += 1;
    console.log(`FAIL  ran ${ran} of 10 checks`);
  }
  dom.window.close();
  if (failures > 0) {
    console.log(`\n${failures} failing check(s)`);
    process.exit(1);
  }
  console.log("\nPASS asset_explorer_strings: the media library reads its stamped words, English otherwise");
  process.exit(0);
}
