// record.test.mjs — the BAD-DEPS admission guard, proven by mutation.
//
// admitFact (record.mjs) has six rejection classes; five already carry
// fail-before-plant coverage (level.test.mjs + adjudicate.test.mjs). BAD-DEPS
// was the ONE class with none: neutering the
// `if (deps !== undefined && !Array.isArray(deps))` guard in record.mjs moved
// the full-suite fail count NOT AT ALL. The two "BAD-DEPS" hits elsewhere are
// decoys — ledger.test.mjs exercises admitRecipe's OWN deps guard (never calls
// admitFact), and adjudicate.test.mjs only asserts the source string is absent
// from adjudicate.mjs. This suite closes that hole directly against admitFact.
//
// It is built to genuinely FAIL when the guard is gone: the negative case
// asserts a non-array deps is REJECTED with reason BAD-DEPS, and the positive
// cases assert both an array deps and an omitted (undefined) deps are ADMITTED.
// Revert the array-check guard and the negative case reds.

import { test } from "node:test";
import assert from "node:assert/strict";

import { admitFact } from "../record.mjs";

// A clean, admissible fact with every OTHER guard satisfied, so a rejection
// here can only be the deps guard. No rerun (demotes to L6, never rejects),
// discrete claim (no continuous measurement → no INADMISSIBLE-CONTINUOUS),
// no path:line tokens (no PATHLESS-REF), subject + claim present.
const CLEAN = Object.freeze({
  subject: "grip admitFact deps guard",
  quantity: "one rejection class",
  claim: "a non-array deps is rejected as BAD-DEPS",
  evidence: "read the guard at the admitFact deps branch",
});

function reasons(result) {
  return (result.rejections ?? []).map((r) => r.reason);
}

test("admitFact rejects a string deps with reason BAD-DEPS", () => {
  const result = admitFact({ ...CLEAN, deps: "not-an-array" });
  assert.equal(result.ok, false, "a non-array deps must be rejected");
  assert.ok(
    reasons(result).includes("BAD-DEPS"),
    `expected a BAD-DEPS rejection, got: ${JSON.stringify(reasons(result))}`,
  );
});

test("admitFact rejects a numeric deps with reason BAD-DEPS", () => {
  const result = admitFact({ ...CLEAN, deps: 5 });
  assert.equal(result.ok, false, "a numeric deps must be rejected");
  assert.ok(
    reasons(result).includes("BAD-DEPS"),
    `expected a BAD-DEPS rejection, got: ${JSON.stringify(reasons(result))}`,
  );
});

test("admitFact rejects an object deps with reason BAD-DEPS", () => {
  const result = admitFact({ ...CLEAN, deps: { subject: "x" } });
  assert.equal(result.ok, false, "a non-array object deps must be rejected");
  assert.ok(
    reasons(result).includes("BAD-DEPS"),
    `expected a BAD-DEPS rejection, got: ${JSON.stringify(reasons(result))}`,
  );
});

test("admitFact admits a fact with a valid array deps", () => {
  const result = admitFact({ ...CLEAN, deps: ["some other subject"] });
  assert.equal(result.ok, true, `array deps must be admitted, got: ${JSON.stringify(result.rejections)}`);
  assert.deepEqual(result.fact.deps, ["some other subject"]);
});

test("admitFact admits a fact with an empty array deps", () => {
  const result = admitFact({ ...CLEAN, deps: [] });
  assert.equal(result.ok, true, `empty array deps must be admitted, got: ${JSON.stringify(result.rejections)}`);
  assert.deepEqual(result.fact.deps, []);
});

test("admitFact admits a fact with undefined deps and stores []", () => {
  const { deps, ...noDeps } = { ...CLEAN, deps: undefined };
  const result = admitFact(noDeps);
  assert.equal(result.ok, true, `undefined deps must be admitted, got: ${JSON.stringify(result.rejections)}`);
  assert.deepEqual(result.fact.deps, [], "an omitted deps defaults to an empty array");
});
