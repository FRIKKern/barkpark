#!/usr/bin/env node
// live-volume-denominators.test.mjs — the D102 TRIPWIRE over grip's own prose.
//
//   node --test tooling/grip/test/live-volume-denominators.test.mjs
//
// WHY THIS FILE EXISTS. grip's shipped modules explain themselves with measured
// numbers, and the most perishable kind is a VOLUME DENOMINATOR — "46 of the 62
// stored rows", "the 62-row store", "51 of the store's 62 recipes". The ledger
// under tooling/grip/ledger/ is an append-only SHARED write target: every wave
// of every epic adds rows to it without opening a single one of these modules.
// So a denominator written in the present tense is false the moment somebody
// else commits, and it goes on shipping as if it were a property of the code.
//
// MEASURED, and it is not a hypothetical. On origin/main before this file
// landed, thirteen such sentences shipped across five modules, all of them
// pinned to a 62-row store — a store that a `fold` of tooling/grip/ledger/ read
// at 62 rows on 2026-07-21 and at 354 rows on 2026-09-02. The sharpest one is
// trial-leads-vs-grep.mjs, which shipped the phrase "the current 62-row store":
// the +167-row backfill merged at 87221bfa55 (2026-07-21 22:13:01 +0200) and
// that harness at 50ee37bcbe (22:13:17), so its "current" was already sixteen
// seconds stale when it arrived on main. A number cannot be kept fresh by
// intention.
//
// THE DISCIPLINE THIS ENFORCES (charter D102, the same ruling D23/D37/D52 made
// three times before it): a volume denominator is either RETIRED or written in
// the PAST TENSE with its snapshot named — a sha, or a date — IN THE SAME
// SENTENCE. Restating it with today's total is not a fix; it just resets the
// clock. The snapshot marker is the ONLY exemption, and that is deliberate:
//
//   * NOTHING IS WHITELISTED BY LINE NUMBER. A line-pinned waiver rots on the
//     next insertion above it and then silently exempts whatever slid into its
//     place. There is no waiver list here at all — a sentence earns its way
//     through by carrying its own snapshot, which is the thing a reader needed.
//   * NOTHING IS WHITELISTED BY FILE. A module added tomorrow is scanned by the
//     same glob, because a hand-listed file set measures the author's memory
//     rather than the tree (the lesson class-coverage.test.mjs records).
//
// WHAT THIS DOES NOT MEASURE — declared, not implied:
//   * IT IS A SHAPE SCAN, NOT A FACT CHECK. A sentence that names a sha proves
//     only that a snapshot was NAMED. Whether the number was true at that sha is
//     something only a re-derivation can say, and this test does not run one.
//   * ITS VOCABULARY IS CLOSED. It knows rows, recipes and the `N-row` compound.
//     A new denominator counting "entries", "runs" or "subjects" is invisible
//     until its noun is added below. The count it reports is a floor.
//   * IT SCANS SHIPPED MODULES ONLY — the top-level tooling/grip/*.mjs glob, not
//     this directory. Test files quote retired prose as fixtures (this one does,
//     immediately below), and a corpus that included them would red on its own
//     evidence.

import { test } from "node:test";
import assert from "node:assert/strict";

import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = resolve(HERE, "..");

// ─────────────────────────────────────────────────────────────────────────────
// (A) THE SCANNER
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A live-volume denominator: a count of the store stated as a share of a total.
 *
 * Four shapes, all measured off the prose that actually shipped rather than
 * imagined: `N of [the|those] M [stored|committed|…] rows`, the `M-row`
 * compound, `the store's M recipes`, and a bare `M stored rows`. `\d{2,4}`
 * deliberately skips single digits — "1 of 3 rows" in a worked example is an
 * illustration, not a corpus claim.
 */
const DENOMINATOR = new RegExp(
  [
    String.raw`\b(?:of|out of)\s+(?:the\s+|those\s+|these\s+)?\d{2,4}\s+(?:stored\s+|committed\s+|live\s+|ledger\s+|minted\s+)?(?:rows|recipes)\b`,
    String.raw`\b\d{2,4}-(?:row|recipe)\b`,
    String.raw`\bthe\s+store's\s+\d{2,4}\s+(?:rows|recipes)\b`,
    String.raw`\b\d{2,4}\s+(?:stored|committed|live)\s+(?:rows|recipes)\b`,
  ].join("|"),
  "i",
);

/**
 * The ONE exemption: the sentence names its snapshot. A sha (7-40 hex with at
 * least one DIGIT in it, so ordinary words spelled from a-f — "defaced",
 * "effaced" — are not mistaken for one) or an ISO date.
 */
const SNAPSHOT = /\b(?=[0-9a-f]{7,40}\b)[0-9a-f]*\d[0-9a-f]*\b|\b20\d{2}-\d{2}(?:-\d{2})?\b/;

/**
 * Every prose block in a module: runs of consecutive comment lines (`//`, and
 * the `/** … *\/` block form the census preamble uses) plus runs of long string
 * literals, which is where a USAGE banner lives. Blocks are joined so a sentence
 * WRAPPED across lines is scanned whole — the failure mode of a line-at-a-time
 * scan is that it never sees a sentence's own snapshot marker one line down.
 */
export function proseBlocks(src) {
  const lines = src.split("\n");
  const blocks = [];
  let cur = null;
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    let text = null;
    const comment = raw.match(/^[ \t]*(?:\/\/|\/\*\*?|\*\/|\*) ?(.*)$/);
    if (comment) {
      text = comment[1].replace(/\*\/\s*$/, "");
    } else {
      const literals = [...raw.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]).filter((s) => s.length >= 20);
      if (literals.length) text = literals.join(" ");
    }
    if (text === null) {
      cur = null;
      continue;
    }
    text = text.replace(/\\n/g, " ");
    if (!cur) {
      cur = { line: i + 1, text: "" };
      blocks.push(cur);
    }
    cur.text += (cur.text ? " " : "") + text;
  }
  return blocks;
}

