import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;

for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "DOMParser",
  "Element",
  "Event",
  "EventTarget",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "Node",
  "NodeFilter",
  "Selection",
  "Text",
]) {
  globalThis[name] = window[name];
}

globalThis.window = window;
globalThis.sessionStorage = window.sessionStorage;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const fetches = [];
const fetchMock = async (url, options = {}) => {
  fetches.push({ url: String(url), options });

  if (options.method === "POST") {
    return { ok: true, json: async () => ({}) };
  }

  return {
    ok: true,
    json: async () => ({
      searchEventId: "search-event-1",
      documents: [{ _id: "drafts.target-paper", title: "Target paper" }],
    }),
  };
};
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

await import("../../../../priv/static/assets/bp-search-intel.js");
globalThis.BpSearchIntel = window.BpSearchIntel;
await import("../../../../priv/static/assets/bp-reference-picker.js");
const { BpPaperCanvas } = await import("./index.js");

assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);
assert.ok(customElements.get("bp-reference-picker"));

const canvas = document.createElement("bp-paper-canvas");
canvas.setAttribute("data-dataset", "production");
canvas.setAttribute("data-scope-prefix", "/w/default/p/default");
canvas.setAttribute("data-picker-browse", "true");
canvas.blocks = [
  {
    id: "public-reference",
    type: "field-reference",
    label: "Related paper",
    fieldName: "relatedPaper",
    refType: "paper",
    value: "",
  },
];

const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;

  const picker = canvas.querySelector(
    '[data-test-id="paper-field-field-reference"]'
  );
  assert.ok(picker, "the field-reference node mounts the real picker Web Component");
  assert.equal(picker.getAttribute("dataset"), "production");
  assert.equal(picker.getAttribute("scope-prefix"), "/w/default/p/default");
  assert.equal(picker.getAttribute("ref-type"), "paper");

  const input = picker.querySelector(".bp-ref-search-input");
  assert.ok(input, "the picker offers its real typeahead input");
  input.value = "target";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));

  await new Promise((resolve) => setTimeout(resolve, 400));

  const result = picker.querySelector(".bp-ref-dropdown-item");
  assert.ok(result, "the mocked scoped search result renders as a picker option");
  assert.match(result.textContent, /Target paper/);
  result.dispatchEvent(
    new window.MouseEvent("mousedown", { bubbles: true, cancelable: true })
  );

  canvas.flushPendingChanges();

  assert.deepEqual(batches, [
    [
      {
        op: "patch-block",
        id: "public-reference",
        patch: { value: "target-paper" },
      },
    ],
  ]);
  assert.equal(picker.value, "target-paper", "draft selection stores the canonical id");
  assert.equal(canvas.flushPendingChanges(), false, "a second flush emits no duplicate op");

  const search = fetches.find(({ options }) => options.method !== "POST");
  assert.equal(
    search.url,
    "/w/default/p/default/v1/data/search/production?q=target&perspective=raw&limit=50&type=paper"
  );

  console.log("mounted public reference picker search/select/flush regression passed");
} finally {
  canvas.remove();
  window.close();
}
