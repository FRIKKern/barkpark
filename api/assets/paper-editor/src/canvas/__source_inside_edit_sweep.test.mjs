// The inside-edit sweep (task-368b4fe38e75712d): in a Paper source mode opens
// writable, a key typed on any line of its Markdown saves that key and nothing else.
// For every shared Portable Doc fixture and seed Paper that opens writable, one
// character is typed on every line source mode shows, and the save runs as it would
// (sourceSaved: realign, the editor's projection, runToOps, the patch.ex fold). No line
// is skipped; where the key goes depends on the line:
//   text      after the first letter of the line's own words (past a heading's #, a
//             quote's >, a callout's [!tone], a list item's marker), or at its end
//             when it has none; a code line at its start; a fence that opens a code
//             block, or a diagram with a caption, at its end (the language or the
//             caption); a block sentinel after the first letter of its first string
//             that is not an id or a type
//   no words  a divider, a closing fence, a blank line, a diagram fence with no
//             caption, a sentinel with no string to type in: the key changes what
//             the line is, and the textarea shows that
// A line with words must save, with the typed character taken out again, exactly what
// was stored, and the reader must show the same words (reader-inline.js). A line with
// no words must keep every block the key did not change. Before any typing, each prose
// block's line must show the words the reader shows.
//   - With the callout rule on, nothing is lost: a callout with a body never opens.
//   - With the rule lifted (here only), the sweep finds the callout body and nothing
//     else, so the one named rule covers the class.
// A key typed into a sentinel's punctuation leaves JSON that does not read; source
// mode refuses to save that (brokenSentinel), and the sweep checks it does.
// Run: node src/canvas/__source_inside_edit_sweep.test.mjs

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { mount } from "./source-flush-mounted-harness.mjs";
import { normalizeCanvasDoc } from "./canvas-document.js";
import { docToBlocks } from "./run-convert.js";
import { sourceSaved } from "./source-save.js";
import { sourceWallGoldens } from "../__source_wall_goldens.mjs";
import { blocksToMarkdown, brokenSentinel, firstLoss, markdownToBlockSpans, markdownToBlocks, sourceLoss } from "../markdown.js";
import { readerInline } from "../markdown/reader-inline.js";
import { SENTINEL_OPEN } from "../markdown/shared.js";

const REPO = fileURLToPath(new URL("../../../../../", import.meta.url));
const TYPED = "Ж";

function papers() {
  const out = [];
  for (const [name, block] of sourceWallGoldens()) out.push([name, [block]]);
  for (const dir of [".demo-content/papers", ".demo-content/repo-papers", "api/test/support/fixtures/bpml"]) {
    for (const name of readdirSync(join(REPO, dir)).sort()) {
      if (!name.endsWith(".json")) continue;
      const json = JSON.parse(readFileSync(join(REPO, dir, name), "utf8"));
      out.push([`${dir}/${name}`, Array.isArray(json) ? json : json.blocks || []]);
    }
  }
  // No shared fixture or seed Paper holds a callout with a body, so the one shape the
  // named rule covers is added here, as the wall's own test builds it.
  const text = (value) => [{ type: "text", value }];
  out.push(["built/callout-with-a-body", [
    { id: "p1", type: "paragraph", content: text("Elsewhere") },
    { id: "c1", type: "callout", tone: "note", content: text("head words"), slots: { body: [
      { id: "b1", type: "paragraph", content: text("body one") },
      { id: "b2", type: "paragraph", content: text("body two") },
    ] } },
  ]]);
  return out;
}

// The editor's own schema, from one mounted canvas: the wall projects with it.
const { canvas } = await mount([]);
const view = {
  toDoc: (blocks) => canvas._editor.schema.nodeFromJSON(canvas._rt(blocks)).toJSON(),
  toOps: (...args) => canvas._ro(...args),
};
const lifted = { calloutBody: "lifted" };

function withoutTyped(value) {
  if (typeof value === "string") return value.split(TYPED).join("");
  if (Array.isArray(value)) return value.map(withoutTyped);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, withoutTyped(v)]));
  return value;
}

