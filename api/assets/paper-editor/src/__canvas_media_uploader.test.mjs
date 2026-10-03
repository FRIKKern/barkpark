// A picture pasted or dropped on the Studio canvas uploads.
//
// Found dogfooding the Studio paper canvas (2026-10-03): the canvas uploads pasted
// and dropped pictures through a host-injected `mediaUploader`, and Studio never
// injected one. Every picture showed "Upload failed: no media uploader is
// connected" and the paper stored an image block with no src. The canvas hook now
// connects the same scoped upload the media picker makes.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:pics" data-paper-rev="3">
    <div class="bp-paper-editor">
      <div id="paper-canvas-pics-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"
           data-canvas-dataset="production" data-canvas-token="" data-canvas-scope-prefix="/w/acme/p/site">
        <bp-paper-canvas></bp-paper-canvas>
      </div>
    </div>
  </main></body>`, { url: "http://localhost/w/acme/p/site/studio" });
const { window } = dom;
const calls = [];
let reply = { ok: true, status: 200, json: async () => ({ result: { url: "/w/acme/p/site/media/files/x.png", assetDocId: "asset-x" } }) };
const fetchStub = async (url, init) => {
  calls.push({ url, init });
  return reply;
};
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  fetch: fetchStub,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const runEl = window.document.querySelector("#paper-canvas-pics-run-0");
const canvas = runEl.querySelector("bp-paper-canvas");
const hook = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
  el: runEl,
  handleEvent: () => {},
  pushEvent: () => Promise.resolve({}),
};

try {
  hook.mounted();
  assert.equal(typeof canvas.mediaUploader, "function", "the Studio canvas has a media uploader");

  const file = new window.File(["png-bytes"], "red-box.png", { type: "image/png" });

  // Session (no bearer on the page): the scoped upload with the CSRF header.
  const result = await canvas.mediaUploader(file);
  assert.equal(JSON.stringify(result), JSON.stringify({ src: "/w/acme/p/site/media/files/x.png" }));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/w/acme/p/site/v1/media/production/upload");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.credentials, "same-origin");
  assert.equal(calls[0].init.headers["x-requested-with"], "bp-paper-canvas");
  assert.equal(calls[0].init.headers.Authorization, undefined);
  assert.equal(calls[0].init.body.get("file").name, "red-box.png");
  assert.equal(calls[0].init.body.get("dataset"), "production");

  // A token page: the bearer instead of the CSRF header.
  canvas.setAttribute("data-token", "tok-123");
  await canvas.mediaUploader(file);
  assert.equal(calls[1].init.headers.Authorization, "Bearer tok-123");
  assert.equal(calls[1].init.headers["x-requested-with"], undefined);

  // A refusal is an error the image node shows, not a src-less success.
  reply = { ok: false, status: 403, json: async () => ({}) };
  await assert.rejects(canvas.mediaUploader(file), /refused the upload \(403\)/);

  console.log("PASS canvas_media_uploader: the Studio canvas uploads pasted and dropped pictures");
} finally {
  hook.destroyed?.();
  window.close();
}
