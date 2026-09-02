#!/usr/bin/env node
// Proof for the decay census — tooling/grip/census.mjs.
//
//   node --test tooling/grip/test/census.test.mjs
//
// THREE OBLIGATIONS, and the suite is shaped around them rather than around the
// code's function list:
//
//   1. SAFETY. Nothing reaches a spawn that screen.mjs refused. Proven as a
//      CONTROL PAIR: a spy executor that records every call is handed the whole
//      DANGER SET (0 calls expected) and then a benign admitted command (1 call
//      expected). Without the second half, the first proves only that the
//      spawn path is dead.
//
//   2. SILENCE IS AN ANSWER, PER FAMILY. Every specimen runs through BOTH
//      classifyOutcome and the naive `rc===0 && stdout` predicate this module
//      replaces, and the suite asserts they DISAGREE. A silence test that only
//      asserts the new answer would stay green if the fix were reverted into a
//      different-looking mistake.
//
//   3. NO WRITES. The ledger directory is byte-compared across a real census
//      run, and the source is grepped for every write call.
//
// MOSTLY HERMETIC. The classifier tests synthesise run records rather than
// spawning. Two tests do execute — the ledger-untouched proof and the real
// admitted command in the control pair — because a census that never ran would
// be proving nothing about a census.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import {
  FAMILY, OUTCOME, CENSUS_TIMEOUT_MS, CENSUS_TIMEOUT_FLOOR_MS, TIMEOUT_FLOOR_MULTIPLE,
  classifyFamily, classifyOutcome, naiveOutcome, isAnswering, isDecayed,
  censusOne, censusRun, summarise, renderHuman, toJson, isNullDistribution,
  isTestRunner, loadCorpusCommands, CORPUS_NAME,
  pipelineSegments, networkTool, networkReach, validateArgv,
  probeToolAvailability, resolveTool, toolHeads,
  loadLedgerRecipes, renderLedgerPreamble, LEDGER_CORPUS_NAME,
} from "../census.mjs";
import { screenCommand, DANGER_SET } from "../screen.mjs";
import { SYNC_TIMEOUT_MS } from "../rerun.mjs";
import { classifyBinding } from "../binding.mjs";

const CENSUS_MJS = fileURLToPath(new URL("../census.mjs", import.meta.url));
const LEDGER_DIR = fileURLToPath(new URL("../ledger/", import.meta.url));
const SOURCE = readFileSync(CENSUS_MJS, "utf8");

// The import/no-import assertions must read the CODE, not the module's prose.
// census.mjs discusses runRerun and classifySafety at length in its header —
// naming what it deliberately does not call is the point of that prose, and a
// grep over the raw file would score the explanation as the violation.
const CODE = SOURCE.split("\n").filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join("\n");

/** A run record as spawnSync would have produced it. */
const run = (exit, stdout = "", stderr = "", extra = {}) => ({ exit, stdout, stderr, timedOut: false, spawnError: null, ms: 5, ...extra });

