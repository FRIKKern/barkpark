// Mounted regression: the canvas authors six heading levels.
//
// Owner ruling 2026-10-03 #63 (Barkdown FRIKKern/barkdown#22, reversing the earlier
// three-level decision): the canvas offers H1–H6 in the slash menu and the turn-into
// palette and block menu, `#### ` / `##### ` / `###### ` make H4–H6, and the
// turn-into chords Mod-Alt-1..6 set H1–H6 (Mod-Shift-4/5/6 stay checklist / bullets /
// numbers). A stored level 4–6 is shown at its own level.

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
const { TURN_INTO, turnTopLevelInto } = await import("./block-handle.js");
const { buildCommandRegistry } = await import("./command-palette.js");
const { runToTiptap, runToOps } = await import("./run-convert.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

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

async function mount(blocks) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return canvas;
}

const para = (id, text) => ({ id, type: "paragraph", content: text ? [{ type: "text", value: text }] : [] });

function first(editor) {
  return editor.state.doc.child(0);
}

// Type `text` at the caret the way the browser does: each character goes through the
// view's handleTextInput props (where TipTap's input rules live) before it is inserted.
function typeText(editor, text) {
  const { view } = editor;
  for (const ch of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, ch, () => view.state.tr.insertText(ch, from, to)));
    if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to));
  }
}

function chord(canvas, digit, { alt = true, shift = false } = {}) {
  const event = new window.KeyboardEvent("keydown", {
    key: String(digit),
    code: `Digit${digit}`,
    keyCode: 48 + digit,
    ctrlKey: true,
    altKey: alt,
    shiftKey: shift,
    bubbles: true,
    cancelable: true,
  });
  canvas.querySelector(".ProseMirror").dispatchEvent(event);
}

try {
  // ── markdown shortcuts ─────────────────────────────────────────────────────
  for (const level of [4, 5, 6]) {
    const canvas = await mount([para("p-1", "")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 1)));
    editor.view.focus();
    typeText(editor, `${"#".repeat(level)} Deep`);
    await check(`"${"#".repeat(level)} " makes a level-${level} heading`, () => {
      const node = first(editor);
      assert.equal(node.type.name, "heading");
      assert.equal(node.attrs.level, level);
      assert.equal(node.textContent, "Deep");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── turn-into chords ───────────────────────────────────────────────────────
  for (const level of [1, 4, 5, 6]) {
    const canvas = await mount([para("p-1", "Make me a heading")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 3)));
    editor.view.focus();
    chord(canvas, level);
    await check(`Mod-Alt-${level} turns the block into a level-${level} heading`, () => {
      const node = first(editor);
      assert.equal(node.type.name, "heading");
      assert.equal(node.attrs.level, level);
    });
    canvas.closest(".bp-paper-editor").remove();
  }
  {
    const canvas = await mount([para("p-1", "Stay a list")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 3)));
    editor.view.focus();
    chord(canvas, 5, { alt: false, shift: true });
    await check("Mod-Shift-5 still makes a bulleted list", () => {
      assert.equal(first(editor).type.name, "bulletList");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── turn-into menu and palette ─────────────────────────────────────────────
  await check("the block menu's Turn into lists Heading 1–6", () => {
    const labels = TURN_INTO.map((t) => t.label);
    for (let level = 1; level <= 6; level++) assert.ok(labels.includes(`Heading ${level}`), `Heading ${level}`);
  });
  {
    const canvas = await mount([para("p-1", "Turn me")]);
    const editor = canvas._editor;
    turnTopLevelInto(editor, 0, "h5");
    await check("turnTopLevelInto h5 sets level 5", () => {
      assert.equal(first(editor).type.name, "heading");
      assert.equal(first(editor).attrs.level, 5);
    });
    const registry = buildCommandRegistry(editor);
    await check("the palette offers Turn into Heading 1–6", () => {
      for (let level = 1; level <= 6; level++) {
        assert.ok(registry.some((c) => c.id === `turn-h${level}`), `turn-h${level}`);
      }
    });
    const turnH6 = registry.find((c) => c.id === "turn-h6");
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 2)));
    turnH6?.run(editor);
    await check("Turn into Heading 6 from the palette sets level 6", () => {
      assert.equal(first(editor).attrs.level, 6);
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── slash menu ─────────────────────────────────────────────────────────────
  {
    const canvas = await mount([para("p-1", "Intro")]);
    const editor = canvas._editor;
    editor.chain().focus().setTextSelection(first(editor).nodeSize - 1).splitBlock().insertContent("/head").run();
    const items = canvas._slash?.isOpen() ? canvas._slash._items : [];
    await check("the slash menu offers Heading 1–6", () => {
      for (let level = 1; level <= 6; level++) {
        assert.ok(items.some((it) => it.type === "heading" && it.level === level && it.label === `Heading ${level}`), `Heading ${level}`);
      }
    });
    const h4 = items.find((it) => it.type === "heading" && it.level === 4);
    if (h4) canvas._chooseSlash(h4);
    await check("choosing Heading 4 inserts a level-4 heading", () => {
      const node = editor.state.doc.child(1);
      assert.equal(node.type.name, "heading");
      assert.equal(node.attrs.level, 4);
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── stored levels ──────────────────────────────────────────────────────────
  await check("a stored level-4/5/6 heading is shown at its own level and round-trips at zero ops", () => {
    const blocks = [4, 5, 6].map((level) => ({ id: `h${level}`, type: "heading", level, text: `Level ${level}` }));
    const doc = runToTiptap(blocks);
    assert.deepEqual(doc.content.map((n) => n.attrs.level), [4, 5, 6]);
    assert.deepEqual(runToOps(blocks, doc), []);
  });
} finally {
  dom.window.close();
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nsix_heading_levels: the canvas authors H1–H6");
process.exit(0);
