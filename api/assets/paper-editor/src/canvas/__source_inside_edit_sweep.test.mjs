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
//             caption)
//   sentinel  a block shown as its JSON sentinel, after the first letter of its first
//             string that is not an id or a type: source mode does not edit such a
//             block, so the save must be refused (changedSentinel)
//             Each sentinel line also gets every edit below, judged by the guard on
//             what the save would store alone (sentinelRefusal, not changedSentinel):
//             each must store the block unchanged, store it deleted by a save that
//             only deletes, or be refused, never a block holding JSON in its words,
//             never two blocks with one id. The one edit that only deletes is the
//             line deleted: each must save. Every other edit that leaves the block out
//             of the save must be refused for deleting it and doing more, counted from
//             the edits typed, not from the result
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
// Run: node src/canvas/__source_inside_edit_sweep.test.mjs

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { mount } from "./source-flush-mounted-harness.mjs";
import { normalizeCanvasDoc } from "./canvas-document.js";
import { docToBlocks } from "./run-convert.js";
import { sentinelRefusal, settledBlocks, sourceSaved, sourceStored, sourceWallLoss } from "./source-save.js";
import { canonicalJSON } from "./projection-json.js";
import { clampLockedPrefix, realignAcrossCommits } from "./source-realign.js";
import { jsonDepth, MAX_VALUE_DEPTH, sharedFixtureWalk } from "../__source_wall_goldens.mjs";
import { blocksToMarkdown, changedSentinel, firstLoss, markdownToBlockSpans, markdownToBlocks } from "../markdown.js";
import { readerInline } from "../markdown/reader-inline.js";
import { SENTINEL_CLOSE, SENTINEL_OPEN } from "../markdown/shared.js";

const REPO = fileURLToPath(new URL("../../../../../", import.meta.url));
const TYPED = "Ж";

