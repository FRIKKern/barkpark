// fleet-scenarios.test.mjs — the derivation that replaced the W15 leg's literal.
//
// Run: node --test --test-concurrency=2 fleet-scenarios.test.mjs
//
// Modelled on attention-scenarios.test.mjs, deliberately: the point of the
// module under test is that a fleet-bearing scenario cannot silently escape the
// guard's axis, so a test that asserted "19 classes today" would pin the very
// thing the module exists to stop pinning. The assertions below are about the
// PROPERTY — the set comes from the SHIPPED renderer, it agrees with that
// renderer on every scenario in the corpus, the accounting closes over the
// whole derived population, and every way an axis can silently narrow REFUSES.
//
// The refusal arms are the unit half of the row's MUTATION criterion: each one
// injects the fault (a fleet-bearing scenario nothing covers, a bare skip, a
// skip that matches nothing, a skip that is drivable, an empty corpus, a lost
// control) and asserts fleetAxis() throws rather than returning a narrowed set.

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FLEET_LITERAL_CONTROL,
  FLEET_PINNED_REPS,
  FLEET_SCEN_SKIP,
  countFleetRows,
  drivableAtFleetHash,
  fleetAxis,
  fleetBearingRows,
  fleetRowsHtml,
} from "./fleet-scenarios.mjs";
import { appHooks } from "./attention-scenarios.mjs";
import { SCENARIOS } from "./scenarios.mjs";

const hooks = appHooks();

test("the renderer comes off the SHIPPED app.js, not a local copy", () => {
  assert.equal(typeof hooks.fleetNestedRowsHtml, "function");
  // Prove it is the page's real renderer and not an always-empty stub: an empty
  // list must render no rows, and a fixture the derivation claims must render
  // the number of rows its own data carries.
  assert.equal(countFleetRows(hooks.fleetNestedRowsHtml([]) || ""), 0);
  const live = (SCENARIOS["mixed-fleet"].data && SCENARIOS["mixed-fleet"].data.barkparks) || [];
  assert.ok(live.length > 0, "mixed-fleet carries no barkparks — the fixture moved");
  assert.equal(
    countFleetRows(hooks.fleetNestedRowsHtml(live)),
    live.length,
    "the shipped renderer did not emit one .fleet-row per box — the derivation's unit of counting drifted",
  );
});

test("membership agrees with the shipped renderer on every scenario — both directions", () => {
  const bearing = new Set(fleetBearingRows(SCENARIOS, hooks).map((b) => b.name));
  let inSet = 0, outOfSet = 0;
  for (const name of Object.keys(SCENARIOS)) {
    const rows = countFleetRows(fleetRowsHtml(SCENARIOS[name], hooks));
    if (rows > 0) {
      inSet++;
      assert.ok(bearing.has(name), `${name} renders ${rows} .fleet-row(s) but is NOT in the derived population — a scenario escaped`);
    } else {
      outOfSet++;
      assert.ok(!bearing.has(name), `${name} renders no .fleet-row yet the derivation claims it`);
    }
  }
  assert.ok(inSet > 0 && outOfSet > 0, `a one-sided corpus measures nothing (${inSet} in, ${outOfSet} out)`);
});

test("the derived population strictly contains the literal the leg used to type", () => {
  const bearing = new Set(fleetBearingRows(SCENARIOS, hooks).map((b) => b.name));
  for (const n of FLEET_LITERAL_CONTROL) {
    assert.ok(bearing.has(n), `${n} was in the pre-derivation FLEET_SCENS literal and is not in the derived population`);
  }
  assert.ok(
    bearing.size > FLEET_LITERAL_CONTROL.length,
    `the derivation returned ${bearing.size} scenario(s) against a literal of ${FLEET_LITERAL_CONTROL.length} — it is not widening anything`,
  );
});

