// Mounted regression: Enter in the locked title moves the caret to the body.
//
// Found dogfooding a new paper (task-0f6a172b8bc795b2): type a title, press Enter,
// keep writing — the body text landed in the title, because Enter in the locked
// title was a silent no-op (charter D6) and the fresh body paragraph is a hidden
// resting scaffold. Owner ruling 2026-10-03 #54 amends D6: Enter in the locked
// title still never splits, creates a block or emits an op; it moves the caret to
// the first body block. The empty title shows a "Title" placeholder.
//
//   1. IN-RUN: title + empty body paragraph (the fresh-paper shape). Enter at the
//      end of the title selects the body paragraph; typing goes into the body; the
//      document and the ops stream are unchanged by the Enter itself.
//   2. MID-TITLE: Enter with the caret inside the title text does not split it.
//   3. NEXT RUN: the title alone in its run (a locked tail follows). Enter focuses
//      the next canvas run's first block.
//   4. AFFORDANCE: no following canvas. Enter focuses the first ghost-slot button,
//      else the "+ Add block" control.
//   5. PLACEHOLDER: an empty locked title carries data-placeholder="Title" even
//      when the caret is elsewhere.

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
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const title = (text) => ({
  id: "tpl-title",
  type: "heading",
  level: 1,
  role: "title",
  locked: true,
  text,
});
const emptyBody = { id: "p-body", type: "paragraph", content: [] };

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

async function mountCanvas(root, blocks, attrs = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  for (const [k, v] of Object.entries(attrs)) canvas.setAttribute(k, v);
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  root.appendChild(canvas);
  return canvas;
}

function editorRoot() {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  document.body.appendChild(root);
  return root;
}

function pressEnter(canvas) {
  const event = new window.KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  });
  canvas.querySelector(".ProseMirror").dispatchEvent(event);
  return event;
}

function caretAt(editor, pos) {
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, pos)));
  editor.view.focus();
}

function topIndexOfSelection(editor) {
  const $from = editor.state.selection.$from;
  return $from.depth >= 1 ? $from.index(0) : -1;
}

