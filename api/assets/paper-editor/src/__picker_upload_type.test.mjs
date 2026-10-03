// __picker_upload_type.test.mjs — task-88472d6e78f2a3cb: an image field must
// refuse a non-image file out loud, from the Upload dialog and from a drop.
//
// Found dogfooding (Lane F, 2026-10-03): Upload > choose notes.txt (the
// dialog's accept="image/*" is only a hint) stored the text file as the
// image and rendered "Image unavailable" with no error; a dropped non-image
// was refused in silence.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-media-picker.js in a
// node:vm (the __picker_metadata.test.mjs harness), captures the element class
// from customElements.define, and drives the shared file door the change and
// drop handlers call.
//
// Run: node src/__picker_upload_type.test.mjs
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
};
sandbox.window.HTMLElement = HTMLElementStub;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, "utf8"), sandbox, { filename: "bp-media-picker.js" });

const Picker = defined["bp-media-picker"];
assert.ok(Picker, "bp-media-picker registers its element class");

function picker() {
  const el = Object.create(Picker.prototype);
  el.uploaded = [];
  el.error = "";
  el._upload = (f) => el.uploaded.push(f.name);
  el._setError = (msg) => {
    el.error = msg || "";
  };
  return el;
}

check("the shared file door exists (the change and drop handlers both call it)", () => {
  assert.equal(typeof Picker.prototype._takeFile, "function");
  const src = fs.readFileSync(SRC, "utf8");
  assert.ok(!/files\[0\];\s*if \(f\) this\._upload\(f\)/.test(src), "the Upload change handler still bypasses the type check");
});

check("a text file is refused with an error naming the file and its type; nothing uploads", () => {
  const el = picker();
  el._takeFile({ name: "notes.txt", type: "text/plain" });
  assert.deepEqual(el.uploaded, []);
  assert.match(el.error, /notes\.txt/);
  assert.match(el.error, /text\/plain/);
});

check("an image uploads, and so does a file the browser could not type", () => {
  const el = picker();
  el._takeFile({ name: "cover.jpg", type: "image/jpeg" });
  el._takeFile({ name: "photo.heic", type: "" });
  assert.deepEqual(el.uploaded, ["cover.jpg", "photo.heic"]);
  assert.equal(el.error, "");
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\npicker upload type: all checks passed");
