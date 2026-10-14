// __format_bubble_off_mounted.test.mjs — format-bubble="off" (EMBED-CONTRACT "Toolbar
// commands"): a host that draws its own toolbar turns the canvas's floating format bubble
// off. No bubble shows on a selection, set or cleared after mount too, and Mod+K and the
// link card's Edit ask the host instead (bp-canvas-link-request, with the current href).
//
// Run: node src/canvas/__format_bubble_off_mounted.test.mjs   (or: npm test)

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
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
const rect = { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 };
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => rect;
window.Element.prototype.getClientRects = () => [];
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");
const { TextSelection } = await import("@tiptap/pm/state");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const text = (value) => [{ type: "text", value }];
const BLOCKS = [
  { id: "p-1", type: "paragraph", content: text("Hello world") },
  { id: "p-2", type: "paragraph", content: [{ type: "text", value: "Linked", marks: [{ type: "link", href: "https://example.com/a" }] }, { type: "text", value: " tail" }] },
];
function posOfText(editor, needle) {
  let at = null;
  editor.state.doc.descendants((node, pos) => {
    if (at != null) return false;
    if (node.isText && node.text.includes(needle)) at = pos + node.text.indexOf(needle);
    return true;
  });
  assert.notEqual(at, null, `text ${needle} is in the doc`);
  return at;
}
const selectText = (editor, needle) => {
  const at = posOfText(editor, needle);
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at, at + needle.length)));
};
const bubbleShown = () => [...document.querySelectorAll(".bp-paper-format")].some((el) => el.style.display !== "none");
function modK(canvas) {
  const event = new window.KeyboardEvent("keydown", { key: "k", code: "KeyK", keyCode: 75, ctrlKey: true, bubbles: true, cancelable: true });
  canvas.querySelector(".ProseMirror").dispatchEvent(event);
  return event;
}

let failed = false;
const canvas = document.createElement("bp-paper-canvas");
canvas.setAttribute("format-bubble", "off");
canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
const requests = [];
canvas.addEventListener("bp-canvas-link-request", (event) => requests.push(event.detail));
document.body.appendChild(canvas);
try {
  await sleep(350);
  const editor = canvas._editor;
  assert.ok(editor?.view?.dom?.isConnected, "the real editor is mounted");
  editor.view.dom.focus();

  // Off: a selection floats no bubble, and the toolbar commands still work.
  selectText(editor, "Hello");
  await sleep(50);
  assert.equal(canvas._bubble, null, "no bubble is made");
  assert.equal(bubbleShown(), false, "nothing floats over the selection");
  assert.equal(canvas.toggleMark("strong"), true, "the host's toolbar still marks");

  // Mod+K asks the host, with no href off a link and the link's href on one.
  const event = modK(canvas);
  assert.equal(event.defaultPrevented, true, "Mod+K is handled");
  assert.deepEqual(requests.at(-1), { href: null }, "a link request with no href");
  selectText(editor, "Linked");
  modK(canvas);
  assert.deepEqual(requests.at(-1), { href: "https://example.com/a" }, "a link request carrying the link's href");
  assert.equal(bubbleShown(), false, "still no bubble");

  // Cleared after mount: the bubble comes back on the next selection.
  canvas.removeAttribute("format-bubble");
  assert.ok(canvas._bubble, "the bubble is made again");
  selectText(editor, "world");
  await sleep(50);
  assert.equal(bubbleShown(), true, "the bubble floats over the selection again");
  const before = requests.length;
  modK(canvas);
  assert.equal(requests.length, before, "with the bubble, Mod+K opens its link row, not the host's");

  // Set after mount: gone again.
  canvas.setAttribute("format-bubble", "off");
  assert.equal(canvas._bubble, null, "the bubble is dropped");
  assert.equal(bubbleShown(), false, "and nothing floats");

  console.log("PASS format_bubble_off: no bubble, live toggle, Mod+K asks the host with the current href");
} catch (error) {
  failed = true;
  throw error;
} finally {
  canvas.remove();
  dom.window.close();
  if (failed) process.exitCode = 1;
}
