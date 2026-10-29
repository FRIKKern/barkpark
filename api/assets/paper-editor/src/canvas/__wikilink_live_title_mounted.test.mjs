// __wikilink_live_title_mounted.test.mjs — contract 1.17.0: a document link's words come live
// from the host, and a target the host says is gone is marked.
//
// `wikilinkResolve(docId)` paints an un-aliased link (no alias, words equal to its stored target)
// with the target's current title; setting it again after a rename repaints every such link and
// the stored body stays byte-identical (no op, and a save of the block for another reason still
// carries the stored words). Aliased links and links over the author's own words keep them.
// `{ missing: true }` from wikilinkResolve or linkPreviewSource marks the link
// (`data-missing`) and hides Open on the hover card and the pill.
// Run: node src/canvas/__wikilink_live_title_mounted.test.mjs   (or: npm test)
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

const link = (target, docId, words = target, extra = {}) => ({ type: "wikilink", target, docId, ...extra, children: [{ type: "text", value: words }] });
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "See " }, link("Plan", "n-plan"), { type: "text", value: " and " }, link("Gone note", "n-gone"), { type: "text", value: " end." }] },
  { id: "p2", type: "paragraph", content: [link("Plan", "n-plan", "the plan", { alias: "the plan" }), { type: "text", value: " is aliased." }] },
  { id: "p3", type: "paragraph", content: [{ type: "text", value: "Written by " }, link("n-ada", "n-ada", "our author"), { type: "text", value: "." }] },
  { id: "p4", type: "paragraph", content: [{ type: "text", value: "Typed " }, { type: "wikilink", target: "Plan", children: [{ type: "text", value: "Plan" }] }, { type: "text", value: " here." }] },
  { id: "p5", type: "paragraph", content: [{ type: "text", value: "Again " }, link("Plan", "n-plan"), { type: "text", value: "." }] },
  { id: "p6", type: "paragraph", content: [{ type: "text", value: "Named " }, link("Plan", "n-plan", "Plan", { alias: "Plan" }), { type: "text", value: "." }] },
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

async function mount({ blocks = BLOCKS, titles, cards = false, editable = true, preview } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  if (cards) canvas.setAttribute("block-cards", "");
  if (!editable) canvas.setAttribute("editable", "false");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  if (titles) canvas.wikilinkResolve = asAnswer(titles);
  if (preview) canvas.linkPreviewSource = preview;
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  document.body.appendChild(canvas);
  await tick(350);
  return { canvas, editor: canvas._editor, ops };
}

const asAnswer = (fn) => (id) => {
  const v = fn(id);
  return typeof v === "string" ? { title: v } : v;
};
const block = (canvas, id) => canvas.querySelector(`[data-bp-id="${id}"]`);
const shown = (el) => {
  const copy = el.cloneNode(true);
  copy.querySelectorAll('[style*="display: none"]').forEach((n) => n.remove());
  return copy.textContent;
};
const stored = (editor) => docToBlocks(editor.getJSON());
const posOf = (editor, word, offset = 0) => {
  let at = null;
  editor.state.doc.descendants((n, p) => { if (at == null && n.isText && n.text.includes(word)) at = p + n.text.indexOf(word) + offset; return at == null; });
  return at;
};
const caret = (editor, pos) => editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, pos)));
const key = (editor, k, opts = {}) => editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts }));
const cardOpen = (canvas) => {
  const card = canvas._linkPreview.el;
  return card && card.style.display !== "none" ? card.querySelector(".bp-link-preview__open").style.display !== "none" : null;
};
const linkEl = (canvas, docId, i = 0) => canvas.querySelectorAll(`span[data-wikilink][docid="${docId}"]`)[i];