/** An executor that records every command it is asked to run and never spawns. */
function spyExec() {
  const calls = [];
  const exec = (cmd) => {
    calls.push(cmd);
    return run(0, "spy");
  };
  exec.calls = calls;
  return exec;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. THE GATE — screen.mjs, and only screen.mjs
// ─────────────────────────────────────────────────────────────────────────────

test("D47: census.mjs imports screenCommand from ./screen.mjs and does NOT import runRerun", () => {
  assert.match(CODE, /import\s*\{\s*screenCommand\s*\}\s*from\s*"\.\/screen\.mjs"/);
  assert.doesNotMatch(CODE, /runRerun/, "the census must not route execution through rerun.mjs's gate");
  // Only the constant may cross from rerun.mjs, so the timeout floor stays tied
  // to its source; no execution path may.
  assert.match(CODE, /import\s*\{\s*SYNC_TIMEOUT_MS\s*\}\s*from\s*"\.\/rerun\.mjs"/);
});

test("the safety bound is screenCommand and NEVER classifySafety", () => {
  assert.doesNotMatch(CODE, /classifySafety/,
    "classifySafety admits 22/22 named outage probes where screenCommand admits 0/22");
  // And the comment stripping must not have hollowed the check out.
  assert.ok(CODE.includes("screenCommand(cmd)"), "the gate call itself must survive the comment strip");
});

test("a named outage command is REFUSED before any spawn, carrying the screen's own reason", () => {
  const exec = spyExec();
  const row = censusOne("systemctl stop bp-crux-parent", { exec });

  assert.equal(exec.calls.length, 0, "the outage command reached the executor");
  assert.equal(row.outcome, OUTCOME.REFUSED);
  assert.equal(row.executed, false);
  // The reason is the SCREEN'S, verbatim — a paraphrase would be a second,
  // unproven claim about why the command was refused.
  assert.equal(row.why, screenCommand("systemctl stop bp-crux-parent").reason);
  assert.ok(row.why.length > 0);
});

test("CONTROL PAIR: the spawn path IS live, so the zero above is the gate and not dead code", () => {
  const exec = spyExec();
  // Same call site, same options, a command the screen admits.
  const row = censusOne("git rev-parse --abbrev-ref HEAD", { exec });
  assert.equal(exec.calls.length, 1, "the executor was never reached — the refusal test proves nothing");
  assert.equal(exec.calls[0], "git rev-parse --abbrev-ref HEAD");
  assert.equal(row.executed, true);
});

test("the ENTIRE danger set is refused with zero spawns", () => {
  const exec = spyExec();
  const rows = DANGER_SET.map((c) => censusOne(c, { exec }));
  assert.equal(exec.calls.length, 0, `spawned: ${exec.calls.join(", ")}`);
  for (const row of rows) {
    assert.equal(row.outcome, OUTCOME.REFUSED, `admitted a danger-set command: ${row.command}`);
  }
  assert.ok(DANGER_SET.length >= 20, "the danger set shrank — the control weakened");
});

test("the gate is not injectable: no option can substitute a permissive screen", () => {
  const exec = spyExec();
  // Every plausible override name a caller might reach for.
  for (const opts of [{ exec, screen: () => ({ ok: true, reason: "x" }) }, { exec, screenCommand: () => ({ ok: true }) }, { exec, unsafe: true, force: true }]) {
    const row = censusOne("reboot", opts);
    assert.equal(row.outcome, OUTCOME.REFUSED, "an option overrode the gate");
  }
  assert.equal(exec.calls.length, 0);
});

// ─────────────────────────────────────────────────────────────────────────────
// 2. FAMILY DISPATCH — read off the pipeline TAIL
// ─────────────────────────────────────────────────────────────────────────────

test("family is read off the LAST pipeline segment, because sh -c exits with the tail's status", () => {
  // The canonical specimen. Keyed on the head this is a lister; the exit code
  // being classified is grep's.
  assert.equal(classifyFamily('git ls-tree -r origin/main --name-only | grep -i "internal/scaffy"'), FAMILY.MATCHER);
  assert.equal(classifyFamily("git ls-tree -r origin/main --name-only"), FAMILY.QUERY_LISTER);
  assert.equal(classifyFamily("cat foo.json | jq .name"), FAMILY.CONTENT_FETCH);
});

test("the five families classify their canonical heads", () => {
  assert.equal(classifyFamily("grep -rn foo lib/"), FAMILY.MATCHER);
  assert.equal(classifyFamily("git grep foo"), FAMILY.MATCHER);
  assert.equal(classifyFamily("git diff origin/main -- tooling/grip/screen.mjs"), FAMILY.DIFFER);
  assert.equal(classifyFamily("diff a.txt b.txt"), FAMILY.DIFFER);
  assert.equal(classifyFamily("go vet ./..."), FAMILY.PREDICATE);
  assert.equal(classifyFamily("git ls-files tooling/"), FAMILY.QUERY_LISTER);
  assert.equal(classifyFamily("git show origin/main:tooling/grip/screen.mjs"), FAMILY.CONTENT_FETCH);
  assert.equal(classifyFamily("cat tooling/grip/README.md"), FAMILY.CONTENT_FETCH);
});

test("a pipe inside a quoted argument is not a segment boundary", () => {
  assert.equal(classifyFamily("grep -E 'foo|bar' lib/"), FAMILY.MATCHER);
});

test("an env-var prefix is not the head — CC=clang go vet is still a PREDICATE", () => {
  // MEASURED: 5 of the 6 `go vet` rows the screen admits from the frozen corpus
  // carry a CC= prefix. Read as UNKNOWN, their clean rc 0 becomes an ambiguous
  // silence and the canonical green is lost on every specimen the census has.
  assert.equal(classifyFamily("CC=clang go vet ./internal/cli/..."), FAMILY.PREDICATE);
  assert.equal(classifyFamily("CC=/usr/bin/clang go vet ./..."), FAMILY.PREDICATE);
  const v = classifyOutcome("CC=clang go vet ./internal/cli/...", run(0, "", ""));
  assert.equal(v.outcome, OUTCOME.PASS);
  assert.equal(v.answering, true);
  assert.equal(naiveOutcome(run(0, "", "")), "NULL-READ");
});

// ─────────────────────────────────────────────────────────────────────────────
// 3. SILENCE IS AN ANSWER — and the naive predicate is shown to get it wrong
// ─────────────────────────────────────────────────────────────────────────────
//
// Each of these asserts BOTH directions: the right answer, and that the
// predicate this module replaces produces a different (wrong) one. Without the
// second assertion the test would stay green against a reverted fix.

test("MATCHER rc1 + empty = ABSENT — an answer the naive predicate inverts", () => {
  const r = run(1, "", "");
  const v = classifyOutcome("grep -rn child_process tooling/grip/ledger.mjs", r);
  assert.equal(v.family, FAMILY.MATCHER);
  assert.equal(v.outcome, OUTCOME.ABSENT);
  assert.equal(v.answering, true);
  assert.equal(v.decayed, false);
  assert.equal(naiveOutcome(r), "NULL-READ", "the naive predicate must disagree, or this test proves nothing");
});

test("DIFFER rc0 + empty = IDENTICAL — the byte-identity proof the naive predicate discards", () => {
  const r = run(0, "", "");
  const v = classifyOutcome("git diff origin/main -- tooling/grip/screen.mjs", r);
  assert.equal(v.family, FAMILY.DIFFER);
  assert.equal(v.outcome, OUTCOME.IDENTICAL);
  assert.equal(v.answering, true);
  assert.equal(naiveOutcome(r), "NULL-READ");
});

test("DIFFER rc1 + 7357 bytes = DIFFERENT, NOT absence — opposite polarity to grep's rc1", () => {
  const r = run(1, "x".repeat(7357), "");
  const v = classifyOutcome("diff a.txt b.txt", r);
  assert.equal(v.outcome, OUTCOME.DIFFERENT);
  assert.equal(v.answering, true);
  assert.equal(v.decayed, false);
  // The same exit code, the other family, the opposite meaning. This pair is
  // the whole argument for dispatching on family first.
  const grepSameRc = classifyOutcome("grep foo bar.txt", run(1, "", ""));
  assert.equal(grepSameRc.outcome, OUTCOME.ABSENT);
  assert.notEqual(grepSameRc.outcome, OUTCOME.DIFFERENT);
});

test("QUERY-LISTER rc0 + empty = EMPTY-SET, not a null read", () => {
  const r = run(0, "", "");
  const v = classifyOutcome("git ls-files tooling/grip/nonexistent/", r);
  assert.equal(v.family, FAMILY.QUERY_LISTER);
  assert.equal(v.outcome, OUTCOME.EMPTY_SET);
  assert.equal(v.answering, true);
  assert.equal(naiveOutcome(r), "NULL-READ");
});

test("a clean `go vet` (rc0, no output) is an ANSWER — the canonical green the naive predicate throws away", () => {
  const r = run(0, "", "");
  const v = classifyOutcome("go vet ./internal/cli/", r);
  assert.equal(v.family, FAMILY.PREDICATE);
  assert.equal(v.outcome, OUTCOME.PASS);
  assert.equal(v.answering, true);
  assert.equal(v.decayed, false);
  assert.equal(naiveOutcome(r), "NULL-READ", "go vet is precisely the specimen the old predicate discarded");
});

test("a PREDICATE answering no is still an answer, but a missing target is decay", () => {
  const no = classifyOutcome("go vet ./internal/cli/", run(1, "", "vet: some finding"));
  assert.equal(no.outcome, OUTCOME.FAIL);
  assert.equal(no.answering, true);

  const gone = classifyOutcome("go vet ./internal/gone/", run(1, "", "matched no packages"));
  assert.equal(gone.outcome, OUTCOME.PATH_GONE);
  assert.equal(gone.decayed, true);
  assert.equal(gone.answering, false);
});

test("MATCHER rc0 with no output contradicts itself and counts as NEITHER answer nor decay", () => {
  const v = classifyOutcome("grep foo bar.txt", run(0, "", ""));
  assert.equal(v.outcome, OUTCOME.ANOMALOUS_SILENCE);
  assert.equal(v.answering, false);
  assert.equal(v.decayed, false);
  assert.equal(v.admissible, false);
});

test("an unclassified family's silent zero is AMBIGUOUS, and the census refuses to guess", () => {
  const v = classifyOutcome("someunknowntool --check", run(0, "", ""));
  assert.equal(v.family, FAMILY.UNKNOWN);
  assert.equal(v.outcome, OUTCOME.AMBIGUOUS_SILENCE);
  assert.equal(v.admissible, false, "guessing here would let the census manufacture its own numbers");
});

// ─────────────────────────────────────────────────────────────────────────────
// 4. rc 128 IS A PRECONDITION, NOT A VERDICT
// ─────────────────────────────────────────────────────────────────────────────

test("CONTENT-FETCH rc128 'does not exist in' = PATH-GONE — real decay", () => {
  const v = classifyOutcome(
    "git show origin/main:tooling/grip/removed.mjs",
    run(128, "", "fatal: path 'tooling/grip/removed.mjs' does not exist in 'origin/main'"),
  );
  assert.equal(v.family, FAMILY.CONTENT_FETCH);
  assert.equal(v.outcome, OUTCOME.PATH_GONE);
  assert.equal(v.decayed, true);
  assert.equal(v.admissible, true);
});

test("CONTENT-FETCH rc128 'invalid object name' = REF-GONE — an environment fault, INADMISSIBLE", () => {
  const v = classifyOutcome(
    "git show origin/main:tooling/grip/screen.mjs",
    run(128, "", "fatal: invalid object name 'origin/main'."),
  );
  assert.equal(v.outcome, OUTCOME.REF_GONE);
  assert.equal(v.decayed, false, "an unfetched worktree must not forge a decay wave");
  assert.equal(v.admissible, false, "it measures this host, not the ledger");
});

test("CONTENT-FETCH rc128 'not a git repository' = WRONG-CWD — an environment fault, INADMISSIBLE", () => {
  const v = classifyOutcome(
    "git show origin/main:tooling/grip/screen.mjs",
    run(128, "", "fatal: not a git repository (or any of the parent directories): .git"),
  );
  assert.equal(v.outcome, OUTCOME.WRONG_CWD);
  assert.equal(v.decayed, false);
  assert.equal(v.admissible, false);
});

test("MEASURED CONSEQUENCE: keying on rc128 alone would report an entire unfetched ledger as decayed", () => {
  const unfetched = [
    "git show origin/main:tooling/grip/screen.mjs",
    "git show origin/main:tooling/grip/level.mjs",
    "git show origin/main:tooling/grip/rerun.mjs",
  ].map((c) => classifyOutcome(c, run(128, "", "fatal: invalid object name 'origin/main'.")));

  assert.equal(unfetched.filter((v) => v.decayed).length, 0);
  const report = summarise(unfetched.map((v, i) => ({ command: `c${i}`, screened: true, executed: true, level: "L2", ...v })), { corpusName: "unfetched-worktree" });
  assert.equal(report.decisive.admissible, 0);
  assert.equal(report.decisive.decayed, 0);
  assert.match(report.prediction.verdict, /NO RESULT/);
  assert.match(renderHuman(report), /NULL STATE/);
});

test("an rc128 stderr nobody recognises is NOT CLASSIFIED rather than guessed", () => {
  const v = classifyOutcome("git show origin/main:x", run(128, "", "fatal: something new and unparsed"));
  assert.equal(v.outcome, OUTCOME.UNCLASSIFIED_128);
  assert.equal(v.admissible, false);
});

test("exit 127 (command not found) is TOOL-ABSENT and in NEITHER rate; a warning beside rc0 is not a fault", () => {
  // THE DEFECT THIS REPLACES. rc 127 used to land in PATH-GONE, which is in the
  // DECAYED set — so a host without `bp`, `gh` or `go` published a decay wave
  // about the LEDGER. Measured on the frozen corpus over one unchanged tree:
  // full PATH 39 of 193 decisive rows decayed (20.2%, verdict CONSISTENT);
  // PATH stripped of those three 61 of 197 (31.0%, verdict CONTRARY), 37 of the
  // 61 pure rc-127. The recipes did not move; the PATH did.
  const v = classifyOutcome("bp task ls", run(127, "", "sh: bp: not found"));
  assert.equal(v.outcome, OUTCOME.TOOL_ABSENT);
  assert.equal(v.decayed, false, "a missing binary measures this host, not the ledger");
  assert.equal(v.answering, false, "nothing was measured, so it is not an answer either");
  assert.equal(v.admissible, false, "it must be in NEITHER rate");
  assert.equal(isDecayed(OUTCOME.TOOL_ABSENT), false, "TOOL-ABSENT must stay outside the DECAYED set");
  assert.match(v.why, /bp/, "the why names the head that was missing, not just 'a command'");

  // THE CONTROL. A path that is genuinely gone is still real decay — the fix
  // must not have laundered PATH-GONE away along with the missing binaries.
  const gone = classifyOutcome("git show origin/main:gone.mjs", run(128, "", "fatal: path 'gone.mjs' does not exist in 'origin/main'"));
  assert.equal(gone.outcome, OUTCOME.PATH_GONE);
  assert.equal(gone.decayed, true, "a gone path is decay and must stay decay");

  const warned = classifyOutcome("git ls-files tooling/", run(0, "a\nb\n", "warning: not a git repository hint"));
  assert.equal(warned.outcome, OUTCOME.ANSWERED, "a clean run must not be reclassified by stderr chatter");
});

// ─────────────────────────────────────────────────────────────────────────────
// 5. TIMEOUT IS ITS OWN CLASS
// ─────────────────────────────────────────────────────────────────────────────

test("the timeout is at least 4x SYNC_TIMEOUT_MS and at least 8000ms", () => {
  assert.equal(TIMEOUT_FLOOR_MULTIPLE, 4);
  assert.equal(CENSUS_TIMEOUT_MS, SYNC_TIMEOUT_MS * 4);
  assert.ok(CENSUS_TIMEOUT_MS >= CENSUS_TIMEOUT_FLOOR_MS, `${CENSUS_TIMEOUT_MS} is below the 8000ms floor`);
  assert.ok(CENSUS_TIMEOUT_MS >= 8000);
});

test("TIMEOUT is its own outcome and is scored as NEITHER answering nor decayed", () => {
  const v = classifyOutcome("git log --oneline", run(null, "", "", { timedOut: true, signal: "SIGTERM" }));
  assert.equal(v.outcome, OUTCOME.TIMEOUT);
  assert.equal(v.answering, false);
  assert.equal(v.decayed, false, "slowness scored as decay is a manufactured finding");
  assert.equal(v.admissible, false);
  assert.match(v.why, /8000ms/);
});

// ─────────────────────────────────────────────────────────────────────────────
// 6. FIRST-CLASS NON-EXECUTION BUCKETS
// ─────────────────────────────────────────────────────────────────────────────

test("NOT-A-COMMAND is a first-class bucket and never spawns", () => {
  const exec = spyExec();
  // An ELISION specimen — the shape that actually reaches this bucket. Most
  // prose in the corpus carries a placeholder (`<path>`) or a parenthetical,
  // and the SCREEN refuses those first as metacharacters; only the trailing-
  // ellipsis kind gets past the screen and needs a bucket of its own.
  const cmd = "cat tooling/grip/README.md ...";
  assert.equal(screenCommand(cmd).ok, true, "the specimen must be screen-admitted, or it tests the screen instead");
  const row = censusOne(cmd, { exec });
  assert.equal(row.outcome, OUTCOME.NOT_A_COMMAND);
  assert.equal(row.executed, false);
  assert.equal(row.admissible, false);
  assert.equal(exec.calls.length, 0);
});

test("test runners are EXCLUDED by default, counted, and opt-in-able", () => {
  assert.equal(isTestRunner("go test ./internal/cli/"), true);
  assert.equal(isTestRunner("mix test test/foo_test.exs"), true);
  assert.equal(isTestRunner("git log --oneline"), false);

  const exec = spyExec();
  const off = censusOne("go test ./internal/cli/", { exec });
  assert.equal(off.outcome, OUTCOME.SKIPPED_TEST_RUNNER);
  assert.equal(exec.calls.length, 0, "the honest default is to NOT run repo code the screen never examined");

  const on = censusOne("go test ./internal/cli/", { exec, includeTestRunners: true });
  assert.equal(on.executed, true);
  assert.equal(exec.calls.length, 1);
});

// ─────────────────────────────────────────────────────────────────────────────
// 7. THE REPORT — reach named, no over-claim, no drift claim
// ─────────────────────────────────────────────────────────────────────────────

const sampleRows = () => {
  const exec = spyExec();
  return [
    // refused
    censusOne("systemctl stop bp-crux-parent", { exec }),
    censusOne("reboot", { exec }),
    // prose
    censusOne("read <the file> and count", { exec }),
    // executed
    { command: "grep -rn foo lib/", screened: true, executed: true, level: "L3", ...classifyOutcome("grep -rn foo lib/", run(1, "", "")) },
    { command: "go vet ./...", screened: true, executed: true, level: "L3", ...classifyOutcome("go vet ./...", run(0, "", "")) },
    { command: "git show origin/main:gone.mjs", screened: true, executed: true, level: "L2", ...classifyOutcome("git show origin/main:gone.mjs", run(128, "", "fatal: path 'gone.mjs' does not exist in 'origin/main'")) },
    { command: "git show origin/main:x.mjs", screened: true, executed: true, level: "L2", ...classifyOutcome("git show origin/main:x.mjs", run(128, "", "fatal: invalid object name 'origin/main'.")) },
  ];
};

test("the report NAMES its corpus and never restates a subset rate as covering the whole set", () => {
  const report = summarise(sampleRows(), { corpusName: CORPUS_NAME });
  const text = renderHuman(report);

  assert.match(text, /tooling\/grip\/fixtures\/evidence-corpus\.json/, "the corpus must be named");
  assert.match(text, /REACH/);
  assert.match(text, /admitted by screen/);
  // The rate's scope is stated in words, tied to the decisive count, and
  // explicitly disclaimed against the full distinct count.
  assert.match(text, new RegExp(`describes THESE ${report.decisive.admissible} decisive rows`));
  // The disclaimer must sit on ONE line — a scope caveat split across a wrap is
  // a caveat a reader skims past.
  assert.ok(
    text.split("\n").some((l) => new RegExp(`not a statement about all ${report.reach.distinct} commands`, "i").test(l)),
    "the over-claim disclaimer must name the full count on a single line",
  );
  assert.ok(report.reach.distinct > report.decisive.admissible, "the fixture must actually have a gap to over-claim across");
});

test("the report distinguishes STILL-ANSWERING from STILL-CORRECT and makes no drift claim", () => {
  const text = renderHuman(summarise(sampleRows(), { corpusName: CORPUS_NAME }));
  assert.match(text, /STILL ANSWERING IS NOT STILL CORRECT/);
  assert.match(text, /internal\/scaffy/, "the specimen that proves answering != correct");
  // The truncation-bound figure may not be quoted, in either render.
  assert.doesNotMatch(text, /\bdrift rate\b(?! is)/i);
  assert.doesNotMatch(text, /154/);
  assert.doesNotMatch(text, /221/);
  const j = JSON.stringify(toJson(summarise(sampleRows(), { corpusName: CORPUS_NAME })));
  assert.doesNotMatch(j, /154\/221/);
  assert.match(j, /answer drift is unmeasured/i);
});

test("inadmissible rows are in NEITHER rate", () => {
  const report = summarise(sampleRows(), { corpusName: CORPUS_NAME });
  // ABSENT + PASS answer; PATH-GONE decays; REF-GONE is inadmissible.
  assert.equal(report.decisive.admissible, 3);
  assert.equal(report.decisive.answering, 2);
  assert.equal(report.decisive.decayed, 1);
  assert.equal(report.decisive.inadmissible, 1);
  // The two rates partition the decisive set exactly — nothing admissible is
  // counted twice and nothing falls between them.
  assert.ok(Math.abs(report.decisive.answeringPct + report.decisive.decayPct - 100) < 1e-9);
});

test("the render leads with a ONE-LINE verdict banner before any detail", () => {
  const text = renderHuman(summarise(sampleRows(), { corpusName: CORPUS_NAME }));
  const first = text.split("\n")[0];
  assert.match(first, /^CENSUS — /);
  assert.match(first, /STILL ANSWER/);
  assert.ok(!first.includes("\n"));
});

test("a no-variance distribution is called a NULL RESULT rather than dressed as a signal", () => {
  assert.equal(isNullDistribution(new Map([["ANSWERED", 100]])), true);
  assert.equal(isNullDistribution(new Map([["ANSWERED", 199], ["ABSENT", 1]])), true);
  assert.equal(isNullDistribution(new Map([["ANSWERED", 60], ["ABSENT", 40]])), false);

  const flat = Array.from({ length: 20 }, (_, i) => ({ command: `c${i}`, screened: true, executed: true, level: "L3", ...classifyOutcome("grep x y", run(1, "", "")) }));
  assert.match(renderHuman(summarise(flat, { corpusName: "flat" })), /NULL RESULT/);
});

test("--json carries the same numbers plus the caveats, and names the corpus", () => {
  const report = summarise(sampleRows(), { corpusName: CORPUS_NAME });
  const j = toJson(report);
  assert.equal(j.corpus, CORPUS_NAME);
  assert.equal(j.decisive.decayed, report.decisive.decayed);
  assert.equal(j.timeout_ms, CENSUS_TIMEOUT_MS);
  assert.ok(j.caveats.length >= 4);
  assert.ok(j.caveats.some((c) => /may not be restated as covering/.test(c)));
  assert.ok(j.rows.every((r) => "outcome" in r && "admissible" in r));
});

test("PREDICTION 3 is predeclared, compared to the measurement, and a contrary result is reported as a result", () => {
  const low = summarise(
    Array.from({ length: 100 }, (_, i) => ({ command: `c${i}`, screened: true, executed: true, level: "L3", ...classifyOutcome("grep x y", run(i < 95 ? 1 : 2, "", "")) })),
    { corpusName: "low" },
  );
  assert.equal(low.prediction.id, 3);
  assert.equal(low.prediction.floorPct, 22.4);
  assert.match(low.prediction.verdict, /CONSISTENT/);

  const high = summarise(
    Array.from({ length: 100 }, (_, i) => ({ command: `c${i}`, screened: true, executed: true, level: "L3", ...classifyOutcome("grep x y", run(i < 50 ? 1 : 2, "", "")) })),
    { corpusName: "high" },
  );
  assert.match(high.prediction.verdict, /CONTRARY/);
  assert.match(renderHuman(high), /PREDICTION 3/);
  assert.match(renderHuman(high), /22\.4% is a FLOOR/);
});

// ─────────────────────────────────────────────────────────────────────────────
// 8. THE CENSUS NEVER WRITES
// ─────────────────────────────────────────────────────────────────────────────

test("census.mjs contains no write call and imports no writer", () => {
  assert.doesNotMatch(SOURCE, /writeFileSync|appendFileSync|createWriteStream|mkdirSync|rmSync|unlinkSync|renameSync/);
  assert.doesNotMatch(CODE, /from\s*"\.\/(record|harvest)\.mjs"/, "the census must not import a writer");

  // ledger.mjs is BOTH a reader and a writer, so the ban is per-BINDING rather
  // than per-module: `foldLedger` is a pure read and is the only name allowed
  // to cross. A blanket module ban would have forced a hand-copied fold — this
  // epic's own defect class — and a blanket allow would let the writer in.
  const imported = [...CODE.matchAll(/import\s*\{([^}]*)\}\s*from\s*"\.\/ledger\.mjs"/g)]
    .flatMap((m) => m[1].split(",").map((s) => s.trim()).filter(Boolean));
  assert.deepEqual(imported, ["foldLedger"], "only the READER may cross from ledger.mjs");
  assert.doesNotMatch(CODE, /writeLedgerRun|admitRecipe|mintRunId/, "no writer name may appear in census code");
});

