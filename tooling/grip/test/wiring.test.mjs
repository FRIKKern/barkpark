#!/usr/bin/env node
// Proof that screen.mjs and ledger.mjs ACTUALLY MEET — tooling/grip/test/wiring.test.mjs
//
//   node --test tooling/grip/test/wiring.test.mjs
//
// WHY THIS FILE EXISTS, AND WHY THE ASSERTION IS CONTAINMENT AND NOT SHAPE.
//
// Wave 3's headline defect was a cross-slice break. ledger.mjs read
// `verdict.message`; screen.mjs returned `{ ok, reason }`. Both modules were
// correct alone, their file sets were disjoint so they dispatched in parallel,
// and nothing in either suite ever put them in a room together. Every refusal
// printed the generic fallback and THREW AWAY the screen's diagnosis — in the
// exact place screen.mjs authors a per-head explanation so the refusal log
// would read as a diagnosis rather than a shrug.
//
// THE TEST THAT LOOKS LIKE THIS ONE AND IS NOT. test/ledger.test.mjs:826 is
// titled "the injected-screen contract MEETS screen.mjs's real return shape".
// Its own line 836 says it "Uses a faithful STAND-IN rather than importing
// screen.mjs" — correctly, because ledger.mjs must keep importing nothing but
// level.mjs (D39), so its suite may not import screen.mjs either. A stand-in
// asserts what its AUTHOR believed the other module returns. It cannot fail
// when that belief goes stale, which is the only failure that matters here.
//
// WHY A SHAPE ASSERTION WOULD ADD NOTHING — measured, not assumed. A NAIVE
// mutation (breaking `reason` in one place) already turns screen.test.mjs
// 16-19 tests red, so that case is covered and a shape assertion here would
// merely duplicate it. The gap is the CONSISTENT REFACTOR: rename `reason` to
// `why` in refuse(), in the admit return, in screenAll's own consumer at
// screen.mjs:806 and throughout test/screen.test.mjs, and EVERY shipped suite
// stays 100% green — screen.test 34/0, ledger.test 60/0, level.test 71/0 —
// while the ledger silently falls back to "the injected screen refused it".
// Wave 3's defect, reproduced, invisible to the entire suite.
//
// SUBSTRING CONTAINMENT is the one assertion that survives that refactor, and
// the one no single-module suite can express: the ledger's live rejection
// message must literally CONTAIN the screen's live diagnosis string. Neither
// module has to know the other's key names for it to hold, and no rename can
// satisfy it by accident.
//
// TWO PROPERTIES, KEPT APART ON PURPOSE:
//   DIAGNOSIS — the refusal names WHY (the containment test).
//   SAFETY    — a dangerous command is never admitted (the fail-open sweep).
// They fail independently. The wave-3 defect broke DIAGNOSIS while SAFETY held
// perfectly, which is exactly why it survived review: the system was safe and
// unhelpful, and only one of those is visible from a green suite.
//
// HERMETIC. No screened command is ever executed. Every write goes to a fresh
// mkdtemp directory.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// THE WHOLE POINT: both real modules, no stand-ins.
import { screenCommand } from "../screen.mjs";
import { admitRecipe, writeLedgerRun } from "../ledger.mjs";

// A command from screen.mjs's own DANGER SET. Chosen because it is refused by
// the sub-verb rule, whose reason string names the allowlist it failed — the
// richest diagnosis the screen produces, so the most to lose by dropping it.
const OUTAGE_COMMAND = "systemctl stop bp-crux-parent";

// Allowlisted, read-only, and it derives L2 — so the row is admissible on the
// level grammar too and REFUSED-COMMAND is the only thing under test.
const READ_ONLY_COMMAND = "git show origin/main:README.md";

const freshDir = () => mkdtempSync(join(tmpdir(), "grip-wiring-"));

