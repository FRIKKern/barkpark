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
// `.bp-pipe-scroll`, `.bp-chart__scroll`, `.bp-diff`/`.bp-filetree`), or an
// existing overflow-wrap/word-break guard already on the rule.
//
// TWO CORRECTIONS TO THE PARAGRAPH ABOVE, both from measuring what it asserted.
//
// 1. `.bp-heat__scroll` used to appear in that list of scroll containers. It is
//    real, but it belongs to the CALENDAR heat only: `heat_calendar_html/2`
//    emits `.bp-heat--cal > .bp-heat__scroll`, while the plain `heatmap_html/1`
//    emits `.bp-heat > .bp-heat__grid` with no scroll wrapper at all, and its
//    row-label track is `auto` — it grows to the widest author label. So the
//    plain heatmap was never covered by the reason given for it. The VERDICT
//    still holds — measured, a plain heatmap needs a 45-character row label
//    before the page scrolls, where plain prose gives way at 22 — but it held
//    for a different reason than the one written down, and a reason that is not
//    the real one is how the next audit skips the block.
//
// 2. The rendered 390px assertion was recorded here as needing a harness
//    "outside api/assets, left to that lane". It does not: __narrow_render.mjs
//    sits beside this file, reads the same pd-golden corpus, and drives real
//    headless Chromium. What it needed was the reader's container geometry
//    (max-width + gutter), which lives in root.html.heex rather than in
//    paper-surface.css — that is a transcription, not a fence problem.
//
// THE LIMIT OF THIS FILE, stated plainly. Every assertion below greps a
// declaration out of the stylesheet. That catches a deleted declaration and
// nothing else: it cannot see a block nobody has thought about, and it cannot
// tell whether the page actually scrolls. Of the ~341 `.bp-*` classes this
// sheet styles, 117 are rendered by no pd-golden fixture at all, so silence
// about them is not evidence. __narrow_render.mjs is the half that measures.
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