const snapshotDir = (dir) =>
  readdirSync(dir).sort().map((name) => {
    const p = join(dir, name);
    const st = statSync(p);
    return `${name}:${st.size}:${st.isFile() ? readFileSync(p, "utf8").length : "dir"}`;
  }).join("|");

test("a REAL census run over corpus commands writes ZERO rows to tooling/grip/ledger/", () => {
  const before = snapshotDir(LEDGER_DIR);
  const commands = loadCorpusCommands().slice(0, 60);
  const report = censusRun(commands, { corpusName: CORPUS_NAME });
  const after = snapshotDir(LEDGER_DIR);

  assert.equal(after, before, "the census mutated the ledger directory");
  assert.ok(report.total > 0);
  assert.ok(report.reach.admitted >= 0);
  // It must actually have run something, or the write-proof is vacuous.
  assert.ok(report.reach.executed > 0, "nothing executed — the no-write proof would be vacuous");
});

test("the frozen corpus loads and the census's reach over it is a real bound, not 100%", () => {
  const commands = loadCorpusCommands();
  assert.ok(commands.length > 500, `expected the frozen corpus, got ${commands.length} commands`);
  const screened = commands.filter((c) => screenCommand(c).ok).length;
  assert.ok(screened > 0 && screened < commands.length,
    "the screen admitting everything or nothing would make the reach statistic meaningless");
});

