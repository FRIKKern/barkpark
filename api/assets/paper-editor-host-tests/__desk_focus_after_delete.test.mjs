// __desk_focus_after_delete.test.mjs — task-8e8a63c36d18130e: after a delete
// the desk puts the focus on the row that took the deleted one's place in the
// list (review of #26447). The Studio says which document went and where it
// sat (`bp:focus-after-delete`, `Handlers.Delete`). LiveView's patch then
// re-uses the list's row elements in place, so a row focused while the
// deleted one was still drawn came to show the document after the neighbour:
// deleting Three of Four, Three, Two, One left the focus on One.
//
// Runs the TRACKED asset api/priv/static/assets/bp-desk.js under jsdom, with
// the desk's list pane markup (rows are `a[data-desk-row]`).
//
// Run: node ../paper-editor-host-tests/__desk_focus_after_delete.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const BASE = "/w/a/p/b/d/production/studio/_desk";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: `http://localhost${BASE}/author`,
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const doc = window.document;
const NAMES = { a4: "Four", a3: "Three", a2: "Two", a1: "One" };
const row = (id) => `<a data-desk-row href="${BASE}/author;${id}">${NAMES[id]}</a>`;

function mount(ids) {
  doc.body.innerHTML =
    `<div id="desk-panes"><section class="pane-column dk-pane" data-pane-index="1" data-pane-kind="list">` +
    `<button type="button" id="create">Create new Author</button>` +
    `<nav id="rows">${ids.map(row).join("")}</nav></section></div>`;
  const el = doc.getElementById("desk-panes");
  Object.defineProperty(el, "clientWidth", { get: () => 1440 });
  const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {} });
  hook.mounted();
  doc.activeElement && doc.activeElement.blur && doc.activeElement.blur();
  return hook;
}

// LiveView's patch of a list without `gone`: the row elements stay where they
// are and take the next document's link and name; the last one goes.
function patchInPlace(ids, gone) {
  const left = ids.filter((id) => id !== gone);
  const els = [...doc.querySelectorAll("a[data-desk-row]")];
  els.forEach((el, i) => {
    if (i >= left.length) return el.remove();
    el.setAttribute("href", `${BASE}/author;${left[i]}`);
    el.textContent = NAMES[left[i]];
  });
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const focused = () => doc.activeElement && doc.activeElement.textContent;
const deleted = (id, index) =>
  window.dispatchEvent(new window.CustomEvent("phx:bp:focus-after-delete", { detail: { type: "author", id, index } }));

let failures = 0;
async function check(name, fn) {
  let hook;
  try {
    hook = await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  } finally {
    if (hook && hook.destroyed) hook.destroyed();
    await wait(1600);
  }
}

const ALL = ["a4", "a3", "a2", "a1"];

await check("a middle row deleted: the focus is on the row that took its place, after the patch", async () => {
  const hook = mount(ALL);
  deleted("a3", 1);
  await wait(50);
  patchInPlace(ALL, "a3");
  await wait(300);
  assert.equal(focused(), "Two", "the neighbour after the deleted row");
  return hook;
});

await check("the last row deleted: the focus is on the row before it", async () => {
  const hook = mount(ALL);
  deleted("a1", 3);
  await wait(50);
  patchInPlace(ALL, "a1");
  await wait(300);
  assert.equal(focused(), "Two");
  return hook;
});

await check("the list already drawn without the row: the row at its place at once", async () => {
  const hook = mount(["a4", "a2", "a1"]);
  deleted("a3", 1);
  await wait(150);
  assert.equal(focused(), "Two");
  return hook;
});

await check("no row is left: the pane's first control", async () => {
  const hook = mount(["a3"]);
  deleted("a3", 0);
  await wait(50);
  doc.getElementById("rows").innerHTML = "";
  await wait(300);
  assert.equal(doc.activeElement && doc.activeElement.id, "create");
  return hook;
});

await check("a key pressed before the patch: the focus is left where the person put it", async () => {
  const hook = mount(ALL);
  deleted("a3", 1);
  doc.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
  await wait(50);
  patchInPlace(ALL, "a3");
  await wait(300);
  assert.notEqual(focused(), "Two");
  assert.notEqual(focused(), "One");
  return hook;
});

window.close();
if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nfocus after delete: all checks passed");
