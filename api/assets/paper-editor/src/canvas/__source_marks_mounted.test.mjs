// Source mode keeps bold, italic, code and links held as text marks
// (task-5f0ba8904b973a3a). The editor holds a mark as a text run's `marks`; the
// Markdown writer wrote only marks spelled as nodes, so `a **x**` held as a run with
// marks ["strong"] was written `a x`, and the source-mode wall had to refuse the Paper.
// Now the writer writes those marks, the round trip finds them again, and source mode
// opens and saves the Paper with every mark. A mark Markdown has no syntax for
// (underline, a link with a title) still rides the block's JSON line, whole.
// Run: node src/canvas/__source_marks_mounted.test.mjs

import assert from "node:assert/strict";
import { mount, paragraph, watchValueWrites } from "./source-flush-mounted-harness.mjs";
import { blocksToMarkdown, sourceLoss } from "../markdown.js";

const text = (value, marks) => (marks ? { type: "text", value, marks } : { type: "text", value });
const para = (id, content) => ({ id, type: "paragraph", content });

// 1) The writer writes a mark held on text, and reading it back finds it.
{
  const bold = para("m1", [text("a "), text("x", ["strong"])]);
  assert.equal(blocksToMarkdown([bold]), "a **x**", "a bold run is written bold");
  assert.equal(sourceLoss([bold]), null, "and read back bold");

  const mixed = para("m2", [
    text("plain "), text("bold", [{ type: "bold" }]), text(" "), text("italic", ["em"]), text(" "),
    text("code", ["code"]), text(" "), text("gone", ["strike"]), text(" "),
    text("site", [{ type: "link", href: "https://example.com/a" }]), text(" "),
    text("both", ["strong", "em"]), text(" "), text("bold code", ["strong", "code"]), text(" end"),
  ]);
  assert.equal(sourceLoss([mixed]), null, `every mark survives: ${blocksToMarkdown([mixed])}`);
  const list = { id: "l1", type: "list", items: [[text("one "), text("two", ["em"])], [text("three", ["code"])]] };
  assert.equal(sourceLoss([list]), null, `a list item's marks survive: ${blocksToMarkdown([list])}`);
  const callout = { id: "c1", type: "callout", tone: "note", content: [text("see "), text("this", ["strong"])] };
  assert.equal(sourceLoss([callout]), null, `a callout's marks survive: ${blocksToMarkdown([callout])}`);

  for (const marks of [["underline"], [{ type: "link", href: "h", title: "t" }], [{ type: "comment", id: "c" }]]) {
    const odd = para("o1", [text("a "), text("x", marks)]);
    assert.match(blocksToMarkdown([odd]), /^<!--bp:block /, `a mark Markdown cannot write (${JSON.stringify(marks)}) rides the JSON line`);
    assert.equal(sourceLoss([odd]), null, "whole");
  }
}

// 2) Through the canvas: source mode opens on a Paper with marks on text, a key typed
//    elsewhere saves only that key, and the untouched paragraph keeps its marks.
const mounted = [];
try {
  const bold = () => para("m1", [text("a "), text("x", ["strong"]), text(" and "), text("y", [{ type: "link", href: "https://example.com/y" }])]);
  const { canvas, batches, server, inSync } = await mount([paragraph("p1", "Elsewhere"), bold()]);
  mounted.push(canvas);
  canvas.toggleSourceMode();
  const textarea = canvas.querySelector(".bp-canvas-source");
  assert.ok(textarea, "source mode opens");
  assert.equal(textarea.value, "Elsewhere\n\na **x** and [y](https://example.com/y)");
  textarea.setSelectionRange("Elsewhere".length, "Elsewhere".length);
  watchValueWrites(textarea).press("!");
  canvas.toggleSourceMode();
  assert.deepEqual(batches.flat().map((op) => [op.op, op.id]), [["patch-block", "p1"]], "only the edited block is sent");
  assert.deepEqual(server[1], bold(), "the untouched paragraph keeps its marks");
  inSync("after a source edit beside marks");
  console.log("source marks: passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
