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
// PASTE. The click on "Paste field" is held back while the clipboard is
// read (Sanity's item under its own type, else the one in text/html); then
// the item's JSON rides on the menu item as `phx-value-clip` for exactly one
// click, which LiveView sends. Anything else on the clipboard is "Nothing to
// paste" and no click goes on. A browser that will not let the page read
// the clipboard is told so, and nothing is sent. The server's refusal
// (`desk:field-toast`) is shown as an alert.
//
// THE SCRIPT ITSELF is loaded by bp-desk.js when the desk mounts. A click on
// Copy or Paste before it has arrived waits for it; if it never arrives the
// pane's toast says so and the next click loads it again.
//
// Runs the TRACKED static assets api/priv/static/assets/bp-desk-field-actions.js
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
    // What a paste reads: `reads` is the clipboard's items, or an error to throw.
    read: async () => {
      if (reads instanceof Error) throw reads;
      return reads.map((types) => ({
        types: Object.keys(types),
        getType: async (type) => ({ text: async () => types[type] }),
      }));
    },
  },
});
let reads = [];
const clipboardApi = window.navigator.clipboard;

await import("../../priv/static/assets/bp-desk-field-actions.js");

document.body.innerHTML =
  `<div class="field"><div class="field-actions">` +
  `<button id="field-actions-excerpt-button" popovertarget="field-actions-excerpt"></button>` +
  `<div id="field-actions-excerpt" popover role="menu" data-desk-field="excerpt" data-desk-copy-failed="Could not copy to the clipboard">` +
  `<button role="menuitem" data-desk-field-copy>Copy field<span><svg></svg></span></button>` +
  `<button role="menuitem" data-desk-field-paste disabled>Paste field</button>` +
  `</div></div></div>` +
  `<div class="field"><div class="field-actions"><div id="field-actions-title" popover role="menu" data-desk-field="title">` +
  `<button role="menuitem" phx-click="desk-field-paste" data-desk-field-paste ` +
  `data-desk-nothing="Nothing to paste" data-desk-invalid="Invalid clipboard item" data-desk-denied="The browser did not let this page read the clipboard">Paste field</button>` +
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
await tick(80);
assert.deepEqual(held, { [SANITY]: copy.json, "text/html": copy.html, "text/plain": copy.text });
assert.deepEqual(writes, [[SANITY, "text/html", "text/plain"].sort()]);
assert.equal(toast(), null, "a landed copy shows no toast");

// 2. An empty field: its words are shown as a status, the clipboard keeps
//    the earlier copy, and nothing more is written.
press();
answer({ field: "excerpt", empty: "Empty value, nothing to copy" });
await tick(80);
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
await tick(80);
assert.equal(writes.length, 1, "an answer for another field is not this copy's");
answer({ ...copy, text: "Again" });
await tick(80);
assert.equal(held["text/plain"], "Again");
assert.equal(writes.length, 2);
assert.equal(toast().textContent, "", "the earlier \"Empty value\" toast is taken down by a copy that lands");
assert.equal(toast().hasAttribute("data-open"), false);

// 4. A browser without web custom types: the item rides in text/html.
refuse = (it) => SANITY in it.types;
press();
answer({ ...copy, text: "Two types" });
await tick(80);
assert.deepEqual(writes.at(-1), ["text/html", "text/plain"]);
assert.equal(held["text/plain"], "Two types");

// 5. One that refuses every item still gets the words.
refuse = () => true;
press();
answer({ ...copy, text: "Words" });
await tick(80);
assert.deepEqual(writes.at(-1), ["writeText"]);
assert.equal(held, "Words");

// 6. No clipboard at all: the menu's own words say the copy failed, as an alert.
Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: undefined });
press();
answer(copy);
await tick(80);
assert.equal(toast().textContent, "Could not copy to the clipboard");
assert.equal(toast().getAttribute("role"), "alert");
assert.equal(held, "Words");

// 7. The disabled Paste item and anything else on the page start nothing.
press(document.querySelector("[data-desk-field-paste]"));
press(document.body);
answer(copy);
await tick(80);
assert.equal(toast().textContent, "Could not copy to the clipboard", "no new toast");

// ── Paste ──────────────────────────────────────────────────────────────
// LiveView's click listener is on the window, in the bubble phase: it sees
// only the click this script hands on, with the item on the button.
Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: clipboardApi });
const sent = [];
window.addEventListener("click", (e) => {
  const el = e.target.closest("[phx-click]");
  if (el) sent.push({ event: el.getAttribute("phx-click"), field: el.getAttribute("phx-value-field"), clip: el.getAttribute("phx-value-clip") });
});
const pasteItem = document.querySelector("#field-actions-title [data-desk-field-paste]");
const ITEM = JSON.stringify({ type: "sanityClipboardItem", value: "Short", barkpark: { kind: "field", field: { name: "excerpt", sig: "string", value: "Short" } } });
const b64 = (text) => Buffer.from(text, "utf8").toString("base64");
const paste = async () => {
  sent.length = 0;
  toast().textContent = "";
  press(pasteItem);
  assert.equal(sent.length, 0, "the click is held back while the clipboard is read");
  await tick(80);
  return sent.slice();
};

