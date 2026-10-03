// __picker_reference_preview.test.mjs — task-b6c5a62bd7b6082e: a mediaAsset
// REFERENCE field must show the picked asset after a reload.
//
// Found dogfooding (Lane F, 2026-10-03): pick an uploaded asset into a
// post's Featured Asset, reload, and the picker shows "Image unavailable".
// `_resolveReferencePreview` fetched the asset document with the default
// PUBLISHED perspective (every uploaded asset is a draft, `drafts.asset-<uuid>`),
// by the bare uuid the reference stores (the document id is `asset-<uuid>`),
// and read `fileInfo` off the body although the scoped mirror wraps the
// document in {result: …}.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-media-picker.js in a
// node:vm (the __picker_metadata.test.mjs harness), captures the element class
// from customElements.define, and drives the method with a stubbed fetch that
// answers the way the server does: 404 unless the request names the drafts
// perspective and the `asset-` id.
//
// Run: node src/__picker_reference_preview.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(__dirname, "../../../priv/static/assets/bp-media-picker.js");

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const requested = [];
class HTMLElementStub {}
const defined = {};
const sandbox = {
  window: {},
  HTMLElement: HTMLElementStub,
  customElements: {
    define(name, cls) {
      defined[name] = cls;
    },
  },
  CustomEvent: class {},
  console,
  async fetch(url) {
    requested.push(url);
    const ok = url.includes("/mediaAsset/asset-a97b") && url.includes("perspective=drafts");
    return {
      ok,
      status: ok ? 200 : 404,
      async json() {
        return {
          result: {
            _id: "drafts.asset-a97b",
            fileInfo: { url: "/media/files/og-default.jpg", mimeType: "image/jpeg" },
          },
        };
      },
    };
  },
};
sandbox.window.HTMLElement = HTMLElementStub;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, "utf8"), sandbox, { filename: "bp-media-picker.js" });

const Picker = defined["bp-media-picker"];
assert.ok(Picker, "bp-media-picker registers its element class");

function picker() {
  const el = Object.create(Picker.prototype);
  el._meta = { url: "", assetId: "a97b", alt: "", mime: "" };
  el._dataset = () => "production";
  el._token = () => "";
  el._scopePrefix = () => "/w/default/p/default";
  el._rendered = 0;
  el._renderPreview = () => {
    el._rendered += 1;
  };
  return el;
}

await check("a reference to an uploaded (draft) asset resolves its URL by the asset- id", async () => {
  requested.length = 0;
  const el = picker();
  await el._resolveReferencePreview("a97b");
  assert.equal(el._meta.url, "/media/files/og-default.jpg", `requested: ${requested.join(", ")}`);
  assert.equal(el._meta.mime, "image/jpeg");
  assert.ok(el._rendered > 0, "the preview re-renders once the URL is known");
});

await check("an id that already carries asset- is not prefixed twice", async () => {
  requested.length = 0;
  const el = picker();
  await el._resolveReferencePreview("asset-a97b");
  assert.equal(el._meta.url, "/media/files/og-default.jpg");
  assert.ok(!requested[0].includes("asset-asset-"), requested[0]);
});

// The mount path: a reference stores the bare uuid, which the value parser
// reads as a "url". Before the fix the picker painted <img src="a97bf457-…">
// and never asked for the asset. Only something an <img> can load may skip
// the lookup.
await check("a stored asset id is not mistaken for an image URL on mount", async () => {
  const looks = sandbox.bpLooksLikeUrl;
  assert.equal(typeof looks, "function", "bpLooksLikeUrl is defined");
  assert.equal(looks("a97bf457-9675-460a-9900-f10d2bca85bb"), false);
  assert.equal(looks("asset-a97b"), false);
  assert.equal(looks("/media/files/og.jpg"), true);
  assert.equal(looks("https://cdn.example.com/og.jpg"), true);
  assert.equal(looks("data:image/png;base64,AAAA"), true);
  const src = fs.readFileSync(SRC, "utf8");
  assert.match(src, /this\._meta\.url = bpLooksLikeUrl\(parsed\.url\) \? parsed\.url : "";/);
});

// Before the asset resolves, the preview must not paint the ID as an <img>:
// that image's error event fired AFTER the real preview landed and replaced
// it with "Image unavailable".
await check("an unresolved reference renders no <img> pointing at the asset id", async () => {
  const el = picker();
  delete el._renderPreview; // use the real one
  el._value = "a97bf457-9675-460a-9900-f10d2bca85bb";
  el._meta = { url: "", assetId: el._value, alt: "" };
  el._isReferenceMode = () => true;
  el._wantsHotspot = () => false;
  el._setClearVisible = () => {};
  el._previewEl = { innerHTML: "", querySelector: () => null };
  el._renderPreview();
  assert.ok(!/<img[^>]*a97bf457/.test(el._previewEl.innerHTML), el._previewEl.innerHTML);
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\npicker reference preview: all checks passed");