const wrap = (block) => [{ type: "paragraph", content: readerInline(block) || [] }];
// The words the reader shows for `after` differ from those for `before`.
const readerDiffers = (before, after) => readerInline(before) !== null && Boolean(firstLoss(wrap(before), wrap(after)));

// Where the key goes in a block sentinel: after the first letter of its first string
// value whose key is not an id or a type, or -1.
function sentinelTextAt(line) {
  const strings = /"((?:[^"\\]|\\.)*)"(\s*:)?/g;
  let key = null;
  for (let m = strings.exec(line); m; m = strings.exec(line)) {
    if (m[2]) {
      key = m[1];
      continue;
    }
    if (key === "id" || key === "type") continue;
    for (let k = 0; k < m[1].length; k++) {
      if (m[1][k] === "\\") {
        k += m[1][k + 1] === "u" ? 5 : 1;
        continue;
      }
      if (/\p{L}/u.test(m[1][k])) return m.index + 1 + k + 1;
    }
  }
  return -1;
}

// [at, words]: where the key goes on `text` and whether the line has words of its own.
function placement(text, lineIndex, span, block) {
  const end = text.length;
  if (span === null || text.trim() === "") return [0, false];
  const type = block && block.type;
  const [from, to] = span;
  if (type === "code" || type === "diagram") {
    const fence = /^(`{3,}|~{3,})/.test(text);
    if (fence && lineIndex === from) return [end, type === "code" || /^\S+\s+\S/.test(text.replace(/^(`{3,}|~{3,})/, ""))];
    if (fence && lineIndex === to - 1) return [end, false];
    return [0, true];
  }
  if (text.startsWith(SENTINEL_OPEN)) {
    const at = sentinelTextAt(text);
    return at === -1 ? [end, false] : [at, true];
  }
  if (type === "divider") return [end, false];
  const marker = /^(#{1,6} |> ?)?(\[![^\]]*\][+-]? ?)?(- \[[ x]\] |[-+*] |\d+[.)] )?/.exec(text)[0].length;
  const found = text.slice(marker).search(/\p{L}/u);
  return found === -1 ? [end, true] : [marker + found + 1, true];
}

const sameBlock = (a, b) => JSON.stringify({ ...a, id: null }) === JSON.stringify({ ...b, id: null });

