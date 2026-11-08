// __block_menu_viewport.test.mjs — task-be754bd628311c5f: on a 390x844 phone the
// block menu opened under a handle near the right/bottom edge and ran off both
// (x 266..466, y 460..1178), and the host canvas (overflow:auto) clipped it, so
// no item was reachable. It is now fixed-positioned, clamped to the viewport,
// flipped above the handle when there is no room below, and capped to the
// viewport height. Also: the faint text on a popup's tinted ACTIVE row fell under
// AA; there it steps up to the soft ink. The menu is a body portal (the panel's
// fixed-surface inventory: editor_panel_containment_test.exs).
// Run: node src/canvas/__block_menu_viewport.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readAuthoredCss } from "../__css_source_graph.mjs";

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
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
// A touch screen: (hover: none) matches. Set BEFORE the canvas mounts — the
// handle reads it once.
window.matchMedia = (query) => ({ matches: query.includes("hover: none"), media: query, addEventListener() {}, removeEventListener() {} });
globalThis.matchMedia = window.matchMedia;


const VW = 390, VH = 844, MARGIN = 8;
Object.defineProperty(window, "innerWidth", { configurable: true, value: VW });
Object.defineProperty(window, "innerHeight", { configurable: true, value: VH });

// Layout stubs: JSDOM has no layout. The handle's rect is set per case; the
// menu reports its natural size (capped by its own max-height, as a browser does).
let handleRect = { left: 300, right: 344, top: 780, bottom: 824, width: 44, height: 44 };
let menuNatural = { width: 200, height: 718 };
const realRect = window.HTMLElement.prototype.getBoundingClientRect;
window.HTMLElement.prototype.getBoundingClientRect = function () {
  if (this.classList.contains("bp-block-handle")) return { ...handleRect, x: handleRect.left, y: handleRect.top };
  if (this.classList.contains("bp-block-menu")) {
    const cap = parseFloat(this.style.maxHeight) || Infinity;
    const h = Math.min(menuNatural.height, cap);
    const left = parseFloat(this.style.left) || 0, top = parseFloat(this.style.top) || 0;
    return { left, top, right: left + menuNatural.width, bottom: top + h, width: menuNatural.width, height: h, x: left, y: top };
  }
  return realRect.call(this);
};

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
let failures = 0, ran = 0;
function check(name, fn) { ran += 1; try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

function insideViewport(menu) {
  const r = menu.getBoundingClientRect();
  assert.equal(menu.style.position, "fixed", "fixed, so an overflow:auto host cannot clip it");
  assert.ok(r.left >= MARGIN && r.right <= VW - MARGIN, `x ${r.left}..${r.right} inside 0..${VW}`);
  assert.ok(r.top >= MARGIN && r.bottom <= VH - MARGIN, `y ${r.top}..${r.bottom} inside 0..${VH}`);
  return r;
}

try {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [
    { id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] },
    { id: "p-b", type: "paragraph", content: [{ type: "text", value: "Beta" }] },
  ];
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const { state, view } = canvas._editor;
  view.focus();
  view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, canvas._topLevelPos("p-b") + 2)));

  canvas.style.setProperty("--paper-chrome-bg", "#123456");
  // Phone: handle near the right and bottom edge, a 718px menu (15 items).
  canvas._handle._openMenu();
  let menu = document.querySelector(".bp-block-menu");
  check("the menu is a body portal (out of the panel and the clipping host) and keeps the host's tokens", () => {
    assert.equal(menu.parentElement, document.body);
    assert.ok(!canvas.contains(menu));
    assert.equal(menu.style.getPropertyValue("--paper-chrome-bg"), "#123456");
  });
  check("phone: the menu stays inside the 390x844 viewport, flipped above the handle", () => {
    const r = insideViewport(menu);
    assert.ok(r.bottom <= handleRect.top, "opens above the handle when there is no room below");
    assert.equal(menu.querySelectorAll("[role=menuitem]").length > 0, true);
  });
  canvas._handle._closeMenu();

  // A menu taller than the viewport: capped, and it scrolls inside.
  menuNatural = { width: 200, height: 1200 };
  canvas._handle._openMenu();
  menu = document.querySelector(".bp-block-menu");
  check("a menu taller than the viewport is capped and scrolls, so every item is reachable", () => {
    insideViewport(menu);
    assert.equal(menu.style.overflowY, "auto");
    assert.ok(parseFloat(menu.style.maxHeight) <= VH - 2 * MARGIN);
  });
  canvas._handle._closeMenu();

  // Room below and to the right: it sits just under the handle, aligned left.
  menuNatural = { width: 200, height: 300 };
  handleRect = { left: 100, right: 144, top: 200, bottom: 222, width: 44, height: 22 };
  canvas._handle._openMenu();
  menu = document.querySelector(".bp-block-menu");
  check("with room, the menu sits just under the handle, aligned with its left edge", () => {
    insideViewport(menu);
    assert.equal(menu.style.left, "100px");
    assert.equal(menu.style.top, "226px");
  });
  canvas._handle._closeMenu();

  // The package owns the wikilink badge. The Barkpark host owns the slash row
  // and its theme contrast, which its host-only test reads from the live shell.
  const bundle = readAuthoredCss();
  check("the active wikilink row shows its faint text in the soft ink", () => {
    assert.match(bundle, /\.bp-wikilink-item\.is-active \.bp-wikilink-type-badge \{ color: var\(--paper-ink-soft\); \}/);
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.message}`);
} finally {
  if (ran !== 5) { failures += 1; console.log(`FAIL  ran ${ran} of 5 checks`); }
  dom.window.close();
}
if (failures) { console.log(`${failures} failure(s)`); process.exit(1); }
console.log("block menu viewport + local popup CSS passed");