// 8a. Sanity's item under its own type: one click goes on, carrying it.
reads = [{ [SANITY]: ITEM, "text/html": "<p>x</p>", "text/plain": "Short" }];
assert.deepEqual(await paste(), [{ event: "desk-field-paste", field: "title", clip: ITEM }]);
assert.equal(pasteItem.hasAttribute("phx-value-clip"), false, "the item is on the button for that click only");
assert.equal(toast().textContent, "", "no toast: the server answers");

// 8b. No custom type (another browser): the item in text/html, base64, UTF-8.
const UTF = JSON.stringify({ type: "sanityClipboardItem", value: "Blåbær", barkpark: { kind: "field", field: { name: "x", sig: "string", value: "Blåbær" } } });
reads = [{ "text/html": `<div data-sanity-clipboard-base64="${b64(UTF)}"><p>Blåbær</p></div>`, "text/plain": "Blåbær" }];
assert.deepEqual((await paste()).map((x) => x.clip), [UTF]);

// 8c. Anything else on the clipboard: nothing to paste, and no click goes on.
for (const other of [
  [],
  [{ "text/plain": "just words" }],
  [{ "text/html": "<p>no item</p>" }],
  [{ "text/html": `<div data-sanity-clipboard-base64="!!!"></div>` }],
  [{ [SANITY]: "not json" }],
  [{ [SANITY]: JSON.stringify({ type: "other" }) }],
]) {
  reads = other;
  assert.deepEqual(await paste(), [], JSON.stringify(other));
  assert.equal(toast().textContent, "Nothing to paste");
  assert.equal(toast().getAttribute("role"), "status");
}

// 8d. An item over the cap is not sent at all.
reads = [{ [SANITY]: JSON.stringify({ type: "sanityClipboardItem", value: "x".repeat(262144) }) }];
assert.deepEqual(await paste(), []);
assert.equal(toast().textContent, "Invalid clipboard item");
assert.equal(toast().getAttribute("role"), "alert");

// 8e. A browser that will not let the page read the clipboard: Paste says
//     so and sends nothing. It does not paste what was copied here earlier:
//     something else may have been copied since (review of #26467).
window.localStorage.clear();
refuse = () => false;
press();
answer({ ...copy, json: ITEM });
await tick(80);
assert.equal(window.localStorage.length, 0, "no copy is kept in the browser");
for (const error of [new window.DOMException("denied", "NotAllowedError"), new window.DOMException("no data", "DataError"), new Error("broken")]) {
  reads = error;
  assert.deepEqual(await paste(), [], error.name);
  assert.equal(toast().textContent, "The browser did not let this page read the clipboard", error.name);
  assert.equal(toast().getAttribute("role"), "alert");
}
// No clipboard to read at all (an old browser, a page not on https): the same.
Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: { write: clipboardApi.write, writeText: clipboardApi.writeText } });
assert.deepEqual(await paste(), []);
assert.equal(toast().textContent, "The browser did not let this page read the clipboard");
Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: clipboardApi });

// 8f. The disabled Paste item reads nothing and sends nothing.
reads = [{ [SANITY]: ITEM }];
sent.length = 0;
press(document.querySelector("#field-actions-excerpt [data-desk-field-paste]"));
await tick(80);
assert.deepEqual(sent, []);

// 8g. The server's refusal is shown: a title and the reason, as an alert.
window.dispatchEvent(new window.CustomEvent("phx:desk:field-toast", { detail: { tone: "critical", title: "Invalid clipboard item", description: "Source and target schema types are not compatible" } }));
assert.equal(toast().querySelector("strong").textContent, "Invalid clipboard item");
assert.equal(toast().querySelector("span").textContent, "Source and target schema types are not compatible");
assert.equal(toast().getAttribute("role"), "alert");
window.dispatchEvent(new window.CustomEvent("phx:desk:field-toast", { detail: { tone: "default", title: "Nothing to paste" } }));
assert.equal(toast().textContent, "Nothing to paste");
assert.equal(toast().getAttribute("role"), "status");

