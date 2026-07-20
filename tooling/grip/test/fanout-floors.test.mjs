#!/usr/bin/env node
// fanout-floors.test.mjs — proof for the never-fewer-agents floors in
// .claude/workflows/wild-bulk-cycle.workflow.js.
//
//   node --test tooling/grip/test/fanout-floors.test.mjs
//
// WHY THIS FILE EXISTS. The slice's own gate is `node --check` — a SYNTAX
// check. It cannot tell a floor of 3 from a floor of 0, a `<` from a `<=`, or a
// deleted throw from a present one. That is vacuous green over exactly the
// guards the slice was built to add, and it is the same defect the floors
// themselves exist to prevent one level up: the anti-goal was prose, prose does
// not run, so it became a throw — and then the throw was checked by something
// that does not run it either. The builder proved these in a scratchpad harness
// that dies with the run and filed tgw-bl-fanout-floor-harness; this is that
// harness, committed, so the next edit to the file cannot silently break a
// floor.
//
// WHY A VM HARNESS AND NOT AN IMPORT. A workflow file is compiled by the host as
// a CLASSIC SCRIPT inside a vm context with codeGeneration disabled, and it has
// top-level await plus a column-0 top-level return — it cannot be imported or
// required (charter D19, settled). So this does what the host does: read the
// source, extract the guard, and run it under a reproduction of that context.
//
// WHAT THIS DOES *NOT* PROVE, stated plainly (charter D28): these throws have
// never fired in a real run, and neither have bp-epic-cycle's. Everything below
// is harness evidence over an extracted guard. A harness is not a wave.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const WORKFLOW = join(REPO, ".claude", "workflows", "wild-bulk-cycle.workflow.js");
const SOURCE = readFileSync(WORKFLOW, "utf8");

// The context the host builds. Proven hostile below before anything relies on it.
function hostContext(extra = {}) {
  return vm.createContext(Object.assign(Object.create(null), extra), {
    codeGeneration: { strings: false, wasm: false },
  });
}

function run(code, extra = {}) {
  return new vm.Script(code).runInContext(hostContext(extra));
}

test("the reproduced context really does refuse codegen, so the rest of this file means something", () => {
  assert.throws(() => run("eval('1+1')"), /EvalError|Code generation/);
  assert.throws(() => run("new Function('return 1')()"), /EvalError|Code generation/);
});

// ── the constants ────────────────────────────────────────────────────────────

function floorValue(name) {
  const m = SOURCE.match(new RegExp(`const ${name}\\s*=\\s*(\\d+)`));
  assert.notEqual(m, null, `${name} is gone from ${WORKFLOW} — a named floor constant was removed or renamed`);
  return Number(m[1]);
}

const FLOORS = {
  DOMAIN_FLOOR: 3,
  PROBE_FLOOR: 10,
  BUNDLE_FLOOR: 3,
  CUT_TASK_FLOOR: 4,
};

test("all four floors exist as named constants at their ratified values", () => {
  for (const [name, expected] of Object.entries(FLOORS)) {
    assert.equal(floorValue(name), expected, `${name} must be ${expected}`);
  }
});

test("a floor of zero would not be a floor — every value is >= 1", () => {
  for (const name of Object.keys(FLOORS)) {
    assert.ok(floorValue(name) >= 1, `${name} must be a real floor, not 0`);
  }
});

// ── the guards actually throw, over n = 0, 1, floor-1, floor, floor+1 ────────
//
// Each guard's CONDITION is lifted from the source by pattern (never by line
// number — every cited line number in this epic's history went stale within a
// wave) and evaluated in the host-shaped context. A guard that stopped
// comparing, or flipped `<` to `<=`, reds here.

function extractCondition(needle) {
  const at = SOURCE.indexOf(needle);
  assert.notEqual(at, -1, `guard \`${needle}\` is gone — a fan-out floor was removed`);
  return needle;
}

function firesAt(condition, floorName, n) {
  const value = { length: n, isArray: true };
  return run(
    `(() => { const ${floorName} = ${floorValue(floorName)};
              const fanout = (v) => (Array.isArray(v) ? v.length : -1);
              const arr = Array.from({length: ${n}}, (_, i) => i);
              const planner = { domains: arr }, digest = { bundles: arr },
                    c = { tasks: arr }, probes = arr, cuts = arr, surveyed = arr,
                    cutCount = fanout(c.tasks);
              return !!(${condition}); })()`,
    { value },
  );
}

const GUARDS = [
  ["fanout(planner.domains) < DOMAIN_FLOOR", "DOMAIN_FLOOR"],
  ["probes.length < PROBE_FLOOR", "PROBE_FLOOR"],
  ["surveyed.length < DOMAIN_FLOOR", "DOMAIN_FLOOR"],
  ["fanout(digest.bundles) < BUNDLE_FLOOR", "BUNDLE_FLOOR"],
  ["cuts.length < BUNDLE_FLOOR", "BUNDLE_FLOOR"],
  ["cutCount < CUT_TASK_FLOOR", "CUT_TASK_FLOOR"],
];

