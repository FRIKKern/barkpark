#!/usr/bin/env node
// The suite's OWN SHAPE is asserted here — tooling/grip/test/suite-shape.test.mjs
//
//   node --test tooling/grip/test/suite-shape.test.mjs
//
// WHY THIS FILE EXISTS: THE FILE FLOOR IS DEFEATED BY EMPTY FILES.
//
// .github/workflows/grip-suite.yml gates this suite on four clauses — `node
// --test` exit 0, `# fail 0`, `# skipped 1`, and at least 20 files matching
// tooling/grip/test/*.test.mjs. That fourth clause was itself added because the
// first three were defeated by construction (`node --test rerun.test.mjs
// DOES-NOT-EXIST.test.mjs` exits 0 with `# fail 0` and `# skipped 1` while 15 of
// 16 real files silently never run). The file floor closes THAT hole and opens a
// smaller one directly underneath it, because a FILE IS NOT A TEST:
//
//     19 files containing the single line `// gutted`
//   +  1 file containing only `test("x", { skip: true }, () => {})`
//
// EXECUTED, not reasoned about:
//
//     file count: 20  (floor is 20)      → clause 4 passes
//     node --test exit: 0                → clause 1 passes
//     # tests 20 / # pass 19             → (never asserted)
//     # fail 0                           → clause 2 passes
//     # skipped 1                        → clause 3 passes
//
// All four clauses green on a suite that asserts NOTHING, down from this repo's
// real 736. Note `# tests 20`, not `# tests 0`: node --test counts each FILE as
// a test, so even a naive `# tests` floor set at 20 would have passed the same
// input. The floor has to be well above the file count to mean anything.
//
// WHAT THIS FILE CAN AND CANNOT DEFEND — stated, not implied.
//
//   * IT CANNOT SURVIVE ITS OWN DELETION. Gut all 21 files including this one
//     and the file floor still reads 21 while nothing runs. Only a `# tests N`
//     floor in the WORKFLOW closes that, and .github/** is another owner's
//     fence. That clause is written out at the bottom of this file, ready to
//     lift, and the proof above is what justifies it.
//   * IT SCANS SOURCE, NOT RUNTIME. A file full of `test("x", () => {})` with no
//     body satisfies the declaration count, which is why an ASSERTION count is
//     asserted alongside it — and why the per-file minimum matters more than the
//     total: the realistic accident is one file emptied by a bad merge, not a
//     self-consistent gutting of twenty.
//   * IT MEASURES PRESENCE, NOT STRENGTH. An assertion that cannot fail counts
//     here exactly like one that can. class-coverage.test.mjs makes the same
//     declaration about mention-vs-control and it is the same bound.
//
// THE SPELLING TRAP THIS FILE HAD TO AVOID, because the first draft of the
// counter fell straight into it: mint.test.mjs imports `{ ok, strictEqual,
// deepStrictEqual }` from node:assert/strict and never writes the string
// `assert.` once, so an `assert\.` scan rates the repo's 38-test mint suite at
// ZERO assertions — the identical single-spelling defect class-coverage.test.mjs
// documents for its own hyphen-only scan. So the aliases are derived FROM EACH
// FILE'S OWN IMPORT STATEMENT rather than guessed, and part (C) below is a
// control proving the counter reports a gutted file.

import { test } from "node:test";
import assert from "node:assert/strict";

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SELF = "suite-shape.test.mjs";

/** Every sibling suite file, GLOBBED — a hand-listed set measures the author's memory. */
const suiteFiles = () => readdirSync(HERE).filter((f) => f.endsWith(".test.mjs")).sort();

