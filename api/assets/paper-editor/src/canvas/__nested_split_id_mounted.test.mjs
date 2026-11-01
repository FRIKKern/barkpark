// task-42d085f7431b8417: Enter inside a container's paragraph or heading (section,
// expandable, step, tab) split it into two children carrying the SAME id (a paste of
// a paragraph that carries an id already in the doc did the same). The canvas
// sent the container with the repeated id, Patch refused it (duplicate_id), and the
// refused batch stayed in flight with every later keystroke
// queued behind it: nothing typed after the Enter reached the server.
//
// Mounted: the real <bp-paper-canvas>, a real Enter keydown, typing through
// handleTextInput. Every batch folds through the patch.ex reference fold (applyOps)
// with a whole-tree duplicate check, the client's after-state equals the fold, a fresh
// canvas mounted on the folded blocks (the reload) shows every typed character, and
// the minted id is written back so the next batch does not mint it again.
//
// The same holds for every other way a copy or a move of a block lands across depths
// (review of #25040): a copy above its original, a paste into a column or a section,
// a nested paragraph moved to the top level, a doc that already repeats an id. The
// original keeps its id, and the live doc never carries an id the server lacks.
//
// The batches are recorded, minted ids normalised, into
// api/test/support/fixtures/paper-editor/nested_split.json; patch_nested_split_test.exs
// folds that file through Patch and the canvas batch write. NESTED_SPLIT_WRITE=1
// rewrites it.
//
// Run: node src/canvas/__nested_split_id_mounted.test.mjs

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
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
const { applyOps } = await import("../smoke/harness.mjs");
const { TextSelection } = await import("@tiptap/pm/state");
const { Fragment, Slice } = await import("@tiptap/pm/model");

const FIXTURE = new URL("../../../../test/support/fixtures/paper-editor/nested_split.json", import.meta.url);
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const clone = (value) => JSON.parse(JSON.stringify(value));
const p = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });

function ids(blocks, out = []) {
  for (const block of blocks || []) {
    if (block.id != null) out.push(block.id);
    for (const key of ["blocks", "children", "steps", "tabs"]) ids(block[key], out);
  }
  return out;
}
function repeated(list) {
  return [...new Set(list.filter((id, i) => list.indexOf(id) !== i))];
}
function words(blocks, out = []) {
  for (const block of blocks || []) {
    if (Array.isArray(block.content)) out.push(block.content.map((n) => n.value || "").join(""));
    else if (typeof block.text === "string") out.push(block.text);
    for (const key of ["blocks", "children", "steps", "tabs"]) words(block[key], out);
  }
  return out;
}
function idOf(blocks, text) {
  for (const block of blocks || []) {
    const own = Array.isArray(block.content) ? block.content.map((n) => n.value || "").join("") : block.text;
    if (own === text) return block.id;
    for (const key of ["blocks", "children", "steps", "tabs"]) {
      const found = idOf(block[key], text);
      if (found) return found;
    }
  }
  return null;
}
function lines(editor) {
  const out = [];
  editor.state.doc.descendants((node) => { if (node.isTextblock) out.push(node.textContent); });
  return out;
}
function liveIds(editor) {
  const out = [];
  editor.state.doc.descendants((node) => { if (!node.isText && node.attrs.bpId != null) out.push(node.attrs.bpId); });
  return out;
}
function caretAfter(editor, text) {
  let at = null;
  editor.state.doc.descendants((node, pos) => {
    if (at == null && node.isText && node.text.includes(text)) at = pos + node.text.indexOf(text) + text.length;
  });
  assert.notEqual(at, null, `"${text}" is in the doc`);
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, at)));
}
function enter(editor) {
  editor.view.dom.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
}
function type(editor, chars) {
  const { view } = editor;
  for (const char of chars) {
    const { from, to } = view.state.selection;
    if (!view.someProp("handleTextInput", (f) => f(view, from, to, char))) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}

function fold(blocks, ops) {
  const next = applyOps(blocks, ops);
  assert.deepEqual(repeated(ids(next)), [], `no block id repeats after ${JSON.stringify(ops.map((op) => op.op))}`);
  return next;
}

function paste(editor, html, plain) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { types: ["text/html", "text/plain"], getData: (t) => (t === "text/html" ? html : plain), files: [] },
  });
  editor.view.dom.dispatchEvent(event);
}
const COPIES = (id) => `<p data-bp-id="${id}" data-bp-type="paragraph">Copied one.</p><p data-bp-id="${id}" data-bp-type="paragraph">Copied two.</p>`;
function textblockAt(doc, text) {
  let found = null;
  doc.descendants((node, pos) => { if (!found && node.isTextblock && node.textContent === text) found = { node, pos }; });
  assert.ok(found, `a line reads "${text}"`);
  return found;
}
// What a drop leaves when its slice kept the ids: `copy` inserts the block again
// before the line `before`, otherwise the block moves there.
function place(editor, text, before, { copy }) {
  const { node, pos } = textblockAt(editor.state.doc, text);
  let tr = editor.state.tr;
  if (!copy) tr = tr.delete(pos, pos + node.nodeSize);
  tr = tr.replaceRange(textblockAt(tr.doc, before).pos, textblockAt(tr.doc, before).pos, new Slice(Fragment.from(node), 0, 0));
  editor.view.dispatch(tr);
}

