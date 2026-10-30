// __wikilink_input_keys_mounted.test.mjs — contract 1.17.0: a typed `[[Title]]` becomes
// a document link only when wikilinkSource(Title) returns a row with that exact title (ignoring
// case); Mod+Enter edits nothing and stays free for the host.
// Run: node src/canvas/__wikilink_input_keys_mounted.test.mjs   (or: npm test)
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
  "InputEvent", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Option", "Selection", "Text",
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

const ROWS = [
  { title: "Plan", id: "n-plan", type: "note" },
  { title: "Planning week", id: "n-week", type: "note" },
  { title: "Ærlig talt", id: "n-aer", type: "note" },
];
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Start " }] },
  { id: "p2", type: "paragraph", content: [{ type: "text", value: "Code " }, { type: "text", value: "x", marks: ["code"] }] },
  { id: "p3", type: "paragraph", content: [{ type: "text", value: "Dead " }, { type: "wikilink", target: "Gone", docId: "n-gone", children: [{ type: "text", value: "Gone" }] }, { type: "text", value: " end." }] },
];

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

async function mount({ blocks = BLOCKS, source = (q) => ROWS.filter((r) => r.title.toLowerCase().includes(q.toLowerCase())), editable = true } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  const asked = [];
  if (source) canvas.wikilinkSource = (q) => { asked.push(q); return source(q); };
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  document.body.appendChild(canvas);
  await tick(350);
  return { canvas, editor: canvas._editor, ops, asked };
}

const blockOf = (editor, id) => docToBlocks(editor.getJSON()).find((b) => b.id === id);
const textOf = (editor, id) => editor.state.doc.child(docToBlocks(editor.getJSON()).findIndex((b) => b.id === id)).textContent;
const links = (editor) => {
  const out = [];
  editor.state.doc.descendants((n) => {
    const m = n.isText && n.marks.find((k) => k.type.name === "wikilink");
    if (m) out.push({ words: n.text, target: m.attrs.target, docId: m.attrs.docId });
  });
  return out;
};
const endOf = (editor, index) => {
  let at = 0;
  editor.state.doc.forEach((node, offset, i) => { if (i === index) at = offset + node.nodeSize - 1; });
  return at;
};
const caret = (editor, pos) => editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, pos)));
function type(editor, text) {
  const { view } = editor;
  for (const char of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, char));
    if (!handled) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}
function paste(editor, text, html = "") {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  const types = html ? ["text/html", "text/plain"] : ["text/plain"];
  Object.defineProperty(event, "clipboardData", { value: { types, getData: (t) => (t === "text/plain" ? text : t === "text/html" ? html : ""), files: [] } });
  editor.view.dom.dispatchEvent(event);
}
function key(editor, init) {
  const ev = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  editor.view.dom.dispatchEvent(ev);
  return ev;
}
function newline(editor, inputType = "insertParagraph") {
  const ev = new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType });
  editor.view.dom.dispatchEvent(ev);
  return ev;
}

