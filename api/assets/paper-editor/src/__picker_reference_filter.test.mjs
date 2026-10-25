// __picker_reference_filter.test.mjs — task-281dfb5b6e350517: Hovedarrangement
// offered every event. A reference field now declares a GROQ filter
// (options.filter); the picker searches as before, asks the GROQ endpoint which
// hits the filter matches, and lists only those. Its parameters come from the
// wrapper's data-filter-params, which LiveView keeps current. A failed filter
// read lists nothing.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node src/__picker_reference_filter.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;

let groqOk = true;
const urls = [];
globalThis.fetch = window.fetch = async (url) => {
  const u = new URL(String(url), "http://localhost");
  urls.push(u);
  if (u.pathname.includes("/data/query/")) {
    if (!groqOk) return { ok: false, json: async () => ({}) };
    return { ok: true, json: async () => ({ result: ["drafts.ev-parent", "ev-parent-2"] }) };
  }
  return {
    ok: true,
    json: async () => ({
      documents: [
        { _id: "drafts.ev-parent", _type: "event", title: "Litteraturfestivalen" },
        { _id: "ev-child", _type: "event", title: "Litteraturfestivalen: dag 1" },
        { _id: "ev-parent-2", _type: "event", title: "Bokhøst" },
      ],
    }),
  };
};

await import("../../../priv/static/assets/bp-reference-picker.js");

function mount(attrs, params) {
  document.body.innerHTML = "";
  const wrap = document.createElement("div");
  if (params) wrap.setAttribute("data-filter-params", JSON.stringify(params));
  const picker = document.createElement("bp-reference-picker");
  for (const [k, v] of Object.entries(attrs)) picker.setAttribute(k, v);
  wrap.appendChild(picker);
  document.body.appendChild(wrap);
  return { wrap, picker };
}

const settle = () => new Promise((r) => setTimeout(r, 10));
const titles = (p) => [...p.querySelectorAll(".bp-ref-dropdown-item")].map((b) => b.textContent);

try {
  {
    const { wrap, picker } = mount(
      { "ref-type": "event", "scope-prefix": "/w/gyldendal-no/p/default", filter: "isSeriesParent == true && _id != $self" },
      { self: "ev-open" },
    );
    await settle();
    picker.querySelector(".bp-ref-search-input").focus();
    await picker._search("festival");

    assert.deepEqual(titles(picker), ["Litteraturfestivalen draft", "Bokhøst"], "only hits the filter matches (the first is a draft)");

    const q = urls.find((u) => u.pathname === "/w/gyldendal-no/p/default/v2025-02-19/data/query/production");
    assert.ok(q, "the filter runs on the scoped GROQ endpoint");
    assert.equal(q.searchParams.get("query"), "*[_id in $bpCandidateIds && (isSeriesParent == true && _id != $self)]._id");
    assert.equal(q.searchParams.get("perspective"), "raw");
    assert.deepEqual(JSON.parse(q.searchParams.get("$bpCandidateIds")), ["drafts.ev-parent", "ev-child", "ev-parent-2"]);
    assert.equal(q.searchParams.get("$self"), '"ev-open"');

    const s = urls.find((u) => u.pathname.includes("/v1/data/search/"));
    assert.equal(s.searchParams.get("limit"), "100", "a filtered field searches deeper");

    // LiveView patches the wrapper's data attribute; the next search reads it.
    urls.length = 0;
    wrap.setAttribute("data-filter-params", JSON.stringify({ self: "ev-other" }));
    await picker._search("festival");
    const q2 = urls.find((u) => u.pathname.includes("/data/query/"));
    assert.equal(q2.searchParams.get("$self"), '"ev-other"', "params follow the form");
  }

  {
    groqOk = false;
    const { picker } = mount({ "ref-type": "event", filter: "isSeriesParent == true" });
    await settle();
    picker.querySelector(".bp-ref-search-input").focus();
    await picker._search("festival");
    assert.deepEqual(titles(picker), [], "a failed filter read lists nothing");
    groqOk = true;
  }

  {
    urls.length = 0;
    const { picker } = mount({ "ref-type": "event" });
    await settle();
    picker.querySelector(".bp-ref-search-input").focus();
    await picker._search("festival");
    assert.equal(titles(picker).length, 3, "no filter, every hit");
    assert.equal(urls.some((u) => u.pathname.includes("/data/query/")), false, "and no GROQ read");
  }

  console.log("reference picker filter: all checks passed");
} finally {
  window.close();
}
