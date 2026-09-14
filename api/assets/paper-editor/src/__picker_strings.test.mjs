// Gyldendal parity E7 — the picker web components render the strings the
// server stamps on the element as `data-strings` (the workspace's locale),
// and fall back to the English literal for every key that is absent, so an
// element without the attribute is byte-identical to before.
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
// Values cross the vm boundary with foreign prototypes; compare plain copies.
const plain = (v) => (v == null ? v : JSON.parse(JSON.stringify(v)));
const hook = {
  menuItems: (...a) => plain(rawHook.menuItems(...a)),
  strings: (...a) => plain(rawHook.strings(...a)),
};
assert.ok(rawHook && rawHook.menuItems && rawHook.strings, "test hook exposes menuItems + strings");

const NB = { upload: "Last opp fil", browse: "Bla i mediebiblioteket", remove: "Fjern bilde" };

check("no data-strings: the menu keeps its English literals byte-for-byte", () => {
  const items = hook.menuItems({ hasValue: true, canUpload: true, busy: false });
  assert.deepEqual(
    items.map((i) => i.label),
    ["Upload file", "Browse library", "Remove image"]
  );
});

check("data-strings from the server: the menu speaks the workspace's language", () => {
  const items = hook.menuItems({ hasValue: true, canUpload: true, busy: false, strings: NB });
  assert.deepEqual(
    items.map((i) => i.label),
    ["Last opp fil", "Bla i mediebiblioteket", "Fjern bilde"]
  );
  assert.equal(items[2].destructive, true, "the destructive flag survives translation");
});

check("the default chrome carries no English literal the workspace locale cannot reach", () => {
  const src = fs.readFileSync(SRC, "utf8");
  for (const lit of [">Browse library<", ">Remove<", "<span>Upload</span>", ">Alt text<", 'placeholder="Describe the image']) {
    assert.ok(!src.includes(lit), `chrome literal still hard-coded: ${lit}`);
  }
});

check("a partial or malformed data-strings falls back per key, never throws", () => {
  const partial = hook.menuItems({ hasValue: true, strings: { browse: "Bla i mediebiblioteket" } });
  assert.deepEqual(
    partial.map((i) => i.label),
    ["Upload file", "Bla i mediebiblioteket", "Remove image"]
  );
  assert.deepEqual(hook.strings({ dataset: { strings: "{not json" } }), {});
  assert.deepEqual(hook.strings({ dataset: {} }), {});
  assert.deepEqual(hook.strings(null), {});
  assert.deepEqual(hook.strings({ dataset: { strings: JSON.stringify(NB) } }), NB);
});

if (failures > 0) {
  console.log(`picker strings: ${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("picker strings: all checks passed");
