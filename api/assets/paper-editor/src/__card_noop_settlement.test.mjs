import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperEditor } = await import("./index.js");
assert.ok(BpPaperEditor);

let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
window.document.body.innerHTML = `
  <main data-paper-doc-key="production:paper:card-noop" data-paper-rev="7">
    <div class="bp-paper-editor"></div>
  </main>
`;
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: window.customElements,
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const Hooks = window.BarkparkPaperEditorHooks;
const replies = [];
const calls = [];
const source = (id) => ({
  id,
  type: "card",
  slots: { body: [{ type: "paragraph", content: [{ type: "text", value: "Alpha" }] }] },
});
const mount = (id) => {
  const el = window.document.createElement("div");
  el.id = `paper-ed-${id}`;
  el.setAttribute("phx-hook", "BarkparkPaperEditor");
  const editor = window.document.createElement("bp-paper-editor");
  editor.setAttribute("data-editor-mode", "card-body");
  editor.block = source(id);
  el.appendChild(editor);
  window.document.querySelector(".bp-paper-editor").appendChild(el);
  const handlers = new Map();
  const hook = {
    ...Hooks.BarkparkPaperEditor,
    el,
    handleEvent(name, handler) {
      handlers.set(name, handler);
    },
    pushEvent(name, payload) {
      calls.push({ source: id, name, payload });
      return new Promise((resolve) => replies.push({ resolve, payload }));
    },
  };
  hook.mounted();
  return { el, hook, editor, handlers };
};
const cardA = mount("card-a");
const cardB = mount("card-b");
const mounts = [cardA, cardB];
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const guarded = () => {
  const event = new window.Event("beforeunload", { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
};
const insert = (mount, text = "Beta") => {
  const tiptap = mount.editor._editor;
  tiptap.view.dispatch(tiptap.state.tr.insertText(text, 1, 6));
};
const revert = (mount) => mount.editor._editor.commands.undo();

try {
  const tiptapA = cardA.editor._editor;
  tiptapA.commands.setTextSelection({ from: 1, to: 6 });
  tiptapA.commands.toggleBold();
  tiptapA.commands.toggleBold();
  assert.equal(guarded(), true, "format-only Card updates mark the wrapper dirty");
  assert.equal(cardA.editor.flushPendingChanges(), false);
  assert.equal(guarded(), false, "bold on then off settles through its authoritative token");
  assert.equal(calls.length, 0, "semantic formatting no-op performs zero storage writes");

  insert(cardA);
  cardA.editor._editor.view.dom.dispatchEvent(
    new window.Event("input", { bubbles: true, composed: true }),
  );
  revert(cardA);
  assert.equal(cardA.editor.flushPendingChanges(), false);
  assert.equal(guarded(), false, "native input plus revert is dirtied only by TipTap updates");

  insert(cardA, "Gamma");
  revert(cardA);
  assert.equal(cardA.editor.flushPendingChanges(), false);
  assert.equal(guarded(), false, "a repeated clean no-op cycle gets a fresh coordinator token");

  insert(cardB);
  assert.equal(cardB.editor.flushPendingChanges(), true);
  const cardBWrite = calls.at(-1);

  insert(cardA);
  cardA.editor._editor.commands.setContent({
    type: "doc",
    content: [{ type: "paragraph", content: [{ type: "text", text: "Alpha" }] }],
  }, true);
  const external = source("card-a");
  external.slots.body[0].content[0].value = "External";
  cardA.editor.flushPendingChanges();
  cardA.handlers.get("bp:block-update")({
    block_id: "card-a",
    block: external,
    rev: 9,
  });
  assert.equal(cardA.editor._editor.getText(), "Alpha", "authority remains queued behind Card B's save");
  assert.equal(calls.length, 1, "Card A's semantic no-op performs zero storage writes");
  assert.equal(guarded(), true, "settling Card A cannot clear Card B's in-flight work");
  replies.shift().resolve({ saved: true, request_id: cardBWrite.payload.request_id, rev: 8 });
  await tick();
  await tick();
  assert.equal(cardA.hook._bpPaperExitCoordinator._flushQuarantinedIfClean(), false,
    "the normal acknowledgement lifecycle already consumes queued authority");
  assert.equal(cardA.editor._sourceBlock.slots.body[0].content[0].value, "External",
    "queued authority reaches the Card WC source setter");
  assert.equal(cardA.editor._cardBodyDraftJSON, null,
    "settled no-op does not retain a local draft over queued authority");
  assert.deepEqual(cardA.editor._cardBodyAwaitingContents, [],
    "settled no-op has no awaiting body write");
  assert.equal(cardA.editor._editor.getText(), "External", "clean no-op releases queued authority after Card B saves");
  assert.equal(guarded(), false);
  const acknowledgedB = source("card-b");
  acknowledgedB.slots.body[0].content = cardBWrite.payload.content;
  cardB.editor.block = acknowledgedB;
  cardA.editor.block = source("card-a");

  let staleToken = null;
  window.document.querySelector("main").addEventListener("bp-local-change", (event) => {
    if (event.target === cardA.editor) staleToken ||= event.detail.token;
  });
  insert(cardA);
  insert(cardA, "Delta");
  cardA.editor.dispatchEvent(new window.CustomEvent("bp-noop", {
    detail: { token: staleToken },
    bubbles: true,
    composed: true,
  }));
  assert.equal(guarded(), true, "a stale token cannot clear newer Card input");
  cardA.editor._editor.commands.setContent({
    type: "doc",
    content: [{ type: "paragraph", content: [{ type: "text", text: "Alpha" }] }],
  }, true);
  cardA.editor.flushPendingChanges();
  assert.equal(guarded(), false, "the newest token can settle the reverted draft");

  insert(cardA);
  assert.equal(cardA.editor.flushPendingChanges(), true);
  const retainedRequestId = calls.at(-1).payload.request_id;
  const writeCount = calls.length;
  cardA.editor.dispatchEvent(new window.CustomEvent("bp-noop", {
    detail: { token: staleToken },
    bubbles: true,
    composed: true,
  }));
  assert.equal(guarded(), true, "an in-flight Card mutation cannot be settled as a no-op");
  replies.shift().resolve({ saved: false, request_id: retainedRequestId });
  await tick();
  cardA.el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
    detail: { waitUntil() {} },
  }));
  assert.equal(calls.length, writeCount + 1, "flush retries the retained mutation");
  assert.equal(calls.at(-1).payload.request_id, retainedRequestId, "retry retains mutation identity");
} finally {
  mounts.forEach(({ hook, editor }) => {
    hook.destroyed();
    editor.remove();
  });
  window.close();
}

console.log("Card mounted no-op settlement contract passed");
