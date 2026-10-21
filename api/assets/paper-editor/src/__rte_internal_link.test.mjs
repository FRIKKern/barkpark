// __rte_internal_link.test.mjs — task-088575052b459f3e: in a Portable Text body
// opened in the Classic rich-text editor, an internal link showed as
// "#internal:<id>" and the link row only took an address. When the server
// stamps data-link-types, the link row now chooses Internal or External.
// Internal mounts a bp-reference-picker over those types; a pick links the text
// to "#internal:<id>" and the link reads as the target's title. The picker's
// own events stay inside the editor.
//
// Runs the TRACKED static assets under jsdom.
// Run: node src/__rte_internal_link.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "KeyboardEvent", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
const execs = [];
window.document.execCommand = (cmd, _ui, arg) => {
  execs.push([cmd, arg]);
  return true;
};

const queries = [];
globalThis.fetch = window.fetch = async (url) => {
  const u = new URL(String(url), "http://localhost");
  if (u.pathname.includes("/data/query/")) {
    queries.push(u);
    return {
      ok: true,
      json: async () => ({
        result: [
          { _id: "onix.product-1", title: "Selvfølelse" },
          { _id: "drafts.article-2", title: "Utkast til artikkel" },
        ],
      }),
    };
  }
  return {
    ok: true,
    json: async () => ({
      documents: [{ _id: "onix.product-2", _type: "product", title: "Følelser og behov" }],
    }),
  };
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

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const keyPress = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));

// The editor as Studio renders it: inside the field bridge's wrapper, inside the
// editor form. The wrapper hears every bp-change that leaves the editor.
const formEvents = [];
const bridged = [];
for (const type of ["input", "change"]) {
  window.addEventListener(type, (e) => {
    if (e.target && e.target.form) formEvents.push(type);
  });
}

function mount(value, attrs = {}) {
  document.body.innerHTML = "";
  bridged.length = 0;
  const form = document.createElement("form");
  const wrap = document.createElement("div");
  wrap.addEventListener("bp-change", (e) => bridged.push(e.detail.value));
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", value);
  el.setAttribute("dataset", "production");
  el.setAttribute("scope-prefix", "/w/gyldendal-no/p/default");
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  wrap.appendChild(el);
  form.appendChild(wrap);
  document.body.appendChild(form);
  return el;
}

// Put the caret inside the element `node`, as a click in the text would.
function caretIn(el, node) {
  const body = el.querySelector(".bp-rte-body");
  body.focus();
  const range = document.createRange();
  range.selectNodeContents(node);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  document.dispatchEvent(new window.Event("selectionchange"));
}

const TYPES = "page,article,product,contributor";

await check("with no link types the link row takes an address only", async () => {
  const el = mount("<p>Tekst</p>");
  assert.equal(el.querySelector(".bp-rte-kind"), null);
  assert.equal(el.querySelector(".bp-rte-internal"), null);
  assert.ok(el.querySelector(".bp-rte-url"));
});

