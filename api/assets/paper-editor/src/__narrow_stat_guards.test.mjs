// __narrow_stat_guards.test.mjs — a stat block must be able to show a number.
//
// THE DEFECT. `.bp-stat__v` is the largest type in this sheet (1.7rem mono) and
// it sits in a cell far narrower than a phone screen: `.bp-stats` is
// `repeat(auto-fit, minmax(140px, 1fr))`, so at a 390px viewport the reading
// column's 358px of content makes exactly two ~179px tracks. Measured in
// headless Chromium against the reader's real container geometry, filling both
// cells the way every real stats row does:
//
//   value                      chars   document width (390px viewport)
//   "1 478"                      5      fits
//   "$1,234,567.89"             13      420px   <- page scrolls
//   "1 234 567,89" (U+202F)     12      407px   <- page scrolls
//   twelve digits, no breaks    12      404px   <- the exact threshold
//
// Twelve characters is not an exotic input, it is a formatted number. None of
// `$1,234,567.89`, `1 234 567,89` offers a single break opportunity — comma,
// period, and the U+202F narrow no-break space used for digit grouping all
// refuse one. A block whose entire job is to show a large figure could not show
// a large figure on a phone.
//
// WHY `anywhere` HERE AND `break-word` ON THE LABEL. They are not
// interchangeable and the difference decides whether the fix works at all.
// `.bp-stat` is `inline-flex` — shrink-to-fit — so outside the grid it sizes
// itself from its content's intrinsic width. `break-word` never reports a
// smaller intrinsic width, so it repairs the grid case and leaves the
// standalone stat exactly as broken; that arm was measured, not assumed. Only
// `anywhere` participates in min-content sizing, which is the property needed
// here and the same property that makes `anywhere` the WRONG choice for
// headings (see __narrow_heading_guards.test.mjs, where a heading must not be
// allowed to shrink its ancestors). The label never sizes its own box — the
// grid track does — so the weaker declaration is right for it, and the weaker
// declaration is the one that cannot move a layout.
//
// WHY NOT AN ELLIPSIS. Several nowrap labels in this sheet pair with `overflow:
// hidden; text-overflow: ellipsis`. That clamp is wrong for a figure: it would
// present a shortened number as though it were the whole number. A number that
// wraps is still readable; a number silently missing its last digits is a lie
// with a tidy right edge.
//
// DESKTOP IS UNCHANGED, MEASURED. Every element's rendered geometry (tag,
// class, x, y, width, height) across all 63 pd-golden block fixtures is
// byte-identical before and after this change at 1280px. The declarations act
// only where the page was already broken.
//
// Run: node src/__narrow_stat_guards.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const surface = readFileSync(
  join(__dirname, "../../../..", "api/assets/paper-surface/paper-surface.css"),
  "utf8",
);

let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS  ${name}`); }
  catch (e) { failures++; console.log(`FAIL  ${name}\n      ${e.message}`); }
}

// The first `.selector { ... }` block. `.bp-stat__v` and `.bp-stat__l` are each
// declared exactly once, so first-match is the rule — but the assertion below
// also pins a neighbouring declaration from the SAME rule, which is what makes
// a wrong match visible instead of silently passing.
function ruleFor(selector) {
  const re = new RegExp(selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}");
  const m = surface.match(re);
  assert.ok(m, `no "${selector} { ... }" rule found in paper-surface.css`);
  return m[1];
}

check(".bp-stat__v can break a number that has no break opportunity", () => {
  const decls = ruleFor(".bp-paper-surface .bp-stat__v");
  assert.match(
    decls,
    /overflow-wrap\s*:\s*anywhere/,
    ".bp-stat__v must set overflow-wrap: anywhere. Without it a twelve-character " +
      "formatted number — $1,234,567.89 has no break opportunity at all — fills a " +
      "179px stats track at 390px and pushes the whole document past the viewport, " +
      "so the reader drags the page sideways to read a figure.",
  );
  assert.doesNotMatch(
    decls,
    /overflow-wrap\s*:\s*break-word/,
    "break-word is not enough for .bp-stat__v: `.bp-stat` is inline-flex, so " +
      "outside the grid it sizes from its content's intrinsic width, and " +
      "break-word never reports a smaller one. Measured, the standalone stat " +
      "stays broken under break-word and is repaired under anywhere.",
  );
  assert.doesNotMatch(
    decls,
    /text-overflow\s*:\s*ellipsis/,
    "never clamp .bp-stat__v with an ellipsis — that shows a truncated figure as " +
      "if it were the whole figure. Wrapping keeps the number readable; clamping " +
      "makes it wrong.",
  );
  // A neighbouring declaration from the same rule. If the matcher ever lands on
  // a different rule, this fails loudly rather than the test passing by luck.
  assert.ok(
    decls.includes("font-size: 1.7rem"),
    ".bp-stat__v lost font-size: 1.7rem — that size is exactly why the value " +
      "runs out of track first, so losing it means this rule is no longer the " +
      "rule this test is about.",
  );
});

check(".bp-stat__l can break a long label", () => {
  const decls = ruleFor(".bp-paper-surface .bp-stat__l");
  assert.match(
    decls,
    /overflow-wrap\s*:\s*break-word/,
    ".bp-stat__l must set overflow-wrap: break-word — a 30-character compound " +
      "label overflows a 179px track at 320px. break-word (not anywhere) is " +
      "correct here: the label never sizes its own box, the grid track does, so " +
      "the declaration that cannot affect intrinsic sizing is the safe one.",
  );
  assert.ok(
    decls.includes("font-size: 0.72rem"),
    ".bp-stat__l lost font-size: 0.72rem — this rule is no longer the rule this " +
      "test is about.",
  );
});

// The grid's track floor is the other half of the arithmetic above. If someone
// raises or lowers it, the 12-character threshold this file documents moves,
// and the comment stops being true.
check(".bp-stats still lays out on a 140px auto-fit floor", () => {
  const decls = ruleFor(".bp-paper-surface .bp-stats");
  assert.ok(
    decls.includes("repeat(auto-fit, minmax(140px, 1fr))"),
    ".bp-stats no longer uses `repeat(auto-fit, minmax(140px, 1fr))`. That floor " +
      "is what makes two ~179px tracks at a 390px viewport, which is the " +
      "arithmetic every threshold in this file's header rests on. Changing it is " +
      "allowed — but re-measure and update the numbers, do not leave them stale.",
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
