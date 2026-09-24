// __link_preview.test.mjs — the hover card on a link and a wikilink (Barkdown plan #23), mounted.
// A canvas with one paragraph holding a plain link and a wikilink; the card shows the address for
// the link and the host-resolved title + first line for the wikilink; Open hands a cancelable
// bp-canvas-open-link to the host; Edit selects the whole mark and opens the bubble's link row
// seeded with the href; leaving hides; destroy removes the card.
// Run: node src/canvas/__link_preview.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (v) => String(v) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
// jsdom has no layout: give every element a small box so positioning code runs.
window.Element.prototype.getBoundingClientRect = function () { return { left: 10, top: 20, right: 110, bottom: 40, width: 100, height: 20 }; };
// jsdom's window.open logs a "not implemented" error; count calls instead.
let opened = [];
window.open = (href) => { opened.push(href); return null; };

const { BpPaperCanvas } = await import("./index.js");
const { LinkPreview } = await import("./link-preview.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

let failures = 0;
function check(name, fn) { return Promise.resolve().then(fn).then(() => console.log(`PASS  ${name}`), (e) => { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e && e.stack ? e.stack.split("\n").slice(0, 3).join("\n      ") : e}`); }); }
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

const blocks = [{ id: "p1", type: "paragraph", content: [
  { type: "text", value: "See " },
  { type: "link", href: "https://example.org/docs/page", children: [{ type: "text", value: "the docs" }] },
  { type: "text", value: " and " },
  { type: "wikilink", target: "Target paper", docId: "target-paper", children: [{ type: "text", value: "Target paper" }] },
  { type: "text", value: "." },
] }];

async function mount(editable = true) {
  const canvas = document.createElement("bp-paper-canvas");
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.blocks = blocks;
  canvas.linkPreviewSource = async (info) => (info.kind === "wikilink" ? { title: "Target paper — the real title", excerpt: "The first line of the target paper.", href: "bp:target-paper" } : null);
  document.body.appendChild(canvas);
  await tick(0);
  assert.ok(canvas._editor, "editor mounted");
  const a = canvas.querySelector("a[href]");
  const w = canvas.querySelector("span[data-wikilink]");
  assert.ok(a && w, "link and wikilink in the DOM");
  return { canvas, a, w };
}

await check("describe(): a link's href, a wikilink's target and docId", async () => {
  const { canvas, a, w } = await mount();
  assert.deepEqual({ ...LinkPreview.describe(a), el: null }, { kind: "link", href: "https://example.org/docs/page", el: null });
  const d = LinkPreview.describe(w);
  assert.equal(d.kind, "wikilink"); assert.equal(d.target, "Target paper"); assert.equal(d.docId, "target-paper");
  canvas.remove();
});

await check("hovering the link shows its host and address; Edit shows in edit mode", async () => {
  const { canvas, a } = await mount();
  const lp = canvas._linkPreview;
  assert.ok(lp, "canvas has a LinkPreview");
  assert.equal(lp.showFor(a), true);
  const card = document.body.querySelector(".bp-link-preview");
  assert.ok(card && card.style.display !== "none", "card visible");
  assert.equal(card.dataset.kind, "link");
  assert.equal(card.querySelector(".bp-link-preview__title").textContent, "example.org");
  assert.equal(card.querySelector(".bp-link-preview__addr").textContent, "https://example.org/docs/page");
  assert.equal(card.querySelector(".bp-link-preview__excerpt").style.display, "none");
  assert.notEqual(card.querySelector(".bp-link-preview__edit").style.display, "none");
  canvas.remove();
});

await check("the body portal follows the hovered paper theme on each opening", async () => {
  const { canvas, a } = await mount();
  a.style.setProperty("--paper-ink", "#123456");
  a.style.setProperty("--paper-chrome-bg", "#f0f1f2");
  canvas._linkPreview.showFor(a);
  assert.equal(canvas._linkPreview.el.style.getPropertyValue("--paper-ink"), "#123456");
  assert.equal(canvas._linkPreview.el.style.getPropertyValue("--paper-chrome-bg"), "#f0f1f2");
  a.style.setProperty("--paper-ink", "#fedcba");
  canvas._linkPreview.showFor(a);
  assert.equal(canvas._linkPreview.el.style.getPropertyValue("--paper-ink"), "#fedcba");
  canvas.remove();
});

await check("hovering the wikilink shows [[target]] at once, then the resolved title and first line", async () => {
  const { canvas, w } = await mount();
  const lp = canvas._linkPreview;
  lp.showFor(w);
  const card = lp.el;
  assert.equal(card.dataset.kind, "wikilink");
  assert.equal(card.querySelector(".bp-link-preview__addr").textContent, "[[Target paper]]");
  await tick(0);
  assert.equal(card.querySelector(".bp-link-preview__title").textContent, "Target paper — the real title");
  assert.equal(card.querySelector(".bp-link-preview__excerpt").textContent, "The first line of the target paper.");
  assert.notEqual(card.querySelector(".bp-link-preview__excerpt").style.display, "none");
  canvas.remove();
});

await check("Open on a wikilink dispatches bp-canvas-open-link with target, docId and the resolved href; a handled event opens no window", async () => {
  const { canvas, w } = await mount();
  const seen = [];
  canvas.addEventListener("bp-canvas-open-link", (e) => { seen.push(e.detail); e.preventDefault(); });
  canvas._linkPreview.showFor(w);
  await tick(0);
  opened = [];
  canvas._linkPreview.el.querySelector(".bp-link-preview__open").click();
  assert.equal(seen.length, 1);
  assert.deepEqual(seen[0], { kind: "wikilink", href: "bp:target-paper", target: "Target paper", docId: "target-paper", alias: null });
  assert.deepEqual(opened, []);
  assert.equal(canvas._linkPreview.isOpen(), false, "card hidden after Open");
  canvas.remove();
});

await check("Open on a plain link that nobody handles falls back to a new window", async () => {
  const { canvas, a } = await mount();
  canvas._linkPreview.showFor(a);
  opened = [];
  canvas._linkPreview.el.querySelector(".bp-link-preview__open").click();
  assert.deepEqual(opened, ["https://example.org/docs/page"]);
  canvas.remove();
});

await check("Edit on the link selects the whole link and opens the bubble's link row seeded with the href", async () => {
  const { canvas, a } = await mount();
  canvas._linkPreview.showFor(a);
  canvas._linkPreview.el.querySelector(".bp-link-preview__edit").click();
  const { from, to } = canvas._editor.state.selection;
  assert.equal(canvas._editor.state.doc.textBetween(from, to), "the docs");
  const input = document.body.querySelector(".bp-paper-format__link-input");
  assert.ok(input, "link row open");
  assert.equal(input.value, "https://example.org/docs/page");
  canvas.remove();
});

await check("Edit on the wikilink selects the whole wikilink text", async () => {
  const { canvas, w } = await mount();
  canvas._linkPreview.showFor(w);
  canvas._linkPreview.el.querySelector(".bp-link-preview__edit").click();
  const { from, to } = canvas._editor.state.selection;
  assert.equal(canvas._editor.state.doc.textBetween(from, to), "Target paper");
  canvas.remove();
});

await check("read-only: the card still shows the address but no Edit", async () => {
  const { canvas, a } = await mount(false);
  canvas._linkPreview.showFor(a);
  const card = canvas._linkPreview.el;
  assert.equal(card.querySelector(".bp-link-preview__addr").textContent, "https://example.org/docs/page");
  assert.equal(card.querySelector(".bp-link-preview__edit").style.display, "none");
  canvas.remove();
});

await check("mouseover shows after the delay, mouseout hides after its delay; a keypress hides at once; destroy removes the card", async () => {
  const { canvas, a } = await mount();
  const lp = canvas._linkPreview;
  lp._delay = 5; lp._hideDelay = 5;
  a.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  assert.equal(lp.isOpen(), false, "not yet");
  await tick(20);
  assert.equal(lp.isOpen(), true, "shown after the delay");
  a.dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body }));
  await tick(20);
  assert.equal(lp.isOpen(), false, "hidden after leaving");
  lp.showFor(a);
  canvas._editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "a", bubbles: true }));
  assert.equal(lp.isOpen(), false, "a keypress hides it");
  canvas.remove();
  await tick(0);
  assert.equal(document.body.querySelector(".bp-link-preview"), null, "card removed on disconnect");
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