// `derived_level: "L6"` is deliberate on the outage row. `systemctl stop …`
// derives L6, so ANY higher claim would add a LEVEL-SKIP rejection alongside
// the one under test and the assertions below would be reading a two-rejection
// row. Isolating REFUSED-COMMAND is the difference between a test that proves
// containment and a test that happens to pass.
const outageRow = () => ({
  subject: "bp-crux-parent service state",
  quantity: "running = true",
  rerun: OUTAGE_COMMAND,
  derived_level: "L6",
  deps: [],
  observed_at: "2026-07-20T12:00:00Z",
});

const readOnlyRow = (subject = "README head") => ({
  subject,
  quantity: "byte count > 0",
  rerun: READ_ONLY_COMMAND,
  derived_level: "L2",
  deps: [],
  observed_at: "2026-07-20T12:00:00Z",
});

// ─────────────────────────────────────────────────────────────────────────────
// PART 1 — the containment contract
// ─────────────────────────────────────────────────────────────────────────────

test("screen's LIVE reason survives verbatim into the ledger's LIVE rejection", () => {
  // Step 1 — what the real screen actually says right now. Not a fixture, not
  // a stand-in: the string screen.mjs returns on this run.
  const verdict = screenCommand(OUTAGE_COMMAND);
  assert.equal(verdict.ok, false, `${OUTAGE_COMMAND} must be refused by the real screen`);

  // Step 2 — the ANTI-VACUITY GUARD, and it is load-bearing rather than
  // decorative. `"".includes(undefined)` is false but `x.includes("")` is
  // ALWAYS true, so an empty or missing reason would make the containment
  // assertion below unfalsifiable — a green that proves nothing, which is the
  // precise failure mode this epic exists to abolish. Under the consistent
  // rename this is the assertion that goes red first: `verdict.reason` becomes
  // undefined and the type check catches it before containment is reached.
  assert.equal(typeof verdict.reason, "string",
    "screen's verdict must carry a `reason` STRING — if this fails, screen.mjs's " +
    "return shape moved and the ledger is now printing a shrug in its place");
  assert.ok(verdict.reason.length > 0,
    "screen's reason must be NON-EMPTY, or containment below is vacuously true");

  // Step 3 — the real ledger, with the real screen injected, exactly as the
  // CLI wires them.
  const admission = admitRecipe(outageRow(), { screen: screenCommand });
  assert.equal(admission.ok, false, "a command that can take a service down must never become a recipe");

  const refusal = admission.rejections.find((r) => r.reason === "REFUSED-COMMAND");
  assert.ok(refusal, "the outage command must be refused under REFUSED-COMMAND specifically");

  // Step 4 — THE LOAD-BEARING ASSERTION. Verbatim containment, both directions
  // proven: the diagnosis is present, and the shrug that would replace it is
  // absent. The second half is not redundant — it names the exact regression,
  // so a future reader of a red sees the wave-3 defect by name.
  assert.ok(
    refusal.message.includes(verdict.reason),
    "THE CROSS-SLICE CONTRACT IS BROKEN.\n" +
    `  screen.mjs said : ${verdict.reason}\n` +
    `  ledger.mjs said : ${refusal.message}\n` +
    "  The ledger is no longer carrying the screen's diagnosis. This is wave 3's\n" +
    "  defect: the modules are each internally consistent and no longer meet.",
  );
  assert.ok(
    !refusal.message.includes("the injected screen refused it"),
    "the ledger fell back to its generic shrug — it could not read the screen's verdict",
  );

  // The isolation the row was built for: exactly one rejection, and it is this
  // one. If a second appears, the assertions above were reading a noisier row
  // than their author intended.
  assert.equal(admission.rejections.length, 1,
    `expected REFUSED-COMMAND alone, got ${admission.rejections.map((r) => r.reason).join("+")}`);
});

