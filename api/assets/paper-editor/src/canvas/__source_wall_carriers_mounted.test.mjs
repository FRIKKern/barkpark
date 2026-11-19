// Source mode shows the words the reader shows, or does not edit the block
// (task-368b4fe38e75712d). The reader takes a prose block's words from `content`, or
// from `text` when there is no content (markdown/reader-inline.js mirrors it). A block
// whose words the Markdown line would not show rides as its JSON sentinel, and source
// mode does not edit a sentinel line: an edit there is refused, nothing is saved, the
// typed text stays in the textarea and one line names the block. Moving or deleting
// the line still saves. A quote or callout holding only `text` is shown by the editor
// as empty, so it opens read-only. And a Paper whose unedited save gives back other
// blocks than stored opens read-only.
// Run: node src/canvas/__source_wall_carriers_mounted.test.mjs (CASE=<shape name> or
// CASE=refused, edges, outcome, duplicate or readme runs one case).

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

const only = process.env.CASE || null;
const runs = (name) => only === null || only === name;
const all = [];
try {
  for (const [name, [block, kind]] of Object.entries(shapes)) {
    if (!runs(name)) continue;
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
  if (runs("refused")) {
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

  // The review's edges (review-source-wall/probes/sentinel-edges.mjs): a sentinel line
  // with a key before it, or wrapped as a quote, a list item, a heading or a fence, is
  // refused like a key inside it. Each row is judged alone and the failures listed.
  if (runs("edges")) {
    const carriers = {
      paragraph: { id: "x", type: "paragraph", text: "carried" },
      image: { id: "x", type: "image", src: "https://example.test/a.png", alt: "A", caption: "cap", width: 300 },
    };
    const edits = {
      "! before": (l) => "!" + l, "quoted": (l) => "> " + l, "listed": (l) => "- " + l,
      "headed": (l) => "# " + l, "fenced": (l) => "```\n" + l + "\n```",
      // Refused already on b655420af7: kept as guard rows.
      "key after": (l) => l + "!", "words after": (l) => l + " more words",
      "key added to the JSON": (l) => l.replace('{"id":"x"', '{"id":"x","alt2":"q"'),
      "split": (l) => l.slice(0, 20) + "\n" + l.slice(20),
    };
    const failed = [];
    for (const [carrier, block] of Object.entries(carriers)) {
      for (const [edit, change] of Object.entries(edits)) {
        const blocks = [paragraph("p0", "Before"), block, paragraph("p2", "After")];
        const { canvas, batches, server } = await mount(clone(blocks));
        all.push(canvas);
        canvas.toggleSourceMode();
        const textarea = canvas.querySelector(".bp-canvas-source");
        const line = textarea.value.split("\n").find((text) => text.startsWith("<!--bp:block"));
        const next = textarea.value.replace(line, change(line));
        watchValueWrites(textarea).type(next);
        const flushed = canvas.flushPendingChanges();
        canvas.toggleSourceMode();
        const still = canvas.querySelector(".bp-canvas-source");
        const refused = flushed === false && still !== null && still.value === next && batches.length === 0 &&
          JSON.stringify(server) === JSON.stringify(blocks) && [
            "Not saved: block 2 is shown as JSON, and source mode does not edit it.",
            "Not saved: block 2 is shown as JSON. Delete it and save first, then make your other changes.",
          ].includes(notice(canvas));
        if (!refused) failed.push(`${carrier} ${edit}: flushed ${flushed}, ${batches.length} batches, open ${still !== null}, ${JSON.stringify(notice(canvas))}`);
      }
    }
    assert.deepEqual(failed, [], "every edge is refused: nothing sent, source mode open, the text kept, block 2 named");
  }

  // A duplicated sentinel line saves a copy under a new id; the block stays as it was
  // and no two blocks share an id.
  // Outcome rows: a block shown as JSON is stored unchanged, or deleted by a save that
  // only deletes; anything else is refused (a line that is no longer there, whatever
  // took its place, gets the notice that asks for the deletion on its own). Each row is
  // judged alone, failures listed.
  if (runs("outcome")) {
    const EDIT = "Not saved: block %N is shown as JSON, and source mode does not edit it.";
    const REMOVE = "Not saved: block %N is shown as JSON. Delete it and save first, then make your other changes.";
    const image = (id) => ({ id, type: "image", src: "https://example.test/a.png", alt: "A", caption: "cap", width: 300 });
    const carried = (id) => ({ id, type: "paragraph", text: "carried" });
    const p = (id, value) => paragraph(id, value);
    // The JSON of a sentinel line with its words edited (alt "A" or text "carried").
    const json = (line, id = null) => {
      let out = line.slice("<!--bp:block ".length, -"-->".length).replace('"alt":"A"', '"alt":"B"').replace('"carried"', '"carried!"');
      return id ? out.replace(/"id":"[^"]*"/, `"id":"${id}"`) : out;
    };
    const lineOf = (md, id) => md.split("\n").find((line) => line.startsWith(`<!--bp:block {"id":"${id}"`));
    const drop = (md, id) => md.split("\n\n").filter((chunk) => !chunk.startsWith(`<!--bp:block {"id":"${id}"`)).join("\n\n");
    const rows = [];
    for (const [kind, make] of [["image", image], ["paragraph", carried]]) {
      const mid = [p("p0", "Before"), make("x"), p("p2", "After")];
      rows.push(
        [`${kind}: marker dropped`, mid, (md) => md.replace(lineOf(md, "x"), json(lineOf(md, "x"))), "refused"],
        [`${kind}: marker broken with a space`, mid, (md) => md.replace(lineOf(md, "x"), "<!--bp :block " + json(lineOf(md, "x")) + "-->"), "refused"],
        [`${kind}: marker dropped, --> kept`, mid, (md) => md.replace(lineOf(md, "x"), json(lineOf(md, "x")) + "-->"), "refused"],
        [`${kind}: marker dropped, id edited`, mid, (md) => md.replace(lineOf(md, "x"), json(lineOf(md, "x"), "y")), "refused"],
        [`${kind}: first block, marker dropped`, [make("x"), p("p2", "After")], (md) => md.replace(lineOf(md, "x"), json(lineOf(md, "x"))), "refused"],
        [`${kind}: last block, marker dropped`, [p("p0", "Before"), make("x")], (md) => md.replace(lineOf(md, "x"), json(lineOf(md, "x"))), "refused"],
        [`${kind}: two side by side, one edited`, [p("p0", "Before"), make("x"), make("z"), p("p2", "After")], (md) => md.replace(lineOf(md, "z"), json(lineOf(md, "z"))), "refused"],
        [`${kind}: deleted, its JSON put at the start`, mid, (md) => json(lineOf(md, "x")) + "\n\n" + drop(md, "x"), "refused"],
        [`${kind}: deleted, its JSON put at the end`, mid, (md) => drop(md, "x") + "\n\n" + json(lineOf(md, "x")), "refused"],
        [`${kind}: deleted, its JSON put in a neighbour's words`, mid, (md) => drop(md, "x").replace("After", "After " + json(lineOf(md, "x"))), "refused"],
        [`${kind}: deleted, its JSON put as a list item`, mid, (md) => drop(md, "x") + "\n\n- " + json(lineOf(md, "x")), "refused"],
        [`${kind}: deleted, its JSON put as a heading`, mid, (md) => drop(md, "x") + "\n\n# " + json(lineOf(md, "x")), "refused"],
        [`${kind}: deleted, its JSON put in a fence`, mid, (md) => drop(md, "x") + "\n\n```json\n" + json(lineOf(md, "x")) + "\n```", "refused"],
        // A paragraph's id passes to the paragraph typed in after it (realign), so the
        // block reads as edited and gets that notice; an image's id has no taker.
        [`${kind}: deleted, and a letter typed far away`, mid, (md) => drop(md, "x").replace("After", "Afterz"),
          (kind === "image" ? REMOVE : EDIT).replace("%N", "2")],
        [`${kind}: deleted alone`, mid, (md) => drop(md, "x"), ["p0", "p2"]],
        [`${kind}: two deleted alone`, [p("p0", "Before"), make("x"), make("z"), p("p2", "After")], (md) => drop(drop(md, "x"), "z"), ["p0", "p2"]],
        [`${kind}: deleted with a plain paragraph`, mid, (md) => drop(md, "x").replace("After", "").replace(/\n+$/, ""), ["p0"]],
      );
    }
    const failed = [];
    for (const [name, blocks, change, want] of rows) {
      const { canvas, batches, server } = await mount(clone(blocks));
      all.push(canvas);
      canvas.toggleSourceMode();
      const textarea = canvas.querySelector(".bp-canvas-source");
      const next = change(textarea.value);
      watchValueWrites(textarea).type(next);
      const flushed = canvas.flushPendingChanges();
      canvas.toggleSourceMode();
      const still = canvas.querySelector(".bp-canvas-source");
      const said = notice(canvas);
      if (Array.isArray(want)) {
        if (still !== null || JSON.stringify(server.map((block) => block.id)) !== JSON.stringify(want)) {
          failed.push(`${name}: saved ${JSON.stringify(server.map((block) => block.id))}, open ${still !== null}`);
        }
        continue;
      }
      const refused = flushed === false && still !== null && still.value === next && batches.length === 0 &&
        JSON.stringify(server) === JSON.stringify(blocks);
      const named = want === "refused" ? [EDIT, REMOVE].some((text) => text.replace("%N", "") === (said || "").replace(/\d+/, "")) : said === want;
      if (!refused || !named) failed.push(`${name}: refused ${refused}, notice ${JSON.stringify(said)}`);
    }

    // A batch the fold refuses is refused whatever the Paper holds (here no block is
    // shown as JSON), with the notice that names no block.
    {
      const blocks = [p("p0", "Before"), p("p2", "After")];
      const { canvas, batches } = await mount(clone(blocks));
      all.push(canvas);
      canvas.toggleSourceMode();
      canvas._ro = () => [{ op: "patch-block", id: "not-there", patch: {} }];
      const textarea = canvas.querySelector(".bp-canvas-source");
      const next = textarea.value.replace("Before", "Before!");
      watchValueWrites(textarea).type(next);
      const flushed = canvas.flushPendingChanges();
      const still = canvas.querySelector(".bp-canvas-source");
      if (flushed !== false || batches.length !== 0 || !still || still.value !== next ||
        notice(canvas) !== "Not saved: source mode could not read this change. Your text is kept.") {
        failed.push(`a batch the fold refuses: flushed ${flushed}, ${batches.length} batches, notice ${JSON.stringify(notice(canvas))}`);
      }
    }
    assert.deepEqual(failed, [], "every outcome row ends as it must");
  }

  if (runs("duplicate")) {
    const carried = { id: "x", type: "paragraph", text: "carried" };
    const { canvas, server } = await mount(clone([paragraph("p0", "Before"), carried]));
    all.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const line = textarea.value.split("\n").find((text) => text.startsWith("<!--bp:block"));
    watchValueWrites(textarea).type(textarea.value + "\n\n" + line);
    canvas.toggleSourceMode();
    assert.equal(server.length, 3, "the copy is saved");
    assert.deepEqual(server[1], carried, "the block stays as it was");
    assert.deepEqual({ ...server[2], id: "x" }, carried, "the copy holds the same keys");
    assert.equal(new Set(server.map((block) => block.id)).size, 3, "under an id of its own");
  }

  // readme.json: an unedited save gives back other blocks than stored (its marks, and
  // the editor's own save rewrites block 4's code+strong run as nested nodes,
  // task-7a92f596371dc4c1), so source mode opens read-only and names the first.
  if (runs("readme")) {
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

  console.log(`source wall carriers mounted: ${Object.keys(shapes).length} shapes, refused/put back/move/delete, edges, outcome, duplicate, readme.json: passed`);
} finally {
  for (const canvas of all) canvas.remove();
}
process.exit(0);