try {
  const { canvas, editor, ops, asked } = await mount();

  await check("a typed [[Plan]] that names a known document becomes a link to it, written as a pick", async () => {
    caret(editor, endOf(editor, 0));
    type(editor, "[[Plan]]");
    await tick(10);
    assert.deepEqual(links(editor).filter((l) => l.docId === "n-plan"), [{ words: "Plan", target: "Plan", docId: "n-plan" }]);
    assert.equal(textOf(editor, "p1"), "Start Plan");
    assert.ok(asked.includes("Plan"));
    canvas.flushPendingChanges();
    await tick(350);
    const saved = ops.find((op) => op.op === "patch-block" && op.id === "p1");
    assert.ok(saved, JSON.stringify(ops));
    assert.deepEqual(saved.patch.content, [{ type: "text", value: "Start " }, { type: "wikilink", target: "Plan", docId: "n-plan", children: [{ type: "text", value: "Plan" }] }]);
  });

  await check("the match ignores case and the link takes the document's own title", async () => {
    type(editor, " [[ærlig TALT]]");
    await tick(10);
    assert.equal(textOf(editor, "p1"), "Start Plan Ærlig talt");
    assert.deepEqual(links(editor).find((l) => l.docId === "n-aer"), { words: "Ærlig talt", target: "Ærlig talt", docId: "n-aer" });
  });

  await check("a title that only starts the same stays text", async () => {
    type(editor, " [[Plann]] [[Planning]]");
    await tick(10);
    assert.equal(textOf(editor, "p1"), "Start Plan Ærlig talt [[Plann]] [[Planning]]");
  });

  await check("undo after the link lands brings back the typed brackets", async () => {
    editor.commands.setContent(editor.getJSON());
    caret(editor, endOf(editor, 0));
    type(editor, " [[Plan]]");
    await tick(10);
    assert.ok(textOf(editor, "p1").endsWith(" Plan"));
    editor.commands.undo();
    assert.ok(textOf(editor, "p1").endsWith(" [[Plan]]"), textOf(editor, "p1"));
    await tick(10);
    assert.ok(textOf(editor, "p1").endsWith(" [[Plan]]"), "undo is not re-linked");
  });

  await check("[[Plan]] typed inside inline code stays text", async () => {
    let at = 0;
    editor.state.doc.descendants((n, p) => { if (n.isText && n.marks.some((m) => m.type.name === "code")) at = p + 1; });
    caret(editor, at);
    type(editor, "[[Plan]]");
    await tick(10);
    assert.equal(textOf(editor, "p2"), "Code x[[Plan]]");
  });

  await check("a paste of [[Plan]], plain, HTML or multi-line, stays text and asks nothing", async () => {
    caret(editor, endOf(editor, 0));
    asked.length = 0;
    paste(editor, " see [[plan]] and [[Plan]].");
    paste(editor, "", "<p> go [[Plan]] now</p>");
    paste(editor, " one [[Plan]]\ntwo [[plan]]");
    await tick(10);
    const p1 = textOf(editor, "p1");
    assert.ok(p1.endsWith(" see [[plan]] and [[Plan]].go [[Plan]] now one [[Plan]]two [[plan]]"), p1);
    assert.deepEqual(asked, []);
  });

  await check("Mod+Enter on plain text edits nothing, emits nothing, and stays free for the host", async () => {
    canvas.flushPendingChanges();
    await tick(350);
    ops.length = 0;
    const before = JSON.stringify(editor.getJSON());
    caret(editor, 3);
    for (const mod of [{ metaKey: true }, { ctrlKey: true }]) {
      const ev = key(editor, { key: "Enter", ...mod });
      assert.equal(ev.defaultPrevented, false, "the host sees a free key");
      assert.equal(newline(editor).defaultPrevented, true, "the browser's own newline is held back");
      assert.equal(newline(editor, "insertLineBreak").defaultPrevented, false, "only the one right after it");
    }
    assert.equal(JSON.stringify(editor.getJSON()), before);
    canvas.flushPendingChanges();
    await tick(350);
    assert.deepEqual(ops, []);
  });

  await check("Mod+Enter on a dead link edits nothing", async () => {
    canvas.wikilinkResolve = (id) => (id === "n-gone" ? { missing: true } : null);
    await tick(10);
    assert.ok(canvas.querySelector("span[data-wikilink][data-missing]"));
    const before = JSON.stringify(editor.getJSON());
    let at = 0;
    editor.state.doc.descendants((n, p) => { if (n.isText && n.text === "Gone") at = p + 2; });
    caret(editor, at);
    key(editor, { key: "Enter", metaKey: true });
    newline(editor, "insertLineBreak");
    assert.equal(JSON.stringify(editor.getJSON()), before);
    assert.equal(textOf(editor, "p3"), "Dead Gone end.");
  });

  await check("Mod+Enter inside a link neither splits it nor adds a line", async () => {
    const before = JSON.stringify(editor.getJSON());
    let at = 0;
    editor.state.doc.descendants((n, p) => { if (!at && n.isText && n.marks.some((m) => m.type.name === "wikilink") && n.text === "Plan") at = p + 2; });
    assert.ok(at);
    caret(editor, at);
    for (const mod of [{ metaKey: true }, { ctrlKey: true }]) {
      key(editor, { key: "Enter", ...mod });
      newline(editor);
    }
    assert.equal(JSON.stringify(editor.getJSON()), before);
  });

  await check("a host that takes Mod+Enter gets it; the browser makes no newline either way", async () => {
    let seen = 0;
    const take = (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { seen += 1; e.preventDefault(); } };
    canvas.addEventListener("keydown", take);
    const ev = key(editor, { key: "Enter", ctrlKey: true });
    canvas.removeEventListener("keydown", take);
    assert.equal(seen, 1);
    assert.equal(ev.defaultPrevented, true);
  });

  await check("a composing Mod+Enter holds nothing back, and the hold is only for a newline", async () => {
    await tick(5);
    key(editor, { key: "Enter", metaKey: true, isComposing: true });
    assert.equal(newline(editor).defaultPrevented, false, "an IME's Enter is the IME's");
    await tick(5);
    key(editor, { key: "Enter", metaKey: true });
    assert.equal(newline(editor, "insertText").defaultPrevented, false, "text input is not held");
    assert.equal(newline(editor).defaultPrevented, true);
  });

  await check("Enter, Shift+Enter and a stray newline input still work", async () => {
    await tick(5);
    assert.equal(newline(editor).defaultPrevented, false, "no Mod+Enter, no hold");
    caret(editor, 3);
    const before = editor.state.doc.childCount;
    key(editor, { key: "Enter", shiftKey: true });
    assert.equal(editor.state.doc.child(0).content.content.some((n) => n.type.name === "hardBreak"), true, "Shift+Enter is a soft break");
    key(editor, { key: "Enter" });
    assert.equal(editor.state.doc.childCount, before + 1, "Enter splits");
  });

  canvas.remove();
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
}

