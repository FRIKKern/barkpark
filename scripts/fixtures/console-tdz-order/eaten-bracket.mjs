// FIXTURE — console-tdz-order-check.mjs --selftest. NOT a test file; nothing
// runs it. `node --check` PARSES it. It exists because a final depth of 0 is
// NOT proof that the lexer read the file.
//
// `i++ / g(1 / 2)` is division twice over, but `+` is a legal regex-start
// position, so the lexer takes `/ g(1 /` for a regex literal and blanks it —
// eating the `(`. The `)` that follows then closes a bracket that was never
// opened. `depthMap` clamps at zero (`Math.max(0, d - 1)`), so the damage is
// invisible to a final-depth check: this file ends at depth 0 with one bracket
// silently swallowed. Only the UNDERFLOW counter sees it.
//
// Expected verdict: exit 3, a REFUSAL — even though the drift happens to cancel
// here and the crossing below would have been found anyway. A guard that got the
// right answer from a depth map it cannot vouch for got it by luck.

import { test } from "node:test";
import assert from "node:assert/strict";

let i = 1;
const g = (n) => n;
const ratio = i++ / g(1 / 2);

test("early test with a live crossing", () => {
  assert.ok(LATE_UNSEEN, String(ratio));
});

const os = await import("node:os");

const LATE_UNSEEN = os.EOL;