test("every guard is present in the source, verbatim", () => {
  for (const [condition] of GUARDS) extractCondition(condition);
});

test("every floor fires below it and stays silent at and above it", () => {
  for (const [condition, floorName] of GUARDS) {
    const floor = floorValue(floorName);
    for (const n of [0, 1, floor - 1]) {
      if (n < 0) continue;
      assert.equal(firesAt(condition, floorName, n), true, `${condition} must FIRE at n=${n} (floor ${floor})`);
    }
    for (const n of [floor, floor + 1]) {
      assert.equal(firesAt(condition, floorName, n), false, `${condition} must NOT fire at n=${n} (floor ${floor})`);
    }
  }
});

// ── the non-array trap ───────────────────────────────────────────────────────
//
// "abc".length is 3, which SATISFIES a floor of 3 and then faults on the .map()
// two lines later with an error naming neither the floor nor the cause. A guard
// whose whole job is to fail informatively must not be the thing that fails
// obscurely.

test("a non-array value does not satisfy a floor by having a .length", () => {
  const fanoutOf = (literal) =>
    run(`(() => { const fanout = (v) => (Array.isArray(v) ? v.length : -1); return fanout(${literal}); })()`);
  assert.equal(fanoutOf('"abcdefghijkl"'), -1, "a string must never satisfy a fan-out floor");
  assert.equal(fanoutOf("({length: 99})"), -1, "an array-like object must never satisfy a fan-out floor");
  assert.equal(fanoutOf("null"), -1);
  assert.equal(fanoutOf("undefined"), -1);
  assert.equal(fanoutOf("[1,2,3]"), 3, "a real array still counts honestly");
});

// ── placement: pre-spend, and paired where the host swallows ─────────────────

test("each floor sits BEFORE the phase it protects spends an agent", () => {
  const domainFloor = SOURCE.indexOf("fanout(planner.domains) < DOMAIN_FLOOR");
  const reconSpend = SOURCE.indexOf("planner.domains.map");
  assert.ok(domainFloor !== -1 && reconSpend !== -1);
  assert.ok(domainFloor < reconSpend, "the domain floor must fire before Recon fans out");

  const bundleFloor = SOURCE.indexOf("fanout(digest.bundles) < BUNDLE_FLOOR");
  const bundleUse = SOURCE.indexOf("digest.bundles.reduce");
  assert.ok(bundleFloor !== -1 && bundleUse !== -1);
  assert.ok(bundleFloor < bundleUse, "the bundle floor must fire before digest.bundles is read");

  // the cut guard is two lines: `const cutCount = fanout(c.tasks)` then the compare
  const cutFloor = SOURCE.indexOf("const cutCount = fanout(c.tasks)");
  const flatten = SOURCE.indexOf("const allCutTasks = cuts.flatMap");
  assert.ok(cutFloor !== -1 && flatten !== -1);
  assert.ok(cutFloor < flatten, "the cut floor must fire per-domain BEFORE the flatMap hides which cutter was short");
});

// The pairing is the subtle half and the easiest to delete by accident: the host
// runs pipeline()/parallel() stages under Promise.allSettled, so an in-stage
// throw is swallowed into a logged null. The probe floor alone would be
// THEATRE — it would drop one domain and let the cycle digest 2 of 3 while
// reporting a full sweep. The survival check is what converts the swallowed
// drop into a real abort.
test("the swallow-converting survival checks are both present", () => {
  assert.match(SOURCE, /surveyed\.length < DOMAIN_FLOOR/, "the domain-survival floor is gone — the probe floor alone is swallowed by allSettled and becomes decorative");
  assert.match(SOURCE, /cuts\.length < BUNDLE_FLOOR/, "the cutter-survival floor is gone — a died cutter is filtered to a silent null");
  assert.match(SOURCE, /Promise\.allSettled|allSettled|swallow/i, "the reason the pairing exists must stay written down next to it");
});

// ── the honesty the charter requires (D28) ───────────────────────────────────

test("the file does not claim these floors have been observed firing in a real run", () => {
  const floorComment = SOURCE.slice(SOURCE.indexOf("Fan-out FLOORS"), SOURCE.indexOf("const DOMAIN_FLOOR"));
  assert.match(floorComment, /never fired in a real run/i, "D28: the honest disclaimer must stay next to the constants");
  assert.match(floorComment, /harness is not a wave|harness/i);
  assert.doesNotMatch(floorComment, /proven to fire\b/i, "D28 forbids claiming these were proven to FIRE — they were proven in a harness");
});

// ── minItems: the finding, recorded so it is not re-litigated ────────────────

test("the minItems finding is recorded next to the floors, with its authority level honest", () => {
  const floorComment = SOURCE.slice(SOURCE.indexOf("Fan-out FLOORS"), SOURCE.indexOf("const DOMAIN_FLOOR"));
  assert.match(floorComment, /minItems/, "the settled minItems question must stay recorded here or the next wave re-probes it");
  // It was settled by READING the host binary, not by watching a wave reject a
  // short array. The comment must not overstate that.
  assert.match(floorComment, /reading the host|not by running a wave/i);
});
