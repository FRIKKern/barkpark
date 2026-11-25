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

// #28779 review. Each case in a wrapper of its own.
const add = (name, html, id) => document.body.insertAdjacentHTML("beforeend", wrap(name, html, id));

await check("blocker 1: A's text ends in a space (Chrome's nbsp): the stored value is seen at once, no banner to come", () => {
  const N = "doc[meta].t1";
  add(N, "<p>one two A</p>", "h3");
  type(N, "<p>one two A&nbsp;</p>");
  const before = paints;
  push({ [N]: { seq: 400, html: "<p>one two A </p>", born: true } });
  assert.equal(seen(N), `${N}|400`);
  assert.equal(paints, before);
});

// task-5e0a0d5e0dfb8f33 (#28779 r2 review): the editor writes <b> and <i>,
// the server draws <strong> and <em>; the same marks are the same value.
await check("the editor's <b>/<i>/<strike> against the stored <strong>/<em>/<s>, A typed since: seen at once, no paint", () => {
  const N = "doc[meta].t9";
  add(N, "<p>one</p>", "h9");
  type(N, "<p>one <b>two</b> <i>three</i> <strike>four</strike></p>");
  const before = paints;
  push({ [N]: { seq: 450, html: "<p>one <strong>two</strong> <em>three</em> <s>four</s></p>", born: true } });
  assert.equal(seen(N), `${N}|450`);
  assert.equal(paints, before);
});

await check("other marks on the same text are another value: it waits over A's typing", () => {
  const N = "doc[meta].t10";
  add(N, "<p>one</p>", "h10");
  type(N, "<p>one <b>two</b></p>");
  const before = paints;
  push({ [N]: { seq: 460, html: "<p>one <em>two</em></p>", born: true } });
  assert.notEqual(seen(N), `${N}|460`);
  assert.equal(paints, before);
  assert.equal(editorOf(N).value, "<p>one <b>two</b></p>");
});

await check("<br> and <img> are not read as <b> and <i>", () => {
  const N = "doc[meta].t11";
  add(N, "<p>one</p>", "h11");
  type(N, "<p>one<br>two</p>");
  push({ [N]: { seq: 470, html: "<p>one<strong>r</strong>two</p>", born: true } });
  assert.notEqual(seen(N), `${N}|470`);
});

await check("blocker 2: B set the load value back while A was offline: the stale editor is drawn, not marked seen", async () => {
  const N = "doc[meta].t2";
  add(N, "<p>one two A</p>", "h4");
  push({ [N]: { seq: 500, html: "<p>one two</p>" } });
  assert.equal(editorOf(N).value, "<p>one two</p>");
  push({ [N]: { seq: 510, html: "<p>one two A</p>", born: true } });
  await idle();
  assert.equal(editorOf(N).value, "<p>one two A</p>");
  assert.equal(seen(N), `${N}|510`);
});

await check("a change with no input event (a code mark, a link) counts as typing: the stored value waits", async () => {
  const N = "doc[meta].t3";
  add(N, "<p>x</p>", "h5");
  push({ [N]: { seq: 600, html: "<p>x B</p>" } });
  const ed = editorOf(N);
  await new Promise((r) => setTimeout(r, 5));
  ed.querySelector(".bp-rte-body").innerHTML = "<p><code>x</code> B</p>";
  ed.dispatchEvent(new window.CustomEvent("bp-change", { bubbles: true, detail: { value: ed.value } }));
  push({ [N]: { seq: 610, html: "<p>x B C</p>", born: true } });
  await idle();
  assert.equal(ed.value, "<p><code>x</code> B</p>");
  assert.equal(seen(N), `${N}|600`);
});

await check("B's next save replaces a stored value waiting over offline typing: still never drawn over it", async () => {
  const N = "doc[meta].t4";
  add(N, "<p>y</p>", "h6");
  push({ [N]: { seq: 700, html: "<p>y B</p>" } });
  await new Promise((r) => setTimeout(r, 5));
  type(N, "<p>y BA</p>");
  push({ [N]: { seq: 710, html: "<p>y B C</p>", born: true } });
  push({ [N]: { seq: 720, html: "<p>y B C D</p>" } });
  await idle();
  assert.equal(editorOf(N).value, "<p>y BA</p>");
  assert.equal(seen(N), `${N}|700`);
});

await check("the desk makes a new editor on rejoin, drawn from the store: its stored value is seen at once, no paint", () => {
  const N = "doc[meta].t5";
  add(N, "<p>z B</p>", "h7");
  const before = paints;
  push({ [N]: { seq: 800, html: "<p>z B</p>", born: true } });
  assert.equal(seen(N), `${N}|800`);
  assert.equal(paints, before);
});

await check("a hold's view replaces a stored value waiting over offline typing: drawn at idle, its number reported (#28779 r2 review)", async () => {
  const N = "doc[meta].t6";
  add(N, "<p>one</p>", "h8");
  push({ [N]: { seq: 900, html: "<p>one two</p>" } });
  await new Promise((r) => setTimeout(r, 5));
  // The editor writes <b> for bold; the server draws <strong>.
  type(N, "<p>one two <b>bo</b></p>");
  push({ [N]: { seq: 910, html: "<p>one two</p>", born: true } });
  push({ [N]: { seq: 920, html: "<p>one two <strong>bo</strong></p>", held: true } });
  await idle();
  // The view is what the editor shows (<b> is <strong>, task-5e0a0d5e0dfb8f33):
  // seen, its number reported, with nothing to draw.
  assert.equal(editorOf(N).value, "<p>one two <b>bo</b></p>");
  assert.equal(seen(N), `${N}|920`);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
// Values left waiting on purpose keep the idle timer going.
process.exit(0);
