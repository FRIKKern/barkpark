// __desk_undo_page.mjs: the page the desk undo host tests run on (the
// __desk_undo*.test.mjs files). A desk with a list pane and an editing pane
// whose form keeps an undo for some fields, the desk's push and the typing
// flush recorded, and the TRACKED static asset
// api/priv/static/assets/bp-desk-undo.js loaded under jsdom.
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
export const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;

export const doc = window.document;
export const MARK = '["production","post","post-14"]';
doc.body.innerHTML =
  `<div id="desk-panes">` +
  `<section id="list" data-pane-kind="list"><input id="search" type="search"></section>` +
  `<section id="pane" data-pane-index="1" data-pane-editing><header><span class="kind" id="kind">Post</span>` +
  `<button id="menu" type="button">…</button><input id="pane-input" type="text"></header>` +
  `<form id="editor-form" data-desk-undo-keys="doc[title] doc[excerpt] doc[choice] doc[cards] doc[address]" phx-value-_bp_doc='${MARK}'>` +
  `<input type="text" id="title" name="doc[title]" value="Fixture post 14">` +
  `<textarea id="excerpt" name="doc[excerpt]">Short.</textarea>` +
  `<input type="text" id="slug" name="doc[slug]" value="fixture-post-14">` +
  `<input type="url" id="site" name="doc[site]">` +
  `<input type="number" id="count" name="doc[count]">` +
  `<input type="text" id="alt" name="doc[image][alt]">` +
  `<select id="choice" name="doc[choice]"><option value="a">Alpha</option><option value="b">Beta</option><option value="c" selected>Gamma</option></select>` +
  `<div id="cards"><input type="text" id="card-label" name="doc[cards][0][label]" value="Two"></div>` +
  `<input type="text" id="street" name="doc[address][street]" value="Main 12">` +
  `<input type="number" id="floor" name="doc[address][floor]">` +
  `<button type="button" id="add">Add</button>` +
  `<fieldset id="set" data-collapsible><legend><button type="button" class="object-toggle" id="set-toggle" aria-expanded="false">More</button></legend>` +
  `<textarea id="folded" name="doc[folded]">Folded.</textarea></fieldset>` +
  `<fieldset id="obj" data-collapsible><legend><button type="button" class="object-toggle" id="obj-toggle" aria-expanded="false">Obj</button></legend>` +
  `<div><fieldset id="inner" data-collapsible><legend><button type="button" class="object-toggle" id="inner-toggle" aria-expanded="false">Inner</button></legend>` +
  `<details id="det"><summary>More</summary><textarea id="deep" name="doc[deep]">Deep.</textarea></details></fieldset></div></fieldset>` +
  `<div contenteditable="true" id="rich">Body</div>` +
  `</form></section>` +
  `<dialog id="dialog" open><input id="dialog-input" type="text"></dialog></div>`;

// LiveView runs a fold button's own command on its click
// (`JS.toggle_attribute({"aria-expanded", "true", "false"})`, Desk.Fieldsets).
export const toggled = [];
doc.addEventListener("click", (e) => {
  const b = e.target.closest && e.target.closest(".object-toggle");
  if (!b) return;
  toggled.push(b.id);
  b.setAttribute("aria-expanded", b.getAttribute("aria-expanded") === "true" ? "false" : "true");
});

export const pushes = [];
export const order = [];
doc.getElementById("desk-panes").bpPush = (event, payload) => {
  order.push("push");
  pushes.push({ event, payload });
};
window.BarkparkFormLeave = () => order.push("flush");
window.BarkparkDocMark = () => doc.getElementById("editor-form").getAttribute("phx-value-_bp_doc");

await import("../../priv/static/assets/bp-desk-undo.js");
if (!window.BarkparkDeskUndo) throw new Error("bp-desk-undo.js did not load");

export const $ = (id) => doc.getElementById(id);
export const key = (target, init) => {
  const e = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(e);
  return e;
};
export const undone = (detail) => window.dispatchEvent(new window.CustomEvent("phx:desk:undone", { detail }));
export const later = (ms) => new Promise((done) => setTimeout(done, ms));

let failures = 0;

export async function check(name, fn) {
  pushes.length = 0;
  order.length = 0;
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

export function done(what) {
  if (failures) {
    console.log(`\n${failures} failing`);
    process.exit(1);
  }
  console.log(`\n${what}: ok`);
}
