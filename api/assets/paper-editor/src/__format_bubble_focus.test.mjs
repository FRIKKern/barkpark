// __format_bubble_focus.test.mjs — the format bubble's link input HOLDS focus
// (task format-bubble-link-input-may-be-unusable).
//
// The defect, proven live in real Chrome against the committed bundle before the
// fix: clicking the bubble's link button opened the URL row, the deferred
// input.focus() blurred ProseMirror, TipTap's onBlur drove FormatBubble.update(),
// update() read view.hasFocus() === false and _hide() ran — one frame after the
// row opened, the whole bubble was display:none and focus fell to <body>. The
// link affordance was unusable end to end.
//
// This file is the MOUNTED, UNPINNED proof of the repair. It mounts the real
// <bp-paper-canvas> in jsdom (the __locked_mounted.test.mjs pattern) and drives
// the REAL focus path: a real mousedown on the real link button, the real rAF
// focus hand-off, the real blur cascade into update(). Nothing stubs or pins
// view.hasFocus — that is the whole point (the wave-11 harness had to pin it to
// keep the bubble alive at all, which is why the defect stayed invisible).
//
// It also pins the hide paths the fix must NOT have broken: focus landing
// outside both the editor and the bubble still hides it (after the one-tick
// settle), and Escape in the input returns focus to the editor with the bubble
// alive.
//
// Run: node src/__format_bubble_focus.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});

