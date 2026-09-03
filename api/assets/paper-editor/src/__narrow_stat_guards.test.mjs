// __narrow_stat_guards.test.mjs — a stat block must be able to show a number,
// and show it as ONE number.
//
// THE DEFECT, AS IT WAS FIRST FOUND. `.bp-stat__v` is the largest type in the
// sheet and it sits in a cell far narrower than a phone screen: `.bp-stats` is
// `repeat(auto-fit, minmax(140px, 1fr))`, so at a 390px viewport the reading
// column's 358px of content makes exactly two ~178px tracks, ~149px of them
// inside the cell padding. At a flat 1.7rem with no break opportunity, a
// twelve-character formatted number filled that track and pushed the DOCUMENT
// past the viewport — the page scrolled sideways to read a figure. The first
// fix was `overflow-wrap: anywhere`, which stopped the page scrolling by
// letting the number break.
//
// THE DEFECT THAT FIX LEFT BEHIND (task-414967096bbe011b, measured 2026-09-02
// on /papers/heggemsnes-act at 390x844). Breaking is not free, and the break
// lands inside the datum:
//
//   * `anywhere` splits a digit run. `$1,234,567.89` has no break opportunity
//     of its own, so the reader is handed `$1,234,56` over `7.89` and has to
//     reassemble the figure by eye.
//   * ordinary wrapping splits a compound value at its spaces: `8 min 10 s`
//     rendered as `8 min 10` over `s`, which reads as two numbers.
//
// WHAT THE RULE IS NOW, and why it takes three declarations. Each one is
// load-bearing and none of them works alone:
//
//   * `white-space: nowrap` — the contract. A value is one thing and renders
//     as one thing, at a space or inside a digit run.
//   * `font-size: clamp(1.15rem, 5.6vw, 1.7rem)` — what makes nowrap
//     affordable. The 1.7rem MAX is reached at a 486px viewport, so every
//     desktop width renders exactly the size this rule always rendered (the
//     1280/1920 rig baselines are unmoved). Below it the value tracks the
//     viewport the column tracks: 21.8px at 390, where `8 min 10 s` measures
//     149px in a 149px cell.
//   * `max-width: 100%` + `overflow-x: auto` — the net, and the reason the
//     ORIGINAL page-scroll guarantee does not lapse. The clamp is keyed on the
//     VIEWPORT while the cell is not a monotonic function of it: `auto-fit`
//     adds a column, so a 620px viewport has FOUR ~112px tracks while the font
//     is already at its 27.2px ceiling. Where the two disagree the value
//     scrolls inside its own cell instead of growing the document.
//
// MEASURED, headless Chromium, the 13-character `$1,234,567.89` in EVERY cell
// (the case that started this file), document.scrollWidth against the viewport:
//
//   viewport   font     cell    value ink   tracks   doc      overflow
//    320px     18.4px   114px     142px       2      320px      0px
//    360px     20.2px   134px     155px       2      360px      0px
//    390px     21.8px   149px     168px       2      390px      0px
//    480px     26.9px   113px     207px       3      480px      0px
//    620px     27.2px   112px     209px       4      620px      0px
//    768px     27.2px   141px     209px       4      768px      0px
//   1280px     27.2px   264px     264px       4     1280px      0px
//
// The page never scrolls sideways at any width, for `$1,234,567.89`,
// `1 234 567,89` (U+202F) or `8 min 10 s`. That was `anywhere`'s job and it is
// still done — by containment rather than by breaking the number.
//
// WHY NOT AN ELLIPSIS, unchanged. Several nowrap labels in this sheet pair with
// `overflow: hidden; text-overflow: ellipsis`. That clamp is wrong for a
// figure: it presents a shortened number as though it were the whole number.
// `overflow-x: auto` hides no digit — every one stays reachable — which is
// exactly why it is the containment allowed here and the ellipsis is not.
//
// DESKTOP IS UNCHANGED, MEASURED. At 1280 the computed font-size is 27.2px
// before and after, and the value renders on one line in both.
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

