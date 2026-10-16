// __picker_asset_ref.test.mjs — task-7ea6f41cede5ee97: the media picker reads
// and writes an image in Sanity's shape,
// `{_type, asset: {_ref, _type: "reference"}, hotspot, crop, alt, …}`.
//
// Found by the gyldendal.no twin's Studio parity audit (2026-10-16): every
// imported image field read "No image selected". The twin keeps Sanity's
// values (its decision 0008), and bp-media-picker read only `url` off the
// value, so `{asset: {_ref: "image-<sha1>-2048x1366-jpg"}}` had no preview,
// and a pick wrote `{url, assetId}`, a shape the site's `asset->` reads skip.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-media-picker.js in a
// node:vm (the __picker_reference_preview.test.mjs harness).
//
// Run: node src/__picker_asset_ref.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(__dirname, "../../../priv/static/assets/bp-media-picker.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
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
    return { ok: false, status: 404, async json() { return {}; } };
  },
};
sandbox.window.HTMLElement = HTMLElementStub;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, "utf8"), sandbox, { filename: "bp-media-picker.js" });

const hook = sandbox.window.__bpMediaPickerTestHook;
const Picker = defined["bp-media-picker"];
const plain = (v) => (v == null ? v : JSON.parse(JSON.stringify(v)));

const REF = "image-2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366-jpg";
const STORED = {
  _type: "imageAsset",
  alt: "Lærelyst kan læres",
  caption: "Foto: Gyldendal",
  asset: { _ref: REF, _type: "reference" },
  crop: { _type: "sanity.imageCrop", top: 0, bottom: 0.1, left: 0, right: 0 },
  hotspot: { _type: "sanity.imageHotspot", x: 0.5, y: 0.4, width: 0.6, height: 0.5 },
};

function picker(attrs) {
  const el = Object.create(Picker.prototype);
  el._meta = { url: "", assetId: "", alt: "", focalX: null, focalY: null, width: null, height: null, lqip: null, mime: "", assetRef: "", source: null };
  el._assetRefShape = false;
  el.getAttribute = (k) => (attrs && k in attrs ? attrs[k] : null);
  el.hasAttribute = (k) => !!(attrs && k in attrs);
  el._renderPreview = () => {};
  el._setError = () => {};
  el._emit = () => {};
  return el;
}

assert.ok(hook && hook.serializeAssetRefValue && hook.sanityImageUrl, "test hook exposes the reference-shape helpers");

check("parse reads the ref, alt and hotspot of a Sanity image, and its size from the id", () => {
  const p = plain(hook.parseValue(JSON.stringify(STORED)));
  assert.equal(p.assetRef, REF);
  assert.equal(p.alt, "Lærelyst kan læres");
  assert.equal(p.focalX, 0.5);
  assert.equal(p.focalY, 0.4);
  assert.equal(p.width, 2048);
  assert.equal(p.height, 1366);
  assert.deepEqual(p.source, STORED);
});

check("a Sanity image id maps to Barkpark's Sanity-compatible image URL", () => {
  assert.equal(
    hook.sanityImageUrl(REF, "/w/gyldendal-no/p/default", "production", 800),
    "/w/gyldendal-no/p/default/images/barkpark/production/2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366.jpg?w=800&fit=max"
  );
  assert.equal(hook.sanityImageUrl("asset-8aa97e08", "", "production"), null);
});

check("the element shows the image of a stored Sanity value (main drew 'No image selected')", () => {
  const el = picker({ "scope-prefix": "/w/gyldendal-no/p/default", dataset: "production" });
  el._takeAssetRef(hook.parseValue(JSON.stringify(STORED)));
  assert.equal(
    el._meta.url,
    "/w/gyldendal-no/p/default/images/barkpark/production/2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366.jpg?w=800&fit=max"
  );
  assert.equal(requested.length, 0, "a Sanity id needs no request");
});

check("an alt edit writes the same object back with the new alt; nothing is added", () => {
  const p = hook.parseValue(JSON.stringify(STORED));
  const out = JSON.parse(hook.serializeAssetRefValue(Object.assign({}, p, { alt: "Ny tekst" })));
  assert.deepEqual(out, Object.assign({}, STORED, { alt: "Ny tekst" }));
});

check("a focal click moves the hotspot centre and keeps its size", () => {
  const p = hook.parseValue(JSON.stringify(STORED));
  const out = JSON.parse(hook.serializeAssetRefValue(Object.assign({}, p, { focalX: 0.25, focalY: 0.75 })));
  assert.deepEqual(out.hotspot, { _type: "sanity.imageHotspot", x: 0.25, y: 0.75, width: 0.6, height: 0.5 });
  assert.deepEqual(out.crop, STORED.crop);
});

check("a new pick points at the asset document and drops the old crop and hotspot", () => {
  const el = picker({ dataset: "production" });
  const p = hook.parseValue(JSON.stringify(STORED));
  el._meta = Object.assign(el._meta, p);
  el._takeAssetRef(p);
  el._select({ url: "/media/files/new.jpg", assetId: "drafts.asset-8aa97e08-6611", width: 1000, height: 667 });
  const out = JSON.parse(el.value);
  assert.deepEqual(out, {
    _type: "imageAsset",
    alt: "Lærelyst kan læres",
    caption: "Foto: Gyldendal",
    asset: { _ref: "asset-8aa97e08-6611", _type: "reference" },
  });
});

check("Remove clears the value, and the next pick still writes the reference shape", () => {
  const el = picker({ dataset: "production" });
  const p = hook.parseValue(JSON.stringify(STORED));
  el._meta = Object.assign(el._meta, p);
  el._takeAssetRef(p);
  el._clearValue();
  assert.equal(el.value, "");
  el._select({ url: "/media/files/new.jpg", assetId: "asset-8aa97e08" });
  assert.deepEqual(JSON.parse(el.value), { _type: "image", asset: { _ref: "asset-8aa97e08", _type: "reference" } });
});

check("an empty field declared value-shape=asset-ref writes the reference shape", () => {
  const el = picker({ "value-shape": "asset-ref" });
  el._takeAssetRef(hook.parseValue(""));
  el._select({ url: "/media/files/new.jpg", assetId: "asset-8aa97e08" });
  assert.deepEqual(JSON.parse(el.value), { _type: "image", asset: { _ref: "asset-8aa97e08", _type: "reference" } });
});

check("an empty field without the declaration keeps writing {url, assetId}", () => {
  const el = picker({});
  el._takeAssetRef(hook.parseValue(""));
  el._select({ url: "/media/files/new.jpg", assetId: "asset-8aa97e08" });
  assert.deepEqual(JSON.parse(el.value), { url: "/media/files/new.jpg", assetId: "8aa97e08" });
});

if (failures) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall passed");
