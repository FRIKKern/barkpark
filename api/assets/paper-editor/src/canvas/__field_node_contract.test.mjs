// Public field-node facade and ProseMirror island contracts. The facade must load
// in plain Node; mounted native and picker controls must remain outside PM's event
// and mutation handling.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

for (const name of ["document", "HTMLElement", "customElements", "window"]) {
  assert.equal(Object.hasOwn(globalThis, name), false, `plain Node starts without ${name}`);
}

const fieldNode = await import("./field-node.js");
assert.deepEqual(Object.keys(fieldNode).sort(), [
  "BP_FIELD_NODE_NAME",
  "BP_NATIVE_FIELD_TYPES",
  "BP_PICKER_FIELD_TYPES",
  "Field",
  "IMAGE_PLACEHOLDER_HINT",
  "IMAGE_PLACEHOLDER_LABEL",
  "canvasScope",
  "coerceFieldValue",
  "coercePickerValue",
  "imagePlaceholderModel",
  "isEmptyPickerValue",
  "mountFieldLabel",
  "nameControl",
  "toFieldNumber",
]);
assert.equal(fieldNode.Field.name, "bpField");
assert.deepEqual(fieldNode.BP_NATIVE_FIELD_TYPES, [
  "field-string", "field-slug", "field-text", "field-boolean", "field-select",
  "field-datetime", "field-color", "field-number",
]);
assert.deepEqual(fieldNode.BP_PICKER_FIELD_TYPES, ["field-image", "field-reference"]);
for (const name of ["document", "HTMLElement", "customElements", "window"]) {
  assert.equal(Object.hasOwn(globalThis, name), false, `facade import does not create ${name}`);
}

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Range", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.ResizeObserver = class ResizeObserver { observe() {} disconnect() {} };
globalThis.CSS ||= { escape: value => String(value) };
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
window.BP_PAPER_EDITOR_NO_INJECT = true;
const fetchMock = async () => ({ ok: true, json: async () => ({ documents: [] }) });
globalThis.fetch = fetchMock;
window.fetch = fetchMock;
await import("./index.js");

const canvas = document.createElement("bp-paper-canvas");
canvas.setAttribute("data-picker-browse", "true");
const batches = [];
canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
canvas.blocks = [
  { id: "native", type: "field-string", label: "Title", value: "Draft" },
  { id: "picker", type: "field-reference", label: "Paper", value: "paper-1" },
];
document.body.appendChild(canvas);

try {
  await new Promise(resolve => setTimeout(resolve, 25));
  for (const [type, label] of [["field-string", "native"], ["field-reference", "picker"]]) {
    const field = canvas.querySelector(`[data-field-type="${type}"]`);
    assert.ok(field, `${label} field mounts`);
    const spec = field.pmViewDesc && field.pmViewDesc.spec;
    assert.ok(spec, `${label} field exposes its mounted ProseMirror node-view contract`);
    assert.equal(spec.stopEvent(new window.Event("click")), true, `${label} field stops PM events`);
    assert.equal(spec.ignoreMutation({ type: "attributes", target: field }), true,
      `${label} field ignores PM DOM mutations`);
  }
  const native = canvas.querySelector('[data-test-id="paper-field-field-string"]');
  native.value = "Flushed";
  native.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.deepEqual(batches, [], "debounced native input stays local before flush");
  assert.equal(canvas.flushPendingChanges(), true, "flush commits pending native input");
  assert.deepEqual(batches.flat(), [
    { op: "patch-block", id: "native", patch: { value: "Flushed" } },
  ]);
  console.log("field node contract: plain facade and native/picker islands passed");
} finally {
  canvas.remove();
  window.close();
}
