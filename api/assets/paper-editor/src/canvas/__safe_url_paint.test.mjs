import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

// The canvas paints a stored href/src through the reader's URL allowlist
// (Render.Util.safe_url/1), in Edit AND in the read-only canvas. Found by the
// injection sweep over every block type: the reader refused javascript:/data:
// URLs, but the action and card button previews, the card image, the image atom
// and the video island painted them into live href/src attributes.
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
const fetchMock = async () => ({ ok: true, json: async () => ({ documents: [] }) });
globalThis.fetch = fetchMock;
window.fetch = fetchMock;

const { safeUrl } = await import("../safe-url.js");
await import("../index.js");

// ── the allowlist, row for row with safe_url/1 ─────────────────────────────
for (const [input, want] of [
  ["https://example.com/a", "https://example.com/a"],
  ["mailto:a@b.c", "mailto:a@b.c"],
  ["/media/files/x.png", "/media/files/x.png"],
  ["#anchor", "#anchor"],
  ["./rel", "./rel"],
  ["javascript:alert(1)", "#"],
  [" JaVaScRiPt:alert(1)", "#"],
  ["java\tscript:alert(1)", "#"],
  ["data:text/html,<script>alert(1)</script>", "#"],
  ["vbscript:msgbox(1)", "#"],
  ["//evil.example/x", "#"],
  ["/\\evil.example/x", "#"],
  ["/\t/evil.example/x", "#"],
  [null, "#"],
  [42, "#"],
]) assert.equal(safeUrl(input), want, `safeUrl(${JSON.stringify(input)})`);

// ── the painted canvas ─────────────────────────────────────────────────────
const JS = "javascript:alert(1)";
const blocks = [
  { id: "act", type: "action", label: "Go", href: JS, priority: "primary" },
  { id: "card", type: "card", title: "Card", body: "Body", media: { src: JS, alt: "x" }, action: { label: "Open", href: JS } },
  { id: "img", type: "image", src: JS, alt: "x" },
  { id: "vid", type: "video", src: JS, poster: "data:text/html,<script>alert(1)</script>" },
];
const live = () => [...document.querySelectorAll("bp-paper-canvas [href], bp-paper-canvas [src], bp-paper-canvas [poster]")]
  .flatMap((el) => ["href", "src", "poster"].map((a) => [el.tagName, a, el.getAttribute(a)]))
  .filter(([, , v]) => v != null && /^\s*(javascript|vbscript|data:)/i.test(v));

for (const editable of [true, false]) {
  const host = document.createElement("bp-paper-canvas");
  host.setAttribute("data-dataset", "production");
  document.body.appendChild(host);
  host.blocks = blocks;
  try {
    if (!editable) host._editor.setEditable(false);
    await new Promise((r) => setTimeout(r, 50));
    const painted = [...host.querySelectorAll("[href], [src], [poster]")].length;
    assert.ok(painted >= 4, `the canvas paints the button, card and media attributes (${painted})`);
    assert.deepEqual(live(), [], `no javascript:/data: URL reaches a live attribute (${editable ? "Edit" : "read-only"})`);
  } finally {
    host.remove();
  }
}
window.close();
console.log("safe-url paint: the canvas paints stored URLs through the reader's allowlist");
