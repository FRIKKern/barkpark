// __picker_reference_hit_preview.test.mjs — task-75cb2cac1e875214: three
// products named "Eventyrnettene" read the same in the reference picker. The
// picker now asks the search for `preview=1` and draws each hit's list preview
// (thumbnail, subtitle, description) the way the desk row does; a hit with no
// preview stays the bare title.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node src/__picker_reference_hit_preview.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;

const urls = [];
globalThis.fetch = window.fetch = async (url) => {
  urls.push(String(url));
  return {
    ok: true,
    json: async () => ({
      documents: [
        {
          _id: "p1",
          _type: "product",
          title: "Eventyrnettene",
          _preview: {
            subtitle: "9788205627765 · Bok",
            description: "Kari Nord (forfatter)",
            media: "https://media.example/p1.jpg",
          },
        },
        { _id: "p2", _type: "product", title: "Eventyrnettene", _preview: { subtitle: "9788205627772 · E-bok" } },
        { _id: "p3", _type: "product", title: "Uten forhåndsvisning" },
      ],
    }),
  };
};

await import("../../../priv/static/assets/bp-reference-picker.js");

try {
  const picker = document.createElement("bp-reference-picker");
  picker.setAttribute("ref-type", "product");
  document.body.appendChild(picker);
  await new Promise((r) => setTimeout(r, 10));

  picker.querySelector(".bp-ref-search-input").focus();
  await picker._search("Eventyrnettene");

  const search = urls.find((u) => u.includes("/v1/data/search/"));
  assert.ok(search && new URL(search, "http://localhost").searchParams.get("preview") === "1", "the search asks for previews");

  const items = [...picker.querySelectorAll(".bp-ref-dropdown-item")];
  assert.equal(items.length, 3);

  const subs = (el) => [...el.querySelectorAll(".bp-ref-hit-sub")].map((s) => s.textContent);
  assert.deepEqual(subs(items[0]), ["9788205627765 · Bok", "Kari Nord (forfatter)"], "subtitle and description lines");
  assert.equal(items[0].querySelector(".bp-ref-hit-media img").getAttribute("src"), "https://media.example/p1.jpg", "the thumbnail");
  assert.deepEqual(subs(items[1]), ["9788205627772 · E-bok"], "a second edition reads differently");
  assert.equal(items[1].querySelector(".bp-ref-hit-media"), null, "no media, no thumbnail box");
  assert.equal(items[2].textContent, "Uten forhåndsvisning", "a hit without a preview is the bare title");
  assert.equal(items[2].classList.contains("bp-ref-hit"), false);

  console.log("reference picker hit preview: all checks passed");
} finally {
  window.close();
}
