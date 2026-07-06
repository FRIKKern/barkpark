// __picker_chrome.test.mjs — pure-Node unit test for the t18a ghost-chrome media
// picker (pd-doctrine rule 6 — no chrome on atoms). Runs the TRACKED static asset
// api/priv/static/assets/bp-media-picker.js in a node:vm with minimal DOM stubs
// (HTMLElement / customElements / window), then asserts the PURE variant + menu
// model the WC exposes via window.__bpMediaPickerTestHook:
//
//   * ghost hides the actions row; default (attr absent / any other value) keeps it
//   * the context menu offers Upload + Browse always, Remove ONLY when a value is set
//   * canUpload:false drops the Upload item
//   * busy:true disables every item (the mirror of default chrome's _setBusy)
//
// The DOM-driven bits (the actual menu element, the reveal swap, bp-change wiring)
// are browser-only and exercised in the live editor; what's pinned here is the pure
// decision logic that governs them. Run: node src/__picker_chrome.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(
  __dirname,
  "../../../priv/static/assets/bp-media-picker.js"
);

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

// ── run the real static asset under minimal DOM stubs ────────────────────────
// The file references `document` / `fetch` only inside instance methods (never at
// module top level), so a class-shaped HTMLElement + a no-op customElements.define
// + a window object is enough to evaluate it and read the test hook.
const windowStub = {};
const context = {
  window: windowStub,
  HTMLElement: class HTMLElement {},
  customElements: { define() {} },
  document: undefined,
  fetch: undefined,
};
context.globalThis = context;
vm.createContext(context);
vm.runInContext(fs.readFileSync(SRC, "utf8"), context, { filename: SRC });

const hook = windowStub.__bpMediaPickerTestHook;

// The hook's arrays come from the vm realm (a different Array prototype), so
// assert.deepEqual would reject them as not reference-equal. Compare the plain
// string ids joined instead — strings cross realms cleanly.
const ids = (arg) => hook.menuItems(arg).map((i) => i.id).join(",");

check("the WC exposes the __bpMediaPickerTestHook pure model", () => {
  assert.ok(hook, "window.__bpMediaPickerTestHook is defined");
  assert.equal(typeof hook.menuItems, "function");
  assert.equal(typeof hook.showsActions, "function");
});

// ── showsActions: ghost hides the button row; everything else keeps it ───────

check("showsActions: ghost hides the actions row", () => {
  assert.equal(hook.showsActions("ghost"), false);
});

check("showsActions: default variant (attr absent / other values) keeps the row", () => {
  assert.equal(hook.showsActions(""), true);
  assert.equal(hook.showsActions(null), true);
  assert.equal(hook.showsActions(undefined), true);
  assert.equal(hook.showsActions("default"), true);
  assert.equal(hook.showsActions("full"), true);
});

// ── menuItems: Upload + Browse always; Remove only when a value is set ───────

check("menuItems: EMPTY field → Upload + Browse, NO Remove", () => {
  assert.equal(ids({ hasValue: false, canUpload: true }), "upload,browse");
});

check("menuItems: SET field → Upload + Browse + Remove", () => {
  const items = hook.menuItems({ hasValue: true, canUpload: true });
  assert.equal(items.map((i) => i.id).join(","), "upload,browse,remove");
  const remove = items.find((i) => i.id === "remove");
  assert.equal(remove.destructive, true, "Remove is styled destructive");
});

check("menuItems: Remove is ABSENT whenever there is no value", () => {
  assert.ok(!hook.menuItems({ hasValue: false }).some((i) => i.id === "remove"));
});

check("menuItems: canUpload:false drops the Upload item", () => {
  assert.equal(ids({ hasValue: true, canUpload: false }), "browse,remove");
});

check("menuItems: default args (no canUpload) still offer Upload", () => {
  assert.equal(ids({ hasValue: false }), "upload,browse");
  // and a bare call must not throw
  assert.equal(hook.menuItems().map((i) => i.id).join(","), "upload,browse");
});

check("menuItems: busy disables EVERY item (mirror of default chrome's _setBusy)", () => {
  const items = hook.menuItems({ hasValue: true, canUpload: true, busy: true });
  assert.equal(items.map((i) => i.id).join(","), "upload,browse,remove");
  assert.ok(items.every((i) => i.disabled === true), "all items disabled while busy");
});

check("menuItems: not busy leaves every item enabled", () => {
  assert.ok(hook.menuItems({ hasValue: true }).every((i) => !i.disabled));
  assert.ok(hook.menuItems({ hasValue: false, busy: false }).every((i) => !i.disabled));
});

check("menuItems: every item carries an id + a human label", () => {
  for (const item of hook.menuItems({ hasValue: true })) {
    assert.equal(typeof item.id, "string");
    assert.ok(item.label && item.label.length > 0, "label is non-empty");
  }
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall picker-chrome checks passed");
