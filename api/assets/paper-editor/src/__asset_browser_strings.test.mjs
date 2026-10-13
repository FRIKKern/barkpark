// __asset_browser_strings.test.mjs — task-50aac4341c9aa36b: "Bla i
// mediebiblioteket" opened an English dialog ("Media library", "Search
// assets…", "No matching assets") in a Norwegian Studio, and the picker's
// context menu was announced as "Image options". The picker now hands its
// stamped media words to BpAssetBrowser.open(); without them the dialog reads
// English as before.
//
// Runs the TRACKED static assets under jsdom.
//
// Run: node src/__asset_browser_strings.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
let failLoad = false;
globalThis.fetch = window.fetch = async () =>
  failLoad ? { ok: false, status: 500, json: async () => ({}) } : { ok: true, json: async () => ({ result: { hits: [] } }) };
await import("../../../priv/static/assets/bp-asset-browser.js");
await import("../../../priv/static/assets/bp-media-picker.js");

const NB = {
  library: "Mediebibliotek",
  search_assets: "Søk i filer",
  search_assets_placeholder: "Søk i medier…",
  close: "Lukk",
  no_matching_assets: "Ingen filer passer",
  loading: "Laster …",
  library_error: "Kunne ikke laste inn mediebiblioteket.",
  image_options: "Bildevalg",
};

const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

function read(browser) {
  return {
    aria: browser.querySelector(".bp-ab-dialog").getAttribute("aria-label"),
    title: browser.querySelector(".bp-ab-title").textContent,
    placeholder: browser.querySelector(".bp-ab-search").placeholder,
    searchAria: browser.querySelector(".bp-ab-search").getAttribute("aria-label"),
    close: browser.querySelector(".bp-ab-close").getAttribute("aria-label"),
    empty: browser.querySelector(".bp-ab-empty").textContent,
    loading: browser.querySelector(".bp-ab-loading").textContent,
  };
}

try {
  const browser = window.BpAssetBrowser.ensure();

  browser.open({ strings: NB });
  await settle();
  assert.deepEqual(read(browser), {
    aria: "Mediebibliotek",
    title: "Mediebibliotek",
    placeholder: "Søk i medier…",
    searchAria: "Søk i filer",
    close: "Lukk",
    empty: "Ingen filer passer",
    loading: "Laster …",
  });
  browser.close();

  // A later opener without words gets the English back, not the last opener's.
  browser.open({});
  await settle();
  assert.deepEqual(read(browser), {
    aria: "Media library",
    title: "Media library",
    placeholder: "Search assets…",
    searchAria: "Search assets",
    close: "Close",
    empty: "No matching assets",
    loading: "Loading…",
  });
  browser.close();

  failLoad = true;
  browser.open({ strings: NB });
  await settle();
  assert.equal(browser.querySelector(".bp-ab-grid-empty").textContent, "Kunne ikke laste inn mediebiblioteket.");
  browser.close();
  failLoad = false;

  // The picker hands its stamped words to the browser it opens.
  const Picker = customElements.get("bp-media-picker");
  const picker = Object.create(Picker.prototype);
  picker._strings = NB;
  picker._dataset = () => "production";
  picker._token = () => "";
  picker._scopePrefix = () => "";
  const realEnsure = window.BpAssetBrowser.ensure;
  let opened = null;
  window.BpAssetBrowser.ensure = () => ({ open: (opts) => (opened = opts) });
  assert.equal(picker._openBrowser(), true);
  assert.equal(opened.strings, NB);
  window.BpAssetBrowser.ensure = realEnsure;

  console.log("asset browser strings: all checks passed");
} finally {
  window.close();
}