const TEST_DECL = /^[ \t]*(?:await\s+)?(?:test|it)(?:\.(?:skip|todo|only))?\s*\(/gm;

/**
 * Assertion call sites in ONE file, counted through the aliases that file's own
 * `node:assert` import actually binds — both the default-object spelling
 * (`assert.equal(`) and the named spelling (`strictEqual(`).
 */
function assertionSites(src) {
  let n = 0;
  const names = new Set();
  for (const m of src.matchAll(/^import\s+([^;]+?)\s+from\s+["']node:assert(?:\/strict)?["']/gm)) {
    const clause = m[1];
    const def = clause.match(/^\s*([A-Za-z_$][\w$]*)/);
    if (def) n += (src.match(new RegExp(`\\b${def[1]}\\s*(?:\\.[A-Za-z]+)?\\s*\\(`, "g")) || []).length;
    const named = clause.match(/\{([^}]*)\}/);
    if (named) for (const raw of named[1].split(",")) {
      const alias = raw.split(/\s+as\s+/).pop().trim();
      if (alias) names.add(alias);
    }
  }
  for (const alias of names) n += (src.match(new RegExp(`\\b${alias}\\s*\\(`, "g")) || []).length;
  return n;
}

const shapeOf = (file) => {
  const src = readFileSync(join(HERE, file), "utf8");
  return { file, tests: (src.match(TEST_DECL) || []).length, asserts: assertionSites(src) };
};

// FLOORS. Measured against the tree, then set with headroom so an ordinary
// refactor does not red them — the point is to catch a file going to ZERO, not
// to pin a total. Measured on the tree that ships this file: 21 files, 719
// source-counted declarations, 2626 assertion sites, and the thinnest real file
// is foldledger-injection.test.mjs at 3 declarations / 11 assertion sites.
const PER_FILE_TESTS = 2;
const PER_FILE_ASSERTS = 3;
const TOTAL_TESTS = 600;
const TOTAL_ASSERTS = 2000;

// (A) NO FILE IS EMPTY — the clause that kills the 19-empty-files defeat.
test("every suite file declares tests AND asserts something", () => {
  const shapes = suiteFiles().map(shapeOf);
  assert.ok(shapes.length >= 20, `expected at least 20 suite files, found ${shapes.length}`);
  const thin = shapes.filter((s) => s.tests < PER_FILE_TESTS || s.asserts < PER_FILE_ASSERTS);
  assert.deepEqual(
    thin, [],
    `these suite files declare fewer than ${PER_FILE_TESTS} tests or fewer than ${PER_FILE_ASSERTS} assertion sites — ` +
      `a file that asserts nothing still satisfies grip-suite.yml's file floor, which is why this check exists`,
  );
});

// (B) THE SUITE AS A WHOLE HAS NOT BEEN HOLLOWED OUT.
test("the suite's total test and assertion counts hold above their floors", () => {
  const shapes = suiteFiles().map(shapeOf);
  const tests = shapes.reduce((n, s) => n + s.tests, 0);
  const asserts = shapes.reduce((n, s) => n + s.asserts, 0);
  assert.ok(tests >= TOTAL_TESTS, `suite declares ${tests} tests, floor is ${TOTAL_TESTS} — per file: ${JSON.stringify(shapes)}`);
  assert.ok(asserts >= TOTAL_ASSERTS, `suite has ${asserts} assertion sites, floor is ${TOTAL_ASSERTS} — per file: ${JSON.stringify(shapes)}`);
});

// (C) CONTROL: THE COUNTER CAN REPORT A GUT. A floor that has never been
// observed failing is not a floor. This runs the SHIPPED counter over the exact
// defeat input measured in the header — no reimplementation, so it proves the
// counter rather than a copy of it.
test("CONTROL: the shipped counter reports the 19-empty-files defeat", () => {
  const gutted = "// gutted\n";
  const oneSkip = 'import { test } from "node:test";\ntest("the one skip the predicate demands", { skip: true }, () => {});\n';
  const shape = (src) => ({ tests: (src.match(TEST_DECL) || []).length, asserts: assertionSites(src) });
  assert.deepEqual(shape(gutted), { tests: 0, asserts: 0 }, "an emptied file must count as zero, not as one file");
  assert.deepEqual(shape(oneSkip), { tests: 1, asserts: 0 }, "a skip-only file declares a test and asserts nothing");
  // …and that whole synthetic suite is BELOW every floor above, while satisfying
  // all four clauses grip-suite.yml actually checks (proven live in the header).
  const synthetic = [...Array(19).fill(gutted), oneSkip].map(shape);
  assert.ok(synthetic.reduce((n, s) => n + s.tests, 0) < TOTAL_TESTS, "the defeat input must fall below the total floor");
  assert.ok(synthetic.some((s) => s.tests < PER_FILE_TESTS && s.asserts < PER_FILE_ASSERTS), "and below the per-file floor");
});

// (D) THE COUNTER HANDLES BOTH ASSERT SPELLINGS — the mint.test.mjs trap.
test("the assertion counter reads the named-import spelling, not only `assert.`", () => {
  const named = 'import { ok, strictEqual } from "node:assert/strict";\nok(1);\nstrictEqual(1, 1);\n';
  const dflt = 'import assert from "node:assert/strict";\nassert.equal(1, 1);\nassert.ok(1);\n';
  assert.equal(assertionSites(named), 2, "named-import assertions must be counted");
  assert.equal(assertionSites(dflt), 2, "default-import assertions must be counted");
  // The live proof: mint.test.mjs is the file that spells it the second way.
  const mint = shapeOf("mint.test.mjs");
  assert.ok(mint.asserts > 0, `mint.test.mjs asserts through named imports and must not read as zero (got ${mint.asserts})`);
  // And this file must not be the only one keeping itself above the floor.
  assert.ok(suiteFiles().filter((f) => f !== SELF).length >= 20, "the floor must be met by files OTHER than this one");
});

// ─────────────────────────────────────────────────────────────────────────────
// THE WORKFLOW CLAUSE THIS FILE CANNOT ADD ITSELF
// ─────────────────────────────────────────────────────────────────────────────
//
// Everything above dies with the file. The complete fix is a FIFTH clause in
// .github/workflows/grip-suite.yml's "grip suite" step, alongside its existing
// fail/skipped parse — that file is another owner's fence, so it is written out
// here rather than applied:
//
//     tests=$(awk -F'# tests ' '/^# tests /{print $2}' "$RUNNER_TEMP/grip-suite.log")
//     floor_tests=600
//     if [ -z "$tests" ] || [ "$tests" -lt "$floor_tests" ]; then
//       echo "::error::expected at least $floor_tests tests, got '# tests ${tests:-<none>}' — \
//     the FILE floor is satisfied by empty files (19 empty + 1 skip-only = exit 0, # fail 0, # skipped 1)"
//       status=1
//     fi
//
// 600 rather than today's 736 for the same headroom reason as the floors above,
// and well clear of the ~21 a fully-gutted tree would report.
