// FIXTURE — console-tdz-order-check.mjs --selftest. NOT a test file; nothing
// runs it. `node --check` PARSES it: this is valid JavaScript that the guard's
// HEURISTIC LEXER mis-reads.
//
// `throw` is a value position — `throw /re/.source` is legal — but `throw` is
// absent from the keyword set `regexCanStart` consults, so the lexer reads the
// `/` as division and leaves the regex body live as code. The `\(` inside it is
// then counted as a real opener that nothing ever closes: the depth map drifts
// +1 from that line on, the depth-0 `await` below is never found, and the guard
// used to answer "crossings: 0 (structurally impossible without a top-level
// await)" with exit 0 — about a file it had just failed to parse, and one that
// carries a LIVE crossing (the early test below reads LATE_UNSEEN).
//
// Expected verdict: exit 3, a REFUSAL. Not a crossing count, and above all not
// a green. The fixture pins the RESPONSE TO A LOST BOUNDARY, not this one bug:
// teaching `regexCanStart` about `throw` would make this file measurable again,
// but the next unlexable shape would be back to certifying itself. What must
// hold forever is that unbalanced brackets produce a refusal.

import { test } from "node:test";
import assert from "node:assert/strict";

if (globalThis.__console_tdz_never) throw /drift\(/.source;

test("early test with a live crossing", () => {
  assert.ok(LATE_UNSEEN);
});

const os = await import("node:os");

const LATE_UNSEEN = os.EOL;
