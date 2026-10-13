// Paste fidelity, Sanity parity (task-68314b1d334213e8): content that was kept but
// shaped wrong. The clipboards are sanity-builder's scout shapes (barkpark-studio
// e2e/journeys/paste.spec.ts CLIPBOARDS) plus controls, pasted as real events.
// Run: node src/canvas/__paste_fidelity_mounted.test.mjs
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
const pasted = (r) => r.blocks.slice(1);

try {
  await test("0. <blockquote><p>…</p></blockquote> is the field's quote style, and a quote block in a paper", async () => {
    const clip = { html: "<p>Before</p><blockquote><p>Quoted text</p></blockquote><p>After</p>", text: "Before\nQuoted text\nAfter" };
    let r = await pasteInto(clip);
    assert.deepEqual(pasted(r).map((b) => b.type), ["paragraph", "pullquote", "paragraph"]);
    assert.equal(plain(pasted(r)[1].content), "Quoted text");
    r.canvas.remove();
    r = await pasteInto(clip, null);
    assert.equal(pasted(r)[1].type, "blockquote");
    r.canvas.remove();
    // Two paragraphs in one quote: one quote block each (Sanity's shape; a quote
    // block may not hold a line break), in a field and in a paper.
    r = await pasteInto({ html: "<blockquote><p>One</p><p>Two</p></blockquote>", text: "One\nTwo" });
    assert.deepEqual(pasted(r).map((b) => [b.type, plain(b.content)]), [["pullquote", "One"], ["pullquote", "Two"]]);
    r.canvas.remove();
    r = await pasteInto({ html: "<blockquote><p>One</p><p>Two</p></blockquote>", text: "One\nTwo" }, null);
    assert.deepEqual(pasted(r).map((b) => [b.type, plain(b.content)]), [["blockquote", "One"], ["blockquote", "Two"]]);
    r.canvas.remove();
  });

  await test("1. a markdown [text](url) is a link over its text, on one line too", async () => {
    for (const text of ["See [the docs](https://example.com/md) now.", "See [the docs](https://example.com/md) now.\n\n- a bullet"]) {
      const r = await pasteInto({ text });
      const p = pasted(r)[0];
      assert.deepEqual(p.content, [{ type: "text", value: "See " }, { type: "link", href: "https://example.com/md", children: [{ type: "text", value: "the docs" }] }, { type: "text", value: " now." }]);
      assert.doesNotMatch(JSON.stringify(r.blocks), /\[the docs\]/);
      r.canvas.remove();
    }
    const r = await pasteInto({ text: "See [the docs](https://example.com/md) now." });
    assert.equal(r.blocks.length, 2, "one line flows into the caret's line, no extra block");
    r.canvas.remove();
  });

  await test("2. Google Docs: no underline inside the link, no newline paragraph from a <br> between blocks", async () => {
    const r = await pasteInto(CLIPBOARDS["google-docs"]);
    const link = JSON.stringify(pasted(r).find((b) => JSON.stringify(b).includes('"link"')));
    assert.doesNotMatch(link, /underline/);
    assert.ok(!r.blocks.some((b) => b.type === "paragraph" && /^\s*$/.test(plain(b.content)) && JSON.stringify(b).includes("\\n")), "no paragraph holding only a newline");
    assert.deepEqual(pasted(r).map((b) => b.type), ["heading", "paragraph", "list", "paragraph"]);
    r.canvas.remove();
  });

  await test("2b. controls: an author's underline outside a link and a <br> inside a line are kept", async () => {
    const r = await pasteInto({ html: '<p><span style="text-decoration:underline">kept</span> and line<br>break</p>', text: "kept and line\nbreak" });
    const p = pasted(r)[0];
    assert.match(JSON.stringify(p.content), /"underline"/);
    assert.equal(plain(p.content), "kept and line\nbreak");
    r.canvas.remove();
  });

  await test("3. plain text: a single newline is a soft break in one block; a blank line still splits", async () => {
    const r = await pasteInto({ text: "Line one\nLine two\n\nNew paragraph after a blank line" });
    assert.deepEqual(pasted(r).map((b) => plain(b.content)), ["Line one\nLine two", "New paragraph after a blank line"]);
    assert.equal(inVocab(r.ed), null);
    r.canvas.remove();
  });
  await test("3b. multi-line plain text pasted inside a quote keeps every line (a quote holds no soft break)", async () => {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.setAttribute("data-vocabulary", VOCAB);
    canvas.blocks = [{ id: "q", type: "pullquote", content: [{ type: "text", value: "Quoted" }] }];
    canvas.acknowledgedSaves = true;
    document.body.append(canvas);
    await tick(50);
    const ed = canvas._editor;
    ed.chain().setTextSelection(ed.state.doc.child(0).nodeSize - 1).run();
    const event = new Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", { value: { types: ["text/plain"], getData: (t) => (t === "text/plain" ? "Line one\nLine two\n\nNew paragraph" : ""), files: [] } });
    ed.view.dom.dispatchEvent(event);
    await tick(20);
    const t = canvas.recoverySnapshot().blocks.map((b) => plain(b.content)).join(" | ");
    for (const want of ["Line one", "Line two", "New paragraph"]) assert.ok(t.includes(want), `kept ${want}: ${t}`);
    canvas.remove();
  });
} finally {
  console.log(`\n${passed} passed`);
}
process.exit(0);
