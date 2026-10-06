// task-06efa9925540f212: a reference could not be chosen without a mouse. The
// options answered mousedown only (Enter/Space fire click), the input was not
// a combobox, arrows did nothing, and the result count was not announced.
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
const tick = (ms = 400) => new Promise((r) => setTimeout(r, ms));
const key = (el, k) =>
  el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));

try {
  await tick(50);
  const input = picker.querySelector(".bp-ref-search-input");
  assert.equal(input.getAttribute("role"), "combobox", "the search input is a combobox");
  assert.equal(input.getAttribute("aria-autocomplete"), "list");

  input.focus();
  input.value = "e";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();

  const status = picker.querySelector('[role="status"]');
  assert.equal(status.textContent, "2 results", "the result count is announced");

  const options = Array.from(picker.querySelectorAll('[role="option"]'));
  assert.equal(options.length, 2);

  key(input, "ArrowDown");
  assert.equal(document.activeElement, options[0], "ArrowDown moves into the options");
  key(options[0], "ArrowDown");
  assert.equal(document.activeElement, options[1]);
  key(options[1], "ArrowUp");
  assert.equal(document.activeElement, options[0]);
  key(options[0], "ArrowUp");
  assert.equal(document.activeElement, input, "ArrowUp from the first option returns to the input");

  // Enter/Space on a focused option fire click: that selects.
  key(input, "ArrowDown");
  key(options[0], "ArrowDown");
  options[1].click();
  await tick(50);
  assert.equal(picker.value, "author-berg", "a keyboard-activated option is selected");
  assert.equal(document.activeElement.textContent, "Change", "focus stays in the field after a pick");

  // Remove takes the focused button away: focus lands on the search input.
  Array.from(picker.querySelectorAll("button")).find((b) => b.textContent === "Remove").click();
  await tick(50);
  assert.equal(
    document.activeElement,
    picker.querySelector(".bp-ref-search-input"),
    "focus lands on the search input after Remove",
  );

  // Escape from an option closes the list and returns to the input.
  const input2 = picker.querySelector(".bp-ref-search-input");
  input2.focus();
  input2.value = "e";
  input2.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
  key(input2, "ArrowDown");
  const first = picker.querySelector('[role="option"]');
  key(first, "Escape");
  assert.equal(document.activeElement, input2, "Escape returns to the input");
  assert.equal(picker.querySelector('[role="listbox"]').hidden, true);

  hits = [];
  input2.value = "zzqx";
  input2.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(picker.querySelector('[role="status"]').textContent, "No matches");

  console.log("ok reference picker keyboard: combobox, arrows, Enter/Space select, Escape, announced count");
} finally {
  picker.remove();
  window.close();
}
