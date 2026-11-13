// __desk_inspect_search.test.mjs — Inspect's search box, as TanStack's
// InspectDialog: typing filters Parsed. A node stays while its key, its value
// or anything under it holds the words (any case); a branch that holds a match
// opens; each count says how many of its keys it shows. Cleared, every branch
// is as it was.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom,
// over the markup desk/inspect_dialog.ex draws.
//
// Run: node ../paper-editor-host-tests/__desk_inspect_search.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post;post-a`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const doc = window.document;
const count = (brace, n, one, other) =>
  `<span class="dk-inspect-count" data-brace="${brace}" data-one="${one}" data-other="${other}">${brace} ${n === 1 ? one : other.replace("{n}", n)}</span>`;
const props = (n) => count("{…}", n, "1 property", "{n} properties");
const leaf = (key, value, type = "string") =>
  `<li><span class="dk-inspect-key">${key}:</span><span class="dk-inspect-value" data-type="${type}">${value}</span></li>`;
const tree =
  `<ul class="dk-inspect-tree"><li><details open=""><summary>${props(4)}</summary><ul class="dk-inspect-tree">` +
  leaf("_id", "drafts.post-a") +
  leaf("rating", "4", "number") +
  `<li><details id="meta" open=""><summary><span class="dk-inspect-key">meta:</span>${props(2)}</summary><ul class="dk-inspect-tree">` +
  leaf("tag", "deep") +
  leaf("note", "Short") +
  `</ul></details></li>` +
  leaf("title", "Looked at") +
  `</ul></details></li></ul>`;
const dialog =
  `<dialog id="insp" class="dk-inspect" data-desk-inspect open><div class="dk-inspect-body inspect-body">` +
  `<div id="insp-parsed" role="tabpanel" class="dk-inspect-panel">` +
  `<label class="dk-inspect-search"><input type="text" class="dk-inspect-search-input" data-desk-inspect-search></label>` +
  tree +
  `</div></div></dialog>`;
const editPane =
  `<section class="pane-column dk-pane dk-doc" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing>` +
  `<div class="pane-body"><form id="editor-form"></form></div>${dialog}</section>`;
doc.body.innerHTML = `<div id="desk-panes">${editPane}</div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
hook.mounted();

const input = doc.querySelector("[data-desk-inspect-search]");
const type = (text) => {
  input.value = text;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
};
// The keys shown, in order, as "key" or "key>child" under meta.
const shown = () =>
  Array.from(doc.querySelectorAll(".dk-inspect-key"))
    .filter((k) => !k.closest("li[hidden]"))
    .map((k) => k.textContent.replace(/:$/, ""));
const counts = () => Array.from(doc.querySelectorAll(".dk-inspect-count")).map((c) => c.textContent);
const meta = doc.getElementById("meta");

// A value deep in a branch: the branch and the match stay, the rest goes.
type("deep");
assert.deepEqual(shown(), ["meta", "tag"], "a value match keeps its ancestors");
assert.deepEqual(counts(), ["{…} 1 property", "{…} 1 property"], "each count is of what it shows");

// Any case; a key matches as a value does.
type("TITLE");
assert.deepEqual(shown(), ["title"], "a key matches, in any case");
assert.deepEqual(counts()[0], "{…} 1 property");

// A branch whose key matches stays, showing only the children that match too.
type("meta");
assert.deepEqual(shown(), ["meta"], "a matching branch key stays");
assert.equal(counts()[1], "{…} 0 properties", "with none of its keys matching, it says 0");

// A folded branch that holds a match opens; cleared, it folds again.
type("");
meta.open = false;
type("note");
assert.equal(meta.open, true, "a branch holding a match opens");
assert.deepEqual(shown(), ["meta", "note"]);
type("");
assert.equal(meta.open, false, "cleared, the branch is folded as it was");
assert.deepEqual(shown(), ["_id", "rating", "meta", "tag", "note", "title"], "cleared, every key is back");
assert.deepEqual(counts(), ["{…} 4 properties", "{…} 2 properties"], "cleared, the counts are whole again");

// Leading and trailing spaces are not part of the words.
type("  short ");
assert.deepEqual(shown(), ["meta", "note"], "the words are trimmed");

// Nothing matches: the root stays, empty, and says so.
type("zzz");
assert.deepEqual(shown(), []);
assert.equal(counts()[0], "{…} 0 properties");

console.log("ok — __desk_inspect_search: value, key and case matches keep ancestors; counts follow; folds restore");
