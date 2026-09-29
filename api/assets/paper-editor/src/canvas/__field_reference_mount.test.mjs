// task-7188bd8e9eb2625a — a field-reference block blanked its whole canvas run in
// Edit. The hook seeds `canvas.blocks` AFTER the element connects; the picker node
// view then set `picker.value` on a not-yet-connected <bp-reference-picker>, whose
// setter rendered with config it only reads on connect and threw. ProseMirror
// aborted the paint, the hook's try/catch swallowed the error, and the author saw
// an EMPTY editor where three blocks were.
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
await import("../../../../priv/static/assets/bp-reference-picker.js");
// A media picker whose value setter throws stands in for any picker WC that
// fails while its node view is built.
class ThrowingMediaPicker extends window.HTMLElement {
  get value() { return ""; }
  set value(_v) { throw new Error("media picker exploded"); }
}
customElements.define("bp-media-picker", ThrowingMediaPicker);
const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const errors = [];
const originalConsoleError = console.error;
console.error = (...args) => errors.push(args.map(String).join(" "));

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
  // 1. The reported repro: lead paragraph, field-reference, end paragraph.
  {
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
  }

  // 2. A picker WC that throws while built degrades to a read-only atom; the rest
  //    of the run stays editable and the failure is reported.
  {
    const { canvas, events, pm } = mount([
      paragraph("f-lead", "Lead paragraph."),
      { id: "t-field-image", type: "field-image", label: "Cover", value: "/media/cover.png" },
      paragraph("f-end", "End paragraph."),
    ]);
    assert.equal(pm.children.length, 3, "the run still paints every block");
    const atom = pm.querySelector('[data-node-view-failed="true"]');
    assert.ok(atom, "the failed picker renders as a read-only atom");
    assert.match(atom.textContent, /Cover/);
    assert.match(atom.textContent, /\/media\/cover\.png/);
    assert.equal(events.node.length, 1);
    assert.equal(events.node[0].blockId, "t-field-image");
    assert.equal(events.run.length, 0, "a node-level fallback does not fail the run");
    assert.equal(canvas._editor.isEditable, true);
    canvas.remove();
  }

  // 3. Any other node view that throws: the run never rests as an empty editor.
  {
    const createElement = document.createElement.bind(document);
    document.createElement = (tag, ...rest) => {
      if (String(tag).toLowerCase() === "input") throw new Error("control exploded");
      return createElement(tag, ...rest);
    };
    let mounted;
    try {
      mounted = mount([
        paragraph("f-lead", "Lead paragraph."),
        { id: "t-field-string", type: "field-string", label: "Title", value: "The Full Deck" },
        paragraph("f-end", "End paragraph."),
      ]);
    } finally {
      document.createElement = createElement;
    }
    const { canvas, events } = mounted;
    assert.equal(canvas.getAttribute("data-mount-failed"), "true");
    const fallback = canvas.querySelector(".bp-canvas-mount-failed");
    assert.ok(fallback, "a read-only fallback replaces the empty editor");
    assert.equal(fallback.querySelector('[role="alert"]')?.textContent.includes("could not open for editing"), true);
    const rows = [...fallback.querySelectorAll(".bp-canvas-mount-failed__block")].map((r) => r.textContent);
    assert.deepEqual(rows, ["Lead paragraph.", "Title The Full Deck", "End paragraph."]);
    assert.equal(canvas.querySelector(".bp-paper-editor-body").hidden, true);
    assert.equal(events.run.length, 1);
    assert.deepEqual(events.run[0].blockIds, ["f-lead", "t-field-string", "f-end"]);
    assert.equal(canvas._editor.isEditable, false, "the failed run takes no edits");
    canvas.setAttribute("editable", "true");
    assert.equal(canvas._editor.isEditable, false, "the host cannot re-enable a failed run");
    assert.ok(errors.some((line) => line.includes("could not open for editing")), "the failure is logged");
    canvas.remove();
  }
  console.log("PASS field-reference mount: run paints, picker failure degrades to an atom, run failure falls back read-only");
} finally {
  console.error = originalConsoleError;
  window.close();
}