async function mount(blocks, host) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = clone(blocks);
  canvas.addEventListener("bp-canvas-ops", (event) => host(canvas, event.detail));
  document.body.appendChild(canvas);
  await tick(350);
  return canvas;
}

async function saved(canvas) {
  canvas.flushPendingChanges();
  await tick(350);
}

async function reloaded(blocks) {
  const fresh = await mount(blocks, () => assert.fail("a fresh mount sends nothing"));
  const seen = lines(fresh._editor);
  fresh.remove();
  return seen;
}

const SCENES = [
  {
    name: "section",
    blocks: [
      { id: "h-trip", type: "heading", level: 2, text: "Trip" },
      { id: "s-day", type: "section", title: "Day one", blocks: [p("p-day", "Left at six."), p("p-two", "Fog.")] },
      p("p-after", "Home."),
    ],
  },
  {
    name: "expandable",
    blocks: [{ id: "x-more", type: "expandable", summary: "Details", blocks: [p("p-day", "Left at six."), p("p-two", "Fog.")] }],
  },
  {
    name: "steps",
    blocks: [{ id: "st-walk", type: "steps", steps: [
      { id: "r-one", title: "First", blocks: [p("p-day", "Left at six.")] },
      { id: "r-two", title: "Second", blocks: [p("p-two", "Fog.")] },
    ] }],
  },
  {
    name: "tabs",
    blocks: [{ id: "t-days", type: "tabs", tabs: [
      { id: "u-one", label: "Monday", blocks: [p("p-day", "Left at six.")] },
      { id: "u-two", label: "Tuesday", blocks: [p("p-two", "Fog.")] },
    ] }],
  },
  {
    name: "section-heading",
    blocks: [{ id: "s-day", type: "section", title: "Day one", blocks: [
      { id: "p-day", type: "heading", level: 3, text: "Left at six." },
      p("p-two", "Fog."),
    ] }],
  },
];