function sweep(rule) {
  const counts = { papers: 0, writable: 0, blocks: 0, shown: 0, lines: 0, words: 0, noWords: 0, refused: 0, skipped: 0, losers: [], typedTypes: new Set(), corpusTypes: new Set(), readOnly: new Map() };
  const opts = rule === "on" ? {} : lifted;
  for (const [name, stored] of papers()) {
    counts.papers += 1;
    for (const block of stored) counts.corpusTypes.add(block.type);
    const live = docToBlocks(normalizeCanvasDoc(view.toDoc(stored), stored));
    const saved = (base) => (parsed) => sourceSaved(base, parsed, view, opts);
    const wall = sourceLoss(stored, saved(stored)) || sourceLoss(live, saved(live));
    if (wall) {
      for (const block of stored) {
        const why = counts.readOnly.get(block.type) || new Set();
        why.add(`${wall.type} ${wall.path}`.replace(/\[\d+\]/g, ""));
        counts.readOnly.set(block.type, why);
      }
      continue;
    }
    counts.writable += 1;
    const md = blocksToMarkdown(live);
    assert.ok(!md.includes(TYPED), `${name}: the typed character is not already in the Paper`);
    assert.equal(live.length, stored.length, `${name}: the editor shows every stored block`);
    const lines = md.split("\n");
    const { blocks: parsed, spans } = markdownToBlockSpans(md);
    counts.blocks += spans.length;
    const lose = (where, why) => counts.losers.push(`${name} ${where}: ${why}`);
    stored.forEach((block, index) => {
      if (readerInline(block) === null) return;
      counts.shown += 1;
      if (readerDiffers(block, parsed[index])) lose(`block ${index + 1} (${block.type})`, "its line shows other words than the reader");
    });
    const spanOf = (line) => spans.findIndex(([from, to]) => line >= from && line < to);
    lines.forEach((text, line) => {
      const index = spanOf(line);
      const span = index === -1 ? null : spans[index];
      const [at, words] = placement(text, line, span, live[index]);
      const typed = [...lines];
      typed[line] = text.slice(0, at) + TYPED + text.slice(at);
      const typedMd = typed.join("\n");
      const type = index === -1 ? "between blocks" : live[index].type;
      const where = `block ${index + 1} (${type}) line ${line + 1}`;
      counts.lines += 1;
      if (index !== -1) counts.typedTypes.add(type);
      if (brokenSentinel(typedMd) !== -1) {
        // The key broke a sentinel's JSON: source mode refuses the save (and the line
        // must be one the sweep had no words to type in).
        counts.refused += 1;
        if (words) lose(where, "a key typed in a sentinel's words broke its JSON");
        return;
      }
      const after = sourceSaved(stored, markdownToBlocks(typedMd), view, lifted);
      if (!JSON.stringify(after).includes(TYPED)) return lose(where, "the typed character was not saved");
      const clean = withoutTyped(after);
      const byId = new Map(clean.map((block) => [block.id, block]));
      if (words) {
        counts.words += 1;
        const loss = firstLoss(stored, clean);
        if (loss) return lose(where, `${loss.type} ${loss.path}`);
        const unread = stored.findIndex((block) => readerDiffers(block, byId.get(block.id)));
        if (unread !== -1) lose(where, `the reader shows other words for block ${unread + 1}`);
        return;
      }
      counts.noWords += 1;
      const now = markdownToBlocks(typedMd);
      let head = 0;
      while (head < parsed.length && head < now.length && sameBlock(parsed[head], now[head])) head++;
      let tail = 0;
      while (tail < parsed.length - head && tail < now.length - head &&
        sameBlock(parsed[parsed.length - 1 - tail], now[now.length - 1 - tail])) tail++;
      stored.forEach((block, i) => {
        if (i >= head && i < stored.length - tail) return;
        const kept = byId.get(block.id);
        const loss = kept ? firstLoss([block], [kept]) : { type: block.type, path: "(gone)" };
        if (loss || readerDiffers(block, kept)) lose(where, `block ${i + 1}, untouched, lost ${loss ? `${loss.type} ${loss.path}` : "its words"}`);
      });
    });
  }
  return counts;
}

function report(label, c) {
  console.log(`inside-edit sweep, ${label}: ${c.papers} Papers, ${c.writable} writable, ${c.blocks} blocks, ` +
    `${c.shown} prose blocks showing the reader's words, ${c.lines} lines typed (${c.words} with words, ` +
    `${c.noWords} without, ${c.refused} refused as broken JSON), ${c.skipped} skipped, ${c.losers.length} losers`);
}

try {
  const on = sweep("on");
  report("rule on", on);
  for (const loser of on.losers.slice(0, 20)) console.log(`  ${loser}`);
  assert.equal(on.skipped, 0, "no line is skipped");
  assert.deepEqual(on.losers, [], "with the callout rule on, no key typed in a writable Paper loses anything");
  const typed = [...on.typedTypes].sort();
  const corpus = [...on.corpusTypes].sort();
  console.log(`  block types typed in (${typed.length}): ${typed.join(", ")}`);
  console.log(`  block types in the corpus (${corpus.length}): ${corpus.join(", ")}`);
  for (const type of corpus.filter((type) => !on.typedTypes.has(type))) {
    console.log(`  not typed in: ${type}, every Paper holding it is read-only for ${[...on.readOnly.get(type)].sort().join("; ")}`);
  }

  const off = sweep("lifted");
  report("rule lifted", off);
  const kinds = [...new Set(off.losers.map((loser) => loser.replace(/^.* \((\w+)\) line \d+: (\w+) (\S+).*$/, "$1 $3").replace(/\[\d+\]/g, "")))];
  for (const loser of off.losers.slice(0, 20)) console.log(`  ${loser}`);
  assert.deepEqual(kinds, ["callout content.value"], "lifted, the sweep finds the callout body and nothing else");
  console.log("source inside-edit sweep: passed");
} finally {
  canvas.remove();
}
process.exit(0);
