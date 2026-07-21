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
import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

import {
  FAMILY, OUTCOME, CENSUS_TIMEOUT_MS, CENSUS_TIMEOUT_FLOOR_MS, TIMEOUT_FLOOR_MULTIPLE,
  classifyFamily, classifyOutcome, naiveOutcome, isAnswering, isDecayed,
  censusOne, censusRun, summarise, renderHuman, toJson, isNullDistribution,
  isTestRunner, loadCorpusCommands, CORPUS_NAME,
} from "../census.mjs";
import { screenCommand, DANGER_SET } from "../screen.mjs";
import { SYNC_TIMEOUT_MS } from "../rerun.mjs";

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

test("exit 127 (command not found) is decay; a warning on stderr beside rc0 is not a fault", () => {
  assert.equal(classifyOutcome("bp task ls", run(127, "", "sh: bp: not found")).outcome, OUTCOME.PATH_GONE);
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
  assert.doesNotMatch(SOURCE, /from\s*"\.\/(ledger|record|harvest)\.mjs"/, "the census must not import a writer");
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
