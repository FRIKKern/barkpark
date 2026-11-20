// A callout with a body keeps both its own words and its body when someone types in
// it (task-6a8137419e0153e4). The reader shows a callout's words from the first
// block of slots.body (Slots.callout_body_inline/1), and the editor shows the same
// words. A key typed there was saved into `content`, over the callout's own "head
// words", and the body the reader shows kept the old words. Now the edit goes into the
// body block the words came from, and `content` and every other body block are kept,
// in the rich editor and in source mode.
// Run: node src/canvas/__callout_body_edit_mounted.test.mjs

import assert from "node:assert/strict";
import { mount, paragraph, watchValueWrites } from "./source-flush-mounted-harness.mjs";

const callout = () => ({
  id: "c1",
  type: "callout",
  tone: "note",
  content: [{ type: "text", value: "head words" }],
  slots: { body: [paragraph("b1", "body one"), paragraph("b2", "body two")] },
});
const words = (block) => (block.content || []).map((run) => run.value).join("");

// The document position just after the callout's last character.
function calloutEnd(editor) {
  let end = -1;
  editor.state.doc.forEach((node, offset) => {
    if (node.type.name === "callout") end = offset + node.nodeSize - 1;
  });
  assert.notEqual(end, -1, "the callout is in the editor");
  return end;
}

const mounted = [];
try {
  // 1) The rich editor: one key at the end of the callout's words.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("p1", "Before"), callout()]);
    mounted.push(canvas);
    const editor = canvas._editor;
    assert.match(editor.state.doc.textContent, /body one/, "the editor shows the body's first block, as the reader does");
    editor.view.dispatch(editor.state.tr.insertText("!", calloutEnd(editor)));
    canvas.flushPendingChanges();
    assert.equal(batches.length, 1, "the key is saved");
    const saved = server[1];
    assert.equal(words(saved), "head words", "the callout's own words are kept");
    assert.equal(saved.slots.body.length, 2, "every body block is kept");
    assert.equal(words(saved.slots.body[0]), "body one!", "the key lands in the body block the editor showed");
    assert.equal(saved.slots.body[0].id, "b1");
    assert.deepEqual(saved.slots.body[1], paragraph("b2", "body two"), "the next body block is unchanged");
    inSync("after a key in a callout with a body");
  }

  // 2) Source mode: one key typed on the callout's line. Its line is the JSON
  //    sentinel (the reader's words are not its `content`), which source mode does
  //    not edit, so the save is refused and the stored callout is unchanged.
  {
    const { canvas, batches, server } = await mount([paragraph("p1", "Before"), callout()]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    assert.equal(textarea.readOnly, false, "source mode opens for typing on a callout with a body");
    const at = textarea.value.indexOf("head words");
    assert.notEqual(at, -1, "the callout's words are in the source");
    textarea.setSelectionRange(at, at);
    watchValueWrites(textarea).press("!");
    canvas.flushPendingChanges();
    if (canvas.sourceMode) canvas.toggleSourceMode();
    if (canvas.sourceMode) canvas.toggleSourceMode();
    assert.deepEqual(batches, [], "nothing is sent");
    assert.deepEqual(server[1], callout(), "the callout keeps its own words and its body");
  }

  // 3) A callout whose body is its own words (the slot form of one paragraph), and one
  //    with a body and no `content`. Source mode and back, unedited, sends nothing and
  //    keeps the body. A key typed in the rich editor lands in the body; `content`
  //    follows only where it held the same words, and none is written where none was.
  for (const [label, block] of [
    ["the same words", { id: "c1", type: "callout", tone: "note", content: [{ type: "text", value: "one words" }], slots: { body: [paragraph("b1", "one words")] } }],
    ["no content", { id: "c1", type: "callout", tone: "note", slots: { body: [paragraph("b1", "one words")] } }],
  ]) {
    const { canvas, batches, server, inSync } = await mount([paragraph("p1", "Before"), block]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    assert.equal(canvas.querySelector(".bp-canvas-source").readOnly, false, `source mode opens for typing (${label})`);
    canvas.toggleSourceMode();
    assert.deepEqual(batches, [], `source mode and back sends nothing (${label})`);
    assert.deepEqual(server[1], block, `and keeps the body (${label})`);
    const editor = canvas._editor;
    editor.view.dispatch(editor.state.tr.insertText("!", calloutEnd(editor)));
    canvas.flushPendingChanges();
    assert.equal(batches.length, 1, `the key is saved (${label})`);
    const saved = server[1];
    assert.equal(words(saved.slots.body[0]), "one words!", `the key lands in the body (${label})`);
    assert.equal(saved.slots.body[0].id, "b1");
    if (block.content) assert.equal(words(saved), "one words!", "content that held the same words follows");
    else assert.equal(saved.content, undefined, "no content is written where none was");
    inSync(`after a key (${label})`);
  }

  console.log("callout body edit mounted: 3 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
