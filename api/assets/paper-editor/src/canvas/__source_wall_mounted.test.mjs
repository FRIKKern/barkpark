// Source mode never opens on a Paper it would change (task-368b4fe38e75712d). An edit in
// source mode saves markdownToBlocks(text) in place of the document. Before this check,
// one key pressed anywhere stripped the marks from every paragraph the Markdown could
// not mark, and an edit inside a callout with a body wrote the body's text over the
// callout's own text. Entering source mode now checks the round trip first (sourceLoss,
// src/markdown/carries.js) of both the stored blocks and the live doc: where either loses
// anything, source mode stays closed, no op is sent, the visual editor is untouched, and
// one plain line names the block. A Paper the round trip keeps whole opens as before.
// Run: node src/canvas/__source_wall_mounted.test.mjs

import assert from "node:assert/strict";
import { mount, paragraph, watchValueWrites } from "./source-flush-mounted-harness.mjs";

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
const json = (value) => JSON.stringify(value);
const notice = (canvas) => canvas.querySelector("[data-bp-figure-constraint]");

// Toggle source mode; if a textarea opens, press one key at `at` (an offset, or "end")
// and toggle back, as a person would. Returns whether the textarea opened.
function editInSource(canvas, at) {
  canvas.toggleSourceMode();
  const textarea = canvas.querySelector(".bp-canvas-source");
  if (!textarea) return false;
  const keys = watchValueWrites(textarea);
  const offset = at === "end" ? textarea.value.length : at;
  textarea.setSelectionRange(offset, offset);
  keys.press("!");
  canvas.toggleSourceMode();
  return true;
}

const mounted = [];
try {
  // 1) A callout with a body, one key typed in another paragraph: source mode refuses.
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Elsewhere"), callout()]);
    mounted.push(canvas);
    const opened = editInSource(canvas, "Elsewhere".length);
    assert.equal(opened, false, "source mode refuses to open on a callout with a body");
    assert.equal(canvas.sourceMode, false, "the visual editor stays");
    assert.deepEqual(batches, [], "no op is sent");
    assert.match(json(server), /head words/);
    assert.match(json(server), /body two/);
    assert.equal(
      notice(canvas)?.textContent,
      "Source mode stays closed: Markdown cannot carry the body of block 2, a callout, yet.",
      "one plain line names the block",
    );
    assert.equal(notice(canvas).getAttribute("role"), "status");
  }

  // 2) A bold run in a paragraph nobody touches, one key typed in another paragraph.
  //    Before the check the save stripped the bold.
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Elsewhere"), bold()]);
    mounted.push(canvas);
    editInSource(canvas, "Elsewhere".length);
    assert.deepEqual(server[1], bold(), "the untouched paragraph keeps its bold");
    assert.deepEqual(batches, [], "no op is sent");
    assert.equal(canvas.sourceMode, false);
    assert.equal(
      notice(canvas)?.textContent,
      "Source mode stays closed: Markdown cannot carry the marks of block 2, a paragraph, yet.",
    );
  }

  // 3) One key typed inside the callout. Before the check the save wrote the body's
  //    text over the callout's own "head words".
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Elsewhere"), callout()]);
    mounted.push(canvas);
    editInSource(canvas, "end");
    assert.deepEqual(server[1], callout(), "the callout keeps its own text and its body");
    assert.deepEqual(batches, [], "no op is sent");
    assert.equal(canvas.sourceMode, false);
  }

  // 4) A Paper the round trip keeps whole opens as before, with no notice, and a key
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
    assert.equal(notice(canvas), null, "no notice");
    canvas.toggleSourceMode();
    assert.deepEqual(batches, [], "a toggle with no edit sends nothing");
    assert.equal(editInSource(canvas, "# Title".length), true);
    assert.deepEqual(batches.flat().map((op) => [op.op, op.id]), [["patch-block", "h1"]], "the edit saves as one patch");
    inSync("after a source edit");
  }

  console.log("source wall mounted: 4 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
