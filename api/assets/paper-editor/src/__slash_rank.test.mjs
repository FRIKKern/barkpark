// The slash menu's first row is the block the author named.
//
// Found dogfooding the Studio canvas (2026-10-03): "/section" + Enter inserted a
// Heading. The filter is a substring over label, type, description and group, and
// Heading ("h1 — section title") sits above Section, so it was the first match.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["document", "HTMLElement", "Element", "Node", "CustomEvent", "Event", "KeyboardEvent", "MouseEvent"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
window.Element.prototype.scrollIntoView ||= () => {};
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);

const { SlashMenu, SLASH_ITEMS } = await import("./slash-menu.js");

const menu = new SlashMenu({ items: SLASH_ITEMS, onChoose: () => {}, onDismiss: () => {} });
const first = (query) => {
  menu.open({ left: 0, top: 0, bottom: 0 }, query);
  const type = menu._items[0]?.type;
  menu.close();
  return type;
};

try {
  assert.equal(first("section"), "section", "/section picks Section, not Heading (whose description says 'section title')");
  assert.equal(first("sec"), "section");
  assert.equal(first("heading"), "heading");
  assert.equal(first("quote"), "blockquote", "Quote before Pullquote");
  assert.equal(first("image"), "image", "Image before Image field");
  assert.equal(first("note"), "note", "Note before Footnotes");
  assert.equal(first("table"), "table");
  // Everything that matched is still offered; only the order changed.
  menu.open({ left: 0, top: 0, bottom: 0 }, "section");
  const types = menu._items.map((item) => item.type);
  menu.close();
  assert.ok(types.includes("heading"), "Heading is still offered for /section");
  // Groups stay contiguous: no group header appears twice.
  menu.open({ left: 0, top: 0, bottom: 0 }, "e");
  const groups = menu._items.map((item) => item.group);
  menu.close();
  const runs = groups.filter((group, index) => index === 0 || groups[index - 1] !== group);
  assert.equal(new Set(runs).size, runs.length, `each group is one contiguous run: ${runs.join(", ")}`);

  console.log("PASS slash_rank: the first slash row is the block the author named");
} finally {
  window.close();
}
