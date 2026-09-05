// __picker_focal.test.mjs — Gyldendal parity E1: the media picker's PURE value
// model with the focal point + alt text. Runs the TRACKED static asset
// api/priv/static/assets/bp-media-picker.js in a node:vm with minimal DOM stubs
// (the __picker_chrome.test.mjs harness) and asserts window.__bpMediaPickerTestHook:
//
//   * parse: a bare URL, {url,assetId}, and {url,assetId,alt,focalX,focalY} all read;
//     a focal outside 0..1 is clamped; garbage is null
//   * serialize: a bare URL stays a bare URL; {url,assetId} stays TWO keys; alt /
//     focalX / focalY are written ONLY when set — every value the picker ever
//     wrote keeps round-tripping byte-identically
//   * focalFromClick: the click's fraction inside the image box, clamped
//
// Run: node src/__picker_focal.test.mjs
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
// Objects born inside the vm context carry that context's Object prototype, so
// strict deepEqual sees "same structure, not reference-equal". Normalise every
// hook result through JSON so the assertions compare VALUES.
const plain = (v) => (v == null ? v : JSON.parse(JSON.stringify(v)));
const hook = {
  parseValue: (...a) => plain(rawHook.parseValue(...a)),
  serializeValue: (...a) => rawHook.serializeValue(...a),
  focalFromClick: (...a) => plain(rawHook.focalFromClick(...a)),
};
assert.ok(rawHook && rawHook.parseValue && rawHook.serializeValue && rawHook.focalFromClick, "test hook exposes parse/serialize/focal");

check("parse: bare URL, {url,assetId}, and the rich shape all read; focal is clamped; garbage is null", () => {
  assert.deepEqual(hook.parseValue("/x.png"), { url: "/x.png", assetId: "", alt: "", focalX: null, focalY: null });
  assert.deepEqual(hook.parseValue(JSON.stringify({ url: "/x.png", assetId: "a1" })), {
    url: "/x.png", assetId: "a1", alt: "", focalX: null, focalY: null,
  });
  assert.deepEqual(
    hook.parseValue(JSON.stringify({ url: "/x.png", assetId: "a1", alt: "Cover", focalX: 0.25, focalY: 1.7 })),
    { url: "/x.png", assetId: "a1", alt: "Cover", focalX: 0.25, focalY: 1 },
  );
  assert.equal(hook.parseValue(JSON.stringify({ url: "/x.png", focalX: "nope" })).focalX, null);
  assert.deepEqual(hook.parseValue(""), { url: "", assetId: "", alt: "", focalX: null, focalY: null });
});

check("serialize: legacy shapes stay byte-identical; alt / focal are written only when set", () => {
  assert.equal(hook.serializeValue("/x.png", ""), "/x.png");
  assert.equal(hook.serializeValue("/x.png", "", { alt: "", focalX: null, focalY: null }), "/x.png");
  assert.equal(hook.serializeValue("/x.png", "a1"), JSON.stringify({ url: "/x.png", assetId: "a1" }));
  assert.equal(
    hook.serializeValue("/x.png", "a1", { alt: "Cover", focalX: 0.5, focalY: 0.25 }),
    JSON.stringify({ url: "/x.png", assetId: "a1", alt: "Cover", focalX: 0.5, focalY: 0.25 }),
  );
  // a bare-URL image that gains an alt becomes an object (there is no other place for it)
  assert.equal(hook.serializeValue("/x.png", "", { alt: "Cover" }), JSON.stringify({ url: "/x.png", assetId: "", alt: "Cover" }));
});

check("round trip: parse(serialize(x)) == x for the rich shape", () => {
  const v = hook.serializeValue("/x.png", "a1", { alt: "Cover", focalX: 0.5, focalY: 0.25 });
  assert.deepEqual(hook.parseValue(v), { url: "/x.png", assetId: "a1", alt: "Cover", focalX: 0.5, focalY: 0.25 });
});

check("focalFromClick: the fraction inside the box, clamped; a degenerate box is null", () => {
  const rect = { left: 100, top: 50, width: 200, height: 100 };
  assert.deepEqual(hook.focalFromClick(rect, 150, 100), { x: 0.25, y: 0.5 });
  assert.deepEqual(hook.focalFromClick(rect, 10, 10), { x: 0, y: 0 });
  assert.deepEqual(hook.focalFromClick(rect, 900, 900), { x: 1, y: 1 });
  assert.equal(hook.focalFromClick({ left: 0, top: 0, width: 0, height: 0 }, 5, 5), null);
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\npicker focal: all checks passed");
