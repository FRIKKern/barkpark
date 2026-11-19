// Source mode shows the words the reader shows, or does not edit the block
// (task-368b4fe38e75712d). The reader takes a prose block's words from `content`, or
// from `text` when there is no content (markdown/reader-inline.js mirrors it). A block
// whose words the Markdown line would not show rides as its JSON sentinel, and source
// mode does not edit a sentinel line: an edit there is refused, nothing is saved, the
// typed text stays in the textarea and one line names the block. Moving or deleting
// the line still saves. A quote or callout holding only `text` is shown by the editor
// as empty, so it opens read-only. And a Paper whose unedited save gives back other
// blocks than stored opens read-only.
// Run: node src/canvas/__source_wall_carriers_mounted.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { clone, mount, paragraph, watchValueWrites } from "./source-flush-mounted-harness.mjs";
import { readerInline } from "../markdown/reader-inline.js";

const T = (value) => [{ type: "text", value }];
const words = (block) => (readerInline(block) || []).map((run) => run.value || "").join("");
const notice = (canvas) => canvas.querySelector("[data-bp-figure-constraint]")?.textContent ?? null;

// The reviewer's carrier shapes (review-source-wall/probes/carriers.mjs and
// patchrule.mjs): what the reader shows and what the editor does with it.
const shapes = {
  paraTextOnly: [{ id: "x", type: "paragraph", text: "carried" }, "sentinel"],
  paraEmptyContentText: [{ id: "x", type: "paragraph", content: [], text: "carried" }, "sentinel"],
  paraContentAndText: [{ id: "x", type: "paragraph", content: T("shown"), text: "shadow" }, "line"],
  headingContentText: [{ id: "x", type: "heading", level: 2, text: "H", content: T("Hc") }, "sentinel"],
  headingContentOnly: [{ id: "x", type: "heading", level: 2, content: T("Only content") }, "sentinel"],
  quoteTextOnly: [{ id: "x", type: "blockquote", text: "quoted" }, "read-only"],
  quoteContentAndText: [{ id: "x", type: "blockquote", content: T("shown"), text: "shadow" }, "line"],
  calloutTextOnly: [{ id: "x", type: "callout", tone: "note", text: "callout text" }, "read-only"],
  calloutContentAndText: [{ id: "x", type: "callout", tone: "note", content: T("shown"), text: "shadow" }, "line"],
};

// Open source mode, type one key at `at` ("end" or an offset), flush, try to leave.
async function typeIn(blocks, at) {
  const mounted = await mount(clone(blocks));
  const { canvas } = mounted;
  canvas.toggleSourceMode();
  const textarea = canvas.querySelector(".bp-canvas-source");
  const opened = { readOnly: textarea.readOnly, value: textarea.value, notice: notice(canvas) };
  const offset = at === "end" ? textarea.value.length : at;
  textarea.setSelectionRange(offset, offset);
  watchValueWrites(textarea).press("!");
  canvas.flushPendingChanges();
  canvas.toggleSourceMode();
  return { ...mounted, textarea, opened };
}

