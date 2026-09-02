// FIXTURE — console-tdz-order-check.mjs --selftest. NOT a test file; nothing
// runs it. It carries a KNOWN answer for the green-when-it-should-red holes the
// wave-62 first-match audit measured by MUTATING the REAL
// cloud/priv/static/__app.test.mjs (task
// cchi-w62-bl-the-tdz-guard-was-never-audited-for-a-first-match-hole).
//
// Expected verdict: exactly FOUR crossings —
//   "test between the boundaries" → SECOND_LATE   (the SECOND depth-0 await)
//   "sibling shadow"              → SIBLING_LATE  (scope-bounded shadowing)
//   "block-registered"            → BLOCK_LATE    (a test inside a `for` block)
//   "split declaration"           → SPLIT_LATE    (multi-line binding pattern —
//                                   closed by #14846, pinned here so a revert
//                                   of that fix is caught by this fixture too)
// and NOT the two DECOYS: "真 shadow"/TRUE_SHADOWED (a genuine shadow, which
// must stay silent) and "function-body-registered"/NEVER_EARLY (registered from
// a function body nothing calls at module evaluation).

import { test } from "node:test";
import assert from "node:assert/strict";

// HOLE 2 — the binding is declared BELOW, in a declaration whose name sits on
// a different line from its keyword. A line-bounded pattern scan binds nothing
// here and the name never reaches the late set.
test("split declaration", () => {
  assert.ok(SPLIT_LATE);
});

// HOLE 3 — a same-named local in a SIBLING scope must not erase the
// module-level read that follows it.
test("sibling shadow", () => {
  { const SIBLING_LATE = 0; assert.equal(SIBLING_LATE, 0); }
  assert.ok(SIBLING_LATE);
});

// DECOY — a genuine shadow. The local covers the only read, so there is no
// crossing and reporting one would be a false positive.
test("真 shadow", () => {
  const TRUE_SHADOWED = 2;
  assert.equal(TRUE_SHADOWED, 2);
});

// HOLE 4 — this `test(` sits at depth 2, but the `for` block RUNS during module
// evaluation, so the registration really is early.
for (const variant of ["only"]) {
  test("block-registered", () => {
    assert.ok(BLOCK_LATE && variant);
  });
}

// DECOY — registered from a function body. Nothing calls `registerLater` during
// module evaluation, so nothing is queued early and counting it would be a
// false positive.
function registerLater() {
  test("function-body-registered", () => {
    assert.ok(NEVER_EARLY);
  });
}

// ── suspension point 1: the first depth-0 await ─────────────────────────────
const os = await import("node:os");

const {
  SPLIT_LATE,
} = { SPLIT_LATE: typeof os.EOL === "string" };
const SIBLING_LATE = 1;
const TRUE_SHADOWED = 3;
const BLOCK_LATE = 1;
const NEVER_EARLY = 1;

// HOLE 1 — registered AFTER the first await, so a first-match boundary drops it
// entirely. It is still on the queue when the SECOND await below suspends the
// module, and SECOND_LATE is dead until that resumes.
test("test between the boundaries", () => {
  assert.ok(SECOND_LATE);
});

// ── suspension point 2: the module suspends here too ────────────────────────
const p = await import("node:path");

const SECOND_LATE = typeof p.sep === "string";

test("a test below every await may read every binding", () => {
  assert.ok(SPLIT_LATE && SIBLING_LATE && BLOCK_LATE && SECOND_LATE);
  registerLater();
});
