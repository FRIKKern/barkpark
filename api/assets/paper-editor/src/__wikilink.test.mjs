// __wikilink.test.mjs — pure-Node unit test for the `[[` wikilink-autocomplete
// TRIGGER detector (parseOpenWikilink). Imports ONLY the DOM-free pure helper
// from wikilink-trigger.js — never touches `document` / TipTap / HTMLElement, so
// it runs in plain Node exactly like __callout_shorthand.test.mjs.
//
// CARVE-OUT: the popup DOM, caret-rect positioning, keyboard routing, and the
// async candidate request/response are BROWSER-ONLY and are NOT covered here —
// they live in the forthcoming wikilink-menu.js / index.js wiring and are
// exercised in the live editor.
//
// Run: node src/__wikilink.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { parseOpenWikilink, wikilinkReplaceRange } from "./wikilink-trigger.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// ── what opens the popup ───────────────────────────────────────────────────

check("opens on `[[ab` with caret at end", () => {
  assert.deepEqual(parseOpenWikilink("[[ab", 4), { query: "ab", from: 0, to: 4 });
});

check("opens MID-PROSE (not just start-of-block)", () => {
  assert.deepEqual(parseOpenWikilink("see [[No", 8), { query: "No", from: 4, to: 8 });
});

check("empty query immediately after `[[`", () => {
  assert.deepEqual(parseOpenWikilink("[[", 2), { query: "", from: 0, to: 2 });
});

check("caret inside the query yields the prefix only", () => {
  assert.deepEqual(parseOpenWikilink("[[abcd", 4), { query: "ab", from: 0, to: 4 });
});

check("nearest unclosed `[[` wins after a closed one", () => {
  assert.deepEqual(parseOpenWikilink("[[a]] then [[b", 14), { query: "b", from: 11, to: 14 });
});

check("a second `[[` resets the query (no nesting)", () => {
  assert.deepEqual(parseOpenWikilink("[[a[[b", 6), { query: "b", from: 3, to: 6 });
});

// ── what keeps it closed ───────────────────────────────────────────────────

check("closed `]]` before the caret => null", () => {
  assert.equal(parseOpenWikilink("[[a]]", 5), null);
});

check("an intervening newline => null", () => {
  assert.equal(parseOpenWikilink("[[a\nb", 5), null);
});

check("no `[[` at all => null", () => {
  assert.equal(parseOpenWikilink("plain prose", 11), null);
});

check("a single `[` is not a trigger", () => {
  assert.equal(parseOpenWikilink("[ab", 3), null);
});

check("caret BEFORE the `[[` => null", () => {
  assert.equal(parseOpenWikilink("x[[ab", 1), null);
});

// ── input hygiene ──────────────────────────────────────────────────────────

check("non-string / non-number args => null", () => {
  assert.equal(parseOpenWikilink(null, 2), null);
  assert.equal(parseOpenWikilink("[[a", "2"), null);
});

check("caretOffset is clamped into range", () => {
  // Offset past the end clamps to text.length (caret at end).
  assert.deepEqual(parseOpenWikilink("[[ab", 99), { query: "ab", from: 0, to: 4 });
});

// ── replace-range PM-position mapping (pick seam) ──────────────────────────

check("caretPos 7, query 'abc' => { from: 2, to: 7 }", () => {
  // The typed span "[[abc" ends at the caret: 2 brackets + 3 query chars back.
  assert.deepEqual(wikilinkReplaceRange(7, "abc"), { from: 2, to: 7 });
});

check("empty query => from = caretPos - 2 (just the `[[`)", () => {
  assert.deepEqual(wikilinkReplaceRange(2, ""), { from: 0, to: 2 });
});

check("mid-doc caret keeps the to anchored at caretPos", () => {
  // "see [[No" with the block starting at doc pos 1: caret 9, query "No" (len 2)
  // → from 9-2-2 = 5 (the "[[").
  assert.deepEqual(wikilinkReplaceRange(9, "No"), { from: 5, to: 9 });
});

check("from is clamped at 0 (never negative)", () => {
  // Degenerate caretPos < 2 cannot subtract below the doc start.
  assert.deepEqual(wikilinkReplaceRange(1, ""), { from: 0, to: 1 });
  assert.deepEqual(wikilinkReplaceRange(0, "x"), { from: 0, to: 0 });
});

check("non-number caretPos / non-string query degrade safely", () => {
  assert.deepEqual(wikilinkReplaceRange(undefined, "ab"), { from: 0, to: 0 });
  assert.deepEqual(wikilinkReplaceRange(5, null), { from: 3, to: 5 });
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall wikilink-trigger checks PASS");
