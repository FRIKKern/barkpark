// A canvas field block's value control is named after its visible label
// (task-358f023c0ad256fd). The label is an editable caption, not a <label for>,
// so a screen reader announced the control as just "edit text". The name follows
// a label edit.
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

const controlOf = (pm, type) =>
  type === "field-reference"
    ? pm.querySelector(".bp-ref-search-input")
    : pm.querySelector(".bp-canvas-field-control");

try {
  for (const block of [
    { id: "fs", type: "field-string", label: "Title", value: "The Full Deck" },
    { id: "fl", type: "field-slug", label: "Slug", value: "full-deck" },
    { id: "ft", type: "field-text", label: "Summary", value: "Short." },
    { id: "fb", type: "field-boolean", label: "Published", value: true },
    { id: "fn", type: "field-select", label: "Audience", value: "eng", options: [{ value: "eng", label: "Engineering" }] },
    { id: "fd", type: "field-datetime", label: "Goes live", value: "" },
    { id: "fc", type: "field-color", label: "Accent", value: "#000000" },
    { id: "fnum", type: "field-number", label: "Pages", value: 312, unit: "pp" },
    { id: "fr", type: "field-reference", label: "Companion paper", value: "" },
  ]) {
    const { canvas, pm } = mount([paragraph("lead", "Lead."), block, paragraph("end", "End.")]);
    const control = controlOf(pm, block.type);
    assert.ok(control, `${block.type}: the value control renders`);
    assert.equal(control.getAttribute("aria-label"), block.label, `${block.type}: named after its label`);

    const labelEl = pm.querySelector(".bp-canvas-field-label");
    typeInto(labelEl, "Renamed field");
    assert.equal(controlOf(pm, block.type).getAttribute("aria-label"), "Renamed field",
      `${block.type}: the name follows a label edit`);
    canvas.remove();
  }

  // No label: no empty name.
  {
    const { canvas, pm } = mount([{ id: "nolabel", type: "field-string", value: "v" }]);
    assert.equal(pm.querySelector(".bp-canvas-field-control").hasAttribute("aria-label"), false,
      "a label-less field leaves its control unnamed, not named \"\"");
    canvas.remove();
  }
} finally {
  dom.window.close();
}
console.log("field value controls are named after their label passed");
