// attention-scenarios.test.mjs — the derivation that replaced GR109's literal.
//
// Run: node --test --test-concurrency=2 attention-scenarios.test.mjs
//
// The point of the module under test is that a scenario cannot silently escape
// the guard's axis. A test that only asserted "19 scenarios today" would pin
// the very thing the module exists to stop pinning, so the assertions below are
// about the PROPERTY: the set comes from the shipped classifier, it agrees with
// the shipped classifier on every scenario in the corpus, it strictly contains
// the literal it replaced, and it REFUSES rather than returning an empty axis.

import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  ATT_LITERAL_CONTROL,
  appHooks,
  attentionScenarioRows,
  attentionScenarios,
} from "./attention-scenarios.mjs";
import { SCENARIOS } from "./scenarios.mjs";

const hooks = appHooks();

test("the classifier comes off the SHIPPED app.js, not a local copy", () => {
  assert.equal(typeof hooks.filterFleet, "function");
  // The arrays come back from the sandbox's OWN realm, so deepStrictEqual
  // against a host [] fails on prototype identity alone — length is the honest
  // assertion here. Both the empty and the nullish arm must survive, because
  // attentionScenarioRows() hands it `[]` for any scenario without barkparks.
  assert.equal(hooks.filterFleet([], "attention").length, 0);
  assert.equal(hooks.filterFleet(null, "attention").length, 0);
  // Prove it is the page's real classifier and not an always-empty stub: a
  // scenario the derivation claims, fed in whole, must classify non-empty, and
  // a bucket that is not "attention" must not return the same set.
  const live = (SCENARIOS["mixed-fleet"].data && SCENARIOS["mixed-fleet"].data.barkparks) || [];
  assert.ok(live.length > 0, "mixed-fleet carries no barkparks — the fixture moved");
  const att = hooks.filterFleet(live, "attention").length;
  const all = hooks.filterFleet(live, null).length;
  assert.ok(att > 0, "mixed-fleet classified zero attention boxes — the classifier is an always-empty stub");
  assert.ok(
    att < all,
    `filterFleet returned all ${all} of mixed-fleet's boxes for the attention bucket — it is not bucketing, it is passing the list through`,
  );
});

test("every scenario's membership agrees with the shipped classifier — both directions", () => {
  const derived = new Set(attentionScenarios(SCENARIOS, hooks));
  let inSet = 0, outOfSet = 0;
  for (const name of Object.keys(SCENARIOS)) {
    const sc = SCENARIOS[name];
    const list = (sc.data && sc.data.barkparks) || [];
    const n = sc.authed === false ? 0 : hooks.filterFleet(list, "attention").slice(0, 6).length;
    if (n > 0) {
      inSet++;
      assert.ok(derived.has(name), `${name} yields ${n} attention row(s) but is NOT in the derived axis — a scenario escaped the guard`);
    } else {
      outOfSet++;
      assert.ok(!derived.has(name), `${name} yields zero attention rows but IS in the derived axis — the sweep would measure zero cells there and red`);
    }
  }
  // Non-vacuity: both arms must have run, or this test proves nothing.
  assert.ok(inSet > 0, "no scenario rendered an attention row — the positive arm never ran");
  assert.ok(outOfSet > 0, "every scenario rendered an attention row — the negative arm never ran");
});

test("the derived axis STRICTLY contains the literal it replaced", () => {
  const names = attentionScenarios(SCENARIOS, hooks);
  for (const control of ATT_LITERAL_CONTROL) {
    assert.ok(names.includes(control), `${control} — the old GR109 literal — fell out of the derived axis`);
  }
  assert.ok(
    names.length > ATT_LITERAL_CONTROL.length,
    `the derivation found ${names.length} scenario(s), not more than the ${ATT_LITERAL_CONTROL.length} the literal already carried — ` +
    `the widening bought nothing, so either the corpus shrank or the derivation is reading the wrong field`,
  );
  // The two named escapees from the filing's evidence pass, asserted by name so
  // a regression that re-narrows the axis to the old three cannot pass here.
  assert.ok(names.includes("fleet-v4"), "fleet-v4 (4 attention rows) is back outside the axis");
  assert.ok(names.includes("fleet-usage"), "fleet-usage (2 attention rows) is back outside the axis");
});

test("an unauthed scenario is excluded even when its data carries attention boxes", () => {
  const donor = attentionScenarios(SCENARIOS, hooks)[0];
  const fixture = {
    "authed-donor": SCENARIOS[donor],
    "signed-out": { ...SCENARIOS[donor], authed: false },
  };
  const names = attentionScenarioRows(fixture, hooks).map((r) => r.name);
  assert.deepEqual(names, ["authed-donor"]);
});

test("an EMPTY derivation is refused, never returned as a clean zero-length axis", () => {
  assert.throws(
    () => attentionScenarios({ quiet: { authed: true, data: { barkparks: [] } } }, hooks),
    /derived \.attention-row set is EMPTY/,
  );
});

test("a derivation that LOSES the positive control is refused", () => {
  // A corpus where something renders attention rows, but none of the three
  // control names do — the shape a classifier regression would produce.
  const donor = SCENARIOS["fleet-v4"];
  assert.throws(
    () => attentionScenarios({ "fleet-v4": donor }, hooks),
    /lost its positive control/,
  );
});

test("a hook bag without filterFleet is refused loudly, not defaulted", () => {
  // A stand-in artifact that calls __bpTestHook but withholds filterFleet —
  // the shape a future app.js edit that drops the export would produce. The
  // module must refuse it by name rather than fall back to a local classifier.
  const stub = path.join(os.tmpdir(), `att-scens-stub-${process.pid}-${Date.now()}.js`);
  fs.writeFileSync(stub, "globalThis.__bpTestHook({ fleetSummary: function () { return {}; } });\n");
  try {
    assert.throws(() => appHooks(new URL(`file://${stub}`)), /no longer exports filterFleet/);
  } finally {
    fs.unlinkSync(stub);
  }
});
