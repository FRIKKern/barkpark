// Mounted regression for node-view controls whose values are held behind their
// own debounce. The canvas flush must commit those controls before diffing the run.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import vm from "node:vm";

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

const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const context = vm.createContext({ window, document, customElements, CustomEvent,
  FormData: window.FormData, setTimeout, clearTimeout });
vm.runInContext(readFileSync(new URL("../../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"), context);
const hooks = window.BarkparkPaperEditorHooks;
const paragraph = (id, value) => ({id, type: "paragraph", content: [{type: "text", value}]});
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function mount() {
  const main = document.createElement("main");
  main.innerHTML = '<button data-editing="true">View</button><div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas"><bp-paper-canvas></bp-paper-canvas></div>';
  const wrapper = main.querySelector("[phx-hook]");
  wrapper.dataset.canvasBlocks = JSON.stringify([paragraph("original", "Original")]);
  wrapper.dataset.canvasDataset = "production";
  document.body.appendChild(main);
  const canvas = wrapper.querySelector("bp-paper-canvas");
  const handlers = new Map();
  const requests = [];
  const hook = {...hooks.BarkparkPaperCanvas, el: wrapper,
    handleEvent: (name, fn) => handlers.set(name, fn),
    pushEvent: (name, payload) => {
      if (name !== "paper-ops") return Promise.resolve({});
      return new Promise((resolve, reject) => requests.push({payload, resolve, reject}));
    },
  };
  hook.mounted();
  let toggles = 0;
  const toggle = {...hooks.BarkparkPaperEditToggle, el: main.querySelector("button"),
    pushEvent: () => { toggles++; return Promise.resolve({}); }};
  toggle.mounted();
  await new Promise(resolve => setTimeout(resolve, 350));
  assert.equal(requests.length, 0);
  return {canvas, requests,
    click: () => toggle.el.dispatchEvent(new window.MouseEvent("click", {bubbles:true, cancelable:true})),
    toggles: () => toggles,
    echo: blocks => handlers.get("bp:canvas-update")({runs:[{run_id:"probe-run-0", blocks}]}),
    close: () => { toggle.destroyed(); hook.destroyed(); main.remove(); },
  };
}
function insert(canvas, value) {
  canvas._editor.commands.insertContentAt(canvas._editor.state.doc.content.size, {
    type: "paragraph", attrs: {bpId: null, bpType: "paragraph"}, content: [{type:"text",text:value}],
  });
}
function append(canvas, text) {
  canvas._editor.view.dispatch(canvas._editor.state.tr.insertText(text,
    canvas._editor.state.doc.content.size - 1));
}
function textOf(canvas) { return canvas._editor.state.doc.textContent; }
function inserted(batch) { return batch.payload.ops.find(op => op.op === "insert-after" || op.op === "append-block").block; }
function resolveSaved(request, saved) {
  request.resolve({saved, request_id: request.payload.request_id});
}

try {
  const test = await mount();
  insert(test.canvas, "Alpha");
  test.canvas.flushPendingChanges();
  assert.equal(test.requests.length, 1);
  const first = test.requests[0];
  const block = inserted(first);
  assert.ok(block.id, "a newly inserted node has a stable wire identity");
  append(test.canvas, " beta");
  test.canvas.flushPendingChanges();
  assert.equal(test.requests.length, 1, "newer local input waits behind the in-flight save");
  test.echo([paragraph("original", "Original"), block]);
  assert.match(textOf(test.canvas), /Alpha beta/, "a delayed own echo cannot overwrite newer input");
  resolveSaved(first, true);
  await tick();
  assert.equal(test.requests.length, 2, "acknowledgement sends the newer incremental edit");
  const second = test.requests[1];
  assert.equal(second.payload.ops.filter(op => op.op === "insert-after" || op.op === "append-block").length, 0,
    "the next batch cannot reinsert the same paragraph");
  assert.ok(second.payload.ops.some(op => op.id === block.id && op.patch?.content?.[0]?.value === "Alpha beta"));
  test.echo([paragraph("original", "Original"), paragraph(block.id, "Alpha beta")]);
  resolveSaved(second, true);
  await tick();
  assert.match(textOf(test.canvas), /Alpha beta/);
  test.close();

  const retry = await mount();
  insert(retry.canvas, "Before source");
  retry.canvas.flushPendingChanges();
  const failed = retry.requests[0];
  const initialPayload = JSON.stringify(failed.payload);
  resolveSaved(failed, false);
  await tick();
  for (const value of ["First source change", "Second source change"]) {
    retry.canvas.toggleSourceMode();
    const source = retry.canvas.querySelector(".bp-canvas-source");
    source.value = "Original\n\n" + value;
    source.dispatchEvent(new Event("input", {bubbles:true}));
    retry.canvas.toggleSourceMode();
  }
  assert.equal(retry.requests.length, 1, "source edits remain local until the failed head is retried");
  retry.click();
  assert.equal(retry.requests.length, 2);
  assert.equal(JSON.stringify(retry.requests[1].payload), initialPayload, "retry preserves the original batch identity");
  const firstInsert = inserted(failed);
  retry.echo([paragraph("original", "Original"), firstInsert]);
  resolveSaved(retry.requests[1], true);
  await tick();
  assert.equal(retry.requests.length, 3, "only the final source state follows the retried head");
  const final = retry.requests[2];
  assert.equal(final.payload.ops.filter(op => op.op === "insert-after" || op.op === "append-block").length, 0);
  assert.ok(final.payload.ops.some(op => op.id === firstInsert.id && op.patch?.content?.[0]?.value === "Second source change"));
  assert.equal(retry.toggles(), 0, "View waits for the final source state");
  retry.echo([paragraph("original", "Original"), paragraph(firstInsert.id, "Second source change")]);
  resolveSaved(final, true);
  await tick();
  assert.equal(retry.toggles(), 1);
  assert.match(textOf(retry.canvas), /Second source change/);
  retry.close();
  const standalone = document.createElement("bp-paper-canvas");
  standalone.blocks = [paragraph("standalone", "Legacy host")];
  document.body.appendChild(standalone);
  await new Promise(resolve => setTimeout(resolve, 350));
  const standaloneBatches = [];
  standalone.addEventListener("bp-canvas-ops", event => standaloneBatches.push(event.detail.ops));
  append(standalone, " first");
  standalone.flushPendingChanges();
  append(standalone, " second");
  standalone.flushPendingChanges();
  assert.equal(standaloneBatches.length, 2,
    "standalone hosts that have not opted into acknowledgements continue emitting edits");
  standalone.remove();
  console.log("mounted canvas acknowledgement, stable-id, and source retry regressions passed");
} finally {
  window.close();
}