try {
  const titles = { "n-plan": "Roadmap", "n-ada": "Ada Lovelace" };
  const calls = [];
  const { canvas, editor, ops } = await mount({ titles: (id) => { calls.push(id); return titles[id] ?? null; } });

  await check("an un-aliased link paints the host's title; its stored words are hidden, not removed", () => {
    assert.equal(shown(block(canvas, "p1")), "See Roadmap and Gone note end.");
    assert.equal(shown(block(canvas, "p5")), "Again Roadmap.");
    assert.equal(block(canvas, "p1").querySelector(".bp-wikilink-label").closest("span[data-wikilink]").getAttribute("docid"), "n-plan", "the label sits inside the link");
    assert.equal(editor.state.doc.textContent.includes("Plan"), true, "the document still holds the stored words");
  });

  await check("an aliased link, a link over the author's own words, and a link with no docId keep their words", () => {
    assert.equal(shown(block(canvas, "p2")), "the plan is aliased.");
    assert.equal(shown(block(canvas, "p3")), "Written by our author.");
    assert.equal(shown(block(canvas, "p4")), "Typed Plan here.");
    assert.equal(shown(block(canvas, "p6")), "Named Plan.", "an alias equal to the target is still the author's");
  });

  await check("each document id is asked once", () => {
    assert.deepEqual([...calls].sort(), ["n-ada", "n-gone", "n-plan"]);
  });

  await check("a rename repaints every un-aliased link; the stored body stays byte-identical and nothing is emitted", async () => {
    const before = canonical(stored(editor));
    titles["n-plan"] = "Roadmap 2027";
    calls.length = 0;
    canvas.refreshWikilinks();
    await tick(20);
    assert.equal(shown(block(canvas, "p1")), "See Roadmap 2027 and Gone note end.");
    assert.equal(shown(block(canvas, "p5")), "Again Roadmap 2027.");
    assert.equal(shown(block(canvas, "p2")), "the plan is aliased.", "the alias stays");
    assert.equal(canonical(stored(editor)), before);
    assert.equal(canonical(stored(editor)), canonical(BLOCKS));
    canvas.flushPendingChanges();
    await tick(350);
    assert.deepEqual(ops, [], "a repaint is not an edit");
    assert.deepEqual([...calls].sort(), ["n-ada", "n-gone", "n-plan"], "asked again");
  });

  await check("an edit elsewhere in the block saves the stored words, not the painted title", async () => {
    editor.view.dispatch(editor.state.tr.insertText("!", posOf(editor, " end.") + 5));
    canvas.flushPendingChanges();
    await tick(350);
    const op = ops.find((o) => o.id === "p1");
    assert.ok(op, JSON.stringify(ops));
    const content = op.patch ? op.patch.content : op.block.content;
    assert.equal(canonical(content[1]), canonical(link("Plan", "n-plan")));
    assert.equal(JSON.stringify(op).includes("Roadmap"), false);
    ops.length = 0;
  });

  await check("a caret inside a painted link shows its stored words; leaving repaints", () => {
    editor.commands.focus();
    caret(editor, posOf(editor, "Plan", 2));
    assert.equal(shown(block(canvas, "p1")), "See Plan and Gone note end.!");
    caret(editor, posOf(editor, "See", 1));
    assert.equal(shown(block(canvas, "p1")), "See Roadmap 2027 and Gone note end.!");
  });

  await check("arrows step over a painted link", () => {
    const from = posOf(editor, "Plan");
    const to = from + 4;
    caret(editor, to);
    key(editor, "ArrowLeft");
    assert.equal(editor.state.selection.head, from);
    key(editor, "ArrowRight");
    assert.equal(editor.state.selection.head, to);
    key(editor, "ArrowLeft", { shiftKey: true });
    assert.deepEqual([editor.state.selection.anchor, editor.state.selection.head], [to, from], "Shift extends over it");
    caret(editor, from - 1);
    const ev = new window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true });
    editor.view.dom.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, false, "a step that ends at its edge is the browser's");
  });

  await check("Backspace at its end and Delete at its start remove the whole link, one undo brings it back", async () => {
    const from = posOf(editor, "Plan");
    caret(editor, from + 4);
    key(editor, "Backspace");
    assert.equal(shown(block(canvas, "p1")), "See  and Gone note end.!");
    editor.commands.undo();
    assert.equal(shown(block(canvas, "p1")), "See Roadmap 2027 and Gone note end.!");
    caret(editor, from);
    key(editor, "Delete");
    assert.equal(shown(block(canvas, "p1")), "See  and Gone note end.!");
    editor.commands.undo();
    assert.equal(canonical(stored(editor)[0].content[1]), canonical(link("Plan", "n-plan")));
    canvas.flushPendingChanges();
    await tick(350);
    ops.length = 0;
  });

  await check("an unpainted link keeps the browser's keys", () => {
    const from = posOf(editor, "Gone note");
    caret(editor, from + 9);
    const ev = new window.KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true });
    editor.view.dom.dispatchEvent(ev);
    assert.equal(shown(block(canvas, "p1")).includes("Gone note"), true);
  });

  await check("a link added later is asked and painted", async () => {
    calls.length = 0;
    titles["n-new"] = "New title";
    caret(editor, posOf(editor, "Written by ") + 11);
    editor.view.dispatch(editor.state.tr.insertText("Plan", editor.state.selection.from).addMark(
      editor.state.selection.from, editor.state.selection.from + 4,
      editor.schema.marks.wikilink.create({ target: "Plan", docId: "n-new" }),
    ));
    await tick(20);
    assert.deepEqual(calls, ["n-new"]);
    assert.equal(shown(block(canvas, "p3")), "Written by New titleour author.");
    editor.commands.undo();
    canvas.flushPendingChanges();
    await tick(350);
    ops.length = 0;
  });

  await check("unset, the stored words come back", async () => {
    canvas.wikilinkResolve = null;
    await tick(20);
    assert.equal(shown(block(canvas, "p1")), "See Plan and Gone note end.!");
    assert.equal(canvas.querySelectorAll(".bp-wikilink-label").length, 0);
    canvas.wikilinkResolve = asAnswer((id) => titles[id] ?? null);
    await tick(20);
    assert.equal(shown(block(canvas, "p1")), "See Roadmap 2027 and Gone note end.!");
  });

  await check("a re-seed of the blocks paints the new run", async () => {
    canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
    await tick(20);
    assert.equal(shown(canvas._editor.view.dom.querySelector('[data-bp-id="p1"]')), "See Roadmap 2027 and Gone note end.");
  });

  canvas.remove();
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
}

