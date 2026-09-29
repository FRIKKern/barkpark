// byte-comparability.test.mjs — the register is a claim about scenarios that
// EXIST, and it must be able to say both yes and no.
//
// The register (byte-comparability.mjs) is a DERIVED snapshot: a two-run serial
// control, not a typed list. Nothing here re-derives it — that costs a browser
// and eleven minutes, and the derivation command is recorded beside the data.
// What this suite guards is the way a snapshot rots: a renamed or deleted
// scenario leaves a row naming nothing, and a row naming nothing silently
// shrinks the exclusion set of any future PNG-diff gate — the gate then reds on
// the clock and the next reader calls the gate flaky instead of the list stale.

import test from "node:test";
import assert from "node:assert/strict";

import { SCENARIOS } from "./scenarios.mjs";
import {
  CLOCK_UNSTABLE,
  DERIVATION,
  isByteComparable,
  byteComparableScenarios,
} from "./byte-comparability.mjs";

test("every scenario in the register still exists in scenarios.mjs", () => {
  const ghosts = CLOCK_UNSTABLE.filter((n) => !(n in SCENARIOS));
  assert.deepEqual(ghosts, [], "register rows naming no scenario: " + ghosts.join(", "));
});

test("the register is sorted and free of duplicates (a duplicate hides a missing row)", () => {
  const sorted = [...CLOCK_UNSTABLE].sort();
  assert.deepEqual(CLOCK_UNSTABLE, sorted, "the register is not in sorted order");
  assert.equal(new Set(CLOCK_UNSTABLE).size, CLOCK_UNSTABLE.length, "duplicate row in the register");
});

test("the register is neither empty nor everything — both would make it useless", () => {
  const total = Object.keys(SCENARIOS).length;
  assert.ok(CLOCK_UNSTABLE.length > 0, "an empty register excludes nothing and a PNG gate would red on the clock");
  assert.ok(
    CLOCK_UNSTABLE.length < total,
    "a register naming every scenario excludes everything and a PNG gate would assert nothing",
  );
});

test("isByteComparable can say NO", () => {
  assert.ok(CLOCK_UNSTABLE.length > 0);
  assert.equal(isByteComparable(CLOCK_UNSTABLE[0]), false);
});

test("isByteComparable can say YES, and identity-iris is one of the stable ones", () => {
  // Load-bearing beyond polarity: identity-iris is the scenario this wave made
  // byte-meaningful again (task-a0258bec59b256d7). If it ever lands in the
  // unstable register, the GR12 shot has stopped being comparable and the
  // proof built on its hash is void.
  assert.equal(isByteComparable("identity-iris"), true);
  assert.equal(isByteComparable("shell-root"), true);
});

test("an unknown name is reported comparable, and that is the deliberate polarity", () => {
  // A new scenario is comparable until a control says otherwise. The opposite
  // default would silently exclude every scenario added after this register was
  // derived — a gate that quietly stops looking as the suite grows.
  assert.equal(isByteComparable("no-such-scenario-zzz"), true);
});

test("byteComparableScenarios() and the register partition the suite exactly", () => {
  const stable = byteComparableScenarios();
  const all = Object.keys(SCENARIOS).sort();
  assert.deepEqual([...stable, ...CLOCK_UNSTABLE].sort(), all);
  assert.equal(stable.filter((n) => CLOCK_UNSTABLE.includes(n)).length, 0);
});

test("the derivation is recorded well enough to be repeated", () => {
  assert.match(DERIVATION.date, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(DERIVATION.base, /^[0-9a-f]{40}$/);
  assert.ok(DERIVATION.command.includes("shoot.sh"), "the command must name the instrument that produced it");
  assert.ok(DERIVATION.cells > 0);
  assert.equal(DERIVATION.runs, 2, "one run cannot establish reproducibility");
});
