// Mounted regression: the standalone `action` block edits its label where the
// reader paints the button (the card action-label precedent). Before, Edit painted
// the reader anchor as a display-only preview and moved the label into a form input
// below it, so clicking the button's text placed no caret.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

for (const [name, path] of [
  ["shell", "../../../../priv/static/assets/bp-paper-editor-shell.css"],
  ["styles.css", "../styles.css"],
]) {
  const css = readFileSync(new URL(path, import.meta.url), "utf8");
  assert.match(css, /\.bp-canvas-action \[data-test-id="paper-action-label"\]:empty::before \{ content: attr\(data-placeholder\);/,
    `${name}: an empty in-place label keeps the button shape and names what goes there`);
  assert.doesNotMatch(css, /\.bp-canvas-action-label\b/, `${name}: no separate label input remains`);
}

const { BpPaperCanvas } = await import("./index.js");
assert.ok(BpPaperCanvas);
const settle = () => new Promise((resolve) => setTimeout(resolve, 350));

async function mount(blocks) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = blocks;
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
  document.body.appendChild(canvas);
  await settle();
  batches.length = 0;
  return { canvas, batches };
}

// 1. The label paints as the reader's button and is the editing host.
{
  const { canvas, batches } = await mount([
    { id: "cta", type: "action", label: "Read the report", href: "/report", priority: "primary",
      qa_meta: { keep: true } },
  ]);
  try {
    const frame = canvas.querySelector('[data-test-id="paper-action"]');
    const host = frame.querySelector('[data-test-id="paper-action-label"]');
    assert.ok(host, "the action paints an in-place label host");
    assert.equal(host.tagName, "SPAN", "the host is not a link, so a click never navigates");
    assert.equal(host.className, "bp-button bp-button--primary", "the host carries the reader's button classes");
    assert.equal(host.contentEditable, "plaintext-only", "the painted label is the editing host");
    assert.equal(host.getAttribute("role"), "textbox");
    assert.equal(host.textContent, "Read the report");
    assert.equal(host.parentElement.contentEditable, "false", "a non-editable boundary isolates the host from the canvas");
    const anchor = frame.querySelector("a.bp-button");
    assert.equal(anchor.style.display, "none", "the read-only anchor is not painted while editing");
    assert.equal(frame.querySelector("input.bp-canvas-action-label"), null, "no second label surface below the button");
    assert.ok(frame.querySelector(".bp-canvas-action-href"), "href stays a config control");
    assert.ok(frame.querySelector(".bp-canvas-action-priority"), "priority stays a config control");

    // Enter ends the edit instead of inserting a line.
    host.focus();
    const enter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    host.dispatchEvent(enter);
    assert.equal(enter.defaultPrevented, true, "Enter is consumed by the label host");

    host.textContent = "Read the full report";
    host.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(batches.length, 0, "typing stays behind the node debounce");
    assert.equal(canvas.flushPendingChanges(), true, "the canvas flush commits the label");
    assert.deepEqual(batches, [[{
      op: "patch-block", id: "cta",
      patch: { label: "Read the full report", href: "/report", priority: "primary" },
    }]], "the label edit changes the label only");
    assert.equal(host.className, "bp-button bp-button--primary", "the variant survives the edit");
  } finally {
    canvas.remove();
  }
}

// 2. A label edit never writes keys the author never set.
{
  const { canvas, batches } = await mount([{ id: "bare", type: "action", label: "Go" }]);
  try {
    const host = canvas.querySelector('[data-test-id="paper-action-label"]');
    assert.equal(host.className, "bp-button", "a never-set priority paints the secondary button");
    host.textContent = "Go now";
    host.dispatchEvent(new window.Event("input", { bubbles: true }));
    host.dispatchEvent(new window.Event("blur"));
    await settle();
    assert.deepEqual(batches, [[{ op: "patch-block", id: "bare", patch: { label: "Go now" } }]],
      "blur commits the label; no href or priority key is materialised");
  } finally {
    canvas.remove();
  }
}

// 3. An untouched mount and a no-op blur emit nothing.
{
  const { canvas, batches } = await mount([{ id: "quiet", type: "action", label: "Stay", href: "/s" }]);
  try {
    const host = canvas.querySelector('[data-test-id="paper-action-label"]');
    host.dispatchEvent(new window.Event("blur"));
    assert.equal(canvas.flushPendingChanges(), false);
    assert.equal(batches.length, 0, "no edit, no op");
  } finally {
    canvas.remove();
  }
}

window.close();
console.log("action label edits in place: ok");
