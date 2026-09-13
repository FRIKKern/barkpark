// __narrow_title_guards.test.mjs — the card-title family, and the one member
// of it that outgrows prose.
//
// THE DEFECT. `.bp-tdetail__title` is free-form author text (a task title) set
// at 1.15rem bold — the largest type inside the detail card. Measured in
// headless Chromium against the reader's real container geometry, at a 320px
// viewport with a single 30-character compound noun:
//
//   block                 type        document width (320px viewport)
//   <p>          (control) 1rem         fits
//   .bp-card__t            0.9rem       fits
//   .bp-tasks__title       1.05rem      fits
//   .bp-tdetail__title     1.15rem bold 324px   <- page scrolls
//
// Four pixels. Worth a declaration anyway, because the cost of an overflow is
// not proportional to its size: 4px past the viewport is a horizontal scrollbar
// on the whole page and a document the reader can drag, exactly as 400px would
// be.
//
// THE OTHER TWO ARE MEASURED CLEAN AND STAY UNGUARDED. `.bp-card__t` and
// `.bp-tasks__title` are the same kind of field — a free-form title in a
// card — and the tempting move is to guard all three for symmetry. They do not
// need it at any token plain prose survives, and this file pins that so the
// symmetry argument has to bring a measurement next time. A guard that fixes
// nothing still costs: it is one more declaration a future reader has to
// account for when a layout misbehaves.
//
// `break-word`, not `anywhere`: the title never sizes its own box, so the
// declaration that cannot participate in min-content sizing is the one that
// cannot move a layout. Every element's rendered geometry across all 63
// pd-golden block fixtures is byte-identical at 1280px before and after.
//
// Run: node src/__narrow_title_guards.test.mjs   (or: npm test)

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

function ruleFor(selector) {
  const re = new RegExp(selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}");
  const m = surface.match(re);
  assert.ok(m, `no "${selector} { ... }" rule found in paper-surface.css`);
  return m[1];
}

check(".bp-tdetail__title can break a long word", () => {
  const decls = ruleFor(".bp-paper-surface .bp-tdetail__title");
  assert.match(
    decls,
    /overflow-wrap\s*:\s*break-word/,
    ".bp-tdetail__title must set overflow-wrap: break-word — at 320px a single " +
      "30-character compound noun puts the document past the screen while the " +
      "same word in a <p> still fits, so the page gains a horizontal scrollbar " +
      "for one task title.",
  );
  // Same-rule pin: if the matcher ever lands elsewhere this fails loudly rather
  // than passing by luck.
  assert.ok(
    decls.includes("font-size: 1.15rem"),
    ".bp-tdetail__title lost font-size: 1.15rem — that size is exactly why this " +
      "title overflows where its 0.9rem and 1.05rem siblings do not, so this is " +
      "no longer the rule this test is about.",
  );
});

// THE VERDICT FLIPPED — and the old test asked for exactly this (gp-b-mobile-
// reading-column). These two used to be pinned as "left unguarded on purpose":
// measured clean at 320px "on every token plain prose survives", with the
// instruction that if a measurement ever said otherwise, the declaration should
// be added along with THE NUMBER that proves it. Here are the numbers.
//
// The old pin was not wrong when it was written; its PRECONDITION moved. Its
// scope was "every token plain prose survives", and before `.bp-paper-surface
// p, li { overflow-wrap: break-word }` landed, plain prose did NOT survive a
// long paper permalink. __narrow_render.mjs skips any token its prose CONTROL
// also fails, so the permalink case against these two was never being asserted
// — the pass was silence, not evidence. Guarding prose widened the set of
// tokens the control survives, and the moment it did, both blocks failed:
//
//   token: "https://guerrilla.barkpark.cloud/papers/mechanical-spacing-doctrine"
//   .bp-tasks__title  442px  |  .bp-card__t  408px   — in viewports of 390, 360
//   and 320px (a plain <p> carrying the same token now fits in all three).
//
// So the size reasoning ("0.9rem does not need one") held only for the
// 30-character compound noun it was measured with. A paper permalink is 68
// characters and is the token these blocks most often actually receive.
// `break-word`, not `anywhere`: neither block sizes its own box.
for (const [selector, px] of [
  [".bp-card__t", 408],
  [".bp-tasks__title", 442],
]) {
  check(`${selector} breaks a long permalink`, () => {
    const decls = ruleFor(`.bp-paper-surface ${selector}`);
    assert.match(
      decls,
      /overflow-wrap\s*:\s*break-word/,
      `${selector} must set overflow-wrap: break-word — carrying a paper ` +
        `permalink it renders ${px}px wide and scrolls the whole document ` +
        "sideways at 390, 360 and 320px (__narrow_render.mjs). This block was " +
        "previously pinned as deliberately unguarded; that pin was scoped to " +
        "'every token plain prose survives', and it stopped holding when the " +
        "prose guard widened that set.",
    );
    assert.doesNotMatch(
      decls,
      /overflow-wrap\s*:\s*anywhere/,
      `${selector} does not size its own box, so the declaration that cannot ` +
        "participate in min-content sizing is the one that cannot move a " +
        "layout that was not already overflowing.",
    );
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
