// Mounted regression for attr-backed node-view islands. A canvas flush must consume
// every local debounce before diffing the ProseMirror document, and a repeated flush
// must not emit the same edits twice.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const jsdom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = jsdom;
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

const blocks = [
  {
    id: "card-1",
    type: "card",
    slots: {
      title: [{ type: "heading", text: "Card before" }],
      body: [{ type: "paragraph", content: [{ type: "text", value: "Body" }] }],
    },
  },
  {
    id: "section-1",
    type: "section",
    title: "Section before",
    blocks: [
      { id: "section-p", type: "paragraph", content: [{ type: "text", value: "Nested" }] },
    ],
  },
  {
    id: "figure-1",
    type: "figure",
    caption: "Caption before",
    child: { id: "figure-image", type: "image", src: "/figure.png", alt: "Figure" },
  },
  {
    id: "task-list-1",
    type: "task-list",
    query: { label: "proj:before", status: "open" },
    title: "Tasks before",
  },
  {
    id: "cards-1",
    type: "cards",
    items: [{ title: "Fleet before", text: "Body" }],
  },
  {
    id: "task-board-1",
    type: "task-board",
    query: { label: "team:before", status: "open" },
  },
];

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = blocks;
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

const input = (el) => el.dispatchEvent(new window.Event("input", { bubbles: true }));

try {
  // Let mount-time normalization settle so the only pending work is deliberate input.
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;

  const cardTitle = canvas.querySelector("[data-test-id='paper-card-title']");
  const sectionTitle = canvas.querySelector("[data-test-id='paper-section-title']");
  const caption = canvas.querySelector(".bp-canvas-figure-caption-input");
  const taskQuery = canvas.querySelector(".bp-canvas-tasklist-query");
  const taskTitle = canvas.querySelector(".bp-canvas-tasklist-title");
  const fleetJson = canvas.querySelector("[data-test-id='paper-fleet-editor-cards'] .bp-fleet-edit-area");
  const fleetQuery = canvas.querySelector("[data-test-id='paper-fleet-editor-task-board'] .bp-fleet-edit-area");
  assert.ok(cardTitle && sectionTitle && caption && taskQuery && taskTitle && fleetJson && fleetQuery,
    "all real node-view edit islands mount");

  cardTitle.textContent = "Card latest";
  input(cardTitle);
  sectionTitle.textContent = "Section latest";
  input(sectionTitle);
  caption.value = "Caption latest";
  input(caption);
  taskQuery.value = "proj:latest";
  input(taskQuery);
  taskTitle.value = "Tasks latest";
  input(taskTitle);
  fleetJson.value = JSON.stringify([{ title: "Fleet latest", text: "Body" }], null, 2);
  input(fleetJson);
  fleetQuery.value = JSON.stringify({ label: "team:latest", status: "closed" }, null, 2);
  input(fleetQuery);

  assert.equal(batches.length, 0, "node-view edits remain local during their debounce");
  assert.equal(canvas.flushPendingChanges(), true, "flush emits the pending node-view edits");
  assert.equal(batches.length, 1, "all node-view edits share one synchronous op batch");

  const ops = batches[0];
  const patchFor = (id) => ops.find((op) => op.op === "patch-block" && op.id === id)?.patch;
  assert.equal(patchFor("card-1").slots.title[0].text, "Card latest");
  assert.equal(patchFor("section-1").title, "Section latest");
  assert.equal(patchFor("figure-1").caption, "Caption latest");
  assert.deepEqual(patchFor("task-list-1").query, {
    label: "proj:latest",
    status: "open",
  });
  assert.equal(patchFor("task-list-1").title, "Tasks latest");
  assert.deepEqual(patchFor("cards-1").items, [
    { title: "Fleet latest", text: "Body" },
  ]);
  assert.deepEqual(patchFor("task-board-1").query, {
    label: "team:latest",
    status: "closed",
  });

  assert.equal(canvas.flushPendingChanges(), false, "a repeated flush is a no-op");
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(batches.length, 1, "a repeated flush emits no duplicate batch");

  console.log("mounted node-view pending-change flush regression passed");
} finally {
  canvas.remove();
  window.close();
}