test("the diagnosis is SPECIFIC to the command, not one constant string", () => {
  // Containment against a single command could be satisfied by a screen that
  // returns one frozen sentence. Two commands refused for DIFFERENT reasons
  // must produce two different ledger messages, each carrying its own live
  // diagnosis — otherwise the log is a shrug wearing a longer coat.
  const cases = [
    { cmd: OUTAGE_COMMAND, subject: "service state" },
    { cmd: "rm -rf /opt/barkpark", subject: "checkout state" },
  ];

  const seen = new Set();
  for (const { cmd, subject } of cases) {
    const verdict = screenCommand(cmd);
    assert.equal(verdict.ok, false, `${cmd} must be refused`);
    assert.ok(typeof verdict.reason === "string" && verdict.reason.length > 0,
      `${cmd} must carry a non-empty reason`);

    const row = { ...outageRow(), subject, rerun: cmd };
    const admission = admitRecipe(row, { screen: screenCommand });
    assert.equal(admission.ok, false);
    const refusal = admission.rejections.find((r) => r.reason === "REFUSED-COMMAND");
    assert.ok(refusal, `${cmd} must be refused under REFUSED-COMMAND`);
    assert.ok(refusal.message.includes(verdict.reason),
      `${cmd}: the ledger dropped the screen's diagnosis`);
    seen.add(verdict.reason);
  }

  assert.equal(seen.size, cases.length,
    "two commands refused for different rules produced the SAME reason string — " +
    "the diagnosis is constant, so containment proves nothing about it");
});

// ─────────────────────────────────────────────────────────────────────────────
// PART 1b — the admit path and all-or-nothing, through both real modules
// ─────────────────────────────────────────────────────────────────────────────