const sentencesOf = (t) => t.split(/(?<=[.!?])\s+/).map((s) => s.trim()).filter(Boolean);

/** Every undated denominator sentence in one source string. */
export function scanSource(file, src) {
  const found = [];
  for (const block of proseBlocks(src)) {
    for (const sentence of sentencesOf(block.text)) {
      const hit = sentence.match(DENOMINATOR);
      if (!hit || SNAPSHOT.test(sentence)) continue;
      found.push({ file, nearLine: block.line, phrase: hit[0], sentence: sentence.slice(0, 200) });
    }
  }
  return found;
}

/** GLOBBED, never hand-listed. */
const shippedModules = (dir) => readdirSync(dir).filter((f) => f.endsWith(".mjs")).sort();

export function scanDir(dir) {
  return shippedModules(dir).flatMap((f) => scanSource(f, readFileSync(join(dir, f), "utf8")));
}

// ─────────────────────────────────────────────────────────────────────────────
// (B) THE TRIPWIRE
// ─────────────────────────────────────────────────────────────────────────────

test("no shipped grip module states a volume denominator without naming its snapshot", () => {
  const violations = scanDir(GRIP);
  assert.deepEqual(
    violations,
    [],
    "these sentences quote a store-volume denominator with no sha and no date in the same sentence. " +
      "The store grows under them, so each one is false as soon as another wave commits (charter D102). " +
      "Retire the figure, or rewrite it past-tense naming the snapshot it was measured at — never restate " +
      "it with today's total, which only resets the clock.",
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// (C) THE CONTROLS — a tripwire nobody has watched fail is a decoration
// ─────────────────────────────────────────────────────────────────────────────

// The prose that actually shipped on origin/main, quoted verbatim as fixtures so
// the scan is proven against the real thing rather than against a mock of it.
const RETIRED_PROSE = Object.freeze([
  "// 46 of the 62 stored rows (74.2%) hard-code an absolute checkout path.",
  "// D76 rules that 49 of the 62 stored rows mask their failure.",
  "// clears the flag; 0 of the 62 rows carry it.",
  "// `leads origin/main` returned 51 of the store's 62 recipes (82%) with ZERO subject matches.",
  "// 57 of the 62 committed rows (91.9%) still carry a quantity the merged mint no longer produces.",
  "// The same binary measures the 62-row store and the post-backfill store.",
  " * Measured on a 400-row store: 17,343ms over every recipe.",
  '  + "  --store <dir>   the ledger directory to measure (the SAME instrument reads the 62-row and\\n"',
]);

test("the scan catches every shape that shipped on origin/main, in comments and in strings", () => {
  for (const line of RETIRED_PROSE) {
    const hits = scanSource("fixture.mjs", line);
    assert.equal(hits.length, 1, `expected a violation, got ${hits.length}: ${line}`);
  }
  // The whole retired header at once, so a block-joining bug cannot hide a hit.
  assert.ok(scanSource("fixture.mjs", RETIRED_PROSE.join("\n")).length >= RETIRED_PROSE.length - 1);
});

test("naming a sha or a date in the same sentence is the ONLY thing that clears it", () => {
  const bare = "// 46 of the 62 stored rows hard-coded an absolute checkout path.";
  assert.equal(scanSource("f.mjs", bare).length, 1);

  const withSha = "// At 60ef35bd06, 46 of the 62 stored rows hard-coded an absolute checkout path.";
  assert.deepEqual(scanSource("f.mjs", withSha), []);

  const withDate = "// On 2026-07-21, 46 of the 62 stored rows hard-coded an absolute checkout path.";
  assert.deepEqual(scanSource("f.mjs", withDate), []);

  // A snapshot in the NEIGHBOURING sentence does not launder this one — that is
  // exactly how a marker drifts away from the figure it was supposed to date.
  const neighbour = "// Measured at 60ef35bd06. 46 of the 62 stored rows hard-coded an absolute path.";
  assert.equal(scanSource("f.mjs", neighbour).length, 1);

  // A word spelled entirely from a-f is not a sha.
  const defaced = "// The corpus was defaced: 46 of the 62 stored rows hard-coded an absolute path.";
  assert.equal(scanSource("f.mjs", defaced).length, 1);
});

test("a sentence wrapped across comment lines is scanned whole, not line by line", () => {
  const wrapped = ["// At 60ef35bd06 (2026-07-21), 46 of the 62 stored", "// rows hard-coded an absolute path."].join("\n");
  assert.deepEqual(scanSource("f.mjs", wrapped), []);
  const wrappedBare = ["// 46 of the 62 stored", "// rows hard-coded an absolute path."].join("\n");
  assert.equal(scanSource("f.mjs", wrappedBare).length, 1);
});

test("the tripwire fires on a module PLANTED in a copy of the shipped tree", () => {
  const tmp = mkdtempSync(join(tmpdir(), "grip-denominator-"));
  try {
    for (const f of shippedModules(GRIP)) writeFileSync(join(tmp, f), readFileSync(join(GRIP, f), "utf8"));
    assert.deepEqual(scanDir(tmp), [], "the copied tree must start clean, or this control proves nothing");

    const victim = join(tmp, "binding.mjs");
    writeFileSync(victim, "// 999 of the 1234 stored rows are cwd-bound\n" + readFileSync(victim, "utf8"));
    const after = scanDir(tmp);
    assert.equal(after.length, 1, "the planted denominator must be the one and only hit");
    assert.equal(after[0].phrase.toLowerCase(), "of the 1234 stored rows");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
