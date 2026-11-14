// task-d621afa4baf3e166: the media library selected one file, could not delete
// at all, and uploaded only through the file input. bp-asset-explorer-bulk.js
// adds tick boxes, a bulk bar (delete, add to folder) and drop-to-upload.
// Run: node ../paper-editor-host-tests/__asset_explorer_bulk.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  runScripts: "outside-only",
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
const BASE = "/w/agency/p/default/v1/media/production";

// The fake server: `hits` is the library, `answer` decides each delete-many.
let hits = [];
let calls = [];
let answer = (ids) => ({ status: 200, body: { result: { deleted: ids, gone: [], refused: [] } } });
const json = (status, body) => ({ ok: status < 400, status, json: async () => body });
window.fetch = async (url, init = {}) => {
  const path = String(url);
  const method = init.method || "GET";
  if (method !== "GET") calls.push({ path, method, headers: init.headers, body: init.body });
  if (path.endsWith("/delete-many")) {
    const { status, body } = answer(JSON.parse(init.body).ids);
    const gone = (body.result || body.error.details).deleted;
    hits = hits.filter((row) => !gone.includes(row.id));
    return json(status, body);
  }
  if (path.includes("/collections")) return json(200, { result: { collections: [{ id: "col-1", title: "Covers" }] } });
  return json(200, { result: { hits, total: hits.length, facets: {} } });
};
window.requestAnimationFrame = (fn) => setTimeout(fn, 0);
for (const file of ["bp-search-intel.js", "bp-modal-focus.js", "bp-asset-explorer-bulk.js", "bp-asset-explorer.js"]) {
  window.eval(readFileSync(new URL(`../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}

const tick = (ms = 30) => new Promise((r) => setTimeout(r, ms));
const library = (n) =>
  Array.from({ length: n }, (_, i) => ({
    id: `blob-${i}`,
    assetDocId: `asset-${i}`,
    originalName: `file-${i}.png`,
    mimeType: "image/png",
    thumbnailUrl: `/media/files/t-${i}.png`,
  }));

async function mount(n) {
  window.document.body.innerHTML = "";
  hits = library(n);
  calls = [];
  const el = window.document.createElement("bp-asset-explorer");
  el.setAttribute("scope-prefix", "/w/agency/p/default");
  el._pageSize = 500;
  window.document.body.appendChild(el);
  await tick(60);
  return el;
}
const box = (el, i) => el.querySelector(`.bp-ae-tick[data-tick-id="asset-${i}"]`);
const tickBox = (el, i, opts = {}) =>
  box(el, i).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, ...opts }));
const ticked = (el) => Array.from(el.querySelectorAll(".bp-ae-tick:checked")).map((b) => b.dataset.tickId);
const deletes = () => calls.filter((c) => c.path === `${BASE}/delete-many`).map((c) => JSON.parse(c.body));
async function confirmDelete(el, trigger = ".bp-ae-bulk-delete") {
  el.querySelector(trigger).click();
  const dialog = el.querySelector(".bp-ae-bulk-confirm");
  assert.ok(dialog, "Delete asks first, in a dialog");
  assert.equal(deletes().length - confirmDelete.before, 0, "nothing is sent before the confirm");
  dialog.querySelector(".bp-ae-bulk-confirm-ok").click();
  await tick(80);
  return dialog;
}
confirmDelete.before = 0;

// 1. Two ticked files, Delete, confirm: ONE delete-many call, both ids, no force.
{
  const el = await mount(3);
  assert.equal(el.querySelector(".bp-ae-bulk").hidden, true, "no bar while nothing is ticked");
  tickBox(el, 0);
  tickBox(el, 2);
  assert.deepEqual(ticked(el), ["asset-0", "asset-2"]);
  assert.equal(el.querySelector(".bp-ae-bulk").hidden, false);
  assert.equal(el.querySelector(".bp-ae-bulk-count").textContent, "2 selected");
  assert.equal(el.querySelector(".bp-ae-bulk-live").textContent, "2 selected", "the count is announced");
  assert.equal(el._selected, null, "ticking does not open the inspector");

  const dialog = await confirmDelete(el);
  assert.match(dialog.querySelector(".bp-ae-modal-title").textContent, /Delete 2 files\?/);
  assert.deepEqual(deletes(), [{ ids: ["blob-0", "blob-2"] }], "one call, both ids, no force");
  assert.equal(calls[0].headers["x-requested-with"], "bp-asset-explorer", "sent with the explorer's own headers");
  assert.deepEqual(ticked(el), [], "ticks on deleted files go away");
  assert.equal(el.querySelectorAll(".bp-ae-tick").length, 1, "the grid reloaded without them");
  assert.equal(el.querySelector(".bp-ae-bulk").hidden, true);
}

// 2. A refused file stays ticked and says how many documents use it; force is
//    sent only after "Delete anyway" and its own confirm.
{
  const el = await mount(3);
  answer = (ids) => ({
    status: 409,
    body: {
      error: {
        code: "conflict",
        details: {
          deleted: ids.filter((id) => id !== "blob-1"),
          gone: [],
          refused: [{ id: "blob-1", code: "conflict", message: "refusing", referencedByCount: 3 }],
        },
      },
    },
  });
  tickBox(el, 0);
  tickBox(el, 1);
  await confirmDelete(el);
  assert.deepEqual(deletes(), [{ ids: ["blob-0", "blob-1"] }]);
  assert.deepEqual(ticked(el), ["asset-1"], "the refused file stays ticked");
  const panel = el.querySelector(".bp-ae-bulk-refused");
  assert.equal(panel.hidden, false);
  assert.match(panel.textContent, /1 file was not deleted/);
  assert.match(panel.textContent, /file-1\.png/);
  assert.match(panel.textContent, /Used by 3 documents/);

  answer = (ids) => ({ status: 200, body: { result: { deleted: ids, gone: [], refused: [] } } });
  confirmDelete.before = 1;
  const dialog = await confirmDelete(el, ".bp-ae-bulk-force");
  assert.match(dialog.textContent, /will show a broken file/);
  assert.deepEqual(deletes()[1], { ids: ["blob-1"], force: true }, "force goes only with the second confirm");
  assert.equal(el.querySelector(".bp-ae-bulk-refused").hidden, true);
  assert.deepEqual(ticked(el), []);
  confirmDelete.before = 0;
}

// 3. Shift+click ticks the range, Ctrl+A ticks everything loaded, Escape
//    clears, and 101 ids go in two calls of at most 100.
{
  const el = await mount(101);
  tickBox(el, 2);
  tickBox(el, 5, { shiftKey: true });
  assert.deepEqual(ticked(el), ["asset-2", "asset-3", "asset-4", "asset-5"]);
  const key = (k, opts = {}) =>
    window.document.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts }));
  key("Escape");
  assert.deepEqual(ticked(el), [], "Escape clears the ticks");
  box(el, 0).focus();
  key("a", { ctrlKey: true });
  assert.equal(ticked(el).length, 101, "Ctrl+A in the grid ticks every loaded file");

  await confirmDelete(el);
  const sent = deletes();
  assert.deepEqual(sent.map((b) => b.ids.length), [100, 1], "101 ids are sent in chunks of at most 100");
  assert.equal(new Set(sent.flatMap((b) => b.ids)).size, 101);
  assert.ok(sent.every((b) => !("force" in b)));
}

// 4. A file drop uploads through the Upload button's path, once per file; a
//    drag that carries no files is ignored.
{
  const el = await mount(1);
  const wrap = el.querySelector(".bp-ae-grid-wrap");
  const drag = (type, dataTransfer) => {
    const e = new window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(e, "dataTransfer", { value: dataTransfer });
    wrap.dispatchEvent(e);
    return e;
  };
  const files = ["a.png", "b.png"].map((n) => new window.File(["x"], n, { type: "image/png" }));

  const text = drag("dragenter", { types: ["text/plain"], files: [] });
  assert.equal(text.defaultPrevented, false, "a text drag is left to the browser");
  assert.equal(wrap.classList.contains("is-drop-target"), false);
  drag("drop", { types: ["text/plain"], files: [] });

  drag("dragenter", { types: ["Files"], files });
  assert.equal(wrap.classList.contains("is-drop-target"), true, "the drop zone shows while files are over the grid");
  const dropped = drag("drop", { types: ["Files"], files });
  assert.equal(dropped.defaultPrevented, true);
  assert.equal(wrap.classList.contains("is-drop-target"), false);
  await tick(60);
  const uploads = calls.filter((c) => c.path === `${BASE}/upload`);
  assert.equal(uploads.length, 2, "one upload per dropped file");
  assert.ok(uploads.every((c) => c.method === "POST" && c.headers["x-requested-with"] === "bp-asset-explorer"));
}

dom.window.close();
console.log("ok asset explorer bulk: one delete-many call, refusals kept and named, chunks of 100, drop uploads");
process.exit(0);