check(".bp-stat__v renders a value as ONE unbroken value", () => {
  const decls = ruleFor(".bp-paper-surface .bp-stat__v");
  assert.match(
    decls,
    /white-space\s*:\s*nowrap/,
    ".bp-stat__v must set white-space: nowrap. Without it a compound value " +
      "breaks at its spaces — `8 min 10 s` rendered as `8 min 10` over `s` at " +
      "390px, which reads as two numbers.",
  );
  assert.doesNotMatch(
    decls,
    /overflow-wrap\s*:\s*(anywhere|break-word)/,
    "no overflow-wrap on .bp-stat__v: `anywhere` is what splits `$1,234,567.89` " +
      "mid-digit-run, and it is inert under nowrap anyway, so leaving it reads " +
      "as a live break opportunity that is not one.",
  );
  assert.doesNotMatch(
    decls,
    /text-overflow\s*:\s*ellipsis/,
    "never clamp .bp-stat__v with an ellipsis — that shows a truncated figure as " +
      "if it were the whole figure. Containment keeps every digit reachable; " +
      "clamping makes the number wrong.",
  );
});

check(".bp-stat__v cannot push the document sideways", () => {
  const decls = ruleFor(".bp-paper-surface .bp-stat__v");
  // THE ORIGINAL GUARANTEE. `overflow-wrap: anywhere` used to buy it by
  // breaking the number; nowrap gives that up, so the containment below is now
  // the only thing standing between a long figure and a page that rocks
  // sideways on a phone. Both halves: a cap on the box, and a contained
  // overflow for the ink inside it.
  assert.match(
    decls,
    /max-width\s*:\s*100%/,
    ".bp-stat__v lost max-width: 100% — a nowrap value then sizes its own box " +
      "from its content and the grid track stops bounding it.",
  );
  assert.match(
    decls,
    /overflow-x\s*:\s*auto/,
    ".bp-stat__v lost overflow-x: auto. Under nowrap that is the ONLY thing " +
      "keeping a 13-character figure from growing document.scrollWidth past the " +
      "viewport — measured at 320/360/390/480/620/768/1280, overflow 0px at " +
      "every one. Removing it re-opens the exact defect this file was opened for.",
  );
});

check(".bp-stat__v is sized by a clamp whose ceiling is the authored 1.7rem", () => {
  const decls = ruleFor(".bp-paper-surface .bp-stat__v");
  // The neighbour pin: if the matcher ever lands on a different rule this fails
  // loudly instead of the test passing by luck. It is also the desktop-parity
  // assertion — 1.7rem must remain the MAX, or every width above 486px moves.
  const m = decls.match(/font-size\s*:\s*clamp\(([^)]*)\)/);
  assert.ok(
    m,
    ".bp-stat__v no longer sizes itself with a clamp(). A flat size is what made " +
      "nowrap unaffordable on a phone: at 1.7rem a ten-character value needs " +
      "161px of a 149px cell.",
  );
  assert.ok(
    m[1].trim().endsWith("1.7rem"),
    `.bp-stat__v clamps to \`${m[1].trim()}\` — the MAX must stay 1.7rem, the ` +
      "size every width at or above 486px renders and every committed rig " +
      "baseline was shot at.",
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
  // 0.72rem until papers/captions-floor, which put a 12px (0.75rem) floor under
  // every text size on the paper — .bp-stat__l was 11.52px. The identity pin
  // moves WITH the floor; what it is for is unchanged (a rule that lost its
  // small size is no longer the rule this file's 12-character arithmetic
  // describes), and the arithmetic in the comment above still holds: a slightly
  // wider label overflows the 179px track SOONER, never later.
  assert.ok(
    decls.includes("font-size: 0.75rem"),
    ".bp-stat__l lost font-size: 0.75rem (the paper's 12px text floor) — this " +
      "rule is no longer the rule this test is about.",
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
