// task-c09196a99fad3d3a: "New folder" posted a create+publish batch to the
// token-only /v1/data/mutate, so an account (cookie) session got 403. It now
// posts { title } to the media-scoped folder door, with the session header.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  runScripts: "outside-only",
  url: "http://localhost/",
});
const { window } = dom;
for (const file of ["bp-search-intel.js", "bp-asset-explorer.js"]) {
  window.eval(readFileSync(new URL(`../../../priv/static/assets/${file}`, import.meta.url), "utf8"));
}
const Explorer = window.customElements.get("bp-asset-explorer");
const create = Explorer.prototype._createCollection;

async function run(token, response) {
  const calls = [];
  const toasts = [];
  window.fetch = async (url, init) => {
    calls.push({ url, init });
    return response;
  };
  const host = Object.create(Explorer.prototype);
  Object.assign(host, {
    _token: () => token,
    _scopePrefix: () => "/w/agency/p/default",
    _dataset: () => "production",
    _toast: (m) => toasts.push(m),
    _loadCollections: async () => {},
    _loadAssets: async () => {},
    _renderCollectionInspector: () => {},
  });
  await create.call(host, "Covers");
  return { calls, toasts, host };
}

const ok = { ok: true, status: 200, json: async () => ({ result: { id: "col-abc", title: "Covers" } }) };
const session = await run("", ok);
assert.equal(session.calls.length, 1);
assert.equal(session.calls[0].url, "/w/agency/p/default/v1/media/production/collections");
assert.equal(session.calls[0].init.method, "POST");
assert.equal(session.calls[0].init.headers["x-requested-with"], "bp-asset-explorer",
  "an account session sends the header the cookie branch requires");
assert.deepEqual(JSON.parse(session.calls[0].init.body), { title: "Covers" });
assert.equal(session.host._collectionId, "col-abc", "the folder opened is the one the server made");
assert.ok(session.toasts.includes("Collection created"));

const refused = await run("", { ok: false, status: 403, json: async () => ({}) });
assert.ok(refused.toasts.includes("Could not create collection"));
assert.equal(refused.host._collectionId, undefined);

console.log("ok asset explorer collection create: media-scoped door, session header, server id");