// 9. bp-desk.js loads this script when the desk mounts, once, from the
//    address on the desk's root; a page with no address loads nothing.
await import("../../priv/static/assets/bp-desk.js");
const api = window.BarkparkDeskFieldActions;
delete window.BarkparkDeskFieldActions;
const SRC = "/assets/v/0123456789abcdef/bp-desk-field-actions.js";
const mountDesk = (attrs) => {
  const el = document.createElement("div");
  el.id = "desk-panes";
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  el.innerHTML =
    `<section data-pane-index="1" data-pane-editing><div class="dk-toast" popover="manual"></div>` +
    `<div class="view-tabs" role="tablist"><button id="tab-editor" role="tab" aria-selected="true" tabindex="0">Editor</button><button role="tab" aria-selected="false" tabindex="-1">JSON</button></div>` +
    `<div class="field" id="f-late"><div class="field-actions"><button id="b-late" popovertarget="m" data-desk-field="late" aria-expanded="false"></button></div><input id="late-input"></div>` +
    `<div class="field" id="f-fixed"><div class="field-actions"><button id="b-fixed" popovertarget="m" data-desk-field="fixed" data-desk-paste-off aria-expanded="false"></button></div><input type="hidden"><input id="fixed-input"></div>` +
    `<div id="m" class="dk-doc-menu-list" popover role="menu" data-desk-unavailable="Copy and paste did not load. Reload the page.">` +
    `<button role="menuitem" phx-click="desk-field-copy" data-desk-field-copy>Copy field</button>` +
    `<button role="menuitem" phx-click="desk-field-paste" data-desk-field-paste>Paste field</button>` +
    `</div></section>`;
  document.body.appendChild(el);
  Object.defineProperty(el, "clientWidth", { get: () => 1440 });
  const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
  hook.mounted();
  return el;
};
const loaded = () => [...document.querySelectorAll("head > script[data-desk-field-actions]")];
mountDesk({}).remove();
assert.equal(loaded().length, 0, "no address, no script");
mountDesk({ "data-desk-field-actions": SRC }).remove();
const deskRoot = mountDesk({ "data-desk-field-actions": SRC });
assert.equal(loaded().length, 1, "loaded once, however often the desk mounts");
assert.equal(loaded()[0].getAttribute("src"), SRC);
assert.equal(loaded()[0].async, true);

// 10. A click made before the script has arrived waits for it and is then
//     made again: it does not vanish, and it is not sent half-handled.
const late = (what) => deskRoot.querySelector(`[data-desk-field-${what}]`);
// One menu for the form: the "…" that opens it names its field on it, is the
// menu's anchor, and turns Paste off for a field that takes none.
const sharedMenu = deskRoot.querySelector("#m");
const opener = (id) => deskRoot.querySelector("#" + id);
const toggle = (state) => {
  if (state === "open") sharedMenu.setAttribute("data-open", "");
  else sharedMenu.removeAttribute("data-open");
  const e = new window.Event("toggle");
  e.newState = state;
  sharedMenu.dispatchEvent(e);
};
press(opener("b-fixed"));
toggle("open");
assert.equal(sharedMenu.getAttribute("data-desk-field"), "fixed");
assert.equal(opener("b-fixed").style.getPropertyValue("anchor-name"), "--dk-field-actions");
assert.equal(opener("b-fixed").getAttribute("aria-expanded"), "true");
assert.equal(late("paste").disabled, true, "Paste is off for a field that takes none");
// Another field's button while it is open: closed for the first, then this click opens it for the second.
let hidden = 0;
sharedMenu.hidePopover = () => {
  hidden += 1;
  sharedMenu.removeAttribute("data-open");
};
press(opener("b-late"));
assert.equal(hidden, 1, "closed for the field it was open for");
assert.equal(opener("b-fixed").getAttribute("aria-expanded"), "false");
assert.equal(opener("b-fixed").style.getPropertyValue("anchor-name"), "", "one anchor at a time");
toggle("open");
assert.equal(sharedMenu.getAttribute("data-desk-field"), "late");
assert.equal(opener("b-late").style.getPropertyValue("anchor-name"), "--dk-field-actions");
assert.equal(opener("b-late").getAttribute("aria-expanded"), "true");
assert.equal(late("paste").disabled, false);
// The same button again: the browser's own toggle closes it; nothing is hidden by hand.
press(opener("b-late"));
assert.equal(hidden, 1);
toggle("closed");
assert.equal(opener("b-late").getAttribute("aria-expanded"), "false");