await check("a Promise answer paints; a throwing or rejecting source keeps the stored words and the canvas mounts", async () => {
  const sources = {
    "n-plan": () => { throw new Error("sync"); },
    "n-gone": () => Promise.resolve({ title: "Gone, renamed" }),
    "n-ada": () => Promise.reject(new Error("async")),
  };
  const { canvas } = await mount({ titles: (id) => sources[id]() });
  await tick(20);
  assert.equal(canvas.hasAttribute("data-mount-failed"), false);
  assert.equal(shown(block(canvas, "p1")), "See Plan and Gone, renamed end.");
  assert.equal(shown(block(canvas, "p3")), "Written by our author.");
  canvas.remove();
});

await check("odd answers keep the stored words; a title is text, never markup", async () => {
  const answers = { "n-plan": { title: "<img src=x onerror=alert(1)>" }, "n-gone": 42, "n-ada": { title: "" } };
  const { canvas } = await mount({ titles: (id) => answers[id] });
  await tick(20);
  assert.equal(shown(block(canvas, "p1")), "See <img src=x onerror=alert(1)> and Gone note end.");
  assert.equal(!!canvas.querySelector("img"), false);
  for (const odd of ["Plan renamed", "", 0, [], { title: 7 }, { missing: "yes" }, true]) {
    canvas.wikilinkResolve = () => odd;
    await tick(20);
    assert.equal(shown(block(canvas, "p1")), "See Plan and Gone note end.", JSON.stringify(odd));
  }
  canvas.remove();
});