const recorded = [];
let failures = 0;
async function scene(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

for (const { name, blocks } of SCENES) {
  await scene(`${name}: Enter at the end, Enter on the empty line, Enter mid-text: every character saves once`, async () => {
    let server = clone(blocks);
    const batches = [];
    const refusals = [];
    const canvas = await mount(blocks, (el, { ops, seq }) => {
      batches.push(clone(ops));
      try {
        server = fold(server, ops);
      } catch (error) {
        refusals.push(error.message);
        el.acknowledgeOps(seq, false);
        return;
      }
      el.acknowledgeOps(seq, true);
      el.applyServerBlocks(clone(server), { mode: "own" });
    });
    try {
      const editor = canvas._editor;
      caretAfter(editor, "Left at six.");
      enter(editor);
      type(editor, "Fog lifted.");
      await saved(canvas);
      assert.deepEqual(refusals, [], "the server takes the split");
      const minted = ids(server).find((id) => !ids(blocks).includes(id));
      assert.ok(minted, "the split half got a fresh id");
      assert.ok(liveIds(editor).includes(minted), "the fresh id is written back onto the live node");
      assert.equal(idOf(server, "Left at six."), "p-day", "the origin half keeps its id");
      assert.equal(idOf(server, "Fog lifted."), minted, "the split half carries the fresh one");
      enter(editor);
      enter(editor);
      type(editor, "Rain.");
      await saved(canvas);
      caretAfter(editor, "Left");
      enter(editor);
      await saved(canvas);
      type(editor, "Late");
      await saved(canvas);

      assert.deepEqual(refusals, [], "the server takes every batch");
      assert.ok(ids(server).includes(minted), "the first minted id is never minted again");
      assert.deepEqual(repeated(liveIds(editor)), [], "the live doc repeats no id");
      assert.deepEqual(server, canvas.blocks, "the fold is what the client believes it saved");
      const text = words(server);
      for (const typed of ["Left", "Late at six.", "Fog lifted.", "", "Rain."]) {
        assert.ok(text.includes(typed), `"${typed}" is saved (have ${JSON.stringify(text)})`);
      }
      assert.deepEqual(await reloaded(server), lines(editor), "a reload shows exactly what the author saw");
      recorded.push({ scene: name, before: clone(blocks), batches, client_after: clone(canvas.blocks), typed: ["Left", "Late at six.", "Fog lifted.", "", "Rain."] });
    } finally {
      canvas.remove();
    }
  });
}

await scene("section: a refused batch keeps every later keystroke, and the fresh diff after the discard carries all of it", async () => {
  const blocks = SCENES[0].blocks;
  let server = clone(blocks);
  const sent = [];
  const canvas = await mount(blocks, (_el, detail) => sent.push(detail));
  try {
    const editor = canvas._editor;
    caretAfter(editor, "Left at six.");
    enter(editor);
    type(editor, "Fog lifted.");
    await saved(canvas);
    assert.equal(sent.length, 1, "one batch goes out");
    assert.equal(canvas.acknowledgeOps(sent[0].seq, false), false, "the refusal keeps it in flight");
    type(editor, " Then rain.");
    await tick(350);
    assert.equal(sent.length, 1, "typing behind a refused batch waits");
    assert.equal(canvas.hasPendingChanges(), true, "and is reported unsaved, so leaving the page warns");
    assert.ok(lines(editor).includes("Fog lifted. Then rain."), "the author still sees it");
    assert.equal(canvas.discardInflightOps(sent[0].seq), true);
    assert.equal(sent.length, 2, "the discard emits a fresh diff at once");
    assert.deepEqual(repeated(ids(fold(clone(blocks), sent[0].ops))), [], "the refused batch itself repeats no id");
    server = fold(server, sent[1].ops);
    assert.equal(canvas.acknowledgeOps(sent[1].seq, true), true);
    assert.ok(words(server).includes("Fog lifted. Then rain."), "the split and the later typing land together");
    assert.deepEqual(server, canvas.blocks);
    assert.deepEqual(await reloaded(server), lines(editor), "a reload shows exactly what the author saw");
  } finally {
    canvas.remove();
  }
});

await scene("section: pasted paragraphs that carry an id already in the doc get fresh ids", async () => {
  const blocks = SCENES[0].blocks;
  let server = clone(blocks);
  const refusals = [];
  const canvas = await mount(blocks, (el, { ops, seq }) => {
    try {
      server = fold(server, ops);
    } catch (error) {
      refusals.push(error.message);
      el.acknowledgeOps(seq, false);
      return;
    }
    el.acknowledgeOps(seq, true);
    el.applyServerBlocks(clone(server), { mode: "own" });
  });
  try {
    const editor = canvas._editor;
    caretAfter(editor, "Fog.");
    const html = '<p data-bp-id="p-day" data-bp-type="paragraph">Copied one.</p><p data-bp-id="p-day" data-bp-type="paragraph">Copied two.</p>';
    const paste = new Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(paste, "clipboardData", {
      value: { types: ["text/html", "text/plain"], getData: (t) => (t === "text/html" ? html : "Copied one.\n\nCopied two."), files: [] },
    });
    editor.view.dom.dispatchEvent(paste);
    await saved(canvas);
    assert.deepEqual(refusals, [], "the server takes the paste");
    assert.ok(words(server).includes("Copied two."), "the pasted paragraph is saved");
    assert.equal(idOf(server, "Left at six."), "p-day", "the paragraph already in the doc keeps its id");
    assert.notEqual(idOf(server, "Copied two."), "p-day", "the pasted copy gets a fresh one");
    assert.deepEqual(repeated(liveIds(editor)), [], "the live doc repeats no id");
    assert.deepEqual(await reloaded(server), lines(editor), "a reload shows exactly what the author saw");
  } finally {
    canvas.remove();
  }
});

// A copy or a move of a block, by paste or by what a drop leaves, then typing.
// `keeps`: line → the id it must still carry. Every batch applies, the fold is what
// the client believes, the live doc carries the ids the server holds, and a reload
// shows every typed character.
async function door(name, blocks, act, { keeps = {}, typed, removes = true }) {
  await scene(name, async () => {
    let server = clone(blocks);
    const batches = [];
    const refusals = [];
    const canvas = await mount(blocks, (el, { ops, seq }) => {
      batches.push(clone(ops));
      try {
        server = fold(server, ops);
      } catch (error) {
        refusals.push(error.message);
        el.acknowledgeOps(seq, false);
        return;
      }
      el.acknowledgeOps(seq, true);
      el.applyServerBlocks(clone(server), { mode: "own" });
    });
    try {
      const editor = canvas._editor;
      await act(editor, canvas);
      await saved(canvas);
      assert.deepEqual(refusals, [], "the server takes every batch");
      for (const [line, id] of Object.entries(keeps)) assert.equal(idOf(server, line), id, `"${line}" keeps ${id}`);
      const text = words(server);
      for (const t of typed) assert.ok(text.includes(t), `"${t}" is saved (have ${JSON.stringify(text)})`);
      if (!removes) assert.deepEqual(batches.flat().filter((op) => op.op === "remove-block"), [], "no block the author left alone is removed");
      assert.deepEqual(server, canvas.blocks, "the fold is what the client believes it saved");
      assert.deepEqual(liveIds(editor).filter((id) => !ids(server).includes(id)), [], "the live doc carries no id the server lacks");
      assert.deepEqual(repeated(liveIds(editor)), [], "the live doc repeats no id");
      assert.deepEqual(await reloaded(server), lines(editor), "a reload shows exactly what the author saw");
      recorded.push({ scene: name.split(":")[0], before: clone(blocks), batches, client_after: clone(canvas.blocks), typed });
    } finally {
      canvas.remove();
    }
  });
}

await door("copy-to-top: a nested paragraph copied to the top level above its section, then typed into: the original keeps its id",
  [p("p-a", "Alpha."), { id: "s-day", type: "section", title: "Day one", blocks: [p("p-day", "Left at six.")] }],
  async (editor, canvas) => {
    place(editor, "Left at six.", "Alpha.", { copy: true });
    await saved(canvas);
    caretAfter(editor, "Left at six.");
    type(editor, " Typed.");
  },
  { keeps: { "Left at six.": "p-day", "Alpha.": "p-a" }, typed: ["Left at six. Typed.", "Left at six."] });

await door("copy-in-section: a nested paragraph copied above itself in its section, then typed into: every character saves",
  [{ id: "s-day", type: "section", title: "Day one", blocks: [p("p-a", "Alpha."), p("p-day", "Left at six.")] }],
  async (editor, canvas) => {
    place(editor, "Left at six.", "Alpha.", { copy: true });
    await saved(canvas);
    caretAfter(editor, "Left at six.");
    type(editor, " Typed.");
  },
  { keeps: { "Alpha.": "p-a" }, typed: ["Left at six. Typed.", "Left at six."] });

await door("move-to-top: a nested paragraph moved to the top level, then typed into: the typing saves",
  [p("p-a", "Alpha."), { id: "s-day", type: "section", title: "Day one", blocks: [p("p-day", "Left at six."), p("p-two", "Fog.")] }],
  async (editor, canvas) => {
    place(editor, "Left at six.", "Alpha.", { copy: false });
    await saved(canvas);
    caretAfter(editor, "Left at six.");
    type(editor, " Typed.");
  },
  { keeps: { "Fog.": "p-two" }, typed: ["Left at six. Typed."] });

await door("paste-above: pasted copies of a section paragraph above it, then typed into: the original keeps its id",
  [{ id: "s-day", type: "section", title: "Day one", blocks: [p("p-a", "Alpha."), p("p-day", "Left at six.")] }],
  async (editor, canvas) => {
    caretAfter(editor, "Alpha.");
    paste(editor, COPIES("p-day"), "Copied one.\n\nCopied two.");
    await saved(canvas);
    caretAfter(editor, "Copied two.");
    type(editor, " More.");
  },
  { keeps: { "Left at six.": "p-day" }, typed: ["Copied two. More.", "Left at six."] });

await door("paste-into-column: pasted copies of a top-level paragraph in a column: the paragraph is left alone",
  [{ id: "col1", type: "columns", columns: [[{ type: "paragraph", content: [{ type: "text", value: "Left" }] }], [{ type: "paragraph", content: [{ type: "text", value: "Right" }] }]] }, p("p-x", "Original X.")],
  async (editor, canvas) => {
    caretAfter(editor, "Left");
    paste(editor, COPIES("p-x"), "Copied one.\n\nCopied two.");
    await saved(canvas);
    caretAfter(editor, "Original X.");
    type(editor, " More.");
  },
  { keeps: { "Original X. More.": "p-x" }, typed: ["Original X. More."], removes: false });

await door("paste-into-section: pasted copies of a top-level paragraph in a section above it: the paragraph is left alone",
  [{ id: "s-day", type: "section", title: "Day one", blocks: [p("p-a", "Alpha.")] }, p("p-x", "Original X.")],
  async (editor, canvas) => {
    caretAfter(editor, "Alpha.");
    paste(editor, COPIES("p-x"), "Copied one.\n\nCopied two.");
    await saved(canvas);
    caretAfter(editor, "Original X.");
    type(editor, " More.");
  },
  { keeps: { "Original X. More.": "p-x" }, typed: ["Original X. More.", "Copied two."], removes: false });

const doorRecordings = recorded.length;
await door("legacy-duplicate: a doc that already holds one id twice, typed into elsewhere: nothing is removed",
  [p("p-a", "Alpha."), { id: "s-day", type: "section", title: "Day one", blocks: [p("p-dup", "Inside.")] }, p("p-dup", "Outside.")],
  async (editor) => {
    caretAfter(editor, "Alpha.");
    type(editor, " More.");
  },
  { keeps: { "Outside.": "p-dup", "Alpha. More.": "p-a" }, typed: ["Alpha. More.", "Inside.", "Outside."], removes: false });
// The server refuses a stored doc that repeats an id (task-42d085f7431b8417 criterion 2),
// so the fixture holds only what it takes today.
recorded.length = doorRecordings;

function normalised(scenes) {
  const names = new Map();
  return JSON.parse(JSON.stringify(scenes).replace(/c-[0-9a-z]+-[0-9a-f]{8}/g, (id) => {
    if (!names.has(id)) names.set(id, `c-split-${names.size + 1}`);
    return names.get(id);
  }));
}

await scene("the recording matches api/test/support/fixtures/paper-editor/nested_split.json", async () => {
  const fixture = { recorded_by: "api/assets/paper-editor/src/canvas/__nested_split_id_mounted.test.mjs", scenes: normalised(recorded) };
  if (process.env.NESTED_SPLIT_WRITE === "1") writeFileSync(FIXTURE, JSON.stringify(fixture, null, 2) + "\n");
  assert.deepEqual(JSON.parse(readFileSync(FIXTURE, "utf8")), fixture);
});

if (failures) {
  console.log(`\n${failures} failed`);
  process.exit(1);
}
console.log("\nnested splits mint fresh ids and every typed character saves");
process.exit(0);
