// Mounted regression: the block menu's "Turn into" converts a whole LIST.
//
// Found dogfooding the Studio canvas (2026-10-03): on a bulleted list, block menu →
// "Checklist" (or "Numbered list") did nothing; the console said "TextSelection
// endpoint not pointing into a node with inline content (bulletList)". The helper put
// the caret at the list's start + 1, between the list and its first item, so the list
// toggle had no list item to act on. The same helper backs the Mod-Shift-digit chords.

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
const { turnTopLevelInto } = await import("./block-handle.js");

const host = document.createElement("bp-paper-canvas");
host.blocks = [
  {
    id: "l1",
    type: "list",
    ordered: false,
    items: [
      [{ type: "text", value: "Alpha" }],
      [{ type: "text", value: "Beta" }],
      [{ type: "text", value: "Gamma" }],
    ],
  },
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Plain line" }] },
];
document.body.appendChild(host);

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  const editor = host._editor;
  assert.ok(editor, "the canvas editor is mounted");
  const top = (index) => editor.state.doc.child(index);
  const items = (node) => {
    const out = [];
    node.forEach((item) => out.push(item.textContent));
    return out;
  };

  for (const [kind, type] of [["task", "taskList"], ["ordered", "orderedList"], ["bullet", "bulletList"]]) {
    assert.equal(turnTopLevelInto(editor, 0, kind), true, `turn into ${kind} applies`);
    assert.equal(top(0).type.name, type, `the list became a ${type}`);
    assert.deepEqual(items(top(0)), ["Alpha", "Beta", "Gamma"], `all three items stay in the ${type}`);
    assert.equal(top(0).attrs.bpId, "l1", `the ${type} keeps the block's id`);
    assert.equal(top(1).type.name, "paragraph", "the next block is untouched");
  }

  // Textblocks still turn into each other and into a list.
  assert.equal(turnTopLevelInto(editor, 1, "h2"), true);
  assert.equal(top(1).type.name, "heading");
  assert.equal(top(1).attrs.level, 2);
  assert.equal(turnTopLevelInto(editor, 1, "ordered"), true);
  assert.equal(top(1).type.name, "orderedList");
  assert.deepEqual(items(top(1)), ["Plain line"]);

  console.log("PASS turn_into_list: Turn into converts a whole list between list kinds");
} finally {
  host.remove();
  window.close();
}