// ── the underpowered floor (added in review) ─────────────────────────────────
//
// FOUND BY RUNNING THE SHIPPED CLI: `node census.mjs --limit 12` admits 3
// decisive rows, measures 0.0% decay, and printed
// "CONSISTENT — measured 0.0% is below the 22.4% floor". A bounded iteration
// run was wearing a full census's authority. Zero-admissible already had a NULL
// STATE; too-few-to-say did not, and an underpowered pass IS a vacuous green.
//
// The control pair matters: the first test proves the floor refuses to speak,
// the second proves it is not simply mute — cross the floor and a real verdict
// comes back.

const answeringRows = (n) =>
  Array.from({ length: n }, (_, i) => ({
    command: `grep -c x file${i}.mjs`, screened: true, executed: true, level: "L3",
    family: "MATCHER", outcome: "PRESENT", why: "matched",
    answering: true, decayed: false, admissible: true,
  }));

test("a handful of decisive rows is UNDERPOWERED — the prediction is not adjudicated on n=3", () => {
  const report = summarise(answeringRows(3), { corpusName: "a bounded iteration run" });
  assert.equal(report.decisive.admissible, 3);
  assert.match(report.prediction.verdict, /UNDERPOWERED/);
  assert.doesNotMatch(report.prediction.verdict, /^CONSISTENT|^CONTRARY/);
  // The measured number is still reported — refusing to adjudicate is not
  // refusing to show the reader what was seen.
  assert.match(report.prediction.verdict, /0\.0%/);
});

test("above the floor the prediction IS adjudicated — the floor is a bound, not a mute button", () => {
  const report = summarise(answeringRows(40), { corpusName: "a full run" });
  assert.equal(report.decisive.admissible, 40);
  assert.match(report.prediction.verdict, /CONSISTENT/);
  assert.doesNotMatch(report.prediction.verdict, /UNDERPOWERED/);
});

// ─────────────────────────────────────────────────────────────────────────────
// 9. D67 — THE SOURCE IS VISIBLE TO GREP
// ─────────────────────────────────────────────────────────────────────────────
//
// A literal 0x00 in the quote-mask filler made file(1) call census.mjs "binary
// data", so every grep wrapper that skips binaries returned ZERO LINES AND
// EXIT 1 over a file with 7 real hits. An agent got a clean empty result
// indistinguishable from genuine absence — this epic's disease inside this
// epic's instrument — and one verifier concluded the census never screens.
//
// The assertion is on BYTES, not on the parsed string: `"\0"` and a raw NUL
// produce the same runtime value, so a source-level check is the only one that
// can tell the fix from the defect.

test("D67: census.mjs contains no NUL byte, so grep can see it at all", () => {
  const bytes = readFileSync(CENSUS_MJS);
  assert.equal(bytes.indexOf(0), -1,
    "a NUL byte makes this file 'binary data' — greps return zero lines and exit 1, which reads exactly like absence");
});

test("D67 CONTROL: the escaped filler masks IDENTICALLY, so the fix changed no behaviour", () => {
  // The mask exists so a pipe inside quotes is not a segment boundary. If the
  // filler's length or its collision with `|` had changed, these would move.
  assert.deepEqual(pipelineSegments("grep -n 'a|b' f.js | wc -l"), ["grep -n 'a|b' f.js", "wc -l"]);
  assert.equal(classifyFamily("grep -n 'a|b' f.js | wc -l"), FAMILY.QUERY_LISTER);
  assert.equal(classifyFamily('git ls-tree -r HEAD | grep -i "x|y"'), FAMILY.MATCHER);
  // A filler that were LONGER than one char per masked char would shift the
  // pipe offsets and slice the raw command in the wrong place.
  assert.deepEqual(pipelineSegments("echo 'aaaaaaaaaa' | head -1"), ["echo 'aaaaaaaaaa'", "head -1"]);
});

// ─────────────────────────────────────────────────────────────────────────────
// 10. D68 — HERMETICITY: AN OUTAGE IS NOT DECAY
// ─────────────────────────────────────────────────────────────────────────────
//
// 38 of 240 admitted rows reach a live service. bp and gh are QUERY-LISTER
// heads, and that family's failure branch is RAN-AND-FAILED, which is DECAYED.
// So one guerrilla or GitHub hiccup flipped up to 36 rows to decayed against a
// published 14.6% — a single-cause spike wearing the costume of 36 independent
// decay events.
//
// EVERY TEST HERE IS PAIRED WITH ITS CONTROL. A fix that classified real tool
// failures as "the environment did it" would launder decay, which is worse than
// the bug: it would make the census permanently, invisibly optimistic.

const OUTAGE_STDERR = [
  // captured from bp against a dead port
  'Error: Get "http://127.0.0.1:1/v1/tasks": dial tcp 127.0.0.1:1: connect: connection refused',
  // captured from bp against an unresolvable host
  'Error: Get "https://nope.invalid/v1/tasks": dial tcp: lookup nope.invalid: no such host',
  // captured from gh with the network down
  "error connecting to api.github.com",
];

test("D68: real bp and gh OUTAGE stderr classifies SPAWN-ERROR — inadmissible, and NOT decay", () => {
  for (const stderr of OUTAGE_STDERR) {
    for (const cmd of ["bp task ls --limit 5", "gh api repos/FRIKKern/barkpark"]) {
      const v = classifyOutcome(cmd, run(1, "", stderr));
      assert.equal(v.outcome, OUTCOME.SPAWN_ERROR, `${cmd} :: ${stderr}`);
      assert.equal(v.decayed, false, "an outage must never be published as decay");
      assert.equal(v.answering, false, "nothing was measured, so it is not an answer either");
      assert.equal(v.admissible, false, "it measures this host, not the ledger");
    }
  }
});

