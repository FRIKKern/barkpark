// __desk_codelist_keys.test.mjs: the keys of a tree codelist on the desk
// (bp-desk-codelist.js, `Fields.TreeCodelistDesk`), the TanStack Studio's
// TreePicker.
//
// In the tree: ArrowDown/ArrowUp/Home/End move, with one row in the Tab
// order; ArrowRight opens a closed branch (a click on its ▶, which the
// server answers) or moves into an open one; ArrowLeft closes an open
// branch or moves to the parent; Enter and Space click the row (the pick).
// In a search every match is open, so Right and Left only move. In the
// search box ArrowDown moves into the tree and Enter submits nothing.
//
// FOCUS. A redraw that takes the focused row away gives the focus to its
// nearest parent still drawn, never the page. That holds after the keys
// moved the focus from row to row (#27107 review B2: Left on an open
// branch, then Down onto its child before the close came back, left the
// focus on BODY). Focus that left the tree on purpose (the search box,
// then a click on nothing) is not pulled back by a later redraw.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-codelist.js
// under jsdom. The redraw keeps every row whose id it draws again, as
// LiveView's patch does, and takes the others away.
//
// Run: node ../paper-editor-host-tests/__desk_codelist_keys.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/volume;v-1",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk-codelist.js");
assert.ok(window.BarkparkDeskCodelist, "the script registers itself");

const doc = window.document;
const ID = "tree-f-subject";
const tick = () => new Promise((r) => setTimeout(r, 0));

// A row as the server draws it.
const li = ({ code, level = 1, parent = "", branch = false, open = false }, first, searching) => {
  const toggle = branch && !searching ? ` phx-click="tree_node_toggle" phx-value-code="${code}"` : "";
  const glyph = branch ? (open ? "▼" : "▶") : "";
  return (
    `<li id="${ID}-i-${code}" role="treeitem" aria-level="${level}"` +
    (branch ? ` aria-expanded="${open}"` : "") +
    ` aria-selected="false" tabindex="${first ? 0 : -1}" data-code="${code}" data-parent="${parent}"` +
    ` phx-click="tree_node_select" phx-value-code="${code}">` +
    `<span class="codelist-toggle" aria-hidden="true"${toggle}>${glyph}</span><span class="mono">${code}</span></li>`
  );
};

doc.body.innerHTML =
  `<form id="editor-form"><div id="${ID}" class="codelist-tree-field">` +
  `<div class="codelist-search"><input id="${ID}-search" type="search" name="codelist_search[${ID}]" /></div>` +
  `<ul id="${ID}-search-tree" class="codelist-tree" role="tree"></ul></div></form>` +
  `<button id="elsewhere">Elsewhere</button>`;
const field = doc.getElementById(ID);
const ul = doc.getElementById(`${ID}-search-tree`);
const box = doc.getElementById(`${ID}-search`);

// The server's redraw, patched in place: kept rows keep their node (and the
// focus), the rest go, new ones come in order. Then LiveView's phx:update.
function redraw(specs, { searching = false } = {}) {
  if (searching) field.setAttribute("data-searching", "");
  else field.removeAttribute("data-searching");
  const tmp = doc.createElement("ul");
  tmp.innerHTML = specs.map((s, i) => li(s, i === 0, searching)).join("");
  const want = [...tmp.children];
  const ids = new Set(want.map((n) => n.id));
  [...ul.children].forEach((n) => ids.has(n.id) || n.remove());
  let prev = null;
  for (const node of want) {
    let cur = doc.getElementById(node.id);
    if (cur) {
      [...cur.attributes].forEach((a) => cur.removeAttribute(a.name));
      [...node.attributes].forEach((a) => cur.setAttribute(a.name, a.value));
      cur.innerHTML = node.innerHTML;
    } else {
      cur = node;
    }
    const ref = prev ? prev.nextSibling : ul.firstChild;
    if (cur !== ref) ul.insertBefore(cur, ref);
    prev = cur;
  }
  doc.dispatchEvent(new window.Event("phx:update"));
}

const A = { code: "A", branch: true };
const AOpen = { code: "A", branch: true, open: true };
const AB = { code: "AB", level: 2, parent: "A" };
const AF = { code: "AF", level: 2, parent: "A" };
const C = { code: "C", branch: true };
const closed = [A, C];
const opened = [AOpen, AB, AF, C];

