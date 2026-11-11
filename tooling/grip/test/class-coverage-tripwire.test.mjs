// class-coverage-tripwire.test.mjs — the class-coverage TRIPWIRE, part (A) of
// the class-coverage suite.
//
//   node --test tooling/grip/test/class-coverage-tripwire.test.mjs
//
// One of the class-coverage-*.test.mjs files the single class-coverage suite was
// split into by subject (task-ff9bcdb1cbe00405); the tests moved unchanged. The
// controls for the classes the tripwire found uncontrolled, parts (B) to (D),
// are in class-coverage-controls.test.mjs; the firing registry, part (E), is in
// class-coverage-firing.test.mjs; the scans they share are in
// lib/class-coverage-scan.mjs. Where the header below says THIS FILE, it means
// those files together.
//
// WHY THIS FILE EXISTS, AND WHY IT IS NOT THE COMMAND THAT WAS FILED.
//
// The filed version of this work was a shell one-liner over SEVEN hand-listed
// modules, matching the HYPHEN spelling only. It reproduces three real absences
// (NO-QUANTITY, NOT-A-REF, WRITE-FAILED) — the measurement was right — but the
// method is wrong three times over:
//
//   1. THE FILE SET WAS HAND-LISTED. backfill.mjs was not on it, so TEST-RUNNER
//      escaped both prior scans. A hand-listed set measures the author's memory,
//      not the tree. This scan GLOBS.
//   2. THE SPELLING WAS SINGLE. census.mjs stores `TOOL_ERROR: "TOOL-ERROR"` and
//      census.test.mjs asserts through the UPPER_SNAKE enum KEY. A hyphen-only
//      scan therefore cries wolf on five genuinely-controlled census classes
//      (SCREEN-REFUSED, ANOMALOUS-SILENCE, AMBIGUOUS-SILENCE, UNCLASSIFIED-128,
//      SKIPPED-TEST-RUNNER) — never-cry-wolf failing INSIDE the instrument built
//      to enforce it. This scan matches BOTH spellings.
//   3. THE UNIVERSE WAS SCRAPED, NEVER ASKED FOR. A scan for HYPHENATED string
//      literals cannot see a class whose name is one word, and widening the
//      regex to bare SHOUTY words would swamp it in prose, fixture keys and
//      assertion names. So the universe is now the UNION of two layers: the
//      hyphenated literal scan, and the VALUES of the enum objects the modules
//      EXPORT, obtained by importing them. The enum layer is scoped to enum
//      values and to nothing else, which is what keeps a bare `PASS` written in
//      a comment out of the universe while putting `OUTCOME.PASS` in it.
//
// It is written in Node (fs + RegExp + import), not shell, deliberately: `grep`
// on the authoring host is ugrep 7.5.0, which rejects invocations GNU grep
// accepts, and grip has NO CI — so a shell-shaped tripwire is tested only on one
// box and untested where it would have to hold. A shell scan also cannot ask a
// module what it exports.
//
// WHAT THIS TRIPWIRE DOES NOT MEASURE — declared, not implied:
//   * IT IS STILL A LOWER BOUND, for two NAMED reasons rather than the old
//     hyphen one. (a) A class name assembled at runtime — concatenation or a
//     template literal — is a literal to neither layer and a value to neither
//     enum, so both layers are blind to it. (b) The enum layer reads DEPTH 1 of
//     an exported plain object with UPPER_SNAKE keys, so a class reached only
//     through an array of records, or one kept in a module-private table, is out
//     of its reach. The blind-spot test below pins binding.mjs's two array
//     registries (BINDING_RULES, EXIT_MASK_RULES) inside the union, so that
//     depth costs nothing TODAY — but a bound that costs nothing today is still
//     a bound.
//   * A MODULE THE SWEEP CANNOT IMPORT CONTRIBUTES NO ENUMS. The sweep runs in a
//     CHILD process precisely because a grip module may execute, print, or exit
//     on import — harvest.mjs runs its fixture gate the moment it is imported.
//     A module that kills the sweep is skipped, NAMED in the printed line, and
//     its enums are then outside the universe. The unreadable count is printed
//     next to the universe size so this bound is visible rather than implied.
//   * IT MEASURES MENTION, NOT CONTROL. A class named anywhere under test/ reads
//     as covered here. Mention is not control — proven by mutation in the survey:
//     renaming FORGE-API-READ to another same-class rule left binding.test.mjs at
//     63/62/1 unchanged, and renaming the else branch collapsed DEFAULT-CWD-BOUND
//     29 → 2 while IMPROVING the epic's flagship else-share with nothing going
//     red (binding.test.mjs registers rules through
//     `assert.ok(registered.has(…))`, a subset check that cannot fail for an
//     unexercised rule). So absence here is a PROOF of no control; presence is
//     only an INVITATION to check. The controls in part (B) below are the real
//     thing: each one fires the class on an input that must trigger it and
//     withholds it on a neighbour that must not.
//
//     RE-MEASURED, AND THE FIGURE NOW CARRIES ITS SHA (D102). At binding.mjs
//     blob a87ab60eb78693c6ee7dc30bbd9983e027370c26 over
//     fixtures/evidence-corpus.json blob f0d6b6cbdb50490889e4489ef782eaca7737e86c
//     the else share is 31 of 652 = 4.8% against the naive 3-way rule's 580 of
//     652 = 89.0%; re-running that rename drops it to 2 of 652 = 0.3%. The
//     survey wrote 0.6% for the mutated figure, which is the shape of the finding
//     but not this corpus's number. The aggregate guard that let the mutation
//     through is now two-sided and counted off the ARM rather than the rule name
//     — see binding.test.mjs's ELSE_BRANCH_FLOOR/ELSE_BRANCH_CEILING.
//   * IT DOES NOT COUNT ITS OWN DECLARATIONS. This file names classes in prose —
//     the paragraph above is itself an example — and a tripwire that reads its
//     own commentary as coverage grades its own homework. So THIS file
//     contributes to the corpus from the part (B) banner ONWARD and no earlier:
//     the controls count, the declarations do not. UNMINTABLE is why that
//     matters — under the old file it was "covered" by nothing but a sentence in
//     this header listing it as invisible.

