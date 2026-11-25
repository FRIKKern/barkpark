// __rt_remote_born.test.mjs (task-eeda66fac5af065f): a new socket sends each
// rich text its stored value (`born`). The page keeps its editors and its
// numbers across a rejoin, so the value is seen at once when the editor
// already shows it, drawn when the editor is untouched since its last draw,
// and never drawn over words typed since then: those may never have been
// posted (the editor form does not auto-recover), and A's next post is held
// against the stored value instead.
//
// Runs the TRACKED asset api/priv/static/assets/bp-rt-remote.js under jsdom,
// with a stand-in editor as __rt_remote_seen does.
// Run: node ../paper-editor-host-tests/__rt_remote_born.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const [A, X] = ["doc[meta].rt", "doc[meta].rt2"];
const wrap = (name, html, id) =>
  `<div data-pt-subfield="${name}"><bp-rich-text-editor value="${html}" data-bridge-target="${id}">` +
  `<div class="bp-rte-body">${html}</div></bp-rich-text-editor><input type="hidden" id="${id}"></div>`;
const dom = new JSDOM(`<!doctype html><html><body>${wrap(A, "<p>one</p>", "h1")}${wrap(X, "<p>x</p>", "h2")}</body></html>`);
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
globalThis.NodeFilter = window.NodeFilter;

let paints = 0;
window.customElements.define(
  "bp-rich-text-editor",
  class extends window.HTMLElement {
    get value() {
      return this.querySelector(".bp-rte-body").innerHTML;
    }
    set value(html) {
      if (html === this.value) return;
      paints += 1;
      this.querySelector(".bp-rte-body").innerHTML = html;
    }
  },
);

await import("../../priv/static/assets/bp-rt-remote.js");

const editorOf = (name) => document.querySelector(`[data-pt-subfield="${name}"] bp-rich-text-editor`);
const seen = (name) => {
  const w = document.querySelector(`[data-pt-subfield="${name}"]`);
  return w.querySelector("input[data-bp-rt-seen]").value;
};
const push = (values) => window.dispatchEvent(new window.CustomEvent("phx:bp:rt-remote", { detail: { values } }));
const type = (name, html) => {
  const body = editorOf(name).querySelector(".bp-rte-body");
  body.innerHTML = html;
  body.dispatchEvent(new window.Event("input", { bubbles: true }));
};
const idle = () => new Promise((r) => setTimeout(r, 1800));

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

await check("a mount's stored value the editor already shows: seen at once, no paint", () => {
  push({ [A]: { seq: 100, html: "<p>one</p>", born: true }, [X]: { seq: 101, html: "<p>x</p>", born: true } });
  assert.equal(paints, 0);
  assert.equal(seen(A), `${A}|101`); // the newest number pushed, as any drawn value
  assert.equal(seen(X), `${X}|101`);
});

await check("B's change drawn, then A types while the socket is down", async () => {
  push({ [A]: { seq: 110, html: "<p>one B</p>" } });
  assert.equal(editorOf(A).value, "<p>one B</p>");
  await new Promise((r) => setTimeout(r, 5));
  type(A, "<p>one BA</p>");
  assert.equal(seen(A), `${A}|110`);
});

await check("the new socket's stored value lands while A types: it waits, and idle does not draw it", async () => {
  push({ [A]: { seq: 200, html: "<p>one B C</p>", born: true } });
  assert.equal(seen(A), `${A}|110`);
  await idle();
  assert.equal(editorOf(A).value, "<p>one BA</p>");
  assert.equal(seen(A), `${A}|110`);
});

await check("the hold's view of A's words replaces it, and shows as the editor does", () => {
  const before = paints;
  push({ [A]: { seq: 210, html: "<p>one BA</p>" } });
  assert.equal(paints, before);
  assert.equal(seen(A), `${A}|210`);
});

await check("an editor untouched since its last draw is drawn the new socket's value at idle", async () => {
  push({ [X]: { seq: 300, html: "<p>x B</p>", born: true } });
  await idle();
  assert.equal(editorOf(X).value, "<p>x B</p>");
  assert.equal(seen(X), `${X}|300`);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
