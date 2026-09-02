#!/usr/bin/env node
// The D92 EXIT RACE, pinned — tooling/grip/test/exit-race.test.mjs
//
//   node --test tooling/grip/test/exit-race.test.mjs
//
// WHAT D92 RULED, AND WHY IT NEEDED A THIRD APPLICATION. Node writes stdout to
// a PIPE asynchronously. `process.stdout.write(big)` hands the kernel as much
// as the pipe buffer will take and QUEUES the rest inside the process; calling
// `process.exit()` on the next line throws that queue away. A run redirected to
// a file (stdout is then a synchronous fd) is whole, and the same run with
// `| jq` appended comes back truncated — so the defect only ever shows up in
// the caller's pipeline and reads like a formatting bug in the tool.
//
// ledger.mjs's entry guard had been converted to `process.exitCode`. backfill's
// and acceptance's had not: backfill ended `.then((code) => process.exit(code))`
// with a `--json` stdout path, and acceptance called `process.exit(outcome.ok ?
// 0 : 1)` on the line after printing its report — the report this epic cites as
// its own evidence. This file is the pin so that cannot come back.
//
// AND THE RULING GOVERNED MORE THAN THREE FILES. A `grep -n 'process.exit('
// tooling/grip/*.mjs` after that second application still hit SIX more runnable
// modules on paths that write stdout first: cli.mjs (`process.exit(main(argv))`
// after the HELP screen and every adjudication verdict), seal.mjs
// (`process.exit(main())` on the line after the whole seal report, whose LAST
// line is the VERDICT-TOKEN), screen.mjs (four arms, all after selftest()'s and
// census()'s tables), harvest.mjs (six arms, four of them after the check table
// the verify prints), census.mjs (four arms, one of them straight after
// `console.log(HELP)`) and trial-leads-vs-grep.mjs (`process.exit(main(argv))`
// after the report or the `--json` document). None of those outputs exceeds a
// 64 KiB pipe buffer TODAY — measured on the tree that ships this file:
// census.mjs --json --limit 3 writes 4925 bytes, trial-leads-vs-grep --json over
// the live ledger 16406, harvest.mjs --verify 2956, cli.mjs --help 544,
// screen.mjs --selftest 137 — so the tear was LATENT in every one of them.
// census's `--json` is the one that grows with the store and so the one that
// reaches the buffer first. The exit STATUS of every converted arm is
// unchanged; clause (A) below now covers all nine files, and clause (A2)
// re-derives the list from disk so it cannot silently shrink.
//
// THE MEASUREMENT, and it is honest about its own reach:
//
//   * The tear threshold is the KERNEL PIPE BUFFER, not "~512 bytes". Measured
//     on darwin with a slow reader: a payload of 4 KiB and one of 16 KiB arrive
//     WHOLE through a `process.exit(0)` tail, because they fit in the buffer and
//     the write completes synchronously. From 64 KiB up, that tail delivers
//     exactly 65536 bytes and never one more — of a 64 KiB payload, of a 256 KiB
//     payload, of a 1 MiB payload. The `process.exitCode` tail delivered all
//     1048580 bytes of the largest, three runs out of three.
//
//   * Reader speed is NOT what decides it. process.exit runs synchronously on
//     the line after write(), before any reader could have drained anything, so
//     a payload past the buffer is torn against a reader that never pauses. The
//     slow reader below is realism, not the trigger.
//
//   * THE TWO HARNESSES DO NOT CURRENTLY EXCEED THAT THRESHOLD. Measured on the
//     tree that ships this file: `backfill.mjs --json --dry-run` writes 1031
//     bytes and `acceptance.mjs --json` writes 3207 — both far inside a 64 KiB
//     buffer, so NEITHER tore under `| cat` or `| (sleep 1; cat)` before the
//     fix. The bug was LATENT, not firing. That is exactly why part (B) below
//     is a guard and part (C) is the proof: (B) runs the real harnesses through
//     a pipe and would only go red once their output grows past the buffer,
//     which is the day this matters and the day nobody would be looking. (C)
//     proves the mechanism today, at a size that does tear, using the two tail
//     FORMS verbatim. Part (A) is what actually fails on a regression: restore
//     either shipped tail and (A) reds immediately, at any output size.
//
// If a future Node release flushes a queued pipe write on process.exit, (C)'s
// control goes red. That is the correct outcome — it means the hazard is gone
// and this file's premise needs re-reading, not that the suite broke.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = join(HERE, "..");