try {
  // ── 1. IN-RUN (the fresh-paper shape) ─────────────────────────────────────
  {
    const root = editorRoot();
    const canvas = await mountCanvas(root, [title("Dogfood paper title"), emptyBody]);
    await tick(350);
    const editor = canvas._editor;
    let ops = [];
    canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...e.detail.ops));
    const before = editor.getJSON();
    caretAt(editor, editor.state.doc.child(0).nodeSize - 1);
    ops = [];
    const event = pressEnter(canvas);

    await check("Enter at the end of the locked title moves the caret to the first body block", () => {
      assert.equal(event.defaultPrevented, true, "the Enter is consumed");
      assert.deepEqual(editor.getJSON(), before, "no split and no new block");
      assert.equal(topIndexOfSelection(editor), 1, "the caret sits in the body paragraph");
    });

    await check("the body paragraph is no longer a hidden resting scaffold", () => {
      const body = canvas.querySelector(".ProseMirror > p");
      assert.ok(body, "the body paragraph renders");
      assert.ok(!body.classList.contains("bp-resting-scaffold"), "the caret's paragraph is visible");
    });

    editor.commands.insertContent("First paragraph of the body.");
    await check("typing after Enter goes into the body, not the title", () => {
      assert.equal(editor.state.doc.child(0).textContent, "Dogfood paper title");
      assert.equal(editor.state.doc.child(1).textContent, "First paragraph of the body.");
    });
    canvas.flushPendingChanges();
    await check("the Enter itself emitted no op; only the typed text is saved", () => {
      assert.ok(!ops.some((op) => op.op === "insert-after" || op.op === "append-block"), JSON.stringify(ops));
      assert.ok(!ops.some((op) => op.id === "tpl-title"), "the title is untouched");
    });
    root.remove();
  }

  // ── 2. MID-TITLE ──────────────────────────────────────────────────────────
  {
    const root = editorRoot();
    const canvas = await mountCanvas(root, [title("Split me"), emptyBody]);
    await tick(350);
    const editor = canvas._editor;
    const before = editor.getJSON();
    caretAt(editor, 3);
    pressEnter(canvas);
    await check("Enter inside the title text does not split it", () => {
      assert.deepEqual(editor.getJSON(), before);
      assert.equal(topIndexOfSelection(editor), 1);
    });
    root.remove();
  }

  // ── 3. NEXT RUN ───────────────────────────────────────────────────────────
  {
    const root = editorRoot();
    const first = await mountCanvas(root, [title("Alone")], { "data-locked-tail": "true" });
    const boundary = document.createElement("div");
    boundary.textContent = "featured image boundary";
    root.appendChild(boundary);
    const second = await mountCanvas(root, [
      { id: "p-next", type: "paragraph", content: [{ type: "text", value: "Next run" }] },
    ]);
    await tick(350);
    caretAt(first._editor, first._editor.state.doc.child(0).nodeSize - 1);
    pressEnter(first);
    await tick(0);
    await check("with no body block in its run, Enter focuses the next run's first block", () => {
      assert.equal(first._editor.state.doc.childCount, 1, "the title run did not grow");
      assert.equal(second._editor.isFocused, true, "the next run has focus");
      assert.equal(topIndexOfSelection(second._editor), 0);
    });
    root.remove();
  }

  // ── 4. AFFORDANCE ─────────────────────────────────────────────────────────
  {
    const root = editorRoot();
    const canvas = await mountCanvas(root, [title("Only title")], { "data-locked-tail": "true" });
    const ghosts = document.createElement("div");
    ghosts.setAttribute("data-test-id", "paper-ghost-slots");
    const ghost = document.createElement("button");
    ghost.type = "button";
    ghost.setAttribute("data-test-id", "paper-ghost-ingress");
    ghosts.appendChild(ghost);
    root.appendChild(ghosts);
    await tick(350);
    caretAt(canvas._editor, canvas._editor.state.doc.child(0).nodeSize - 1);
    pressEnter(canvas);
    await check("with no following block, Enter focuses the first ghost slot", () => {
      assert.equal(document.activeElement, ghost);
    });
    ghosts.remove();
    const form = document.createElement("form");
    form.setAttribute("data-test-id", "paper-add-block");
    const select = document.createElement("select");
    form.appendChild(select);
    root.appendChild(form);
    caretAt(canvas._editor, canvas._editor.state.doc.child(0).nodeSize - 1);
    pressEnter(canvas);
    await check("without ghost slots, Enter focuses the + Add block control", () => {
      assert.equal(document.activeElement, select);
    });
    root.remove();
  }

  // ── 5. PLACEHOLDER ────────────────────────────────────────────────────────
  {
    const root = editorRoot();
    const canvas = await mountCanvas(root, [
      title(""),
      { id: "p-body", type: "paragraph", content: [{ type: "text", value: "Body" }] },
    ]);
    await tick(350);
    const editor = canvas._editor;
    caretAt(editor, editor.state.doc.child(0).nodeSize + 2);
    await tick(0);
    await check("an empty locked title shows a 'Title' placeholder while the caret is elsewhere", () => {
      const h1 = canvas.querySelector(".ProseMirror > h1");
      assert.ok(h1, "the title heading renders");
      assert.equal(h1.getAttribute("data-placeholder"), "Title");
      assert.ok(h1.classList.contains("is-empty"), "it carries the placeholder class the CSS paints");
    });
    caretAt(editor, 1);
    await tick(0);
    await check("the placeholder still reads 'Title' with the caret in the title", () => {
      const h1 = canvas.querySelector(".ProseMirror > h1");
      assert.equal(h1.getAttribute("data-placeholder"), "Title");
    });
    root.remove();
  }
} finally {
  dom.window.close();
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\ntitle_enter_caret: Enter in the locked title moves to the body; the empty title reads 'Title'");
process.exit(0);
