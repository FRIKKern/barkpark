// The canvas block handle (+ and ⋮⋮) is gutter chrome: it must never take page space
// and never cover authored text.
//
// /papers loads ONLY the shell stylesheet (BP_PAPER_EDITOR_NO_INJECT), which lacked
// the gutter rules. The handle then rendered IN FLOW at the end of its canvas: a
// hovered or focused nested run (step body, terminal body) grew 22px and shrank again
// 250ms after the pointer left, sliding every block below under the next click. Made
// absolute, the old `Math.max(0, …)` clamp then parked it over the first word of a
// block with no gutter, where it would take the click aimed at that word.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

for (const file of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /(^|\n)bp-paper-canvas\s*\{[^}]*position: relative;/, `${file}: the canvas anchors its gutter chrome`);
  assert.match(css, /\n\.bp-block-handle\s*\{[^}]*position: absolute;/, `${file}: the block handle is out of flow`);
  assert.match(css, /\n\.bp-block-drop\s*\{[^}]*position: absolute;/, `${file}: the drop line is out of flow`);
  // Fixed since task-be754bd628311c5f: out of flow AND out of an overflow:auto
  // host's clip, so a phone's viewport-clamped menu stays reachable.
  assert.match(css, /\n\.bp-block-menu\s*\{[^}]*position: (absolute|fixed);/, `${file}: the block menu is out of flow`);
}

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("./index.js");

const rect = (left, top, width, height) => () => ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top });
const host = document.createElement("bp-paper-canvas");
host.blocks = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "First word here" }] }];
document.body.appendChild(host);
const handle = host.querySelector(".bp-block-handle");
assert.ok(handle, "an editable canvas mounts its gutter handle");
const para = host.querySelector(".ProseMirror > p");
assert.ok(para, "paragraph painted");

const hover = () => host.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: 0, clientY: 30 }));
let failures = 0;
const check = (name, fn) => { try { fn(); console.log(`ok - ${name}`); } catch (e) { failures++; console.error(`not ok - ${name}\n  ${e.message}`); } };

try {
  check("with a gutter, the handle sits left of the block and clear of its text", () => {
    host.getBoundingClientRect = rect(400, 0, 600, 200);
    para.getBoundingClientRect = rect(400, 20, 600, 28);
    hover();
    assert.equal(handle.style.display, "flex", "hover shows the handle");
    const left = 400 + parseFloat(handle.style.left);
    assert.ok(left + 46 <= 400, `handle spans ${left}..${left + 46}, the text starts at 400`);
  });
  check("without a gutter (block starts at the viewport edge), there is no handle over the first word", () => {
    handle.style.display = "none";
    host.getBoundingClientRect = rect(16, 0, 358, 200);
    para.getBoundingClientRect = rect(16, 20, 358, 28);
    hover();
    if (handle.style.display !== "none") {
      const left = 16 + parseFloat(handle.style.left);
      assert.ok(left + 46 <= 16, `a shown handle spans ${left}..${left + 46} over text starting at 16`);
    }
  });
} finally {
  host.remove();
}

if (failures) { console.error(`${failures} block handle gutter check(s) failed`); process.exit(1); }
console.log("block handle gutter: ok");