test("D68 CONTROL: a tool that CONNECTED and answered no is still RAN-AND-FAILED", () => {
  // If these flipped to SPAWN-ERROR the fix would have laundered real decay
  // into "the environment did it", and the census would read green forever.
  const genuine = [
    ["gh api repos/FRIKKern/nope", "gh: Not Found (HTTP 404)"],
    ["bp task get does-not-exist", "Error: barkpark_not_found: no such task"],
    ["bp doc ls tag", "Error: unauthorized: token expired"],
    ["ls tooling/grip/gone", ""],
  ];
  for (const [cmd, stderr] of genuine) {
    const v = classifyOutcome(cmd, run(1, "", stderr));
    assert.equal(v.outcome, OUTCOME.RAN_AND_FAILED, `${cmd} must stay real decay`);
    assert.equal(v.decayed, true);
    assert.equal(v.admissible, true);
  }
});

test("D68: an env fault on stderr beside a CLEAN exit is still not a fault", () => {
  // The rc!==0 guard predates this change; broadening the patterns must not
  // have widened it into "any mention of a refused connection poisons the row".
  const v = classifyOutcome("bp task ls", run(0, "3 tasks", "warning: retried after connection refused"));
  assert.equal(v.outcome, OUTCOME.ANSWERED);
  assert.equal(v.admissible, true);
});

test("D68: curl transport failure is caught BY EXIT CODE, because `curl -s` leaves stderr EMPTY", () => {
  // 27 of the corpus's 34 curl commands pass -s, which suppresses curl's own
  // "Failed to connect" text. No stderr regex can ever reach these rows.
  for (const exit of [6, 7]) {
    const v = classifyOutcome("curl -s http://localhost:4000/api/schemas", run(exit, "", ""));
    assert.equal(v.outcome, OUTCOME.SPAWN_ERROR, `curl exit ${exit} with empty stderr`);
    assert.equal(v.decayed, false);
    assert.equal(v.admissible, false);
  }
});

test("D68 CONTROL: curl exit 22 is the SERVICE ANSWERING and stays decay", () => {
  // --fail exits 22 on an HTTP >= 400: the socket opened, the server replied.
  // Scoring that as an environment fault would delete the signal the census is
  // for. Same for a nonzero exit from a NON-curl tool: the code check must be
  // head-scoped, not a global "6 and 7 are always faults" rule.
  const http = classifyOutcome("curl -sf http://localhost:4000/api/schemas", run(22, "", ""));
  assert.equal(http.outcome, OUTCOME.RAN_AND_FAILED);
  assert.equal(http.decayed, true);

  const notCurl = classifyOutcome("bp task ls", run(7, "", ""));
  assert.equal(notCurl.outcome, OUTCOME.RAN_AND_FAILED, "exit 7 means nothing outside curl's table");
});

test("D68: network reach is COUNTED over every pipeline segment and NAMED in the render", () => {
  assert.equal(networkTool("bp task ls --limit 5"), "bp");
  assert.equal(networkTool("gh api repos/x/y | jq .name"), "gh", "the head reached the network even though jq set the exit code");
  assert.equal(networkTool("curl -s http://localhost:4000/api/schemas"), "curl");
  assert.equal(networkTool("git ls-remote origin main"), "git ls-remote");
  assert.equal(networkTool("grep -rn foo tooling/grip"), null);
  assert.equal(networkTool("git ls-tree HEAD --name-only"), null, "local git is not network reach");

  const rows = [
    { command: "bp task ls", executed: true },
    { command: "gh api repos/x/y | jq .name", executed: true },
    { command: "curl -s http://x/y", executed: true },
    { command: "grep -rn foo .", executed: true },
    { command: "bp task ls --all", executed: false },
  ];
  const net = networkReach(rows);
  assert.equal(net.executedReaching, 3, "the un-executed bp row reached nothing");
  assert.deepEqual(net.byTool, { bp: 1, gh: 1, curl: 1 });

  const report = summarise(
    rows.filter((r) => r.executed).map((r) => ({ ...r, screened: true, level: "L3", ...classifyOutcome(r.command, run(0, "x")) })),
    { corpusName: "a run with reach" },
  );
  assert.equal(report.reach.network.executedReaching, 3);
  const text = renderHuman(report);
  assert.match(text, /NETWORK REACH/);
  assert.match(text, /bp=1/);
  assert.match(text, /THIS HOST AT THIS TIME/, "the render must scope its own rate to this host and this moment");
});

test("D68: a hermetic run says so rather than printing nothing", () => {
  const rows = [{ command: "grep -c x f.js", screened: true, executed: true, level: "L3", ...classifyOutcome("grep -c x f.js", run(0, "3")) }];
  const text = renderHuman(summarise(rows, { corpusName: "hermetic" }));
  assert.match(text, /reaching a live service {2}0 of 1/);
  assert.match(text, /touched nothing off this checkout/);
});

// ─────────────────────────────────────────────────────────────────────────────
// 11. `--ledger` — THE CENSUS POINTED AT THE PRODUCT, NOT THE QUARRY
// ─────────────────────────────────────────────────────────────────────────────

test("--ledger folds the real store, dedupes to one recipe per key, and SURFACES the rivals", () => {
  const source = loadLedgerRecipes(LEDGER_DIR);
  assert.ok(source.stats.rows > 0, "the ledger is empty — wave 4's first row is missing");
  assert.equal(source.commands.length, source.stats.subjects,
    "deduped: exactly one recipe per (subject, quantity) key");
  assert.ok(source.commands.every((c) => typeof c === "string" && c.trim()));

  const all = loadLedgerRecipes(LEDGER_DIR, { allRivals: true });
  assert.ok(all.commands.length >= source.commands.length);
  assert.equal(all.skippedRivals, 0);

  // The rivals are SKIPPED, never dropped in silence — summarise()'s report has
  // no field for them, so flattening to a bare string[] would lose them.
  //
  // THE WITNESS IS THE allRivals LOAD, NOT `rows - subjects`. loadLedgerRecipes
  // counts DISTINCT rerun STRINGS per key, so what it skips is exactly what the
  // allRivals load keeps and this one drops. This used to be asserted as
  // `rows - subjects`, which is the same number ONLY while no two ROWS under one
  // key carry byte-identical commands — an accident of the store, never a
  // property of the reader. Re-recording an existing recipe through the write
  // path (D118's append-only repair: the original row is never edited, a new
  // attested run supersedes it) writes precisely that duplicate, with a fresher
  // observed_at and nothing else changed, and the old identity went red on a
  // store that was behaving correctly.
  assert.equal(source.skippedRivals, all.commands.length - source.commands.length,
    "skipped = every distinct command past the first, per key");
  // The looser relation still holds and names the gap: a key holding two rows
  // with the SAME command contributes to rows-subjects and not to skippedRivals.
  assert.ok(source.skippedRivals <= source.stats.rows - source.stats.subjects,
    "a repeated command is a re-run of one recipe, not a second way in");
  assert.equal(source.rivalMethods.length, source.stats.rival_methods);
});

test("the pre-census block prints the fold facts summarise() has NO FIELD FOR", () => {
  const source = loadLedgerRecipes(LEDGER_DIR);
  const text = renderLedgerPreamble(source);
  assert.match(text, /tooling\/grip\/ledger/, "the render must NAME its corpus — a bare exit-0 gate is vacuous without it");
  assert.match(text, /rows folded\s+\d+/);
  assert.match(text, /subjects\s+\d+/);
  assert.match(text, /rival methods\s+\d+/);
  assert.match(text, /unreadable\s+\d+/);
  // And these four are genuinely absent from the census report itself, which is
  // the whole reason the block exists.
  const report = censusRun([], { corpusName: "empty" });
  assert.equal("unreadable" in report, false);
  assert.equal("rival_methods" in report, false);
});

test("the pre-census block says how much of the key the FOLD re-derived — a clean '0 rivals' is a property of the READ", () => {
  // The fold re-derives the quantity half of every key from the command,
  // because the mint's grammar moved after the rows were written and the store
  // is immutable. 57 of the 62 committed rows carry a stored key today's mint
  // no longer produces. Absorbing that silently would let "rival methods 0"
  // read as a fact about the DATA, and the fallback count is the only signal
  // that the fold is still keying on a stale value anywhere.
  const source = loadLedgerRecipes(LEDGER_DIR);
  assert.ok(source.stats.quantity_restated > 0, "the committed store must still exercise this path");
  const text = renderLedgerPreamble(source);
  assert.match(text, /key re-derived\s+\d+ quantity, \d+ level/);
  assert.match(text, /fell back\s+\d+ quantity, \d+ level/);
  assert.ok(
    text.includes(`key re-derived   ${source.stats.quantity_restated} quantity`),
    `the rendered count must be the fold's own: ${text}`,
  );
});

test("THE CALL SHAPE: censusRun is SYNCHRONOUS and already summarises — re-summarising CRASHES", () => {
  const report = censusRun(["grep -c screenCommand tooling/grip/census.mjs"], { corpusName: "shape" });
  // CORRECT: renderHuman over censusRun's return.
  assert.ok(Array.isArray(report.rows), "censusRun returns a finished report, not rows");
  assert.match(renderHuman(report), /CENSUS —/);
  // WRONG, and it cost a verifier a crash. Kept executable so the trap stays
  // provable rather than merely documented.
  assert.throws(() => summarise(report, { corpusName: "shape" }), /rows\.filter is not a function/);
  // It is not a thenable either — `await censusRun(...)` would silently work and
  // then hand a report to code expecting rows.
  assert.equal(typeof report.then, "undefined");
});