// What the page sent: toggles and picks, by code.
const sent = [];
doc.addEventListener("click", (e) => {
  const t = e.target.closest("[phx-click]");
  if (t) sent.push(`${t.getAttribute("phx-click")}:${t.getAttribute("phx-value-code")}`);
});

const row = (code) => doc.getElementById(`${ID}-i-${code}`);
const at = () => doc.activeElement?.getAttribute("data-code") ?? (doc.activeElement === box ? "box" : doc.activeElement?.tagName);
const tabStops = () => [...ul.querySelectorAll('[tabindex="0"]')].map((r) => r.getAttribute("data-code"));
const key = (k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  doc.activeElement.dispatchEvent(e);
  return e;
};

redraw(closed);

// ── The search box ─────────────────────────────────────────────────────────
box.focus();
assert.ok(key("Enter").defaultPrevented, "Enter in the box submits nothing");
assert.ok(key("ArrowDown").defaultPrevented, "ArrowDown in the box is the tree's");
assert.equal(at(), "A", "ArrowDown moves from the box to the first row");
assert.deepEqual(tabStops(), ["A"]);

// ── Moving ─────────────────────────────────────────────────────────────────
key("ArrowDown");
assert.equal(at(), "C");
assert.deepEqual(tabStops(), ["C"], "the focused row is the one Tab stop");
key("Home");
assert.equal(at(), "A");
key("End");
assert.equal(at(), "C");
key("ArrowUp");
assert.equal(at(), "A");

// ── Right opens a closed branch; the redraw keeps the focus and Tab stop ───
sent.length = 0;
assert.ok(key("ArrowRight").defaultPrevented);
assert.deepEqual(sent, ["tree_node_toggle:A"], "Right on a closed branch clicks its ▶");
redraw(opened);
assert.equal(at(), "A");
assert.deepEqual(tabStops(), ["A"], "the redraw put the first row in the Tab order; the focused row takes it back");
key("ArrowRight");
assert.equal(at(), "AB", "Right on an open branch moves into it");
key("ArrowLeft");
assert.equal(at(), "A", "Left on a child moves to its parent");
await tick();

// ── B2: Left closes A, Down lands on AB before the close comes back ────────
sent.length = 0;
key("ArrowLeft");
assert.deepEqual(sent, ["tree_node_toggle:A"], "Left on an open branch clicks its ▶");
key("ArrowDown");
assert.equal(at(), "AB");
await tick(); // A's blur settles after AB's focus
redraw(closed); // the close takes AB away
assert.equal(at(), "A", "the focus goes to AB's parent, not the page");
assert.deepEqual(tabStops(), ["A"]);
await tick();

// The same after several moves, and a redraw that takes the parent too.
redraw(opened);
key("ArrowRight");
key("ArrowDown");
assert.equal(at(), "AF");
await tick();
redraw([C]);
assert.equal(at(), "C", "with no parent drawn, the first row");
await tick();

// ── Enter and Space pick; a search's Right and Left only move ──────────────
redraw(opened);
row("AB").focus();
sent.length = 0;
assert.ok(key("Enter").defaultPrevented);
assert.ok(key(" ").defaultPrevented, "Space picks, and does not scroll");
assert.deepEqual(sent, ["tree_node_select:AB", "tree_node_select:AB"]);
redraw(opened, { searching: true });
row("A").focus();
sent.length = 0;
key("ArrowRight");
assert.equal(at(), "AB", "in a search Right moves into the open branch");
key("ArrowLeft");
assert.equal(at(), "A", "and Left moves to the parent");
key("ArrowLeft");
assert.deepEqual(sent, [], "a search's branches are not toggled");
await tick();

// ── Focus that left the tree on purpose stays where it went ────────────────
redraw(opened);
row("AB").focus();
box.focus();
await tick();
box.blur();
assert.equal(doc.activeElement, doc.body);
redraw(closed);
assert.equal(doc.activeElement, doc.body, "a redraw does not pull the focus back after a row left for the box");

row("A").focus();
doc.getElementById("elsewhere").focus();
await tick();
redraw(opened);
assert.equal(doc.activeElement.id, "elsewhere", "nor away from another control");

console.log("ok desk codelist keys: moves, opens, closes, picks; a redraw never drops the focus to the page");
