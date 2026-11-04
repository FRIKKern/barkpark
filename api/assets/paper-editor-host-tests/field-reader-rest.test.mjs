// Field atoms rest in the exact React golden article-reader DOM.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element",
  "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Range", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.ResizeObserver = class ResizeObserver { observe() {} disconnect() {} };
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
globalThis.CSS ||= { escape: value => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("../paper-editor/src/canvas/index.js");

const fixtureUrl = (type) => new URL(
  `../../../js/packages/react/tests/fixtures/pd-golden/${type}.golden.json`,
  import.meta.url,
);
const types = ["field-boolean", "field-color", "field-datetime", "field-image", "field-number",
  "field-reference", "field-select", "field-slug", "field-string", "field-text"];
const tick = () => new Promise(resolve => setTimeout(resolve, 25));

function restingHtml(field) {
  const clone = field.cloneNode(true);
  clone.querySelector(":scope > .bp-canvas-field-editor")?.remove();
  clone.classList.remove("bp-canvas-field", "bp-canvas-field-picker", "bp-canvas-field--bound");
  for (const name of [...clone.classList]) if (name.startsWith("ProseMirror")) clone.classList.remove(name);
  for (const attr of ["data-bp-type", "data-field-type", "tabindex", "draggable"]) clone.removeAttribute(attr);
  return clone.outerHTML;
}

try {
  for (const type of types) {
    const golden = JSON.parse(readFileSync(fixtureUrl(type), "utf8"));
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [{ ...structuredClone(golden.input), id: `rest-${type}` }];
    document.body.appendChild(canvas);
    try {
      await tick();
      const field = canvas.querySelector(`[data-field-type="${type}"]`);
      assert.ok(field, `${type}: field mounted`);
      assert.equal(restingHtml(field), golden.expectedHtml, `${type}: rest is exact reader DOM`);
      assert.equal(field.querySelector(":scope > .bp-canvas-field-editor").hidden, true,
        `${type}: authoring chrome is hidden at rest`);
    } finally {
      canvas.remove();
    }
  }

  console.log("field reader rest: 10 exact rows passed");
} finally {
  window.close();
}
