import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement",
  "InputEvent", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

const thrown = [];
window.addEventListener("error", (event) => thrown.push(event.error));
await import("../canvas/index.js");
const { mirror } = await import("./page/mirror.mjs");

const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const para = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });
const doc = [para("p-a", "Alpha"), para("p-e", ""), para("p-b", "Beta")];

async function mount() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("editable", "true");
  canvas.blocks = structuredClone(doc);
  document.body.append(canvas);
  await tick(50);
  return canvas;
}
const left = await mount();
const right = await mount();
mirror(left, right);

const lines = (canvas) => {
  const out = [];
  canvas._editor.state.doc.forEach((node) => {
    const runs = [];
    node.descendants((child) => { if (child.isText) runs.push(`${child.marks.map((m) => m.type.name).join("+")}/${child.text}`); });
    out.push(`${node.type.name}:${runs.join(" ")}`);
  });
  return out;
};
const caretAt = (canvas, id, offset) => {
  let pos;
  canvas._editor.state.doc.forEach((node, start) => { if (node.attrs.bpId === id) pos = start + offset; });
  canvas._editor.commands.setTextSelection(pos);
};
const key = (key, init = {}) => left._editor.view.dom.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
function typeLeft(chars) {
  const view = left._editor.view;
  left._editor.view.dom.dispatchEvent(new InputEvent("beforeinput", { inputType: "insertText", data: chars, bubbles: true, cancelable: true }));
  for (const char of chars) {
    const { from, to } = view.state.selection;
    if (!view.someProp("handleTextInput", (f) => f(view, from, to, char))) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}
function pasteLeft(data) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { types: Object.keys(data), getData: (kind) => data[kind] || "", files: [] } });
  left._editor.view.dom.dispatchEvent(event);
}
const same = (why) => assert.deepEqual(lines(right), lines(left), why);

caretAt(left, "p-a", 6);
caretAt(right, "p-b", 1);
key("Enter");
same("Enter goes in where the left caret is, not where the right one was");
assert.deepEqual(lines(left), ["paragraph:/Alpha", "paragraph:", "paragraph:", "paragraph:/Beta"]);
typeLeft("Fog");
same("typed text follows into the new line, whose id differs on each side");
key("Backspace");
same("Backspace");
caretAt(left, "p-e", 1);
typeLeft("mid");
same("a caret moved by clicking or a button follows by block id");
caretAt(left, "p-b", 1);
key("ArrowDown");
key("x");
same("arrows and plain character keys are not sent as keys");
caretAt(left, "p-b", 3);
typeLeft("!");
same("text in a selection's own block");
const selectBeta = (canvas) => {
  let start;
  canvas._editor.state.doc.forEach((node, at) => { if (node.attrs.bpId === "p-b") start = at; });
  canvas._editor.commands.setTextSelection({ from: start + 1, to: start + 5 });
};
selectBeta(left);
caretAt(right, "p-a", 1);
key("b", { metaKey: true });
key("b", { ctrlKey: true });
same("a range follows too, and shortcuts go across");
assert.ok(lines(left).some((line) => line.includes("bold/")), "the shortcut made bold text");
key("Delete");
same("Delete");
pasteLeft({ "text/plain": "One\n\nTwo" });
same("paste goes across with its clipboard");
assert.ok(lines(left).some((line) => line.includes("Two")), "the paste landed");
assert.deepEqual(thrown, [], "nothing threw");

console.log("PASS  testing-ground mirror: Enter, Backspace, Delete, shortcuts, typing and paste from the left window go into the right one at the same block");
