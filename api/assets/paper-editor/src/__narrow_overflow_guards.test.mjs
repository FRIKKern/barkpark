// __narrow_overflow_guards.test.mjs — jf-w1-engine-narrow-dark-fixes source guard.
//
// task-0e7a1a8ed32b5de5 found two criteria on jf-w1-engine-narrow-dark-fixes
// stamped met=true for CSS that was never pushed to origin/main:
//   1. .bp-lineage__body had no overflow-wrap/word-break — .bp-lineage__nodes
//      is an auto-fit minmax(150px,1fr) grid, so a node can be squeezed to its
//      150px floor at narrow measures, and a long unbroken body string (a URL,
//      a compound word) then blows the column out sideways instead of wrapping.
//   2. .bp-duel__table had no self-containment — it is a plain width:100% table
//      with no display:block/max-width/overflow-x, unlike .bp-table (which
//      already carries the three-declaration escape hatch for exactly this).
//
// Both were re-built from scratch here (the original branch never reached
// origin/main) rather than re-landed blind. This is the source guard that was
// missing the first time: it reds if either rule regresses to its pre-fix
// shape, so a future edit that reintroduces the bug is caught before a stamp
// can outlive the code again.
//
// jf-narrow-viewport-sweep-remaining-blocks widened this to a systematic pass
// over every `.bp-*` block family in paper-surface.css, hunting the same two
// defect shapes: (a) a `white-space: nowrap` cell with no scroll container or
// ellipsis clamp on its own rule, and (b) a container holding author-supplied
// unbreakable tokens (task/paper slugs, dep ids, criterion prose that may
// embed a URL) with no overflow-wrap/word-break guard. That pass found:
//   - `.bp-task-chip` set bare `white-space: nowrap` with NO ellipsis/overflow
//     clamp (unlike every other nowrap label in the sheet — `.bp-trow__t`,
//     `.bp-rm__lbl`, `.bp-gauge__l/__n`, `.bp-bar-chart__l`,
//     `.bp-criteria-progress__l` all pair nowrap with `overflow: hidden;
//     text-overflow: ellipsis`). A long task title chip in prose had no
//     escape hatch and forced the line to overflow sideways at 390px. Fixed
//     by dropping nowrap in favor of `overflow-wrap: anywhere` — the same
//     normal-wrapping behavior its sibling chips (`.bp-tag`, `.bp-wikilink`)
//     already use, so a multi-word title now wraps instead of forcing a
//     single unbreakable line.
//   - `.bp-crit__t`, `.bp-bcard__t`, `.bp-tdetail__deps`, `.bp-tdetail__labels`
//     and `.bp-rail__paper` render free-form author content (acceptance-
//     criterion prose, board-card titles, dependency/task ids, paper slugs)
//     with no overflow-wrap guard, unlike their siblings that already carry
//     one for the identical risk (`.bp-field__v`, `.bp-lineage__body`,
//     `.bp-kilde__ref`, `.bp-api-endpoint__path`, `.bp-pnode__f/__src`,
//     `.bp-canvas-stage__f`). This codebase's own task/paper slugs (e.g. a
//     40+ char loop-epic branch name) are a live example of the unbroken
//     token these containers can receive. All five now carry
//     `overflow-wrap: anywhere`.
//   - `.bp-legend__n` is a fixed `width: 6.5rem; flex: none` mono label with
//     no wrap guard; same fix.
// Everything else in the sheet was audited and found ALREADY SAFE by one of:
// nowrap paired with its own ellipsis clamp, nesting inside an established
// `overflow-x: auto` scroll container (`.bp-table`, `.bp-duel__table`,
// `.bp-heat__scroll`, `.bp-pipe-scroll`, `.bp-chart__scroll`, `.bp-diff`/
// `.bp-filetree`), or an existing overflow-wrap/word-break guard already on
// the rule. The rendered 390px no-horizontal-scroll assertion this task also
// calls for (every PortableDoc golden fixture through headless Chromium)
// needs `js/packages/react/tests/fixtures/pd-golden/` and a browser harness —
// outside api/assets, left to that lane; this file is the source-level half.
//
// Run: node src/__narrow_overflow_guards.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const readRepo = (rel) => readFileSync(join(__dirname, "../../../..", rel), "utf8");

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

