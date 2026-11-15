// __desk_field_actions.test.mjs: the browser half of a desk field's "Copy
// field" (bp-desk-field-actions.js, `Desk.FieldActions`).
//
// The click starts one clipboard write whose three types (Sanity's item
// under its web custom type, text/html, text/plain) wait for the server's
// answer; `desk:field-copied` settles them. An empty field rejects the
// write, so the clipboard keeps what it held, and its words are shown. A
// browser that refuses the write begun in the click gets one after the
// answer, down to the plain words. A failed copy says so.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-field-actions.js
// under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_field_actions.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/w/acme/p/web/d/production/studio/_desk/post;post-22",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
globalThis.Blob = window.Blob;

const SANITY = "web application/vnd.sanity-clipboard-item+json";
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

// jsdom has no popover: the toast is shown while this is set.
window.HTMLElement.prototype.showPopover = function () {
  this.setAttribute("data-open", "");
};
window.HTMLElement.prototype.hidePopover = function () {
  this.removeAttribute("data-open");
};
const matches = window.Element.prototype.matches;
window.Element.prototype.matches = function (selector) {
  if (selector === ":popover-open") return this.hasAttribute("data-open");
  return matches.call(this, selector);
};

// A clipboard that keeps what was last written, as the browser's.
let held = "before";
let refuse = () => false;
const writes = [];
class ClipboardItem {
  constructor(types) {
    this.types = types;
  }
}
window.ClipboardItem = ClipboardItem;
const settle = async (types) => {
  const out = {};
  for (const [type, part] of Object.entries(types)) {
    const body = await part;
    assert.equal(body.type, type.replace(/^web /, ""), "each blob is typed as its entry, without `web `");
    out[type] = await new Promise((resolve) => {
      const reader = new window.FileReader();
      reader.onload = () => resolve(reader.result);
      reader.readAsText(body);
    });
  }
  return out;
};
Object.defineProperty(window.navigator, "clipboard", {
  configurable: true,
  value: {
    write: async ([item]) => {
      if (refuse(item)) throw new Error("refused");
      const types = await settle(item.types);
      held = types;
      writes.push(Object.keys(types).sort());
    },
    writeText: async (text) => {
      held = text;
      writes.push(["writeText"]);
    },
  },
});

await import("../../priv/static/assets/bp-desk-field-actions.js");

document.body.innerHTML =
  `<div class="field"><div class="field-actions">` +
  `<button id="field-actions-excerpt-button" popovertarget="field-actions-excerpt"></button>` +
  `<div id="field-actions-excerpt" popover role="menu" data-desk-copy-failed="Could not copy to the clipboard">` +
  `<button role="menuitem" data-desk-field-copy="excerpt">Copy field<span><svg></svg></span></button>` +
  `<button role="menuitem" data-desk-field-paste="excerpt" disabled>Paste field</button>` +
  `</div></div></div>`;

const item = document.querySelector("[data-desk-field-copy]");
const press = (el = item) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const answer = (detail) => window.dispatchEvent(new window.CustomEvent("phx:desk:field-copied", { detail }));
const toast = () => document.querySelector("body > .dk-field-toast");
const copy = { field: "excerpt", json: '{"type":"sanityClipboardItem"}', html: "<div><p>Short</p></div>", text: "Short" };

// 1. A click on the icon inside the item starts the write; the answer fills
//    its three types. No toast for a copy that landed, as TanStack's.
press(item.querySelector("svg"));
await tick();
assert.equal(held, "before", "nothing is written before the server answers");
answer(copy);
await tick(20);
assert.deepEqual(held, { [SANITY]: copy.json, "text/html": copy.html, "text/plain": copy.text });
assert.deepEqual(writes, [[SANITY, "text/html", "text/plain"].sort()]);
assert.equal(toast(), null, "a landed copy shows no toast");

// 2. An empty field: its words are shown as a status, the clipboard keeps
//    the earlier copy, and nothing more is written.
press();
answer({ field: "excerpt", empty: "Empty value, nothing to copy" });
await tick(20);
assert.equal(writes.length, 1, "an empty field writes nothing");
assert.equal(held["text/plain"], "Short", "the earlier copy is still on the clipboard");
assert.equal(toast().textContent, "Empty value, nothing to copy");
assert.equal(toast().getAttribute("role"), "status");
assert.equal(toast().getAttribute("data-tone"), "caution");
assert.ok(toast().hasAttribute("data-open"), "the toast is shown");
assert.equal(toast().getAttribute("popover"), "manual");

// 3. An answer nobody asked for, or for another field, writes nothing.
answer(copy);
press();
answer({ ...copy, field: "title" });
await tick(20);
assert.equal(writes.length, 1, "an answer for another field is not this copy's");
answer({ ...copy, text: "Again" });
await tick(20);
assert.equal(held["text/plain"], "Again");
assert.equal(writes.length, 2);

// 4. A browser without web custom types: the item rides in text/html.
refuse = (it) => SANITY in it.types;
press();
answer({ ...copy, text: "Two types" });
await tick(20);
assert.deepEqual(writes.at(-1), ["text/html", "text/plain"]);
assert.equal(held["text/plain"], "Two types");

// 5. One that refuses every item still gets the words.
refuse = () => true;
press();
answer({ ...copy, text: "Words" });
await tick(20);
assert.deepEqual(writes.at(-1), ["writeText"]);
assert.equal(held, "Words");

// 6. No clipboard at all: the menu's own words say the copy failed, as an alert.
Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: undefined });
press();
answer(copy);
await tick(20);
assert.equal(toast().textContent, "Could not copy to the clipboard");
assert.equal(toast().getAttribute("role"), "alert");
assert.equal(held, "Words");

// 7. The disabled Paste item and anything else on the page start nothing.
press(document.querySelector("[data-desk-field-paste]"));
press(document.body);
answer(copy);
await tick(20);
assert.equal(toast().textContent, "Could not copy to the clipboard", "no new toast");

console.log("desk field actions: ok (copy in three types, empty refused, fallbacks, failure said)");
process.exit(0);
