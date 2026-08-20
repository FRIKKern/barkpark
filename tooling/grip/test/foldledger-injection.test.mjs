// foldledger-injection.test.mjs — the product READ paths admit against the same
// two bounds the write path does (D66 read-path residual).
//
//   node --test tooling/grip/test/foldledger-injection.test.mjs
//
// foldLedger already COMPOSES admitRecipe on read, but that only fires the two
// bounded rejections when the caller injects `{ now, screen }`. Two product read
// callers folded with NO bounds:
//
//   census.mjs  loadLedgerRecipes → foldLedger(dir)
//   backfill.mjs auditLedger      → foldLedger(dir)
//
// so a FUTURE-OBSERVED-AT row (observed_at in 2099 — composed, not observed) and
// a REFUSED-COMMAND rerun (an outage-capable command screenCommand refuses)
// folded CLEAN through the product read paths, while writeLedgerRun refuses both
// at the write seam. This test folds a fixture carrying exactly those two rows
// (plus one clean row) through both product read paths and asserts both land in
// unreadable[].
//
// MUTATION PROOF, made explicit: the CONTROL test below folds the SAME fixture
// through the un-bounded library call `foldLedger(dir)` — the shape the two
// callers had before this slice — and shows both rows fold CLEAN there. So if
// the injection is reverted, the two product-path assertions go green→red: the
// forgeries would fold clean again. The rows are otherwise valid (the control
// proves it), so nothing but the missing bounds could keep them out.
//
// OFFLINE: every fold reads a fresh mkdtemp directory. Nothing here reads or
// writes the committed tooling/grip/ledger/, and this test does not touch the
// slow live census.test.mjs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { foldLedger } from "../ledger.mjs";
import { loadLedgerRecipes } from "../census.mjs";
import { auditLedger } from "../backfill.mjs";

// A run file readLedgerRuns folds under scope "all": a plain object with a
// recipes[] array. Each row is a valid recipe EXCEPT for the one bound it is
// built to trip — so admitRecipe rejects it on that bound and nothing else.
const CLEAN_ROW = {
  subject: "grip/census.mjs",
  quantity: "line count",
  rerun: "wc -l tooling/grip/census.mjs",
  observed_at: "2026-07-20T00:00:00Z",
};

// observed_at in 2099 — later than any real `date -u`, so FUTURE-OBSERVED-AT
// fires the moment a `now` is injected, and cannot fire without one.
const FUTURE_ROW = {
  subject: "grip/future",
  quantity: "line count",
  rerun: "wc -l tooling/grip/census.mjs",
  observed_at: "2099-12-31T23:59:59Z",
};

// An outage-capable command screenCommand refuses — REFUSED-COMMAND fires the
// moment a `screen` is injected, and cannot fire without one.
const REFUSED_ROW = {
  subject: "grip/refused",
  quantity: "unit state",
  rerun: "systemctl stop bp-crux-parent",
  observed_at: "2026-07-20T00:00:00Z",
};

// An INPUT-FREE rejection: a stored `value` is refused with or without bounds —
// admitRecipe checks it before it ever looks at `now`/`screen`. It is here to
// prove the injection did not disturb the rejections that never needed a bound.
const VALUE_ROW = {
  subject: "grip/valued",
  quantity: "line count",
  rerun: "wc -l tooling/grip/census.mjs",
  observed_at: "2026-07-20T00:00:00Z",
  value: 42,
};

function seedFixture() {
  const dir = mkdtempSync(join(tmpdir(), "grip-foldinject-"));
  writeFileSync(
    join(dir, "grip-20260720T000000Z-fixture.json"),
    `${JSON.stringify({ run_id: "grip-20260720T000000Z-fixture", recipes: [CLEAN_ROW, FUTURE_ROW, REFUSED_ROW, VALUE_ROW] }, null, 2)}\n`,
  );
  return dir;
}

const reasonsOf = (unreadable) => new Set(unreadable.map((u) => u.reason));

test("census loadLedgerRecipes injects now+screen: future & refused rows land in unreadable[]", () => {
  const dir = seedFixture();
  const loaded = loadLedgerRecipes(dir);
  const reasons = reasonsOf(loaded.unreadable);
  assert.ok(reasons.has("FUTURE-OBSERVED-AT"), `expected FUTURE-OBSERVED-AT in unreadable[], got ${[...reasons].join(", ") || "none"}`);
  assert.ok(reasons.has("REFUSED-COMMAND"), `expected REFUSED-COMMAND in unreadable[], got ${[...reasons].join(", ") || "none"}`);
  // NO REGRESSION: the input-free rejection (a stored value) still fires — the
  // injection added the two bounded classes without disturbing the rest.
  assert.ok(reasons.has("VALUE-STORED"), `expected VALUE-STORED to still reject, got ${[...reasons].join(", ") || "none"}`);
  // The clean row still folds — exactly one recipe survives the three rejections.
  assert.equal(loaded.stats.rows, 1);
  assert.deepEqual(loaded.commands, ["wc -l tooling/grip/census.mjs"]);
});

test("backfill auditLedger injects now+screen: both forged rows counted unreadable, one clean row folds", () => {
  const dir = seedFixture();
  const audit = auditLedger(dir);
  // FUTURE-OBSERVED-AT + REFUSED-COMMAND + VALUE-STORED = three unreadable rows;
  // only the clean row folds.
  assert.equal(audit.unreadable, 3);
  assert.equal(audit.rows, 1);
});

test("CONTROL (mutation direction): un-bounded foldLedger(dir) folds both forgeries CLEAN", () => {
  // This is the shape both callers had before the injection. It proves the rows
  // are valid apart from the two bounds — so reverting the injection would let
  // them fold clean again, flipping the two product-path assertions above to red.
  const dir = seedFixture();
  const unbounded = foldLedger(dir);
  const reasons = reasonsOf(unbounded.unreadable);
  // The two BOUNDED forgeries fold clean without now/screen — this is the exact
  // mutation the product paths guard against; reverting the injection reds the
  // two product-path tests above.
  assert.equal(reasons.has("FUTURE-OBSERVED-AT"), false, "unbounded fold must NOT catch the future row");
  assert.equal(reasons.has("REFUSED-COMMAND"), false, "unbounded fold must NOT catch the refused row");
  // The input-free VALUE-STORED rejection fires either way, so the clean row and
  // the two now-foldable forgeries make three folded rows, one still unreadable.
  assert.deepEqual([...reasons], ["VALUE-STORED"]);
  assert.equal(unbounded.stats.rows, 3);
});
