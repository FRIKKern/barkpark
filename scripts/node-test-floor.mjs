#!/usr/bin/env node
// A `node --test` runner that CANNOT pass on emptiness.
//
//   node scripts/node-test-floor.mjs 'lib/**/*.test.ts' [more patterns...]
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
// EVERY FLOOR HERE IS DERIVED, never a hand-written literal: the expected file
// count comes from the patterns' own expansion, so it moves with the suite.
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
const sep = argv.indexOf("--");
const nodeArgs = sep === -1 ? [] : argv.slice(0, sep);
const patterns = sep === -1 ? argv : argv.slice(sep + 1);

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
  process.exit(1);
}

if (patterns.length === 0) {
  fail("no glob patterns given — usage: node scripts/node-test-floor.mjs '<glob>' [<glob>...]");
}
// fs.globSync landed in node 22. Refuse loudly on an older runtime rather than
// throwing a TypeError that reads like a bug in the suite.
if (typeof globSync !== "function") {
  fail(`node ${process.version} has no fs.globSync — this runner needs node >= 22`);
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

// ------------------------------------------------------------------ run + count
let totalTests = 0;
let totalPass = 0;
let totalFail = 0;

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

  totalTests += tests;
  totalPass += tally(r.out, "pass") ?? 0;
  totalFail += tally(r.out, "fail") ?? 0;
}

if (totalFail > 0) fail(`${totalFail} failing test(s)`);

const summary = `node-test floor: ran ${totalTests} tests from ${files.length} files (pass ${totalPass}, fail ${totalFail}) for ${patterns.join(" ")}${nodeArgs.length ? ` [node ${nodeArgs.join(" ")}]` : ""}`;
console.log(`\n${summary}`);
summarize(summary);
