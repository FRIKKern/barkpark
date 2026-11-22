// A prose block whose inline nests past the depth limit keeps its words in the rich
// editor, and the notice is written after them (task-11bbe4b4ae8c85f4;
// canvas/inline-depth.js holds the rule). The editor already draws the word at the
// limit (the em, strong and link edges below are pins); past the limit it showed the
// word with no notice, and the pack's deepest doc threw a RangeError.
// Such a block is carried whole and read-only: the notice never enters the editor's
// doc or the stored doc, and saving the Paper writes the block as it was stored.
// Run: node src/canvas/__inline_depth_notice.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mount, paragraph } from "./source-flush-mounted-harness.mjs";
import { expandLimitDoc } from "../../../../priv/portable_doc/conformance/conformance.mjs";
import { MAX_CARRY_DEPTH, MAX_INLINE_DEPTH, MAX_WORD_DEPTH } from "./inline-depth.js";

const NOTICE = "Nested too deep to show";

// The editor's bounds equal the rows Go and Elixir read too
// (api/test/support/fixtures/portable-doc-slot-depth.json), and MAX_CARRY_DEPTH equals
// its own sum from the shared depth limits, so neither can drift on its own.
{
  const { bounds } = JSON.parse(readFileSync(new URL("../../../../test/support/fixtures/portable-doc-slot-depth.json", import.meta.url), "utf8"));
  assert.equal(MAX_INLINE_DEPTH, bounds.max_nest_depth, "MAX_INLINE_DEPTH is the shared depth limit");
  assert.equal(MAX_WORD_DEPTH, bounds.max_word_depth, "MAX_WORD_DEPTH is the shared word depth");
  assert.equal(MAX_CARRY_DEPTH, bounds.editor_max_carry_depth, "MAX_CARRY_DEPTH is the fixture's row");
  assert.equal(MAX_CARRY_DEPTH, 2 * bounds.max_word_depth + 2 * bounds.max_nest_depth + 16, "MAX_CARRY_DEPTH is its sum");
}
const pack = JSON.parse(readFileSync(new URL("../../../../test/support/fixtures/portable-doc-limits.json", import.meta.url), "utf8"));
const edge = (name) => {
  const found = pack.edges.find((e) => e.name === name);
  assert.ok(found, `the limit pack holds the edge "${name}"`);
  return { id: "d1", ...expandLimitDoc(found.doc) };
};
const packDoc = (name) => ({ id: "d1", ...expandLimitDoc(pack.docs.find((d) => d.name === name).doc) });
const nestedEm = (levels) => {
  let inline = { type: "text", value: "leaf" };
  for (let i = 0; i < levels; i++) inline = { type: "em", children: [inline] };
  return { id: "d1", type: "paragraph", content: [inline] };
};

// Where the editor would take a key at the end of `words`, or -1 when no editable
// text holds them.
function typingSpot(editor, words) {
  let at = -1;
  editor.state.doc.descendants((node, pos) => {
    if (at !== -1 || !node.isText) return;
    const i = node.text.indexOf(words);
    if (i !== -1) at = pos + i + words.length;
  });
  return at;
}

const failures = [];
const mounted = [];
const own = async (name, run) => { try { await run(); } catch (error) { failures.push(`${name}: ${error.message}`); } };

try {
  // 1) Pins: at the limit the editor draws the word, editable, with no notice.
  for (const name of ["em at the depth limit", "strong at the depth limit", "link at the depth limit"]) {
    await own(`1) ${name}`, async () => {
      const { canvas } = await mount([edge(name)]);
      mounted.push(canvas);
      assert.notEqual(typingSpot(canvas._editor, "leaf"), -1, "the word is editable text");
      assert.ok(!canvas.textContent.includes(NOTICE), "no notice at the limit");
    });
  }

  // 2) Past the limit: the word, then the notice, read-only. The notice is in neither
  //    the editor's doc nor the stored doc; a key beside it and source mode send
  //    nothing for it, and the block is stored byte for byte as it was.
  for (const [label, block] of [["em past the value depth", edge("em past the value depth")], ["301 em, a storable doc", nestedEm(301)]]) {
    await own(`2) ${label}`, async () => {
      const stored = JSON.stringify(block);
      const { canvas, batches, server } = await mount([paragraph("p1", "Before"), block]);
      mounted.push(canvas);
      const editor = canvas._editor;
      const view = canvas.querySelector('[data-bp-inline-depth-readonly="d1"]');
      assert.ok(view, "the block is shown read-only");
      assert.equal(view.getAttribute("contenteditable"), "false", "it takes no typing");
      assert.equal(view.textContent, `leaf ${NOTICE}`, "the word, one space, then the notice");
      assert.equal(typingSpot(editor, "leaf"), -1, "the word is not text the editor can type into");
      assert.ok(!JSON.stringify(editor.getJSON()).includes(NOTICE), "the notice is not in the editor's doc");

      editor.view.dispatch(editor.state.tr.insertText("!", typingSpot(editor, "Before")));
      canvas.flushPendingChanges();
      assert.deepEqual(batches.map((ops) => ops.map((op) => op.id)), [["p1"]], "only the paragraph typed in is sent");
      canvas.toggleSourceMode();
      canvas.toggleSourceMode();
      canvas.flushPendingChanges();
      assert.deepEqual(batches.length, 1, "source mode and back sends nothing");
      assert.equal(JSON.stringify(server[1]), stored, "the stored block is as it was, byte for byte");
      assert.equal(JSON.stringify(canvas.blocks[1]), stored, "and so is the canvas's own copy");
      assert.ok(!JSON.stringify(canvas.blocks).includes(NOTICE), "the notice is not in the saved doc");
    });
  }

  // 3) A text with more marks than fit keeps its word, then the notice.
  await own("3) marks past the limit", async () => {
    const block = { id: "d1", type: "paragraph", content: [{ type: "text", value: "leaf", marks: Array(101).fill("strong") }] };
    const { canvas } = await mount([block]);
    mounted.push(canvas);
    const view = canvas.querySelector('[data-bp-inline-depth-readonly="d1"]');
    assert.ok(view, "the block is shown read-only");
    assert.equal(view.textContent, `leaf ${NOTICE}`);
  });

  // 4) The pack's deepest inline doc (20,000 nested strong) opens without an error
  //    and shows the notice. Words deeper than the word bound (1000) are not read.
  await own("4) nested strong, 20,000", async () => {
    const canvas = document.createElement("bp-paper-canvas");
    canvas.blocks = [packDoc("nested strong")];
    document.body.appendChild(canvas);
    mounted.push(canvas);
    await new Promise((resolve) => setTimeout(resolve, 350));
    const view = canvas.querySelector('[data-bp-inline-depth-readonly="d1"]');
    assert.ok(view, "the block is shown read-only");
    assert.equal(view.textContent, NOTICE);
  });

  // 5) A word deeper than the word bound (1000) is not read: 1001 nested em, inside the
  //    carry bound, show the notice alone. Without the word bound the word would show.
  await own("5) 1001 em, one word past the word bound", async () => {
    const { canvas } = await mount([nestedEm(1001)]);
    mounted.push(canvas);
    const view = canvas.querySelector('[data-bp-inline-depth-readonly="d1"]');
    assert.ok(view, "the block is shown read-only");
    assert.equal(view.textContent, NOTICE, "the notice alone, no word");
  });

  if (failures.length > 0) throw new Error(failures.join("\n"));
  console.log("inline depth notice: 5 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
