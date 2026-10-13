// __media_picker_hook_mounted.test.mjs — the host's image picker (mediaPicker,
// EMBED-CONTRACT): an Image insert opens it for the new block, an image's Select opens
// it for that image, and its answer becomes the image's src (alt, width) in one undo
// step. null or a throw leaves the image as it was; unset, the image block is today's.
//
// Run: node src/canvas/__media_picker_hook_mounted.test.mjs   (or: npm test)

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
  { id: "img-1", type: "image", src: "https://cdn.example/old.png", alt: "Old" },
];
const images = (editor) => { const out = []; editor.state.doc.descendants((n) => { if (n.type.name === "bpImage") out.push({ src: n.attrs.src || "", alt: n.attrs.alt || "", width: n.attrs.width ?? null }); return true; }); return out; };
const caretIn = (editor, needle) => {
  let at = null;
  editor.state.doc.descendants((n, p) => { if (at == null && n.isText && n.text.includes(needle)) at = p + n.text.indexOf(needle) + 1; return true; });
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
};
const content = (json) => JSON.parse(JSON.stringify(json, (k, v) => (k === "bpId" || k === "bpType" ? undefined : v)));

async function mount() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail.ops));
  document.body.appendChild(canvas);
  await sleep(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real editor is mounted");
  return { canvas, editor: canvas._editor, batches };
}

let failed = false;
const mounts = [];
try {
  const { canvas, editor, batches } = await mount();
  mounts.push(canvas);
  assert.equal(canvas.hasAttribute("data-media-picker"), false, "no picker: no attribute");
  const calls = [];
  let answer = { src: "https://cdn.example/picked.png", alt: "Picked", width: 320 };
  canvas.mediaPicker = async (request) => (calls.push(request), typeof answer === "function" ? answer() : answer);
  assert.equal(canvas.hasAttribute("data-media-picker"), true, "a picker marks the canvas (its Select shows)");
  editor.view.dom.focus();

  // Insert Image: the picker opens for the new block; its answer fills it, saved, one undo step.
  caretIn(editor, "Hello");
  const before = editor.getJSON();
  const from = batches.length;
  assert.equal(canvas.insertBlock("image"), true, "Image inserts");
  await sleep(20);
  assert.equal(calls.length, 1, "the picker opened once");
  assert.deepEqual(calls[0], { kind: "insert", current: null }, "asked for a new image");
  assert.deepEqual(images(editor)[0], { src: "https://cdn.example/picked.png", alt: "Picked", width: 320 }, "the new image holds the pick");
  await sleep(600);
  assert.ok(JSON.stringify(batches.slice(from)).includes("https://cdn.example/picked.png"), "the pick is on the wire");
  // The insert and its pick are one gesture: one undo takes both back.
  assert.equal(editor.commands.undo(), true);
  assert.deepEqual(content(editor.getJSON()), content(before), "one undo takes the picked image back");
  await sleep(600);

  // Select on an image: asked with its current picture, replaced by the answer.
  const select = canvas.querySelector(".bp-canvas-image-pick");
  assert.ok(select, "an image offers Select");
  select.click();
  await sleep(20);
  assert.deepEqual(calls.at(-1), { kind: "replace", current: { src: "https://cdn.example/old.png", alt: "Old" } }, "asked to replace, with the current picture");
  assert.equal(images(editor).at(-1).src, "https://cdn.example/picked.png", "replaced");
  await sleep(600);

  // Cancel (null) or a failing picker: nothing changes.
  for (const next of [null, () => { throw new Error("closed"); }, { src: "  " }]) {
    answer = next;
    const doc = editor.getJSON();
    canvas.querySelector(".bp-canvas-image-pick").click();
    await sleep(20);
    assert.deepEqual(editor.getJSON(), doc, "no pick, no change");
  }

  // Unset: no attribute, and an Image insert is today's empty block.
  canvas.mediaPicker = null;
  assert.equal(canvas.hasAttribute("data-media-picker"), false);
  const count = calls.length;
  caretIn(editor, "Hello");
  assert.equal(canvas.insertBlock("image"), true);
  await sleep(20);
  assert.equal(calls.length, count, "no picker is asked");
  assert.equal(images(editor)[0].src, "", "an empty image block, as before");

  console.log("PASS media_picker_hook: insert and Select open the host's picker; the pick lands in one undo step; cancel and unset change nothing");
} catch (error) {
  failed = true;
  throw error;
} finally {
  for (const c of mounts) c.remove();
  dom.window.close();
  if (failed) process.exitCode = 1;
}
