// __desk_lang_tabs_keys.test.mjs: the keys of a localizedText field's
// language tabs on the desk (bp-desk-lang-tabs.js, `Fields.LocalizedTabs`),
// the TanStack Studio's LocalizedTextInput.
//
// On a tab: ArrowRight and ArrowLeft move to the next and the previous
// language, round; Home and End to the first and the last. The tab moved to
// is clicked (its click is the LiveView JS command that selects it) and
// takes the focus. Other keys, keys with a modifier, and keys on anything
// that is not a tab do nothing.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-lang-tabs.js
// under jsdom.
//
// Run: node ../paper-editor-host-tests/__desk_lang_tabs_keys.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/volume;v-1",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk-lang-tabs.js");
assert.ok(window.BarkparkDeskLangTabs, "the script registers itself");

const doc = window.document;
const LANGS = ["nob", "eng", "deu"];
doc.body.innerHTML =
  `<fieldset><legend id="blurb-label">Blurb</legend><div class="localized">` +
  `<div class="lang-tabs" role="tablist" aria-labelledby="blurb-label">` +
  LANGS.map(
    (l, i) =>
      `<button type="button" role="tab" id="blurb-tab-${l}" aria-selected="${i === 0}" tabindex="${i === 0 ? 0 : -1}">${l}</button>`,
  ).join("") +
  `</div><textarea id="blurb.nob"></textarea></div></fieldset>`;

const tab = (l) => doc.getElementById(`blurb-tab-${l}`);
const clicks = [];
for (const l of LANGS) tab(l).addEventListener("click", () => clicks.push(l));

const press = (el, key, init = {}) => {
  const e = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  el.dispatchEvent(e);
  return e;
};

const step = (from, key, to) => {
  tab(from).focus();
  clicks.length = 0;
  const e = press(tab(from), key);
  assert.deepEqual(clicks, [to], `${key} on ${from} clicks ${to}`);
  assert.equal(doc.activeElement, tab(to), `${key} on ${from} focuses ${to}`);
  assert.ok(e.defaultPrevented, `${key} is the tablist's`);
};

step("nob", "ArrowRight", "eng");
step("eng", "ArrowRight", "deu");
step("deu", "ArrowRight", "nob"); // round
step("nob", "ArrowLeft", "deu"); // round
step("deu", "ArrowLeft", "eng");
step("eng", "Home", "nob");
step("nob", "End", "deu");

// Not the tablist's keys.
for (const [key, init] of [["Tab", {}], ["Enter", {}], ["ArrowDown", {}], ["ArrowRight", { altKey: true }], ["ArrowRight", { metaKey: true }]]) {
  tab("eng").focus();
  clicks.length = 0;
  const e = press(tab("eng"), key, init);
  assert.deepEqual(clicks, [], `${key} clicks nothing`);
  assert.equal(doc.activeElement, tab("eng"), `${key} moves nothing`);
  assert.equal(e.defaultPrevented, false, `${key} is left alone`);
}

// A key in the text is the text's.
const text = doc.getElementById("blurb.nob");
text.focus();
clicks.length = 0;
assert.equal(press(text, "ArrowRight").defaultPrevented, false);
assert.deepEqual(clicks, []);

console.log("desk lang tabs keys: ok");