await check("no source, a throwing source, a rejecting one, an odd answer or a row with no id: the text stays", async () => {
  for (const source of [null, () => { throw new Error("sync"); }, () => Promise.reject(new Error("async")), () => ({ title: "Plan", id: "n-plan" }), () => [{ title: "Plan" }], () => [null, { title: "Plan", id: "" }]]) {
    const { canvas, editor } = await mount({ source });
    caret(editor, endOf(editor, 0));
    type(editor, "[[Plan]]");
    await tick(10);
    assert.equal(textOf(editor, "p1"), "Start [[Plan]]", String(source));
    canvas.remove();
  }
});

await check("an edit to the brackets before the answer lands keeps the text; an edit elsewhere does not stop it", async () => {
  const pending = [];
  const { canvas, editor } = await mount({ source: (q) => (q === "Plan" ? new Promise((r) => pending.push(() => r(ROWS))) : []) });
  caret(editor, endOf(editor, 0));
  type(editor, "[[Plan]]");
  editor.view.dispatch(editor.state.tr.delete(endOf(editor, 0) - 1, endOf(editor, 0)));
  pending.splice(0).forEach((release) => release());
  await tick(10);
  assert.equal(textOf(editor, "p1"), "Start [[Plan]");
  type(editor, "]");
  const p = endOf(editor, 0) - 3;
  editor.view.dispatch(editor.state.tr.insertText("t", p, p + 1));
  pending.splice(0).forEach((release) => release());
  await tick(10);
  assert.equal(textOf(editor, "p1"), "Start [[Plat]]", "the same length, other words: still text");
  editor.view.dispatch(editor.state.tr.insertText("n", p, p + 1));
  editor.view.dispatch(editor.state.tr.delete(endOf(editor, 0) - 1, endOf(editor, 0)));
  type(editor, "]");
  editor.view.dispatch(editor.state.tr.insertText("Now ", 1));
  pending.splice(0).forEach((release) => release());
  await tick(10);
  assert.equal(textOf(editor, "p1"), "Now Start Plan");
  canvas.remove();
});

await check("an answer that lands after the canvas is gone is dropped", async () => {
  let release;
  const { canvas, editor } = await mount({ source: () => new Promise((r) => { release = r; }) });
  caret(editor, endOf(editor, 0));
  type(editor, "[[Plan]]");
  canvas.remove();
  await tick(10);
  release(ROWS);
  await tick(10);
});

await check("a slow answer is asked for once while other edits land, and one that lands after the canvas turns read-only writes nothing", async () => {
  const waiting = [];
  const { canvas, editor, ops, asked } = await mount({ source: () => new Promise((r) => { waiting.push(r); }) });
  caret(editor, endOf(editor, 0));
  type(editor, "[[Plan]]");
  assert.equal(asked.at(-1), "Plan");
  asked.length = 0;
  type(editor, " and more");
  await tick(10);
  assert.deepEqual(asked, [], "the pending [[Plan]] is not asked again");
  canvas.flushPendingChanges();
  await tick(350);
  ops.length = 0;
  canvas.setAttribute("editable", "false");
  await tick(10);
  waiting.forEach((release) => release(ROWS));
  await tick(10);
  assert.equal(textOf(editor, "p1"), "Start [[Plan]] and more");
  canvas.flushPendingChanges();
  await tick(350);
  assert.deepEqual(ops, []);
  canvas.remove();
});

await check("[[Plan]] from a seed or the server is never linked or asked", async () => {
  const seeded = [{ id: "p1", type: "paragraph", content: [{ type: "text", value: "Seed [[Plan]]" }] }];
  const { canvas, editor, asked, ops } = await mount({ blocks: seeded });
  canvas.applyServerBlocks([{ id: "p1", type: "paragraph", content: [{ type: "text", value: "Server [[Plan]] and [[Plan]]" }] }]);
  await tick(10);
  assert.equal(textOf(editor, "p1"), "Server [[Plan]] and [[Plan]]");
  assert.deepEqual(asked, []);
  canvas.flushPendingChanges();
  await tick(350);
  assert.deepEqual(ops, []);
  canvas.remove();
});

await check("the picker is shut once the brackets close", async () => {
  const { canvas, editor } = await mount();
  caret(editor, endOf(editor, 0));
  type(editor, "[[Pla");
  await tick(10);
  assert.equal(canvas._wikilink && canvas._wikilink.isOpen(), true, "the picker opened");
  type(editor, "n]]");
  await tick(10);
  assert.equal(canvas._wikilink.isOpen(), false);
  assert.equal(textOf(editor, "p1"), "Start Plan");
  canvas.remove();
});

await check("a linked [[Plan]] paints its live title", async () => {
  const { canvas, editor } = await mount();
  canvas.wikilinkResolve = (id) => (id === "n-plan" ? { title: "Roadmap" } : null);
  caret(editor, endOf(editor, 0));
  type(editor, "[[Plan]]");
  await tick(10);
  assert.equal(canvas.querySelector(".bp-wikilink-label")?.textContent, "Roadmap");
  assert.equal(blockOf(editor, "p1").content.find((c) => c.type === "wikilink").children[0].value, "Plan");
  canvas.remove();
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\nwikilink input and keys mounted: all checks passed");
process.exit(0);
