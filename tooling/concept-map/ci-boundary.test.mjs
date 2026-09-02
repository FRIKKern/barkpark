// ci-boundary.test.mjs — the predicate's own selftest.
//
// Drives compare() on SYNTHETIC baselines, so it needs no symbol graph, no mix,
// and no network — the same dependency-free shape as the rest of concept-map.
//
// WHAT IT IS ACTUALLY DEFENDING. The gate this file tests spent months keyed on
// concept IDENTITY, and a concept identity is a directory name. Every new feature
// folder therefore minted identities the baseline had never seen, and the gate
// read all of them as "new architectural debt". On main it reported 108 identity
// regressions and meant 8. The rule below — compare only the subgraph both sides
// can speak about, report growth apart — is the fix, and these cases pin it in
// BOTH directions: growth must not red, and a real edge between two long-known
// concepts must still red, by name.
//
// The both-directions half is the load-bearing half. A predicate that reds on
// nothing would pass every "growth is not a regression" case in this file, which
// is why every such case is paired with an assertion that the gate DOES still
// fire on the mutation next to it.

import { test } from "node:test";
import assert from "node:assert/strict";

import { compare, baselineConcepts } from "./ci-boundary.mjs";

// A baseline that knows exactly four concepts: kernel `core`, features `alpha`,
// `beta`, `gamma`. It carries one sideways edge and one wrong-direction edge.
const BASE = {
  kernel: ["core"],
  counts: { sideways: 1, wrongDirection: 1, featureCycles: 0 },
  edges: { sideways: ["alpha>beta"], wrongDirection: ["core>alpha"] },
  featureCyclePairs: [],
};

const metrics = (sideways = [], wrongDirection = [], featureCyclePairs = []) => ({
  counts: {
    sideways: sideways.length,
    wrongDirection: wrongDirection.length,
    featureCycles: featureCyclePairs.length,
  },
  edges: { sideways, wrongDirection },
  featureCyclePairs,
});

const edgesNamed = (res) =>
  res.regressions.filter((r) => r.kind === "new-edge").map((r) => r.edge);
const cyclesNamed = (res) =>
  res.regressions.filter((r) => r.kind === "new-cycle").map((r) => r.pair);

test("baselineConcepts reads the roster out of the baseline's own text", () => {
  const known = baselineConcepts(BASE);
  assert.deepEqual([...known].sort(), ["alpha", "beta", "core"]);
  // `gamma` is NOT known: the baseline names it nowhere. That is the documented
  // blind spot — a concept that existed but carried no debt is indistinguishable
  // from one that did not exist — and it is asserted here so the trade-off is a
  // fact in the test suite rather than a claim in a comment.
  assert.ok(!known.has("gamma"));
});

test("the baseline's own graph, replayed unchanged, is not a regression", () => {
  const res = compare(metrics(["alpha>beta"], ["core>alpha"]), BASE);
  assert.equal(res.regressed, false, "an unchanged graph must be green");
  assert.deepEqual(res.comparableCounts, { sideways: 1, wrongDirection: 1, featureCycles: 0 });
});

test("GROWTH: a new concept's edges are informational, never a regression", () => {
  // `delta` did not exist at baseline. Everything it touches is growth.
  const res = compare(
    metrics(["alpha>beta", "delta>alpha", "delta>beta", "alpha>delta"], ["core>alpha"]),
    BASE
  );
  assert.equal(res.regressed, false, "growth in a new concept must not red the gate");
  assert.deepEqual(res.growth.newConcepts, ["delta"]);
  assert.equal(res.growth.counts.sideways, 3);
  assert.deepEqual(res.growth.sideways, ["alpha>delta", "delta>alpha", "delta>beta"]);
  // and the comparable slice is untouched by the growth
  assert.equal(res.comparableCounts.sideways, 1);
});

test("REAL: a new edge between two BASELINE-KNOWN concepts still reds, by name", () => {
  // `beta>alpha` is new; both ends were known in June. This is the mutation that
  // proves the growth partition did not blind the gate.
  const res = compare(metrics(["alpha>beta", "beta>alpha"], ["core>alpha"]), BASE);
  assert.equal(res.regressed, true);
  assert.deepEqual(edgesNamed(res), ["beta>alpha"]);
});

