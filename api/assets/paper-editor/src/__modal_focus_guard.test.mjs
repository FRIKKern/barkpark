// Run-8 dialog sweep: every aria-modal dialog a static Studio script builds
// (the media library explorer and browser) manages focus through the ONE
// shared helper, window.BarkparkModalFocus.trap (bp-modal-focus.js), not a
// private copy. LiveView dialogs are held by modal_focus_guard_test.exs.
// A predicate over the files, not a list: a new script that declares
// aria-modal and does not call trap() reds here.
// Run: node src/__modal_focus_guard.test.mjs
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

const dir = new URL("../../../priv/static/assets/", import.meta.url);
const scripts = readdirSync(dir)
  .filter((f) => f.endsWith(".js") && !f.endsWith(".min.js") && !f.includes("bundle") && f !== "bp-modal-focus.js")
  .map((f) => ({ f, src: readFileSync(new URL(f, dir), "utf8") }));

const declaresModal = (src) => /aria-modal=\\?"true\\?"|setAttribute\("aria-modal", ?"true"\)/.test(src);
const usesTrap = (src) => /BarkparkModalFocus/.test(src) && /\.trap\(/.test(src);

const modal = scripts.filter(({ src }) => declaresModal(src));
assert.ok(modal.length >= 2, `found ${modal.length} scripts declaring an aria-modal dialog; the scan is broken`);

const missing = modal.filter(({ src }) => !usesTrap(src)).map(({ f }) => f);
assert.deepEqual(missing, [], `aria-modal dialogs without the shared trap(): ${missing.join(", ")}`);

// CONTROL: the predicate can fail.
const explorer = modal.find(({ f }) => f === "bp-asset-explorer.js");
assert.ok(explorer, "the explorer declares its aria-modal folder dialog");
assert.equal(usesTrap(explorer.src.replaceAll(".trap(", ".nope(")), false);

console.log(`ok modal focus guard: ${modal.length} scripts with an aria-modal dialog all use trap()`);