// ── 1b. the CLOCK STRIP stays a strip at 360px ───────────────────────────────
//
// pe-bl-clock-strip-block. `.bp-lineage__nodes` was
// `repeat(auto-fit, minmax(150px, 1fr))`, which WRAPS: four dated stops render
// 3+1 inside the reading column and the fourth starts a second row that reads
// as a second timeline. The three declarations below are what make it a strip
// instead, and each one is load-bearing at 360px:
//
//   grid-auto-flow: column   one track per stop, so the stops never wrap
//   overflow-x: auto         the strip self-scrolls instead of pushing the
//                            page body sideways once 4 x 150px exceeds the box
//   border-top on __nodes    ONE continuous spine — the old per-node border-top
//                            was cut by every 14px gap
//
// The per-node rule must NOT carry a border-top any more: if it comes back the
// spine is four dashes again, and nothing else in the file would notice.
check(".bp-lineage__nodes is a self-scrolling strip on one continuous spine", () => {
  const nodes = ruleFor(".bp-paper-surface .bp-lineage__nodes", surface);
  assert.ok(
    /grid-auto-flow\s*:\s*column/.test(nodes),
    ".bp-lineage__nodes must set grid-auto-flow: column — auto-fit wraps the " +
      "fourth stop onto a second row at the reading measure.",
  );
  assert.ok(
    /grid-auto-columns\s*:\s*minmax\(\s*150px/.test(nodes),
    ".bp-lineage__nodes must floor each stop at 150px so a stop stays legible " +
      "once the strip starts scrolling.",
  );
  assert.ok(
    /overflow-x\s*:\s*auto/.test(nodes),
    ".bp-lineage__nodes must self-scroll (overflow-x: auto) — at 360px four " +
      "150px stops exceed the box and the PAGE must not scroll sideways.",
  );
  assert.ok(
    /border-top\s*:\s*1px solid var\(--paper-rule\)/.test(nodes),
    ".bp-lineage__nodes must carry the spine itself; a per-node border-top is " +
      "cut by every gap.",
  );

  const node = ruleFor(".bp-paper-surface .bp-lineage__node", surface);
  assert.ok(
    !/border-top/.test(node),
    ".bp-lineage__node must NOT carry a border-top — that is the broken spine " +
      "the clock strip replaced.",
  );
  assert.ok(
    /position\s*:\s*relative/.test(node),
    ".bp-lineage__node must be a positioning context for its spine tick.",
  );
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

// ── 5. RUNNING PROSE breaks a long unbreakable token ─────────────────────────
//
// gp-b-mobile-reading-column. Sections 1-4 above guard the `.bp-*` COMPONENT
// containers. Nothing guarded the two elements that carry most of a paper's
// words: `p` and `li`. Headings already take `overflow-wrap: break-word`
// (`.bp-paper-surface h1..h6`, with its own note on why), so prose was the
// remaining hole, and prose is where this codebase's unbreakable tokens
// actually appear — a 40-character git SHA, a bare paper URL, a `--flag=value`.
//
// MEASURED on the live public reader (headless Chromium against
// guerrilla.barkpark.cloud/papers/paper-editing-parity-status-2026-09-07),
// which is how this was found rather than argued out of the cascade:
//
//   360px viewport, --paper-gutter 16px, 328px content box:
//     28 paragraphs had scrollWidth > clientWidth (worst 376 vs 328) and
//     documentElement.scrollWidth was 392 against a 360px viewport — the whole
//     page scrolled sideways by 32px on a phone.
//   390px viewport, 358px content box: 6 paragraphs, document 392 vs 390.
//   With the rule injected on that same live page: both go to ZERO.
//
// The gutter ladder is NOT the defect and this rule does not touch it: the
// shell already steps 40/24/16 at 767/479 and measured exactly that. The
// column is the right WIDTH; a word inside it had no way to break.
//
// `break-word` and deliberately not `anywhere`, matching the heading rule: it
// acts only once a word has a whole line to itself and still does not fit, so
// a column already wide enough for its content is untouched. Verified by
// diffing EVERY rendered element's geometry on the live reader at 1280px and
// 768px with and without the rule — byte-identical, zero elements moved.
//
// It must live in THIS shared sheet and not in bulldocs.html.heex: put it in
// the reader layout alone and View wraps a line at a different word than Edit,
// which is the single drift measure_parity_test.exs exists to prevent.

check("running prose (p, li) carries a long-token break guard", () => {
  const re = /\.bp-paper-surface\s+p,\s*\n\s*\.bp-paper-surface\s+li\s*\{([^}]*)\}/;
  const m = surface.match(re);
  assert.ok(
    m,
    "no `.bp-paper-surface p, .bp-paper-surface li { ... }` rule in " +
      "paper-surface.css — running prose has no long-token break guard. " +
      "Measured without it at 360px on the live reader: 28 paragraphs " +
      "overflowed their 328px column and the document scrolled sideways " +
      "392 vs 360 (gp-b-mobile-reading-column).",
  );
  assert.ok(
    /overflow-wrap\s*:\s*break-word/.test(m[1]),
    "the prose rule must set overflow-wrap: break-word — the same guard the " +
      "heading rule takes, and deliberately not `anywhere`, which would " +
      "break words that still had room to fit.",
  );
  assert.ok(
    !/overflow-wrap\s*:\s*anywhere/.test(m[1]),
    "`anywhere` breaks a word the moment the line is tight rather than only " +
      "when the word alone cannot fit, so it changes wrapping in columns that " +
      "were never overflowing — the 1280px before/after geometry diff that " +
      "proved this change desktop-neutral would no longer hold.",
  );
  // The gutter ladder is a separate mechanism; this guard must not be read as
  // covering it, and the paragraph rule above must keep its own declarations.
  const para = ruleFor(".bp-paper-surface p ", surface);
  assert.ok(
    /hyphens\s*:\s*manual/.test(para),
    "the paragraph rule lost `hyphens: manual` — the explicit OFF that keeps " +
      "ragged-right prose from auto-hyphenating.",
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
