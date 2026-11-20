// Source mode never changes a Paper it cannot carry (task-368b4fe38e75712d). An edit
// in source mode saves markdownToBlocks(text) in place of the document. Before this
// check, one key pressed anywhere stripped the marks from every paragraph the Markdown
// could not mark, and one key inside a callout with a body wrote the body's text over
// the callout's own words. Entering source mode now runs the save first (sourceSaved,
// canvas/source-save.js: the ops a save sends, folded onto what is stored as patch.ex
// folds them) for both the stored blocks and the live doc, and compares the result with
// what was stored (sourceLoss, src/markdown/carries.js). A Paper opens writable only
// when that gives back every key that was stored, and it holds no callout with a body;
// anything else opens read-only. It shows the Markdown, takes no typing, writes
// nothing back (not on leaving, not on a flush), and one plain line says why and names
// the block. A Paper the save keeps whole opens as before.
// Run: node src/canvas/__source_wall_mounted.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mount, paragraph, watchValueWrites } from "./source-flush-mounted-harness.mjs";
import { sourceSaved } from "./source-save.js";
import { runToOps, runToTiptap } from "./run-convert.js";
import { firstLoss } from "../markdown.js";

const callout = () => ({
  id: "c1",
  type: "callout",
  tone: "note",
  content: [{ type: "text", value: "head words" }],
  slots: { body: [paragraph("b1", "body one"), paragraph("b2", "body two")] },
});
const bold = () => ({
  id: "m1",
  type: "paragraph",
  content: [{ type: "text", value: "a " }, { type: "text", value: "bold", marks: ["strong"] }],
});
const notice = (canvas) => canvas.querySelector("[data-bp-figure-constraint]");

// Open source mode and put one key at `at` (an offset, or "end"). The key is written
// past the textarea's readOnly, the way a script could, so the test proves nothing is
// written back even then. Flush, then leave. Returns what the open textarea showed.
function editInSource(canvas, at) {
  canvas.toggleSourceMode();
  const textarea = canvas.querySelector(".bp-canvas-source");
  assert.ok(textarea, "source mode opens");
  const seen = { readOnly: textarea.readOnly, value: textarea.value, notice: notice(canvas)?.textContent };
  const offset = at === "end" ? textarea.value.length : at;
  textarea.setSelectionRange(offset, offset);
  watchValueWrites(textarea).press("!");
  canvas.flushPendingChanges();
  if (canvas.sourceMode) canvas.toggleSourceMode();
  return seen;
}

