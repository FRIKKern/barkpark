import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import "../__reconnect_mode.test.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle;
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("./index.js");

for (const path of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(path, import.meta.url), "utf8");
  assert.match(css, /\.bp-expandable__body \.bp-paper-editor-body > \.ProseMirror > h2\s*\{\s*margin-top: 1\.9em; border-top: 0; padding-top: 0;/, "nested headings do not acquire root section rules");
  assert.match(css, /\.bp-paper-editor-body \.ProseMirror > \.bp-resting-scaffold\s*\{\s*display: none;/, "both CSS surfaces preserve reader margin collapse");
  assert.match(css, /\.bp-paper-editor-body \.bp-scaffold-control:focus-visible\s*\{\s*outline: 2px solid var\(--paper-accent\)/, "hidden content controls retain visible keyboard focus");
  assert.match(css, /@media \(max-width: 720px\)\s*\{[^}]*\.bp-section__cell\s*\{\s*grid-column: 1 \/ -1 !important;/, "mobile section spans cannot create implicit columns");
}
assert.match(readFileSync(new URL("../../../paper-surface/paper-surface.css", import.meta.url), "utf8"), /@media \(max-width: 720px\)\s*\{[^}]*\.bp-section__cell\s*\{\s*grid-column: 1 \/ -1 !important;/, "reader uses the same mobile span reset");

const blocks = [
  { id: "lead", type: "paragraph", content: [{ type: "text", value: "Lead" }] },
  { id: "empty", type: "ingress", content: [], audit: "keep" },
  { id: "rule", type: "divider", audit: "keep" },
  { id: "heading", type: "heading", level: 2, content: [{ type: "text", value: "Section" }] },
  { id: "list", type: "list", items: [""] },
];
function mount(kind, late = false) {
  const parent = document.createElement("div");
  parent.dataset.paperContainerKind = kind;
  const host = document.createElement("bp-paper-canvas");
  if (!late) host.blocks = structuredClone(blocks);
  const ops = [];
  host.addEventListener("bp-canvas-ops", event => ops.push(...event.detail.ops));
  parent.appendChild(host);
  document.body.appendChild(parent);
  if (late) host.blocks = structuredClone(blocks);
  return { parent, host, ed: host._editor, ops };
}
try {
  const { parent, host, ed, ops } = mount("document");
  try {
    const original = ed.getJSON();
    assert.equal(host.querySelectorAll(".bp-resting-scaffold").length, 2, "only empty prose and redundant root divider collapse");
    assert.equal(host.querySelector("li .bp-resting-scaffold"), null, "empty list items remain visible");
    assert.equal(host.flushPendingChanges(), false);
    assert.deepEqual(ops, [], "opening does not rewrite hidden scaffolds");
    assert.equal(host.querySelectorAll(".bp-scaffold-control").length, 1, "adjacent hidden blocks cannot overlap controls");
    host.querySelector('button[aria-label="Edit empty ingress (first of 2 hidden blocks)"]').click();
    assert.equal(host.querySelector('[data-bp-id="empty"]').classList.contains("bp-resting-scaffold"), false);
    ed.commands.insertContent("New lead");
    assert.equal(ed.state.doc.child(1).textContent, "New lead");
    ed.commands.undo();
    assert.deepEqual(ed.getJSON(), original, "empty content and metadata survive undo");
    ed.commands.setTextSelection(1);
    host.querySelector('button[aria-label="Edit empty ingress (first of 2 hidden blocks)"]').click();
    host.querySelector('button[aria-label="Select hidden divider"]').click();
    assert.equal(ed.state.selection.node.type.name, "divider");
    ed.commands.deleteSelection();
    assert.equal(ed.state.doc.childCount, 4);
    ed.commands.undo();
    assert.deepEqual(ed.getJSON(), original, "divider deletion is reversible without metadata loss");
  } finally { parent.remove(); }
  const nested = mount("section");
  try {
    assert.equal(nested.host.querySelector('button[aria-label="Select hidden divider"]'), null, "nested dividers retain reader geometry");
  } finally { nested.parent.remove(); }
  const late = mount("document", true);
  try {
    assert.equal(late.host.querySelectorAll(".bp-resting-scaffold").length, 2, "post-mount data assignment also collapses resting scaffolds");
  } finally { late.parent.remove(); }
  console.log("resting scaffolds preserve geometry, access, and source history");
} finally { window.close(); }
