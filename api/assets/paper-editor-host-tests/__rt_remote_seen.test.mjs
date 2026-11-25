// __rt_remote_seen.test.mjs (task-2833650e2e72d380): while values wait,
// each editor's `_bp_rt_seen[]` reports one less than the FIRST of them, not
// the newest: the editor still shows what it showed before the first. The
// merge of the page's own post (`own`) starts it again from itself.
//
// Runs the TRACKED asset api/priv/static/assets/bp-rt-remote.js under jsdom,
// with a stand-in editor as __rt_remote_caret does.
// Run: node ../paper-editor-host-tests/__rt_remote_seen.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const NAME = "doc[meta].rt";
const dom = new JSDOM(
  `<!doctype html><html><body><div data-pt-subfield="${NAME}">` +
    '<bp-rich-text-editor data-bridge-target="h"><div class="bp-rte-body"><p>one</p></div></bp-rich-text-editor>' +
    '<input type="hidden" id="h"></div></body></html>',
);
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
globalThis.NodeFilter = window.NodeFilter;

window.customElements.define(
  "bp-rich-text-editor",
  class extends window.HTMLElement {
    get value() {
      return this.querySelector(".bp-rte-body").innerHTML;
    }
    set value(html) {
      this.querySelector(".bp-rte-body").innerHTML = html;
    }
  },
);

await import("../../priv/static/assets/bp-rt-remote.js");

const editor = document.querySelector("bp-rich-text-editor");
const seen = () => document.querySelector("input[data-bp-rt-seen]").value;
const push = (seq, html, own = false) =>
  window.dispatchEvent(new window.CustomEvent("phx:bp:rt-remote", { detail: { values: { [NAME]: { seq, html, own } } } }));
const typed = () => editor.querySelector(".bp-rte-body").dispatchEvent(new window.Event("input", { bubbles: true }));

let failures = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
};

await check("a value drawn at once: seen names it", () => {
  push(5, "<p>one five</p>");
  assert.equal(seen(), `${NAME}|5`);
});

await check("two values wait (A typing): seen stays one less than the first", () => {
  typed();
  push(9, "<p>one nine</p>");
  assert.equal(seen(), `${NAME}|8`);
  typed();
  push(12, "<p>one twelve</p>");
  assert.equal(editor.value, "<p>one five</p>");
  assert.equal(seen(), `${NAME}|8`);
});

await check("the merge of A's own post: seen starts again from it", () => {
  typed();
  push(20, "<p>one A</p>", true);
  assert.equal(seen(), `${NAME}|19`);
  typed();
  push(25, "<p>one A B</p>");
  assert.equal(seen(), `${NAME}|19`);
});

await check("drawn once A is idle: seen names the newest", async () => {
  await new Promise((r) => setTimeout(r, 1800));
  assert.equal(editor.value, "<p>one A B</p>");
  assert.equal(seen(), `${NAME}|25`);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrt-remote seen: all checks passed");
process.exit(0);
