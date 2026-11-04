// The actual Barkpark reference picker mounts inside a field-reference without
// blanking the surrounding canvas run.
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver",
  "Node", "NodeFilter", "Selection", "Text",
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

// The public reader loaded the picker WITHOUT bp-search-intel.js: no global here.
await import("../../priv/static/assets/bp-reference-picker.js");
const { BpPaperCanvas } = await import("../paper-editor/src/canvas/index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const paragraph = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const mount = (blocks) => {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-dataset", "production");
  canvas.setAttribute("data-picker-browse", "true");
  const events = { node: [], run: [] };
  canvas.addEventListener("bp-canvas-node-failed", (e) => events.node.push(e.detail));
  canvas.addEventListener("bp-canvas-mount-failed", (e) => events.run.push(e.detail));
  // The BarkparkPaperCanvas hook's order: the element is connected first, then seeded.
  document.body.appendChild(canvas);
  canvas.blocks = blocks;
  return { canvas, events, pm: canvas.querySelector(".ProseMirror") };
};

try {
  const { canvas, events, pm } = mount([
    paragraph("f-lead", "Lead paragraph."),
    { id: "t-field-reference", type: "field-reference", label: "Companion paper", value: "terminal-mermaid-diagrams" },
    paragraph("f-end", "End paragraph."),
  ]);
  assert.equal(pm.children.length, 3, "all three blocks paint in Edit");
  assert.match(pm.textContent, /Lead paragraph\./);
  assert.match(pm.textContent, /End paragraph\./);
  const picker = pm.querySelector("bp-reference-picker");
  assert.ok(picker, "the reference picker mounts");
  assert.equal(picker.value, "terminal-mermaid-diagrams");
  assert.match(picker.textContent, /terminal-mermaid-diagrams/, "the picker paints the stored reference");
  assert.equal(canvas.hasAttribute("data-mount-failed"), false);
  assert.deepEqual(events, { node: [], run: [] });
  canvas.remove();
  console.log("PASS field-reference mount: actual picker and surrounding run paint");
} finally {
  window.close();
}
