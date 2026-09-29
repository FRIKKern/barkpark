// A paragraph or heading with no authored alignment paints NO inline text-align in Edit,
// exactly like the reader (which inherits `start`). Stock TextAlign painted its default
// `text-align: left` on every block — the View/Edit parity matrix's textAlign start/left
// divergence on every heading and paragraph. Authored center/right still paint, and
// switching back to left removes the inline style again.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

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

const host = document.createElement("bp-paper-canvas");
host.blocks = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Plain paragraph" }] },
  { id: "h1", type: "heading", level: 2, text: "Plain heading" },
  { id: "p2", type: "paragraph", align: "center", content: [{ type: "text", value: "Centred" }] },
  { id: "h2", type: "heading", level: 2, align: "right", text: "Right heading" },
];
document.body.appendChild(host);
const pm = host.querySelector(".ProseMirror");
const [p1, h1, p2, h2] = pm.children;

let failures = 0;
const check = (name, fn) => { try { fn(); console.log(`ok - ${name}`); } catch (e) { failures++; console.error(`not ok - ${name}\n  ${e.message}`); } };
try {
  check("an unaligned paragraph and heading carry no inline text-align (they inherit start, like View)", () => {
    assert.equal(p1.style.textAlign, "", `paragraph style="${p1.getAttribute("style")}"`);
    assert.equal(h1.style.textAlign, "", `heading style="${h1.getAttribute("style")}"`);
  });
  check("authored center / right still paint", () => {
    assert.equal(p2.style.textAlign, "center");
    assert.equal(h2.style.textAlign, "right");
  });
  check("aligning back to left removes the inline style", () => {
    const ed = host._editor;
    let pos = -1;
    ed.state.doc.forEach((node, offset) => { if (node.attrs.bpId === "p2") pos = offset; });
    assert.ok(pos >= 0, "centred paragraph found");
    ed.chain().setTextSelection(pos + 1).setTextAlign("left").run();
    const again = host.querySelector(".ProseMirror").children[2];
    assert.equal(again.style.textAlign, "", `after left: style="${again.getAttribute("style")}"`);
  });
} finally {
  host.remove();
}
if (failures) { console.error(`${failures} align paint check(s) failed`); process.exit(1); }
console.log("align paint: ok");