const { window } = dom;
for (const name of [
  "customElements",
  "CustomEvent",
  "document",
  "DOMParser",
  "Element",
  "Event",
  "EventTarget",
  "HTMLElement",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "Node",
  "NodeFilter",
  "Selection",
  "Text",
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
window.Element.prototype.scrollIntoView ||= function () {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./canvas/index.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
const settle = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));
const mousedown = (el) =>
  el.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
const keydown = (el, key) =>
  el.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [
  {
    id: "b1",
    type: "paragraph",
    content: [{ type: "text", value: "The quick brown fox jumps over the lazy dog" }],
  },
];
document.body.appendChild(canvas);
await settle(400); // let TipTap's mount-time normalization finish

try {
  const editor = canvas._editor;
  assert.ok(editor, "mount creates the real TipTap editor");
  const proseMirror = canvas.querySelector(".ProseMirror");
  assert.ok(proseMirror, "mount creates the real ProseMirror DOM");

  // A real focused, non-empty text selection — the bubble's show condition.
  editor.chain().focus().setTextSelection({ from: 5, to: 10 }).run();
  await settle();

  const bubble = document.querySelector(".bp-paper-format");
  check("selection floats the bubble (precondition, unpinned hasFocus)", () => {
    assert.ok(bubble, "bubble element exists");
    assert.ok(
      editor.view.hasFocus(),
      "the editor genuinely holds focus — nothing pinned view.hasFocus",
    );
    assert.equal(bubble.style.display, "flex", "bubble is visible");
  });

  // THE REGRESSION: press the link button and let the rAF focus hand-off run.
  // Old code: input.focus() → editor blur → update() → _hide(); the row died
  // one frame after opening. Fixed code: focus inside the bubble counts as
  // alive, so the row stays open and the input keeps focus.
  const linkBtn = document.querySelector(".bp-paper-format__btn--link");
  const linkRow = document.querySelector(".bp-paper-format__link-row");
  const linkInput = document.querySelector(".bp-paper-format__link-input");
  mousedown(linkBtn);
  await frame(); // the deferred input.focus()
  await settle(); // the one-tick blur settle in update()

  check("link button opens the URL row and the row SURVIVES the editor blur", () => {
    assert.equal(linkRow.style.display, "flex", "link row is open");
    assert.equal(bubble.style.display, "flex", "bubble did not self-hide");
  });
  check("the link input HOLDS focus (the editor is blurred, the bubble is alive)", () => {
    assert.equal(document.activeElement, linkInput, "activeElement is the URL input");
    assert.equal(editor.view.hasFocus(), false, "the editor really is blurred — unpinned");
  });

  // Typing a URL and pressing Enter applies the mark and returns focus.
  linkInput.value = "https://example.com/mounted-run";
  keydown(linkInput, "Enter");
  await settle();
  check("Enter in the input applies the link over the held selection", () => {
    let href = null;
    editor.state.doc.nodesBetween(5, 10, (node) => {
      const mark = node.marks && node.marks.find((m) => m.type.name === "link");
      if (mark) href = mark.attrs.href;
    });
    assert.equal(href, "https://example.com/mounted-run", "link mark landed on the selection");
    assert.ok(editor.view.hasFocus(), "focus returned to the editor");
    assert.equal(linkRow.style.display, "none", "the row closed after apply");
    assert.equal(bubble.style.display, "flex", "bubble still floats the selection");
  });

  // Escape path: open the row again, Escape returns focus with the bubble alive.
  // Also proves the double-fire fix (paper-editor-bundle-stale-and-escape-
  // stoppropagation): a window-level Escape listener — standing in for the
  // palette/menu layer's own capture-bubbling handler — must NOT observe this
  // keydown once stopPropagation() runs on the link input's Escape branch.
  mousedown(linkBtn);
  await frame();
  await settle();
  let windowEscapeCount = 0;
  const onWindowEscape = (e) => {
    if (e.key === "Escape") windowEscapeCount++;
  };
  // A CAPTURE-phase listener stands in for the palette/menu layer's own
  // handler: capture runs root -> target BEFORE this element's bubble-phase
  // stopPropagation() ever executes, so it must still fire — proving the fix
  // eliminates the bubble-phase double-fire without touching capture-phase
  // precedence (both directions of the task's browser measurement: E1 window
  // BUBBLE=0, E2 palette-open menu capture stays =1).
  let captureEscapeCount = 0;
  const onCaptureEscape = (e) => {
    if (e.key === "Escape") captureEscapeCount++;
  };
  window.addEventListener("keydown", onWindowEscape);
  window.addEventListener("keydown", onCaptureEscape, { capture: true });
  keydown(linkInput, "Escape");
  window.removeEventListener("keydown", onWindowEscape);
  window.removeEventListener("keydown", onCaptureEscape, { capture: true });
  await settle();
  check("Escape closes the row, refocuses the editor, bubble alive", () => {
    assert.equal(linkRow.style.display, "none", "row closed");
    assert.equal(bubble.style.display, "flex", "bubble alive");
    assert.ok(editor.view.hasFocus(), "editor refocused");
  });
  check("Escape in the link input does not double-fire a window bubble-phase Escape handler", () => {
    assert.equal(
      windowEscapeCount,
      0,
      "the link input's Escape branch must stopPropagation() so a window/menu-layer " +
        "bubble-phase Escape listener never also sees this keydown — without it, one " +
        "Escape press closes the link row AND fires whatever else is listening for " +
        "Escape on window.",
    );
  });
  check("...while a capture-phase Escape listener (palette precedence) still fires", () => {
    assert.equal(
      captureEscapeCount,
      1,
      "stopPropagation() on the bubble phase must not suppress a capture-phase " +
        "listener that already ran before the event reached the input — a palette " +
        "open at the same time must keep first say over Escape.",
    );
  });

  // The hide path the fix must not break: focus leaving BOTH the editor and the
  // bubble hides the bubble once focus settles (no stale float).
  mousedown(linkBtn);
  await frame();
  await settle();
  assert.equal(document.activeElement, linkInput, "precondition: focus in the input");
  const outside = document.createElement("button");
  document.body.appendChild(outside);
  outside.focus();
  await settle();
  check("focus landing outside editor AND bubble still hides it (settled hide)", () => {
    assert.equal(editor.view.hasFocus(), false, "editor unfocused");
    assert.equal(bubble.style.display, "none", "bubble hid — no stale float");
  });
  outside.remove();
} finally {
  canvas.remove();
  window.close();
}

if (failures > 0) {
  console.log(`\n${failures} format-bubble focus check(s) FAILED`);
  process.exit(1);
}
console.log(
  "\nmounted format-bubble focus proof passed — the link input holds focus and every hide path still hides",
);
