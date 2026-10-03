// Pasting a list from Microsoft Word into the canvas lands as a LIST, not as
// paragraphs that start with "·   ". Found dogfooding the Studio canvas
// (2026-10-03): Word puts each item on the clipboard as
// <p style="mso-list:l0 level1 lfo1"> with the bullet or number as literal
// text inside an <![if !supportLists]> conditional, and the canvas stored that
// literal text. The clipboard HTML below is the shape Word for Windows and
// Word for Mac write (markers in mso-list:Ignore spans inside the conditional).

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "CompositionEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (v) => String(v) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");
const { normalizeWordListHTML } = await import("./word-paste.js");

const marker = (glyph, font = "Symbol") =>
  `<![if !supportLists]><span style='font-family:${font}'><span style='mso-list:Ignore'>${glyph}<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span><![endif]>`;
const wordItem = (list, level, glyph, text, cls = "MsoListParagraphCxSpMiddle", font) =>
  `<p class=${cls} style='text-indent:-18.0pt;mso-list:${list} level${level} lfo1'>${marker(glyph, font)}${text}<o:p></o:p></p>`;
const wordDoc = (body) =>
  `<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word"><head><style>p.MsoNormal{margin:0cm}</style></head><body lang=EN-US><!--StartFragment-->${body}<!--EndFragment--></body></html>`;

function paste(canvas, html, text) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: {
    types: ["text/html", "text/plain"],
    getData: (type) => (type === "text/html" ? html : type === "text/plain" ? text : ""),
    files: [],
  } });
  canvas._editor.view.dom.dispatchEvent(event);
}
function mount() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [{ id: "before", type: "paragraph", content: [] }];
  canvas.acknowledgedSaves = true;
  document.body.append(canvas);
  return canvas;
}
const inl = (c) => (c || []).map((n) => n.value ?? inl(n.children || [])).join("");
const itemText = (it) => (Array.isArray(it) ? inl(it) : it.text ?? inl(it.content || []));
let passed = 0;
function test(name, run) {
  const canvas = mount();
  try {
    run(canvas);
    console.log("PASS " + name);
    passed++;
  } finally {
    canvas.remove();
  }
}

try {
  test("a Word bulleted list pastes as one unordered list without bullet glyphs", (c) => {
    paste(c, wordDoc(
      `<p class=MsoNormal>Intro line<o:p></o:p></p>` +
      wordItem("l0", 1, "·", "Word item one", "MsoListParagraphCxSpFirst") +
      wordItem("l0", 1, "·", "Word item <b>two</b>", "MsoListParagraphCxSpLast"),
    ), "Intro line\n·   Word item one\n·   Word item two");
    const blocks = c.recoverySnapshot().blocks;
    const list = blocks.find((b) => b.type === "list");
    assert.ok(list, `a list block exists: ${JSON.stringify(blocks)}`);
    assert.equal(list.ordered, false);
    assert.deepEqual(list.items.map(itemText), ["Word item one", "Word item two"]);
    assert.ok(!JSON.stringify(blocks).includes("·"), "no bullet glyph is stored");
    assert.ok(blocks.some((b) => b.type === "paragraph" && inl(b.content) === "Intro line"));
  });

  test("a Word numbered list pastes as an ordered list", (c) => {
    paste(c, wordDoc(
      wordItem("l1", 1, "1.", "First step", "MsoListParagraphCxSpFirst", "Calibri") +
      wordItem("l1", 1, "2.", "Second step", "MsoListParagraphCxSpLast", "Calibri"),
    ), "1. First step\n2. Second step");
    const list = c.recoverySnapshot().blocks.find((b) => b.type === "list");
    assert.ok(list);
    assert.equal(list.ordered, true);
    assert.deepEqual(list.items.map(itemText), ["First step", "Second step"]);
  });

  test("a second-level Word item nests under its parent", (c) => {
    paste(c, wordDoc(
      wordItem("l0", 1, "·", "Parent", "MsoListParagraphCxSpFirst") +
      wordItem("l0", 2, "o", "Child", "MsoListParagraphCxSpMiddle", "Courier New") +
      wordItem("l0", 1, "·", "Sibling", "MsoListParagraphCxSpLast"),
    ), "Parent\nChild\nSibling");
    const html = c._editor.getHTML();
    assert.match(html, /<li><p>Parent<\/p><ul[^>]*><li><p>Child<\/p><\/li><\/ul><\/li><li><p>Sibling<\/p><\/li>/,
      `the child item nests inside the parent: ${html}`);
  });

  test("non-Word HTML is returned unchanged", () => {
    const html = "<p>Plain <b>HTML</b></p><ul><li>x</li></ul>";
    assert.equal(normalizeWordListHTML(html), html);
  });

  console.log(`${passed} Word list paste cases passed`);
} finally {
  dom.window.close();
}
