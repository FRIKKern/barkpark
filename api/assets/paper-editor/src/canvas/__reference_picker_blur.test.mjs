// task-99bc7de193ae9efe: the reference field's suggestion list stayed open after
// focus left the field (Tab, Shift+Tab, a click elsewhere), floating over the
// fields below; nothing but Escape inside the field or a pick closed it.
// Run: node src/canvas/__reference_picker_blur.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

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

let hits = [
  { _id: "author-ness", title: "Ingrid Ness" },
  { _id: "author-berg", title: "Ola Berg" },
];
const fetchMock = async (url, options = {}) => {
  if (options.method === "POST") return { ok: true, json: async () => ({}) };
  if (String(url).includes("/v1/data/doc/")) {
    await new Promise((r) => setTimeout(r, 150));
    return { ok: true, json: async () => ({ result: { _id: "author-berg", title: "Ola Berg" } }) };
  }
  return { ok: true, json: async () => ({ searchEventId: "e1", documents: hits }) };
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../../../priv/static/assets/bp-search-intel.js");
globalThis.BpSearchIntel = window.BpSearchIntel;
await import("../../../../priv/static/assets/bp-reference-picker.js");

const picker = document.createElement("bp-reference-picker");
picker.setAttribute("ref-type", "author");
picker.setAttribute("dataset", "production");
document.body.appendChild(picker);
const after = document.createElement("input");
after.id = "after";
document.body.appendChild(after);
const tick = (ms = 400) => new Promise((r) => setTimeout(r, ms));
const list = () => picker.querySelector('[role="listbox"]');
const input = () => picker.querySelector(".bp-ref-search-input");

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

async function openList() {
  input().focus();
  input().value = "e";
  input().dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
}

try {
  await tick(50);

  await check("typing opens the list", async () => {
    await openList();
    assert.equal(list().hidden, false);
    assert.equal(input().getAttribute("aria-expanded"), "true");
  });

  await check("moving focus from the input to an option keeps it open", async () => {
    picker.querySelectorAll('[role="option"]')[0].focus();
    await tick(20);
    assert.equal(list().hidden, false);
  });

  await check("focus leaving the field closes the list", async () => {
    after.focus();
    await tick(20);
    assert.equal(list().hidden, true);
    assert.equal(input().getAttribute("aria-expanded"), "false");
  });

  await check("a search answer that lands after focus left does not reopen it", async () => {
    input().focus();
    input().value = "Ingrid";
    input().dispatchEvent(new window.Event("input", { bubbles: true }));
    after.focus();
    await tick();
    assert.equal(list().hidden, true);
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  harness: ${e.stack}`);
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall reference list blur checks passed");
process.exit(0);
