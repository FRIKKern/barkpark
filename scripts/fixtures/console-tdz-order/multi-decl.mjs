// FIXTURE — console-tdz-order-check.mjs --selftest. NOT a test file; nothing
// runs it. It pins the FIRST-MATCH-WINS hole audited in wave 62: a declaration
// binds a SET of names, and a reader that takes ONE value per declaration loses
// the rest — silently, toward green.
//
// Expected verdict: exactly two crossings —
//   "reads the second declarator"  → LATE_SECOND (the second entry of a
//                                    declaration LIST; a reader that stops at
//                                    the first `=` sees only LATE_FIRST)
//   "reads a multi-line pattern"   → LATE_IN_PATTERN, via earlyHelper (a reader
//                                    that stops at the first NEWLINE sees the
//                                    pattern `{`, extracts no names at all, and
//                                    drops the whole declaration)
// and NOT "shadows a late name", which declares its own LATE_SECOND.

import { test } from "node:test";
import assert from "node:assert/strict";

// An EARLY top-level helper, so the multi-line-pattern crossing is reached only
// transitively — it must survive BOTH the pattern fix and the transitive walk.
function earlyHelper() {
  return LATE_IN_PATTERN;
}

test("reads the second declarator", () => {
  assert.ok(LATE_SECOND);
});

test("reads a multi-line pattern", () => {
  assert.ok(earlyHelper());
});

test("shadows a late name", () => {
  const LATE_SECOND = 1;
  assert.equal(LATE_SECOND, 1);
});

// ── the module boundary: the first depth-0 await ────────────────────────────
const os = await import("node:os");

// A DECLARATION LIST. The bound set is {LATE_FIRST, LATE_SECOND}.
const LATE_FIRST = os.EOL, LATE_SECOND = 2;

// A MULTI-LINE BINDING PATTERN. The bound set is {LATE_IN_PATTERN,
// LATE_DEFAULTED}. `LATE_DEFAULT_SOURCE` is a default VALUE, not a binding —
// counting it would invent a crossing, so the pattern reader must drop it.
const LATE_DEFAULT_SOURCE = 3;
const {
  LATE_IN_PATTERN,
  LATE_DEFAULTED = LATE_DEFAULT_SOURCE,
} = { LATE_IN_PATTERN: 1 };

test("late tests may read all of them", () => {
  assert.ok(LATE_FIRST && LATE_SECOND && LATE_IN_PATTERN && LATE_DEFAULTED);
});
