// task-6d3bd0c5d673c16f: opening a document collapses the root pane into its
// strip (<div> -> <button>, same id), so morphdom re-inserts the next pane
// column and the focused desk row lost focus to <body>. The #studio-panes hook
// (WidthBucket, inline in root.html.heex) gives focus back after the patch.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
const start = root.indexOf("Hooks.WidthBucket = {");
assert.ok(start > 0, "root.html.heex defines Hooks.WidthBucket");
const end = root.indexOf("\n    };", start);
const source = root.slice(start + "Hooks.WidthBucket = ".length, end + "\n    }".length);

const dom = new JSDOM(`<main><div id="studio-panes"><div id="pane-a"><button id="row">Row</button></div></div><button id="header">Header</button></main>`, { runScripts: "outside-only" });
const { window } = dom;
const hookDef = window.eval(`(${source})`);
const el = window.document.getElementById("studio-panes");
const hook = Object.assign(Object.create(hookDef), { el });

// Wide/standard: the row survives but its column is re-inserted -> blur.
const row = window.document.getElementById("row");
row.focus();
hook.beforeUpdate();
const pane = window.document.getElementById("pane-a");
el.removeChild(pane);
el.appendChild(pane);
assert.equal(window.document.activeElement, window.document.body, "the move drops focus (the defect)");
hook.updated();
assert.equal(window.document.activeElement, row, "the hook gives focus back to the row");

// Narrow/phone: the row is destroyed; nothing to give back.
row.focus();
hook.beforeUpdate();
pane.remove();
hook.updated();
assert.equal(window.document.activeElement, window.document.body);

// A deliberate focus target (phx-mounted JS.focus) is never overridden.
const el2 = window.document.createElement("div");
el2.innerHTML = '<button id="row2">Row 2</button>';
el.appendChild(el2);
const row2 = window.document.getElementById("row2");
row2.focus();
hook.beforeUpdate();
window.document.getElementById("header").focus();
hook.updated();
assert.equal(window.document.activeElement.id, "header", "focus a patch moved on purpose stays put");

console.log("ok desk focus keep: moved row refocused, destroyed row left, deliberate focus kept");