test("REAL survives a flood of growth around it", () => {
  // The failure mode that mattered: one real edge drowned in 100 growth rows.
  // Here the real edge must be the ONLY thing named.
  const noise = ["delta>alpha", "delta>beta", "epsilon>delta", "alpha>epsilon", "beta>delta"];
  const res = compare(metrics(["alpha>beta", "beta>alpha", ...noise], ["core>alpha"]), BASE);
  assert.equal(res.regressed, true);
  assert.deepEqual(edgesNamed(res), ["beta>alpha"], "growth must not appear in the red list");
  assert.equal(res.growth.counts.sideways, 5);
});

test("a wrong-direction edge into a known concept reds; into a new one does not", () => {
  const red = compare(metrics(["alpha>beta"], ["core>alpha", "core>beta"]), BASE);
  assert.equal(red.regressed, true);
  assert.deepEqual(edgesNamed(red), ["core>beta"]);

  const informational = compare(metrics(["alpha>beta"], ["core>alpha", "core>delta"]), BASE);
  assert.equal(informational.regressed, false);
  assert.deepEqual(informational.growth.wrongDirection, ["core>delta"]);
});

test("a baseline KERNEL reaching a new concept is bucketed NOTABLE, not red", () => {
  const res = compare(metrics(["alpha>beta"], ["core>alpha", "core>delta"]), BASE);
  assert.equal(res.regressed, false);
  assert.deepEqual(res.growth.kernelReach, ["core>delta"]);
  // A feature reaching a new concept is ordinary growth, NOT kernelReach.
  const plain = compare(metrics(["alpha>beta", "alpha>delta"], ["core>alpha"]), BASE);
  assert.deepEqual(plain.growth.kernelReach, []);
});

test("COUNTS are compared on the known subgraph, not on the whole graph", () => {
  // 6 sideways edges in total, but only the 1 baseline edge is comparable. The
  // old predicate reported "count rose from 1 to 6"; the fixed one reports flat.
  const res = compare(
    metrics(["alpha>beta", "delta>alpha", "delta>beta", "epsilon>alpha", "epsilon>beta", "delta>epsilon"], [
      "core>alpha",
    ]),
    BASE
  );
  assert.equal(res.regressed, false);
  assert.equal(res.comparableCounts.sideways, 1);
  assert.equal(res.growth.counts.sideways, 5);
});

test("a count rise WITHIN the known subgraph still reds", () => {
  // Same shape as above but with one extra KNOWN-to-KNOWN edge. The count row
  // must come back — otherwise the previous case is passing on blindness.
  const res = compare(
    metrics(["alpha>beta", "beta>alpha", "delta>alpha", "delta>beta"], ["core>alpha"]),
    BASE
  );
  const counts = res.regressions.filter((r) => r.kind === "count");
  assert.equal(counts.length, 1);
  assert.equal(counts[0].dimension, "sideways");
  assert.equal(counts[0].baseline, 1);
  assert.equal(counts[0].current, 2);
});

test("paying debt down is silently fine, and never negative", () => {
  const res = compare(metrics([], []), BASE);
  assert.equal(res.regressed, false);
  assert.deepEqual(res.comparableCounts, { sideways: 0, wrongDirection: 0, featureCycles: 0 });
});

test("cycles follow the same partition, in both directions", () => {
  const growthOnly = compare(metrics(["delta>alpha", "alpha>delta"], [], ["alpha|delta"]), BASE);
  assert.equal(growthOnly.regressed, false);
  assert.deepEqual(growthOnly.growth.featureCycles, ["alpha|delta"]);

  const real = compare(
    metrics(["alpha>beta", "beta>alpha"], ["core>alpha"], ["alpha|beta"]),
    BASE
  );
  assert.equal(real.regressed, true);
  assert.deepEqual(cyclesNamed(real), ["alpha|beta"]);
});

test("a reshuffle inside the known subgraph is still a regression", () => {
  // Flat count, one known edge swapped for another known-to-known edge. The
  // identity check is what catches this, and the growth partition must not have
  // cost us it.
  const res = compare(metrics(["beta>alpha"], ["core>alpha"]), BASE);
  assert.equal(res.regressed, true);
  assert.deepEqual(edgesNamed(res), ["beta>alpha"]);
  assert.equal(
    res.regressions.filter((r) => r.kind === "count").length,
    0,
    "the count is flat; only the identity row should fire"
  );
});

test("importing this module does not run the gate", () => {
  // The CLI guard in ci-boundary.mjs. Without it, this whole file would have
  // rebuilt the symbol graph and run the real gate as an import side effect —
  // and the tests would have been measuring the repo, not the predicate.
  assert.equal(typeof compare, "function");
  assert.equal(typeof baselineConcepts, "function");
});