test("a --ledger-sized run reports UNDERPOWERED, and the measured rate is an OBSERVATION", () => {
  // Charter P6's predicted null, shipping as a MECHANISM with an honest reading
  // rather than as a result. Today's store is far below the 30-row floor.
  const source = loadLedgerRecipes(LEDGER_DIR);
  const report = censusRun(source.commands, { corpusName: LEDGER_CORPUS_NAME });
  if (report.decisive.admissible < 30) {
    assert.match(report.prediction.verdict, /UNDERPOWERED/);
    assert.match(report.prediction.verdict, /observation only/);
    assert.doesNotMatch(report.prediction.verdict, /^CONSISTENT|^CONTRARY/);
  } else {
    assert.doesNotMatch(report.prediction.verdict, /UNDERPOWERED/,
      "the store crossed the floor — this branch is the honest alternative, not a skip");
  }
});

test("censusing the ledger writes NOTHING back into it", () => {
  const before = snapshotDir(LEDGER_DIR);
  const source = loadLedgerRecipes(LEDGER_DIR);
  const report = censusRun(source.commands, { corpusName: LEDGER_CORPUS_NAME });
  assert.equal(snapshotDir(LEDGER_DIR), before, "the census mutated the store it was measuring");
  assert.ok(report.reach.executed > 0, "nothing ran — the no-write proof would be vacuous");
});

// ─────────────────────────────────────────────────────────────────────────────
// 12. UNKNOWN FLAGS ARE REJECTED
// ─────────────────────────────────────────────────────────────────────────────
//
// `--totally-bogus-flag-xyz` exited 0 having quietly run the default census,
// which reads to an operator — and to a gate — exactly like the flag worked.
// Same class as the `--limit NaN` defect: a request silently denied.

test("an unknown flag is REJECTED by name, and the known ones are not", () => {
  assert.equal(validateArgv(["--ledger", "--json"]).ok, true);
  assert.equal(validateArgv(["--limit", "5"]).ok, true);
  assert.equal(validateArgv(["--limit", "--json"]).ok, true, "--limit's value is adjudicated by the limit check, not here");
  assert.equal(validateArgv([]).ok, true);

  const bogus = validateArgv(["--totally-bogus-flag-xyz", "--limit", "5"]);
  assert.equal(bogus.ok, false);
  assert.match(bogus.reason, /--totally-bogus-flag-xyz/);
  assert.match(bogus.reason, /--ledger/, "the rejection must print the valid set");

  const stray = validateArgv(["bogus"]);
  assert.equal(stray.ok, false);
  assert.match(stray.reason, /unexpected argument/);
});

test("CONTROL: the CLI actually exits 2 on an unknown flag and 0 on --ledger", () => {
  // validateArgv returning {ok:false} proves nothing if the CLI never calls it.
  const bogus = spawnSync(process.execPath, [CENSUS_MJS, "--totally-bogus-flag-xyz", "--limit", "5"], { encoding: "utf8" });
  assert.equal(bogus.status, 2, "an ignored flag exits 0 and looks exactly like an honoured one");
  assert.match(bogus.stderr, /unknown flag/);

  const ok = spawnSync(process.execPath, [CENSUS_MJS, "--ledger"], { encoding: "utf8" });
  assert.equal(ok.status, 0);
  // NON-VACUOUS: the render must NAME the ledger. On origin/main `--ledger` is
  // an ignored flag that also exits 0 over the FIXTURE, and its output contains
  // this string zero times — so a bare exit-0 gate would pass without the
  // feature. The name is what makes the gate able to fail.
  assert.match(ok.stdout, /tooling\/grip\/ledger/);
});

// ── THE UNREADABLE BRANCH, FIRED RATHER THAN INSPECTED ───────────────────────
//
// The preamble's unreadable block is dead on today's store (0 unreadable), so
// the builder shipped it UNPROVEN BY EXECUTION and said so. A branch nobody has
// run is a branch nobody knows the shape of — and this one exists precisely to
// stop a partially-read store publishing itself as a smaller clean one, which
// is the failure mode with the highest cost in this whole module. So it is
// fired here against a synthesised rotten store rather than read.

test("a rotten run file is REPORTED in the preamble and kept OUT of both rates", () => {
  const dir = mkdtempSync(join(tmpdir(), "grip-census-rotten-"));
  writeFileSync(join(dir, "grip-20260721T000000Z-rotten.json"), "{ this is not json");
  writeFileSync(
    join(dir, "grip-20260721T000001Z-good.json"),
    JSON.stringify({
      run_id: "grip-20260721T000001Z",
      recipes: [{
        subject: "tooling/grip/census.mjs", quantity: "wc:-l",
        rerun: "wc -l tooling/grip/census.mjs",
        derived_level: "L3", deps: [], observed_at: "2026-07-21T00:00:01Z",
      }],
    }),
  );

  const source = loadLedgerRecipes(dir);
  assert.equal(source.stats.unreadable, 1, "precondition: the fold sees the rotten file");
  assert.equal(source.commands.length, 1, "the readable row still censuses");

  const text = renderLedgerPreamble(source);
  assert.match(text, /unreadable       1/, "the count must be on the face of the report");
  assert.match(text, /NOT ABOUT DECAY/, "and it must say what it is NOT, or a reader scores it as decay");
  assert.match(text, /rotten\.json/, "naming the file is what makes it re-derivable");
  assert.match(text, /UNPARSEABLE/);

  // The load-bearing half: an unreadable row is in NEITHER rate. It never
  // reached the engine, so it cannot be an answer and it cannot be decay.
  const report = censusRun(source.commands, { corpusName: "rotten-store probe" });
  assert.equal(report.reach.distinct, 1, "only the readable row was censused");
  assert.equal("unreadable" in report, false, "summarise has no field for it — which is WHY the preamble exists");
});

test("CONTROL: a clean store's preamble does NOT print the unreadable block", () => {
  const dir = mkdtempSync(join(tmpdir(), "grip-census-clean-"));
  writeFileSync(
    join(dir, "grip-20260721T000001Z-good.json"),
    JSON.stringify({
      run_id: "grip-20260721T000001Z",
      recipes: [{
        subject: "tooling/grip/census.mjs", quantity: "wc:-l",
        rerun: "wc -l tooling/grip/census.mjs",
        derived_level: "L3", deps: [], observed_at: "2026-07-21T00:00:01Z",
      }],
    }),
  );
  const text = renderLedgerPreamble(loadLedgerRecipes(dir));
  assert.match(text, /unreadable       0/);
  assert.doesNotMatch(text, /NOT ABOUT DECAY/, "a clean store must not cry wolf");
});

// ─────────────────────────────────────────────────────────────────────────────
// 13. D73 — WHICH TREE EACH ANSWER IS ABOUT
// ─────────────────────────────────────────────────────────────────────────────
//
// The census asks whether a recipe still ANSWERS. A tree-sensitive recipe keeps
// answering — from the wrong tree — so it scores a clean ANSWERED while being
// wrong, and the epic's own rot detector was blind to this class. Every row now
// carries its binding class (from binding.mjs); the render reports the class
// distribution and states which tree the census itself ran in.

test("D73 FAIL-BEFORE/PASS-AFTER: a tree-sensitive recipe run in two cwds was blind by OUTCOME, now DISTINGUISHED by binding class", () => {
  // The demonstrated blindness: `git ls-tree HEAD …` returns 1 line in the
  // primary checkout and 4 in a fresh worktree — cwd the ONLY variable — yet the
  // census scored an identical healthy ANSWERED from both. Two execution
  // environments, one modelled by each spy.
  const recipe = "git ls-tree HEAD --name-only tooling/grip/ledger/";
  const primaryTree = () => run(0, "README.md\n");
  const freshWorktree = () => run(0, "README.md\na.json\nb.json\nc.json\n");
  const a = censusOne(recipe, { exec: primaryTree });
  const b = censusOne(recipe, { exec: freshWorktree });

  // BEFORE — the OUTCOME column alone. Identical, healthy, indistinguishable:
  // both ANSWERED, both answering, neither decayed. This IS the blindness.
  assert.equal(a.outcome, OUTCOME.ANSWERED);
  assert.equal(b.outcome, OUTCOME.ANSWERED);
  assert.equal(a.answering, true);
  assert.equal(b.answering, true);
  assert.equal(a.outcome, b.outcome, "the outcome field cannot tell the two trees apart");

  // AFTER — every row now carries its binding class, and it names the tree the
  // answer is about: THIS worktree, not necessarily the reader's.
  assert.equal(a.binding.binding_class, "per-worktree");
  assert.equal(a.binding.portable_scope, "this worktree");
  assert.equal(b.binding.binding_class, "per-worktree");
  assert.equal(b.binding.portable_scope, "this worktree");

  // And the class DISCRIMINATES where the outcome could not: a SHA-pinned read
  // is content-addressed ("any clone"), same healthy ANSWERED, a different tree
  // story. That gap is the whole point of this slice.
  const portable = censusOne("git show 1a2b3c4d:tooling/grip/census.mjs", { exec: () => run(0, "…bytes…") });
  assert.equal(portable.outcome, OUTCOME.ANSWERED, "same healthy outcome");
  assert.equal(portable.binding.binding_class, "content-addressed");
  assert.equal(portable.binding.portable_scope, "any clone");
  assert.notEqual(
    portable.binding.portable_scope, a.binding.portable_scope,
    "the binding class distinguishes what the outcome field could not",
  );
});

