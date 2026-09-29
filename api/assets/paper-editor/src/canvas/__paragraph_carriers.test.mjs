import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { tiptapToBlock } from "../convert.js";
import "../__paragraph_carriers.test.mjs";

const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("../index.js");

const source = { id: "p", type: "paragraph", text: "Legacy paragraph", audit: { keep: true } };
for (const mode of ["canvas", "single"]) {
  const host = document.createElement(mode === "canvas" ? "bp-paper-canvas" : "bp-paper-editor");
  const ops = [];
  if (mode === "canvas") {
    host.blocks = [source];
    host.addEventListener("bp-canvas-ops", e => ops.push(...e.detail.ops));
  } else {
    host.block = source;
    host.addEventListener("bp-op", e => ops.push(e.detail));
  }
  document.body.appendChild(host);
  try {
    const editor = host._editor;
    assert.equal(editor.getText(), source.text);
    assert.doesNotMatch(editor.getHTML(), /bpParagraphSource|audit/);
    editor.commands.setTextSelection({ from: 1, to: source.text.length + 1 });
    editor.commands.insertContent("Changed paragraph");
    host.flushPendingChanges();
    assert.deepEqual(ops.at(-1).patch, { text: "Changed paragraph" });
    assert.equal(editor.commands.undo(), true);
    assert.deepEqual(tiptapToBlock(editor.getJSON(), "p", "paragraph"), { text: source.text });
    if (mode === "canvas") {
      editor.commands.setTextSelection(7);
      editor.commands.splitBlock();
      const nodes = editor.getJSON().content;
      assert.deepEqual(tiptapToBlock({ content: [nodes[0]] }, "p", "paragraph"), { text: "Legacy" });
      assert.deepEqual(tiptapToBlock({ content: [nodes[1]] }, null, "paragraph"), { text: " paragraph" });
      host.flushPendingChanges();
      const inserted = ops.find(op => op.op === "insert-after");
      assert.ok(inserted, "native split emits a new block rather than overwriting the original");
    }
  } finally { host.remove(); }
}
// Reader-accepted inline spellings (inline.ex compose_inline/apply_mark): `strike`/`s`
// wrappers, a text leaf's flat `marks` array and its legacy `text` key. An UNTOUCHED
// sibling that also carries a link must stay byte-identical when another block in the
// run is edited (the Link extension's target/rel/class defaults once made the carrier
// comparison fail and re-serialize it, dropping the strike — lane B pass-5 census), and a
// TOUCHED paragraph must keep the formatting the reader paints.
{
  const t = (value) => ({ type: "text", value });
  const aliasParagraph = { id: "alias", type: "paragraph", content: [
    t("A "), { type: "link", href: "https://x.test/a", children: [t("link")] }, t(" and "),
    { type: "strike", children: [t("gone")] }, t(", "), { type: "s", children: [t("short")] }, t(", "),
    { type: "text", value: "bold", marks: [{ type: "bold" }] }, t(", "), { type: "text", text: "legacy" }, t("."),
  ], audit: { keep: true } };
  const host = document.createElement("bp-paper-canvas");
  const ops = [];
  host.blocks = [{ id: "h", type: "heading", level: 2, text: "Head" }, aliasParagraph];
  host.addEventListener("bp-canvas-ops", e => ops.push(...e.detail.ops));
  document.body.appendChild(host);
  try {
    const editor = host._editor;
    assert.equal(editor.getJSON().content[1].content.map(n => n.text).join(""), "A link and gone, short, bold, legacy.",
      "the canvas shows every run the reader paints, including a legacy text-key leaf");
    const marksOf = (text) => editor.getJSON().content[1].content.find(n => n.text === text)?.marks?.map(m => m.type) || [];
    assert.deepEqual(marksOf("gone"), ["strike"]);
    assert.deepEqual(marksOf("short"), ["strike"]);
    assert.deepEqual(marksOf("bold"), ["bold"]);
    editor.commands.setTextSelection(3);
    editor.commands.insertContent("X");
    host.flushPendingChanges();
    assert.equal(ops.filter(op => op.id === "alias").length, 0, "an untouched linked paragraph is never rewritten");
    const end = editor.state.doc.content.size - 1;
    editor.commands.setTextSelection(end);
    editor.commands.insertContent("!");
    host.flushPendingChanges();
    const patch = ops.filter(op => op.id === "alias").at(-1)?.patch;
    assert.ok(patch, "the touched paragraph emits its patch");
    const struck = patch.content.filter(n => n.type === "strikethrough").map(n => n.children[0].value);
    assert.deepEqual(struck, ["gone", "short"], "strike and s survive a touch as canonical strikethrough");
    assert.ok(patch.content.some(n => n.type === "strong" && n.children[0].value === "bold"), "a flat bold mark survives as strong");
    assert.match(JSON.stringify(patch.content), /legacy/, "a legacy text-key leaf keeps its words");
  } finally { host.remove(); }
}
dom.window.close();
console.log("mounted paragraph carrier editing and split preservation passed");
