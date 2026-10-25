// __rte_link_fields.test.mjs — task-025d7af119d6f0b8: the Classic rich-text
// editor's link row offers Email and File (DAM) beside Internal and External.
// An email link is a mailto: address. A file link is a file picked from the
// media library (bp-asset-browser), carried as data-link-kind="dam" and
// data-file-name on the <a>. A document link carries its list page's
// parameters as data-link-params, and an address link its new-tab switch as
// data-new-tab. The server stores these on the linkAnnotation
// (Barkpark.Content.PortableText).
//
// Runs the TRACKED static assets under jsdom. Synthetic fixtures only.
// Run: node src/__rte_link_fields.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;

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

await import("../../../priv/static/assets/bp-reference-picker.js");
await import("../../../priv/static/assets/bp-rich-text-editor.js");

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
const shown = (el) =>
  ["internal", "params-box", "external", "email", "file"].filter((n) => !el.querySelector(".bp-rte-" + n).hidden);

await check("the row offers Internal, External, Email and File, each with its own controls", async () => {
  const el = mount("<p>text</p>", { "data-strings": JSON.stringify({ Email: "E-post", "File (DAM)": "Fil (DAM)" }) });
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  const kinds = Array.from(el.querySelectorAll(".bp-rte-kind")).map((b) => [b.dataset.kind, b.textContent]);
  assert.deepEqual(kinds.slice(2), [["email", "E-post"], ["file", "Fil (DAM)"]]);
  assert.deepEqual(shown(el), ["internal", "params-box"]);
  kind(el, "external");
  assert.deepEqual(shown(el), ["external"]);
  kind(el, "email");
  assert.deepEqual(shown(el), ["email"]);
  kind(el, "file");
  assert.deepEqual(shown(el), ["file"]);
});

await check("Email links the selection to mailto:<address>", async () => {
  const el = mount("<p>write us</p>");
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  kind(el, "email");
  const input = el.querySelector(".bp-rte-email-input");
  type(input, "not-an-address");
  keyPress(el.querySelector(".bp-rte-email-set"));
  assert.equal(input.getAttribute("aria-invalid"), "true");
  assert.equal(el.querySelector("a"), null);
  type(input, "someone@example.test");
  keyPress(el.querySelector(".bp-rte-email-set"));
  const a = el.querySelector("a");
  assert.equal(a.getAttribute("href"), "mailto:someone@example.test");
  assert.equal(a.hasAttribute("data-link-kind"), false);
  assert.equal(el.querySelector(".bp-rte-linkrow").hidden, true);
});

