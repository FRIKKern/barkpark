// __rte_reconnect.test.mjs — task-1647a0c1c37cf069: on the desk's narrow
// layout the patch moves the pane that holds the Classic rich text editor
// (LiveView's morphdom appends the moved node again). A custom element that is
// moved is disconnected and connected again. `disconnectedCallback` took the
// text's listeners off, and `connectedCallback` returned early on its
// double-mount guard, so the moved text took typing but sent no `bp-change`:
// the field bridge never wrote the hidden input, and nothing was saved.
//
// Runs the TRACKED static asset under jsdom.
// Run: node ../paper-editor-host-tests/__rte_reconnect.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
window.document.execCommand = () => true;
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

function mount() {
  const from = document.createElement("section");
  const to = document.createElement("section");
  document.body.append(from, to);
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", "<p>Hello</p>");
  from.appendChild(el);
  const changes = [];
  el.addEventListener("bp-change", (e) => changes.push(e.detail.value));
  return { el, to, changes, body: () => el.querySelector(".bp-rte-body") };
}

const type = (body, text) => {
  body.innerHTML = `<p>${text}</p>`;
  body.dispatchEvent(new window.Event("input", { bubbles: true }));
};

check("typing in a mounted editor sends bp-change (control)", () => {
  const { body, changes } = mount();
  type(body(), "Hello one");
  assert.equal(changes.length, 1);
  assert.match(changes[0], /Hello one/);
});

check("after the editor is moved in the page, typing still sends bp-change", () => {
  const { el, to, body, changes } = mount();
  const before = body();
  to.appendChild(el); // a move: disconnected, then connected again
  assert.equal(body(), before, "the moved editor keeps its text element");
  type(body(), "Hello after the move");
  assert.equal(changes.length, 1, "bp-change after the move");
  assert.match(changes[0], /Hello after the move/);
});

check("a move builds no second toolbar or text, and sends one bp-change per input", () => {
  const { el, to, body, changes } = mount();
  to.appendChild(el);
  el.parentNode.removeChild(el);
  to.appendChild(el);
  assert.equal(el.querySelectorAll(".bp-rte-body").length, 1);
  assert.equal(el.querySelectorAll(".bp-rte-toolbar").length, 1);
  type(body(), "Once");
  assert.equal(changes.length, 1);
});

check("a removed editor sends nothing", () => {
  const { el, body, changes } = mount();
  const text = body();
  el.remove();
  type(text, "Gone");
  assert.equal(changes.length, 0);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
