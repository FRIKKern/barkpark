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

import { classifyRef } from "../level.mjs";
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
  const { universe } = scanClassCoverage();
  for (const id of INVISIBLE_BY_CONSTRUCTION) {
    assert.ok(!universe.has(id), `${id} is now hyphen-free no longer — the blind-spot declaration below must be rewritten`);
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
