// __desk_reference_search_order.test.mjs — in the desk's edit pane a typed
// reference search lists its hits as the TanStack Studio's picker does
// (barkpark-studio lib/ref-rank.ts, ref-order.spec.ts): the best matches
// first (each query word that starts a word of the title), then by title
// with numbers in order. Outside the desk the server's order stands.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_reference_search_order.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "EventTarget",
  "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.sessionStorage = window.sessionStorage;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.CSS ||= { escape: (value) => String(value) };

// The server's order: newest first, a draft beside its published twin.
const served = ["Fixture post 30", "Fixture post 05", "Fixture post 2", "Fixture post 10", "Ref scout", "Fixture post 01", "Fixture draft probe"];
const fetchMock = async (url, options = {}) => {
  if (options.method === "POST") return { ok: true, json: async () => ({}) };
  return {
    ok: true,
    json: async () => ({
      searchEventId: "e1",
      documents: served.map((title, i) => ({ _id: "post-" + i, _type: "post", title })),
    }),
  };
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../priv/static/assets/bp-search-intel.js");
globalThis.BpSearchIntel = window.BpSearchIntel;
await import("../../priv/static/assets/bp-reference-picker.js");

const tick = (ms = 50) => new Promise((r) => setTimeout(r, ms));
document.body.innerHTML = `<section class="dk-edit"><div id="desk"></div></section><div id="studio"></div>`;

async function search(where, term) {
  const host = document.getElementById(where);
  host.replaceChildren();
  const picker = document.createElement("bp-reference-picker");
  picker.setAttribute("ref-type", "post");
  host.appendChild(picker);
  const input = picker.querySelector(".bp-ref-search-input");
  input.focus();
  input.value = term;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick(500);
  return [...picker.querySelectorAll('[role="option"]')].map((o) => o.textContent.trim());
}

try {
  assert.deepEqual(
    await search("desk", "Fixture post 0"),
    ["Fixture post 01", "Fixture post 05", "Fixture post 2", "Fixture post 10", "Fixture post 30", "Fixture draft probe", "Ref scout"],
    "all three words first, then two, then one, each by title with numbers in order"
  );
  assert.deepEqual(
    await search("desk", "post 1"),
    ["Fixture post 10", "Fixture post 01", "Fixture post 2", "Fixture post 05", "Fixture post 30", "Fixture draft probe", "Ref scout"],
    "a number word matches by its start"
  );
  // Control: outside the desk the hits stay as the server sent them.
  assert.deepEqual(await search("studio", "Fixture post 0"), served, "the server's order elsewhere");

  console.log("desk reference search order: ok");
  process.exit(0);
} catch (e) {
  console.error(e);
  process.exit(1);
}
