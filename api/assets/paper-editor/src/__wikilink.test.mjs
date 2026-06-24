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
import {
  parseOpenWikilink,
  wikilinkReplaceRange,
  parseOpenTag,
  tagReplaceRange,
} from "./wikilink-trigger.js";

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

// ── `#` tag trigger — what opens the popup ─────────────────────────────────

check("opens on `#des` with caret at end => query 'des'", () => {
  assert.deepEqual(parseOpenTag("#des", 4), { query: "des", from: 0, to: 4 });
});

check("a bare `#` (empty query) does NOT open — needs a letter", () => {
  assert.equal(parseOpenTag("#", 1), null);
});

check("a pure-numeric `#5` does NOT open (Obsidian tags need a letter)", () => {
  assert.equal(parseOpenTag("#5", 2), null);
  assert.equal(parseOpenTag("issue #42", 9), null);
});

check("a numeric-led tag with a letter `#2024-recap` opens", () => {
  assert.deepEqual(parseOpenTag("#2024-recap", 11), {
    query: "2024-recap",
    from: 0,
    to: 11,
  });
});

check("opens MID-PROSE after whitespace (sigil after a space)", () => {
  assert.deepEqual(parseOpenTag("see #des", 8), { query: "des", from: 4, to: 8 });
});

check("opens after a newline (newline is whitespace => sigil)", () => {
  assert.deepEqual(parseOpenTag("a\n#des", 6), { query: "des", from: 2, to: 6 });
});

check("nested tag `#a/b` => query 'a/b' (slash allowed)", () => {
  assert.deepEqual(parseOpenTag("#a/b", 4), { query: "a/b", from: 0, to: 4 });
});

check("digits / dash / underscore are valid query chars", () => {
  assert.deepEqual(parseOpenTag("#v2_x-y", 7), { query: "v2_x-y", from: 0, to: 7 });
});

check("caret inside the query yields the prefix only", () => {
  assert.deepEqual(parseOpenTag("#abcd", 3), { query: "ab", from: 0, to: 3 });
});

check("nearest sigil `#` wins after an earlier completed tag", () => {
  // "#one two #de" — caret at end picks the LATER `#` (preceded by a space).
  assert.deepEqual(parseOpenTag("#one two #de", 12), { query: "de", from: 9, to: 12 });
});

// ── `#` tag trigger — what keeps it closed ─────────────────────────────────

check("a trailing space ends the query => null", () => {
  assert.equal(parseOpenTag("#des ", 5), null);
});

check("mid-word `#` (C# / C-sharp) => null", () => {
  assert.equal(parseOpenTag("C#", 2), null);
});

check("mid-word `#` with a query after it => null", () => {
  // "issue5#tag" — the `#` is glued to "5", not a sigil.
  assert.equal(parseOpenTag("issue5#tag", 10), null);
});

check("`##` (heading shorthand) never triggers => null", () => {
  assert.equal(parseOpenTag("##", 2), null);
});

check("`##h` (heading + text) never triggers => null", () => {
  assert.equal(parseOpenTag("##h", 3), null);
});

check("an embedded space in the span => null", () => {
  // "#a b" caret at end: the space is an invalid query char.
  assert.equal(parseOpenTag("#a b", 4), null);
});

check("an embedded newline in the span => null", () => {
  assert.equal(parseOpenTag("#a\nb", 4), null);
});

check("non-tag punctuation in the span => null", () => {
  assert.equal(parseOpenTag("#a.b", 4), null);
});

check("no `#` at all => null", () => {
  assert.equal(parseOpenTag("plain prose", 11), null);
});

check("caret BEFORE the `#` => null", () => {
  assert.equal(parseOpenTag("x #des", 1), null);
});

check("non-string / non-number args => null", () => {
  assert.equal(parseOpenTag(null, 2), null);
  assert.equal(parseOpenTag("#a", "2"), null);
});

check("caretOffset is clamped into range", () => {
  assert.deepEqual(parseOpenTag("#des", 99), { query: "des", from: 0, to: 4 });
});

// ── `#` tag replace-range PM-position mapping (pick seam) ───────────────────

check("tag: caretPos 5, query 'des' => { from: 1, to: 5 }", () => {
  // The typed span "#des" ends at the caret: 1 hash + 3 query chars back.
  assert.deepEqual(tagReplaceRange(5, "des"), { from: 1, to: 5 });
});

check("tag: empty query => from = caretPos - 1 (just the `#`)", () => {
  assert.deepEqual(tagReplaceRange(1, ""), { from: 0, to: 1 });
});

check("tag: mid-doc caret keeps `to` anchored at caretPos", () => {
  // "see #de" at doc offset: caret 8, query "de" (len 2) → from 8-2-1 = 5.
  assert.deepEqual(tagReplaceRange(8, "de"), { from: 5, to: 8 });
});

check("tag: from is clamped at 0 (never negative)", () => {
  assert.deepEqual(tagReplaceRange(0, "x"), { from: 0, to: 0 });
  assert.deepEqual(tagReplaceRange(1, "abc"), { from: 0, to: 1 });
});

check("tag: non-number caretPos / non-string query degrade safely", () => {
  assert.deepEqual(tagReplaceRange(undefined, "ab"), { from: 0, to: 0 });
  assert.deepEqual(tagReplaceRange(5, null), { from: 4, to: 5 });
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall wikilink-trigger checks PASS");
