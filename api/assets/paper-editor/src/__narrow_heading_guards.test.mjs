// __narrow_heading_guards.test.mjs — display type must be able to break a word.
//
// THE DEFECT. A heading sets the widest type on the page, so it runs out of
// line before prose does, and paper-surface.css gave prose and headings the
// same treatment: no wrap guard at all. Every row below is a measurement, taken
// in headless Chromium with this sheet loaded inside the reader's real container
// geometry (the `.bp-paper-surface` max-width/gutter block in
// api/lib/barkpark_web/layouts/root.html.heex, which paper-surface.css
// deliberately does not carry); "document" is document.documentElement
// .scrollWidth, and anything above the viewport number means the page scrolls
// sideways:
//
//   viewport   block           token                              document
//   390px      <p>             implementasjonsdetaljer (23)         fits
//   390px      h1              implementasjonsdetaljer (23)        468px
//   390px      h1              menneskerettighetsorganisasjon (30) 611px
//   390px      h2              menneskerettighetsorganisasjon (30) 426px
//   320px      h3              menneskerettighetsorganisasjon (30) 344px
//   320px      .bp-role-eyebrow  menneskerettighetsorganisasjon    348px
//
// A document wider than the screen is a page the reader has to drag sideways to
// finish a sentence. The trigger is not a malformed paper: those are ordinary
// dictionary words. Norwegian and German build compounds as SINGLE words, and
// Barkpark's ONIX/Bokbasen surface publishes for Norwegian houses, so a
// 30-character noun in a heading is a Tuesday, not an edge case.
//
// WHY THE EYEBROW AND NOT THE BIGGER ROLES. `.bp-role-ingress` is 1.28em and
// `.bp-role-pullquote` 1.2em; the eyebrow is 0.78em — the SMALLEST of the three
// — and it is the only one that overflows. Size is not what runs a line out of
// room; cost per character is. The eyebrow adds `text-transform: uppercase`
// (every lowercase glyph becomes a wider capital) and `letter-spacing: 0.08em`
// (a gap paid after each one), and that pair beats a 1.28em body-cased role.
// Guarding the two larger roles as well would have looked tidier and fixed
// nothing; they are measured clean and are deliberately left alone.
//
// WHY `break-word` AND NOT `anywhere`. They are not interchangeable, and the
// difference is the whole reason this is safe to land. `overflow-wrap:
// anywhere` participates in min-content sizing, so it can shrink any
// shrink-to-fit ancestor — a real risk in this sheet, which is full of
// inline-flex and auto-track boxes. `break-word` acts only when a word already
// has a whole line to itself and still does not fit, and never reports a
// smaller intrinsic width. Proof rather than assertion: every element's
// rendered geometry (tag, class, x, y, width, height) across all 63 pd-golden
// block fixtures is BYTE-IDENTICAL before and after this change, at 1280px and
// at 390px alike. The declarations act only where the page was already broken.
//
// Run: node src/__narrow_heading_guards.test.mjs   (or: npm test)

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

// Returns the declaration block of the rule whose selector list STARTS with the
// given text. Anchoring on the whole selector list matters here: a bare
// `.bp-paper-surface h1` search would skip the shared six-heading rule (its
// selector continues with a comma, not a brace) and silently land on the
// per-level `.bp-paper-surface h1 { font-size: ... }` rule further down, which
// is a different rule that carries none of this. The test would then pass or
// fail for reasons unrelated to what it claims to check.
function ruleStartingWith(selectorHead) {
  const i = surface.indexOf(selectorHead);
  assert.ok(i !== -1, `selector "${selectorHead}" is absent from paper-surface.css`);
  const open = surface.indexOf("{", i);
  const close = surface.indexOf("}", open);
  assert.ok(open !== -1 && close !== -1, `no declaration block follows "${selectorHead}"`);
  return surface.slice(open + 1, close);
}

const HEADING_RULE_HEAD =
  ".bp-paper-surface h1, .bp-paper-surface h2, .bp-paper-surface h3,\n" +
  ".bp-paper-surface h4, .bp-paper-surface h5, .bp-paper-surface h6 {";

check("the shared h1–h6 rule can break a long word", () => {
  const decls = ruleStartingWith(HEADING_RULE_HEAD);
  assert.match(
    decls,
    /overflow-wrap\s*:\s*break-word/,
    "the shared h1–h6 rule must set overflow-wrap: break-word. Without it a " +
      "single ordinary compound noun — 23 characters is enough at 390px — makes " +
      "an h1 push the whole document wider than the screen, and the reader has " +
      "to drag the page sideways to finish the heading.",
  );
  assert.doesNotMatch(
    decls,
    /overflow-wrap\s*:\s*anywhere/,
    "use break-word, not anywhere, on headings. `anywhere` participates in " +
      "min-content sizing and can collapse a shrink-to-fit ancestor around a " +
      "heading that fits perfectly well; `break-word` cannot, which is what " +
      "makes the desktop geometry provably unchanged.",
  );
  // The rule's existing job must survive the edit.
  for (const must of ["font-family: var(--paper-font-serif)", "color: var(--paper-ink)"]) {
    assert.ok(decls.includes(must), `the h1–h6 rule lost a pre-existing declaration: ${must}`);
  }
});

check(".bp-role-eyebrow can break a long word", () => {
  const decls = ruleStartingWith(".bp-paper-surface .bp-role-eyebrow {");
  assert.match(
    decls,
    /overflow-wrap\s*:\s*break-word/,
    ".bp-role-eyebrow must set overflow-wrap: break-word. Its uppercase " +
      "transform and 0.08em letter-spacing cost more per character than the " +
      "1.28em ingress does, so it is the role that overflows first — measured " +
      "at 320px, not inferred from font-size.",
  );
  for (const must of ["text-transform: uppercase", "letter-spacing: 0.08em"]) {
    assert.ok(
      decls.includes(must),
      `.bp-role-eyebrow lost ${must} — that pair is precisely why this rule ` +
        "needs the guard, so losing it would make the guard look arbitrary.",
    );
  }
});

// The two larger roles are measured CLEAN. Pinning that keeps a future reader
// from "fixing" them for symmetry and quietly widening the change.
for (const role of ["bp-role-ingress", "bp-role-pullquote"]) {
  check(`.${role} is left unguarded on purpose`, () => {
    const decls = ruleStartingWith(`.bp-paper-surface .${role} {`);
    assert.doesNotMatch(
      decls,
      /overflow-wrap/,
      `.${role} has no wrap guard because it does not need one — it is measured ` +
        "clean at 320px on every token the eyebrow fails. If a measurement now " +
        "says otherwise, add the declaration AND the row that proves it; do not " +
        "add it for symmetry with the eyebrow.",
    );
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
