// __callout_shorthand.test.mjs — pure-Node unit test for the `> [!type]`
// callout authoring shorthand: the trigger regex + normalizeTone. Deliberately
// SEPARATE from __smoke.mjs because a callout never enters convert.js (it is
// inserted server-side via default_block, not round-tripped through the block
// converters), and because this test imports only the DOM-free tone.js — it
// never instantiates TipTap or touches HTMLElement.
//
// Run: node src/__callout_shorthand.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { normalizeTone } from "./tone.js";

// The exact regex the WC's _maybeCalloutShorthand uses (kept in sync by review;
// the no-newline guard in the WC means \s only ever matches the trailing space).
const SHORTHAND = /^>\s*\[!(\w+)\]([+-]?)\s$/;

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

// ── regex: what fires and what doesn't ─────────────────────────────────────

check("fires on `> [!note] ` (space-separated, no modifier)", () => {
  const m = SHORTHAND.exec("> [!note] ");
  assert.ok(m, "expected a match");
  assert.equal(m[1], "note");
  assert.equal(m[2], "");
});

check("fires on `>[!warn]- ` (no space after >, collapse modifier)", () => {
  const m = SHORTHAND.exec(">[!warn]- ");
  assert.ok(m);
  assert.equal(m[1], "warn");
  assert.equal(m[2], "-");
});

check("fires on `> [!info]+ ` (expand modifier)", () => {
  const m = SHORTHAND.exec("> [!info]+ ");
  assert.ok(m);
  assert.equal(m[1], "info");
  assert.equal(m[2], "+");
});

check("does NOT fire without the committing trailing space", () => {
  assert.equal(SHORTHAND.exec("> [!note]"), null);
  assert.equal(SHORTHAND.exec("> [!note]-"), null);
});

check("does NOT fire with trailing prose after the space", () => {
  assert.equal(SHORTHAND.exec("> [!note] x"), null);
});

check("does NOT fire on a plain blockquote or a slash trigger", () => {
  assert.equal(SHORTHAND.exec("> not a callout "), null);
  assert.equal(SHORTHAND.exec("/head"), null);
  assert.equal(SHORTHAND.exec("[!note] "), null); // no leading '>'
});

check("is anchored at offset 0 (no mid-line match)", () => {
  assert.equal(SHORTHAND.exec("prefix > [!note] "), null);
});

// ── modifier → collapsed mapping (the WC computes collapsed = m[2] === "-") ──

check("collapsed iff modifier is '-'", () => {
  assert.equal("" === "-", false);
  assert.equal("-" === "-", true);
  assert.equal("+" === "-", false);
});

// ── normalizeTone: aliases remap, canonical pass-through, unknown -> info ────

check("aliases remap (note->info, warn->warning, error->danger)", () => {
  assert.equal(normalizeTone("note"), "info");
  assert.equal(normalizeTone("warn"), "warning");
  assert.equal(normalizeTone("error"), "danger");
});

check("canonical tones pass through unchanged", () => {
  for (const t of ["info", "success", "warning", "danger", "neutral"]) {
    assert.equal(normalizeTone(t), t);
  }
});

check("case-insensitive", () => {
  assert.equal(normalizeTone("NOTE"), "info");
  assert.equal(normalizeTone("Warning"), "warning");
});

check("unknown / empty / non-string falls back to info", () => {
  assert.equal(normalizeTone("bogus"), "info");
  assert.equal(normalizeTone(""), "info");
  assert.equal(normalizeTone(undefined), "info");
  assert.equal(normalizeTone(null), "info");
});

// ── end-to-end: regex token -> normalizeTone -> canonical ──────────────────

check("`> [!warn]- ` yields tone=warning, collapsed=true", () => {
  const m = SHORTHAND.exec("> [!warn]- ");
  assert.ok(m);
  assert.equal(normalizeTone(m[1]), "warning");
  assert.equal(m[2] === "-", true);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall callout-shorthand checks PASS");