// 9b. The open menu follows its field through a patch of the form (review
//     of #26479). A rule that locks the field turns Paste off under the open
//     menu, and one that opens it turns Paste on again.
press(opener("b-late"));
toggle("open");
assert.equal(late("paste").disabled, false);
opener("b-late").setAttribute("data-desk-paste-off", "");
await tick(20);
assert.equal(late("paste").disabled, true, "locked under the open menu: Paste goes off");
opener("b-late").removeAttribute("data-desk-paste-off");
await tick(20);
assert.equal(late("paste").disabled, false);
//     A rule that hides the field: the menu closes and the focus goes to the
//     next field's control, not to the page's body and not to a "…" button.
hidden = 0;
deskRoot.querySelector("#f-late").hidden = true;
await tick(20);
assert.equal(hidden, 1, "the menu is closed when its field is no longer drawn");
assert.equal(document.activeElement.id, "fixed-input");
//     A patch that takes a field out reuses its element for the next one
//     (morphdom, no ids): the next field is found by its name, not by the
//     element it had when the menu opened.
deskRoot.querySelector("#f-late").hidden = false;
press(opener("b-late"));
toggle("open");
hidden = 0;
const lateField = deskRoot.querySelector("#f-late");
const fixedField = deskRoot.querySelector("#f-fixed");
lateField.innerHTML = fixedField.innerHTML;
fixedField.remove();
await tick(20);
assert.equal(hidden, 1, "closed: no button names the field any more");
assert.equal(document.activeElement, lateField.querySelector("#fixed-input"), "the control of the field that is now next");
lateField.id = "f-fixed";
lateField.insertAdjacentHTML("beforebegin", `<div class="field" id="f-late"><div class="field-actions"><button id="b-late" popovertarget="m" data-desk-field="late" aria-expanded="false"></button></div><input id="late-input"></div>`);
toggle("closed");
//     The LAST field is taken out under its open menu (re-review of #26479):
//     the focus goes to the field before it. Nothing is made focusable by the
//     script: the next patch would take a `tabindex` the server did not draw
//     away again, and the focus with it.
deskRoot.querySelector("#f-late").hidden = false;
press(opener("b-fixed"));
toggle("open");
hidden = 0;
deskRoot.querySelector("#f-fixed").remove();
await tick(20);
assert.equal(hidden, 1, "the menu is closed when its field is removed");
assert.equal(document.activeElement.id, "late-input", "the field before it");
//     No field is left at all: the pane's selected view tab, which the
//     server draws focusable. Still there after a wait and one more patch.
toggle("closed");
press(opener("b-late"));
toggle("open");
hidden = 0;
deskRoot.querySelector("#f-late").remove();
await tick(20);
assert.equal(hidden, 1);
assert.equal(document.activeElement.id, "tab-editor", "never the body");
await tick(500);
deskRoot.querySelector("section").setAttribute("data-desk-save", "patched");
await tick(20);
assert.equal(document.activeElement.id, "tab-editor");
assert.equal(deskRoot.querySelector("section").hasAttribute("tabindex"), false, "the script adds no tabindex of its own");
deskRoot.querySelector("section").insertAdjacentHTML("beforeend", `<div class="field" id="f-late"><div class="field-actions"><button id="b-late" popovertarget="m" data-desk-field="late" aria-expanded="false"></button></div><input id="late-input"></div>`);
//     Closed: a later patch does nothing.
toggle("closed");
deskRoot.querySelector("#f-late").hidden = true;
await tick(20);
assert.equal(hidden, 1);
deskRoot.querySelector("#f-late").hidden = false;
press(opener("b-late"));
toggle("open");
toggle("closed");

const paneToast = () => deskRoot.querySelector(".dk-toast");
sent.length = 0;
press(late("copy"));
await tick(20);
assert.deepEqual(sent, [], "held: LiveView does not see the click yet");
assert.equal(paneToast().textContent, "");
window.BarkparkDeskFieldActions = api;
loaded()[0].dispatchEvent(new window.Event("load"));
assert.deepEqual(sent.map((x) => [x.event, x.field]), [["desk-field-copy", "late"]], "made again once the script is there");
answer({ field: "late", empty: "Empty value, nothing to copy" });

// 11. The script does not arrive: the pane's toast says so, the click is
//     not sent, and the next click tries the load again.
delete window.BarkparkDeskFieldActions;
sent.length = 0;
press(late("copy"));
loaded()[0].dispatchEvent(new window.Event("error"));
assert.deepEqual(sent, [], "nothing is sent for a script that failed");
assert.equal(paneToast().textContent, "Copy and paste did not load. Reload the page.");
assert.ok(paneToast().hasAttribute("data-open"), "the pane's toast is shown");
assert.equal(loaded().length, 0, "the failed script is taken out");
press(late("copy"));
assert.equal(loaded().length, 1, "the next click loads it again");
window.BarkparkDeskFieldActions = api;
loaded()[0].dispatchEvent(new window.Event("load"));
assert.deepEqual(sent.map((x) => [x.event, x.field]), [["desk-field-copy", "late"]]);
answer({ field: "late", empty: "Empty value, nothing to copy" });

// 12. With the script there, bp-desk.js holds nothing back.
sent.length = 0;
press(late("copy"));
assert.equal(sent.length, 1);
answer({ field: "late", empty: "Empty value, nothing to copy" });

console.log("desk field actions: ok (copy in three types, empty refused, fallbacks, failure said, paste reads and hands on, loaded by the desk, one menu for the form, it follows its field, a click waits for the script)");
process.exit(0);
