// __paper_anchor.test.mjs (task-52d612bdb8ff6cb3): the sanitizer moves a
// legacy body's stored ids to `bp-anchor-<id>`. An outside link,
// `/papers/x#intro`, must still land on the moved `bp-anchor-intro`.
//
// Runs the TRACKED asset api/priv/static/assets/bp-paper-anchor.js under
// jsdom, and checks the reader layout loads it deferred, outside <head>.
//
// Run: node ../paper-editor-host-tests/__paper_anchor.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "./jsdom.mjs";

const BODY =
  '<main><article id="paper-body">' +
  '<h2 id="bp-anchor-intro">Intro</h2><a name="bp-anchor-old">old</a>' +
  '<p id="bp-anchor-paper-body">stored</p><li id="fn-fn1">note</li>' +
  "</article></main>";

const dom = new JSDOM(`<!doctype html><html><body>${BODY}</body></html>`, {
  url: "http://localhost/papers/x#intro",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;

const landed = [];
window.Element.prototype.scrollIntoView = function () {
  landed.push(this.id || this.getAttribute("name"));
};

await import("../../priv/static/assets/bp-paper-anchor.js");

// On load: #intro names nothing, bp-anchor-intro does.
assert.deepEqual(landed, ["bp-anchor-intro"], "the load lands an outside #intro on bp-anchor-intro");

const go = (hash) => {
  landed.length = 0;
  window.location.hash = hash;
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
};

go("#old");
assert.deepEqual(landed, ["bp-anchor-old"], "a hashchange lands an old a-name anchor");

// A hash that names a page element is the browser's: never moved into the body.
go("#paper-body");
assert.deepEqual(landed, [], "#paper-body stays the page's article");

go("#fn-fn1");
assert.deepEqual(landed, [], "a footnote id lands natively");

go("#bp-anchor-intro");
assert.deepEqual(landed, [], "a hash already in the namespace lands natively");

go("#nothing");
assert.deepEqual(landed, [], "a hash nothing answers scrolls nowhere");

go("#%E0%A4%A");
assert.deepEqual(landed, [], "a malformed escape does not throw");

// The reader layout loads it deferred, at the bottom (Golden Rule 4).
const layout = readFileSync(
  new URL("../../lib/barkpark_web/layouts/bulldocs.html.heex", import.meta.url),
  "utf8",
);
const tag = '<script src="/assets/bp-paper-anchor.js" defer></script>';
assert.ok(layout.includes(tag), "bulldocs.html.heex loads bp-paper-anchor.js deferred");
assert.ok(layout.indexOf(tag) > layout.indexOf("</head>"), "the tag sits after </head>");

console.log("__paper_anchor: ok");