await check("a new link opens on Internal with a document picker over the declared types", async () => {
  const el = mount("<p>Tekst</p>", { "data-link-types": TYPES, "data-picker-strings": JSON.stringify({ change: "Endre" }) });
  caretIn(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  const kinds = Array.from(el.querySelectorAll(".bp-rte-kind"));
  assert.deepEqual(kinds.map((b) => [b.dataset.kind, b.getAttribute("aria-pressed")]), [
    ["internal", "true"],
    ["external", "false"],
    ["email", "false"],
    ["file", "false"],
  ]);
  const picker = el.querySelector(".bp-rte-internal bp-reference-picker");
  assert.ok(picker, "no picker in the link row");
  assert.equal(picker.getAttribute("ref-type"), TYPES);
  assert.equal(picker.getAttribute("scope-prefix"), "/w/gyldendal-no/p/default");
  assert.equal(picker.getAttribute("data-strings"), JSON.stringify({ change: "Endre" }));
  assert.equal(el.querySelector(".bp-rte-external").hidden, true);
});

await check("picking a document links the text to #internal:<id>; nothing but the body leaves the editor", async () => {
  formEvents.length = 0;
  execs.length = 0;
  const el = mount("<p>Tekst</p>", { "data-link-types": TYPES });
  caretIn(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  const picker = el.querySelector(".bp-rte-internal bp-reference-picker");
  const search = picker.querySelector(".bp-ref-search-input");
  search.focus();
  search.value = "Følelser";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  search.dispatchEvent(new window.Event("change", { bubbles: true }));
  await wait(450);
  picker.querySelector('[role="option"]').click();
  assert.deepEqual(execs.filter(([c]) => c === "createLink"), [["createLink", "#internal:onix.product-2"]]);
  assert.deepEqual(formEvents, [], "a link row event reached the form");
  // The bridge heard the editor's HTML, never the picker's document id.
  assert.ok(bridged.length >= 1);
  assert.ok(bridged.every((v) => v.includes("<p>")), `bridged ${JSON.stringify(bridged)}`);
  assert.equal(el.querySelector(".bp-rte-linkrow").hidden, true);
});

await check("an internal link reads as its target's title, and the title stays out of the value", async () => {
  queries.length = 0;
  const el = mount('<p>Les <a href="#internal:onix.product-1" data-pt-def="m1">boka</a> og <a href="#internal:article-2">dette</a></p>', {
    "data-link-types": TYPES,
  });
  await wait(20);
  assert.equal(queries.length, 1);
  assert.equal(queries[0].pathname, "/w/gyldendal-no/p/default/v2025-02-19/data/query/production");
  const ids = JSON.parse(queries[0].searchParams.get("$ids"));
  assert.ok(ids.includes("onix.product-1") && ids.includes("drafts.onix.product-1"));
  const [a, b] = el.querySelectorAll("a");
  assert.equal(a.getAttribute("title"), "Selvfølelse");
  assert.equal(b.getAttribute("title"), "Utkast til artikkel");
  assert.equal(
    el.value,
    '<p>Les <a href="#internal:onix.product-1" data-pt-def="m1">boka</a> og <a href="#internal:article-2">dette</a></p>',
  );
});

await check("an existing internal link opens on Internal with its document, and a new pick retargets it in place", async () => {
  execs.length = 0;
  const el = mount('<p>Les <a href="#internal:onix.product-1" data-pt-def="m1">boka</a></p>', { "data-link-types": TYPES });
  await wait(20);
  caretIn(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  const picker = el.querySelector(".bp-rte-internal bp-reference-picker");
  assert.equal(picker.getAttribute("value"), "onix.product-1");
  assert.equal(el.querySelector('.bp-rte-kind[data-kind="internal"]').getAttribute("aria-pressed"), "true");
  // Change, search, pick.
  picker.querySelector(".ref-selected button").click();
  const search = picker.querySelector(".bp-ref-search-input");
  search.value = "Følelser";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  await wait(450);
  picker.querySelector('[role="option"]').click();
  const a = el.querySelector("a");
  assert.equal(a.getAttribute("href"), "#internal:onix.product-2");
  assert.equal(a.getAttribute("data-pt-def"), "m1");
  assert.equal(a.getAttribute("title"), "Følelser og behov");
  assert.deepEqual(execs.filter(([c]) => c === "createLink"), []);
  assert.equal(bridged.at(-1), '<p>Les <a href="#internal:onix.product-2" data-pt-def="m1">boka</a></p>');
});

await check("an external link opens on External with its address; Set keeps the address", async () => {
  formEvents.length = 0;
  const el = mount('<p><a href="https://example.test/">ut</a></p>', { "data-link-types": TYPES });
  caretIn(el, el.querySelector("a"));
  keyPress(el.querySelector(".bp-rte-link"));
  assert.equal(el.querySelector('.bp-rte-kind[data-kind="external"]').getAttribute("aria-pressed"), "true");
  assert.equal(el.querySelector(".bp-rte-internal").hidden, true);
  const url = el.querySelector(".bp-rte-url");
  assert.equal(url.value, "https://example.test/");
  url.value = "example.test/ny";
  url.dispatchEvent(new window.Event("input", { bubbles: true }));
  keyPress(el.querySelector(".bp-rte-set"));
  assert.equal(el.querySelector("a").getAttribute("href"), "https://example.test/ny");
  assert.deepEqual(formEvents, []);
});

await check("Internal and External switch the row between the picker and the address box", async () => {
  const el = mount("<p>Tekst</p>", { "data-link-types": TYPES });
  caretIn(el, el.querySelector("p"));
  keyPress(el.querySelector(".bp-rte-link"));
  keyPress(el.querySelector('.bp-rte-kind[data-kind="external"]'));
  assert.equal(el.querySelector(".bp-rte-external").hidden, false);
  assert.equal(el.querySelector(".bp-rte-internal").hidden, true);
  keyPress(el.querySelector('.bp-rte-kind[data-kind="internal"]'));
  assert.equal(el.querySelector(".bp-rte-internal").hidden, false);
  assert.ok(el.querySelector(".bp-rte-internal bp-reference-picker"));
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nrich-text internal link: all checks passed");
process.exit(0);
