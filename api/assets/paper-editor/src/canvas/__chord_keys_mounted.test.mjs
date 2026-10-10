// Mounted regression (task-2a659a853f02c2cc): the canvas's list and code chords.
//
// Mod-Shift-8 makes a bulleted list, the Google Docs and Tiptap chord, beside Notion's
// Mod-Shift-5. Mod-Shift-6 and Tiptap's own Mod-Shift-7 make a numbered list. A code block
// moved off Mod-Shift-8 to Mod-Alt-c, Tiptap's chord for it. The slash menu and the
// command palette name each chord on its row, in the viewer's keyboard words.
// Run: node src/canvas/__chord_keys_mounted.test.mjs

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node",
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
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");
const { chordLabel, chordAria } = await import("../slash-menu.js");

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

async function mount(blocks, strings) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  if (strings) root.setAttribute("data-strings", JSON.stringify(strings));
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return canvas;
}

const para = (id, text) => ({ id, type: "paragraph", content: text ? [{ type: "text", value: text }] : [] });
const first = (editor) => editor.state.doc.child(0);

// A real keydown on the editor's DOM, so it travels ProseMirror's handleKeyDown and the
// extensions' keymaps in their real order.
function press(canvas, { key, code, keyCode, shift = false, alt = false }) {
  const event = new window.KeyboardEvent("keydown", {
    key, code, keyCode, ctrlKey: true, altKey: alt, shiftKey: shift, bubbles: true, cancelable: true,
  });
  canvas.querySelector(".ProseMirror").dispatchEvent(event);
  return event;
}
const digit = (canvas, d) => press(canvas, { key: String(d), code: `Digit${d}`, keyCode: 48 + d, shift: true });

async function inParagraph(text) {
  const canvas = await mount([para("p-1", text)]);
  const editor = canvas._editor;
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 3)));
  editor.view.focus();
  return { canvas, editor };
}
const unmount = (canvas) => canvas.closest(".bp-paper-editor").remove();

try {
  // ── the chords ─────────────────────────────────────────────────────────────
  for (const [d, type] of [[5, "bulletList"], [6, "orderedList"], [7, "orderedList"], [8, "bulletList"]]) {
    const { canvas, editor } = await inParagraph("Make me a list");
    const event = digit(canvas, d);
    await check(`Mod-Shift-${d} turns the paragraph into ${type}`, () => {
      assert.equal(first(editor).type.name, type);
      assert.equal(first(editor).textContent, "Make me a list");
      assert.equal(event.defaultPrevented, true, "the browser's own chord is held back");
    });
    unmount(canvas);
  }
  {
    const { canvas, editor } = await inParagraph("Make me code");
    // A Mac types "ç" for Alt+C, so the chord is read off event.code.
    const event = press(canvas, { key: "ç", code: "KeyC", keyCode: 67, alt: true });
    await check("Mod-Alt-c turns the paragraph into a code block that keeps its text", () => {
      assert.equal(editor.state.doc.childCount, 1);
      assert.equal(first(editor).type.name, "bpCode");
      assert.equal(first(editor).attrs.value, "Make me code");
      assert.equal(event.defaultPrevented, true);
    });
    unmount(canvas);
  }
  {
    const canvas = await mount([para("p-1", "")]);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 1)));
    editor.view.focus();
    press(canvas, { key: "ç", code: "KeyC", keyCode: 67, alt: true });
    await check("Mod-Alt-c on an empty paragraph makes an empty code block", () => {
      assert.equal(first(editor).type.name, "bpCode");
      assert.equal(first(editor).attrs.value, "");
    });
    unmount(canvas);
  }
  {
    const canvas = await mount([para("p-1", "")]);
    const editor = canvas._editor;
    editor.commands.setContent("<p>line one<br>line two</p>");
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, 3)));
    editor.view.focus();
    press(canvas, { key: "ç", code: "KeyC", keyCode: 67, alt: true });
    await check("a soft line break becomes a newline in the code", () => {
      assert.equal(first(editor).type.name, "bpCode");
      assert.equal(first(editor).attrs.value, "line one\nline two");
    });
    unmount(canvas);
  }
  {
    const { canvas, editor } = await inParagraph("Stay a list");
    digit(canvas, 8);
    await check("Mod-Shift-8 no longer makes a code block", () => {
      const types = [];
      editor.state.doc.forEach((node) => types.push(node.type.name));
      assert.ok(!types.includes("bpCode"), `top-level blocks: ${types.join(", ")}`);
    });
    unmount(canvas);
  }

  // ── the chord in the viewer's keyboard words ───────────────────────────────
  await check("a chord reads ⌘⇧8 on a Mac and Ctrl+Shift+8 elsewhere", () => {
    assert.equal(chordLabel("Mod-Shift-8", true), "⌘⇧8");
    assert.equal(chordLabel("Mod-Alt-c", true), "⌘⌥C");
    assert.equal(chordLabel("Mod-Shift-8", false), "Ctrl+Shift+8");
    assert.equal(chordAria("Mod-Alt-c", false), "Control+Alt+C");
    assert.equal(chordAria("Mod-Shift-8", true), "Meta+Shift+8");
  });

  const NB = { Shift: "Skift", Ctrl: "Ctrl", Alt: "Alt", "monospace block": "fast bredde-blokk" };
  for (const [lang, strings, shift, mono] of [["en", null, "Shift", "monospace block"], ["nb", NB, "Skift", "fast bredde-blokk"]]) {
    const canvas = await mount([para("p-1", "Alpha")], strings);
    canvas._openSlash("");
    const rows = [...canvas._slash._el.querySelectorAll(".bp-slash-item")];
    const row = (type) => rows.find((r) => r.dataset.type === type);
    await check(`the ${lang} slash menu names the code and list chords`, () => {
      assert.equal(row("code").querySelector(".bp-slash-desc").textContent, `${mono} · Ctrl+Alt+C`);
      assert.equal(row("code").getAttribute("aria-keyshortcuts"), "Control+Alt+C");
      assert.match(row("list").querySelector(".bp-slash-desc").textContent, new RegExp(`· Ctrl\\+${shift}\\+8$`));
      assert.equal(row("paragraph").hasAttribute("aria-keyshortcuts"), false, "a row with no chord names none");
    });
    canvas._closeSlash();

    canvas._openPalette();
    const items = [...canvas._palette._el.querySelectorAll(".bp-slash-item")];
    const byShortcut = (aria) => items.find((r) => r.getAttribute("aria-keyshortcuts") === aria);
    await check(`the ${lang} command palette names the turn-into and code chords`, () => {
      assert.match(byShortcut("Control+Shift+8")?.textContent || "", new RegExp(`Ctrl\\+${shift}\\+8`));
      assert.match(byShortcut("Control+Shift+7")?.textContent || "", new RegExp(`Ctrl\\+${shift}\\+7`));
      assert.match(byShortcut("Control+Alt+C")?.textContent || "", /Ctrl\+Alt\+C/);
    });
    unmount(canvas);
  }
} catch (error) {
  failures += 1;
  console.log(`FAIL  harness: ${error.stack}`);
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall chord checks passed");
process.exit(0);
