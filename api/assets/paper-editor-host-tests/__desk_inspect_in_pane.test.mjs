// __desk_inspect_in_pane.test.mjs — Inspect where TanStack draws it: in the
// edit pane, over its form (final re-shoot, tell 3). It is no modal, which
// would lift it over the page, so it keeps a modal's keys itself, as
// TanStack's DialogBox: the focus starts on its close button, Tab goes round
// inside it, Escape closes it, a press on the dim layer closes it, and the
// focus goes back to where it was.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom,
// over the markup desk/editor_host.ex and desk/inspect_dialog.ex draw.
//
// Run: node ../paper-editor-host-tests/__desk_inspect_in_pane.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/post;post-a,inspect=on`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

// jsdom has no show() or close(). show() opens it in place; a modal would be
// wrong here, so showModal throws.
const P = window.HTMLDialogElement.prototype;
P.show = function () { this.setAttribute("open", ""); };
P.showModal = function () { throw new Error("Inspect is no modal"); };
P.close = function () {
  if (!this.hasAttribute("open")) return;
  this.removeAttribute("open");
  this.dispatchEvent(new window.Event("close"));
};

const doc = window.document;
const dialog =
  `<dialog id="insp" class="dk-inspect" data-desk-inspect phx-update="ignore">` +
  `<div class="dk-inspect-head"><h2>Inspecting <em>Post A</em></h2>` +
  `<form method="dialog"><button type="submit" class="dk-inspect-close" aria-label="Close">x</button></form></div>` +
  `<div role="tablist"><button type="button" role="tab" id="t-parsed" aria-selected="true" data-desk-inspect-tab>Parsed</button>` +
  `<button type="button" role="tab" id="t-raw" aria-selected="false" tabindex="-1" data-desk-inspect-tab>Raw JSON</button></div>` +
  `<div class="dk-inspect-body inspect-body"><div id="insp-parsed" role="tabpanel" class="dk-inspect-panel">` +
  `<label class="dk-inspect-search"><input type="text" id="find" data-desk-inspect-search></label>` +
  `<ul class="dk-inspect-tree"><li><details open><summary id="root-sum">{…} 2 properties</summary><ul class="dk-inspect-tree">` +
  `<li><details id="meta"><summary id="meta-sum"><span class="dk-inspect-key">meta:</span></summary><ul class="dk-inspect-tree">` +
  `<li><details open><summary id="deep-sum">inside a folded branch</summary></details></li></ul></details></li>` +
  `</ul></details></li></ul></div>` +
  `<div id="insp-raw" role="tabpanel" class="dk-inspect-panel" hidden><pre><code>{}</code></pre><button id="raw-btn">x</button></div>` +
  `</div></dialog>`;
const editPane =
  `<section class="pane-column dk-pane dk-doc dk-edit" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing>` +
  `<div class="pane-header"><button type="button" id="split">Split</button></div>` +
  `<div id="p1-body" class="pane-body doc-form dk-edit-body">` +
  `<div id="p1-inspect" class="dk-inspect-layer" data-desk-inspect-layer></div>` +
  `<form id="editor-form"><input type="text" id="title" name="doc[title]" value="Post A"></form></div></section>`;
doc.body.innerHTML = `<div id="desk-panes">${editPane}</div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const pushed = [];
const hook = Object.assign(Object.create(window.BarkparkDesk), {
  el,
  pushEvent(name, payload) { pushed.push([name, payload]); },
});
hook.mounted();

const tick = () => new Promise((r) => setTimeout(r, 0));
const at = () => doc.activeElement && doc.activeElement.id;
const key = (k, init = {}) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init });
  doc.activeElement.dispatchEvent(e);
  return e;
};
// The page draws the dialog in the pane's layer (inspect=on).
const draw = async () => {
  doc.getElementById("p1-inspect").innerHTML = dialog;
  await tick();
  return doc.getElementById("insp");
};
const closes = () => pushed.filter(([n, p]) => n === "desk-inspect" && p.open === false).length;

// Opened from the form's title: in the pane, the focus on its close button.
doc.getElementById("title").focus();
let d = await draw();
assert.equal(d.open, true, "drawn: it opens");
assert.equal(d.closest("[data-pane-editing] .dk-edit-body > [data-desk-inspect-layer]") !== null, true, "it is in the edit pane's form");
assert.equal(doc.activeElement.className, "dk-inspect-close", "the focus starts on its close button");

// Tab goes round inside: close, Parsed, search, the open branch, the folded
// branch's own line, and back to close. Not Raw JSON (its tab is out of turn,
// its panel hidden), not the line inside the folded branch.
const order = [];
for (let i = 0; i < 6; i++) {
  const e = key("Tab");
  if (!e.defaultPrevented) {
    // The browser moves the focus on; the stops are in document order.
    const stops = Array.from(d.querySelectorAll("button, input, summary"))
      .filter((x) => ["t-raw", "raw-btn", "deep-sum"].indexOf(x.id) < 0);
    stops[stops.indexOf(doc.activeElement) + 1].focus();
  }
  order.push(at() || doc.activeElement.className);
}
assert.deepEqual(order, ["t-parsed", "find", "root-sum", "meta-sum", "dk-inspect-close", "t-parsed"], "Tab goes round inside the card");

// Shift+Tab from the first goes to the last.
d.querySelector(".dk-inspect-close").focus();
assert.equal(key("Tab", { shiftKey: true }).defaultPrevented, true);
assert.equal(at(), "meta-sum", "Shift+Tab from the first goes to the last");

// The search hides a branch: Tab skips what it hid.
doc.getElementById("meta-sum").closest("li").hidden = true;
doc.getElementById("root-sum").focus();
assert.equal(key("Tab").defaultPrevented, true);
assert.equal(doc.activeElement.className, "dk-inspect-close", "a key the search left out is no stop");
doc.getElementById("meta-sum").closest("li").hidden = false;

// Escape closes it, goes no further, gives the focus back to the title, and
// tells the page.
let outer = 0;
const count = () => { outer++; };
doc.addEventListener("keydown", count);
doc.getElementById("find").focus();
const esc = key("Escape");
doc.removeEventListener("keydown", count);
assert.equal(esc.defaultPrevented, true);
assert.equal(outer, 0, "Escape goes no further than the dialog");
assert.equal(d.open, false, "Escape closes it");
assert.equal(at(), "title", "the focus is back where it was");
assert.equal(closes(), 1, "the page is told");

// Drawn again (Back to inspect=on), from the pane header's button: a press on
// the card does nothing, a press on the dim layer closes it.
doc.getElementById("split").focus();
d = await draw();
assert.equal(d.open, true);
const press = (target) => {
  const e = new window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
  target.dispatchEvent(e);
  return e;
};
press(d.querySelector("h2"));
assert.equal(d.open, true, "a press on the card leaves it open");
const dim = press(doc.getElementById("p1-inspect"));
assert.equal(dim.defaultPrevented, true, "the press moves no focus to the page");
assert.equal(d.open, false, "a press on the dim layer closes it");
assert.equal(at(), "split", "the focus is back on the pane header's button");
assert.equal(closes(), 2);

console.log("ok — __desk_inspect_in_pane: in the pane, focus on close, Tab stays inside, Escape and the dim layer close and give the focus back");
