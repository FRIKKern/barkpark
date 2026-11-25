// __rt_remote_forget.test.mjs (task-29686209fb9fc5dc): on a document
// switch the server sends `forget`; a value waiting for an input name is
// the old document's, so it is dropped, never drawn into the new
// document's editor of the same name.
//
// Runs the TRACKED asset api/priv/static/assets/bp-rt-remote.js under jsdom,
// with a stand-in editor as __rt_remote_seen does.
// Run: node ../paper-editor-host-tests/__rt_remote_forget.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const NAME = "doc[meta].rt";
const dom = new JSDOM(
  `<!doctype html><html><body><div id="w1" data-pt-subfield="${NAME}">` +
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

const editor = () => document.querySelector("bp-rich-text-editor");
const seen = () => document.querySelector("input[data-bp-rt-seen]").value;
const send = (detail) => window.dispatchEvent(new window.CustomEvent("phx:bp:rt-remote", { detail }));
const typed = () => editor().querySelector(".bp-rte-body").dispatchEvent(new window.Event("input", { bubbles: true }));

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

await check("B's value waits while A types on the first document", () => {
  typed();
  send({ values: { [NAME]: { seq: 9, html: "<p>one B</p>" } } });
  assert.equal(seen(), `${NAME}|8`);
});

await check("another document of the same type: forget drops it, idle draws nothing", async () => {
  document.getElementById("w1").outerHTML =
    `<div id="w2" data-pt-subfield="${NAME}">` +
    '<bp-rich-text-editor data-bridge-target="h"><div class="bp-rte-body"><p>doc two</p></div></bp-rich-text-editor>' +
    '<input type="hidden" id="h"></div>';
  send({ forget: true, values: {} });
  await new Promise((r) => setTimeout(r, 1800));
  assert.equal(editor().value, "<p>doc two</p>");
});

await check("a value for the new document after forget is drawn as any", async () => {
  send({ values: { [NAME]: { seq: 15, html: "<p>doc two B</p>" } } });
  assert.equal(editor().value, "<p>doc two B</p>");
  assert.equal(seen(), `${NAME}|15`);
});

// #28766 review: each value names its document, as the form does. With the
// forget lost, a value of doc 1 is still never drawn into doc 2's editor,
// and the page does not report a number of it.
const D1 = '["production","t","d1"]';
const D2 = '["production","t","d2"]';
const inForm = (doc, html) => {
  document.body.innerHTML =
    `<form id="editor-form" phx-value-_bp_doc='${doc}'><div data-pt-subfield="${NAME}">` +
    `<bp-rich-text-editor data-bridge-target="h"><div class="bp-rte-body">${html}</div></bp-rich-text-editor>` +
    '<input type="hidden" id="h"></div></form>';
};

await check("doc 1's value waits while A types, then doc 2 shows with no forget: idle draws nothing", async () => {
  inForm(D1, "<p>one</p>");
  typed();
  send({ doc: D1, values: { [NAME]: { seq: 20, html: "<p>one B</p>" } } });
  assert.equal(seen(), `${NAME}|19`);
  inForm(D2, "<p>doc two</p>");
  await new Promise((r) => setTimeout(r, 1800));
  assert.equal(editor().value, "<p>doc two</p>");
});

await check("doc 2's first value after it is drawn, its own number reported", () => {
  send({ doc: D2, values: { [NAME]: { seq: 30, html: "<p>doc two B</p>" } } });
  assert.equal(editor().value, "<p>doc two B</p>");
  assert.equal(seen(), `${NAME}|30`);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
