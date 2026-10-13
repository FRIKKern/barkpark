// The pickers the canvas mounts read the workspace's strings (task-8f6507ea3a5c79c6).
// A field-image, a field-reference and a card's media picker are built in JS, so
// they never got the data-strings the server stamps on its own pickers: an nb-NO
// workspace saw English. The run wrapper's maps reach the canvas host, and each
// node-view hands them to its picker. A host with no strings leaves the pickers on
// their English defaults.
//
// Run: node src/canvas/__canvas_picker_strings.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "File", "FormData", "HTMLElement", "KeyboardEvent", "MouseEvent",
  "MutationObserver", "Node", "NodeFilter", "Selection", "Text", "FocusEvent", "InputEvent",
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
const fetchMock = async () => ({ ok: true, json: async () => ({ documents: [], result: { hits: [] } }) });
globalThis.fetch = fetchMock;
window.fetch = fetchMock;
await import("../../../../priv/static/assets/bp-asset-browser.js");
await import("../../../../priv/static/assets/bp-media-picker.js");
await import("../../../../priv/static/assets/bp-reference-picker.js");
const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const MEDIA = JSON.stringify({ replace: "Bytt bilde", remove: "Fjern" });
const REFERENCE = JSON.stringify({ search: "Søk i %{types}…", documents: "dokumenter" });

const text = (value) => [{ type: "text", value }];
const blocks = [
  { id: "img", type: "field-image", label: "Cover", value: "" },
  { id: "ref", type: "field-reference", label: "Companion paper", value: "" },
  { id: "card", type: "card", slots: {
    title: [{ type: "heading", text: "Title" }],
    body: [{ type: "paragraph", content: text("Body") }],
  } },
];

const mount = (attrs) => {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-dataset", "production");
  canvas.setAttribute("data-picker-browse", "true");
  for (const [k, v] of Object.entries(attrs)) canvas.setAttribute(k, v);
  document.body.appendChild(canvas);
  canvas.blocks = blocks;
  return canvas;
};
const settle = () => new Promise((resolve) => setTimeout(resolve, 25));

try {
  {
    const canvas = mount({ "data-media-strings": MEDIA, "data-reference-strings": REFERENCE });
    await settle();
    const image = canvas.querySelector('[data-test-id="paper-field-field-image"]');
    const reference = canvas.querySelector('[data-test-id="paper-field-field-reference"]');
    const cardMedia = canvas.querySelector('[data-test-id="paper-card-media-src"]');
    assert.ok(image && reference && cardMedia, "all three canvas pickers mount");
    assert.equal(image.getAttribute("data-strings"), MEDIA, "field-image gets the media strings");
    assert.equal(cardMedia.getAttribute("data-strings"), MEDIA, "the card media picker gets the media strings");
    assert.equal(reference.getAttribute("data-strings"), REFERENCE, "field-reference gets the reference strings");
    assert.equal(reference.querySelector(".bp-ref-search-input").placeholder, "Søk i dokumenter…",
      "the reference picker renders the workspace's words");
    canvas.remove();
  }

  {
    const canvas = mount({});
    await settle();
    for (const id of ["paper-field-field-image", "paper-field-field-reference", "paper-card-media-src"]) {
      assert.equal(canvas.querySelector(`[data-test-id="${id}"]`).hasAttribute("data-strings"), false,
        `${id}: no host strings, no data-strings`);
    }
    assert.equal(canvas.querySelector(".bp-ref-search-input").placeholder, "Search documents…",
      "without strings the reference picker keeps its English");
    canvas.remove();
  }

  console.log("canvas picker strings: all checks passed");
} finally {
  dom.window.close();
}
