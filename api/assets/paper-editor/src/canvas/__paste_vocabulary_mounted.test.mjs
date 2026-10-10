// A paste is fitted to a field's vocabulary node by node and never dropped whole
// (task-76c5440175affe20). The clipboards are sanity-builder's scout shapes
// (barkpark-studio e2e/journeys/paste.spec.ts CLIPBOARDS), pasted as real events.
// Run: node src/canvas/__paste_vocabulary_mounted.test.mjs
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

const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);




const R = { x: 0, y: 0, top: 0, left: 0, right: 10, bottom: 10, width: 10, height: 10 };
window.Element.prototype.getClientRects = function () { return [R]; };
window.Element.prototype.getBoundingClientRect = function () { return R; };
window.Range.prototype.getClientRects = function () { return [R]; };
window.Range.prototype.getBoundingClientRect = function () { return R; };
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const { docVocabularyViolation, parseVocabulary } = await import("./vocabulary.js");

const S = 'font-size:11pt;font-family:Arial,sans-serif;color:#000000;background-color:transparent;font-variant:normal;text-decoration:none;vertical-align:baseline;white-space:pre;white-space:pre-wrap;'
const P = 'line-height:1.38;margin-top:0pt;margin-bottom:0pt;'
const CLIPBOARDS = {
  'google-docs': {
    html: `<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1a2b3c4d-7fff-1234-5678-9abcdef01234"><h2 dir="ltr" style="line-height:1.38;margin-top:18pt;margin-bottom:6pt;"><span style="font-size:16pt;font-family:Arial,sans-serif;color:#000000;font-weight:400;font-style:normal;${S}">Docs heading</span></h2><p dir="ltr" style="${P}"><span style="${S}font-weight:700;font-style:normal;">Bold</span><span style="${S}font-weight:400;font-style:normal;">, </span><span style="${S}font-weight:400;font-style:italic;">italic</span><span style="${S}font-weight:400;font-style:normal;"> and a </span><a href="https://example.com/docs" style="text-decoration:none;"><span style="font-size:11pt;font-family:Arial,sans-serif;color:#1155cc;font-weight:400;font-style:normal;text-decoration:underline;-webkit-text-decoration-skip:none;text-decoration-skip-ink:none;vertical-align:baseline;white-space:pre;white-space:pre-wrap;">link</span></a><span style="${S}font-weight:400;">.</span></p><ul style="margin-top:0;margin-bottom:0;padding-inline-start:48px;"><li dir="ltr" style="list-style-type:disc;font-size:11pt;font-family:Arial,sans-serif;" aria-level="1"><p dir="ltr" style="${P}" role="presentation"><span style="${S}font-weight:400;">Docs bullet one</span></p></li><li dir="ltr" style="list-style-type:disc;" aria-level="1"><p dir="ltr" style="${P}" role="presentation"><span style="${S}font-weight:400;">Docs bullet two</span></p></li></ul><br><p dir="ltr" style="${P}"><span style="${S}font-weight:400;">Docs last line</span></p></b><br class="Apple-interchange-newline">`,
    text: 'Docs heading\nBold, italic and a link.\n* Docs bullet one\n* Docs bullet two\n\nDocs last line',
  },
  word: {
    html: `<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word" xmlns="http://www.w3.org/TR/REC-html40"><head><meta http-equiv=Content-Type content="text/html; charset=utf-8"><meta name=Generator content="Microsoft Word 15"><style><!-- p.MsoNormal {margin:0in;font-size:11.0pt;font-family:"Calibri",sans-serif;} p.MsoListParagraphCxSpFirst {margin-left:.5in;} --></style></head><body lang=EN-US style='tab-interval:.5in'><!--StartFragment--><h1><span style='mso-fareast-font-family:"Times New Roman"'>Word heading<o:p></o:p></span></h1><p class=MsoNormal><b><span style='font-family:"Calibri",sans-serif'>Bold</span></b>, <i>italic</i> and a <a href="https://example.com/word">link</a>.<o:p></o:p></p><p class=MsoListParagraphCxSpFirst style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol;mso-fareast-font-family:Symbol'><span style='mso-list:Ignore'>·<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span><![endif]>Word bullet one<o:p></o:p></p><p class=MsoListParagraphCxSpLast style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol;mso-fareast-font-family:Symbol'><span style='mso-list:Ignore'>·<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span><![endif]>Word bullet two<o:p></o:p></p><p class=MsoNormal>Word last line<o:p></o:p></p><!--EndFragment--></body></html>`,
    text: 'Word heading\nBold, italic and a link.\n·        Word bullet one\n·        Word bullet two\nWord last line',
  },
  'web-article': {
    html: `<meta charset="utf-8"><article><h2>Web heading</h2><p><strong>Bold</strong> and <em>italic</em> with a <a href="https://example.com/web" target="_blank" rel="noopener" class="ext">link</a>.</p><ul><li>Web bullet one</li><li>Web bullet <strong>two</strong></li></ul><ol><li>Web number one</li></ol><figure><img src="https://www.sanity.io/static/images/opengraph/social.png" alt="A photo" width="20" height="20"><figcaption>A caption</figcaption></figure><table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table><blockquote><p>Quoted text</p></blockquote><pre><code>const x = 1</code></pre><p>Web last line</p></article>`,
    text: 'Web heading\nBold and italic with a link.\nWeb bullet one\nWeb bullet two\nWeb number one\nA caption\nA\tB\n1\t2\nQuoted text\nconst x = 1\nWeb last line',
  },
  markdown: {text: '## MD heading\n\n**Bold** and *italic* with a [link](https://example.com/md).\n\n- MD bullet one\n- MD bullet two\n\n1. MD one\n2. MD two\n\n> MD quote\n\nMD last line'},
  'plain-text': {text: 'Line one\nLine two\n\nNew paragraph after a blank line'},
}



