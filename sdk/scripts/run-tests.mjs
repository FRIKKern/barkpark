#!/usr/bin/env node
// The sdk/ test gate. Runs the suite AND refuses to pass on emptiness.
//
// WHY THIS EXISTS. The previous gate was:
//     "test": "tsc && node --test \"dist/test/**/*.test.js\""
// `node --test` with a glob that matches NOTHING prints `# tests 0` and exits
// 0, so "0 tests ran" and "33 tests passed" were the same green check. Deleting
// one string from tsconfig.json's `include` ("test/**/*.ts") silenced all 33
// assertions with no warning in the log — measured, not theorised.
//
// A second, smaller footgun: `tsc` does not clean dist/, so a LOCAL run kept
// executing compiled mirrors of test files that no longer existed in source.
//
// THE PREDICATE HERE REFUSES EMPTINESS, in five places:
//   1. zero source test files under test/            -> FAIL
//   2. any source test file with no compiled output  -> FAIL (names each one)
//   3. any compiled test file with no source         -> FAIL (stale mirror)
//   4. any file registering zero tests               -> FAIL (per file, never in aggregate)
//   5. a test count that cannot be read at all       -> FAIL (never treated as a pass)
//
// Floor 4 does NOT trust `# tests`. Measured on node v22.22.0: a file with no
// `test()` calls still reports `# tests 1` / `ok 1 - <file path>` — the FILE
// counted as its own passing test. Real tests are counted from the top-level
// subtest names instead, with that self-referential entry excluded.
// Every floor is DERIVED from the source tree — never a hand-written literal —
// so it moves with the suite instead of going stale.
//
// The last line printed is machine-greppable, so a future emptiness regression
// is visible in the CI log without re-running the mutation:
//     sdk gate: ran <N> tests from <F> files (pass <P>, fail <X>)

