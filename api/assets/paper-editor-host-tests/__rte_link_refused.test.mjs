// __rte_link_refused.test.mjs — task-8c1ce08bb99e4d89: the Classic rich-text
// editor's link row put any address it was given into the editor DOM, so a
// javascript: link sat there until the next save dropped it. It now takes
// only what a link may draw, the rule of Barkpark.Content.LinkHref.allowed?/1
// and TanStack's lib/link-href.ts: http, https, mailto, tel, a path, a ?
// query, a # address. Anything else stays in the open row with TanStack's
// words (BodyToolbar.tsx LinkInput), and no <a> is made or changed. A server
// update (ptDefUpdate) takes the same rule.
//
// Runs the TRACKED static assets under jsdom. Synthetic fixtures only.
// Run: node ../paper-editor-host-tests/__rte_link_refused.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
// ptDefUpdate finds a link by CSS.escape(key); jsdom may not carry CSS.
globalThis.CSS = window.CSS || { escape: (v) => String(v).replace(/["\\]/g, "\\$&") };

// jsdom has no execCommand. This one does what a browser's createLink does to
// a selection: it wraps the selected text in <a href>.
const execs = [];
window.document.execCommand = (cmd, _ui, arg) => {
  execs.push([cmd, arg]);
  if (cmd === "createLink") {
    const sel = window.getSelection();
    if (sel.rangeCount) {
      const range = sel.getRangeAt(0);
      const a = document.createElement("a");
      a.setAttribute("href", arg);
      a.appendChild(range.extractContents());
      range.insertNode(a);
    }
  }
  return true;
};

globalThis.fetch = window.fetch = async () => ({ ok: true, json: async () => ({ result: [], documents: [] }) });

// The media library as bp-asset-browser exposes it; a test picks a file
// through the onSelect the editor hands over.
const browserOpens = [];
window.BpAssetBrowser = {
  ensure: () => ({
    open: (opts) => browserOpens.push(opts),
  }),
};

await import("../../priv/static/assets/bp-reference-picker.js");
await import("../../priv/static/assets/bp-rich-text-editor.js");

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

const keyPress = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));
const TYPES = "page,article";

const bridged = [];
function mount(value, attrs = {}) {
  document.body.innerHTML = "";
  bridged.length = 0;
  browserOpens.length = 0;
  execs.length = 0;
  const form = document.createElement("form");
  const wrap = document.createElement("div");
  wrap.addEventListener("bp-change", (e) => bridged.push(e.detail.value));
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", value);
  el.setAttribute("dataset", "production");
  el.setAttribute("scope-prefix", "/w/demo/p/default");
  el.setAttribute("data-link-types", TYPES);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  wrap.appendChild(el);
  form.appendChild(wrap);
  document.body.appendChild(form);
  return el;
}

// Select the contents of `node`, as a drag over the text would.
function select(el, node) {
  const body = el.querySelector(".bp-rte-body");
  body.focus();
  const range = document.createRange();
  range.selectNodeContents(node);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  document.dispatchEvent(new window.Event("selectionchange"));
}

const type = (input, value) => {
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
};

const kind = (el, k) => keyPress(el.querySelector(`.bp-rte-kind[data-kind="${k}"]`));

const REASON = "Use a web, mail or phone address (https:, mailto:, tel:) or a path.";
const reason = (el) => el.querySelector(".bp-rte-link-refused:not([hidden])");
const scripted = (el) => el.querySelectorAll('.bp-rte-body a[href^="javascript" i], .bp-rte-body a[href^="data" i], .bp-rte-body a[href^="vbscript" i], .bp-rte-body a[href^="//"]').length;

const REFUSED = [
  "javascript:alert(1)",
  "JaVaScRiPt:alert(1)",
  "  javascript:alert(1)",
  "jav\tascript:alert(1)",
  "java\u0000script:alert(1)",
  "data:text/html,<script>alert(1)</script>",
  "vbscript:msgbox(1)",
  "//evil.example/x",
  "/\\evil.example/x",
];

for (const [label, attrs] of [["no link types", {}], ["link types (External)", { "data-link-types": TYPES }]]) {
  for (const href of REFUSED) {
    await check(`${label}: ${JSON.stringify(href)} makes no link and says why`, async () => {
      const el = mount("<p>text</p>", attrs);
      if (!attrs["data-link-types"]) el.removeAttribute("data-link-types");
      select(el, el.querySelector("p"));
      keyPress(el.querySelector(".bp-rte-link"));
      if (attrs["data-link-types"]) kind(el, "external");
      const input = el.querySelector(".bp-rte-url");
      type(input, href);
      keyPress(el.querySelector(".bp-rte-set"));
      assert.equal(el.querySelector(".bp-rte-body a"), null, el.querySelector(".bp-rte-body").innerHTML);
      assert.equal(execs.filter(([c]) => c === "createLink").length, 0);
      assert.equal(el.querySelector(".bp-rte-linkrow").hidden, false, "the row stays open");
      assert.equal(input.getAttribute("aria-invalid"), "true");
      const why = reason(el);
      assert.ok(why, "a reason is shown");
      assert.equal(why.textContent, REASON);
      assert.equal(why.getAttribute("role"), "alert");
      assert.equal(input.getAttribute("aria-describedby"), why.id);
    });
  }
}

await check("an existing link given javascript: keeps its address", async () => {
  const el = mount('<p><a href="https://example.test/a" data-pt-def="m1">site</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  type(el.querySelector(".bp-rte-url"), "javascript:alert(1)");
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(el.querySelector("a").getAttribute("href"), "https://example.test/a");
  assert.equal(scripted(el), 0);
  assert.ok(reason(el));
});

await check("typing again takes the reason away, and an allowed address links", async () => {
  const el = mount("<p>text</p>");
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  const input = el.querySelector(".bp-rte-url");
  type(input, "javascript:alert(1)");
  keyPress(el.querySelector(".bp-rte-set"));
  assert.ok(reason(el));
  type(input, "https://example.test/ok");
  assert.equal(reason(el), null);
  assert.equal(input.hasAttribute("aria-invalid"), false);
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(el.querySelector(".bp-rte-body a").getAttribute("href"), "https://example.test/ok");
  assert.equal(el.querySelector(".bp-rte-linkrow").hidden, true);
});

await check("closing the row takes the reason away", async () => {
  const el = mount("<p>text</p>");
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  type(el.querySelector(".bp-rte-url"), "javascript:alert(1)");
  keyPress(el.querySelector(".bp-rte-set"));
  keyPress(el.querySelector(".bp-rte-link"));
  assert.equal(el.querySelector(".bp-rte-linkrow").hidden, true);
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  assert.equal(reason(el), null);
  assert.equal(el.querySelector(".bp-rte-url").hasAttribute("aria-invalid"), false);
});

for (const [typed, linked] of [
  ["https://example.test/a", "https://example.test/a"],
  ["http://example.test/a", "http://example.test/a"],
  ["mailto:someone@example.test", "mailto:someone@example.test"],
  ["tel:+4712345678", "tel:+4712345678"],
  ["/about", "/about"],
  ["./next", "./next"],
  ["../up", "../up"],
  ["?page=2", "?page=2"],
  ["#top", "#top"],
  ["example.test", "https://example.test"],
]) {
  await check(`control: ${JSON.stringify(typed)} links to ${JSON.stringify(linked)}`, async () => {
    const el = mount("<p>text</p>");
    el.removeAttribute("data-link-types");
    select(el, el.querySelector("p"));
    keyPress(el.querySelector(".bp-rte-link"));
    type(el.querySelector(".bp-rte-url"), typed);
    keyPress(el.querySelector(".bp-rte-set"));
    assert.equal(el.querySelector(".bp-rte-body a").getAttribute("href"), linked);
    assert.equal(reason(el), null);
  });
}

await check("the reason in the host's words", async () => {
  const nb = "Bruk en nett-, e-post- eller telefonadresse (https:, mailto:, tel:) eller en sti.";
  const el = mount("<p>text</p>", { "data-strings": JSON.stringify({ [REASON]: nb }) });
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  kind(el, "external");
  type(el.querySelector(".bp-rte-url"), "javascript:alert(1)");
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(reason(el).textContent, nb);
});

await check("a server update with a javascript: address leaves the link as it is", async () => {
  const el = mount('<p><a href="https://example.test/a" data-pt-def="m1">site</a></p>');
  el.ptDefUpdate("m1", "javascript:alert(1)");
  assert.equal(el.querySelector("a").getAttribute("href"), "https://example.test/a");
  el.ptDefUpdate("m1", "https://example.test/b");
  assert.equal(el.querySelector("a").getAttribute("href"), "https://example.test/b");
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrich-text link refusal: all checks passed");
process.exit(0);