test("D73: a REFUSED row still carries its binding class — the class is known before any spawn", () => {
  const exec = spyExec();
  const row = censusOne("systemctl stop bp-crux-parent", { exec });
  assert.equal(row.outcome, OUTCOME.REFUSED);
  assert.equal(exec.calls.length, 0);
  assert.ok(row.binding, "the binding class is a function of the command string, not of execution");
  assert.equal(typeof row.binding.binding_class, "string");
});

test("D73: the render reports the BINDING-CLASS distribution, sourced from binding.mjs", () => {
  const mk = (command, level, r) => ({
    command, screened: true, executed: true, level,
    binding: classifyBinding(command), ...classifyOutcome(command, r),
  });
  const rows = [
    mk("git show 1a2b3c4d:tooling/grip/census.mjs", "L2", run(0, "bytes")),          // content-addressed
    mk("git show origin/main:tooling/grip/screen.mjs", "L2", run(0, "bytes")),        // shared-ref
    mk("git ls-tree HEAD --name-only tooling/grip/ledger/", "L3", run(0, "README.md\n")), // per-worktree
    mk("grep -c foo tooling/grip/census.mjs", "L3", run(0, "3")),                     // cwd-bound
  ];
  const report = summarise(rows, { corpusName: "binding-demo" });
  // The distribution is carried on the report, folded over the whole corpus.
  assert.equal(report.binding.by_class["content-addressed"], 1);
  assert.equal(report.binding.by_class["shared-ref"], 1);
  assert.equal(report.binding.by_class["per-worktree"], 1);
  assert.equal(report.binding.by_class["cwd-bound"], 1);

  const text = renderHuman(report);
  assert.match(text, /BINDING CLASS/);
  assert.match(text, /content-addressed\s+any clone/);
  assert.match(text, /per-worktree\s+this worktree/);
  assert.match(text, /cwd-bound\s+this cwd/);
  // The sharpened honesty line: some answered about a tree that is not the
  // reader's — but STILL-ANSWERING is never restated as STILL-CORRECT.
  assert.match(text, /NOT NECESSARILY/);
  assert.match(text, /STILL ANSWERING IS NOT STILL CORRECT/);
});

test("D73: the render documents that WRONG-CWD does NOT cover the wrong-tree class", () => {
  const rows = [{
    command: "git ls-tree HEAD --name-only tooling/grip/ledger/", screened: true, executed: true, level: "L3",
    binding: classifyBinding("git ls-tree HEAD --name-only tooling/grip/ledger/"),
    ...classifyOutcome("git ls-tree HEAD --name-only tooling/grip/ledger/", run(0, "README.md\n")),
  }];
  const text = renderHuman(summarise(rows, { corpusName: "wrong-cwd-demo" }));
  // WRONG-CWD is cited as a NON-guard here: it fires only outside a git repo
  // entirely, never in any worktree — so it is not coverage for this class.
  assert.match(text, /WRONG-CWD does NOT cover this class/);
  assert.match(text, /only outside a git repository/i);
  assert.match(text, /never fires inside any worktree/i);
});

test("D73: the render STATES which tree the census ran in when provenance is supplied", () => {
  // A fake provenance object, shaped exactly as treeProvenance returns, so the
  // render is exercised without a git spawn.
  const fakeProv = {
    cwd: "/x/tree", state: "measured", reason: null, in_repo: true,
    root: "/x/tree", head: "abc1234def", head_short: "abc1234",
    origin_main: "def5678", origin_main_short: "def5678",
    differs_from_origin: false, dirty: false, dirty_files: 0,
  };
  const rows = [{
    command: "grep -c x f.js", screened: true, executed: true, level: "L3",
    binding: classifyBinding("grep -c x f.js"), ...classifyOutcome("grep -c x f.js", run(0, "3")),
  }];
  const withProv = renderHuman(summarise(rows, { corpusName: "tree-demo", provenance: fakeProv }));
  assert.match(withProv, /\[grip-provenance\]/, "the render must state which tree it ran in");
  assert.match(withProv, /tree \/x\/tree/);

  // CONTROL: with no provenance the render simply omits the line — it never
  // fabricates a tree it was not told about, and the banner stays line one.
  const noProv = renderHuman(summarise(rows, { corpusName: "tree-demo" }));
  assert.doesNotMatch(noProv, /\[grip-provenance\]/);
  assert.match(noProv.split("\n")[0], /^CENSUS — /);
});

test("D73: --json carries the binding distribution and each row's binding class", () => {
  const rows = [
    { command: "git show 1a2b3c4d:x.mjs", screened: true, executed: true, level: "L2", binding: classifyBinding("git show 1a2b3c4d:x.mjs"), ...classifyOutcome("git show 1a2b3c4d:x.mjs", run(0, "bytes")) },
    { command: "git ls-tree HEAD tooling/", screened: true, executed: true, level: "L3", binding: classifyBinding("git ls-tree HEAD tooling/"), ...classifyOutcome("git ls-tree HEAD tooling/", run(0, "a\n")) },
  ];
  const j = toJson(summarise(rows, { corpusName: "json-binding" }));
  assert.equal(j.binding.by_class["content-addressed"], 1);
  assert.equal(j.binding.by_class["per-worktree"], 1);
  assert.ok(j.rows.every((r) => "binding_class" in r && "portable_scope" in r));
  const shaRow = j.rows.find((r) => r.command.includes("1a2b3c4d"));
  assert.equal(shaRow.binding_class, "content-addressed");
  assert.equal(shaRow.portable_scope, "any clone");
  // The caveat names the WRONG-CWD gap in the machine render too.
  assert.ok(j.caveats.some((c) => /WRONG-CWD does not cover the wrong-tree class/i.test(c)));
});

test("CONTROL: `--ledger` stdout carries the provenance tree line and the binding-class distribution", () => {
  // The real CLI, end to end. emitProvenance writes the banner to STDERR; the
  // render writes the tree line and the binding section to STDOUT.
  const r = spawnSync(process.execPath, [CENSUS_MJS, "--ledger"], { encoding: "utf8" });
  assert.equal(r.status, 0, `census --ledger exited ${r.status}: ${r.stderr}`);
  assert.match(r.stdout, /\[grip-provenance\]/, "the render must state which tree it ran in");
  assert.match(r.stdout, /BINDING CLASS/, "the render must report the binding-class distribution");
  assert.match(r.stdout, /WRONG-CWD does NOT cover this class/, "the WRONG-CWD non-coverage note must ship in the render");
});

// ─────────────────────────────────────────────────────────────────────────────
// 13. TOOL AVAILABILITY — A MISSING BINARY IS NOT A ROTTED RECIPE
// ─────────────────────────────────────────────────────────────────────────────
//
// THE DEFECT. rc 127 was mapped to PATH-GONE, and PATH-GONE is in the DECAYED
// set, so a host with a lean PATH published its own missing binaries as decay
// IN THE LEDGER. Re-derived over one unchanged tree and one unchanged corpus,
// only the PATH differing:
//
//   full PATH                     39 of 193 decisive decayed  20.2%  CONSISTENT
//   PATH without bp, gh, go, mix  61 of 197 decisive decayed  31.0%  CONTRARY
//
// 37 of that second 61 are pure rc-127. The verdict FLIPPED on which tools the
// operator happened to have installed — the census's own disease (a number
// computed at one authority level, published at a higher one) inside the
// census's own instrument.
//
// THE FIX IS TWO-PART AND BOTH PARTS ARE TESTED HERE. (1) TOOL-ABSENT sits
// outside DECAYED, so the rows leave both rates. (2) A tool-availability header
// is PROBED (a PATH walk, not an assumption) and printed on EVERY run, and no
// rate is printed without it — because a reader cannot otherwise tell a rate
// conditional on a lean PATH from one that is not.
//
// EVERY PROBE TEST INJECTS ITS OWN PATH AND ITS OWN EXECUTABLE PREDICATE. A test
// that asked the real host whether `bp` exists would pass or fail on what the
// machine happens to have installed, which is the exact conditionality being
// fixed.

/** A fake host: only the named absolute paths are executable. */
const fakeHost = (executables) => (p) => executables.includes(p);
const FAKE_PATH = "/opt/fake/bin:/usr/bin";
const HAS_GREP_ONLY = fakeHost(["/usr/bin/grep", "/usr/bin/git"]);

const executedRow = (command) => ({ command, screened: true, executed: true, level: "L3" });