// Sanity's default block content: the field the scout pasted into.
const VOCAB = JSON.stringify({ styles: ["normal", "h1", "h2", "h3", "h4", "blockquote"], lists: ["bullet", "number"], marks: ["strong", "em", "code", "underline"], annotations: [{ name: "link" }], of: ["image"] });

async function pasteInto(clip, vocabulary = VOCAB) {
  const canvas = document.createElement("bp-paper-canvas");
  if (vocabulary) canvas.setAttribute("data-vocabulary", vocabulary);
  canvas.blocks = [{ id: "p0", type: "paragraph", content: [{ type: "text", value: "Paste below this line." }] }];
  canvas.acknowledgedSaves = true;
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail));
  document.body.append(canvas);
  await tick(50);
  const ed = canvas._editor;
  ed.chain().setTextSelection(ed.state.doc.child(0).nodeSize - 1).splitBlock().run();
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { types: clip.html ? ["text/html", "text/plain"] : ["text/plain"], getData: (t) => (t === "text/html" ? clip.html || "" : t === "text/plain" ? clip.text : ""), files: [] } });
  ed.view.dom.dispatchEvent(event);
  await tick(20);
  canvas.flushPendingChanges?.();
  const blocks = canvas.recoverySnapshot().blocks;
  const notice = () => canvas.querySelector("[data-bp-paste-notice]")?.textContent || "";
  return { canvas, blocks, notice, batches, ed };
}
const plain = (inline) => (inline || []).map((n) => n.value ?? n.text ?? plain(n.children)).join("");
const texts = (blocks) => blocks.map((b) => b.text || plain(b.content) || (b.items || []).map(plain).join(" | ") || b.value || "");
const inVocab = (ed) => docVocabularyViolation(ed.getJSON(), parseVocabulary(VOCAB));

let passed = 0;
async function test(name, run) { await run(); console.log("PASS " + name); passed++; }

