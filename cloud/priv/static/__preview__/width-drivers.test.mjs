// width-drivers.test.mjs — the arms for task-72ffb2fdecffd2d3.
//
// THE SHAPE THIS SUITE INHERITS: breakpoint-sweep.test.mjs's recount arms
// (#17538). A COMMENT CANNOT BE DERIVED, only RECOUNTED — so the numerals and
// names in overflow-guard.mjs's 1280 coverage line are read back out of the
// axes here, and drift reds instead of printing quietly on a green run.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { driverSentence, parseAxes, widthDrivers } from "./width-drivers.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GUARD = fs.readFileSync(path.join(HERE, "overflow-guard.mjs"), "utf8");

// ── THE PARSER ───────────────────────────────────────────────────────────────

test("a flat numeric axis is read, with its scope and its line", () => {
  const axes = parseAxes('const BAND_WIDTHS = [721, 900, 1024];\n');
  assert.equal(axes.length, 1);
  assert.equal(axes[0].name, "BAND_WIDTHS");
  assert.equal(axes[0].leg, null, "column 0 means module scope");
  assert.deepEqual(axes[0].widths, [721, 900, 1024]);
  assert.equal(axes[0].pairs, null);
  assert.equal(axes[0].line, 1);
  assert.equal(axes[0].max, 1024);
});

test("THE BLINDNESS THAT WROTE THE FALSE SENTENCE: a pair axis drives widths too", () => {
  // A reader grepping `const *_WIDTHS` for 1280 finds ONE hit and concludes
  // nothing else drives it. FLICK_VIEWPORTS is [[w, h], …] — the shape every
  // height-varying leg uses — and it is the counter-example.
  const src = '  const FLICK_VIEWPORTS = [[320, 568], [390, 844], [1280, 900]];\n';
  const [axis] = parseAxes(src);
  assert.deepEqual(axis.widths, [320, 390, 1280], "the WIDTH of each pair is a driven width");
  assert.deepEqual(axis.pairs, [[320, 568], [390, 844], [1280, 900]]);
  assert.equal(axis.cellFor(1280), "1280x900", "and the sentence must be able to say WHICH cell, not just the width");
  // MUTATION: a widths-only parser reproduces the original false negative.
  const widthsOnly = (s) => parseAxes(s).filter((a) => !a.pairs);
  assert.deepEqual(widthsOnly(src), [], "drop pair support and FLICK_VIEWPORTS vanishes — which is exactly how 'nothing drives 1280' got written");
});

test("SCOPE IS INDENTATION, not 'the nearest const D above'", () => {
  const src = [
    'const WIDTHS = [721, 1440];',
    '    if (requested.includes("W26-x")) {',
    '      const D = "W26-x";',
    '      const TRACK_WIDTHS = [900, 1280];',
    'const LATER_WIDTHS = [320];',
  ].join("\n");
  const by = Object.fromEntries(parseAxes(src).map((a) => [a.name, a.leg]));
  assert.equal(by.WIDTHS, null);
  assert.equal(by.TRACK_WIDTHS, "W26-x");
  assert.equal(by.LATER_WIDTHS, null,
    "a module-level axis declared AFTER a leg is still module-level; keying on the last `const D` would hand it to W26-x and nobody would ever see the lie");
});

test("the BARE `WIDTHS` axis is found — a naming convention is not a guarantee", () => {
  // MEASURED: with the prefix group mandatory, this derivation reported FIVE
  // axes above 1280 instead of six, missing the file's primary axis.
  const axes = parseAxes(GUARD);
  const bare = axes.find((a) => a.name === "WIDTHS");
  assert.ok(bare, "overflow-guard.mjs's module-level `const WIDTHS` must be in the census");
  assert.equal(bare.max, 1440);
  assert.equal(bare.leg, null);
});

test("a non-numeric array is not an axis", () => {
  assert.deepEqual(parseAxes('const FLICK_SCENS = ["failed", "mixed-fleet"];'), []);
  assert.deepEqual(parseAxes('const THEME_WIDTHS = [];'), []);
});

// ── THE CLAIM, RECOUNTED AGAINST THE SHIPPED FILE ────────────────────────────

