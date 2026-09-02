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

test("CONTROL (mutation direction): the FULLY un-bounded fold — `screen: null`, no now — folds both forgeries CLEAN", () => {
  // This is the shape both callers had before the injection, and it is now
  // reachable ONLY by asking for it: `screen: null` is the explicit opt-out.
  // It proves the rows are valid apart from the two bounds — so reverting the
  // injection would let them fold clean again, flipping the two product-path
  // assertions above to red.
  const dir = seedFixture();
  const unbounded = foldLedger(dir, { screen: null });
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
  assert.equal(unbounded.arming.screen, "none", "an unscreened count must SAY it is unscreened");
  assert.equal(unbounded.arming.now, null);
});

// ── the read-path split this file's CONTROL used to demonstrate ──────────────
//
// The control above was, until the arming slice, written as plain
// `foldLedger(dir)` — and it passed, because a library fold defaulted to NO
// screen while the CLI fold of the same bytes injected one. That is the whole
// defect: two reading paths over one store, five subjects apart on the
// committed directory, both exiting normally. `screen` now defaults ON; `now`
// still does not (D19 — this module owns no clock). These two tests pin both
// halves so neither can silently re-open.

test("the library default IS the CLI's screen: an un-bounded fold catches REFUSED-COMMAND and says so", () => {
  const dir = seedFixture();
  const byDefault = foldLedger(dir);
  const reasons = reasonsOf(byDefault.unreadable);
  assert.ok(reasons.has("REFUSED-COMMAND"), `the default fold must catch the refused row, got ${[...reasons].join(", ") || "none"}`);
  assert.equal(byDefault.arming.screen, "screen.mjs");
  // …and the clock is still the caller's business, so the future row is NOT
  // caught by default. A count taken here and a count taken under a `now` can
  // legitimately differ — which is precisely why `arming.now` is reported.
  assert.equal(reasons.has("FUTURE-OBSERVED-AT"), false, "D19: the fold reads no clock, so an un-injected `now` bounds nothing");
  assert.equal(byDefault.arming.now, null);
});

test("a malformed screen bound is armed as `invalid`, never as `none` — a broken read is not an unscreened population", () => {
  const dir = seedFixture();
  const broken = foldLedger(dir, { screen: 42 });
  assert.equal(broken.arming.screen, "invalid");
  assert.equal(broken.stats.rows, 0, "admitRecipe rejects every row BAD-OPTION under a non-function screen");
  assert.ok(reasonsOf(broken.unreadable).has("BAD-OPTION"));
});
