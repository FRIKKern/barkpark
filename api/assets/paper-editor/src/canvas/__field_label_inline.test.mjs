// Click-to-edit census: a field atom's label ("Title", "Published", "Cover", …) is
// painted by the reader but was a dead caption in Edit. It is now its own plain-text
// typing surface; the save carries only `label`, so the stored value keeps its form,
// and an absent label stays absent.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver",
  "Node", "NodeFilter", "Selection", "Text", "FocusEvent", "InputEvent",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.sessionStorage = window.sessionStorage;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
const fetchMock = async () => ({ ok: true, json: async () => ({ documents: [] }) });
globalThis.fetch = fetchMock;
window.fetch = fetchMock;
await import("../../../../priv/static/assets/bp-reference-picker.js");
const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const paragraph = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const mount = (blocks) => {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-dataset", "production");
  canvas.setAttribute("data-picker-browse", "true");
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...e.detail.ops));
  document.body.appendChild(canvas);
  canvas.blocks = blocks;
  return { canvas, ops, pm: canvas.querySelector(".ProseMirror") };
};
const typeInto = (el, text) => {
  el.focus();
  el.textContent = text;
  el.dispatchEvent(new window.Event("input", { bubbles: true }));
};

try {
  for (const block of [
    { id: "fs", type: "field-string", label: "Title", value: "The Full Deck" },
    { id: "fb", type: "field-boolean", label: "Published", value: true },
    { id: "fn", type: "field-select", label: "Audience", value: "eng", options: [{ value: "eng", label: "Engineering" }] },
    { id: "fr", type: "field-reference", label: "Companion paper", value: "terminal-mermaid-diagrams" },
  ]) {
    const { canvas, ops, pm } = mount([paragraph("lead", "Lead."), block, paragraph("end", "End.")]);
    const labelEl = pm.querySelector(".bp-canvas-field-label");
    assert.ok(labelEl, `${block.type}: the label paints`);
    assert.equal(labelEl.textContent, block.label);
    assert.equal(labelEl.getAttribute("contenteditable"), "plaintext-only", `${block.type}: the label is a typing surface`);
    typeInto(labelEl, block.label + " QZ");
    labelEl.dispatchEvent(new window.FocusEvent("blur"));
    canvas.flushPendingChanges();
    const mine = ops.filter((op) => op.id === block.id);
    assert.equal(mine.length, 1, `${block.type}: one patch`);
    assert.deepEqual(mine[0], { op: "patch-block", id: block.id, patch: { label: block.label + " QZ" } },
      `${block.type}: the patch carries only the label`);
    assert.equal(ops.filter((op) => op.id !== block.id).length, 0, `${block.type}: no other block is written`);
    // Enter commits instead of breaking the line.
    const enter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    labelEl.dispatchEvent(enter);
    assert.equal(enter.defaultPrevented, true, `${block.type}: Enter does not break the label`);
    canvas.remove();
  }

  // An absent label that stays empty is never written.
  {
    const { canvas, ops, pm } = mount([{ id: "nolabel", type: "field-string", value: "v" }]);
    const labelEl = pm.querySelector(".bp-canvas-field-label");
    typeInto(labelEl, "");
    labelEl.dispatchEvent(new window.FocusEvent("blur"));
    canvas.flushPendingChanges();
    assert.deepEqual(ops, [], "an untouched absent label writes nothing");
    canvas.remove();
  }
} finally {
  dom.window.close();
}
console.log("field labels edit in place and save only the label passed");
