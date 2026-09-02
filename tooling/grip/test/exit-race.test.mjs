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
// its own evidence. This file is the pin so that cannot come back in any of the
// three.
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
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = join(HERE, "..");

/** The three entry guards charter D92 governs. ledger.mjs is the reference fix. */
const GUARDED = ["backfill.mjs", "acceptance.mjs", "ledger.mjs"];

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
  // Verbatim from the pre-fix tree — the scanner must call BOTH of these out,
  // or clause (A) above is green because it cannot see, not because it is true.
  const backfillTail = "  main(process.argv.slice(2))\n    .then((code) => process.exit(code))\n";
  const acceptanceTail = "  process.exit(outcome.ok ? 0 : 1);\n";
  assert.equal(callsExit(backfillTail), true, "the backfill tail that shipped must read as an offender");
  assert.equal(callsExit(acceptanceTail), true, "the acceptance tail that shipped must read as an offender");
  assert.equal(setsExitCode(backfillTail), false, "and neither of them sets exitCode");
  // …and the scanner must NOT be fooled into a red by prose ABOUT the defect,
  // which every one of the three fixed guards now carries above it.
  const prose = "  // process.exit(code) TRUNCATES a not-yet-flushed pipe.\n  process.exitCode = 0;\n";
  assert.equal(callsExit(prose), false, "a full-line comment naming the anti-pattern is not a call");
  assert.equal(setsExitCode(prose), true, "and the fix underneath it must still be seen");
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