test("an allowlisted read-only command passes the real screen and writes ONE file", () => {
  const dir = freshDir();
  try {
    // The screen must admit it — assert that first, so a screen regression
    // that refused honest reads is reported as such rather than surfacing as a
    // confusing write failure two assertions later.
    const verdict = screenCommand(READ_ONLY_COMMAND);
    assert.equal(verdict.ok, true,
      `${READ_ONLY_COMMAND} is read-only and must be ADMITTED — refusing honest work is the other error direction`);

    const admission = admitRecipe(readOnlyRow(), { screen: screenCommand });
    assert.equal(admission.ok, true,
      `admitRecipe rejected an admissible row: ${(admission.rejections ?? []).map((r) => r.message).join(" | ")}`);

    const written = writeLedgerRun({
      run_id: "wiring-admit",
      recipes: [readOnlyRow()],
      dir,
      screen: screenCommand,
    });
    assert.equal(written.ok, true,
      `writeLedgerRun rejected: ${(written.rejections ?? []).map((r) => r.message).join(" | ")}`);
    assert.equal(written.written, true, "the first write of these bytes must actually write");

    const files = readdirSync(dir);
    assert.equal(files.length, 1, `expected exactly one run file, got ${JSON.stringify(files)}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("ALL-OR-NOTHING: one refused row in a batch of two writes NOTHING", () => {
  const dir = freshDir();
  try {
    const written = writeLedgerRun({
      run_id: "wiring-batch",
      recipes: [readOnlyRow("honest row"), outageRow()],
      dir,
      screen: screenCommand,
    });

    assert.equal(written.ok, false, "a batch containing a refused command must not be written");

    // The refusal must be ATTRIBUTED to the right row. A rejection that named
    // the wrong index would send a writer editing an innocent row.
    const refusal = written.rejections.find((r) => r.reason === "REFUSED-COMMAND");
    assert.ok(refusal, "the batch must fail under REFUSED-COMMAND");
    assert.equal(refusal.index, 1, "the rejection must point at the offending row");

    // And the diagnosis survives the batch path too — not just the single-row
    // path. These are different call sites in ledger.mjs.
    const verdict = screenCommand(OUTAGE_COMMAND);
    assert.ok(refusal.message.includes(verdict.reason),
      "the batch path dropped the screen's diagnosis");

    // The property itself: nothing on disk. Not "a file without the bad row" —
    // a partial write is the silent-strip defect at file granularity.
    assert.deepEqual(readdirSync(dir), [],
      "a rejected batch left a file behind — the honest row was silently kept without its neighbour");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PART 2 — the fail-open sweep (the SAFETY property, standing control)
// ─────────────────────────────────────────────────────────────────────────────
//
// The containment test guards DIAGNOSIS. This guards SAFETY, and they are
// genuinely independent: wave 3 broke diagnosis while safety held. The sweep is
// what keeps a future "let's be lenient about the verdict shape" from admitting
// an outage command quietly.
//
// Every shape below is something a screen might plausibly return once someone
// refactors it — including the ones that are TRUTHY (`{ok:1}`, `{ok:'false'}`,
// a bare string) and would be admitted by any check looser than the strict
// `verdict.ok === true` ledger.mjs performs. The list is deliberately hostile.

const FAIL_OPEN_SHAPES = [
  { name: "false", screen: () => false },
  { name: "undefined", screen: () => undefined },
  { name: "null", screen: () => null },
  { name: "0", screen: () => 0 },
  { name: "empty string", screen: () => "" },
  { name: "{}", screen: () => ({}) },
  { name: "[]", screen: () => [] },
  { name: "{ok:0}", screen: () => ({ ok: 0 }) },
  { name: "{ok:1} (TRUTHY)", screen: () => ({ ok: 1 }) },
  { name: "{ok:'false'} (TRUTHY)", screen: () => ({ ok: "false" }) },
  { name: "NaN", screen: () => NaN },
  { name: "bare string (TRUTHY)", screen: () => "refused: systemctl" },
  { name: "throws", screen: () => { throw new Error("screen blew up"); } },
  { name: "Promise (async screen)", screen: () => Promise.resolve({ ok: false, reason: "async" }) },
  { name: "{ok:false}", screen: () => ({ ok: false }) },
];

test(`FAIL-OPEN SWEEP: all ${FAIL_OPEN_SHAPES.length} screen return shapes REFUSE an outage command`, () => {
  assert.ok(FAIL_OPEN_SHAPES.length >= 15,
    "the sweep is the standing control — it may grow, never shrink below 15");

  const admitted = [];
  const byReason = new Map();

  for (const { name, screen } of FAIL_OPEN_SHAPES) {
    const admission = admitRecipe(outageRow(), { screen });
    if (admission.ok) {
      admitted.push(name);
      continue;
    }
    const reasons = admission.rejections.map((r) => r.reason);
    for (const r of reasons) byReason.set(r, (byReason.get(r) ?? 0) + 1);
  }

  assert.deepEqual(admitted, [],
    `FAIL-OPEN: ${admitted.join(", ")} admitted "${OUTAGE_COMMAND}". A screen whose ` +
    "verdict shape is not understood must REFUSE, never admit — a ledger row is a " +
    "standing invitation to re-run the command it names.",
  );

  // Refusing is necessary; refusing under the RIGHT NAME is what makes the log
  // actionable. A throw and an async screen are AUTHOR errors, not dangerous
  // commands, and telling their author "your command was refused" would send
  // them auditing the screen instead of fixing the wiring.
  assert.equal(byReason.get("SCREEN-FAILED"), 1, "a throwing screen must be named SCREEN-FAILED, not REFUSED-COMMAND");
  assert.equal(byReason.get("SCREEN-NOT-SYNC"), 1, "an async screen must be named SCREEN-NOT-SYNC — it screens nothing");
  assert.equal(byReason.get("REFUSED-COMMAND"), FAIL_OPEN_SHAPES.length - 2,
    "every remaining shape is an ordinary refusal");
});

test("the sweep can distinguish safe from unsafe — it does not refuse everything", () => {
  // A sweep that passed because admitRecipe refuses unconditionally would be
  // the vacuous green in its purest form: 15/15 "safe" and the module useless.
  // One honest screen, one honest command, one admission proves the control has
  // a working other direction.
  const admission = admitRecipe(readOnlyRow(), { screen: () => ({ ok: true, reason: "admitted" }) });
  assert.equal(admission.ok, true,
    "a permissive screen over a read-only command must ADMIT — otherwise the sweep " +
    "above proves nothing but that admitRecipe always says no");
});
