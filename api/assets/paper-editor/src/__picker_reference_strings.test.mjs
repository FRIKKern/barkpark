// __picker_reference_strings.test.mjs — task-4a15ad05b70d29c7: the reference
// picker announced "1 result" and printed its search suggestions ("Recent",
// "Popular", "No matches before", "N searches", "N docs") in English in a
// Norwegian Studio. The words now come from the stamped data-strings map; with
// no map they read English as before.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom and drives the two render methods directly.
//
// Run: node src/__picker_reference_strings.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.fetch = window.fetch = async () => ({ ok: false, json: async () => ({}) });
await import("../../../priv/static/assets/bp-reference-picker.js");
const Picker = customElements.get("bp-reference-picker");
assert.ok(Picker, "bp-reference-picker is defined");

const NB = {
  one_result: "1 treff",
  n_results: "%{count} treff",
  recent: "Nylige",
  popular: "Populære",
  no_matches_before: "Ga ingen treff før",
  one_search: "1 søk",
  n_searches: "%{count} søk",
  one_doc: "1 dokument",
  n_docs: "%{count} dokumenter",
};

function picker(strings) {
  const p = Object.create(Picker.prototype);
  p._strings = strings;
  p._refTypes = ["author"];
  p._dropdown = document.createElement("div");
  p._status = document.createElement("div");
  p._searchInput = null;
  return p;
}

function suggestions(p) {
  p._suggestions = {
    recent: [{ query: "ness", resultCount: 3 }, { query: "hamsun", resultCount: 1 }],
    popular: [{ query: "ibsen", count: 5 }, { query: "undset", count: 1 }],
    nohits: [{ query: "zz", count: 2 }],
  };
  p._renderSuggestDropdown();
  return {
    titles: [...p._dropdown.querySelectorAll(".bp-ref-suggest-title")].map((e) => e.textContent),
    meta: [...p._dropdown.querySelectorAll(".bp-ref-suggest-meta")].map((e) => e.textContent),
  };
}

function announced(p, n) {
  p._renderResultDropdown(Array.from({ length: n }, (_, i) => ({ id: `a${i}`, title: `A ${i}` })));
  return p._status.textContent;
}

try {
  const nb = picker(NB);
  assert.equal(announced(nb, 1), "1 treff");
  assert.equal(announced(nb, 4), "4 treff");
  assert.deepEqual(suggestions(nb), {
    titles: ["Nylige", "Populære", "Ga ingen treff før"],
    meta: ["3 dokumenter", "1 dokument", "5 søk", "1 søk", "2 søk"],
  });

  const en = picker({});
  assert.equal(announced(en, 1), "1 result");
  assert.equal(announced(en, 4), "4 results");
  assert.deepEqual(suggestions(en), {
    titles: ["Recent", "Popular", "No matches before"],
    meta: ["3 docs", "1 doc", "5 searches", "1 search", "2 searches"],
  });

  // A translation is text, never markup.
  const hostile = picker({ recent: "<b>x</b>" });
  assert.equal(suggestions(hostile).titles[0], "<b>x</b>");

  console.log("reference picker strings: all checks passed");
} finally {
  window.close();
}
