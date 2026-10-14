// __block_menu_edit_mounted.test.mjs — a declared object block's … menu has Edit
// (Sanity's block object menu: Edit, Remove), which opens its field editor, as a
// double-click does; the edit saves as ONE replace-block. A prose block, and an
// object block whose kind declares no fields, offer no Edit; nor does a read-only
// canvas.
// Run: node src/canvas/__block_menu_edit_mounted.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement",
  "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Option", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const VOCAB = {
  styles: ["normal"],
  of: [
    { name: "factBox", title: "Faktaboks", fields: [{ name: "body", title: "Body", type: "text" }] },
    { name: "rule", title: "Rule", fields: [] },
  ],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro." }] },
  { id: "fb1", type: "factBox", body: "Old fact." },
  { id: "r1", type: "rule" },
];
let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}
const menuItems = () => [...document.querySelectorAll(".bp-block-menu [data-action]")].map((b) => b.dataset.action);
const dialog = () => document.querySelector(".bp-inline-object-dialog");

try {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  const handle = canvas._handle;
  const openAt = (i) => { handle._index = i; handle._openMenu(); };

  check("a declared object block's menu offers Edit first; a prose block and a field-less kind do not", () => {
    openAt(1);
    assert.equal(menuItems()[0], "edit", JSON.stringify(menuItems()));
    assert.equal(document.querySelector('.bp-block-menu [data-action="edit"]').textContent.trim().endsWith("Edit"), true);
    handle._closeMenu();
    openAt(0);
    assert.ok(!menuItems().includes("edit"), "paragraph");
    handle._closeMenu();
    openAt(2);
    assert.ok(!menuItems().includes("edit"), "a kind with no fields");
    handle._closeMenu();
  });

  check("Edit opens its field editor over the stored value", () => {
    openAt(1);
    document.querySelector('.bp-block-menu [data-action="edit"]').click();
    assert.equal(document.querySelector(".bp-block-menu"), null, "the menu closed");
    assert.ok(dialog(), "the field editor opened");
    assert.equal(dialog().querySelector('[data-field="body"]').value, "Old fact.");
  });

  dialog().querySelector('[data-field="body"]').value = "New fact.";
  dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
  canvas.flushPendingChanges();
  await tick(20);
  check("its Save is ONE replace-block", () => {
    const mine = ops.filter((op) => op.id === "fb1");
    assert.equal(mine.length, 1, JSON.stringify(ops));
    assert.equal(mine[0].op, "replace-block");
    assert.equal(mine[0].block.body, "New fact.");
  });

  check("a read-only canvas offers no Edit", () => {
    canvas.setAttribute("editable", "false");
    openAt(1);
    assert.ok(!menuItems().includes("edit"), JSON.stringify(menuItems()));
    handle._closeMenu();
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nblock menu edit mounted: all checks passed");
  process.exit(0);
}
