// __internal_link_mounted.test.mjs — a field that declares Sanity's `internalLink`
// annotation admits portable-doc's `wikilink` (the document link, { target, docId }):
// the toolbar's toggleMark("wikilink", { docId, target }) sets it over the selection
// and clears it, state() reports it, the stored shape bp import writes
// ({ type, target, docId, children }, no alias) round-trips byte-identical, and a
// field without internalLink refuses it.
// Run: node src/canvas/__internal_link_mounted.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement",
  "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Option", "Selection", "Text",
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
const { docToBlocks } = await import("./run-convert.js");
const { TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);

const VOCAB = { styles: ["normal"], marks: ["strong"], annotations: [{ name: "link" }, { name: "internalLink" }] };
const IMPORTED = {
  id: "p-imp", type: "paragraph",
  content: [
    { type: "text", value: "Written with " },
    { type: "wikilink", target: "author-ada", docId: "author-ada", children: [{ type: "strong", children: [{ type: "text", value: "Ada" }] }] },
    { type: "text", value: "." },
  ],
};
const BLOCKS = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "See the author page." }] }, IMPORTED];

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}
async function mount(vocab) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(vocab));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  document.body.appendChild(canvas);
  await tick(350);
  return canvas;
}
const selectWord = (editor, word) => {
  let at = null;
  editor.state.doc.descendants((n, p) => { if (at == null && n.isText && n.text.includes(word)) at = p + n.text.indexOf(word); });
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at, at + word.length)));
};

try {
  const canvas = await mount(VOCAB);
  const editor = canvas._editor;
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));

  await check("the imported wikilink shape round-trips byte-identical (no op)", async () => {
    assert.equal(canonical(docToBlocks(editor.getJSON()).find((b) => b.id === "p-imp")), canonical(IMPORTED));
    canvas.flushPendingChanges();
    await tick(20);
    assert.deepEqual(ops.filter((o) => o.id === "p-imp"), []);
  });

  await check("toggleMark wikilink sets a document link over the selection; state() reports it", async () => {
    selectWord(editor, "author page");
    assert.equal(canvas.can("toggleMark", { mark: "wikilink", docId: "author-ada" }), true);
    assert.equal(canvas.toggleMark("wikilink", { docId: "author-ada", target: "Ada Lovelace" }), true);
    assert.deepEqual(canvas.state().wikilink, { target: "Ada Lovelace", docId: "author-ada" });
    assert.ok(canvas.state().marks.includes("wikilink"));
    canvas.flushPendingChanges();
    await tick(20);
    const op = ops.find((o) => o.id === "p1");
    assert.ok(op, JSON.stringify(ops));
    const link = JSON.stringify(op).match(/\{"type":"wikilink"[^]*?\]\}/)?.[0] || JSON.stringify(op);
    assert.ok(link.includes('"docId":"author-ada"') && link.includes('"target":"Ada Lovelace"') && link.includes('"author page"'), link);
  });

  await check("with no document it clears the link in place", () => {
    selectWord(editor, "author");
    assert.equal(canvas.can("toggleMark", { mark: "wikilink" }), true);
    assert.equal(canvas.toggleMark("wikilink"), true);
    assert.equal(canvas.state().wikilink, null);
    assert.equal(canvas.can("toggleMark", { mark: "wikilink" }), false, "nothing left to clear");
  });

  await check("a field without internalLink refuses it", async () => {
    const plain = await mount({ styles: ["normal"], marks: ["strong"], annotations: [{ name: "link" }] });
    const ed = plain._editor;
    selectWord(ed, "author page");
    assert.equal(plain.can("toggleMark", { mark: "wikilink", docId: "author-ada" }), false);
    assert.equal(plain.toggleMark("wikilink", { docId: "author-ada" }), false);
    plain.remove();
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ninternal link mounted: all checks passed");
  process.exit(0);
}
