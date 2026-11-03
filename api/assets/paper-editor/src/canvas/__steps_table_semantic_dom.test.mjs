// Mounted production-DOM contract for the two container rows that previously
// needed conformance repair. Steps expose a real reader title plus removable
// controls. Tables expose their real role/cell wrappers and only project the PM
// tbody to reader sections after strict structural validation.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver",
  "Node", "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { projectMountedTableForReader } = await import("./table-node.js");
const { DOMParser: PMDOMParser } = await import("@tiptap/pm/model");
await import("../index.js");

const text = (value) => ({ type: "text", value });
const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [
  {
    id: "steps-semantic", type: "steps",
    steps: [{ id: "step-one", title: "Prepare", blocks: [{ id: "step-body", type: "paragraph", content: [text("Collect inputs.")] }] }],
  },
  {
    id: "table-semantic", type: "table",
    head: [[text("Name")], [text("Age")]],
    rows: [[[text("Ada")], [text("36")]], [[text("Bob")], [text("40")]]],
  },
];
document.body.appendChild(canvas);

try {
  const step = canvas.querySelector("li.bp-steps__step");
  const readerTitle = step.querySelector(":scope > .bp-steps__title");
  const controls = step.querySelector(":scope > .bp-canvas-row__head");
  const input = controls.querySelector("input[data-test-id='paper-step-title']");
  const body = step.querySelector(":scope > .bp-steps__body");
  assert.equal(readerTitle.textContent, "Prepare", "the mounted row owns its real reader title");
  assert.equal(input.hidden, true, "the duplicate editor input is absent from the resting paint");
  assert.equal(body.textContent, "Collect inputs.", "the actual reader body remains the PM contentDOM");

  readerTitle.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.equal(document.activeElement, input, "keyboard activation enters the title editor");
  assert.equal(readerTitle.hidden, true);
  input.value = "Prepare carefully";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  input.blur();
  assert.equal(readerTitle.hidden, false, "blur returns to the reader-shaped resting title");
  assert.equal(readerTitle.textContent, "Prepare carefully", "the real title follows the committed PM attribute");
  assert.equal(canvas._editor.state.doc.firstChild.firstChild.attrs.title, "Prepare carefully");

  const table = canvas.querySelector("table.bp-table[data-bp-conformance-root]");
  assert.equal(table.getAttribute("role"), "presentation", "the mounted table carries the reader role itself");
  assert.equal(table.querySelectorAll(":scope > tbody > tr").length, 3);
  assert.equal(table.querySelectorAll(":scope > tbody > tr:first-child > th > span").length, 2,
    "header cells own real inline span contentDOMs");
  assert.equal(table.querySelectorAll(":scope > tbody > tr:nth-child(2) > td > span").length, 2,
    "body cells own real inline span contentDOMs");

  const liveHTML = table.outerHTML;
  const projected = projectMountedTableForReader(table);
  assert.ok(projected, "the production table satisfies the strict reader projection");
  assert.equal(table.outerHTML, liveHTML, "projection never mutates the live editable table");
  assert.equal(projected.querySelectorAll(":scope > thead > tr > th").length, 2);
  assert.equal(projected.querySelectorAll(":scope > tbody > tr").length, 2);
  assert.equal(projected.querySelector("td > span").hasAttribute("data-bp-table-cell-content"), false,
    "the projected reader span drops its editor-only parser marker");

  const bodyCellPositions = [];
  canvas._editor.state.doc.descendants((node, pos) => {
    if (node.type.name === "bpTableCell") bodyCellPositions.push({ node, pos });
  });
  const ada = bodyCellPositions[0];
  canvas._editor.chain().setTextSelection(ada.pos + 1 + ada.node.content.size).insertContent(" Lovelace").run();
  assert.equal(table.querySelector(":scope > tbody > tr:nth-child(2) > td > span").textContent, "Ada Lovelace",
    "typing and selection still edit the PM cell through its semantic span");

  const paste = document.createElement("div");
  paste.innerHTML = '<table data-bp-type="table"><tbody><tr><td><span style="font-weight:bold">Authored</span></td></tr></tbody></table>';
  const parsed = PMDOMParser.fromSchema(canvas._editor.schema).parse(paste);
  const parsedText = parsed.firstChild.firstChild.firstChild.firstChild;
  assert.equal(parsedText.text, "Authored");
  assert.ok(parsedText.marks.some((mark) => mark.type.name === "bold"),
    "an authored sole span is parsed as content, not mistaken for the structural wrapper");

  const malformed = [
    (clone) => clone.removeAttribute("role"),
    (clone) => clone.querySelector("td").replaceChildren("bare text"),
    (clone) => clone.querySelector("tbody tr:nth-child(2) td").replaceWith(document.createElement("th")),
    (clone) => clone.querySelector("tbody").append(clone.querySelector("tbody tr").cloneNode(true)),
  ];
  for (const mutate of malformed) {
    const clone = table.cloneNode(true);
    mutate(clone);
    assert.equal(projectMountedTableForReader(clone), false, "malformed producer DOM must fail closed");
  }

  console.log("PASS steps/table semantic DOM: real resting nodes, preserved editing, strict projection");
} finally {
  canvas.remove();
  window.close();
}