test("the accounting closes: every derived scenario is driven or itemised, never both, never neither", () => {
  const axis = fleetAxis(SCENARIOS, hooks);
  const driven = new Set(axis.drive);
  const skipped = new Set(axis.skipped.map((s) => s.scen));
  for (const b of axis.bearing) {
    const d = driven.has(b.name), s = skipped.has(b.name);
    assert.ok(d || s, `${b.name} is neither driven nor itemised — it is measured by nobody`);
    assert.ok(!(d && s), `${b.name} is both driven and itemised — the ledger contradicts the axis`);
  }
  assert.equal(driven.size + skipped.size, axis.bearing.length);
  // No bare skips: every itemised entry carries a twin, a written reason or a row id.
  for (const s of axis.skipped) {
    assert.ok(s.sameAs || s.why || s.row, `${s.scen} is skipped with neither a driven twin, a written reason nor a filed row id`);
  }
  // Every distinct rendered markup is represented by exactly one driven member
  // (or by an all-itemised class), which is what makes 110 scenarios 16 cells
  // wide without the axis losing a question anyone could have asked.
  const drivenSigs = new Set(axis.drive.map((n) => axis.rowsByName.get(n).sig));
  for (const cls of axis.classes) {
    const allItemised = cls.members.every((m) => skipped.has(m));
    assert.ok(
      drivenSigs.has(cls.sig) || allItemised,
      `markup class ${cls.sig} (${cls.members.join(", ")}) is driven by nobody and itemised by nobody`,
    );
  }
});

test("the pinned positive controls are driven, not merely present", () => {
  const axis = fleetAxis(SCENARIOS, hooks);
  for (const n of FLEET_PINNED_REPS) {
    assert.ok(axis.drive.includes(n), `${n} is a pinned representative and is not in the driven axis`);
  }
  // The row names these two by hand as the escapees the literal never drove.
  assert.ok(axis.drive.includes("fleet-support-failed"));
  assert.ok(axis.drive.includes("fleet-archives-stored"));
});

// ── REFUSALS. Each arm injects a fault and asserts a THROW, not a narrower set ──

function withScenario(extra, fn) {
  const clone = Object.assign(Object.create(null), SCENARIOS, extra);
  return fn(clone);
}

function novelBox(tag) {
  const novel = JSON.parse(JSON.stringify(SCENARIOS["mixed-fleet"].data.barkparks[0]));
  novel.id = "zzz-" + tag;
  novel.name = "a box no other fixture renders — " + tag;
  return novel;
}

test("a NEW drivable fleet-bearing scenario is DRIVEN automatically, not skipped", () => {
  // The half the filed row asked for first. Under the old literal an added
  // fixture was simply not walked and the run went green; under the derivation
  // it enters the axis on its own, because its rendered markup matches no
  // driven class. This is COVERAGE, which is why it is not a refusal — and it
  // is asserted here so nobody "fixes" the derivation into refusing instead.
  const axis = withScenario(
    { "zzz-new-drivable-fleet": { data: { barkparks: [novelBox("drivable")] } } },
    (S) => fleetAxis(S, hooks),
  );
  assert.ok(
    axis.drive.includes("zzz-new-drivable-fleet"),
    "an added fleet-bearing scenario did not enter the driven axis — it is walked by nobody, which is the defect this module removes",
  );
});

test("REFUSES a fleet-bearing scenario the leg has NO COVERAGE for", () => {
  // "No coverage" is not "not yet listed" — the derivation lists it. It is a
  // scenario the leg CANNOT drive: one that renders .fleet-row but paints
  // another page, so `#fleet` never routes there and no cell can measure it.
  // Unitemised, that is the exact fault the filed row named, and it refuses.
  assert.throws(
    () => withScenario(
      { "zzz-uncovered-fleet": { pathname: "/new", data: { barkparks: [novelBox("uncovered")] } } },
      (S) => fleetAxis(S, hooks),
    ),
    /NO COVERAGE for: zzz-uncovered-fleet/,
    "a fleet-bearing scenario nothing can drive and nothing itemises did not refuse — the leg goes green having measured nothing about it",
  );
});