const surface = readRepo("api/assets/paper-surface/paper-surface.css");

function ruleFor(selector, css) {
  // First `.selector { ... }` occurrence — mirrors __code_interior.test.mjs's
  // approach of matching one canonical declaration block, not every mention
  // of the class name (data_viz.ex/comments also say the string).
  const re = new RegExp(
    selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}",
  );
  const m = css.match(re);
  assert.ok(m, `no "${selector} { ... }" rule found in paper-surface.css`);
  return m[1];
}

// ── 1. .bp-lineage__body wraps a long unbroken string ─────────────────────────

check(".bp-lineage__body carries an overflow-wrap guard", () => {
  const decls = ruleFor(".bp-paper-surface .bp-lineage__body", surface);
  assert.ok(
    /overflow-wrap\s*:\s*anywhere/.test(decls),
    ".bp-lineage__body must set overflow-wrap: anywhere — without it a long " +
      "unbroken body string blows out the 150px-floor grid column sideways " +
      "instead of wrapping (task-0e7a1a8ed32b5de5).",
  );
  // The pre-existing declarations must survive the edit untouched.
  for (const must of ["font-size: 0.76rem", "line-height: 1.45", "margin-top: 5px"]) {
    assert.ok(decls.includes(must), `.bp-lineage__body lost a pre-existing declaration: ${must}`);
  }
});

// ── 2. .bp-duel__table self-contains like .bp-table does ──────────────────────

check(".bp-duel__table self-contains horizontally, .bp-table's own escape hatch", () => {
  const decls = ruleFor(".bp-paper-surface .bp-duel__table", surface);
  for (const must of ["display: block", "max-width: 100%", "overflow-x: auto"]) {
    assert.ok(
      decls.includes(must),
      `.bp-duel__table is missing "${must}" — without the full three-declaration ` +
        "escape hatch (.bp-table's own pattern) a wide duel table cannot scroll " +
        "and instead pushes the whole page wider at narrow measures.",
    );
  }
  // width:100% must survive — it is what keeps desktop (>=720px) unchanged.
  assert.ok(decls.includes("width: 100%"), ".bp-duel__table must keep width:100% so desktop layout is unchanged.");
});

// ── 3. .bp-task-chip wraps a long title instead of forcing a nowrap overflow ──

check(".bp-task-chip does not force an unguarded single-line overflow", () => {
  const decls = ruleFor(".bp-paper-surface .bp-task-chip", surface);
  assert.ok(
    !/white-space\s*:\s*nowrap/.test(decls),
    ".bp-task-chip must not set bare white-space:nowrap — with no ellipsis " +
      "or overflow-wrap paired to it (unlike every other nowrap label in " +
      "this sheet), a long task title has no escape hatch and overflows " +
      "the line sideways at 390px (jf-narrow-viewport-sweep-remaining-blocks).",
  );
  assert.ok(
    /overflow-wrap\s*:\s*anywhere/.test(decls),
    ".bp-task-chip should wrap normally like its sibling chips (.bp-tag, " +
      ".bp-wikilink) rather than forcing a single unbreakable line.",
  );
});

// ── 4. free-form author-content containers carry an overflow-wrap guard ──────

for (const selector of [
  ".bp-crit__t",
  ".bp-bcard__t",
  ".bp-tdetail__deps",
  ".bp-tdetail__labels",
  ".bp-rail__paper",
  ".bp-legend__n",
]) {
  check(`${selector} carries an overflow-wrap guard`, () => {
    const decls = ruleFor(`.bp-paper-surface ${selector}`, surface);
    assert.ok(
      /overflow-wrap\s*:\s*anywhere/.test(decls),
      `${selector} renders free-form author content (a task/paper slug, ` +
        "dependency id, or criterion prose) with no wrap guard — an " +
        "unbroken token (this codebase's own task ids run 40+ chars) " +
        "blows the container out sideways at 390px " +
        "(jf-narrow-viewport-sweep-remaining-blocks).",
    );
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
