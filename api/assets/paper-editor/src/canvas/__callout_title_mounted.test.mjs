import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true, url: "http://localhost/",
});
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element",
  "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
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

function mount(attrs = {}) {
  const host = document.createElement("bp-paper-canvas");
  const original = { id: "callout", type: "callout", title: "Read this first",
    tone: "warning", content: [{ type: "strong", children: [{ type: "text", value: "Body stays intact" }] }],
    qa: { preserve: "metadata" }, ...attrs };
  host.blocks = [original];
  const ops = [];
  host.addEventListener("bp-canvas-ops", event => ops.push(...event.detail.ops));
  document.body.appendChild(host);
  return { host, original, ops, title: host.querySelector('[aria-label="Callout title"]') };
}
function typeTitle(title, value) {
  title.textContent = value;
  title.dispatchEvent(new Event("input", { bubbles: true }));
}
function key(title, key, opts = {}) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...opts });
  title.dispatchEvent(event);
  return event;
}

try {
  for (const attrs of [{}, { collapsible: true }, { collapsible: true, collapsed: true }]) {
    const { host, title, ops, original } = mount(attrs);
    try {
      assert.ok(title, "the visible title is an on-Paper textbox");
      assert.equal(title.contentEditable, "plaintext-only");
      assert.equal(title.tagName, attrs.collapsible ? "SPAN" : "STRONG");
      assert.equal(title.parentElement.contentEditable, "false",
        "the title is its own browser editing host, never the surrounding PM canvas");
      title.focus();
      const openBefore = host.querySelector("details")?.open;
      const click = new Event("click", { bubbles: true, cancelable: true });
      title.dispatchEvent(click);
      assert.equal(click.defaultPrevented, true, "editing text cannot toggle the summary");
      typeTitle(title, "Edited in place");
      assert.equal(host._editor.state.doc.firstChild.attrs.title, "Edited in place");
      assert.equal(host.querySelector("details")?.open, openBefore);
      assert.equal(host._editor.state.doc.textContent, "Body stays intact");
      assert.equal(key(title, "z", { metaKey: true }).defaultPrevented, true);
      assert.equal(title.textContent, "Read this first");
      key(title, "z", { metaKey: true, shiftKey: true });
      assert.equal(title.textContent, "Edited in place");
      host.flushPendingChanges();
      assert.equal(ops.length, 1);
      assert.deepEqual(ops[0], { op: "patch-block", id: "callout", patch: {
        content: original.content, tone: "warning", title: "Edited in place",
        collapsible: !!attrs.collapsible, collapsed: !!attrs.collapsed,
      } });
      assert.deepEqual({ ...original, ...ops[0].patch }, { ...original, title: "Edited in place",
        collapsible: !!attrs.collapsible, collapsed: !!attrs.collapsed },
        "body, marks, tone, fold and custom metadata remain intact");
      assert.equal(key(title, "Enter").defaultPrevented, true);
      assert.equal(host._editor.state.doc.childCount, 1);
      if (attrs.collapsible) {
        const summary = host.querySelector("summary");
        summary.focus();
        assert.equal(key(summary, "Enter").defaultPrevented, false,
          "ProseMirror must leave native summary keyboard activation alone");
      }
    } finally { host.remove(); }
  }

  const empty = mount({ title: undefined, collapsible: true });
  try {
    assert.equal(empty.title.textContent, "Warning");
    empty.title.focus();
    empty.title.blur();
    empty.host.flushPendingChanges();
    assert.deepEqual(empty.ops, [], "focus/blur/flush never authors the fallback tone label");
    empty.title.focus();
    typeTitle(empty.title, "Custom heading");
    typeTitle(empty.title, "");
    assert.equal(empty.title.textContent, "", "clearing a focused title does not reinsert its label");
    empty.title.blur();
    assert.equal(empty.title.textContent, "Warning");
    empty.host.flushPendingChanges();
    assert.deepEqual(empty.ops, [], "adding then clearing an absent title is a no-op");
  } finally { empty.host.remove(); }

  const composing = mount();
  try {
    composing.title.focus();
    composing.title.dispatchEvent(new Event("compositionstart"));
    typeTitle(composing.title, "日本語");
    assert.equal(composing.host._editor.state.doc.firstChild.attrs.title, "Read this first");
    composing.title.dispatchEvent(new Event("compositionend"));
    composing.host.flushPendingChanges();
    assert.equal(composing.ops.length, 1);
    assert.equal(composing.ops[0].patch.title, "日本語");
    assert.deepEqual(composing.ops[0].patch.content, composing.original.content);
  } finally { composing.host.remove(); }

  console.log("mounted callout title: in-place input, fold isolation, immediate flush, undo/redo, absence and composition passed");
} finally { window.close(); }
