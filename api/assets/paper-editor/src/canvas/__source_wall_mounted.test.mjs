// Source mode never changes a Paper it cannot carry (task-368b4fe38e75712d). An edit
// in source mode saves markdownToBlocks(text) in place of the document. Before this
// check, one key pressed anywhere stripped the marks from every paragraph the Markdown
// could not mark, and one key inside a callout with a body wrote the body's text over
// the callout's own words. Entering source mode now checks the round trip first
// (sourceLoss, src/markdown/carries.js) of both the stored blocks and the live doc, each
// settled as the save would store it (settleSourceParse: a block that keeps its id and
// type is a patch-block, so a top-level key the parse leaves out stays stored, except a
// callout's slots, which an edit inside it overwrites). Where either loses
// anything, source mode opens read-only. It shows the Markdown, takes no typing, writes
// nothing back (not on leaving, not on a flush), and one plain line says why and names
// the block. A Paper the round trip keeps whole opens as before.
// Run: node src/canvas/__source_wall_mounted.test.mjs

import assert from "node:assert/strict";
import { mount, paragraph, watchValueWrites } from "./source-flush-mounted-harness.mjs";
import { settleSourceParse } from "./source-realign.js";
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

  // 5) The settle step: a kept id and type keeps a top-level key the parse leaves out;
  //    a type change goes as a whole block, so the key counts as lost.
  {
    const base = [{ id: "t1", type: "heading", level: 1, role: "title", text: "T" }];
    assert.equal(firstLoss(base, settleSourceParse(base, [{ id: "x", type: "heading", level: 1, text: "T" }])), null,
      "a patch-block keeps the role");
    const replaced = firstLoss(base, settleSourceParse(base, [{ id: "x", type: "paragraph", content: [{ type: "text", value: "T" }] }]));
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

  console.log("source wall mounted: 6 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
