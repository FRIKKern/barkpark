// The inside-edit sweep (task-368b4fe38e75712d): the source-mode wall's named callout
// rule (canvas/source-save.js) is the whole class of "an edit inside a block writes
// over what it stores". For every block of every shared Portable Doc fixture and seed
// Paper that source mode opens writable, one character is typed inside that block's
// own Markdown, once on each line whose text holds a letter (just after its first
// letter; a line's markers, a fence line and a block's JSON line are not its text).
// The save runs as it would (sourceSaved: realign, the editor's projection, runToOps,
// the patch.ex fold) and the result, with the typed character taken out again, must
// be what was stored.
//   - With the rule on, no edit loses anything: a callout with a body never opens.
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
import { sourceSaved } from "./source-save.js";
import { blocksToMarkdown, firstLoss, markdownToBlockSpans, markdownToBlocks, sourceLoss } from "../markdown.js";

const REPO = fileURLToPath(new URL("../../../../../", import.meta.url));
const GOLDENS = join(REPO, "api/priv/portable_doc/goldens");
const TYPED = "Ж";

function papers() {
  const out = [];
  for (const dir of ["blocks", "limits"]) {
    for (const name of readdirSync(join(GOLDENS, dir)).sort()) {
      if (!name.endsWith(".json")) continue;
      const golden = JSON.parse(readFileSync(join(GOLDENS, dir, name), "utf8"));
      out.push([`${dir}/${name}`, [{ id: "fixture", ...golden.input }]]);
    }
  }
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

function sweep(rule) {
  const counts = { papers: 0, writable: 0, blocks: 0, lines: 0, losers: [] };
  for (const [name, stored] of papers()) {
    counts.papers += 1;
    const live = docToBlocks(normalizeCanvasDoc(view.toDoc(stored), stored));
    const opts = rule === "on" ? {} : lifted;
    const saved = (base) => (parsed) => sourceSaved(base, parsed, view, opts);
    if (sourceLoss(stored, saved(stored)) || sourceLoss(live, saved(live))) continue;
    counts.writable += 1;
    const md = blocksToMarkdown(live);
    assert.ok(!md.includes(TYPED), `${name}: the typed character is not already in the Paper`);
    const lines = md.split("\n");
    const { spans } = markdownToBlockSpans(md);
    spans.forEach(([from, to], index) => {
      counts.blocks += 1;
      for (let line = from; line < to; line++) {
        const text = lines[line];
        // Not text: a block's JSON line, a fence line (its info names the block).
        if (text.startsWith("<!--bp:") || /^(`{3,}|~{3,})/.test(text)) continue;
        // The text starts after the line's markers (a heading's #, a quote's >, a
        // callout's [!tone], a list item's bullet, number or box).
        const marker = /^(#{1,6} |> ?)?(\[![^\]]*\][+-]? ?)?(- \[[ x]\] |[-+*] |\d+[.)] )?/.exec(text)[0].length;
        const found = text.slice(marker).search(/\p{L}/u);
        if (found === -1) continue;
        const letter = marker + found;
        counts.lines += 1;
        const typed = [...lines];
        typed[line] = text.slice(0, letter + 1) + TYPED + text.slice(letter + 1);
        const after = sourceSaved(stored, markdownToBlocks(typed.join("\n")), view, lifted);
        const landed = JSON.stringify(after).includes(TYPED);
        const loss = firstLoss(stored, withoutTyped(after));
        if (!landed || loss) {
          const type = (live[index] && live[index].type) || "block";
          counts.losers.push(`${name} block ${index + 1} (${type}) line ${line + 1}: ${landed ? `${loss.type} ${loss.path}` : "the typed character was not saved"}`);
        }
      }
    });
  }
  return counts;
}

try {
  const on = sweep("on");
  console.log(`inside-edit sweep, rule on: ${on.papers} Papers, ${on.writable} writable, ${on.blocks} blocks, ${on.lines} lines, ${on.losers.length} losers`);
  assert.deepEqual(on.losers, [], "with the callout rule on, no edit inside a writable block loses anything");

  const off = sweep("lifted");
  console.log(`inside-edit sweep, rule lifted: ${off.papers} Papers, ${off.writable} writable, ${off.blocks} blocks, ${off.lines} lines, ${off.losers.length} losers`);
  const kinds = [...new Set(off.losers.map((loser) => loser.replace(/^.* \((\w+)\) line \d+: (\w+) (\S+).*$/, "$1 $3").replace(/\[\d+\]/g, "")))];
  for (const loser of off.losers.slice(0, 20)) console.log(`  ${loser}`);
  assert.deepEqual(kinds, ["callout content.value"], "lifted, the sweep finds the callout body and nothing else");
  console.log("source inside-edit sweep: passed");
} finally {
  canvas.remove();
}
process.exit(0);