import { appendFileSync, existsSync, readdirSync, rmSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const SRC_TESTS = join(ROOT, "test");
const OUT_TESTS = join(ROOT, "dist", "test");

/**
 * Echo a line onto the GitHub Actions job summary when running in CI, so the
 * test count is readable without scrolling the log. The runner writes this
 * itself rather than the workflow piping `npm test` through `tee`: a pipe in a
 * GitHub `run:` step (whose default shell is `bash -e`, NOT `-o pipefail`)
 * takes the exit status of the LAST command, which would hand this gate the
 * very defect it exists to prevent.
 * @param {string} line
 */
function summarize(line) {
  const dest = process.env.GITHUB_STEP_SUMMARY;
  if (dest) appendFileSync(dest, `${line}\n`);
}

/** @param {string} msg */
function fail(msg) {
  console.error(`\nsdk gate FAILED: ${msg}`);
  summarize(`**sdk gate FAILED** — ${msg.split("\n")[0]}`);
  process.exit(1);
}

/**
 * Every file under `dir` whose name ends with `suffix`, as paths relative to
 * `dir`, POSIX-separated so the source/compiled comparison is platform-stable.
 * @param {string} dir @param {string} suffix @returns {string[]}
 */
function walk(dir, suffix) {
  if (!existsSync(dir)) return [];
  /** @type {string[]} */
  const found = [];
  /** @param {string} current */
  const visit = (current) => {
    for (const entry of readdirSync(current)) {
      const full = join(current, entry);
      if (statSync(full).isDirectory()) visit(full);
      else if (entry.endsWith(suffix)) found.push(relative(dir, full).split(sep).join("/"));
    }
  };
  visit(dir);
  return found.sort();
}

// ---------------------------------------------------------------- clean build
// Delete dist/ first: tsc never removes stale output, and a stale mirror of a
// deleted test is a green that proves nothing.
rmSync(join(ROOT, "dist"), { recursive: true, force: true });

const tscBin = join(ROOT, "node_modules", "typescript", "bin", "tsc");
if (!existsSync(tscBin)) fail(`typescript is not installed (${tscBin} is missing) — run \`npm ci\` in sdk/`);
const built = spawnSync(process.execPath, [tscBin], { cwd: ROOT, stdio: "inherit" });
if (built.status !== 0) fail(`tsc exited ${built.status}`);

// --------------------------------------------------------- collection floors
const sources = walk(SRC_TESTS, ".test.ts");
if (sources.length === 0) {
  fail(`no *.test.ts files under ${relative(ROOT, SRC_TESTS)}/ — an empty suite is not a passing suite`);
}

const expected = sources.map((p) => `${p.slice(0, -".ts".length)}.js`);
const compiled = walk(OUT_TESTS, ".test.js");

const missing = expected.filter((p) => !compiled.includes(p));
if (missing.length > 0) {
  fail(
    `${missing.length} of ${expected.length} test file(s) compiled to nothing — the suite would have run PARTIALLY OR NOT AT ALL.\n` +
      `  Most likely cause: tsconfig.json no longer includes "test/**/*.ts", or rootDir moved.\n` +
      missing.map((p) => `  missing: dist/test/${p}`).join("\n"),
  );
}

const orphans = compiled.filter((p) => !expected.includes(p));
if (orphans.length > 0) {
  fail(
    `${orphans.length} compiled test file(s) have no source — stale output would be executed as if it were real:\n` +
      orphans.map((p) => `  orphan: dist/test/${p}`).join("\n"),
  );
}

// --------------------------------------------------------------- run + count
// One runner process PER FILE, so the floor is per-file: a file that collects
// zero tests is a hole in the suite, and a single aggregate `# tests` total
// would hide that hole behind its siblings' counts.
let totalTests = 0;
let totalPass = 0;
let totalFail = 0;

/** @param {string} out @param {string} key @returns {number|null} */
const tally = (out, key) => {
  const m = out.match(new RegExp(`^# ${key} (\\d+)$`, "m"));
  return m ? Number(m[1]) : null;
};

/**
 * Top-level subtest names, EXCLUDING the self-referential entry node emits when
 * a file registers no tests at all. Measured on node v22.22.0: a file with zero
 * `test()` calls still reports `# tests 1` / `ok 1 - <the file path>`. Counting
 * that entry counts the door, not what the door saw — so `# tests` alone cannot
 * tell "one real test" from "no tests whatsoever".
 * @param {string} out @param {string} filePath @returns {string[]}
 */
const topLevelSubtests = (out, filePath) =>
  out
    .split("\n")
    .map((line) => /^# Subtest: (.*)$/.exec(line))
    .filter((m) => m !== null)
    .map((m) => /** @type {RegExpExecArray} */ (m)[1])
    .filter((name) => name !== filePath);

for (const rel of expected) {
  const filePath = join(OUT_TESTS, rel);
  const run = spawnSync(
    process.execPath,
    ["--test", "--test-reporter=tap", "--test-reporter-destination=stdout", filePath],
    { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  const out = run.stdout ?? "";
  process.stdout.write(out);
  process.stderr.write(run.stderr ?? "");

  const tests = tally(out, "tests");
  const pass = tally(out, "pass");
  const failed = tally(out, "fail");

  if (tests === null) {
    fail(`dist/test/${rel}: no test count in the runner output — an unreadable result is a failure, never a pass`);
  }
  if (run.status !== 0) {
    fail(`dist/test/${rel}: node --test exited ${run.status} (${failed ?? "?"} failing)`);
  }
  // THE FLOOR. Derived from the tree, never a hand-written literal: every file
  // that exists must contribute at least one REAL test. Both `# tests 0` and
  // node's `# tests 1` for a file that registered nothing are rejected here.
  const real = topLevelSubtests(out, filePath);
  if (real.length < 1) {
    fail(
      `dist/test/${rel}: registered 0 tests (node reported "# tests ${tests}", which counts the FILE, not a test) — ` +
        `a test file that asserts nothing is a hole in the suite, not a pass`,
    );
  }

  totalTests += tests;
  totalPass += pass ?? 0;
  totalFail += failed ?? 0;
}

if (totalFail > 0) fail(`${totalFail} failing test(s)`);

const summary = `sdk gate: ran ${totalTests} tests from ${expected.length} files (pass ${totalPass}, fail ${totalFail})`;
console.log(`\n${summary}`);
summarize(summary);
