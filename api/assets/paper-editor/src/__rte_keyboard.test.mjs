// __rte_keyboard.test.mjs — task-e471f8bd50a1aefd: the Classic editor's rich-text
// toolbar acted only on mousedown, so Enter or Space on a focused Bold, Italic,
// Link, Set or Remove did nothing; the buttons were named by their glyph ("B");
// and the text body had no role or name. A keyboard press (a click with detail 0)
// now acts, a pointer still acts once, every button is named by its word, and
// the body is a named multiline textbox.
//
// Runs the TRACKED static asset under jsdom.
// Run: node src/__rte_keyboard.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
const calls = [];
window.document.execCommand = (cmd) => {
  calls.push(cmd);
  return true;
};
await import("../../../priv/static/assets/bp-rich-text-editor.js");

function mount(attrs = {}) {
  const el = document.createElement("bp-rich-text-editor");
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  document.body.appendChild(el);
  return el;
}

// A keyboard activation: Enter/Space on a <button> fires `click` with detail 0.
const keyPress = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));
// A pointer press: mousedown, then a click with detail 1.
const pointerPress = (el) => {
  el.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true, detail: 1 }));
  el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 1 }));
};

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

const NB = { Bold: "Fet", Italic: "Kursiv", Link: "Lenke", "Link address": "Lenkeadresse" };
const el = mount({ "data-strings": JSON.stringify(NB), "data-label": "Tekst" });
const bold = el.querySelector('[data-cmd="bold"]');
const italic = el.querySelector('[data-cmd="italic"]');
const link = el.querySelector(".bp-rte-link");
const row = el.querySelector(".bp-rte-linkrow");

check("Enter or Space on Bold and Italic runs the command", () => {
  calls.length = 0;
  keyPress(bold);
  keyPress(italic);
  assert.deepEqual(calls, ["bold", "italic"]);
});

check("a pointer press on Bold runs the command once", () => {
  calls.length = 0;
  pointerPress(bold);
  assert.deepEqual(calls, ["bold"]);
});

check("Enter on Link opens the link row; a pointer press toggles it once", () => {
  row.hidden = true;
  keyPress(link);
  assert.equal(row.hidden, false);
  pointerPress(link);
  assert.equal(row.hidden, true);
});

check("Enter on Remove unlinks and closes the row", () => {
  row.hidden = false;
  calls.length = 0;
  keyPress(el.querySelector(".bp-rte-unset"));
  assert.deepEqual(calls, ["unlink"]);
  assert.equal(row.hidden, true);
});

check("every toolbar button is named by its word, in the stamped language", () => {
  assert.equal(bold.getAttribute("aria-label"), "Fet");
  assert.equal(italic.getAttribute("aria-label"), "Kursiv");
  assert.equal(link.getAttribute("aria-label"), "Lenke");
  assert.equal(el.querySelector(".bp-rte-url").getAttribute("aria-label"), "Lenkeadresse");
});

check("the text body is a multiline textbox named by the field label", () => {
  const body = el.querySelector(".bp-rte-body");
  assert.equal(body.getAttribute("role"), "textbox");
  assert.equal(body.getAttribute("aria-multiline"), "true");
  assert.equal(body.getAttribute("aria-label"), "Tekst");
});

check("with no stamped words the names read English", () => {
  const en = mount();
  assert.equal(en.querySelector('[data-cmd="bold"]').getAttribute("aria-label"), "Bold");
  assert.equal(en.querySelector(".bp-rte-body").hasAttribute("aria-label"), false);
  en.remove();
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall rich-text keyboard checks passed");
process.exit(0);
