// FIXTURE — console-tdz-order-check.mjs --selftest. NOT a test file; nothing
// runs it. It carries a KNOWN answer so a mis-lex cannot fail silently toward
// green (the v1 failure this guard exists to not repeat).
//
// Expected verdict: exactly two crossings —
//   "direct crossing"     → LATE_DIRECT
//   "transitive crossing" → LATE_VIA_HELPER (reached only through earlyHelper)
// and NOT "shadowed name", which declares its own LATE_SHADOWED.

import { test } from "node:test";
import assert from "node:assert/strict";

// A regex literal carrying an embedded quote. UNMASKED, its `"` opens a phantom
// string that swallows code and drifts the depth map — which is how the
// unmasked v1 reported a vacuous green on a file with five live crossings.
const CARD_RE = /class="[^"]*plan-card"/;
const RATIO = 10 / 2; // a real division: `/` here must NOT start a regex

// An EARLY top-level helper that names a LATE binding. The tests below reach
// LATE_VIA_HELPER only through this call — a direct-reference guard misses it.
function earlyHelper(n) {
  return LATE_VIA_HELPER + n;
}

test("direct crossing", () => {
  assert.ok(LATE_DIRECT);
});

test("transitive crossing", () => {
  assert.equal(earlyHelper(1), 2);
});

test("shadowed name", () => {
  const LATE_SHADOWED = 2;
  assert.equal(LATE_SHADOWED, 2);
});

test("clean early test", () => {
  assert.match('<a class="plan-card">', CARD_RE);
  assert.equal(RATIO, 5);
  // INLINE regex inside a call — the exact shape that drifts an unmasked depth
  // map: the phantom string opened by the second `"` swallows the closing `)`,
  // so the call never closes and every later depth is one too deep.
  assert.match('<a data-plan="new-plan">', /plan=("[^"]*")/);
});

// An INDENTED await inside a function body is not a module boundary. A naive
// `grep -n await` picks this line and every later measurement is wrong.
async function loadLater() {
  const mod = await import("node:path");
  return mod.sep;
}

// ── the module boundary: the first depth-0 await ────────────────────────────
const os = await import("node:os");

const LATE_DIRECT = typeof os.EOL === "string";
const LATE_VIA_HELPER = 1;
const LATE_SHADOWED = 3;

test("late tests may read late bindings", async () => {
  assert.ok(LATE_DIRECT && LATE_VIA_HELPER && LATE_SHADOWED);
  assert.equal(typeof (await loadLater()), "string");
});