/**
 * EVERY entry point charter D92 governs — tooling/grip's whole runnable
 * surface, not a sample. ledger.mjs is the reference fix, backfill and
 * acceptance the second application, and the remaining six the residue this
 * list closes.
 *
 * WHY THE RULE IS FILE-SCOPED AND NOT PATH-SCOPED. The clause below reds on ANY
 * `process.exit(` in these files, a fatal arm that has written nothing to stdout
 * included — an arm that, on its own, is harmless. That is deliberate, and it is
 * the cheap direction to be wrong in: judging per-hit whether an arm is
 * reachable after a write means re-deriving the control flow of nine CLIs on
 * every edit, and the arm somebody adds next year is precisely the one nobody
 * re-derives. Every fatal arm in these files was converted with its exit STATUS
 * and its stderr TEXT preserved, so the blanket rule costs nothing and cannot be
 * defeated by adding one more arm.
 */
const GUARDED = [
  "acceptance.mjs",
  "backfill.mjs",
  "census.mjs",
  "cli.mjs",
  "harvest.mjs",
  "ledger.mjs",
  "screen.mjs",
  "seal.mjs",
  "trial-leads-vs-grep.mjs",
];

/**
 * Source with FULL-LINE comments removed. Deliberately conservative: a line
 * whose first non-space character is `//`, `*` or `/*` is prose and drops out,
 * and anything else is code. A trailing `// …process.exit(…)` on a live line
 * would therefore still count as a hit — erring toward a red, never toward a
 * miss, which is the direction a tripwire is allowed to be wrong in.
 */
const codeOnly = (src) => src.split("\n").filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join("\n");