test("the same uncovered scenario PASSES once it is itemised with a reason", () => {
  // The other direction of the same door: the refusal is about accounting, not
  // about the fixture, so an itemised entry lets the run proceed.
  FLEET_SCEN_SKIP.push({ scen: "zzz-uncovered-fleet", why: "test fixture: foreign pathname", row: "cch-bl-w15-fleet-leg-scenario-axis-of-two" });
  try {
    const axis = withScenario(
      { "zzz-uncovered-fleet": { pathname: "/new", data: { barkparks: [novelBox("uncovered")] } } },
      (S) => fleetAxis(S, hooks),
    );
    assert.ok(axis.skipped.some((s) => s.scen === "zzz-uncovered-fleet"));
  } finally {
    FLEET_SCEN_SKIP.pop();
  }
});

test("REFUSES a skip entry carrying neither a written reason nor a filed row id", () => {
  // The allowlist direction: an itemised exclusion that itemises nothing.
  const bare = { scen: "theater-ready" };
  const i = FLEET_SCEN_SKIP.findIndex((e) => e.scen === "theater-ready");
  const saved = FLEET_SCEN_SKIP[i];
  FLEET_SCEN_SKIP[i] = bare;
  try {
    assert.throws(() => fleetAxis(SCENARIOS, hooks), /carries neither a written reason nor a filed row id/);
  } finally {
    FLEET_SCEN_SKIP[i] = saved;
  }
  // And the restored ledger is clean again — a test that leaves the module
  // poisoned would make every assertion after it meaningless.
  assert.ok(fleetAxis(SCENARIOS, hooks).drive.length > 0);
});

test("REFUSES a skip entry that matches nothing — the ledger cannot rot into a blanket", () => {
  FLEET_SCEN_SKIP.push({ scen: "no-such-fixture-anywhere", why: "written, and wrong" });
  try {
    assert.throws(() => fleetAxis(SCENARIOS, hooks), /names a scenario that renders NO \.fleet-row today/);
  } finally {
    FLEET_SCEN_SKIP.pop();
  }
});

test("REFUSES a skip entry for a scenario that IS drivable at #fleet", () => {
  FLEET_SCEN_SKIP.push({ scen: "mixed-fleet", why: "would be slow" });
  try {
    assert.throws(() => fleetAxis(SCENARIOS, hooks), /is DRIVABLE at #fleet/);
  } finally {
    FLEET_SCEN_SKIP.pop();
  }
});

test("REFUSES an empty derivation rather than sweeping zero cells cleanly", () => {
  assert.throws(() => fleetAxis({}, hooks), /derived \.fleet-row set is EMPTY/);
});

test("REFUSES a lost positive control", () => {
  const thinned = Object.create(null);
  for (const k of Object.keys(SCENARIOS)) if (k !== "fleet-support-failed") thinned[k] = SCENARIOS[k];
  assert.throws(() => fleetAxis(thinned, hooks), /lost its positive control — fleet-support-failed/);
});

test("REFUSES when the shipped renderer stops exporting its hook", () => {
  assert.throws(
    () => fleetBearingRows(SCENARIOS, { fleetNestedRowsHtml: null }),
    /no longer exports fleetNestedRowsHtml/,
  );
});

test("the drivability predicate is a rule over pathname, not a list of names", () => {
  assert.equal(drivableAtFleetHash({}), true);
  assert.equal(drivableAtFleetHash({ pathname: "/" }), true);
  assert.equal(drivableAtFleetHash({ pathname: "/new" }), false);
  assert.equal(drivableAtFleetHash({ pathname: "/activate" }), false);
  // Every itemised non-twin exclusion must actually satisfy the reason class.
  for (const e of FLEET_SCEN_SKIP) {
    assert.equal(
      drivableAtFleetHash(SCENARIOS[e.scen]),
      false,
      `${e.scen} is itemised out of the axis but IS drivable at #fleet — the ledger's only accepted reason does not apply`,
    );
  }
});
