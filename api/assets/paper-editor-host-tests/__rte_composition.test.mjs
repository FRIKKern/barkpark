// __rte_composition.test.mjs (task-9c12e45747b151ee): an IME composition
// in the Classic rich-text editor posted its text at once. The editor sent
// bp-change on every input, a composing one too, so the field bridge saved
// a value with half a word in it. Another editor's save of earlier text in
// the same block, made while that composition was open, was then based on
// an older value and held as a clash. TanStack's PortableTextInput emits no
// patch for a composition in progress. The editor now sends nothing while a
// composition is open and sends the value once it commits.
//
// Runs the TRACKED asset api/priv/static/assets/bp-rich-text-editor.js under
// jsdom. Synthetic fixtures only.
// Run: node ../paper-editor-host-tests/__rte_composition.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "MutationObserver", "InputEvent", "CompositionEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
window.document.execCommand = () => true;
globalThis.fetch = window.fetch = async () => ({ ok: true, json: async () => ({ result: [], documents: [] }) });

await import("../../priv/static/assets/bp-rich-text-editor.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

const posted = [];
function mount(value) {
  document.body.innerHTML = "";
  posted.length = 0;
  const wrap = document.createElement("div");
  wrap.addEventListener("bp-change", (e) => posted.push(e.detail.value));
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", value);
  wrap.appendChild(el);
  document.body.appendChild(wrap);
  return el.querySelector(".bp-rte-body");
}

// What the browser does to the text as a composition runs, and the events.
const compose = (body, text) => {
  body.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
  body.querySelector("p").append(text);
  body.dispatchEvent(new window.CompositionEvent("compositionupdate", { bubbles: true, data: text }));
  body.dispatchEvent(new window.InputEvent("input", { bubbles: true, isComposing: true, data: text, inputType: "insertCompositionText" }));
};
const commit = (body, text, { inputAfter }) => {
  body.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: text }));
  // Firefox sends one more input, not composing, after compositionend.
  if (inputAfter) body.dispatchEvent(new window.InputEvent("input", { bubbles: true, isComposing: false, data: text, inputType: "insertCompositionText" }));
};

check("a composition in progress posts nothing", () => {
  const body = mount("<p>one two</p>");
  compose(body, "か");
  assert.deepEqual(posted, []);
});

check("a commit as Chrome sends it (the last input composing, then compositionend) posts the value", () => {
  const body = mount("<p>one two</p>");
  compose(body, "か");
  commit(body, "か", { inputAfter: false });
  assert.equal(posted.length, 1);
  assert.match(posted[0], /one twoか/);
});

check("a commit as Firefox sends it (compositionend, then an input) posts the committed value", () => {
  const body = mount("<p>one two</p>");
  compose(body, "か");
  commit(body, "か", { inputAfter: true });
  assert.ok(posted.length >= 1);
  assert.ok(posted.every((v) => /one twoか/.test(v)));
});

check("typing outside a composition posts on every input, as before", () => {
  const body = mount("<p>one</p>");
  body.querySelector("p").append("x");
  body.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText", data: "x" }));
  assert.equal(posted.length, 1);
  assert.match(posted[0], /onex/);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrich-text composition: all checks passed");
process.exit(0);
