// Portable field interactions reveal existing authoring controls without
// changing persistence or accessibility semantics. Exact reader DOM lives in
// the sibling host test against the canonical React goldens.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

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
await import("./index.js");

const tick = () => new Promise(resolve => setTimeout(resolve, 25));

try {
  // Keyboard activation exposes the retained native control; Escape restores the
  // reader row and returns focus to the field boundary without authoring an edit.
  {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [{ id: "keyboard", type: "field-string", label: "Title", value: "Rest" }];
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await tick();
      const field = canvas.querySelector('[data-field-type="field-string"]');
      const editor = field.querySelector(":scope > .bp-canvas-field-editor");
      const control = field.querySelector('[data-test-id="paper-field-field-string"]');
      field.focus();
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      await Promise.resolve();
      assert.equal(editor.hidden, false, "Enter reveals the authoring island");
      assert.equal(document.activeElement, control, "activation focuses the value control");
      control.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      assert.equal(editor.hidden, true, "Escape restores reader-at-rest");
      assert.equal(document.activeElement, field, "Escape returns focus to the field boundary");
      canvas.flushPendingChanges();
      assert.deepEqual(batches, [], "activation and Escape do not author a patch");
    } finally {
      canvas.remove();
    }
  }

  // A reference pick keeps the picker's resolved title as transient display only;
  // the persisted patch remains the selected id.
  {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [{ id: "ref", type: "field-reference", label: "Author", value: "author-ada" }];
    const batches = [];
    canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
    document.body.appendChild(canvas);
    try {
      await tick();
      const field = canvas.querySelector('[data-field-type="field-reference"]');
      field.querySelector(".bp-field__v").click();
      await Promise.resolve();
      const picker = field.querySelector("bp-reference-picker");
      const title = document.createElement("span");
      title.className = "ref-selected-title";
      title.textContent = "Ada Lovelace";
      picker.appendChild(title);
      picker.dispatchEvent(new window.CustomEvent("bp-change", {
        bubbles: true,
        detail: { value: "author-lovelace" },
      }));
      await tick();
      picker.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      canvas.flushPendingChanges();
      assert.equal(field.querySelector(".bp-field__v").textContent, "Ada Lovelace",
        "resolved picker title survives as the resting display");
      assert.deepEqual(batches.flat(), [{ op: "patch-block", id: "ref", patch: { value: "author-lovelace" } }],
        "reference persistence remains the selected id only");
    } finally {
      canvas.remove();
    }
  }

  console.log("field reader rest: keyboard activation and transient reference title passed");
} finally {
  window.close();
}