await check("an answer that lands after the canvas is gone is dropped", async () => {
  let release;
  const { canvas } = await mount({ titles: (id) => (id === "n-plan" ? new Promise((r) => { release = r; }) : null) });
  canvas.remove();
  await tick(20);
  release({ title: "Too late" });
  await tick(20);
  assert.equal(canvas.querySelectorAll(".bp-wikilink-label").length, 0);
});

await check("an answer from before the last refresh is dropped", async () => {
  let release;
  const { canvas } = await mount({ titles: (id) => (id === "n-plan" ? new Promise((r) => { release = () => r({ title: "Old answer" }); }) : null) });
  const late = release;
  canvas.wikilinkResolve = (id) => (id === "n-plan" ? { title: "Fresh" } : null);
  await tick(20);
  late();
  await tick(20);
  assert.equal(shown(block(canvas, "p1")), "See Fresh and Gone note end.");
  canvas.remove();
});

await check("set before the element upgrades, it is reclaimed", async () => {
  const tpl = document.createElement("template");
  tpl.innerHTML = "<bp-paper-canvas></bp-paper-canvas>";
  const el = tpl.content.firstChild;
  el.wikilinkResolve = () => ({ title: "Early" });
  el.blocks = JSON.parse(JSON.stringify(BLOCKS));
  document.body.appendChild(document.adoptNode(el));
  await tick(350);
  assert.equal(typeof Object.getOwnPropertyDescriptor(el, "wikilinkResolve"), "undefined", "the own property gave way to the setter");
  assert.equal(shown(block(el, "p1")), "See Early and Early end.");
  el.remove();
});

await check("a link that arrives from the server is asked and painted, and nothing is emitted", async () => {
  const { canvas, ops } = await mount({ titles: (id) => ({ "n-plan": "Roadmap", "n-srv": "From the server" })[id] ?? null });
  await tick(20);
  const next = JSON.parse(JSON.stringify(BLOCKS));
  next[1] = { id: "p2", type: "paragraph", content: [{ type: "text", value: "Remote " }, link("Old", "n-srv"), { type: "text", value: "." }] };
  canvas.applyServerBlocks(next);
  await tick(20);
  assert.equal(shown(block(canvas, "p2")), "Remote From the server.");
  canvas.flushPendingChanges();
  await tick(350);
  assert.deepEqual(ops, []);
  canvas.remove();
});

await check("two canvases on one page keep their own titles and marks", async () => {
  const a = await mount({ titles: (id) => (id === "n-plan" ? "Title A" : null) });
  const b = await mount({ titles: (id) => (id === "n-plan" ? "Title B" : id === "n-gone" ? { missing: true } : null) });
  await tick(20);
  assert.equal(shown(block(a.canvas, "p1")), "See Title A and Gone note end.");
  assert.equal(shown(block(b.canvas, "p1")), "See Title B and Gone note end.");
  assert.equal(a.canvas.querySelectorAll("[data-missing]").length, 0);
  assert.equal(b.canvas.querySelectorAll("[data-missing]").length, 1);
  a.canvas.remove();
  b.canvas.remove();
});

await check("read mode paints too", async () => {
  const { canvas } = await mount({ editable: false, titles: (id) => (id === "n-plan" ? "Roadmap" : null) });
  await tick(20);
  assert.equal(shown(block(canvas, "p1")), "See Roadmap and Gone note end.");
  canvas.remove();
});

await check("removed and appended again, it still paints", async () => {
  const { canvas } = await mount({ titles: (id) => (id === "n-plan" ? "Roadmap" : null) });
  canvas.remove();
  document.body.appendChild(canvas);
  await tick(350);
  assert.equal(shown(block(canvas, "p1")), "See Roadmap and Gone note end.");
  canvas.remove();
});