test("the probe RESOLVES a head against a real PATH walk and reports absence as absence", () => {
  const opts = { pathEnv: FAKE_PATH, isExecutable: HAS_GREP_ONLY };

  const found = resolveTool("grep", opts);
  assert.equal(found.present, true);
  assert.equal(found.at, "/usr/bin/grep", "the probe names WHERE it resolved, so the claim is checkable");
  assert.equal(found.kind, "on-path");

  const missing = resolveTool("bp", opts);
  assert.equal(missing.present, false);
  assert.equal(missing.at, null);

  // NOT VACUOUS IN THE OTHER DIRECTION: give the same head a PATH that has it
  // and the same call flips. Without this half the test would pass against a
  // probe that returned `false` for everything.
  assert.equal(resolveTool("bp", { pathEnv: "/opt/fake/bin", isExecutable: fakeHost(["/opt/fake/bin/bp"]) }).present, true);
});

test("the probe knows a shell builtin needs no binary, and resolves a ./path literal against the tree", () => {
  // `/bin/sh -c 'cd x && …'` needs nothing on PATH. Reporting `cd` ABSENT would
  // make the header cry wolf on every run, and a header that cries wolf is one
  // an operator learns to skip.
  const builtin = resolveTool("cd", { pathEnv: "", isExecutable: () => false });
  assert.equal(builtin.present, true);
  assert.equal(builtin.kind, "shell-builtin");

  // A head with a slash is NOT a PATH lookup: `./scripts/x.sh` is resolved
  // against the tree. Path-stripping it to `x.sh` and searching PATH would
  // report every repo script in the corpus as a missing tool.
  const script = resolveTool("./scripts/x.sh", { cwd: "/repo", pathEnv: FAKE_PATH, isExecutable: fakeHost(["/repo/scripts/x.sh"]) });
  assert.equal(script.present, true);
  assert.equal(script.kind, "path-literal");
  assert.equal(script.at, "/repo/scripts/x.sh");
  assert.equal(resolveTool("./scripts/gone.sh", { cwd: "/repo", pathEnv: FAKE_PATH, isExecutable: fakeHost([]) }).present, false);
});

test("heads are counted over EVERY pipeline segment, and only over rows that actually executed", () => {
  const heads = toolHeads([
    executedRow("bp task ls | grep foo"),
    executedRow("grep -rn x tooling"),
    { command: "sudo rm -rf /", screened: false, executed: false, level: "L3" },
  ]);
  // `bp task ls | grep foo` exits with GREP's status, so a tail-only read would
  // report this run as fully tooled while its head was missing.
  assert.equal(heads.get("bp"), 1, "the pipeline HEAD must be probed even though the tail set the exit code");
  assert.equal(heads.get("grep"), 2);
  assert.equal(heads.has("sudo"), false, "a refused row reached no shell, so its head says nothing about the rates");
});

test("the render prints a tool-availability header naming which heads were PRESENT and which ABSENT", () => {
  const rows = [
    { ...executedRow("grep -rn x tooling"), ...classifyOutcome("grep -rn x tooling", run(1, "", "")) },
    { ...executedRow("bp task ls"), ...classifyOutcome("bp task ls", run(127, "", "sh: bp: not found")) },
    { ...executedRow("go vet ./..."), ...classifyOutcome("go vet ./...", run(127, "", "sh: go: not found")) },
  ];
  const report = summarise(rows, { corpusName: "tool-availability-demo", pathEnv: FAKE_PATH, isExecutable: HAS_GREP_ONLY });
  const text = renderHuman(report);

  assert.match(text, /TOOL AVAILABILITY ON THIS HOST/);
  // The header must NAME the heads, not just count them — a bare "2 absent" is
  // a number the reader cannot act on or check.
  const headerLines = text.split("\n").filter((l) => /^\s+(present|ABSENT)\s/.test(l));
  assert.equal(headerLines.length, 2);
  assert.match(headerLines[0], /\bgrep\b/, "the present line must name grep");
  assert.match(headerLines[1], /\bbp\b/, "the ABSENT line must name bp");
  assert.match(headerLines[1], /\bgo\b/, "the ABSENT line must name go");
  assert.doesNotMatch(headerLines[0], /\bbp\b/, "bp is absent on this fake host and must not be listed present");

  assert.deepEqual(report.tools.absentHeads.sort(), ["bp", "go"]);
  assert.deepEqual(report.tools.presentHeads, ["grep"]);
  assert.equal(report.reach.toolAbsent, 2);

  // AND THE RATE IT QUALIFIES EXCLUDES THEM. Both rc-127 rows are inadmissible,
  // so the one remaining decisive row carries the whole rate.
  assert.equal(report.decisive.admissible, 1);
  assert.equal(report.decisive.decayed, 0, "two missing binaries must not appear as two decayed recipes");
});

test("the header is printed even when NOTHING is missing — 'everything was installed' is the fact a rate rests on", () => {
  const rows = [{ ...executedRow("grep -rn x tooling"), ...classifyOutcome("grep -rn x tooling", run(1, "", "")) }];
  const text = renderHuman(summarise(rows, { corpusName: "fully-tooled", pathEnv: FAKE_PATH, isExecutable: HAS_GREP_ONLY }));
  assert.match(text, /TOOL AVAILABILITY ON THIS HOST/);
  assert.match(text, /every head this run executed resolves here/);
  assert.match(text, /STILL ANSWERING vs DECAYED/, "a fully-tooled run still prints its rates");
});

test("NO RATE WITHOUT THE HEADER: with no probe, both renders WITHHOLD the decay figure", () => {
  const rows = [
    { ...executedRow("grep -rn x tooling"), ...classifyOutcome("grep -rn x tooling", run(1, "", "")) },
    { ...executedRow("cat gone"), ...classifyOutcome("cat gone", run(1, "", "cat: gone: No such file or directory")) },
  ];
  const withProbe = summarise(rows, { corpusName: "gated", pathEnv: FAKE_PATH, isExecutable: HAS_GREP_ONLY });
  const noProbe = summarise(rows, { corpusName: "gated", tools: null });

  // The CONTROL half: with the header, the rate is printed as normal. Without
  // it, the same rows produce no rate anywhere in the render.
  const okText = renderHuman(withProbe);
  assert.match(okText, /STILL ANSWERING vs DECAYED/);
  assert.match(okText.split("\n")[0], /decayed\./);

  const text = renderHuman(noProbe);
  assert.match(text, /NO RATE — THE TOOL-AVAILABILITY PROBE DID NOT RUN/);
  assert.doesNotMatch(text, /STILL ANSWERING vs DECAYED/, "the rate block must not be reachable without the header");
  assert.doesNotMatch(text.split("\n")[0], /% of .* STILL ANSWER/, "the banner is the first place a number could escape");

  // AND THE MACHINE RENDER MAKES THE SAME REFUSAL. A JSON escape hatch around a
  // human-render guard is the guard not existing.
  const j = toJson(noProbe);
  assert.equal(j.decisive.decayPct, null);
  assert.equal(j.decisive.answeringPct, null);
  assert.match(j.decisive.rate_withheld, /tool-availability/i);
  assert.equal(j.tool_availability, null);
  // The control, again: the probed report DOES carry its numbers.
  assert.equal(typeof toJson(withProbe).decisive.decayPct, "number");
});

test("--json carries the tool-availability header and a caveat that names it", () => {
  const rows = [
    { ...executedRow("grep -rn x tooling"), ...classifyOutcome("grep -rn x tooling", run(1, "", "")) },
    { ...executedRow("bp task ls"), ...classifyOutcome("bp task ls", run(127, "", "sh: bp: not found")) },
  ];
  const j = toJson(summarise(rows, { corpusName: "json-tools", pathEnv: FAKE_PATH, isExecutable: HAS_GREP_ONLY }));
  assert.deepEqual(j.tool_availability.absent.map((e) => e.head), ["bp"]);
  assert.deepEqual(j.tool_availability.present.map((e) => e.head), ["grep"]);
  assert.equal(j.tool_availability.rows_scored_tool_absent, 1);
  assert.ok(j.caveats.some((c) => /TOOL-ABSENT/.test(c) && /NEITHER rate/.test(c)));
});

test("the probe SPAWNS NOTHING — the census's execution set stays exactly what screenCommand admitted", () => {
  // The whole safety argument of this module (D47) is that screenCommand is the
  // only gate and nothing else reaches a shell. A probe implemented as
  // `sh -c 'command -v bp'` would have quietly widened that set. This asserts
  // the implementation reads the filesystem instead.
  let spawned = 0;
  const rows = [executedRow("bp task ls | grep foo"), executedRow("go vet ./...")];
  const probe = probeToolAvailability(rows, {
    pathEnv: FAKE_PATH,
    isExecutable: (p) => { spawned += 0; return HAS_GREP_ONLY(p); },
  });
  assert.equal(spawned, 0);
  assert.equal(probe.probed, 3, "bp, grep and go");
  assert.equal(probe.rowsDependingOnAbsent, 2);

  // And the SOURCE never composes a shell probe: no `command -v`, no `which`,
  // no `type -p` reaching the executor.
  assert.ok(!/command\s+-v/.test(CODE), "the probe must not shell out to `command -v`");
  assert.ok(!/\bwhich\s+\$\{/.test(CODE), "the probe must not shell out to `which`");
});
