import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("../index.js");

const source = {
  id: "card-1",
  type: "card",
  tone: "warn",
  qa: { preserve: "card metadata" },
  slots: {
    title: [{
      id: "title-1",
      type: "heading",
      level: 3,
      text: "Original title",
      qa: { preserve: "title metadata" },
    }],
    body: [{
      id: "body-1",
      type: "paragraph",
      qa: { preserve: "body metadata" },
      content: [{
        type: "strong",
        children: [{ type: "text", value: "Body stays intact" }],
      }],
    }],
  },
};

function mount(level = 3) {
  const host = document.createElement("bp-paper-canvas");
  const original = structuredClone(source);
  original.slots.title[0].level = level;
  host.blocks = [original];
  const batches = [];
  host.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
  document.body.appendChild(host);
  const title = host.querySelector('[data-test-id="paper-card-title"]');
  assert.ok(title);
  return { host, title, batches, original };
}

function input(title, value) {
  title.textContent = value;
  title.dispatchEvent(new Event("input", { bubbles: true }));
}

function key(title, key, options = {}) {
  const event = new KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...options,
  });
  title.dispatchEvent(event);
  return event;
}

try {
  const fast = mount();
  try {
    assert.equal(
      fast.title.parentElement.tagName,
      "H3",
      "the semantic title host keeps the authored heading level",
    );
    assert.equal(fast.title.contentEditable, "plaintext-only");
    assert.equal(fast.title.getAttribute("role"), "textbox");
    assert.equal(fast.title.tabIndex, 0);
    assert.equal(
      fast.title.parentElement.contentEditable,
      "false",
      "the title is a nested editing host rather than part of the outer ProseMirror host",
    );

    const bodySelection = fast.host._editor.state.selection.from;
    fast.title.focus();
    const range = document.createRange();
    range.selectNodeContents(fast.title);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    document.dispatchEvent(new Event("selectionchange"));
    assert.equal(document.activeElement, fast.title, "a title selection remains in the title host");
    assert.equal(
      fast.host._editor.state.selection.from,
      bodySelection,
      "title selection does not move the body ProseMirror selection",
    );

    input(fast.title, "Fast settled title");
    fast.title.blur();
    assert.equal(fast.title.textContent, "Fast settled title", "blur cannot repaint the old title");
    assert.equal(fast.host._editor.state.doc.firstChild.attrs.title, "Fast settled title");
    assert.equal(fast.host.flushPendingChanges(), true);
    assert.equal(fast.batches.length, 1);

    const patch = fast.batches[0][0];
    assert.equal(patch.op, "patch-block");
    assert.equal(patch.id, "card-1");
    assert.deepEqual(patch.patch.slots.title, [{
      id: "title-1",
      type: "heading",
      level: 3,
      text: "Fast settled title",
      qa: { preserve: "title metadata" },
    }]);
    assert.deepEqual(patch.patch.slots.body, source.slots.body);
    assert.deepEqual(
      { ...source, ...patch.patch },
      { ...source, slots: { ...source.slots, title: patch.patch.slots.title } },
      "title input preserves Card identity, metadata, heading semantics, and rich body source",
    );
    assert.equal(fast.host.flushPendingChanges(), false);
  } finally {
    fast.host.remove();
  }

  const composing = mount();
  try {
    composing.title.focus();
    composing.title.dispatchEvent(new Event("compositionstart", { bubbles: true }));
    input(composing.title, "日本語");
    assert.equal(
      composing.host._editor.state.doc.firstChild.attrs.title,
      "Original title",
      "an unfinished composition is not committed",
    );
    composing.title.dispatchEvent(new Event("compositionend", { bubbles: true }));
    assert.equal(composing.host._editor.state.doc.firstChild.attrs.title, "日本語");
    composing.host.flushPendingChanges();
    assert.equal(composing.batches[0][0].patch.slots.title[0].text, "日本語");
  } finally {
    composing.host.remove();
  }

  for (const [level, expectedTag] of [
    [1, "H1"],
    ["2", "H2"],
    ["3", "H3"],
    [4, "H2"],
    [null, "H2"],
    ["junk", "H2"],
  ]) {
    const clamped = mount(level);
    try {
      assert.equal(
        clamped.title.parentElement.tagName,
        expectedTag,
        `authored level ${String(level)} follows the reader's 1..3 clamp`,
      );
      input(clamped.title, "Clamped title edit");
      clamped.host.flushPendingChanges();
      assert.equal(
        clamped.batches[0][0].patch.slots.title[0].level,
        level,
        "render-time level normalization never rewrites authoritative source",
      );
    } finally {
      clamped.host.remove();
    }
  }

  const keyboard = mount();
  try {
    keyboard.title.focus();
    input(keyboard.title, "Undoable title");
    const undo = key(keyboard.title, "z", { metaKey: true });
    assert.equal(undo.defaultPrevented, true);
    assert.equal(keyboard.title.textContent, "Original title");
    key(keyboard.title, "z", { metaKey: true, shiftKey: true });
    assert.equal(keyboard.title.textContent, "Undoable title");

    const enter = key(keyboard.title, "Enter");
    assert.equal(enter.defaultPrevented, true);
    assert.notEqual(document.activeElement, keyboard.title);
    assert.equal(keyboard.host._editor.state.doc.childCount, 1);
    assert.equal(keyboard.host._editor.state.doc.firstChild.type.name, "bpCard");
  } finally {
    keyboard.host.remove();
  }

  console.log("mounted Card title boundary, immediate settlement, composition, Enter, undo and source preservation passed");
} finally {
  window.close();
}