test("THE DEFECT: 1280 IS driven elsewhere in this file, and the leg says so by name", () => {
  const r = widthDrivers(GUARD, 1280, "TRACK_WIDTHS");
  assert.ok(r.drivers.length >= 1,
    "the retired sentence claimed 1280 was driven by nothing; if this is ever 0 again, the sentence below must say the honest negative and someone must have MEANT it");
  const flick = r.drivers.find((a) => a.name === "FLICK_VIEWPORTS");
  assert.ok(flick, "FLICK_VIEWPORTS has driven 1280x900 since 7c8fa229a (2026-08-03) — it is THE counter-example this row was filed on");
  assert.equal(flick.leg, "W27-failed-retry-reachable-after-flick");
  assert.equal(flick.cellFor(1280), "1280x900");
});

test("and the OTHER half: axes above 1280 exist, so 'a sweep stopping at 1024' was never the ceiling", () => {
  const r = widthDrivers(GUARD, 1280, "TRACK_WIDTHS");
  assert.ok(r.above.length >= 6, `expected at least the six 1440 axes above 1280, found ${r.above.length}`);
  assert.equal(Math.max(...r.above.map((a) => a.max)), 1440);
  assert.ok(r.above.some((a) => a.name === "WIDTHS"), "including the module-level default axis");
});

test("MUTATION — REMOVE 1280 FROM FLICK_VIEWPORTS AND THE SENTENCE MOVES", () => {
  const mutated = GUARD.replace(
    "const FLICK_VIEWPORTS = [[320, 568], [390, 844], [1280, 900]];",
    "const FLICK_VIEWPORTS = [[320, 568], [390, 844]];",
  );
  assert.notEqual(mutated, GUARD, "the mutation must bite — if the literal moved, re-aim this arm rather than deleting it");
  const before = driverSentence(widthDrivers(GUARD, 1280, "TRACK_WIDTHS"));
  const after = driverSentence(widthDrivers(mutated, 1280, "TRACK_WIDTHS"));
  assert.notEqual(after, before, "THIS is the whole point: a prose sentence would have printed the same words either way");
  assert.match(before, /ALSO driven by 1 other axis/);
  assert.match(after, /driven by NO other axis in this file/,
    "and the derivation is willing to say the honest negative — the old claim was not wrong for being negative, it was wrong for being unrecounted");
});

test("MUTATION — ADD A SEVENTH 1280 DRIVER AND THE COUNT FOLLOWS", () => {
  const mutated = GUARD.replace(
    "const RAIL_WIDTHS = [320, 390, 900];",
    "const RAIL_WIDTHS = [320, 390, 900, 1280];",
  );
  assert.notEqual(mutated, GUARD);
  const r = widthDrivers(mutated, 1280, "TRACK_WIDTHS");
  assert.equal(r.drivers.length, 2);
  assert.match(driverSentence(r), /ALSO driven by 2 other axis\/axes/);
});

// ── THE RETIRED CLAIM MUST NOT COME BACK ─────────────────────────────────────

test("no surviving PRINT in overflow-guard.mjs asserts that 1280 is driven by nothing", () => {
  // Scoped to what a RUN emits. The header comment quotes the retired sentence
  // on purpose — a retraction that cannot quote what it retracts is a worse
  // document — so this arm reads the okLine/process.stdout side only.
  const emitted = [...GUARD.matchAll(/okLine\(([\s\S]*?)\);\n/g)].map((m) => m[1]).join("\n");
  assert.ok(!/driven by NO other instrument/.test(emitted),
    "the false claim is back in a printed line");
  assert.ok(!/sweep stopping at 1024 certifies/.test(emitted),
    "the second false half is back in a printed line");
  // NOT VACUOUS: the scan reaches real okLine bodies.
  assert.ok(/NEGATIVE CONTROLS/.test(emitted), "the okLine scan must actually be reading the W26 leg's printed lines");
});

test("the guard PRINTS the derived sentence rather than a copy of today's answer", () => {
  assert.match(GUARD, /from "\.\/width-drivers\.mjs"/);
  assert.match(GUARD, /okLine\(driverSentence\(widthDrivers\(SELF_SRC, 1280, "TRACK_WIDTHS"\)\)\);/,
    "the leg must call the derivation; pasting its current output back in as a literal is the rot this row exists to stop");
  assert.match(GUARD, /const SELF_SRC = fs\.readFileSync\(fileURLToPath\(import\.meta\.url\), "utf8"\);/,
    "and derive it from THIS FILE'S bytes");
});
