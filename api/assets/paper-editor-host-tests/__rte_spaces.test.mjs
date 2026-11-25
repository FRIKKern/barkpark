// __rte_spaces.test.mjs (task-a196f4063197dc02): another editor deleted
// "twoA" from "one twoA three" and this page's editor was given
// "one  three", two plain spaces. The browser drew them as one, and when
// the next letter was typed between them Chrome dropped one: the store held
// "one Qthree". The editor now paints such a run as Chrome writes typed
// spaces ("one  three"), so every space is drawn and the reader draws
// both too.
//
// r1 drew every space with `white-space: pre-wrap` instead (#28735 r1
// review). Under it Chrome writes a raw newline for Shift+Enter and two
// plain spaces for two typed ones, and pretty-printed HTML shows its
// indentation in the editor only. jsdom cannot type as Chrome does, so the
// rule is pinned here (check 1), and the keys themselves run in Chrome.
//
// Runs the TRACKED assets api/priv/static/assets/bp-rich-text-editor.js and
// bp-rt-remote.js.
// Run: node ../paper-editor-host-tests/__rte_spaces.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "NodeFilter", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
window.document.execCommand = () => true;
globalThis.fetch = window.fetch = async () => ({ ok: true, json: async () => ({ result: [], documents: [] }) });

await import("../../priv/static/assets/bp-rich-text-editor.js");
await import("../../priv/static/assets/bp-rt-remote.js");

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

const NAME = "doc[meta].rt";
function mount(value) {
  document.body.innerHTML = `<div data-pt-subfield="${NAME}"><input type="hidden" id="h"></div>`;
  const el = document.createElement("bp-rich-text-editor");
  el.dataset.bridgeTarget = "h";
  el.setAttribute("value", value);
  document.body.firstChild.prepend(el);
  return el;
}
const bodyOf = (el) => el.querySelector(".bp-rte-body");
const posted = (el) => {
  const out = [];
  el.addEventListener("bp-change", (e) => out.push(e.detail.value));
  bodyOf(el).dispatchEvent(new window.Event("input", { bubbles: true }));
  return out[0];
};

check("the text draws spaces as the reader does: no white-space rule, so Chrome writes <br> and nbsp", () => {
  const body = bodyOf(mount("<p>one  three</p>"));
  assert.equal(body.style.whiteSpace, "");
  assert.ok(!/pre|break/.test(window.getComputedStyle(body).whiteSpace), window.getComputedStyle(body).whiteSpace);
});

check("a value another editor sent with two spaces draws both, and posts them as Chrome writes two typed spaces", () => {
  const el = mount("<p>one two three</p>");
  el.value = "<p>one  three</p>";
  assert.equal(bodyOf(el).querySelector("p").textContent, "one  three");
  assert.equal(posted(el), "<p>one&nbsp; three</p>");
});

check("text Chrome wrote (two typed spaces: a&nbsp; z) paints and posts exactly as it came", () => {
  const el = mount("<p>a&nbsp; zb</p>");
  assert.equal(posted(el), "<p>a&nbsp; zb</p>");
});

check("pretty-printed HTML keeps its whitespace as it is, so it draws as the reader draws it", () => {
  const html = "<p>\n  First line <b>bold</b>\n  continues here.\n</p>\n\n<p>Second</p>\n";
  assert.equal(posted(mount(html)), html);
});

check("runs, line ends and marks", () => {
  const cases = [
    ["<p>a   b</p>", "<p>a&nbsp; &nbsp;b</p>"],
    ["<p>a  </p>", "<p>a&nbsp;&nbsp;</p>"],
    ["<p>a </p>", "<p>a&nbsp;</p>"],
    ["<p> a</p>", "<p>&nbsp;a</p>"],
    ["<p>a<br> b</p>", "<p>a<br>&nbsp;b</p>"],
    ["<p>one <b> two</b></p>", "<p>one&nbsp;<b> two</b></p>"],
    ["<p>one <b>two</b> three</p>", "<p>one <b>two</b> three</p>"],
    ["<p>a</p> <p>b</p>", "<p>a</p> <p>b</p>"],
    ["<p>  </p>", "<p>  </p>"],
  ];
  for (const [given, want] of cases) assert.equal(posted(mount(given)), want, given);
});

check("the same value sent again does not repaint", () => {
  const el = mount("<p>one  three</p>");
  const node = bodyOf(el).querySelector("p").firstChild;
  el.value = "<p>one  three</p>";
  assert.equal(bodyOf(el).querySelector("p").firstChild, node);
});

// The caret code (bp-rt-remote.js, #28716/#28723) counts characters; an
// nbsp is one, so the caret keeps its place through a painted value.
check("the caret stays after the same characters when another editor's value is painted", () => {
  const el = mount("<p>one  three</p>");
  const text = bodyOf(el).querySelector("p").firstChild;
  const r = document.createRange();
  r.setStart(text, 5);
  r.collapse(true);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(r);
  window.dispatchEvent(
    new window.CustomEvent("phx:bp:rt-remote", { detail: { values: { [NAME]: { seq: 1, html: "<p>X one  three</p>" } } } }),
  );
  const at = window.getSelection().getRangeAt(0);
  at.insertNode(document.createTextNode("Q"));
  assert.equal(bodyOf(el).querySelector("p").textContent, "X one  Qthree");
  assert.equal(document.getElementById("h").value, "<p>X one&nbsp; three</p>");
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrich-text spaces: all checks passed");
process.exit(0);
