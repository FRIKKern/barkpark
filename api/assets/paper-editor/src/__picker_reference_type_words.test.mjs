// __picker_reference_type_words.test.mjs — task-a3bedc86f8a6a517: the reference
// picker named its type by machine name ("Søk i author…", a pill badge
// "author") although Studio knows what the author called it ("Forfatter").
// The picker now reads the {type => word} map Studio stamps on its shell; with
// no map (the public reader) it reads the raw name as before.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node src/__picker_reference_type_words.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.fetch = window.fetch = async () => ({ ok: true, json: async () => ({ result: { _id: "author-a", title: "Ingrid Ness", _type: "author" } }) });
await import("../../../priv/static/assets/bp-reference-picker.js");

function mount(labels, attrs) {
  document.body.innerHTML = "";
  const shell = document.createElement("div");
  if (labels) shell.setAttribute("data-type-labels", JSON.stringify(labels));
  const picker = document.createElement("bp-reference-picker");
  for (const [k, v] of Object.entries(attrs)) picker.setAttribute(k, v);
  shell.appendChild(picker);
  document.body.appendChild(shell);
  return picker;
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 10));

try {
  const labels = { author: "Forfatter", task: "oppgave" };

  {
    const p = mount(labels, { "ref-type": "author" });
    await settle();
    assert.equal(p.querySelector(".bp-ref-search-input").placeholder, "Search Forfatter…", "the placeholder names the type by its word");
  }

  {
    const p = mount(labels, { "ref-type": "author", value: "author-a" });
    await settle();
    assert.equal(p.querySelector(".ref-selected-type").textContent, "Forfatter", "the pill badge names the type by its word");
  }

  {
    const p = mount(labels, { "ref-type": "author,task" });
    await settle();
    assert.equal(p.querySelector(".bp-ref-search-input").placeholder, "Search Forfatter, oppgave…", "several types read as words");
  }

  {
    const p = mount(null, { "ref-type": "author" });
    await settle();
    assert.equal(p.querySelector(".bp-ref-search-input").placeholder, "Search author…", "no map: the raw name as before");
  }

  console.log("reference picker type words: all checks passed");
} finally {
  window.close();
}
