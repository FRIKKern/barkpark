// __menus_a11y.test.mjs — task-be754bd628311c5f: the slash menu is a NAMED
// listbox, the block menu owns menuitems in labelled groups, and on a touch
// screen (no hover) the block handle follows the caret even where a phone has
// no gutter, so a touch author can reach Duplicate / Move / Delete.
// Run: node src/canvas/__menus_a11y.test.mjs
import assert from "node:assert/strict";
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

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

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

  // Touch: put the caret in the second block; its handle shows.
  const { state, view } = canvas._editor;
  const posB = canvas._topLevelPos("p-b");
  view.focus();
  view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, posB + 2)));
  const handle = canvas.querySelector(".bp-block-handle");
  check("touch: the handle follows the caret (no hover, no gutter)", () => {
    assert.ok(handle.classList.contains("bp-block-handle--touch"));
    assert.equal(handle.style.display, "flex");
    assert.equal(canvas._handle._index, 1);
  });

  // The block menu: menuitems in labelled groups, and a name.
  canvas._handle._openMenu();
  const menu = document.querySelector(".bp-block-menu");
  check("block menu: a named role=menu whose actions are menuitems in labelled groups", () => {
    assert.equal(menu.getAttribute("role"), "menu");
    assert.ok(menu.getAttribute("aria-label"));
    const actions = [...menu.querySelectorAll("[data-action]")];
    assert.ok(actions.length > 0);
    for (const a of actions) assert.equal(a.getAttribute("role"), "menuitem", a.outerHTML.slice(0, 80));
    for (const child of menu.children) {
      assert.equal(child.getAttribute("role"), "group");
      assert.ok(child.getAttribute("aria-label"));
    }
  });
  canvas._handle._closeMenu();

  // The slash menu: a named listbox.
  canvas._openSlash("");
  const slash = document.querySelector(".bp-slash-menu");
  check("slash menu: a listbox with an accessible name", () => {
    assert.equal(slash.getAttribute("role"), "listbox");
    assert.equal(slash.getAttribute("aria-label"), "Insert block");
  });

  // task-5f171731bacb8ebe: arrowing moved only an `is-active` class, so a screen reader heard
  // nothing. The active option is aria-selected, and the editor — which keeps
  // focus — points at it.
  // The menu opens from typing "/" in the editor, so focus is there.
  const pm = canvas._editor.view.dom;
  canvas._closeSlash();
  canvas._editor.view.focus();
  canvas._openSlash("");
  const options = () => [...slash.querySelectorAll('[role="option"]')];
  check("slash menu: the active option is selected and the editor points at it", () => {
    assert.ok(slash.id, "the listbox has an id");
    assert.equal(pm.getAttribute("aria-controls"), slash.id);
    const [first, second] = options();
    assert.ok(first.id && second.id && first.id !== second.id, "options have unique ids");
    assert.equal(first.getAttribute("aria-selected"), "true");
    assert.equal(second.getAttribute("aria-selected"), "false");
    assert.equal(pm.getAttribute("aria-activedescendant"), first.id);
  });
  canvas._slash.move(1);
  check("slash menu: moving the selection moves aria-selected and activedescendant", () => {
    const [first, second] = options();
    assert.equal(first.getAttribute("aria-selected"), "false");
    assert.equal(second.getAttribute("aria-selected"), "true");
    assert.equal(pm.getAttribute("aria-activedescendant"), second.id);
  });
  canvas._closeSlash();
  check("slash menu: closing clears the editor's pointers", () => {
    assert.equal(pm.getAttribute("aria-activedescendant"), null);
    assert.equal(pm.getAttribute("aria-controls"), null);
  });

  // The name is in the viewer's language: it read "Insert block" in nb-NO.
  root.setAttribute("data-strings", JSON.stringify({ "Insert block": "Sett inn blokk" }));
  (await import("../i18n.js")).loadStringsFrom(canvas);
  canvas._editor.view.focus();
  canvas._openSlash("");
  check("slash menu: the listbox name is translated", () => {
    assert.equal(slash.getAttribute("aria-label"), "Sett inn blokk");
  });
  canvas._closeSlash();

  // The [[ / # / : popup had the same gap, and no accessible name at all.
  const { WikilinkMenu } = await import("../wikilink-menu.js");
  const host = document.createElement("div");
  host.setAttribute("contenteditable", "true");
  document.body.appendChild(host);
  host.focus();
  const wiki = new WikilinkMenu({});
  wiki.open({ left: 0, top: 0, bottom: 0 }, "");
  wiki.setResults([{ title: "Alpha", id: "a" }, { title: "Beta", id: "b" }]);
  wiki.move(1);
  const wikiEl = document.querySelector(".bp-wikilink-menu");
  check("wikilink menu: named, and the editor points at the selected option", () => {
    assert.equal(wikiEl.getAttribute("aria-label"), "Link to page");
    assert.equal(host.getAttribute("aria-controls"), wikiEl.id);
    const [a, b] = [...wikiEl.querySelectorAll('[role="option"]')];
    assert.equal(a.getAttribute("aria-selected"), "false");
    assert.equal(b.getAttribute("aria-selected"), "true");
    assert.equal(host.getAttribute("aria-activedescendant"), b.id);
  });
  wiki.close();
  check("wikilink menu: closing clears the editor's pointers", () => {
    assert.equal(host.getAttribute("aria-activedescendant"), null);
    assert.equal(host.getAttribute("aria-controls"), null);
  });
} finally {
  dom.window.close();
}
if (failures) { console.log(`${failures} failure(s)`); process.exit(1); }
console.log("canvas menus a11y passed");
