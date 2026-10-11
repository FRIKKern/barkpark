// task-4e10550394f87112: a desk search hit is a live navigation that remounts
// the desk with focus on <body>. The server pushes `bp:focus-doc-header`, and
// this listener (inline in root.html.heex) focuses the opened document's
// header, holding it through the join's re-renders for a second while focus
// is idle on <body>.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
const start = root.indexOf('window.addEventListener("phx:bp:focus-doc-header"');
assert.ok(start > 0, "root.html.heex listens for phx:bp:focus-doc-header");
const end = root.indexOf("\n    });\n", start) + "\n    });\n".length;
const source = root.slice(start, end);

const dom = new JSDOM(
  `<main><button id="other">Other</button><div id="panel"><div class="pane-header editor-header" tabindex="-1">Fjellet</div></div></main>`,
  { runScripts: "outside-only" },
);
const { window } = dom;
const { document } = window;
window.eval(source);
const tick = (ms) => new Promise((r) => setTimeout(r, ms));
const push = () => window.dispatchEvent(new window.CustomEvent("phx:bp:focus-doc-header"));
const header = () => document.querySelector(".pane-header.editor-header");
const key = () => document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true }));

// The push lands focus on the header.
push();
assert.equal(document.activeElement, header(), "the opened document's header takes focus");

// The join re-renders and blurs it: it is taken back while focus is idle.
header().blur();
assert.equal(document.activeElement, document.body);
await tick(120);
assert.equal(document.activeElement, header(), "a blur to <body> during the join is undone");

// A header REPLACED by a patch is found again.
const panel = document.getElementById("panel");
panel.innerHTML = '<div class="pane-header editor-header" tabindex="-1">Fjellet</div>';
await tick(120);
assert.equal(document.activeElement, header(), "a re-rendered header is focused in turn");

// Focus the user put somewhere else is never taken.
document.getElementById("other").focus();
await tick(120);
assert.equal(document.activeElement.id, "other", "deliberate focus elsewhere is kept");

// Once the user presses a key, the listener stops.
await tick(1000);
document.activeElement.blur();
push();
assert.equal(document.activeElement, header());
key();
header().blur();
await tick(150);
assert.equal(document.activeElement, document.body, "a key press means the user has moved on");

console.log("focus doc header: header focused, held through the join, never stolen");