function papers() {
  const out = [];
  // Every document of the shared fixtures, read by the same walk the wall's fixture
  // test pins, but those past the value-depth limit, which no Paper can hold.
  for (const [name, blocks] of sharedFixtureWalk().docs) {
    if (jsonDepth({ blocks }) <= MAX_VALUE_DEPTH) out.push([`goldens/${name}`, blocks]);
  }
  for (const dir of [".demo-content/papers", ".demo-content/repo-papers", "api/test/support/fixtures/bpml",
    "api/test/support/fixtures/portable-doc-validate/valid"]) {
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
  // An empty run projects to a doc with no content key.
  toDoc: (blocks) => ({ content: [], ...canvas._editor.schema.nodeFromJSON(canvas._rt(blocks)).toJSON() }),
  toOps: (...args) => canvas._ro(...args),
};
const lifted = { calloutBody: "lifted" };
const settle = (blocks) => settledBlocks(blocks, view);

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

// The edits each sentinel line `l` (line `i` of `lines`) gets: the review's, and
// machine-made ones (a character before, after and inside the line, the line wrapped,
// split, duplicated, deleted, moved under the next block).
function sentinelEdits(lines, i) {
  const l = lines[i];
  const mid = Math.floor(l.length / 2);
  const at = (text) => { const next = [...lines]; next[i] = text; return next.join("\n"); };
  const without = () => { const next = [...lines]; next.splice(i, lines[i + 1] === "" ? 2 : 1); return next; };
  const movedDown = () => {
    const next = without();
    let j = i;
    while (j < next.length && next[j] !== "") j++;
    next.splice(j, 0, "", l);
    return next.join("\n");
  };
  return {
    "key before": at(TYPED + l), "! before": at("!" + l), "key after": at(l + TYPED),
    "words after": at(l + " more words"), "key in the middle": at(l.slice(0, mid) + TYPED + l.slice(mid)),
    "key after the marker": at(SENTINEL_OPEN + TYPED + l.slice(SENTINEL_OPEN.length)),
    "key added to the JSON": at(l.replace(SENTINEL_OPEN + "{", SENTINEL_OPEN + '{"alt2":"q",')),
    "split at 20": at(l.slice(0, 20) + "\n" + l.slice(20)), "split in the middle": at(l.slice(0, mid) + "\n" + l.slice(mid)),
    "duplicated": at(l + "\n\n" + l), "duplicated first": l + "\n\n" + lines.join("\n"),
    "deleted": without().join("\n"), "indented": at("    " + l),
    "quoted": at("> " + l), "listed": at("- " + l), "headed": at("# " + l), "numbered": at("1. " + l),
    "fenced": at("```\n" + l + "\n```"), "moved under the next block": movedDown(),
  };
}

// Every string in `value`.
const strings = (value) => typeof value === "string" ? [value]
  : Array.isArray(value) ? value.flatMap(strings)
    : value && typeof value === "object" ? Object.values(value).flatMap(strings) : [];

const sameBlock = (a, b) => JSON.stringify({ ...a, id: null }) === JSON.stringify({ ...b, id: null });

function sweep(rule) {
  const counts = { rows: [], papers: 0, writable: 0, blocks: 0, shown: 0, lines: 0, words: 0, noWords: 0, refused: 0, lost: 0, edits: 0, guardKept: 0, guardDeleted: 0, guardRefused: 0, removalRefused: 0, removalTyped: 0, fenceRefused: 0, skipped: 0, losers: [], typedTypes: new Set(), writableTypes: new Set(), corpusTypes: new Set(), readOnly: new Map() };
  const opts = rule === "on" ? {} : lifted;
  for (const [name, stored] of papers()) {
    counts.papers += 1;
    for (const block of stored) counts.corpusTypes.add(block.type);
    const live = docToBlocks(normalizeCanvasDoc(view.toDoc(stored), stored));
    const wall = sourceWallLoss(stored, live, view, opts);
    if (wall) {
      counts.rows.push([name, `read-only: ${wall.type} ${wall.path}`]);
      for (const block of stored) {
        const why = counts.readOnly.get(block.type) || new Set();
        why.add(`${wall.type} ${wall.path}`.replace(/\[\d+\]/g, ""));
        counts.readOnly.set(block.type, why);
      }
      continue;
    }
    counts.writable += 1;
    for (const block of stored) counts.writableTypes.add(block.type);
    const before = { lines: counts.lines, words: counts.words, noWords: counts.noWords, refused: counts.refused, losers: counts.losers.length };
    const row = () => counts.rows.push([name, `writable: ${counts.lines - before.lines} lines typed, ` +
      `kept ${counts.words + counts.noWords - before.words - before.noWords}, refused ${counts.refused - before.refused}, ` +
      `losers ${counts.losers.length - before.losers}`]);
    const md = blocksToMarkdown(live);
    assert.ok(!md.includes(TYPED), `${name}: the typed character is not already in the Paper`);
    assert.equal(live.length, stored.length, `${name}: the editor shows every stored block`);
    const lines = md.split("\n");
    const { blocks: parsed, spans } = markdownToBlockSpans(md);
    const kept = stored;
    counts.blocks += spans.length;
    const lose = (where, why) => counts.losers.push(`${name} ${where}: ${why}`);
    stored.forEach((block, index) => {
      if (readerInline(block) === null) return;
      counts.shown += 1;
      if (readerDiffers(block, parsed[index])) lose(`block ${index + 1} (${block.type})`, "its line shows other words than the reader");
    });
    const sentinelIds = new Set(live.filter((b, i) => lines[spans[i] ? spans[i][0] : -1]?.startsWith(SENTINEL_OPEN)).map((b) => b.id));
    const spanOf = (line) => spans.findIndex(([from, to]) => line >= from && line < to);
    lines.forEach((text, line) => {
      // Each line ends in one outcome: kept (with words or without), refused, refused for
      // a fence it opened, lost (a loser), or skipped when it reached none of them.
      const losers = counts.losers.length;
      const outcome = typeLine(text, line);
      if (counts.losers.length > losers) counts.lost += 1;
      else if (outcome) counts[outcome] += 1;
      else counts.skipped += 1;
    });
    row();
    function typeLine(text, line) {
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
      if (text.startsWith(SENTINEL_OPEN)) {
        // A block shown as JSON is not edited: source mode must refuse the save.
        if (changedSentinel(typedMd, md) === -1) lose(where, "a key typed in a sentinel was not refused");
        const block = live[index];
        const payload = text.trim().slice(SENTINEL_OPEN.length, -SENTINEL_CLOSE.length);
        const was = canonicalJSON(stored[index]);
        for (const [edit, editedMd] of Object.entries(sentinelEdits(lines, line))) {
          counts.edits += 1;
          const laid = clampLockedPrefix(live, realignAcrossCommits(live, live, markdownToBlocks(editedMd)));
          const { saved } = sourceStored(stored, laid, view);
          if (edit !== "deleted" && saved && !saved.some((b) => b.id === block.id)) counts.removalTyped += 1;
          const refusal = sentinelRefusal(stored, live, md, saved, settle);
          if (refusal && edit === "deleted") lose(where, `the line deleted alone was refused (${refusal.kind})`);
          if (refusal) {
            counts.guardRefused += 1;
            if (refusal.kind === "removal") counts.removalRefused += 1;
            continue;
          }
          const ids = saved.map((b) => b.id);
          if (new Set(ids).size !== ids.length) lose(where, `${edit}: two blocks share an id`);
          const same = saved.find((b) => b.id === block.id);
          if (same && canonicalJSON(same) !== was && canonicalJSON(same) !== canonicalJSON(block)) {
            lose(where, `${edit}: the block shown as JSON was stored changed`);
          }
          const storedById = new Map(stored.map((b) => [b.id, canonicalJSON(b)]));
          const json = saved.find((b) => storedById.get(b.id) !== canonicalJSON(b) &&
            strings(b).some((s) => s.includes("bp:block") || s.includes(payload)));
          if (json) lose(where, `${edit}: block ${json.id} holds the JSON in its words`);
          if (same) counts.guardKept += 1;
          else counts.guardDeleted += 1;
        }
        return "refused";
      }
      if (changedSentinel(typedMd, md) !== -1) return lose(where, "a key typed outside any sentinel was refused");
      const laidTyped = clampLockedPrefix(live, realignAcrossCommits(live, live, markdownToBlocks(typedMd)));
      const storedTyped = sourceStored(stored, laidTyped, view).saved;
      if (sentinelRefusal(stored, live, md, storedTyped, settle)) {
        // Refused rightly only when the key opened a fence that takes a sentinel line
        // into its body: that save would store the JSON as the fence's words.
        const whole = (text) => markdownToBlocks(text).filter((b) => b.id && sentinelIds.has(b.id)).length;
        if (whole(typedMd) < whole(md)) return "fenceRefused";
        return lose(where, "the stored-result guard refused a key typed outside any sentinel");
      }
      const after = sourceSaved(stored, markdownToBlocks(typedMd), view, { ...lifted, realignTo: live });
      if (!JSON.stringify(after).includes(TYPED)) return lose(where, "the typed character was not saved");
      const clean = withoutTyped(after);
      const byId = new Map(clean.map((block) => [block.id, block]));
      if (words) {
        const loss = firstLoss(kept, clean);
        if (loss) return lose(where, `${loss.type} ${loss.path}`);
        const unread = kept.findIndex((block) => readerDiffers(block, byId.get(block.id)));
        if (unread !== -1) lose(where, `the reader shows other words for block ${unread + 1}`);
        return "words";
      }
      const now = markdownToBlocks(typedMd);
      let head = 0;
      while (head < parsed.length && head < now.length && sameBlock(parsed[head], now[head])) head++;
      let tail = 0;
      while (tail < parsed.length - head && tail < now.length - head &&
        sameBlock(parsed[parsed.length - 1 - tail], now[now.length - 1 - tail])) tail++;
      // The blocks before and after what the key changed, by position (an id may move
      // to a neighbour when a line is typed between blocks; that is not a loss).
      kept.forEach((block, i) => {
        if (i >= head && i < kept.length - tail) return;
        const now = i < head ? clean[i] : clean[clean.length - (kept.length - i)];
        const loss = now ? firstLoss([block], [{ ...now, id: block.id }]) : { type: block.type, path: "(gone)" };
        if (loss || readerDiffers(block, now)) lose(where, `block ${i + 1}, untouched, lost ${loss ? `${loss.type} ${loss.path}` : "its words"}`);
      });
      return "noWords";
    }
  }
  return counts;
}

// The same count made apart from the sweep: the lines of every Paper's Markdown that
// opens writable, and the block types in all of them, read from the files again.
function census(rule) {
  const opts = rule === "on" ? {} : lifted;
  let lines = 0;
  const types = new Set();
  for (const [, stored] of papers()) {
    for (const block of stored) types.add(block.type);
    const live = docToBlocks(normalizeCanvasDoc(view.toDoc(stored), stored));
    if (!sourceWallLoss(stored, live, view, opts)) lines += blocksToMarkdown(live).split("\n").length;
  }
  return { lines, types: [...types].sort() };
}

// Every line the census counts reached exactly one outcome, none was skipped.
function tally(rule, c) {
  const { lines, types } = census(rule);
  const outcomes = c.words + c.noWords + c.refused + c.fenceRefused + c.lost + c.skipped;
  assert.equal(c.lines, lines, `${rule}: the sweep typed on every line the census counts`);
  assert.equal(outcomes, lines, `${rule}: kept + refused + fence-refused + lost + skipped is the census's line count`);
  assert.equal(c.skipped, 0, `${rule}: no line is skipped`);
  return types;
}

function report(label, c) {
  console.log(`inside-edit sweep, ${label}: ${c.papers} Papers, ${c.writable} writable, ${c.blocks} blocks, ` +
    `${c.shown} prose blocks showing the reader's words; ${c.lines} lines typed: ` +
    `kept ${c.words + c.noWords} (${c.words} with words, ${c.noWords} without), refused ${c.refused}, ` +
    `refused for opening a fence over a sentinel ${c.fenceRefused}, lost ${c.lost}, skipped ${c.skipped}; ` +
    `${c.losers.length} losers`);
  console.log(`  sentinel lines, ${c.edits} edits judged by the stored-result guard alone: ` +
    `kept unchanged ${c.guardKept}, deleted whole ${c.guardDeleted}, refused ${c.guardRefused} ` +
    `(${c.removalRefused} for deleting the block and doing more)`);
  assert.equal(c.guardKept + c.guardDeleted + c.guardRefused, c.edits, "each sentinel edit ends in one of the three");
  assert.equal(c.removalRefused, c.removalTyped,
    "the deletion refusals are the edits other than the deletion that leave the block out of the save");
}

try {
  const on = sweep("on");
  report("rule on", on);
  for (const loser of on.losers.slice(0, 20)) console.log(`  ${loser}`);
  const censusTypes = tally("on", on);
  for (const [name, says] of on.rows.filter(([name]) => name.includes("portable-doc-validate"))) console.log(`  ${name}: ${says}`);
  assert.deepEqual(on.losers, [], "with the callout rule on, no key typed in a writable Paper loses anything");
  const typed = [...on.typedTypes].sort();
  const corpus = [...on.corpusTypes].sort();
  console.log(`  block types typed in (${typed.length}): ${typed.join(", ")}`);
  console.log(`  block types in the corpus (${corpus.length}): ${corpus.join(", ")}`);
  for (const type of corpus.filter((type) => !on.typedTypes.has(type))) {
    console.log(`  not typed in: ${type}, every Paper holding it is read-only for ${[...on.readOnly.get(type)].sort().join("; ")}`);
  }
  assert.deepEqual(corpus, censusTypes, "the sweep saw the block types the census reads from the files");
  assert.deepEqual(typed, [...on.writableTypes].sort(), "a key was typed in every block type a writable Paper holds, by name");
  assert.deepEqual(censusTypes.filter((type) => !on.typedTypes.has(type)), [...on.readOnly.keys()].filter((type) => !on.writableTypes.has(type)).sort(),
    "every block type not typed in is held only by Papers that open read-only, and is named above");

  const off = sweep("lifted");
  report("rule lifted", off);
  tally("lifted", off);
  const kinds = [...new Set(off.losers.map((loser) => loser.replace(/^.* \((\w+)\) line \d+: (\w+) (\S+).*$/, "$1 $3").replace(/\[\d+\]/g, "")))];
  for (const loser of off.losers.slice(0, 20)) console.log(`  ${loser}`);
  assert.deepEqual(kinds, ["callout content.value"], "lifted, the sweep finds the callout body and nothing else");
  console.log("source inside-edit sweep: passed");
} finally {
  canvas.remove();
}
process.exit(0);