await check("an existing mailto link opens on Email with its address", async () => {
  const el = mount('<p><a href="mailto:a@example.test" data-pt-def="m1">mail</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  assert.equal(el.querySelector('.bp-rte-kind[data-kind="email"]').getAttribute("aria-pressed"), "true");
  assert.equal(el.querySelector(".bp-rte-email-input").value, "a@example.test");
  type(el.querySelector(".bp-rte-email-input"), "b@example.test");
  keyPress(el.querySelector(".bp-rte-email-set"));
  assert.equal(bridged.at(-1), '<p><a href="mailto:b@example.test" data-pt-def="m1">mail</a></p>');
});

await check("File opens the media library over every kind of file; a pick links to the file and names it", async () => {
  const el = mount("<p>the brochure</p>", { "data-token": "tok", "data-media-strings": JSON.stringify({ library: "Bibliotek" }) });
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  kind(el, "file");
  keyPress(el.querySelector(".bp-rte-file-pick"));
  assert.equal(browserOpens.length, 1);
  const opts = browserOpens[0];
  assert.equal(opts.accept, "*/*");
  assert.equal(opts.dataset, "production");
  assert.equal(opts.scopePrefix, "/w/demo/p/default");
  assert.equal(opts.token, "tok");
  assert.deepEqual(opts.strings, { library: "Bibliotek" });
  opts.onSelect({
    id: "asset-1",
    url: "https://files.example.test/a/brochure.pdf",
    title: "Brochure",
    asset: { fileInfo: { originalName: "brochure.pdf" } },
  });
  const a = el.querySelector("a");
  assert.equal(a.getAttribute("href"), "https://files.example.test/a/brochure.pdf");
  assert.equal(a.getAttribute("data-link-kind"), "dam");
  assert.equal(a.getAttribute("data-file-name"), "brochure.pdf");
  assert.ok(bridged.at(-1).includes('data-link-kind="dam"'), `bridged ${bridged.at(-1)}`);
});

await check("an existing file link opens on File with its name, and a new pick replaces url and name", async () => {
  const el = mount('<p><a href="https://files.example.test/f.pdf" data-pt-def="m1" data-link-kind="dam" data-file-name="f.pdf">file</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  assert.equal(el.querySelector('.bp-rte-kind[data-kind="file"]').getAttribute("aria-pressed"), "true");
  assert.equal(el.querySelector(".bp-rte-file-name").textContent, "f.pdf");
  keyPress(el.querySelector(".bp-rte-file-pick"));
  browserOpens[0].onSelect({ url: "https://files.example.test/g.pdf", title: "g.pdf", asset: { fileInfo: {} } });
  assert.equal(
    bridged.at(-1),
    '<p><a href="https://files.example.test/g.pdf" data-pt-def="m1" data-link-kind="dam" data-file-name="g.pdf">file</a></p>',
  );
});

await check("a file link given an address loses its file attributes", async () => {
  const el = mount('<p><a href="https://files.example.test/f.pdf" data-pt-def="m1" data-link-kind="dam" data-file-name="f.pdf">file</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  kind(el, "external");
  type(el.querySelector(".bp-rte-url"), "https://example.test/page");
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(bridged.at(-1), '<p><a href="https://example.test/page" data-pt-def="m1">file</a></p>');
});

await check("a new address link opens in a new tab unless the switch is turned off", async () => {
  const el = mount("<p>one</p><p>two</p>");
  const [p1, p2] = el.querySelectorAll("p");
  select(el, p1);
  keyPress(el.querySelector(".bp-rte-link"));
  kind(el, "external");
  assert.equal(el.querySelector(".bp-rte-newtab-box").checked, true);
  type(el.querySelector(".bp-rte-url"), "https://example.test/");
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(p1.querySelector("a").getAttribute("data-new-tab"), "true");

  select(el, p2);
  keyPress(el.querySelector(".bp-rte-link"));
  kind(el, "external");
  const box = el.querySelector(".bp-rte-newtab-box");
  box.checked = false;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));
  type(el.querySelector(".bp-rte-url"), "https://example.test/two");
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(p2.querySelector("a").getAttribute("data-new-tab"), "false");
});

await check("the new-tab switch on an existing address link saves as it changes; untouched it writes nothing", async () => {
  const el = mount('<p><a href="https://example.test/" data-pt-def="m1">out</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  const box = el.querySelector(".bp-rte-newtab-box");
  assert.equal(box.checked, false);
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(el.querySelector("a").hasAttribute("data-new-tab"), false);

  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  box.checked = true;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(bridged.at(-1), '<p><a href="https://example.test/" data-pt-def="m1" data-new-tab="true">out</a></p>');
  assert.equal(el.querySelector(".bp-rte-linkrow").hidden, false);
});

await check("an internal link's parameters show, save on Enter and keep only the query of a pasted address", async () => {
  const el = mount('<p><a href="#internal:list-1" data-pt-def="m1" data-link-params="page=2">list</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  const params = el.querySelector(".bp-rte-params");
  assert.equal(params.value, "page=2");
  type(params, "https://site.example.test/list?tags=a,b&sort=name-asc");
  params.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  assert.equal(params.value, "tags=a,b&sort=name-asc");
  assert.equal(
    bridged.at(-1),
    '<p><a href="#internal:list-1" data-pt-def="m1" data-link-params="tags=a,b&amp;sort=name-asc">list</a></p>',
  );
  type(params, "");
  params.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(bridged.at(-1), '<p><a href="#internal:list-1" data-pt-def="m1" data-link-params="">list</a></p>');
});

await check("parameters typed before a pick ride on the new document link", async () => {
  const el = mount("<p>list</p>");
  select(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  type(el.querySelector(".bp-rte-params"), "?tags=x");
  const picker = el.querySelector(".bp-rte-internal bp-reference-picker");
  picker.dispatchEvent(new window.CustomEvent("bp-change", { detail: { value: "list-2" } }));
  const a = el.querySelector("a");
  assert.equal(a.getAttribute("href"), "#internal:list-2");
  assert.equal(a.getAttribute("data-link-params"), "tags=x");
});

await check("a document link given another document drops the old document's parameters", async () => {
  const el = mount('<p><a href="#internal:list-1" data-pt-def="m1" data-link-params="page=2">list</a></p>');
  select(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  const picker = el.querySelector(".bp-rte-internal bp-reference-picker");
  picker.dispatchEvent(new window.CustomEvent("bp-change", { detail: { value: "list-3" } }));
  assert.equal(bridged.at(-1), '<p><a href="#internal:list-3" data-pt-def="m1">list</a></p>');
});

await check("without link types the row takes an address only and adds no attributes", async () => {
  const el = mount("<p>plain</p>");
  el.remove();
  const bare = document.createElement("bp-rich-text-editor");
  bare.setAttribute("value", "<p>plain</p>");
  document.body.appendChild(bare);
  assert.equal(bare.querySelector(".bp-rte-kind"), null);
  assert.equal(bare.querySelector(".bp-rte-newtab-box"), null);
  assert.equal(bare.querySelector(".bp-rte-email"), null);
  select(bare, bare.querySelector("p"));
  keyPress(bare.querySelector(".bp-rte-link"));
  type(bare.querySelector(".bp-rte-url"), "example.test");
  keyPress(bare.querySelector(".bp-rte-set"));
  assert.equal(bare.querySelector(".bp-rte-body").innerHTML, '<p><a href="https://example.test">plain</a></p>');
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrich-text link fields: all checks passed");
process.exit(0);