const mounted = [];
try {
  // 1) A callout with a body: the editor writes an edit inside it over its own words
  //    (case 4), so source mode opens read-only, names that callout, and a key typed in
  //    another paragraph sends nothing; the stored callout keeps its text and its body.
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Elsewhere"), callout()]);
    mounted.push(canvas);
    const seen = editInSource(canvas, "Elsewhere".length);
    assert.equal(seen.readOnly, true, "source mode opens read-only on a callout with a body");
    assert.match(seen.value, /^Elsewhere\n\n> \[!note\]/, "it shows the Markdown");
    assert.equal(seen.notice, "Read only: Markdown cannot carry the body of block 2, a callout, yet.",
      "one plain line says why and names the callout");
    assert.deepEqual(batches, [], "no op is sent");
    assert.deepEqual(server[1], callout(), "the stored callout keeps its text and its body");
  }

  // 2) A bold run in a paragraph nobody touches, one key typed in another paragraph.
  //    Before the check the save stripped the bold; now source mode is read-only.
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Elsewhere"), bold()]);
    mounted.push(canvas);
    const seen = editInSource(canvas, "Elsewhere".length);
    assert.equal(seen.readOnly, true, "source mode opens read-only on a lost mark");
    assert.equal(seen.value, "Elsewhere\n\na bold", "it shows the Markdown");
    assert.equal(seen.notice, "Read only: Markdown cannot carry the marks of block 2, a paragraph, yet.",
      "one plain line says why and names the block");
    assert.deepEqual(batches, [], "no op is sent, on a flush or on leaving");
    assert.deepEqual(server[1], bold(), "the untouched paragraph keeps its bold");
    assert.equal(canvas.sourceMode, false, "leaving goes back to the visual editor");
    assert.equal(notice(canvas), null, "and the line goes with source mode");
  }

  // 3) A title-role heading: Markdown writes no role, but the heading's save is a patch
  //    of its text, so source mode opens for typing and the role stays stored.
  {
    const title = () => ({ id: "t1", type: "heading", level: 1, role: "title", text: "Keyboard" });
    const { canvas, batches, server } = await mount([title(), paragraph("p1", "Body text.")]);
    mounted.push(canvas);
    const seen = editInSource(canvas, "# Keyboard".length);
    assert.equal(seen.readOnly, false, "source mode opens for typing on a title-role heading");
    assert.deepEqual(batches.flat().map((op) => op.op), ["patch-block"]);
    assert.deepEqual(server[0], { ...title(), text: "Keyboard!" }, "the save keeps the role");
  }

  // 4) One key typed inside the callout. On main the save wrote the body's text over
  //    the callout's own "head words" (the rich editor does the same: task-6a8137419e0153e4).
  //    Read-only, nothing is sent.
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Elsewhere"), callout()]);
    mounted.push(canvas);
    editInSource(canvas, "end");
    assert.deepEqual(server[1], callout(), "the callout keeps its own text and its body");
    assert.deepEqual(batches, [], "no op is sent");
  }

  // 5) The save is run, not modelled (sourceSaved: realign, projection, runToOps, the
  //    patch.ex fold). A heading's role is never patched, so a parse without it keeps
  //    it; a type change goes as a replace-block, which rebuilds the block without it.
  {
    const view = { toDoc: runToTiptap, toOps: runToOps };
    const base = [{ id: "t1", type: "heading", level: 1, role: "title", text: "T" }];
    const typed = sourceSaved(base, [{ id: "x", type: "heading", level: 1, text: "T!" }], view);
    assert.deepEqual(typed, [{ ...base[0], text: "T!" }], "the save patches the text and keeps the role");
    const replaced = firstLoss(base, sourceSaved(base, [{ id: "x", type: "paragraph", content: [{ type: "text", value: "T" }] }], view));
    assert.ok(replaced, "a block saved whole (its type changed) loses the role, and the check says so");
  }

  // 6) A Paper the round trip keeps whole opens as before, with no notice, and a key
  //    typed there saves as before.
  {
    const { canvas, batches, inSync } = await mount([
      { id: "h1", type: "heading", level: 2, text: "Title" },
      paragraph("p1", "Plain words"),
      { id: "l1", type: "list", ordered: false, items: [[{ type: "text", value: "one" }], [{ type: "text", value: "two" }]] },
      { id: "k1", type: "code", lang: "js", value: "let x = 1;" },
    ]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    assert.equal(canvas.sourceMode, true, "source mode opens");
    assert.equal(canvas.querySelector(".bp-canvas-source").readOnly, false, "for typing");
    assert.equal(notice(canvas), null, "no notice");
    canvas.toggleSourceMode();
    assert.deepEqual(batches, [], "a toggle with no edit sends nothing");
    assert.equal(editInSource(canvas, "# Title".length).readOnly, false);
    assert.deepEqual(batches.flat().map((op) => [op.op, op.id]), [["patch-block", "h1"]], "the edit saves as one patch");
    inSync("after a source edit");
  }

  // 7) An ordered list that starts at 5, one key typed in another paragraph. The save
  //    would patch the list too, with `start: null` (the prose patch writes a key the
  //    parse dropped as null), and the list would count from 1. Markdown cannot carry
  //    the start yet, so source mode opens read-only and names the list.
  {
    const list = () => ({ id: "l1", type: "list", ordered: true, start: 5, items: [[{ type: "text", value: "five" }]] });
    const { canvas, batches, server } = await mount([paragraph("p1", "Before"), list()]);
    mounted.push(canvas);
    const seen = editInSource(canvas, "Before".length);
    assert.equal(seen.readOnly, true, "source mode opens read-only on a list that starts at 5");
    assert.equal(seen.notice, "Read only: Markdown cannot carry the start of block 2, a list, yet.",
      "one plain line names the list");
    assert.deepEqual(batches, [], "no op is sent");
    assert.deepEqual(server[1], list(), "the list keeps its start");
  }

  // 8) Typing queued behind a batch in flight, or behind one whose save failed and waits
  //    for a retry. The wall judges what is stored as it will be once that batch lands
  //    and the queued typing follows, so source mode opens for typing and the key saves
  //    after the batch. It opened read-only, naming the typed paragraph's text
  //    (task-0c39ad547f8bab23). A real loss in the queued typing is still refused.
  for (const state of ["in flight", "failed"]) {
    const { canvas, batches, server, inSync } = await mount([paragraph("p1", "Original")]);
    mounted.push(canvas);
    const held = [];
    canvas.acknowledgeOps = (seq) => { held.push(seq); return false; };
    const ack = (seq, saved) => Object.getPrototypeOf(canvas).acknowledgeOps.call(canvas, seq, saved);
    const type = (text) => {
      canvas._editor.view.dispatch(canvas._editor.state.tr.insertText(text, canvas._editor.state.doc.content.size - 1));
      canvas.flushPendingChanges();
    };
    type(" one");
    assert.equal(held.length, 1, `one batch ${state}`);
    if (state === "failed") ack(held[0], false);
    type(" two");
    assert.equal(batches.length, 1, `the typing waits behind the batch ${state}`);
    const seen = editInSource(canvas, "end");
    assert.equal(seen.readOnly, false, `source mode opens for typing behind a batch ${state}`);
    assert.equal(seen.notice, undefined, "with no notice");
    assert.equal(batches.length, 1, "the source edit waits too");
    delete canvas.acknowledgeOps;
    ack(held[0], true);
    assert.equal(server[0].content[0].value, "Original one two!", `the queued typing and the key save after the batch ${state}`);
    inSync(`behind a batch ${state}`);

    const lossy = await mount([paragraph("p1", "Original")]);
    mounted.push(lossy.canvas);
    lossy.canvas.acknowledgeOps = (seq) => { held.push(seq); return false; };
    lossy.canvas._editor.view.dispatch(lossy.canvas._editor.state.tr.insertText(" one", lossy.canvas._editor.state.doc.content.size - 1));
    lossy.canvas.flushPendingChanges();
    if (state === "failed") Object.getPrototypeOf(lossy.canvas).acknowledgeOps.call(lossy.canvas, held.at(-1), false);
    const marked = runToTiptap([{ ...bold(), id: null }]).content[0];
    lossy.canvas._editor.commands.insertContentAt(lossy.canvas._editor.state.doc.content.size, marked);
    lossy.canvas.flushPendingChanges();
    const refused = editInSource(lossy.canvas, "end");
    assert.equal(refused.readOnly, true, `a lost mark in typing queued behind a batch ${state} is still refused`);
    assert.equal(refused.notice, "Read only: Markdown cannot carry the marks of block 2, a paragraph, yet.");
    assert.equal(lossy.batches.length, 1, "nothing more is sent");
  }

  // 9) The shared carrier list (goldens/nested-list-carriers.json): an item with an id,
  //    a text fallback and a key the editor does not know, and lists nested under items.
  //    The save cannot give its items back, so source mode opens read-only with this
  //    line, and a key typed there sends nothing (__source_wall_fixtures.test.mjs lists
  //    the file as refused on items[0]).
  {
    const carriers = JSON.parse(readFileSync(new URL("../../../../priv/portable_doc/goldens/nested-list-carriers.json", import.meta.url), "utf8")).blocks;
    const { canvas, batches, server } = await mount(carriers);
    mounted.push(canvas);
    const seen = editInSource(canvas, "end");
    assert.equal(seen.readOnly, true, "source mode opens read-only on the carrier list");
    assert.equal(seen.notice, "Read only: Markdown cannot carry the items of block 1, a list, yet.");
    assert.deepEqual(batches, [], "no op is sent");
    assert.deepEqual(server, JSON.parse(readFileSync(new URL("../../../../priv/portable_doc/goldens/nested-list-carriers.json", import.meta.url), "utf8")).blocks,
      "the stored list is unchanged");
  }

  console.log("source wall mounted: 9 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
