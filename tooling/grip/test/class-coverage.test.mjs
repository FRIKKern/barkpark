// class-coverage.test.mjs — the class-coverage TRIPWIRE, plus controls for the
// classes it found uncontrolled.
//
//   node --test tooling/grip/test/class-coverage.test.mjs
//
// WHY THIS FILE EXISTS, AND WHY IT IS NOT THE COMMAND THAT WAS FILED.
//
// The filed version of this work was a shell one-liner over SEVEN hand-listed
// modules, matching the HYPHEN spelling only. It reproduces three real absences
// (NO-QUANTITY, NOT-A-REF, WRITE-FAILED) — the measurement was right — but the
// method is wrong twice over:
//
//   1. THE FILE SET WAS HAND-LISTED. backfill.mjs was not on it, so TEST-RUNNER
//      escaped both prior scans. A hand-listed set measures the author's memory,
//      not the tree. This scan GLOBS.
//   2. THE SPELLING WAS SINGLE. census.mjs stores `TOOL_ERROR: "TOOL-ERROR"` and
//      census.test.mjs asserts through the UPPER_SNAKE enum KEY. A hyphen-only
//      scan therefore cries wolf on five genuinely-controlled census classes
//      (SCREEN-REFUSED, ANOMALOUS-SILENCE, AMBIGUOUS-SILENCE, UNCLASSIFIED-128,
//      SKIPPED-TEST-RUNNER) — never-cry-wolf failing INSIDE the instrument built
//      to enforce it. This scan matches BOTH spellings.
//
// It is written in Node (fs + RegExp), not shell, deliberately: `grep` on the
// authoring host is ugrep 7.5.0, which rejects invocations GNU grep accepts, and
// grip has NO CI — so a shell-shaped tripwire is tested only on one box and
// untested where it would have to hold.
//
// WHAT THIS TRIPWIRE DOES NOT MEASURE — declared, not implied:
//   * IT REQUIRES A HYPHEN. Six of adjudicate.mjs's ten verdict names (ADMITTED,
//     DEMOTED, REJECTED, FAILED, UNAVAILABLE, CONFLICT) and backfill.mjs's
//     UNMINTABLE carry no hyphen and are INVISIBLE to it by construction. The
//     number it prints is a LOWER BOUND on the identifier universe, never a
//     census of it.
//   * IT MEASURES MENTION, NOT CONTROL. A class named anywhere under test/ reads
//     as covered here. Mention is not control — proven by mutation in the survey:
//     renaming FORGE-API-READ to another same-class rule left binding.test.mjs at
//     63/62/1 unchanged, and renaming the else branch collapsed DEFAULT-CWD-BOUND
//     29 → 2 while IMPROVING the epic's flagship else-share 4.8% → 0.6% with
//     nothing going red (binding.test.mjs:454 is `assert.ok(registered.has(…))`,
//     a subset check that cannot fail for an unexercised rule). So absence here
//     is a PROOF of no control; presence is only an INVITATION to check. The
//     controls in part (B) below are the real thing: each one fires the class on
//     an input that must trigger it and withholds it on a neighbour that must not.

import { test } from "node:test";
import assert from "node:assert/strict";

import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, cpSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { checkCeiling, classifyRef } from "../level.mjs";
import { admitFact } from "../record.mjs";
import { writeLedgerRun } from "../ledger.mjs";
import { classifyOutcome, OUTCOME } from "../census.mjs";
import { backfillOne, DISPOSITION } from "../backfill.mjs";
import { classifyBinding, isDefaultRule } from "../binding.mjs";
import { mintRecipe } from "../mint.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = resolve(HERE, "..");
const SELF = "class-coverage.test.mjs";

// ─────────────────────────────────────────────────────────────────────────────
// (A) THE TRIPWIRE
// ─────────────────────────────────────────────────────────────────────────────

