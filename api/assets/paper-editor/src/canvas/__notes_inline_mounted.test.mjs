import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

// task-bbfdcf4c80b8300d wave 2: a notes row's label ("P1"), lead ("One
// vocabulary.") and body edit where the reader paints them. Before this, the
// whole notes block was a read-only fleet paint with a JSON textarea island.
for (const file of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-notes-config\s*\{[^}]*bottom: 100%;/s,
    `${file}: notes configuration sits above the authored rows`);
  assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-notes-config\[open\]\s*\{[^}]*position: relative;/s,
    `${file}: opened notes configuration flows without covering rows`);
}

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("../index.js");

// The reader's bytes (components.ex note_item_html/1).
const row = (label, lead, text) =>
  `<div class="bp-note"><span class="bp-note__k">${label}</span><div class="bp-note__d">${lead ? `<b>${lead}</b> ` : ""}${text}</div></div>`;
const html = `<div class="bp-notes">${row("P1", "One vocabulary.", "New widgets are compositions.")}${row("P4", "", "No lead here.")}</div>`;
function paint(host, markup = html, sourceBlock = host.blocks[0]) {
  const hole = host.querySelector("[data-bp-fleet-body]");
  const event = new CustomEvent("bp-fleet-paint", { detail: { html: markup, sourceBlock }, cancelable: true });
  if (hole.dispatchEvent(event)) hole.innerHTML = markup;
}
function mount(attrs = {}) {
  const block = { id: "n", type: "notes", items: [
    { label: "P1", lead: "One vocabulary.", text: "New widgets are compositions.", audit: { keep: true } },
    { label: "P4", text: "No lead here." },
  ], qa_meta: { keep: "n" }, ...attrs };
  const host = document.createElement("bp-paper-canvas");
  host.blocks = [block];
  const batches = [];
  host.addEventListener("bp-canvas-ops", e => batches.push(e.detail));
  document.body.appendChild(host);
  paint(host);
  return { host, block, batches };
}
function input(el, text) { el.textContent = text; el.dispatchEvent(new Event("input", { bubbles: true })); }

try {
  const { host, block, batches } = mount();
  try {
    const labels = host.querySelectorAll('[aria-label="Note label"]');
    const leads = host.querySelectorAll('[aria-label="Note lead"]');
    const bodies = host.querySelectorAll('[aria-label="Note body"]');
    assert.equal(labels.length, 2, "every row's label edits where it reads");
    assert.equal(leads.length, 1, "a lead edits where it reads; a row without one paints none");
    assert.equal(bodies.length, 2, "every row's body edits where it reads");
    assert.equal(bodies[0].textContent, "New widgets are compositions.");
    assert.equal(bodies[0].previousSibling.nodeValue, " ", "the reader's single space after the lead stays outside the body");
    assert.equal(host.querySelector(".bp-note__d").textContent, "One vocabulary. New widgets are compositions.",
      "decoration keeps the reader's painted text byte-for-byte");
    assert.equal(bodies[1].textContent, "No lead here.");
    assert.equal(labels[0].contentEditable, "plaintext-only");
    assert.equal(host.querySelector(".bp-paper-notes-config").open, false);

    labels[0].focus(); labels[0].blur(); host.flushPendingChanges();
    assert.deepEqual(batches, [], "focus/blur is not an authored change");

    bodies[0].focus(); input(bodies[0], "Compositions, not widgets.");
    host.flushPendingChanges();
    bodies[0].blur();
    leads[0].focus(); input(leads[0], "One word list.");
    host.flushPendingChanges();
    leads[0].blur();
    const expected = structuredClone(block);
    expected.items[0].text = "Compositions, not widgets.";
    expected.items[0].lead = "One word list.";
    const { id, type, ...expectedPatch } = expected;
    assert.deepEqual(batches.at(-1).ops.at(-1).patch, expectedPatch, "only the authored fields change; unknown keys stay");
    assert.deepEqual(host._editor.state.doc.firstChild.attrs.bpBlock, expected);
  } finally { host.remove(); }

  for (const attrs of [{ locked: true }, { query: { source: "derived" } }]) {
    const r = mount(attrs);
    try { assert.equal(r.host.querySelector('[aria-label="Note label"]'), null); }
    finally { r.host.remove(); }
  }

  const slotted = mount({ items: [{ slots: { body: [{ type: "paragraph", content: [{ type: "text", value: "Slot" }] }] }, label: "S" }, { label: "P4", text: "No lead here." }] });
  try {
    assert.equal(slotted.host.querySelectorAll('[aria-label="Note label"]').length, 1,
      "a slot-materialized row paints from its slots, so it stays panel-edited");
  } finally { slotted.host.remove(); }

  const mismatch = mount();
  try {
    paint(mismatch.host, `<div class="bp-notes">${row("P1", "One vocabulary.", "Only one row.")}</div>`);
    assert.equal(mismatch.host.querySelector('[aria-label="Note label"]'), null, "a mismatched paint never maps onto an arbitrary item");
  } finally { mismatch.host.remove(); }
  console.log("notes inline: label/lead/body edit in place, reader bytes kept, locked/query/slot rows and mismatched paints refused");
} finally { window.close(); }