const callsExit = (src) => /process\.exit\s*\(/.test(codeOnly(src));
const setsExitCode = (src) => /process\.exitCode\s*=/.test(codeOnly(src));

/**
 * Spawn a script with stdout as a PIPE and read it SLOWLY — pausing the stream
 * between chunks, which is what a `| jq` on a busy box amounts to. Resolves the
 * whole of what the reader actually received, plus the exit status.
 */
function readSlowly(args, { cwd = GRIP, pauseMs = 25 } = {}) {
  return new Promise((resolvePromise) => {
    const child = spawn(process.execPath, args, { cwd, stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (chunk) => {
      child.stdout.pause();
      out += chunk;
      setTimeout(() => child.stdout.resume(), pauseMs);
    });
    child.on("close", (status) => setTimeout(() => resolvePromise({ out, status }), pauseMs * 4));
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// (A) THE SHIPPED TAILS. The clause that reds on a regression, at any size.
// ─────────────────────────────────────────────────────────────────────────────

test("no D92-governed entry guard calls process.exit, and every one sets process.exitCode", () => {
  const offenders = [];
  const silent = [];
  for (const name of GUARDED) {
    const src = readFileSync(join(GRIP, name), "utf8");
    if (callsExit(src)) offenders.push(name);
    if (!setsExitCode(src)) silent.push(name);
  }
  assert.deepEqual(
    offenders, [],
    "these harnesses call process.exit() outside a comment — charter D92: process.exit() discards whatever " +
      "stdout has queued for an asynchronous pipe, so `--json | jq` gets a truncated document while the same " +
      "run redirected to a file is whole. Set process.exitCode and let the loop drain",
  );
  assert.deepEqual(silent, [], "a guard that neither exits nor sets exitCode always reports success");
});

test("CONTROL: the tail scanner reports the exact shapes that shipped on main", () => {
  // Verbatim from the pre-fix tree, one per guarded file that had an offending
  // arm — the scanner must call EVERY one of these out, or clause (A) above is
  // green because it cannot see, not because it is true. A scanner that catches
  // two of eight is the "counting doors is not counting what a door sees"
  // failure, and it is invisible from a green.
  const SHIPPED = {
    "backfill.mjs": "  main(process.argv.slice(2))\n    .then((code) => process.exit(code))\n",
    "acceptance.mjs": "  process.exit(outcome.ok ? 0 : 1);\n",
    "cli.mjs": "  emitProvenance();\n  process.exit(main(process.argv));\n",
    "seal.mjs": "if (import.meta.url === `file://${process.argv[1]}`) process.exit(main());\n",
    "screen.mjs": "      if (selftest() > 0) process.exit(1);\n",
    "harvest.mjs": "    console.error(`FAIL: ${failed}/${CHECKS.length} checks failed.`);\n    process.exit(1);\n",
    "census.mjs": "    console.log(HELP);\n    process.exit(0);\n",
    "trial-leads-vs-grep.mjs": "  process.exit(main(process.argv.slice(2)));\n",
  };
  const unseen = Object.entries(SHIPPED).filter(([, tail]) => !callsExit(tail)).map(([name]) => name);
  assert.deepEqual(unseen, [], "the scanner failed to read these shipped tails as offenders — clause (A) is blind, not true");
  const falselyCredited = Object.entries(SHIPPED).filter(([, tail]) => setsExitCode(tail)).map(([name]) => name);
  assert.deepEqual(falselyCredited, [], "and none of the pre-fix tails sets exitCode");

  // …and the scanner must NOT be fooled into a red by prose ABOUT the defect,
  // which every fixed guard now carries above it. The second sample is the line
  // cli.mjs actually ships above its guard — a synthetic comment would prove
  // less than the real one this file has to coexist with.
  const prose = "  // process.exit(code) TRUNCATES a not-yet-flushed pipe.\n  process.exitCode = 0;\n";
  assert.equal(callsExit(prose), false, "a full-line comment naming the anti-pattern is not a call");
  assert.equal(setsExitCode(prose), true, "and the fix underneath it must still be seen");
  const shippedProse = "// This file used to end with a BARE `process.exit(main(process.argv))` at module\n";
  assert.equal(callsExit(shippedProse), false, "cli.mjs's own prose about the old bare exit is not a call");
});

// ─────────────────────────────────────────────────────────────────────────────
// (A2) THE LIST ITSELF. A hand-kept file list is a tripwire that goes blind the
//      day somebody adds a tenth CLI — so re-derive the universe from disk.
// ─────────────────────────────────────────────────────────────────────────────

test("GUARDED names every tooling/grip module that reads argv positionally", () => {
  // The derivation: a module that indexes `process.argv` (`process.argv[1]`,
  // `[2]`, `.slice(2)`) is a RUNNABLE entry point and therefore governed. That
  // is deliberately narrower than "mentions process.argv": leads.mjs asks
  // `process.argv.includes("--full")` inside a helper the ledger CLI calls and
  // is not itself runnable, so it is correctly out. If a new CLI appears with an
  // indexed argv read and nobody adds it here, THIS is what reds — not a silent
  // pass over a shorter list.
  const entryPoints = readdirSync(GRIP)
    .filter((f) => f.endsWith(".mjs"))
    .filter((f) => /process\.argv\s*(\[|\.slice\s*\()/.test(codeOnly(readFileSync(join(GRIP, f), "utf8"))))
    .sort();
  assert.deepEqual(
    entryPoints.filter((f) => !GUARDED.includes(f)), [],
    "these tooling/grip modules read argv positionally — they are runnable entry points D92 governs, and " +
      "GUARDED above does not name them, so clause (A) is not looking at them",
  );
  assert.deepEqual(
    GUARDED.filter((f) => !entryPoints.includes(f)), [],
    "GUARDED names a module that no longer reads argv positionally — either it was renamed or it stopped " +
      "being an entry point; a stale name makes the list look longer than its reach",
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// (B) THE REAL HARNESSES, THROUGH A REAL PIPE. Latent today; the guard for the
//     day their output outgrows the kernel buffer. A truncated JSON cannot
//     parse, so JSON.parse succeeding IS the completeness assertion.
// ─────────────────────────────────────────────────────────────────────────────

test("backfill --json survives a slow pipe whole, and its exit status is unchanged", async () => {
  const { out, status } = await readSlowly(["backfill.mjs", "--json", "--dry-run", "--limit", "3"]);
  const parsed = JSON.parse(out); // throws on a torn document
  assert.equal(status, 0, "the exitCode tail must leave a clean run reporting 0, exactly as process.exit(0) did");
  for (const key of ["now", "dir", "wrote", "counts", "audit"]) {
    assert.ok(key in parsed, `the piped document lost its \`${key}\` field — it did not arrive whole`);
  }
  assert.ok(out.trimEnd().endsWith("}"), "the last byte of the document must have reached the reader");
});

test("acceptance survives a slow pipe whole in both output modes, and PASS still exits 0", async () => {
  const json = await readSlowly(["acceptance.mjs", "--json"]);
  const parsed = JSON.parse(json.out);
  assert.ok("ok" in parsed, "the piped acceptance document lost its verdict field");
  assert.ok(Array.isArray(parsed.results), "and its per-specimen results");

  const report = await readSlowly(["acceptance.mjs"]);
  const lastLine = report.out.trimEnd().split("\n").pop();
  assert.match(
    lastLine, /^ACCEPTANCE: (PASS|FAIL)$/,
    "the verdict is the LAST line acceptance prints, so a torn pipe eats the verdict first and leaves a " +
      "report that still looks like a report",
  );
  assert.equal(report.status, parsed.ok ? 0 : 1, "the report run's status must match the verdict, as before");
  assert.equal(json.status, report.status, "and both output modes must agree on it");
});

test("census --json survives a slow pipe whole, and its rejection statuses are unchanged", async () => {
  // census's --json is the output in this directory that GROWS with the ledger,
  // so it is the one that reaches the 64 KiB buffer first. --limit 3 keeps this
  // clause under a second; the tail form it exercises is the same one every
  // unbounded run uses.
  const { out, status } = await readSlowly(["census.mjs", "--json", "--limit", "3"]);
  const parsed = JSON.parse(out); // throws on a torn document
  assert.equal(status, 0, "a clean census must still report 0 through the exitCode tail");
  assert.ok(out.trimEnd().endsWith("}"), "the last byte of the document must have reached the reader");
  assert.ok(Object.keys(parsed).length > 0, "the piped document arrived empty");

  // The three named rejections leave the block with `break cliMain` now rather
  // than process.exit — the STATUS each one reports is what census.test.mjs
  // asserts and what a caller branches on, so pin it here too.
  for (const argv of [
    ["--totally-bogus-flag-xyz", "--limit", "5"],
    ["--limit", "not-a-number"],
    ["--all-rivals"],
  ]) {
    const r = await readSlowly(["census.mjs", ...argv]);
    assert.equal(r.status, 2, `census ${argv.join(" ")} must still exit 2, got ${r.status}`);
  }
  const help = await readSlowly(["census.mjs", "--help"]);
  assert.equal(help.status, 0, "--help must still exit 0");
  assert.ok(help.out.includes("census"), "and it must still print the help screen it exits after");
});

test("harvest --verify survives a slow pipe whole, and every Fatal keeps its status", async () => {
  // harvest's failing arms became `throw new Fatal(code, message)` handled by a
  // single bottom-of-file catch. The whole point is that the STATUS did not
  // move, so assert the statuses, not the refactor.
  const { out, status } = await readSlowly(["harvest.mjs", "--verify"]);
  assert.equal(status, 0, "a green fixture gate must still report 0");
  assert.match(out.trimEnd().split("\n").pop(), /^PASS: \d+ checks green/, "the PASS line is the LAST thing --verify prints, so a torn pipe eats the verdict first");

  const bad = await readSlowly(["harvest.mjs", "--no-such-mode"]);
  assert.equal(bad.status, 2, "an unknown mode must still exit 2");
  const selftest = await readSlowly(["harvest.mjs", "--selftest"]);
  assert.equal(selftest.status, 0, "a clean --selftest must still exit 0");
});

test("cli and screen keep their statuses under the exitCode tail", async () => {
  const help = await readSlowly(["cli.mjs", "--help"]);
  assert.equal(help.status, 0, "cli --help must still exit 0");
  assert.ok(help.out.includes("Exit:"), "and print the whole HELP screen, whose last section is the exit table");
  const noArgs = await readSlowly(["cli.mjs"]);
  assert.equal(noArgs.status, 2, "cli with no facts file must still exit EXIT.USAGE (2)");
  const cliSelftest = await readSlowly(["cli.mjs", "--selftest"]);
  assert.equal(cliSelftest.status, 0, "cli --selftest must still exit 0 — CI reads this status");

  const screenSelftest = await readSlowly(["screen.mjs", "--selftest"]);
  assert.equal(screenSelftest.status, 0, "screen --selftest must still exit 0");
  assert.match(screenSelftest.out, /PASS: all three named sets hold\./, "the PASS line moved under an `else` when the exit above it went — a run that passes must still print it");
  const screenBad = await readSlowly(["screen.mjs", "--no-such-mode"]);
  assert.equal(screenBad.status, 2, "an unknown screen mode must still exit 2");
});

// WHAT (B) DOES NOT COVER, said out loud rather than left to look like coverage.
// seal.mjs and trial-leads-vs-grep.mjs are in GUARDED and clause (A) reds on
// either regaining a `process.exit(`, but neither gets a piped-parse clause
// here: seal.mjs's live arms reach a Barkpark host this suite must not depend
// on (seal.test.mjs drives it through its own fixtures), and
// trial-leads-vs-grep.mjs --json over the live ledger measured 50s of wall
// clock — a cost the whole suite would pay on every run to re-prove a mechanism
// clause (C) already proves in milliseconds. Their exit statuses were exercised
// by hand at conversion time and their tails are pinned by (A).

// ─────────────────────────────────────────────────────────────────────────────
// (C) THE MECHANISM, at a size that actually tears. Two generated scripts whose
//     tails are the two forms verbatim; everything else about them identical.
// ─────────────────────────────────────────────────────────────────────────────

test("the tail form decides: process.exit tears a 1 MiB pipe, process.exitCode delivers it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "grip-d92-"));
  const body = (tail) =>
    "async function main() {\n" +
    "  process.stdout.write(`${JSON.stringify({ pad: \"x\".repeat(1048576), tail: \"END\" })}\\n`);\n" +
    "  return 0;\n" +
    "}\n" +
    `main()\n  ${tail}\n`;
  const torn = join(dir, "tail-exit.mjs");
  const whole = join(dir, "tail-exitcode.mjs");
  writeFileSync(torn, body(".then((code) => process.exit(code));"));
  writeFileSync(whole, body(".then((code) => { process.exitCode = code; });"));

  const a = await readSlowly([whole], { cwd: dir, pauseMs: 5 });
  const parsed = JSON.parse(a.out);
  assert.equal(parsed.tail, "END", "the exitCode tail must deliver the last field of a 1 MiB document");
  assert.ok(a.out.length > 1048576, `expected the whole payload, reader got ${a.out.length} bytes`);
  assert.equal(a.status, 0, "and still report 0");

  const b = await readSlowly([torn], { cwd: dir, pauseMs: 5 });
  assert.ok(
    b.out.length < a.out.length,
    `the process.exit tail must LOSE bytes a pipe had not taken yet — it delivered ${b.out.length} of ` +
      `${a.out.length}. If this is now equal, Node flushes a queued pipe write on exit and D92's premise ` +
      "has changed; re-read this file's header before touching the shipped guards",
  );
  assert.throws(() => JSON.parse(b.out), "and what the reader got must not parse — that is what the caller sees");
  assert.equal(b.status, 0, "while the process still reports SUCCESS, which is why the truncation is silent");
});
