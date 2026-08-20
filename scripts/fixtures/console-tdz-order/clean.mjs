// FIXTURE — console-tdz-order-check.mjs --selftest. The green twin of
// crossing.mjs: same shapes (early helper, regex literal, indented await,
// locally shadowed name), zero crossings. It is here so the self-test proves
// the guard can PASS as well as fail — a guard that only ever reds is not a
// measurement either.

import { test } from "node:test";
import assert from "node:assert/strict";

const CARD_RE = /class="[^"]*plan-card"/;
const EARLY_CONST = 41;

function earlyHelper(n) {
  return EARLY_CONST + n;
}

test("early test reads only early bindings", () => {
  assert.equal(earlyHelper(1), 42);
  assert.match('class="plan-card"', CARD_RE);
});

test("early test shadows a late name", () => {
  const LATE_ONLY = 7;
  assert.equal(LATE_ONLY, 7);
});

async function loadLater() {
  const mod = await import("node:path");
  return mod.sep;
}

// ── the module boundary ─────────────────────────────────────────────────────
const os = await import("node:os");

const LATE_ONLY = typeof os.EOL === "string";

test("late test reads late bindings", async () => {
  assert.ok(LATE_ONLY);
  assert.equal(typeof (await loadLater()), "string");
});