await check("a deleted target ({ missing: true } from wikilinkResolve) is marked and keeps its words; recreated, it paints again", async () => {
  const state = { "n-gone": { missing: true } };
  const { canvas } = await mount({ titles: (id) => state[id] ?? null });
  await tick(20);
  const gone = linkEl(canvas, "n-gone");
  assert.ok(gone.querySelector("[data-missing]"), gone.outerHTML);
  assert.equal(shown(block(canvas, "p1")), "See Plan and Gone note end.");
  assert.equal(!!linkEl(canvas, "n-plan").querySelector("[data-missing]"), false);
  canvas._linkPreview.showFor(gone);
  assert.equal(cardOpen(canvas), false, "the card knows it is gone with no linkPreviewSource");
  canvas._linkPreview.hide();
  state["n-gone"] = "Gone note, back";
  canvas.refreshWikilinks();
  await tick(20);
  assert.equal(!!linkEl(canvas, "n-gone").querySelector("[data-missing]"), false);
  assert.equal(shown(block(canvas, "p1")), "See Plan and Gone note, back end.");
  canvas.remove();
});


for (const cards of [false, true]) {
  const where = cards ? "the pill" : "the hover card";
  await check(`linkPreviewSource { missing: true } hides Open on ${where} and marks the link`, async () => {
    const gone = new Set(["n-gone"]);
    const { canvas, ops } = await mount({ cards, preview: ({ docId }) => (gone.has(docId) ? { missing: true } : { title: "There" }) });
    assert.equal(canvas._linkPreview.showFor(linkEl(canvas, "n-plan")), true);
    await tick(10);
    assert.equal(cardOpen(canvas), true, "a target that is there keeps Open");
    canvas._linkPreview.hide();
    canvas._linkPreview.showFor(linkEl(canvas, "n-gone"));
    await tick(10);
    assert.equal(cardOpen(canvas), false, "Open hides");
    for (const part of ["edit", "remove"]) {
      assert.equal(canvas._linkPreview.el.querySelector(`.bp-link-preview__${part}`).style.display, "", `${part} stays`);
    }
    assert.ok(linkEl(canvas, "n-gone").querySelector("[data-missing]"), "the span is marked");
    assert.equal(!!linkEl(canvas, "n-plan").querySelector("[data-missing]"), false);
    canvas._linkPreview.hide();
    canvas._linkPreview.showFor(linkEl(canvas, "n-gone"));
    assert.equal(cardOpen(canvas), false, "known gone: Open is hidden before the answer lands");
    gone.delete("n-gone");
    canvas._linkPreview.hide();
    canvas._linkPreview.showFor(linkEl(canvas, "n-gone"));
    await tick(10);
    assert.equal(cardOpen(canvas), true, "recreated: Open comes back");
    assert.equal(!!linkEl(canvas, "n-gone").querySelector("[data-missing]"), false, "and the mark goes");
    canvas.flushPendingChanges();
    await tick(350);
    assert.deepEqual(ops, [], "marking is not an edit");
    canvas._linkPreview.hide();
    canvas.remove();
  });
}

for (const cards of [false, true]) await check(`an async { missing: true } marks too; no answer leaves the link as it was (${cards ? "pill" : "card"})`, async () => {
  let answer = Promise.resolve({ missing: true });
  const { canvas } = await mount({ cards, preview: () => answer });
  canvas._linkPreview.showFor(linkEl(canvas, "n-gone"));
  await tick(10);
  assert.equal(cardOpen(canvas), false);
  assert.ok(linkEl(canvas, "n-gone").querySelector("[data-missing]"));
  canvas._linkPreview.hide();
  answer = Promise.resolve(null);
  canvas._linkPreview.showFor(linkEl(canvas, "n-gone"));
  await tick(10);
  assert.ok(linkEl(canvas, "n-gone").querySelector("[data-missing]"), "null says nothing new");
  canvas._linkPreview.hide();
  answer = Promise.reject(new Error("x"));
  canvas._linkPreview.showFor(linkEl(canvas, "n-gone"));
  await tick(10);
  assert.ok(linkEl(canvas, "n-gone").querySelector("[data-missing]"), "a rejection says nothing new");
  canvas._linkPreview.hide();
  canvas.remove();
});