try {
  await test("1. markdown with a `> quote` line pastes EVERY block; the quote is the field's quote block", async () => {
    const r = await pasteInto(CLIPBOARDS.markdown);
    const t = texts(r.blocks);
    for (const want of ["MD heading", "MD bullet one | MD bullet two", "MD quote", "MD last line"]) assert.ok(t.includes(want), `kept ${want}: ${JSON.stringify(t)}`);
    assert.equal(r.blocks.find((b) => plain(b.content) === "MD quote").type, "pullquote");
    assert.equal(r.notice(), "", "nothing was left out, so no notice");
    assert.equal(inVocab(r.ed), null);
    r.canvas.remove();
  });

  await test("2. HTML with a <table> keeps the surrounding blocks and the cell text as paragraphs", async () => {
    const r = await pasteInto({ html: "<p>Before</p><table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table><p>After</p>", text: "Before\nA\tB\n1\t2\nAfter" });
    const t = texts(r.blocks);
    for (const want of ["Before", "A", "B", "1", "2", "After"]) assert.ok(t.includes(want), `kept ${want}: ${JSON.stringify(t)}`);
    assert.ok(!r.blocks.some((b) => b.type === "table"), "no table in a field without one");
    assert.equal(inVocab(r.ed), null);
    r.canvas.remove();
  });

  await test("3. <img>/<figure> pastes all its text and shows a lasting notice naming the image", async () => {
    const r = await pasteInto(CLIPBOARDS["web-article"]);
    const t = texts(r.blocks);
    for (const want of ["Web heading", "A caption", "A", "2", "Quoted text", "const x = 1", "Web last line"]) assert.ok(t.includes(want), `kept ${want}: ${JSON.stringify(t)}`);
    assert.match(r.notice(), /Pasted the text\. Left out: an image\./);
    assert.doesNotMatch(r.notice(), /Nothing was pasted/);
    await tick(600);
    assert.match(r.notice(), /Left out: an image/, "the notice has no timeout, and outlives the save flush");
    r.ed.commands.insertContent("x");
    assert.equal(r.notice(), "", "the person's next edit clears it");
    assert.equal(inVocab(r.ed), null);
    r.canvas.remove();
  });

  await test("3b. a paper canvas (no vocabulary) also pastes the text of HTML with an image", async () => {
    const r = await pasteInto(CLIPBOARDS["web-article"], null);
    assert.ok(texts(r.blocks).includes("Web last line"));
    assert.match(r.notice(), /Left out: an image\./);
    r.canvas.remove();
  });

  await test("4. a pasted <pre><code> becomes a paragraph with a code mark, so the save is not refused", async () => {
    const r = await pasteInto({ html: "<p>Before</p><pre><code>const x = 1</code></pre><p>After</p>", text: "Before\nconst x = 1\nAfter" });
    const code = r.blocks.find((b) => plain(b.content) === "const x = 1");
    assert.equal(code.type, "paragraph");
    assert.deepEqual(code.content, [{ type: "code", value: "const x = 1" }]);
    const opTypes = r.batches.flatMap((batch) => batch.ops || []).flatMap((op) => (op.block ? [op.block.type] : []));
    assert.ok(opTypes.length && opTypes.every((type) => type === "paragraph"), `ops carry only admitted blocks: ${opTypes}`);
    assert.equal(inVocab(r.ed), null);
    r.canvas.remove();
  });

  await test("an in-vocabulary paste is untouched (Google Docs)", async () => {
    const r = await pasteInto(CLIPBOARDS["google-docs"]);
    assert.deepEqual(r.blocks.map((b) => b.type + (b.level || "")), ["paragraph", "heading2", "paragraph", "list", "paragraph", "paragraph"]);
    assert.equal(r.notice(), "");
    r.canvas.remove();
  });
} finally {
  console.log(`\n${passed} passed`);
}
process.exit(0);
