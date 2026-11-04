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
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

const { undoDepth } = await import("@tiptap/pm/history");
const { markdownToBlocks } = await import("../markdown.js");
await import("../index.js");
await import("./index.js");

const paragraph = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });
const clone = (value) => JSON.parse(JSON.stringify(value));
const sorted = (value) => Array.isArray(value)
  ? value.map(sorted)
  : value && typeof value === "object"
    ? Object.fromEntries(Object.keys(value).sort()
      .filter((key) => !(key === "lang" && value[key] === ""))
      .map((key) => [key, sorted(value[key])]))
    : value;

// A server that folds each batch the way portable_doc/patch.ex does: patch-block is a
// shallow merge that never changes `type`.
function replay(server, op) {
  const at = (id) => server.findIndex((block) => block.id === id);
  const need = (id) => {
    const index = at(id);
    assert.notEqual(index, -1, `${op.op} names ${id}, which the server does not hold`);
    return index;
  };
  if (op.op === "patch-block") {
    const index = need(op.id);
    server[index] = { ...server[index], ...clone(op.patch) };
  } else if (op.op === "replace-block") server[need(op.id)] = clone(op.block);
  else if (op.op === "remove-block") server.splice(need(op.id), 1);
  else if (op.op === "insert-after") {
    assert.equal(at(op.block.id), -1, `insert-after re-inserts ${op.block.id}`);
    server.splice(op.afterId == null ? 0 : need(op.afterId) + 1, 0, clone(op.block));
  } else if (op.op === "append-block") {
    assert.equal(at(op.block.id), -1, `append-block re-inserts ${op.block.id}`);
    server.push(clone(op.block));
  } else if (op.op === "move-block") {
    const [block] = server.splice(need(op.id), 1);
    server.splice(op.after == null ? 0 : need(op.after) + 1, 0, block);
  } else assert.fail(`unexpected op ${op.op}`);
}

async function mount(blocks, { flushKeepsSource = true } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.flushKeepsSource = flushKeepsSource;
  canvas.blocks = blocks;
  const batches = [];
  const server = clone(blocks);
  const refused = [];
  canvas.addEventListener("bp-canvas-ops", (event) => {
    batches.push(event.detail.ops);
    try {
      for (const op of event.detail.ops) replay(server, op);
    } catch (error) {
      refused.push(error.message);
    }
    canvas.acknowledgeOps(event.detail.seq, true);
  });
  document.body.appendChild(canvas);
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;
  const inSync = (label) => {
    assert.deepEqual(refused, [], `the server takes every op ${label}`);
    assert.deepEqual(sorted(server), sorted(canvas.blocks),
      `the server's replay of every batch equals the canvas's blocks ${label}`);
  };
  return { canvas, batches, server, inSync };
}

const liveIds = (canvas) => canvas._editor.getJSON().content.map((node) => node.attrs.bpId);
const liveTexts = (canvas) => canvas._editor.getJSON().content.map((node) =>
  node.attrs.value ?? (node.content || []).map((child) => child.text || "").join(""));

function watchValueWrites(textarea) {
  const proto = Object.getPrototypeOf(textarea);
  const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
  const writes = [];
  Object.defineProperty(textarea, "value", {
    configurable: true,
    get() { return descriptor.get.call(this); },
    set(v) { writes.push(v); descriptor.set.call(this, v); },
  });
  const type = (v) => { descriptor.set.call(textarea, v); textarea.dispatchEvent(new window.Event("input", { bubbles: true })); };
  // One key at the selection, as a browser does: it replaces what is selected.
  const press = (key) => {
    const [from, to, text] = [textarea.selectionStart, textarea.selectionEnd, textarea.value];
    type(text.slice(0, from) + key + text.slice(to));
    textarea.setSelectionRange(from + key.length, from + key.length);
  };
  return { writes, type, press };
}

export {
  window, undoDepth, markdownToBlocks, paragraph, clone, sorted, mount, liveIds,
  liveTexts, watchValueWrites,
};
