// __rte_preview_strings.test.mjs — task-d1c2ef3924bde715: the rich-text
// toolbar ("Bold", "Italic", "Link", "Set", "Remove") and the document preview
// ("No document selected", "Title", "Contributors", …) were English in a
// Norwegian Studio. Both read the map the server stamps as data-strings; with
// none they read English as before, and a translation is text, never markup.
//
// Runs the TRACKED static assets under jsdom.
//
// Run: node src/__rte_preview_strings.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
window.document.execCommand = () => true;
await import("../../../priv/static/assets/bp-rich-text-editor.js");
await import("../../../priv/static/assets/bp-document-preview.js");

function toolbar(strings) {
  const el = document.createElement("bp-rich-text-editor");
  if (strings) el.setAttribute("data-strings", JSON.stringify(strings));
  document.body.appendChild(el);
  const out = {
    bold: el.querySelector('[data-cmd="bold"]').title,
    link: el.querySelector(".bp-rte-link").title,
    set: el.querySelector(".bp-rte-set").textContent,
    remove: el.querySelector(".bp-rte-unset").textContent,
  };
  el.remove();
  return out;
}

function preview(strings, doc) {
  const el = document.createElement("bp-document-preview");
  if (strings) el.setAttribute("data-strings", JSON.stringify(strings));
  if (doc) {
    el.setAttribute("schema-name", "book");
    el.setAttribute("document-json", JSON.stringify(doc));
  }
  document.body.appendChild(el);
  const text = el.innerText ?? el.textContent;
  const html = el.innerHTML;
  el.remove();
  return { text, html };
}

try {
  assert.deepEqual(toolbar({ "Bold (mod+B)": "Fet (Cmd/Ctrl+B)", Link: "Lenke", Set: "Bruk", Remove: "Fjern" }), {
    bold: "Fet (Cmd/Ctrl+B)",
    link: "Lenke",
    set: "Bruk",
    remove: "Fjern",
  });
  assert.deepEqual(toolbar(null), { bold: "Bold (mod+B)", link: "Link", set: "Set", remove: "Remove" });
  assert.equal(toolbar({ Remove: '"><img src=x>' }).remove, '"><img src=x>', "a translation is text");

  assert.match(preview({ "No document selected": "Ingen dokument valgt" }, null).text, /Ingen dokument valgt/);
  assert.match(preview(null, null).text, /No document selected/);
  const nb = preview({ Title: "Tittel", "Full content (JSON)": "Hele innholdet (JSON)" }, { _id: "b1", title: "Fjell" });
  assert.match(nb.text, /Tittel/);
  assert.match(nb.text, /Hele innholdet \(JSON\)/);
  assert.doesNotMatch(preview({ "No document selected": "<b>x</b>" }, null).html, /<b>x<\/b>/, "a translation is text");

  console.log("rich text + preview strings: all checks passed");
} finally {
  window.close();
}
