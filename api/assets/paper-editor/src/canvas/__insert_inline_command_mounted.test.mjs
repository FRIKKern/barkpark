// __insert_inline_command_mounted.test.mjs — the insertInline toolbar command
// (EMBED-CONTRACT "Toolbar commands"): a declared inline object at the caret, as the
// slash pick inserts it. can() answers for declared kinds only and not on a read-only
// canvas; the field editor opens first (the popover, or the host's editBlockObject)
// and its answer puts the atom in, a cancel inserts nothing.
// Run: node src/canvas/__insert_inline_command_mounted.test.mjs   (or: npm test)
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
const { TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const VOCAB = {
  styles: ["normal"],
  inline: [{ name: "chip", title: "Status chip", fields: [{ name: "text", title: "Text", type: "string" }] }],
};
const BLOCKS = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "Status here." }] }];
let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}
const dialog = () => document.querySelector(".bp-inline-object-dialog");
function key(el, name) {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
}

try {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  document.body.appendChild(canvas);
  await tick(350);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  const editor = canvas._editor;
  const chips = () => {
    const out = [];
    editor.state.doc.descendants((n) => { if (n.type.name === "bpInlineOpaque") out.push(n.attrs.node); });
    return out;
  };
  // The caret after "Status".
  const caret = () => {
    let at = null;
    editor.state.doc.descendants((n, p) => { if (at == null && n.isText && n.text.includes("Status")) at = p + 6; });
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
  };
  caret();

  await check("can() answers for the field's declared inline kinds only", () => {
    assert.equal(canvas.can("insertInline", { type: "chip" }), true);
    assert.equal(canvas.can("insertInline", { type: "nope" }), false);
    assert.equal(canvas.can("insertInline", {}), false);
  });

  await check("insertInline opens the field editor; Escape inserts nothing", () => {
    assert.equal(canvas.insertInline("chip"), true);
    assert.ok(dialog(), "the editor opened");
    key(dialog(), "Escape");
    assert.equal(chips().length, 0);
  });

  await check("its Save puts the chip in at the caret, and the op carries it", async () => {
    caret();
    assert.equal(canvas.run("insertInline", { type: "chip" }), true);
    dialog().querySelector('[data-field="text"]').value = "Reviewed";
    dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
    assert.deepEqual(chips(), [{ type: "chip", text: "Reviewed" }]);
    const para = editor.state.doc.child(0);
    const parts = [];
    para.forEach((n) => parts.push(n.isText ? n.text : n.attrs.node.type));
    assert.deepEqual(parts, ["Status", "chip", " here."], "at the caret");
    canvas.flushPendingChanges();
    await tick(20);
    assert.ok(JSON.stringify(ops).includes('"Reviewed"'), JSON.stringify(ops));
  });

  await check("with a host editor (editBlockObject) the host is asked, inline: true", async () => {
    const asked = [];
    canvas.editBlockObject = async (request) => (asked.push(request), { text: "Draft" });
    caret();
    assert.equal(canvas.insertInline("chip"), true);
    await tick(10);
    assert.equal(dialog(), null, "no popover");
    assert.equal(asked.length, 1);
    assert.equal(asked[0].inline, true);
    assert.ok(chips().some((c) => c.text === "Draft"));
    canvas.editBlockObject = null;
  });

  await check("a read-only canvas: can() is false and insertInline does nothing", () => {
    canvas.setAttribute("editable", "false");
    assert.equal(canvas.can("insertInline", { type: "chip" }), false);
    assert.equal(canvas.insertInline("chip"), false);
    assert.equal(dialog(), null);
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ninsert inline command mounted: all checks passed");
  process.exit(0);
}
