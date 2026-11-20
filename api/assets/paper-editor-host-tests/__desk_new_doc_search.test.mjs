// __desk_new_doc_search.test.mjs — the desk navbar's Create new document has
// TanStack's "Search document types" box (task-6f94a9762c2c0c33; TypePicker in
// barkpark-studio app/src/components/NewDocMenu.tsx):
//
// - typing keeps the ways whose title holds the text, any case;
// - nothing is lit until an arrow key moves, and Enter opens the lit way;
// - with nothing left, "No results for <text>" in place of the list;
// - each open starts over: the box empty, every way shown, the focus in it.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-new-doc.js
// under jsdom on a picker shaped like Desk.NewDocMenu.picker's render.
//
// Run: node ../paper-editor-host-tests/__desk_new_doc_search.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;

const doc = window.document;
const ways = ["Author", "New doc post", "Post by Alan Turing", "Category"];
doc.body.innerHTML = `<div class="dk">
  <div id="dk-new-doc" popover role="dialog" class="dk-menu dk-new-doc">
    <div class="dk-new-doc-find">
      <input id="dk-new-doc-find" type="text" role="combobox" aria-label="Search document types"
        aria-autocomplete="list" aria-expanded="true" aria-controls="dk-new-doc-list" autofocus data-desk-new-doc-find />
    </div>
    <div id="dk-new-doc-list" role="listbox" aria-label="New document" class="dk-new-doc-list">
      ${ways.map((w, i) => `<button id="dk-new-doc-option-${i}" type="button" role="option" tabindex="-1" aria-selected="false" class="dk-menu-item">${w}</button>`).join("\n      ")}
    </div>
    <p id="dk-new-doc-empty" class="dk-new-doc-empty" hidden>No results for <strong data-desk-new-doc-query></strong></p>
  </div>
</div>`;

await import("../../priv/static/assets/bp-desk-new-doc.js");
assert.equal(typeof window.BarkparkDeskNewDoc, "object", "bp-desk-new-doc.js loaded");

const picker = doc.getElementById("dk-new-doc");
const find = doc.getElementById("dk-new-doc-find");
const list = doc.getElementById("dk-new-doc-list");
const empty = doc.getElementById("dk-new-doc-empty");
const options = [...list.querySelectorAll('[role="option"]')];
const shown = () => options.filter((o) => !o.hidden).map((o) => o.textContent.trim());
const lit = () => options.filter((o) => o.getAttribute("aria-selected") === "true").map((o) => o.textContent.trim());
const picked = [];
options.forEach((o) => o.addEventListener("click", () => picked.push(o.textContent.trim())));

// The browser's order: beforetoggle, the popover drawn (its autofocus taken),
// then a queued toggle. jsdom has no popovers: :popover-open is the attribute.
const fire = (el, name) => {
  const e = new window.Event(name);
  Object.defineProperty(e, "newState", { value: "open" });
  el.dispatchEvent(e);
};
window.Element.prototype.matches = ((m) => function (sel) {
  return sel === ":popover-open" ? this.hasAttribute("data-open") : m.call(this, sel);
})(window.Element.prototype.matches);
const open = () => {
  fire(picker, "beforetoggle");
  picker.setAttribute("data-open", "");
  find.focus();
  fire(picker, "toggle");
};
const type = (text) => {
  find.value = text;
  find.dispatchEvent(new window.Event("input", { bubbles: true }));
};
const key = (k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  find.dispatchEvent(e);
  return e.defaultPrevented;
};

// Opened: everything shown, nothing lit, the focus in the box.
open();
assert.equal(doc.activeElement, find, "the box has the focus when the list opens");
assert.deepEqual(shown(), ways, "every way is shown");
assert.deepEqual(lit(), [], "nothing is lit");
assert.equal(key("Enter"), false, "Enter with nothing lit opens nothing");
assert.deepEqual(picked, []);

// Typing "alan" leaves only Post by Alan Turing; any case, trimmed.
type("  ALAN ");
assert.deepEqual(shown(), ["Post by Alan Turing"], "typing alan leaves only Post by Alan Turing");
assert.equal(list.hidden, false);
assert.equal(empty.hidden, true);

// "post" leaves two; the arrows light them in turn, and stop at the ends.
type("post");
assert.deepEqual(shown(), ["New doc post", "Post by Alan Turing"]);
assert.deepEqual(lit(), [], "typing lights nothing");
assert.equal(key("ArrowDown"), true, "ArrowDown is the box's");
assert.deepEqual(lit(), ["New doc post"]);
assert.equal(find.getAttribute("aria-activedescendant"), options[1].id, "the box names the lit option");
key("ArrowDown");
key("ArrowDown");
assert.deepEqual(lit(), ["Post by Alan Turing"], "ArrowDown stops at the last shown way");
key("ArrowUp");
key("ArrowUp");
assert.deepEqual(lit(), ["New doc post"], "ArrowUp stops at the first shown way");

// Enter opens the lit one.
key("ArrowDown");
assert.equal(key("Enter"), true, "Enter on a lit way is the box's");
assert.deepEqual(picked, ["Post by Alan Turing"], "Enter opens the lit way");

// The pointer lights the way under it.
options[1].dispatchEvent(new window.Event("pointerover", { bubbles: true }));
assert.deepEqual(lit(), ["New doc post"], "the pointer lights the way under it");

// Nothing left: "No results for <text>", the list gone, the box says so.
type("zebra");
assert.deepEqual(shown(), []);
assert.equal(list.hidden, true, "the list gives way");
assert.equal(empty.hidden, false, "No results for shows");
assert.equal(empty.querySelector("strong").textContent, "zebra", "it names the text");
assert.equal(find.getAttribute("aria-expanded"), "false");
assert.equal(find.hasAttribute("aria-activedescendant"), false);
assert.equal(key("ArrowDown"), true);
assert.deepEqual(lit(), [], "an arrow over nothing lights nothing");

// Open again: it starts over.
picker.removeAttribute("data-open");
find.blur();
open();
assert.equal(find.value, "", "the box is empty again");
assert.deepEqual(shown(), ways, "every way is shown again");
assert.equal(empty.hidden, true);
assert.equal(find.getAttribute("aria-expanded"), "true");
assert.equal(doc.activeElement, find, "the focus is in the box again");

// Keys typed before the queued toggle arrives are kept (it came late under
// load and wiped them, so Enter opened the first way, not the typed one).
picker.removeAttribute("data-open");
fire(picker, "beforetoggle");
picker.setAttribute("data-open", "");
find.focus();
type("alan");
fire(picker, "toggle");
assert.equal(find.value, "alan", "a late toggle keeps what was typed");
assert.deepEqual(shown(), ["Post by Alan Turing"], "a late toggle keeps the filter");

// Another popover's opening is not this one's.
type("cat");
const other = doc.createElement("div");
doc.body.appendChild(other);
fire(other, "beforetoggle");
fire(other, "toggle");
assert.deepEqual(shown(), ["Category"], "another popover opening leaves this one alone");

console.log("__desk_new_doc_search: ok");
