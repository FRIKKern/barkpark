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

// task-ed1f8f527d2936ba: the empty drop target's own aria-label was a hard-coded
// "Add image", and the paper editor's image fields printed their copy from CSS
// (`content: "Add an image"`), so a Norwegian author saw English. The labels now
// ride the empty element as data-label-* in the viewer's language, and the
// stylesheet shows them through attr().
let PickerClass = null;
{
  const sb = {
    window: {},
    HTMLElement: HTMLElementStub,
    customElements: { define(_name, cls) { PickerClass = PickerClass || cls; } },
    CustomEvent: class {},
    console,
  };
  sb.window.HTMLElement = HTMLElementStub;
  vm.createContext(sb);
  vm.runInContext(fs.readFileSync(SRC, "utf8"), sb, { filename: "bp-media-picker.js" });
}
function renderEmpty(strings) {
  const el = Object.create(PickerClass.prototype);
  Object.assign(el, { _previewEl: { innerHTML: "" }, _meta: {}, _value: "", _busy: false, _strings: strings });
  el._isReferenceMode = () => false;
  el._setClearVisible = () => {};
  el._renderPreview();
  return el._previewEl.innerHTML;
}

check("the empty drop target carries its labels in the viewer's language", () => {
  assert.ok(PickerClass, "the picker class was captured from customElements.define");
  const nb = renderEmpty({
    add: "Legg til bilde",
    add_short: "+ Legg til bilde",
    add_an_image: "Legg til et bilde",
    add_featured: "Legg til et hovedbilde",
    drop_hint: "Slipp en fil, klikk for å laste opp, eller bla i biblioteket",
  });
  assert.match(nb, /aria-label="Legg til bilde"/);
  assert.match(nb, /data-label-short="\+ Legg til bilde"/);
  assert.match(nb, /data-label-add="Legg til et bilde"/);
  assert.match(nb, /data-label-featured="Legg til et hovedbilde"/);
  assert.match(nb, /data-label-hint="Slipp en fil, klikk for å laste opp, eller bla i biblioteket"/);
  const en = renderEmpty(undefined);
  assert.match(en, /aria-label="Add image"/);
  assert.match(en, /data-label-add="Add an image"/);
  assert.match(renderEmpty({ add: 'Say "hi" <b>' }), /aria-label="Say &quot;hi&quot; &lt;b&gt;"/, "a translation is escaped");
});

check("the paper-editor shell shows the stamped labels, not English literals", () => {
  const shell = fs.readFileSync(path.join(__dirname, "../../../priv/static/assets/bp-paper-editor-shell.css"), "utf8");
  for (const attr of ["data-label-short", "data-label-add", "data-label-featured", "data-label-hint"]) {
    assert.ok(shell.includes(`content: attr(${attr})`), `shell CSS does not show ${attr}`);
  }
  for (const lit of ['content: "+ Add image"', 'content: "Add an image"', 'content: "Add a featured image"', 'content: "Drop a file']) {
    assert.ok(!shell.includes(lit), `English CSS content still hard-coded: ${lit}`);
  }
});

if (failures > 0) {
  console.log(`picker strings: ${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("picker strings: all checks passed");
