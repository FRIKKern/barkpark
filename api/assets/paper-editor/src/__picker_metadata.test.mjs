// __picker_metadata.test.mjs — Gyldendal parity E1.7: the media picker's PURE
// value model keeps the DENORMALISED image metadata (width / height / lqip).
// Runs the TRACKED static asset api/priv/static/assets/bp-media-picker.js in
// a node:vm with minimal DOM stubs (the __picker_focal.test.mjs harness) and
// asserts window.__bpMediaPickerTestHook:
//
//   * parse: width / height / lqip read back (dimensions as numbers, from the
//     numbers OR the "1600" strings the asset document's fileInfo carries);
//     a non-positive or non-numeric dimension is null; a blank lqip is null
//   * serialize: written ONLY when known — the legacy shapes stay byte-identical
//     — so an alt / focal edit on a migrated cover never strips lqip/width/height
//   * round trip: parse(serialize(x)) == x for the full shape
//
// On main before E1.7, parse dropped the three keys and serialize never wrote
// them: the first cover swap in the Studio shipped an image the twin site
// could neither size nor blur-load.
//
// Run: node src/__picker_metadata.test.mjs
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

class HTMLElementStub {}
const sandbox = {
  window: {},
  HTMLElement: HTMLElementStub,
  customElements: { define() {} },
  CustomEvent: class {},
  console,
};
sandbox.window.HTMLElement = HTMLElementStub;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, "utf8"), sandbox, { filename: "bp-media-picker.js" });
const rawHook = sandbox.window.__bpMediaPickerTestHook;
const plain = (v) => (v == null ? v : JSON.parse(JSON.stringify(v)));
const hook = {
  parseValue: (...a) => plain(rawHook.parseValue(...a)),
  serializeValue: (...a) => rawHook.serializeValue(...a),
};
assert.ok(rawHook && rawHook.parseValue && rawHook.serializeValue, "test hook exposes parse/serialize");

const LQIP = "data:image/jpeg;base64,/9j/2wBDAAYEBQ";
const migrated = {
  url: "/media/files/2026/08/cover.jpg",
  assetId: "8dd4c35a-5ba2-4fcb-80df-9d35e05f6900",
  alt: "Cover of Over My Dead Body",
  focalX: 0.5,
  focalY: 0.25,
  width: 1600,
  height: 2527,
  lqip: LQIP,
};

check("parse: width / height / lqip read back as numbers and a string", () => {
  const p = hook.parseValue(JSON.stringify(migrated));
  assert.equal(p.width, 1600);
  assert.equal(p.height, 2527);
  assert.equal(p.lqip, LQIP);
  assert.equal(p.alt, migrated.alt);
});

check("parse: fileInfo-style string dimensions become numbers; junk is null", () => {
  const p = hook.parseValue(JSON.stringify({ url: "/x.jpg", assetId: "a1", width: "1600", height: "900" }));
  assert.equal(p.width, 1600);
  assert.equal(p.height, 900);
  const q = hook.parseValue(JSON.stringify({ url: "/x.jpg", assetId: "a1", width: "", height: -3, lqip: "" }));
  assert.equal(q.width, null);
  assert.equal(q.height, null);
  assert.equal(q.lqip, null);
  const bare = hook.parseValue("/x.jpg");
  assert.equal(bare.width, null);
  assert.equal(bare.lqip, null);
});

check("serialize: legacy shapes stay byte-identical when no metadata is known", () => {
  assert.equal(hook.serializeValue("/x.png", ""), "/x.png");
  assert.equal(hook.serializeValue("/x.png", "a1"), JSON.stringify({ url: "/x.png", assetId: "a1" }));
  assert.equal(
    hook.serializeValue("/x.png", "a1", { alt: "Cover", focalX: 0.5, focalY: 0.25, width: null, height: null, lqip: null }),
    JSON.stringify({ url: "/x.png", assetId: "a1", alt: "Cover", focalX: 0.5, focalY: 0.25 }),
  );
});

check("serialize: width / height / lqip are written when known — an alt edit keeps them", () => {
  const p = hook.parseValue(JSON.stringify(migrated));
  const edited = hook.serializeValue(p.url, p.assetId, { ...p, alt: "New alt" });
  const back = hook.parseValue(edited);
  assert.equal(back.alt, "New alt");
  assert.equal(back.width, 1600);
  assert.equal(back.height, 2527);
  assert.equal(back.lqip, LQIP);
  assert.equal(back.focalX, 0.5);
});

check("serialize: a fresh pick with dimensions but no lqip writes the dimensions only", () => {
  const v = hook.serializeValue("/y.jpg", "b2", { alt: "", focalX: null, focalY: null, width: "1200", height: 800, lqip: null });
  assert.deepEqual(JSON.parse(v), { url: "/y.jpg", assetId: "b2", width: 1200, height: 800 });
});

check("round trip: parse(serialize(x)) == x for the full shape", () => {
  const v = hook.serializeValue(migrated.url, migrated.assetId, migrated);
  assert.deepEqual(hook.parseValue(v), migrated);
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\npicker metadata: all checks passed");
