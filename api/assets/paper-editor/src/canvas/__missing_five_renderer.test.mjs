import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { runToOps, runToTiptap } from "./run-convert.js";

const TYPES = ["arrayOf", "codelist", "composite", "localizedText", "pre-gate-badge"];
const fixtures = TYPES.map((type) => {
  const path = new URL(`../../../../priv/portable_doc/goldens/blocks/${type}.golden.json`, import.meta.url);
  const golden = JSON.parse(readFileSync(path, "utf8"));
  return { type, block: { ...golden.input, id: `missing-five-${type}` }, html: golden.expectedHtml };
});

for (const { type, block } of fixtures) {
  const doc = runToTiptap([block]);
  assert.equal(doc.content.length, 1, `${type}: projects one node`);
  assert.equal(doc.content[0].type, "bpFleet", `${type}: uses the server-paint receiver`);
  assert.deepEqual(doc.content[0].attrs.bpBlock, block, `${type}: carries the source block verbatim`);
  assert.deepEqual(runToOps([block], doc), [], `${type}: an untouched receiver emits zero ops`);
}

const { window } = new JSDOM("<!doctype html><body></body>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
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

try {
  for (const { type, block, html } of fixtures) {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [block];
    document.body.appendChild(canvas);
    try {
      await new Promise((resolve) => setTimeout(resolve, 0));
      const hole = canvas.querySelector("[data-bp-fleet-body]");
      assert.ok(hole, `${type}: mounts a server-paint hole`);
      const event = new CustomEvent("bp-fleet-paint", {
        detail: { html, sourceBlock: block },
        cancelable: true,
      });
      assert.equal(hole.dispatchEvent(event), true, `${type}: delegates canonical HTML injection to the host`);
      hole.innerHTML = html;
      assert.equal(hole.innerHTML, html, `${type}: resting DOM is byte-identical to the reader fragment`);
      assert.equal(canvas.querySelector(".bp-paper-contextual-controls"), null,
        `${type}: renderer-only rows add no competing edit chrome`);
    } finally {
      canvas.remove();
    }
  }
} finally {
  window.close();
}

console.log("missing-five renderer: verbatim source, zero ops, and exact server-painted reader DOM");