await check("a link with no docId is marked by its target, and only links with that target", async () => {
  const { canvas } = await mount({ preview: ({ docId, target }) => (!docId && target === "Plan" ? { missing: true } : { title: "There" }) });
  canvas._linkPreview.showFor(block(canvas, "p4").querySelector("span[data-wikilink]"));
  await tick(10);
  assert.equal(cardOpen(canvas), false);
  assert.ok(block(canvas, "p4").querySelector("[data-missing]"));
  assert.equal(canvas.querySelectorAll("[data-missing]").length, 1, "the docId links with the same target stay unmarked");
  canvas._linkPreview.hide();
  canvas.remove();
});

await check("find and state() read the stored words", async () => {
  const { canvas, editor } = await mount({ titles: (id) => (id === "n-plan" ? "Roadmap" : null) });
  await tick(20);
  assert.equal(canvas.findSet("Roadmap").count, 0);
  assert.equal(canvas.findSet("Plan").count > 0, true);
  canvas.findClear();
  editor.commands.focus();
  caret(editor, posOf(editor, "Plan") + 2);
  assert.deepEqual(canvas.state().wikilink, { target: "Plan", docId: "n-plan" });
  canvas.remove();
});

await check("a plain link's card keeps Open whatever the source says", async () => {
  const blocks = [{ id: "p1", type: "paragraph", content: [{ type: "link", href: "https://example.com/", children: [{ type: "text", value: "site" }] }] }];
  const { canvas } = await mount({ blocks, preview: () => ({ missing: true }) });
  canvas._linkPreview.showFor(canvas.querySelector("a[href]"));
  await tick(10);
  assert.equal(cardOpen(canvas), true);
  canvas._linkPreview.hide();
  canvas.remove();
});

await check("the card names a renamed target by its live title", async () => {
  const { canvas } = await mount({ titles: (id) => (id === "n-plan" ? "Roadmap" : null) });
  await tick(20);
  canvas._linkPreview.showFor(linkEl(canvas, "n-plan", 1));
  const card = canvas._linkPreview.el;
  assert.equal(card.querySelector(".bp-link-preview__title").textContent, "the plan → Roadmap");
  canvas._linkPreview.hide();
  canvas._linkPreview.showFor(linkEl(canvas, "n-plan"));
  assert.equal(card.querySelector(".bp-link-preview__title").textContent, "Roadmap");
  assert.equal(card.querySelector(".bp-link-preview__addr").textContent, "[[Roadmap]]");
  canvas._linkPreview.hide();
  canvas.remove();
});

await check("at 160 paragraphs a keystroke repaints in under a frame, or under 4x bare on a loaded machine", async () => {
  const many = Array.from({ length: 160 }, (_, i) => ({ id: `m${i}`, type: "paragraph", content: [{ type: "text", value: `Row ${i} links ` }, link("Plan", "n-plan"), { type: "text", value: " and " }, link(`Note ${i}`, `n-${i}`), { type: "text", value: " here." }] }));
  const time = async (titles) => {
    const { canvas, editor } = await mount({ blocks: many, titles });
    await tick(50);
    const painted = canvas.querySelectorAll(".bp-wikilink-label").length;
    const at = posOf(editor, "Row 80") + 3;
    const times = [];
    for (let i = 0; i < 60; i++) {
      const t0 = performance.now();
      editor.view.dispatch(editor.state.tr.insertText("x", at));
      times.push(performance.now() - t0);
    }
    const each = times.sort((a, b) => a - b)[30];
    canvas.remove();
    return { painted, each };
  };
  const bare = await time(null);
  const live = await time((id) => `Title of ${id}`);
  console.log(`      ${live.each.toFixed(2)} ms per keystroke with 320 painted links, ${bare.each.toFixed(2)} ms with none (median, jsdom)`);
  assert.equal(live.painted, 320);
  assert.equal(bare.painted, 0);
  assert.ok(live.each < Math.max(16, bare.each * 4), `${live.each} ms painted, ${bare.each} ms bare`);
});

if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\nwikilink live title mounted: all checks passed");
process.exit(0);