import { test } from "node:test";
import assert from "node:assert/strict";

import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { BINDING_RULES, EXIT_MASK_RULES } from "../binding.mjs";
import { corpusTextOf, GRIP, scanClassCoverage, SUITE } from "./lib/class-coverage-scan.mjs";

// ─────────────────────────────────────────────────────────────────────────────
// (A) THE TRIPWIRE
// ─────────────────────────────────────────────────────────────────────────────

// The committed expectation. EMPTY is the whole point: every class in the union
// universe — hyphenated literal OR exported enum value — is named by some test
// under tooling/grip/test/. A new class landing with no test anywhere turns this
// red and names it, one word or seven.
const EXPECTED_UNCONTROLLED = [];

// What this file itself brought under control, measured by scanning with THIS
// file excluded from the test corpus — so the row below is the honest "before".
// Split by which LAYER sees them, because that split is the whole point of the
// change: the hyphenated seven were always visible to the scan, and UNMINTABLE
// was not visible to anything until the enum layer arrived.
const CONTROLLED_HERE = [
  "TEST-RUNNER",
  "FORGE-API-READ",
  "DEFAULT-CWD-BOUND",
  "TOOL-ERROR",
  "WRITE-FAILED",
  "NOT-A-REF",
  "NO-QUANTITY",
];
const CONTROLLED_HERE_UNHYPHENATED = ["UNMINTABLE"];

