// __picker_search_no_autosave.test.mjs — task-32d983d47299e137: typing "Åpent
// hus" in Hovedarrangement's picker search wrote a draft of the event on every
// keystroke, though nothing was picked. The search box sits inside the editor
// form, and LiveView posts phx-change="autosave" for any input or change event
// that reaches the window from a form control. The search box's events now stop
// at the picker; a pick still reaches the form through bp-change.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-reference-picker.js
// under jsdom.
//
// Run: node src/__picker_search_no_autosave.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "Node", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;

globalThis.fetch = window.fetch = async () => ({
  ok: true,
  json: async () => ({ documents: [{ _id: "ev-open-house", _type: "event", title: "Åpent hus" }] }),
});

await import("../../../priv/static/assets/bp-reference-picker.js");

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

// The editor form, as Studio renders it: the picker inside a form with a
// hidden input. LiveView listens for input and change on the window.
function mount() {
  document.body.innerHTML = "";
  const form = document.createElement("form");
  form.setAttribute("phx-change", "autosave");
  const hidden = document.createElement("input");
  hidden.type = "hidden";
  hidden.name = "doc[parentEvent]";
  form.appendChild(hidden);
  const picker = document.createElement("bp-reference-picker");
  picker.setAttribute("ref-type", "event");
  form.appendChild(picker);
  document.body.appendChild(form);
  return { form, picker };
}

const formEvents = [];
for (const type of ["input", "change"]) {
  window.addEventListener(type, (e) => {
    if (e.target && e.target.form) formEvents.push(`${type}:${e.target.name || "(no name)"}`);
  });
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

await check("typing in the search box sends no input or change event to the form", async () => {
  formEvents.length = 0;
  const { picker } = mount();
  const input = picker.querySelector(".bp-ref-search-input");
  input.focus();
  for (const ch of "Åpent hus") {
    input.value += ch;
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
  }
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.deepEqual(formEvents, []);
});

await check("the search still runs and lists the hit", async () => {
  const { picker } = mount();
  const input = picker.querySelector(".bp-ref-search-input");
  input.focus();
  input.value = "Åpent";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  await wait(450);
  const options = picker.querySelectorAll('[role="option"]');
  assert.equal(options.length, 1);
  assert.match(options[0].textContent, /Åpent hus/);
});

await check("a pick still emits bp-change with the id", async () => {
  const { picker } = mount();
  const seen = [];
  picker.addEventListener("bp-change", (e) => seen.push(e.detail.value));
  const input = picker.querySelector(".bp-ref-search-input");
  input.focus();
  input.value = "Åpent";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  await wait(450);
  picker.querySelector('[role="option"]').click();
  assert.deepEqual(seen, ["ev-open-house"]);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nreference picker search: all checks passed");
process.exit(0);