const all = [];
try {
  for (const [name, [block, kind]] of Object.entries(shapes)) {
    const blocks = [paragraph("p0", "Before"), block];

    // A key typed in the other paragraph: the reader shows the carrier's words as before.
    {
      const run = await typeIn(blocks, "Before".length);
      all.push(run.canvas);
      if (kind === "read-only") {
        assert.equal(run.opened.readOnly, true, `${name}: read-only`);
        assert.match(run.opened.notice, new RegExp(`^Read only: .* of block 2, a ${block.type}, yet\\.$`), `${name}: the line names block 2`);
        assert.deepEqual(run.batches, [], `${name}: nothing is sent`);
      } else {
        assert.equal(run.opened.readOnly, false, `${name}: writable`);
        assert.equal(words(run.server[0]), "Before!", `${name}: the typed key is saved`);
      }
      assert.equal(words(run.server[1]), words(block), `${name}: the reader shows the carrier's words as before`);
      assert.deepEqual(run.server[1], block, `${name}: the carrier is stored as before`);
    }

    // A key typed at the end of the carrier's own line.
    {
      const run = await typeIn(blocks, "end");
      all.push(run.canvas);
      if (kind === "sentinel") {
        assert.ok(run.opened.value.endsWith("-->"), `${name}: the line is the block's JSON sentinel`);
        assert.deepEqual(run.batches, [], `${name}: the edited JSON line is refused, nothing is sent`);
        assert.equal(JSON.stringify(run.server), JSON.stringify(blocks), `${name}: the stored Paper is byte-equal`);
        assert.equal(notice(run.canvas), "Not saved: block 2 is shown as JSON, and source mode does not edit it.");
        assert.equal(run.canvas.sourceMode, true, `${name}: source mode stays open`);
        assert.equal(run.textarea.value, `${run.opened.value}!`, `${name}: the typed text is still there`);
      } else if (kind === "read-only") {
        assert.deepEqual(run.batches, [], `${name}: nothing is sent`);
        assert.deepEqual(run.server[1], block, `${name}: stored as before`);
      } else {
        assert.equal(words(run.server[1]), `${words(block)}!`, `${name}: the reader shows what was typed, and only that`);
      }
    }
  }

  // Refused, then put back: the line reads as it was, so leaving sends nothing; and a
  // sentinel line moved or deleted is saved as usual.
  {
    const carried = { id: "x", type: "paragraph", text: "carried" };
    const blocks = [paragraph("p0", "Before"), carried, paragraph("p2", "After")];
    const { canvas, batches, server } = await mount(clone(blocks));
    all.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const keys = watchValueWrites(textarea);
    const shown = textarea.value;
    const at = shown.indexOf("carried") + 1;
    textarea.setSelectionRange(at, at);
    keys.press("Ж");
    assert.equal(canvas.flushPendingChanges(), false, "a key inside the JSON's words is refused too");
    assert.equal(notice(canvas), "Not saved: block 2 is shown as JSON, and source mode does not edit it.");
    keys.type(shown);
    canvas.toggleSourceMode();
    assert.equal(canvas.sourceMode, false, "put back, source mode closes");
    assert.equal(notice(canvas), null, "and the line goes");
    assert.deepEqual(batches, [], "nothing is sent");

    canvas.toggleSourceMode();
    const lines = canvas.querySelector(".bp-canvas-source").value.split("\n\n");
    watchValueWrites(canvas.querySelector(".bp-canvas-source")).type([lines[0], lines[2], lines[1]].join("\n\n"));
    canvas.toggleSourceMode();
    assert.deepEqual(server.map((block) => block.id), ["p0", "p2", "x"], "a moved sentinel line saves the move");
    assert.deepEqual(server[2], carried, "and the block whole");

    canvas.toggleSourceMode();
    const now = canvas.querySelector(".bp-canvas-source").value.split("\n\n");
    watchValueWrites(canvas.querySelector(".bp-canvas-source")).type([now[0], now[1]].join("\n\n"));
    canvas.toggleSourceMode();
    assert.deepEqual(server.map((block) => block.id), ["p0", "p2"], "a deleted sentinel line saves the delete");
  }

  // readme.json: an unedited save gives back other blocks than stored (its marks, and
  // the editor's own save rewrites block 4's code+strong run as nested nodes,
  // task-7a92f596371dc4c1), so source mode opens read-only and names the first.
  {
    const path = fileURLToPath(new URL("../../../../../.demo-content/repo-papers/readme.json", import.meta.url));
    const json = JSON.parse(readFileSync(path, "utf8"));
    const stored = Array.isArray(json) ? json : json.blocks;
    const { canvas, batches } = await mount(clone(stored));
    all.push(canvas);
    canvas.toggleSourceMode();
    assert.equal(canvas.querySelector(".bp-canvas-source").readOnly, true, "readme.json opens read-only");
    assert.equal(notice(canvas), "Read only: Markdown cannot carry the marks of block 2, a paragraph, yet.");
    canvas.toggleSourceMode();
    assert.deepEqual(batches, [], "nothing is sent");
  }

  console.log(`source wall carriers mounted: ${Object.keys(shapes).length} shapes, refused/put back/move/delete, readme.json: passed`);
} finally {
  for (const canvas of all) canvas.remove();
}
process.exit(0);