// A SHOUTY class identifier is a fully-uppercase, hyphen-joined STRING LITERAL.
// Restricting to literals (rather than any word in the file) keeps prose in
// comments — "DEFAULT-*", "the D73 rule" — out of the universe, so the tripwire
// counts things the code can actually return.
const SHOUTY_LITERAL = /(["'`])((?:[A-Z0-9]+-)+[A-Z0-9]+)\1/g;

/**
 * scanClassCoverage({ srcDir, testDir, excludeTests }) →
 *   { modules, universe: Map<class, "file:line">, hyphenOnly: [], dual: [] }
 *
 * GLOBS `srcDir` — never a hand-listed set. `dual` is the uncontrolled set under
 * BOTH spellings (`NO-QUANTITY` and `NO_QUANTITY`); `hyphenOnly` is what the
 * filed method would have said, kept so the two can be printed side by side.
 * Exported so a scratch copy of the tree can be scanned without editing this one.
 */
export function scanClassCoverage({ srcDir = GRIP, testDir = join(GRIP, "test"), excludeTests = [] } = {}) {
  const modules = readdirSync(srcDir).filter((name) => name.endsWith(".mjs")).sort();
  const universe = new Map();
  for (const name of modules) {
    const lines = readFileSync(join(srcDir, name), "utf8").split("\n");
    lines.forEach((line, i) => {
      SHOUTY_LITERAL.lastIndex = 0;
      let m;
      while ((m = SHOUTY_LITERAL.exec(line)) !== null) {
        if (!universe.has(m[2])) universe.set(m[2], `${name}:${i + 1}`);
      }
    });
  }

  const testFiles = readdirSync(testDir)
    .filter((name) => name.endsWith(".mjs") && !excludeTests.includes(name))
    .sort();
  const corpus = testFiles.map((name) => readFileSync(join(testDir, name), "utf8")).join("\n");

  const hyphenOnly = [];
  const dual = [];
  for (const [id, where] of universe) {
    const mentionedHyphen = corpus.includes(id);
    const mentionedSnake = new RegExp(`\\b${id.replace(/-/g, "_")}\\b`).test(corpus);
    if (!mentionedHyphen) hyphenOnly.push({ id, where });
    if (!mentionedHyphen && !mentionedSnake) dual.push({ id, where });
  }
  return { modules, testFiles, universe, hyphenOnly, dual };
}

// The committed expectation. EMPTY is the whole point: every hyphenated class
// literal in tooling/grip/*.mjs is named by some test under tooling/grip/test/.
// A new class landing with no test anywhere turns this red and names it.
const EXPECTED_UNCONTROLLED = [];

// What this file itself brought under control. Measured by scanning with THIS
// file excluded from the test corpus — so the row below is the honest "before".
const CONTROLLED_HERE = [
  "TEST-RUNNER",
  "FORGE-API-READ",
  "DEFAULT-CWD-BOUND",
  "TOOL-ERROR",
  "WRITE-FAILED",
  "NOT-A-REF",
  "NO-QUANTITY",
];

test("TRIPWIRE: every hyphenated class literal in tooling/grip/*.mjs is named by some test (dual spelling, globbed)", () => {
  const scan = scanClassCoverage();
  const names = scan.dual.map((row) => `${row.id} (${row.where})`);

  console.log(
    `\n  [class-coverage] ${scan.modules.length} modules globbed, ${scan.testFiles.length} test files read` +
      `, ${scan.universe.size} hyphenated class literals found (LOWER BOUND — see the blind-spot test)` +
      `\n  [class-coverage] uncontrolled under BOTH spellings: ${names.length === 0 ? "none" : names.join(", ")}\n`,
  );

  assert.deepEqual(
    names,
    EXPECTED_UNCONTROLLED,
    "a class literal exists in tooling/grip/*.mjs that no test names under either spelling — write a fail-before control for it, or add it to EXPECTED_UNCONTROLLED with a written reason",
  );
});

test("TRIPWIRE never cries wolf: the hyphen-only method flags five census classes this scan clears", () => {
  // These five ARE controlled — census.test.mjs asserts them as fired outcomes
  // through the UPPER_SNAKE enum key (OUTCOME.TOOL_ERROR …), which is how the
  // module spells them at the call site. The filed hyphen-only scan cannot see
  // that spelling and reports them absent.
  const CRIED_WOLF_ON = ["SCREEN-REFUSED", "ANOMALOUS-SILENCE", "AMBIGUOUS-SILENCE", "UNCLASSIFIED-128", "SKIPPED-TEST-RUNNER"];

  // Scanned with THIS file excluded, so the comparison is the historical one:
  // what the two methods said about the tree BEFORE this file existed.
  const before = scanClassCoverage({ excludeTests: [SELF] });
  const hyphen = before.hyphenOnly.map((r) => r.id);
  const dual = before.dual.map((r) => r.id);

  for (const id of CRIED_WOLF_ON) {
    assert.ok(hyphen.includes(id), `${id} should be flagged by the hyphen-only method (that is the defect being demonstrated)`);
    assert.ok(!dual.includes(id), `${id} is controlled via its UPPER_SNAKE spelling and must NOT be flagged`);
  }
  for (const id of CONTROLLED_HERE) {
    assert.ok(dual.includes(id), `${id} was uncontrolled before this file — if another test now controls it, drop it from CONTROLLED_HERE`);
  }

  console.log(
    `\n  [side by side] hyphen-only (the filed method): ${hyphen.length} flagged — ${hyphen.join(", ")}` +
      `\n  [side by side] dual-spelling (this tripwire):  ${dual.length} flagged — ${dual.join(", ")}` +
      `\n  [side by side] the ${CRIED_WOLF_ON.length} cleared are controlled through the UPPER_SNAKE enum key, not the hyphen string\n`,
  );
});

test("TRIPWIRE declares its own blind spot: it requires a hyphen, so seven known class names are invisible to it", () => {
  const INVISIBLE_BY_CONSTRUCTION = ["ADMITTED", "DEMOTED", "REJECTED", "FAILED", "UNAVAILABLE", "CONFLICT", "UNMINTABLE"];
  const { modules, universe } = scanClassCoverage();

  // NOT VACUOUS: `universe` only ever holds hyphenated ids, so asserting absence
  // alone would pass for any string at all. The load-bearing half is the FIRST
  // assertion — each of these is a REAL class literal that lives in the modules
  // this tripwire scans, and is nonetheless missing from its universe. If a
  // rename ever gives one of them a hyphen, the second assertion goes red and
  // the declaration below must be rewritten; if one is deleted outright, the
  // first goes red and it must be dropped from the list.
  const sources = modules.map((name) => readFileSync(join(GRIP, name), "utf8")).join("\n");
  for (const id of INVISIBLE_BY_CONSTRUCTION) {
    assert.match(
      sources,
      new RegExp(`(["'\`])${id}\\1`),
      `${id} is no longer a string literal in tooling/grip/*.mjs — drop it from the blind-spot declaration`,
    );
    assert.ok(!universe.has(id), `${id} carries a hyphen now — the blind-spot declaration below must be rewritten`);
  }
  console.log(
    `\n  [BLIND SPOT] This tripwire matches hyphenated UPPERCASE string literals ONLY.` +
      ` ${INVISIBLE_BY_CONSTRUCTION.length} known class names — ${INVISIBLE_BY_CONSTRUCTION.join(", ")} —` +
      ` carry no hyphen and are INVISIBLE to it by construction (six of adjudicate.mjs's ten verdicts, plus backfill.mjs's UNMINTABLE).` +
      ` The universe size it prints is a LOWER BOUND, not a census; and mention under test/ is not control.\n`,
  );
});

test("TRIPWIRE is able to fail: a planted class in a scratch copy of the tree is named", () => {
  // The plant's NAME is assembled at runtime and never appears spelled out in
  // any file under test/ — otherwise this very file would "control" it by
  // mention and the plant would come back clean, which is how a tripwire proves
  // itself green without being able to go red.
  const planted = ["PLANTED", "UNCONTROLLED", "CLASS"].join("-");
  const scratch = mkdtempSync(join(tmpdir(), "grip-classcov-plant-"));
  try {
    cpSync(GRIP, join(scratch, "grip"), { recursive: true });
    const src = join(scratch, "grip");
    writeFileSync(join(src, "planted.mjs"), `export const PLANTED = Object.freeze({ NEVER_TESTED: "${planted}" });\n`, "utf8");
    const scan = scanClassCoverage({ srcDir: src, testDir: join(src, "test") });
    const flagged = scan.dual.map((r) => r.id);
    assert.ok(flagged.includes(planted), `the plant was not flagged; scan said ${JSON.stringify(flagged)}`);
    assert.ok(scan.modules.includes("planted.mjs"), "the glob missed a new module — a hand-listed set is exactly how backfill.mjs escaped");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

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
  // The near-miss that matters: `notifications.ex:389-397` IS ref-shaped. Calling
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
  // 29 → 2 and IMPROVED the flagship else-share 4.8% → 0.6% with nothing red.
  // Both halves are pinned here — the name AND its default-ness.
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

// ─────────────────────────────────────────────────────────────────────────────
// (E) THE FIRING REGISTRY — MENTIONED is not FIRED, and the gap is now named
// ─────────────────────────────────────────────────────────────────────────────
//
// Part (A) says it in its own header: "IT MEASURES MENTION, NOT CONTROL. A class
// named anywhere under test/ reads as covered here." That declaration was
// honest and it was also the whole hole. Three classes sat inside it for the
// life of this suite — UNKNOWN-LEVEL (named only by an assertion that it must
// NOT appear in adjudicate.mjs), PROBE-DRIFT (asserted only as an empty array)
// and REASONS (named nowhere at all, and invisible to part (A) anyway because
// it carries no hyphen). Each was a rule that could not go red.
//
// WHAT THIS PART ADDS, AND WHAT IT DELIBERATELY DOES NOT.
//
// It is NOT a framework that infers firing from the shape of an assertion. Every
// textual proxy tried was wrong in one direction or the other: `assert` appears
// in absence assertions too, and a rule id in a test TITLE matched
// "VERDICTS is frozen" for VERDICT. So the claim "test T fires rule R" stays a
// HUMAN claim, written down once per rule, and what is mechanical is the part a
// human gets wrong: that the claim is COMPLETE (every rule the modules can
// return has one) and that it still POINTS AT SOMETHING (the named test exists,
// under that exact title, naming that rule in its body).
//
// The universe is the rules a module can actually RETURN — string literals in
// `reason:` / `kind:` position — which is a smaller and more meaningful set than
// part (A)'s "every SHOUTY literal", and unlike part (A) it does not require a
// hyphen, so REASONS and VERDICT are inside it.
//
// THE LIST THAT MUST STAY EMPTY is `unregistered`. A new rule lands with no
// firing entry and this goes red naming it. There is no exemption list to add
// it to on the way past — the only way through is to write the control, which
// is the point.

/** Rules a grip module can RETURN — a `reason:` or `kind:` string literal. */
const RETURNED_RULE = /\b(?:reason|kind):\s*"([A-Z][A-Z0-9-]{3,})"/g;

/** A top-level `test("…")` declaration, with its title. */
const TEST_TITLE = /^[ \t]*(?:await\s+)?test\s*\(\s*"((?:[^"\\]|\\.)*)"/;

/**
 * scanFiringCoverage({ srcDir, testDir, registry }) →
 *   { universe: Map<rule, "file:line">, unregistered: [], phantoms: [] }
 *
 * `unregistered` — a returnable rule with no firing entry. THE LIST THAT MUST
 * STAY EMPTY.
 * `phantoms` — an entry pointing at a test that does not exist under that title,
 * or one whose body never names the rule. Rot in the other direction.
 *
 * Parameterised over the tree exactly like scanClassCoverage, so a scratch copy
 * can be scanned without editing this file — which is how the plant below proves
 * the tripwire can go red.
 */
export function scanFiringCoverage({ srcDir = GRIP, testDir = join(GRIP, "test"), registry = {} } = {}) {
  const universe = new Map();
  for (const name of readdirSync(srcDir).filter((n) => n.endsWith(".mjs")).sort()) {
    const lines = readFileSync(join(srcDir, name), "utf8").split("\n");
    lines.forEach((line, i) => {
      RETURNED_RULE.lastIndex = 0;
      let m;
      while ((m = RETURNED_RULE.exec(line)) !== null) {
        if (!universe.has(m[1])) universe.set(m[1], `${name}:${i + 1}`);
      }
    });
  }

  // Every test in the suite, sliced from its own declaration to the next one, so
  // "the rule is named in THAT test" is a question about a body and not about
  // the file it happens to share with twenty others.
  const bodies = new Map();
  const duplicates = [];
  for (const name of readdirSync(testDir).filter((n) => n.endsWith(".mjs")).sort()) {
    const lines = readFileSync(join(testDir, name), "utf8").split("\n");
    let title = null;
    let buffer = [];
    const flush = () => {
      if (title === null) return;
      const key = `${name} :: ${title}`;
      if (bodies.has(key)) duplicates.push(key);
      else bodies.set(key, buffer.join("\n"));
    };
    for (const line of lines) {
      const m = TEST_TITLE.exec(line);
      if (m) {
        flush();
        title = m[1];
        buffer = [line];
      } else if (title !== null) buffer.push(line);
    }
    flush();
  }

  const unregistered = [];
  for (const [rule, where] of universe) {
    if (!Object.hasOwn(registry, rule)) unregistered.push({ rule, where });
  }

  const phantoms = [];
  for (const [rule, entry] of Object.entries(registry)) {
    const key = `${entry.file} :: ${entry.test}`;
    const body = bodies.get(key);
    if (body === undefined) phantoms.push({ rule, key, why: "no test under that exact title" });
    else if (!body.includes(rule)) phantoms.push({ rule, key, why: "the named test never names the rule" });
  }

  return { universe, bodies, duplicates, unregistered, phantoms };
}

// THE REGISTRY. One row per rule a grip module can return: the test that makes
// it FIRE on a positive input. Mention does not qualify and neither does an
// absence assertion — the three rows added by this slice (UNKNOWN-LEVEL,
// PROBE-DRIFT, REASONS) exist precisely because those were all that stood.
//
// PROBE-DRIFT is registered although it is NOT in the derived universe: it is
// returned as a populated `probe_drift` array rather than a `kind:` literal, so
// no scan of the returnable set can see it. That invisibility is exactly how it
// went uncontrolled, and the row is here so it cannot go back.
const FIRING_CONTROLS = Object.freeze({
  // acceptance.mjs — the specimen judgements
  "SPECIMEN-COUNT": { file: "acceptance.test.mjs", test: "MUTATION: losing a ratified specimen turns it RED" },
  "NO-EXPECTATION": { file: "acceptance.test.mjs", test: "MUTATION: an unexpected new ratified specimen turns it RED" },
  "NO-SCREEN-EXPECTATION": { file: "acceptance.test.mjs", test: "a ratified specimen with no frozen screen row is a NO-SCREEN-EXPECTATION failure" },
  "SCREEN-DRIFT": { file: "acceptance.test.mjs", test: "MUTATION: a specimen whose rerun is rewritten drifts against the frozen screen" },
  "VERDICT": { file: "acceptance.test.mjs", test: "MUTATION: corrupting a specimen's claimed level turns that specimen RED" },
  "REASONS": { file: "acceptance.test.mjs", test: "REASONS FIRES: a specimen still REJECTED, but for a reason the doctrine did not name" },
  "CAUGHT-BY": { file: "acceptance.test.mjs", test: "MUTATION: relabelling a caught specimen UNCAUGHT turns it RED" },
  "DECLARED-DIVERGENCE": { file: "acceptance.test.mjs", test: "MUTATION: a DECLARED divergence is reported as a finding and keeps the suite green" },
  "UNDECLARED-DIVERGENCE": { file: "acceptance.test.mjs", test: "MUTATION: an UNDECLARED rule divergence turns it RED" },
  "PROBE-DRIFT": { file: "acceptance.test.mjs", test: "PROBE-DRIFT FIRES: a probe moved off its level voids the whole run before any specimen is judged" },

  // level.mjs — the authority grammar
  "UNKNOWN-LEVEL": { file: SELF, test: "UNKNOWN-LEVEL fires on a claim that is not on the ladder, and names the ladder it is off" },
  "LEVEL-SKIP": { file: "level.test.mjs", test: "a claim above the derived level is REJECTED with LEVEL-SKIP naming both levels" },
  "PATHLESS-REF": { file: "level.test.mjs", test: "a path-less line reference is REJECTED with PATHLESS-REF" },
  "NOT-A-REF": { file: SELF, test: "NOT-A-REF fires on a non-reference, and never on a real one" },

  // record.mjs — write-time admission
  "MISSING-SUBJECT": { file: "level.test.mjs", test: "admitFact rejects a subject-less or claim-less record with named reasons" },
  "MISSING-CLAIM": { file: "level.test.mjs", test: "admitFact rejects a subject-less or claim-less record with named reasons" },
  "BAD-DEPS": { file: "ledger.test.mjs", test: "deps must be an array of non-empty subjects (R2), and empty is honest" },
  "INADMISSIBLE-CONTINUOUS": { file: "level.test.mjs", test: "admitFact flags a predicate-less continuous quantity INADMISSIBLE-CONTINUOUS" },

  // mint.mjs — recipe minting
  "NO-RERUN": { file: SELF, test: "NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints" },
  "NO-SUBJECT": { file: SELF, test: "NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints" },
  "NO-QUANTITY": { file: SELF, test: "NO-QUANTITY is REACHABLE: a path swallowed by `cd` mints a subject and no quantity" },

  // ledger.mjs — the store
  "ALREADY-RECORDED": { file: "ledger.test.mjs", test: "the same run written twice is ALREADY-RECORDED — idempotent, and still one file" },
  "UNPARSEABLE": { file: "ledger.test.mjs", test: "an unparseable ledger file is REPORTED, never silently skipped (D6)" },
  "MALFORMED-RUN": { file: "ledger.test.mjs", test: "an unparseable ledger file is REPORTED, never silently skipped (D6)" },
  "NOT-A-RUN": { file: "ledger.test.mjs", test: "a document that never claimed to be a run is NOT-A-RUN, DISTINCT from MALFORMED-RUN, and both stay counted" },
  "MALFORMED-ROW": { file: "ledger.test.mjs", test: "null rows, bare strings and subject-less rows are REPORTED, never merged into one bogus entry" },
});

test("FIRING TRIPWIRE: every rule a grip module can RETURN has a test that makes it fire", () => {
  const scan = scanFiringCoverage({ registry: FIRING_CONTROLS });
  const names = scan.unregistered.map((row) => `${row.rule} (${row.where})`);

  console.log(
    `\n  [firing] ${scan.universe.size} returnable rules found (reason:/kind: literals, hyphen NOT required)` +
      `, ${Object.keys(FIRING_CONTROLS).length} registered firing controls` +
      `\n  [firing] returnable with no FIRING control: ${names.length === 0 ? "none" : names.join(", ")}\n`,
  );

  assert.deepEqual(
    names, [],
    "a grip module can return this rule and no test makes it fire. Mention is not control and an absence " +
      "assertion is not control — write a positive control and register it in FIRING_CONTROLS. There is no " +
      "exemption list: a rule that cannot go red is a gate that cannot go red",
  );
});

test("FIRING TRIPWIRE points at real tests: no registry row is a phantom, and no title is ambiguous", () => {
  const scan = scanFiringCoverage({ registry: FIRING_CONTROLS });

  // The other rot direction. A renamed or deleted control leaves a row that
  // still READS like coverage, which is the same laundering one level up.
  assert.deepEqual(
    scan.phantoms, [],
    "a FIRING_CONTROLS row no longer points at a test that names its rule — the control was renamed or deleted",
  );

  // Bodies are sliced by title, so a duplicated title inside one file would make
  // the body lookup ambiguous and the phantom check quietly weaker.
  assert.deepEqual(scan.duplicates, [], "two tests share a title inside one file — the firing scan slices bodies by title");

  // NOT VACUOUS: the registry is non-empty and covers more than one module.
  assert.ok(Object.keys(FIRING_CONTROLS).length >= 20, "the registry lost rows without the tripwire noticing");
  assert.ok(new Set(Object.values(FIRING_CONTROLS).map((e) => e.file)).size >= 4);
});

test("FIRING TRIPWIRE is able to fail: a planted rule with a MENTION-ONLY test is flagged, while part (A) clears it", () => {
  // THE DISCRIMINATION, demonstrated rather than asserted in prose. The plant is
  // a module that RETURNS a new rule, plus a test file that names the rule in an
  // absence assertion — exactly the shape UNKNOWN-LEVEL had. Part (A) sees a
  // mention and reports the class controlled. Part (E) sees no firing control
  // and reports it uncontrolled. Both scans, one tree, opposite answers.
  const planted = ["PLANTED", "MENTION", "ONLY"].join("-");
  const scratch = mkdtempSync(join(tmpdir(), "grip-firing-plant-"));
  try {
    cpSync(GRIP, join(scratch, "grip"), { recursive: true });
    const src = join(scratch, "grip");
    writeFileSync(join(src, "planted.mjs"), `export const plantedRule = () => ({ ok: false, reason: "${planted}" });\n`, "utf8");
    // The mention-only test: it names the rule and asserts it is ABSENT, which is
    // green whether the rule works or was deleted.
    writeFileSync(
      join(src, "test", "planted.test.mjs"),
      `import { test } from "node:test";\nimport assert from "node:assert/strict";\n` +
        `test("the planted rule is not restated elsewhere", () => {\n` +
        `  assert.equal("nothing".includes("${planted}"), false);\n});\n`,
      "utf8",
    );

    const mention = scanClassCoverage({ srcDir: src, testDir: join(src, "test") });
    assert.ok(mention.universe.has(planted), "the mention scan must see the planted rule at all");
    assert.equal(mention.dual.some((r) => r.id === planted), false,
      "part (A) is expected to CLEAR the plant — it is mentioned, and mention is all that scan measures");

    const firing = scanFiringCoverage({ srcDir: src, testDir: join(src, "test"), registry: FIRING_CONTROLS });
    assert.ok(firing.universe.has(planted), "the firing scan must see the planted rule");
    assert.deepEqual(
      firing.unregistered.map((r) => r.rule), [planted],
      "the plant must be the one and only rule with no firing control — and the ONLY one, or the shipped tree is already leaking",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
