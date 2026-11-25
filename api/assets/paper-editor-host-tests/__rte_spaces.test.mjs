// __rte_spaces.test.mjs (task-a196f4063197dc02): another editor deleted
// "twoA" from "one twoA three" and this page's editor was given
// "one  three", two ASCII spaces. Under the default `white-space: normal`
// the two are drawn as one, and when the next letter was typed between
// them Chrome dropped one: the store held "one Qthree". The editor's text
// now keeps every space as TanStack's editor does (`white-space: pre-wrap`),
// so the browser has no collapsed space to drop.
//
// jsdom draws nothing, so this checks the rule the browser draws by, and
// that a value with two spaces comes back with both.
//
// Runs the TRACKED asset api/priv/static/assets/bp-rich-text-editor.js.
// Run: node ../paper-editor-host-tests/__rte_spaces.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
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

function mount(value) {
  document.body.innerHTML = "";
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", value);
  document.body.appendChild(el);
  return el;
}

check("the text keeps every space: white-space is pre-wrap", () => {
  const body = mount("<p>one  three</p>").querySelector(".bp-rte-body");
  assert.equal(window.getComputedStyle(body).whiteSpace, "pre-wrap");
});

check("a value another editor sent with two spaces keeps both, and posts both", () => {
  const el = mount("<p>one two three</p>");
  el.value = "<p>one  three</p>";
  const posted = [];
  el.addEventListener("bp-change", (e) => posted.push(e.detail.value));
  el.querySelector(".bp-rte-body").dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(el.querySelector(".bp-rte-body p").textContent, "one  three");
  assert.match(posted[0], /one {2}three/);
});

check("a moved editor keeps the rule", () => {
  const el = mount("<p>a</p>");
  const other = document.createElement("div");
  document.body.appendChild(other);
  other.appendChild(el);
  assert.equal(window.getComputedStyle(el.querySelector(".bp-rte-body")).whiteSpace, "pre-wrap");
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrich-text spaces: all checks passed");
process.exit(0);
