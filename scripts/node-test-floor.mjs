#!/usr/bin/env node
// A `node --test` runner that CANNOT pass on emptiness.
//
//   node scripts/node-test-floor.mjs 'lib/**/*.test.ts' [more patterns...]
//   node scripts/node-test-floor.mjs --floor 5 'src/**/*.test.ts'
//   node scripts/node-test-floor.mjs --import ./setup.mjs -- '__tests__/*.test.ts'
//
// Everything before a `--` is forwarded to node verbatim; everything after it
// (or all of it, when there is no `--`) is a glob pattern. The separator is
// required rather than inferred, because a flag's VALUE does not start with a
// dash — `--import ./setup.mjs` would otherwise leave `./setup.mjs` looking
// exactly like a pattern, and mis-reading it as one is how a runner ends up
// gating the wrong file set.
//
// Drop-in replacement for `node --test '<glob>'` in a CI step. Dependency-free
// and node-builtin only, so the dep-free jobs that use it stay dep-free.
//
// WHAT IT DEFENDS AGAINST — all three measured on node v22.22.0:
//
//   1. ZERO-MATCH GLOB IS A PASS.
//        node --test 'lib/**/*.test.ts'   (nothing matches)
//        -> "# tests 0", EXIT 0
//      A gate whose glob stops matching goes green while proving nothing.
//
//   2. A MISSING PATH IS SILENTLY DROPPED WHEN A SIBLING MATCHES.
//        node --test real.test.mjs missing.test.mjs
//        -> "# tests 1", EXIT 0     (the missing file is not even mentioned)
//      Only when EVERY path is missing does node exit 1. So a partly-silenced
//      suite reports the same green as a whole one.
//
//   3. A FILE THAT REGISTERS NO TESTS COUNTS AS ONE PASSING TEST.
//        a file with no `test()` calls -> "# tests 1" / "ok 1 - <file path>"
//      `# tests` therefore counts the FILE, not what the file asserted, and
//      cannot distinguish "one real test" from "nothing ran".
//
//   4. A SKIPPED TEST IS INDISTINGUISHABLE FROM A TEST THAT RAN.
//        test("x", { skip: true }, ...)  -> "# Subtest: x" / "ok 1 - x # SKIP"
//        -> "# tests 1", "# pass 0", "# skipped 1", EXIT 0
//      REGISTRATION is not EXECUTION. A skipped test still emits its
//      `# Subtest:` line, so defect 3's per-file check — which counts those
//      lines — was satisfied by a file where nothing ran, and `# tests` (the
//      number this runner reports as "ran N tests") counted it as having run.
//      Measured 2026-09-18 on origin/main c511a44fc: a lone `{ skip: "..." }`
//      test printed `ran 1 tests from 1 files (pass 0, fail 0)` and exited 0,
//      and `perl -pi -e 's/^test\(/test.skip(/'` over one of
//      templates/search-starter's 12 spec files left the suite green at
//      `ran 93 tests ... (pass 83)`. So this runner now counts EXECUTED tests
//      (`# tests` minus `# skipped`), refuses any file whose executed count is
//      zero, and prints the skipped tally rather than swallowing it.
//      NOT "any skip fails": a platform-conditional `t.skip()` guarding one
//      control among many (tooling/grip/test/class-coverage.test.mjs's
//      running-as-root arm) is a legitimate shape, and a file carrying one
//      still has executed tests. The rule is per FILE, on ZERO.
//      The `ran N tests` number in the summary line is the EXECUTED count —
//      pr-meta.yml parses it as a deliberate per-suite test floor, and a floor
//      that counts skipped tests is satisfied by a suite that stopped running.
//
// THE FOUR DEFECTS ABOVE ARE CAUGHT BY DERIVATION -- the expected file count
// comes from the patterns' own expansion. A DERIVED FLOOR CANNOT CATCH THE
// FIFTH: partial deletion. Delete 4 of 5 test files and the derived floor
// shrinks to 4 along with the tree, every surviving pattern still matches, the
// survivor still registers tests, and this runner exits 0. That is not a bug in
// the derivation -- anything computed from the current tree agrees with a
// gutted tree by construction -- it is the reason `--floor N` exists.
//
//   --floor N   The call site's COMMITTED literal for how many files these
//               patterns must expand to. Below N is a hard failure naming both
//               numbers. Above N is reported, never fatal, with the new number
//               to commit. Optional; omit it and the runner behaves exactly as
//               it did before, derivation only.
//
// DECISION (task-9d5170e3fa616767): a literal at the call site, matching the
// precedent in .github/workflows/grip-suite.yml (`floor=20`). The cost is real
// and deliberate -- growing a suite means editing the workflow -- and it is the
// only thing that can be WRONG when the tree shrinks, because it does not come
// from the tree. The flag is optional rather than required so that call sites
// invoking an EXPLICIT path list rather than a glob (architecture.yml's
// `ci-boundary.test.mjs`) are not forced to carry a floor that defect 2 already
// pins: a named path that disappears reds on its own.
//
// `--floor` is the runner's own flag. It is stripped from argv before the `--`
// split, so it may sit on either side of the separator and is never forwarded
// to node.
//
// Templates and packages that must stay copy-pasteable keep their own
// self-contained `test` script; this file is for the CI step, which always has
// the whole repo checked out. sdk/scripts/run-tests.mjs is the one deliberate
// sibling: it must additionally compare compiled output against TypeScript
// sources, a concern this generic runner has no business knowing about.

