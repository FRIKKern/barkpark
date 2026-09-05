// Mounted regression for node-view controls whose values are held behind their
// own debounce. The canvas flush must commit those controls before diffing the run.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [
  { id: "code-1", type: "code", value: "old code", lang: "text" },
  { id: "field-1", type: "field-string", label: "Name", value: "old field" },
  { id: "action-1", type: "action", label: "Old action", href: "/old", priority: "secondary" },
];
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => {
  batches.push(event.detail.ops);
});
document.body.appendChild(canvas);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;

  const code = canvas.querySelector(".bp-canvas-code-area");
  const field = canvas.querySelector('[data-test-id="paper-field-field-string"]');
  const action = canvas.querySelector('[data-test-id="paper-action-label"]');
  assert.ok(code && field && action, "the representative real node views mount");

  code.value = "final code";
  code.dispatchEvent(new window.Event("input", { bubbles: true }));
  field.value = "final field";
  field.dispatchEvent(new window.Event("input", { bubbles: true }));
  action.value = "Final action";
  action.dispatchEvent(new window.Event("input", { bubbles: true }));

  assert.equal(batches.length, 0, "all three values remain inside node debounce timers");
  assert.equal(canvas.flushPendingChanges(), true, "canvas flush emits the node edits immediately");
  assert.deepEqual(batches, [[
    { op: "patch-block", id: "code-1", patch: { value: "final code", lang: "text" } },
    { op: "patch-block", id: "field-1", patch: { value: "final field" } },
    {
      op: "patch-block",
      id: "action-1",
      patch: { label: "Final action", href: "/old", priority: "secondary" },
    },
  ]], "the emitted batch contains each latest control value exactly once");

  assert.equal(canvas.flushPendingChanges(), false, "a repeated flush is a no-op");
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(batches.length, 1, "cleared node timers cannot emit a delayed duplicate");

  code.value = "source transition code";
  code.dispatchEvent(new window.Event("input", { bubbles: true }));
  canvas._enterSourceMode();
  assert.ok(canvas.querySelector(".bp-canvas-source").value.includes("source transition code"),
    "entering source captures pending node input before serialization");
  assert.equal(batches.length, 2, "source entry emits the pending code edit once");
  canvas.flushPendingChanges();
  assert.equal(batches.length, 2, "unchanged source exit does not repeat the edit");

  console.log("mounted node-view pending flush regression passed");
} finally {
  canvas.remove();
  window.close();
}
