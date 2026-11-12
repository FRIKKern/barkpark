// __desk_slice_discarded.test.mjs — live.spec:48: the draft in the desk's
// editor was discarded elsewhere (`Desk.Discarded`). The page sends
// `desk:discarded` after the patch that put the published version in the
// form; LiveView leaves the FOCUSED field as typed, so the hook sets it from
// the published values, and then tells the page it has the new form
// (`desk-discard-seen`): until then the page drops the form's saves.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk.js under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_slice_discarded.test.mjs
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
doc.body.innerHTML =
  `<input id="outside" name="doc[title]" value="Not the editor's">` +
  `<div id="desk-panes"><section class="pane-column dk-pane dk-doc" id="p1" data-pane-index="1" data-pane-kind="doc" data-pane-editing aria-label="Post">` +
  `<div class="pane-body"><form id="editor-form">` +
  `<input type="text" id="title" name="doc[title]" value="Here elsewhere">` +
  `<input type="text" id="cta.url" name="doc[cta][url]" value="https://dead">` +
  `<input type="checkbox" id="featured" name="doc[featured]" value="true">` +
  `</form></div></section></div>`;
const el = doc.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });

const handlers = {};
const pushed = [];
const hook = Object.assign(Object.create(window.BarkparkDesk), {
  el,
  pushEvent: (name, payload) => pushed.push([name, payload]),
  handleEvent: (name, fn) => (handlers[name] = fn),
});
hook.mounted();
assert.equal(typeof handlers["desk:discarded"], "function", "the hook listens for desk:discarded");

const values = { "doc[title]": "Here", "doc[cta][url]": "https://published", "doc[featured]": "false" };
const title = doc.getElementById("title");
const url = doc.getElementById("cta.url");

// The focused field keeps what was typed through the patch: the hook sets it.
title.focus();
title.value = "Here elsewhere!";
handlers["desk:discarded"]({ values });
assert.equal(title.value, "Here", "the focused field shows the published value");
assert.equal(url.value, "https://dead", "an unfocused field is the patch's, not the hook's");
assert.deepEqual(pushed, [["desk-discard-seen", {}]], "the page hears this browser has the new form");

// A field the values do not name keeps what it has; the page still hears.
pushed.length = 0;
url.focus();
url.value = "typed";
handlers["desk:discarded"]({ values: { "doc[title]": "Here" } });
assert.equal(url.value, "typed");
assert.deepEqual(pushed, [["desk-discard-seen", {}]]);

// A checkbox's value is its option, not the field's: left alone.
pushed.length = 0;
const box = doc.getElementById("featured");
box.focus();
handlers["desk:discarded"]({ values });
assert.equal(box.value, "true");

// Focus outside the editor's form: nothing set, the answer still goes.
pushed.length = 0;
const outside = doc.getElementById("outside");
outside.focus();
handlers["desk:discarded"]({ values });
assert.equal(outside.value, "Not the editor's");
assert.deepEqual(pushed, [["desk-discard-seen", {}]]);

// A hook mounted with no handleEvent (another host) does not break.
const bare = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
bare.mounted();

console.log("desk discarded: ok");