import { appendFileSync, globSync } from "node:fs";
import { execFile } from "node:child_process";
import { availableParallelism } from "node:os";
import { relative, resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

const argv = process.argv.slice(2);

/**
 * Echo one line onto the GitHub Actions job summary when running in CI. The
 * runner writes it itself rather than the workflow piping through `tee`: a pipe
 * in a GitHub `run:` step (default shell `bash -e`, NOT `-o pipefail`) takes the
 * exit status of the LAST command, which is this very defect.
 * @param {string} line
 */
function summarize(line) {
  const dest = process.env.GITHUB_STEP_SUMMARY;
  if (dest) appendFileSync(dest, `${line}\n`);
}

/** @param {string} msg */
function fail(msg) {
  console.error(`\nnode-test floor FAILED: ${msg}`);
  summarize(`**node-test floor FAILED** — ${msg.split("\n")[0]}`);
  process.exit(1); // pipe-exit-ok: this is the FAIL exit; every piping caller runs under `set -o pipefail` (pr-meta.yml) so the 1 propagates through tee
}

// ------------------------------------------------------------------ arguments
// --floor is consumed here, BEFORE the `--` split, so it never reaches node and
// never gets mistaken for a glob. Every rejection below is a hard failure: a
// floor the runner could not read is a floor that is not being enforced, and
// silently continuing without one is exactly the green-on-nothing this file
// exists to refuse.
/** @type {string[]} */
const rest = [];
/** @type {number|null} */
let floor = null;
for (let i = 0; i < argv.length; i++) {
  const arg = argv[i];
  /** @type {string|undefined} */
  let raw;
  if (arg === "--floor") {
    raw = argv[++i];
  } else if (arg.startsWith("--floor=")) {
    raw = arg.slice("--floor=".length);
  } else {
    rest.push(arg);
    continue;
  }
  if (floor !== null) fail("--floor given more than once — one literal per call site, or the later one silently wins");
  if (raw === undefined || raw === "" || raw.startsWith("-")) {
    fail(`--floor needs an integer file count, got ${raw === undefined ? "nothing" : JSON.stringify(raw)}`);
  }
  if (!/^[0-9]+$/.test(/** @type {string} */ (raw))) {
    fail(`--floor needs an integer file count, got ${JSON.stringify(raw)}`);
  }
  floor = Number(raw);
  if (floor < 1) fail("--floor must be at least 1 — a floor of 0 is satisfied by an empty tree, which is the defect");
}

const sep = rest.indexOf("--");
const nodeArgs = sep === -1 ? [] : rest.slice(0, sep);
const patterns = sep === -1 ? rest : rest.slice(sep + 1);

if (patterns.length === 0) {
  fail("no glob patterns given — usage: node scripts/node-test-floor.mjs '<glob>' [<glob>...]");
}
// fs.globSync landed in node 22. Refuse loudly on an older runtime rather than
// throwing a TypeError that reads like a bug in the suite.
if (typeof globSync !== "function") {
  fail(`node ${process.version} has no fs.globSync — this runner needs node >= 22`);
}

// This runner OWNS the reporter: it parses TAP to count what each file actually
// registered, so a caller-supplied reporter would silently take over stdout and
// leave the count unreadable. That case fails closed (an unreadable count is
// treated as a failure, never a pass) — but failing closed on a caller's
// reasonable-looking flag is a bad way to learn this, so say it up front.
const clash = nodeArgs.find((a) => a === "--test-reporter" || a.startsWith("--test-reporter="));
if (clash) {
  fail(
    `${clash} cannot be forwarded — this runner sets its own TAP reporter in order to count the tests each file\n` +
      `  registered. Drop the flag: the per-file TAP output is printed verbatim, and the summary line reports the totals.`,
  );
}

// ------------------------------------------------------------------ collection
// Expanded pattern by pattern, so a pattern that matches nothing is named even
// when its siblings matched plenty. That is defect 2 above.
/** @type {string[]} */
const files = [];
for (const pattern of patterns) {
  const hits = globSync(pattern).sort();
  if (hits.length === 0) {
    fail(
      `the pattern ${JSON.stringify(pattern)} matched NO files (cwd ${process.cwd()}).\n` +
        `  \`node --test\` would have reported "# tests 0" and exited 0 here.`,
    );
  }
  for (const hit of hits) {
    const abs = resolve(hit);
    if (!files.includes(abs)) files.push(abs);
  }
}

// ------------------------------------------------------------------ the literal
// Checked BEFORE a single test process spawns: a suite that lost files has
// already failed, and making CI run the survivors first only delays the answer.
// The BELOW branch is the one that matters -- it is the only assertion in this
// file that does not derive its expectation from the tree it is measuring.
if (floor !== null && files.length < floor) {
  fail(
    `${files.length} test files discovered, floor is ${floor} — a test file stopped being discovered, ` +
      `or you deleted one and must lower the floor deliberately.\n` +
      `  Patterns: ${patterns.join(" ")} (cwd ${process.cwd()})\n` +
      `  Found: ${files.map((f) => relative(process.cwd(), f)).join(", ")}\n` +
      `  The floor is a literal committed at the CALL SITE precisely so it cannot shrink along with the tree.`,
  );
}
if (floor !== null && files.length > floor) {
  const grew =
    `node-test floor: ${files.length} test files discovered, floor is ${floor} — the suite grew; ` +
    `raise the floor to ${files.length} at the call site so the new files are pinned too.`;
  console.log(grew);
  summarize(grew);
}

// ------------------------------------------------------------------ run + count
let totalExecuted = 0;
let totalPass = 0;
let totalFail = 0;
let totalSkipped = 0;

/** @param {string} out @param {string} key @returns {number|null} */
const tally = (out, key) => {
  const m = out.match(new RegExp(`^# ${key} (\\d+)$`, "m"));
  return m ? Number(m[1]) : null;
};

/**
 * Top-level subtest names, EXCLUDING the self-referential entry node emits for
 * a file that registered no tests. That exclusion is defect 3 above.
 * @param {string} out @param {string} filePath @returns {string[]}
 */
const realTests = (out, filePath) =>
  out
    .split("\n")
    .map((line) => /^# Subtest: (.*)$/.exec(line))
    .filter((m) => m !== null)
    .map((m) => /** @type {RegExpExecArray} */ (m)[1])
    .filter((name) => name !== filePath && name !== relative(process.cwd(), filePath));

// One process PER FILE, so the zero-test floor is per file: a single aggregate
// `# tests` would hide an empty file behind its siblings' counts. That costs a
// process spawn each, so the files run CONCURRENTLY — on web/'s 55 files the
// sequential form took 27s against the old gate's 9s, which is a real tax on a
// gate that runs on every PR. Pooled, it lands back in the same range.
const limit = Math.max(1, availableParallelism());
/** @type {{shown: string, status: number, out: string, err: string}[]} */
const results = new Array(files.length);
let next = 0;

async function worker() {
  while (next < files.length) {
    const i = next++;
    const file = files[i];
    const args = [...nodeArgs, "--test", "--test-reporter=tap", "--test-reporter-destination=stdout", file];
    try {
      const { stdout, stderr } = await run(process.execPath, args, { maxBuffer: 64 * 1024 * 1024 });
      results[i] = { shown: relative(process.cwd(), file), status: 0, out: stdout, err: stderr };
    } catch (e) {
      // execFile rejects on a non-zero exit; the output is still on the error.
      const err = /** @type {{code?: number, stdout?: string, stderr?: string}} */ (e);
      results[i] = {
        shown: relative(process.cwd(), file),
        status: typeof err.code === "number" ? err.code : 1,
        out: err.stdout ?? "",
        err: err.stderr ?? String(e),
      };
    }
  }
}

await Promise.all(Array.from({ length: Math.min(limit, files.length) }, worker));

// Evaluated in FILE order, so the report is deterministic regardless of which
// worker finished first.
for (const r of results) {
  process.stdout.write(r.out);
  process.stderr.write(r.err);

  const tests = tally(r.out, "tests");
  if (tests === null) fail(`${r.shown}: no test count in the runner output — an unreadable result is a failure, never a pass`);
  if (r.status !== 0) fail(`${r.shown}: node --test exited ${r.status}`);
  if (realTests(r.out, resolve(r.shown)).length < 1) {
    fail(
      `${r.shown}: registered 0 tests (node reported "# tests ${tests}", which counts the FILE, not a test) — ` +
        `a test file that asserts nothing is a hole in the suite, not a pass`,
    );
  }

  // Defect 4. `# skipped` is node's own aggregate over every level, so a
  // nested-only skip leaves the top-level test counted as executed, which is
  // correct: the outer test DID run. An unreadable `# skipped` is read as 0
  // rather than failing closed — the line has been in node's TAP summary since
  // the reporter existed, and the count above already failed closed for us.
  const skipped = tally(r.out, "skipped") ?? 0;
  const executed = tests - skipped;
  if (executed < 1) {
    fail(
      `${r.shown}: registered ${tests} test(s) and executed NONE — all ${skipped} were skipped ` +
        `(node reported "# tests ${tests}", "# skipped ${skipped}", "# pass ${tally(r.out, "pass") ?? 0}" and exited 0).\n` +
        `  A skipped test emits the same "# Subtest:" line as one that ran, so registration is not evidence of execution.\n` +
        `  Un-skip at least one test in this file, or delete the file and lower the floor at the call site deliberately.`,
    );
  }

  totalExecuted += executed;
  totalSkipped += skipped;
  totalPass += tally(r.out, "pass") ?? 0;
  totalFail += tally(r.out, "fail") ?? 0;
}

if (totalFail > 0) fail(`${totalFail} failing test(s)`);

// `ran N` is the EXECUTED count, never the registered one — see defect 4. The
// `ran N tests from M files (pass P, fail F` prefix is load-bearing: pr-meta.yml
// parses it with `sed -nE 's/^node-test floor: ran ([0-9]+) tests .*/\1/p'`.
const summary = `node-test floor: ran ${totalExecuted} tests from ${files.length} files (pass ${totalPass}, fail ${totalFail}${totalSkipped > 0 ? `, skipped ${totalSkipped}` : ""}) for ${patterns.join(" ")}${floor !== null ? ` [floor ${floor} files]` : ""}${nodeArgs.length ? ` [node ${nodeArgs.join(" ")}]` : ""}`;
console.log(`\n${summary}`);
summarize(summary);
