// task-ab4fcde6ac800741: Change replaced the chosen reference with an empty
// search and nothing brought it back: Escape only closed the list, there was
// no Cancel, and the field showed a blank search over a value it still held.
// A title that resolved after load also re-rendered the pill and dropped a
// keyboard user's focus from Change to the page.
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
const tick = (ms = 400) => new Promise((r) => setTimeout(r, ms));
const key = (el, k) =>
  el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
const button = (label) => Array.from(picker.querySelectorAll("button")).find((b) => b.textContent === label);
const emitted = [];
picker.addEventListener("bp-change", (e) => emitted.push(e.detail.value));

// Pick "Ola Berg" by keyboard, as a user would, so the field holds a pick.
async function pickBerg() {
  const input = picker.querySelector(".bp-ref-search-input");
  input.focus();
  input.value = "e";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
  picker.querySelectorAll('[role="option"]')[1].click();
  await tick(50);
}

try {
  await tick(50);
  await pickBerg();
  assert.equal(picker.value, "author-berg");
  assert.equal(button("Cancel"), undefined, "an empty field offers no Cancel");
  emitted.length = 0;

  // Change, then Escape: the first Escape closes an open list, the next one
  // restores the pick and returns focus to Change.
  button("Change").click();
  const input = picker.querySelector(".bp-ref-search-input");
  assert.equal(document.activeElement, input, "Change focuses the search");
  input.value = "e";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
  assert.equal(picker.querySelector('[role="listbox"]').hidden, false, "the list is open");
  key(input, "Escape");
  assert.equal(picker.querySelector('[role="listbox"]').hidden, true, "the first Escape closes the list");
  assert.equal(document.activeElement, input, "and stays in the search");
  key(input, "Escape");
  assert.equal(picker.value, "author-berg", "the second Escape restores the pick");
  assert.equal(picker.querySelector(".ref-selected-title").textContent, "Ola Berg");
  assert.equal(document.activeElement, button("Change"), "focus returns to Change");

  // Change, then the Cancel button.
  button("Change").click();
  assert.ok(button("Cancel"), "Change offers Cancel");
  button("Cancel").click();
  assert.equal(picker.value, "author-berg", "Cancel restores the pick");
  assert.equal(document.activeElement, button("Change"));
  assert.deepEqual(emitted, [], "a cancelled change emits nothing");

  // Remove forgets the pick: its empty search has no Cancel, and Escape does not resurrect it.
  button("Remove").click();
  await tick(50);
  assert.equal(button("Cancel"), undefined, "after Remove there is nothing to cancel back to");
  key(picker.querySelector(".bp-ref-search-input"), "Escape");
  assert.equal(picker.value, "", "Escape after Remove keeps the field empty");
  assert.deepEqual(emitted, [""]);

  // A new pick after Change replaces the prior one for good.
  await pickBerg();
  button("Change").click();
  hits = [{ _id: "author-ness", title: "Ingrid Ness" }];
  const input3 = picker.querySelector(".bp-ref-search-input");
  input3.value = "n";
  input3.dispatchEvent(new window.Event("input", { bubbles: true }));
  await tick();
  picker.querySelector('[role="option"]').click();
  await tick(50);
  assert.equal(picker.value, "author-ness");
  assert.equal(button("Cancel"), undefined);

  // A stored value's title resolves after the user is already on Change: it
  // lands in place, and focus stays on Change.
  const held = document.createElement("bp-reference-picker");
  held.setAttribute("ref-type", "author");
  held.setAttribute("dataset", "production");
  held.setAttribute("value", "author-berg");
  document.body.appendChild(held);
  await tick(20);
  const heldChange = Array.from(held.querySelectorAll("button")).find((b) => b.textContent === "Change");
  heldChange.focus();
  await tick(300);
  assert.equal(held.querySelector(".ref-selected-title").textContent, "Ola Berg", "the title resolved");
  assert.equal(document.activeElement, heldChange, "focus stays on Change when the title lands");
  held.remove();

  console.log("ok reference picker cancel: Escape and Cancel restore the pick after Change, emit nothing");
} catch (e) {
  console.log("FAIL " + e.message);
  process.exitCode = 1;
} finally {
  picker.remove();
  window.close();
}