test("TRIPWIRE: every class in tooling/grip/*.mjs — hyphenated literal OR exported enum value — is named by some test", () => {
  const scan = scanClassCoverage();
  const names = scan.uncontrolled.map((row) => `${row.id} (${row.where})`);

  // NON-VACUITY OF THE SELF-SLICE. If the slice ever swallowed part (A), this
  // file's own declarations would start counting as coverage and the tripwire
  // would go quietly green on classes nothing exercises; if it swallowed part
  // (B) instead, seven controlled classes would flag. Both directions are pinned.
  const selfControls = SUITE.map((name) => corpusTextOf(name, readFileSync(join(GRIP, "test", name), "utf8"))).join("\n");
  assert.ok(selfControls.includes("never cries wolf: a pathless ref"), "the self-slice lost this file's controls");
  assert.ok(!selfControls.includes("EXPECTED_UNCONTROLLED"), "the self-slice swallowed part (A) — declarations would credit themselves");

  console.log(
    `\n  [class-coverage] ${scan.modules.length} modules globbed, ${scan.testFiles.length} test files read` +
      `, ${scan.unreadable.length} modules unreadable by the enum sweep${scan.unreadable.length ? ` (${scan.unreadable.join(", ")})` : ""}` +
      `\n  [class-coverage] universe ${scan.universe.size} = ${scan.literalUniverse.size} hyphenated literals ∪ ${scan.enumUniverse.size} exported enum values (LOWER BOUND — see the blind-spot test)` +
      `\n  [class-coverage] uncontrolled: ${names.length === 0 ? "none" : names.join(", ")}\n`,
  );

  assert.deepEqual(
    names,
    EXPECTED_UNCONTROLLED,
    "a class exists in tooling/grip/*.mjs that no test names under any spelling — write a fail-before control for it, or add it to EXPECTED_UNCONTROLLED with a written reason",
  );
});

test("TRIPWIRE never cries wolf: the hyphen-only method flags five census classes this scan clears", () => {
  // These five ARE controlled — census.test.mjs asserts them as fired outcomes
  // through the UPPER_SNAKE enum key (OUTCOME.TOOL_ERROR …), which is how the
  // module spells them at the call site. The filed hyphen-only scan cannot see
  // that spelling and reports them absent.
  const CRIED_WOLF_ON = ["SCREEN-REFUSED", "ANOMALOUS-SILENCE", "AMBIGUOUS-SILENCE", "UNCLASSIFIED-128", "SKIPPED-TEST-RUNNER"];

  // Scanned with THIS file excluded, so the comparison is the historical one:
  // what the methods said about the tree BEFORE this file existed.
  const before = scanClassCoverage({ excludeTests: SUITE });
  const hyphen = before.hyphenOnly.map((r) => r.id);
  const dual = before.dual.map((r) => r.id);
  const union = before.uncontrolled.map((r) => r.id);

  for (const id of CRIED_WOLF_ON) {
    assert.ok(hyphen.includes(id), `${id} should be flagged by the hyphen-only method (that is the defect being demonstrated)`);
    assert.ok(!dual.includes(id), `${id} is controlled via its UPPER_SNAKE spelling and must NOT be flagged`);
    assert.ok(!union.includes(id), `${id} is controlled — the union layer must not re-introduce the false alarm`);
  }
  for (const id of CONTROLLED_HERE) {
    assert.ok(dual.includes(id), `${id} was uncontrolled before this file — if another test now controls it, drop it from CONTROLLED_HERE`);
  }
  for (const id of CONTROLLED_HERE_UNHYPHENATED) {
    assert.ok(!dual.includes(id), `${id} carries no hyphen — the literal layer cannot see it and must not report it`);
    assert.ok(union.includes(id), `${id} was uncontrolled before this file — if another test now controls it, drop it from CONTROLLED_HERE_UNHYPHENATED`);
  }

  console.log(
    `\n  [side by side] hyphen-only (the filed method): ${hyphen.length} flagged — ${hyphen.join(", ")}` +
      `\n  [side by side] dual-spelling, literals only:  ${dual.length} flagged — ${dual.join(", ")}` +
      `\n  [side by side] union with the enum layer:     ${union.length} flagged — ${union.join(", ")}` +
      `\n  [side by side] the ${CRIED_WOLF_ON.length} cleared are controlled through the UPPER_SNAKE enum key, not the hyphen string` +
      `\n  [side by side] the enum layer adds ${union.length - dual.length}: ${CONTROLLED_HERE_UNHYPHENATED.join(", ")} — invisible to every literal scan\n`,
  );
});

