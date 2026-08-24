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

// The siblings are measured clean. Pinning that keeps the next reader from
// guarding them for symmetry with no measurement behind it.
for (const [selector, why] of [
  [".bp-card__t", "0.9rem"],
  [".bp-tasks__title", "1.05rem"],
]) {
  check(`${selector} is left unguarded on purpose`, () => {
    const decls = ruleFor(`.bp-paper-surface ${selector}`);
    assert.doesNotMatch(
      decls,
      /overflow-wrap/,
      `${selector} has no wrap guard because at ${why} it does not need one — ` +
        "measured clean at 320px on every token plain prose survives. If a " +
        "measurement now says otherwise, add the declaration AND the number that " +
        "proves it; do not add it for symmetry with .bp-tdetail__title.",
    );
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
