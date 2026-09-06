// Mounted canvas regression for the complete autocomplete selection seam:
// query source -> visible picker -> keyboard choice -> canonical patch payload.

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
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");

const candidate = {
  title: "Reader Autocomplete Candidate",
  id: "reader-autocomplete-candidate",
  type: "paper",
};
const tag = "reader-autocomplete-tag";
const queries = [];
const batches = [];

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [{
  id: "body",
  type: "paragraph",
  content: [{ type: "text", value: "Start " }],
}];
canvas.wikilinkSource = async (query) => {
  queries.push(["wikilink", query]);
  return [candidate];
};
canvas.tagSource = async (query) => {
  queries.push(["tag", query]);
  return [tag];
};
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
document.body.appendChild(canvas);

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const openPickerTitle = () =>
  [...document.querySelectorAll(".bp-wikilink-menu")]
    .find((menu) => menu.style.display === "block")
    ?.querySelector(".bp-wikilink-title")
    ?.textContent;
const pressEnter = () => {
  const event = new window.KeyboardEvent("keydown", {
    key: "Enter",
    bubbles: true,
    cancelable: true,
  });
  canvas._editor.view.dom.dispatchEvent(event);
};

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;

  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  assert.equal(editor.commands.setTextSelection(editor.state.doc.content.size - 1), true);

  assert.equal(editor.commands.insertContent("[[Reader"), true);
  await tick();
  assert.deepEqual(queries, [["wikilink", "Reader"]]);
  assert.equal(openPickerTitle(), candidate.title);
  pressEnter();

  assert.equal(editor.commands.insertContent("#reader"), true);
  await tick();
  assert.deepEqual(queries, [["wikilink", "Reader"], ["tag", "reader"]]);
  assert.equal(openPickerTitle(), `#${tag}`);
  pressEnter();

  assert.equal(canvas.flushPendingChanges(), true);
  assert.deepEqual(batches, [[{
    op: "patch-block",
    id: "body",
    patch: {
      content: [
        { type: "text", value: "Start " },
        {
          type: "wikilink",
          target: candidate.title,
          docId: candidate.id,
          children: [{ type: "text", value: candidate.title }],
        },
        { type: "text", value: " " },
        { type: "tag", name: tag },
        { type: "text", value: " " },
      ],
    },
  }]]);
  assert.equal(canvas.flushPendingChanges(), false, "the selected marks are clean after flush");

  console.log("mounted autocomplete query, selection, and canonical payload passed");
} finally {
  canvas.remove();
  window.close();
}