test("TRIPWIRE declares its residual blind spot: the hyphen hole is CLOSED, what is left is depth and construction", () => {
  // The seven the previous draft of this file declared invisible by construction.
  // Both halves are load-bearing: they are still absent from the LITERAL layer
  // (nothing was renamed to sneak them in), and they are now IN the universe via
  // the enum layer. If a rename gives one a hyphen the first goes red; if one
  // leaves its enum the second goes red, and either way the declaration below is
  // stale and must be rewritten.
  const CLOSED_BY_THE_ENUM_LAYER = ["ADMITTED", "DEMOTED", "REJECTED", "FAILED", "UNAVAILABLE", "CONFLICT", "UNMINTABLE"];
  const scan = scanClassCoverage();
  for (const id of CLOSED_BY_THE_ENUM_LAYER) {
    assert.ok(!scan.literalUniverse.has(id), `${id} carries a hyphen now — it is no longer an example of the closed hole`);
    assert.ok(scan.universe.has(id), `${id} is no longer an exported enum value — the blind-spot declaration below must be rewritten`);
  }

  // THE RESIDUAL DEPTH BOUND, priced rather than asserted away. The enum layer
  // reads depth 1 of an exported object, so binding.mjs's two ARRAY registries
  // are outside it. They cost nothing today only because every rule name they
  // carry is also a hyphenated literal the other layer sees — which is a fact
  // about today's spelling, not a property of the scan, so it is pinned here.
  for (const entry of [...BINDING_RULES, ...EXIT_MASK_RULES]) {
    assert.ok(
      scan.universe.has(entry.rule),
      `${entry.rule} lives in an array registry the enum layer does not walk, and it is no longer a hyphenated literal either — it has fallen out of the universe entirely`,
    );
  }

  console.log(
    `\n  [BLIND SPOT] The hyphen hole is CLOSED: the universe is now hyphenated literals ∪ exported enum values,` +
      ` so ${CLOSED_BY_THE_ENUM_LAYER.length} one-word classes the previous draft declared invisible are inside it.` +
      ` WHAT REMAINS, and why the number is still a LOWER BOUND: (a) a class name built at RUNTIME by concatenation` +
      ` is a literal to neither layer; (b) the enum layer reads DEPTH 1 of an exported object, so a class held only in` +
      ` an array of records or in a module-private table is out of reach — the ${BINDING_RULES.length + EXIT_MASK_RULES.length}` +
      ` array-registry rules pinned above are covered by the literal layer, not by the enum one;` +
      ` (c) ${scan.unreadable.length} module(s) the sweep could not import contribute no enums at all.` +
      ` And mention under test/ is still not control.\n`,
  );
});

test("TRIPWIRE is able to fail: planted classes in a scratch copy of the tree are named — hyphenated AND one word", () => {
  // Both plants' NAMES are assembled at runtime and never appear spelled out in
  // any file under test/ — otherwise this very file would "control" them by
  // mention and the plants would come back clean, which is how a tripwire proves
  // itself green without being able to go red. (The self-slice would drop this
  // block from the corpus anyway; assembling the names too means the plant does
  // not depend on the slice being right.)
  const plantedHyphen = ["PLANTED", "UNCONTROLLED", "CLASS"].join("-");
  const plantedWord = ["PLANTED", "SINGLEWORD", "CLASS"].join("");
  const scratch = mkdtempSync(join(tmpdir(), "grip-classcov-plant-"));
  try {
    cpSync(GRIP, join(scratch, "grip"), { recursive: true });
    const src = join(scratch, "grip");
    writeFileSync(
      join(src, "planted.mjs"),
      `export const PLANTED = Object.freeze({ NEVER_TESTED: "${plantedHyphen}", ALSO_NEVER_TESTED: "${plantedWord}" });\n`,
      "utf8",
    );
    const scan = scanClassCoverage({ srcDir: src, testDir: join(src, "test") });
    const flagged = scan.uncontrolled.map((r) => r.id);
    assert.ok(flagged.includes(plantedHyphen), `the hyphenated plant was not flagged; scan said ${JSON.stringify(flagged)}`);
    assert.ok(flagged.includes(plantedWord), `the ONE-WORD plant was not flagged — this is the hole the enum layer exists to close; scan said ${JSON.stringify(flagged)}`);
    assert.ok(!scan.literalUniverse.has(plantedWord), "the one-word plant must be invisible to the literal layer — otherwise this proves nothing about the enum layer");
    assert.ok(scan.enumUniverse.has(plantedWord), "the enum layer did not see the planted enum value");
    assert.ok(scan.modules.includes("planted.mjs"), "the glob missed a new module — a hand-listed set is exactly how backfill.mjs escaped");
    assert.deepEqual(scan.unreadable, [], "the enum sweep could not import part of the scratch tree — the plant result is not trustworthy");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
