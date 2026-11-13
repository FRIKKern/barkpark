// class-coverage-controls.test.mjs — parts (B) to (D) of the class-coverage
// suite: a control pair for each class the tripwire found uncontrolled.
//
//   node --test tooling/grip/test/class-coverage-controls.test.mjs
//
// One of the class-coverage-*.test.mjs files the single class-coverage suite was
// split into by subject (task-ff9bcdb1cbe00405); the tests moved unchanged. The
// tripwire reads this file as corpus from the part (B) banner onward; this
// header and the imports do not count (corpusTextOf in
// lib/class-coverage-scan.mjs).

import { test } from "node:test";
import assert from "node:assert/strict";

import { chmodSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { checkCeiling, classifyRef } from "../level.mjs";
import { admitFact } from "../record.mjs";
import { writeLedgerRun } from "../ledger.mjs";
import { classifyOutcome, OUTCOME } from "../census.mjs";
import { backfillOne, DISPOSITION } from "../backfill.mjs";
import { classifyBinding, isDefaultRule } from "../binding.mjs";
import { mintRecipe } from "../mint.mjs";

// ─────────────────────────────────────────────────────────────────────────────
// (B) THE CONTROLS — each class FIRES on an input that must trigger it, and
// stays SILENT on a neighbour that must not. Fail-before plant + never-cry-wolf,
// one pair per class.
// ─────────────────────────────────────────────────────────────────────────────

test("NOT-A-REF fires on a non-reference, and never on a real one", () => {
  for (const bad of ["", "   ", "see the notifications module", "api/lib/x.ex:", "api/lib/x.ex:12:14"]) {
    const v = classifyRef(bad);
    assert.equal(v.ok, false);
    assert.equal(v.reason, "NOT-A-REF", `${JSON.stringify(bad)} should be NOT-A-REF`);
    assert.match(v.message, /^NOT-A-REF: /);
  }
  assert.equal(classifyRef(null).reason, "NOT-A-REF");
});

test("NOT-A-REF never cries wolf: a pathless ref is PATHLESS-REF and a good ref is ok", () => {
  // The near-miss that matters: `notifications.ex:389-397` IS ref-shaped. Calling  [lineref-ok]
  // it NOT-A-REF would erase the distinction the class exists to draw.
  const pathless = classifyRef("notifications.ex:389-397");
  assert.equal(pathless.ok, false);
  assert.equal(pathless.reason, "PATHLESS-REF");
  const good = classifyRef("cloud/lib/barkpark_cloud/notifications.ex:389-397");
  assert.equal(good.ok, true);
  assert.deepEqual(good.lines, { start: 389, end: 397 });
});

test("WRITE-FAILED fires when the ledger directory refuses the write", (t) => {
  if (typeof process.getuid === "function" && process.getuid() === 0) {
    t.skip("running as root — a read-only directory cannot produce EACCES, so this control cannot be exercised here");
    return;
  }
  const now = "2026-07-27T00:00:00Z";
  const recipe = mintRecipe({ rerun: "wc -l tooling/grip/mint.mjs" }, { observed_at: now }).recipe;
  const base = mkdtempSync(join(tmpdir(), "grip-classcov-write-"));
  const readOnly = join(base, "ro");
  try {
    mkdirSync(readOnly);
    chmodSync(readOnly, 0o555);
    const verdict = writeLedgerRun({ run_id: "grip-classcoverage-plant", recipes: [recipe], dir: readOnly, now });
    assert.equal(verdict.ok, false);
    assert.deepEqual(verdict.rejections.map((r) => r.reason), ["WRITE-FAILED"]);
    assert.match(verdict.rejections[0].message, /^WRITE-FAILED: /);
    assert.match(verdict.rejections[0].message, /EACCES/);
    assert.equal(readdirSync(readOnly).length, 0, "nothing may be written when the write failed");
  } finally {
    chmodSync(readOnly, 0o755);
    rmSync(base, { recursive: true, force: true });
  }
});

test("WRITE-FAILED never cries wolf: a writable directory writes, and a re-write is ALREADY-RECORDED", () => {
  const now = "2026-07-27T00:00:00Z";
  const recipe = mintRecipe({ rerun: "wc -l tooling/grip/mint.mjs" }, { observed_at: now }).recipe;
  const dir = mkdtempSync(join(tmpdir(), "grip-classcov-ok-"));
  try {
    const first = writeLedgerRun({ run_id: "grip-classcoverage-plant", recipes: [recipe], dir, now });
    assert.equal(first.ok, true);
    assert.equal(first.written, true);
    // Same bytes again: idempotent, and emphatically NOT a write failure.
    const second = writeLedgerRun({ run_id: "grip-classcoverage-plant", recipes: [recipe], dir, now });
    assert.equal(second.ok, true);
    assert.equal(second.written, false);
    assert.equal(second.reason, "ALREADY-RECORDED");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("TOOL-ERROR fires when a matcher or a differ ERRORS, and is counted as decay", () => {
  const matcher = classifyOutcome("grep -n isolation tooling/grip/mint.mjs", { exit: 2, stdout: "", stderr: "grep: unrecognized option" });
  assert.equal(matcher.outcome, OUTCOME.TOOL_ERROR);
  assert.equal(matcher.outcome, "TOOL-ERROR");
  assert.equal(matcher.answering, false);
  assert.equal(matcher.decayed, true);
  assert.equal(matcher.admissible, true, "decay is admissible — it is an answer about the world having moved");

  const differ = classifyOutcome("diff a.txt b.txt", { exit: 3, stdout: "", stderr: "diff: something broke" });
  assert.equal(differ.outcome, OUTCOME.TOOL_ERROR);
});

test("TOOL-ERROR never cries wolf: grep rc 1 is an ABSENCE and a gone path is PATH-GONE", () => {
  // THE SPECIMEN. rc 1 with no bytes is grep answering "nothing here". Reading it
  // as a tool error is the exact fabricated-decay defect this census exists to end.
  const absent = classifyOutcome("grep -n isolation tooling/grip/mint.mjs", { exit: 1, stdout: "", stderr: "" });
  assert.equal(absent.outcome, OUTCOME.ABSENT);
  assert.equal(absent.answering, true);

  const gone = classifyOutcome("grep -n isolation gone.mjs", { exit: 2, stdout: "", stderr: "grep: gone.mjs: No such file or directory" });
  assert.equal(gone.outcome, OUTCOME.PATH_GONE);
  assert.notEqual(gone.outcome, OUTCOME.TOOL_ERROR);
});

const NEVER_SPAWNS = () => {
  throw new Error("a test runner must never be executed by the backfill");
};
const ANSWERED_RUN = () => ({ exit: 0, stdout: "42\n", stderr: "", ms: 1, timedOut: false, spawnError: null });

test("TEST-RUNNER fires on the runners the screen admits — and the command is never spawned", () => {
  // `exec` throws: reaching the executor at all fails this test, which is the
  // property that matters — a test runner executes repo code the screen never read.
  for (const cmd of ["go test ./...", "mix test test/foo_test.exs"]) {
    const row = backfillOne(cmd, { now: "2026-07-27T00:00:00Z", exec: NEVER_SPAWNS });
    assert.equal(row.disposition, DISPOSITION.TEST_RUNNER, `${cmd} should be dispositioned TEST-RUNNER`);
    assert.equal(row.disposition, "TEST-RUNNER");
    assert.equal(row.outcome, "SKIPPED-TEST-RUNNER");
  }
});

test("TEST-RUNNER never cries wolf: the screen decides first, and a real read is MINTED", () => {
  const now = "2026-07-27T00:00:00Z";
  // PRECEDENCE, recorded rather than assumed: `npm test` and `pytest` never reach
  // the test-runner check at all — the screen refuses them first (npm's `test`
  // sub-verb is off the read-only allowlist; `pytest` is an unknown head and the
  // screen fails closed). Their disposition is SCREEN-REFUSED, and calling that a
  // TEST-RUNNER row would misreport WHY the command did not run.
  for (const cmd of ["npm test --workspace js/sdk", "pytest -q"]) {
    const row = backfillOne(cmd, { now, exec: NEVER_SPAWNS });
    assert.equal(row.disposition, DISPOSITION.SCREEN_REFUSED, `${cmd} is refused by the screen before the runner check`);
  }
  for (const cmd of ["go vet ./internal/cli", "wc -l tooling/grip/mint.mjs"]) {
    const row = backfillOne(cmd, { now, exec: ANSWERED_RUN });
    assert.notEqual(row.disposition, DISPOSITION.TEST_RUNNER, `${cmd} is not a test runner`);
    assert.equal(row.disposition, DISPOSITION.MINTED);
  }
});

test("UNMINTABLE fires when a command ANSWERS but no recipe can be minted, and names WHY", () => {
  // The four shapes part (C) proves reach NO-QUANTITY: `cd` swallows the head
  // AND its argument, so the path still mints a subject while the quantity has
  // no head left to come from. The command ANSWERED — this is neither a decay
  // nor a refusal, and that is the distinction UNMINTABLE exists to record.
  //
  // THIS CONTROL IS WHY THE ENUM LAYER WAS BUILT. UNMINTABLE carries no hyphen,
  // so no literal scan could ever see it; before this pair it was named by
  // nothing under test/ except a sentence in this file's own header declaring it
  // invisible — a class "covered" by the confession that it was not.
  const now = "2026-07-27T00:00:00Z";
  for (const cmd of ["cd tooling/grip/mint.mjs", "cd api/lib/foo.ex", "cd tooling/grip", "cd x.txt"]) {
    const row = backfillOne(cmd, { now, exec: ANSWERED_RUN });
    assert.equal(row.disposition, DISPOSITION.UNMINTABLE, `${cmd} should be dispositioned UNMINTABLE`);
    assert.equal(row.disposition, "UNMINTABLE");
    assert.equal(row.outcome, "ANSWERED", "an UNMINTABLE row RAN and answered — what was lost is the recipe, never the read");
    assert.equal(row.why, "NO-QUANTITY", "the row must carry the mint reason, or UNMINTABLE degenerates into a shrug");
  }
});

test("UNMINTABLE never cries wolf: a real read MINTS, a refusal is SCREEN-REFUSED, a failed run is DECAYED", () => {
  const now = "2026-07-27T00:00:00Z";
  const FAILED_RUN = () => ({ exit: 1, stdout: "", stderr: "boom", ms: 1, timedOut: false, spawnError: null });
  for (const cmd of ["wc -l tooling/grip/mint.mjs", "go vet ./internal/cli"]) {
    assert.equal(backfillOne(cmd, { now, exec: ANSWERED_RUN }).disposition, DISPOSITION.MINTED, `${cmd} mints — it is not unmintable`);
  }
  // The two neighbours that also end with NO durable row. Calling either of them
  // UNMINTABLE would misreport WHY the row is missing: the first never ran at
  // all, the second ran and lost its answer, and only a minted-stage failure is
  // UNMINTABLE.
  assert.equal(backfillOne("FOO=1", { now, exec: NEVER_SPAWNS }).disposition, DISPOSITION.SCREEN_REFUSED);
  const decayed = backfillOne("wc -l gone.txt", { now, exec: FAILED_RUN });
  assert.equal(decayed.disposition, DISPOSITION.DECAYED);
  assert.equal(decayed.outcome, "RAN-AND-FAILED");
});

test("FORGE-API-READ fires on gh reads, and names the forge as the anchor", () => {
  for (const cmd of ["gh api repos/FRIKKern/barkpark/pulls/6284", "gh pr view 6284 --json state", "gh run list --limit 5"]) {
    const v = classifyBinding(cmd);
    assert.equal(v.rule, "FORGE-API-READ", `${cmd} should fire FORGE-API-READ`);
    assert.equal(v.binding_class, "shared-ref");
    assert.equal(v.portable_scope, "any worktree of this clone");
    assert.equal(isDefaultRule(v.rule), false, "FORGE-API-READ is a fired rule, never an else branch");
  }
});

test("FORGE-API-READ never cries wolf: other shared-ref reads keep their OWN rule names", () => {
  // The mutation that this pair exists to catch: routing `gh` to a neighbouring
  // rule of the SAME class leaves every class-level assertion green. Asserting
  // the RULE, per command, is what makes the rename visible.
  assert.equal(classifyBinding("git ls-remote origin main").rule, "GIT-REMOTE-SERVER-OP");
  assert.equal(classifyBinding("git show origin/main:tooling/grip/mint.mjs").rule, "REMOTE-TRACKING-REF");
  for (const cmd of ["git ls-remote origin main", "git show origin/main:tooling/grip/mint.mjs"]) {
    assert.notEqual(classifyBinding(cmd).rule, "FORGE-API-READ");
    assert.equal(classifyBinding(cmd).binding_class, "shared-ref", "same class, different rule — the class alone cannot tell them apart");
  }
});

test("DEFAULT-CWD-BOUND fires when no rule matched, and says so as a FLOOR", () => {
  for (const cmd of ["echo hello", "true", "date -u +%s"]) {
    const v = classifyBinding(cmd);
    assert.equal(v.rule, "DEFAULT-CWD-BOUND", `${cmd} should land on the else branch`);
    assert.equal(v.binding_class, "cwd-bound");
    assert.equal(isDefaultRule(v.rule), true, "the else branch MUST be registered as a default — the else-share number is derived from this");
    assert.match(v.reason, /ELSE branch/);
    assert.equal(v.anchor ?? null, null, "an else branch names no anchor — it has not found one");
  }
});

test("DEFAULT-CWD-BOUND never cries wolf: a fired cwd-bound rule is NOT the else branch", () => {
  // The survey's mutation: renaming the else branch collapsed DEFAULT-CWD-BOUND
  // 29 → 2 and IMPROVED the flagship else-share (4.8% → 0.3% at binding.mjs blob
  // a87ab60eb78693c6ee7dc30bbd9983e027370c26) with nothing red.
  // Both halves are pinned here — the name AND its default-ness — and
  // binding.test.mjs now bounds the arrival count from both sides as well, so
  // the aggregate figure the rename moved is no longer undefended.
  for (const [cmd, rule] of [
    ["curl -s http://localhost:4000/api/schemas", "NETWORK-READ-NO-TREE"],
    ["wc -l tooling/grip/mint.mjs", "RELATIVE-PATH-READ"],
    ["node tooling/grip/ledger.mjs --selftest", "TOOLCHAIN-CWD-ROOTED"],
  ]) {
    const v = classifyBinding(cmd);
    assert.equal(v.binding_class, "cwd-bound");
    assert.equal(v.rule, rule, `${cmd} must keep its own rule name, not the else branch's`);
    assert.equal(isDefaultRule(v.rule), false, `${rule} is a finding, not a floor`);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// (C) NO-QUANTITY — the reachability question, answered
// ─────────────────────────────────────────────────────────────────────────────
//
// THE HYPOTHESIS UNDER TEST was that NO-QUANTITY is structurally unreachable:
// `quantityPhrase` returns "" only when the measuring stage has no head, and
// mintRecipe returns NO-SUBJECT first whenever the head is empty — so the branch
// looked dead, and five probe shapes reached NO-SUBJECT instead.
//
// THE HYPOTHESIS IS FALSE, and this is the disposition: NO-QUANTITY IS REACHABLE.
// The subject does NOT depend on the head — `subject = paths[0] ?? cmd:<head>` —
// so a command whose only token is a PATH swallowed by `cd` mints a subject and
// no quantity. `cd tooling/grip/mint.mjs` is such a command: headAt skips `cd`
// AND its argument, leaving head "", while pathToken still sees the argument.
//
// PROBE TABLE (rerun → reason), the shapes tried and what each returned:
//   "cd tooling/grip/mint.mjs"     → NO-QUANTITY   ← REACHES IT (path swallowed by cd)
//   "cd api/lib/foo.ex"            → NO-QUANTITY   ← reaches it
//   "cd tooling/grip"              → NO-QUANTITY   ← reaches it
//   "cd x.txt"                     → NO-QUANTITY   ← reaches it
//   "FOO=1"                        → NO-SUBJECT    (assignment skipped, no path)
//   "cd /tmp && "                  → NO-SUBJECT    (absolute path is not a path token)
//   ""                             → NO-RERUN      (guarded earlier)
//   "wc -l tooling/grip/mint.mjs"  → ok            (control)
//
// The branch is LIVE, it is now controlled below, and nothing was deleted.

test("NO-QUANTITY is REACHABLE: a path swallowed by `cd` mints a subject and no quantity", () => {
  const now = "2026-07-27T00:00:00Z";
  for (const rerun of ["cd tooling/grip/mint.mjs", "cd api/lib/foo.ex", "cd tooling/grip", "cd x.txt"]) {
    const v = mintRecipe({ rerun }, { observed_at: now });
    assert.equal(v.ok, false);
    assert.equal(v.reason, "NO-QUANTITY", `${JSON.stringify(rerun)} should reach NO-QUANTITY, not ${v.reason}`);
  }
});

test("NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints", () => {
  const now = "2026-07-27T00:00:00Z";
  assert.equal(mintRecipe({ rerun: "" }, { observed_at: now }).reason, "NO-RERUN");
  assert.equal(mintRecipe({}, { observed_at: now }).reason, "NO-RERUN");
  assert.equal(mintRecipe({ rerun: "FOO=1" }, { observed_at: now }).reason, "NO-SUBJECT");
  assert.equal(mintRecipe({ rerun: "cd /tmp && " }, { observed_at: now }).reason, "NO-SUBJECT");

  const minted = mintRecipe({ rerun: "cd tooling/grip && wc -l mint.mjs" }, { observed_at: now });
  assert.equal(minted.ok, true, `a real read must mint, got ${minted.reason}`);
  assert.equal(minted.recipe.quantity, "wc:-l");
});

// ─────────────────────────────────────────────────────────────────────────────
// (D) UNKNOWN-LEVEL — the off-ladder claim, fired
// ─────────────────────────────────────────────────────────────────────────────
//
// UNKNOWN-LEVEL had exactly one hit under tooling/grip/test/ and it was a
// NEGATIVE assertion: adjudicate.mjs must not RESTATE the name (it composes
// record.mjs instead of re-implementing it). That assertion is green whether
// the ceiling check works, is inverted, or was deleted — it never asks the
// grammar anything. Below, it is asked.

test("UNKNOWN-LEVEL fires on a claim that is not on the ladder, and names the ladder it is off", () => {
  // The whole ceiling rests on LEVELS being a total order over known rungs. A
  // claim outside it cannot be COMPARED, so admitting it would silently let an
  // arbitrary string past the level gate — the failure mode is not "wrong
  // level", it is "no level at all, waved through".
  for (const claimed of ["L9", "L0", "l3", "L3 ", "high", ""]) {
    const v = checkCeiling(claimed, "L3");
    assert.equal(v.ok, false, `${JSON.stringify(claimed)} is off the ladder and must not be comparable`);
    assert.equal(v.reason, "UNKNOWN-LEVEL", `${JSON.stringify(claimed)} should be UNKNOWN-LEVEL, got ${v.reason}`);
    assert.match(v.message, /^UNKNOWN-LEVEL: claimed level /);
    assert.match(v.message, /is not on the ladder L1 L2 L3 L4 L5 L6/);
  }

  // The DERIVED side of the same guard — the half a caller cannot reach by
  // typing a bad claim, and the half that would go unnoticed if deriveLevel
  // ever started answering something the ladder does not carry.
  const derived = checkCeiling("L3", "L7");
  assert.equal(derived.reason, "UNKNOWN-LEVEL");
  assert.match(derived.message, /^UNKNOWN-LEVEL: derived level /);

  // And it reaches the real admission path, not just the helper: this is the
  // reproduction the filing named.
  const rejected = admitFact({ subject: "s", claim: "c", rerun: "git rev-parse HEAD", level: "L9" });
  assert.equal(rejected.ok, false);
  assert.deepEqual(rejected.rejections.map((r) => r.reason), ["UNKNOWN-LEVEL"]);
  assert.equal(rejected.rejections[0].claimed, "L9");
  assert.equal(rejected.rejections[0].derived, "L3");
});

test("UNKNOWN-LEVEL never cries wolf: an on-ladder over-claim is LEVEL-SKIP, and an under-claim is admitted", () => {
  // The distinction the class exists to draw. "Off the ladder" and "too high on
  // the ladder" are different findings with different fixes — collapsing them
  // would tell an author to re-derive when the real defect is a typo, and vice
  // versa. Both neighbours are pinned here.
  const skip = checkCeiling("L1", "L3");
  assert.equal(skip.ok, false);
  assert.equal(skip.reason, "LEVEL-SKIP");
  assert.notEqual(skip.reason, "UNKNOWN-LEVEL");

  for (const [claimed, derived] of [["L3", "L3"], ["L4", "L3"], ["L6", "L1"]]) {
    assert.equal(checkCeiling(claimed, derived).ok, true, `${claimed} on ${derived} is an honest claim`);
  }

  // An omitted level is not an unknown one — a fact with no claim is levelled
  // by its command (D3), never rejected.
  const admitted = admitFact({ subject: "s", claim: "c", rerun: "git rev-parse HEAD" });
  assert.equal(admitted.ok, true, `an unclaimed level must be derived, not rejected: ${JSON.stringify(admitted.rejections)}`);
  assert.equal(admitted.fact.level, "L3");
});
