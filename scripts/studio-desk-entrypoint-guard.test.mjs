#!/usr/bin/env node
//
// studio-desk-entrypoint-guard.test.mjs — the PROCESS tests for the two ways
// the instrument used to fail unreadably before it measured anything.
//
// Every other studio-desk self-test imports the instrument and exercises a pure
// function. These two defects cannot be reached that way, because both of them
// are about what the PROCESS does:
//
//   1. D130 — THE SYMLINK ENTRYPOINT GUARD. `INVOKED_DIRECTLY` used to compare
//      `path.resolve(process.argv[1])` against `fileURLToPath(import.meta.url)`.
//      That is asymmetric: Node resolves ESM module URLs through realpath while
//      `argv[1]` is whatever the shell handed over, verbatim. Run through ANY
//      symlink — macOS `/tmp` -> `/private/tmp`, a checkout reached through one,
//      a `ln -s` convenience shim — the two strings differed, the guard said
//      "this file was imported", and the process exited 0 having written ZERO
//      bytes to stdout AND stderr. Piped through `tee` that is an empty file at
//      exit 0: indistinguishable from a tooling hiccup, and one careless `|
//      tail` from being read as "no failures". Source inspection cannot prove a
//      process exit code, so this file spawns the instrument through a real
//      symlink and reads the code and the bytes.
//
//   2. THE `--out` TEMPORAL DEAD ZONE. `resolveOutPath()` composes three named,
//      one-line refusals through `die`, which is a `const` declared ~200 lines
//      below it. Resolving `OUT_PATH` at module scope put all three inside
//      `die`'s temporal dead zone, so a malformed `--out` printed a raw
//      `ReferenceError: Cannot access 'die' before initialization` stack trace
//      instead of the sentence it had carefully written. Same class of defect as
//      D130 — the instrument failing in a shape nobody can read — reintroduced
//      by the fix for it. Only a spawn sees the difference: the message and the
//      ReferenceError are both "it threw" to an importer.
//
// Nothing here needs ssh, a browser, or the deployed box. Every argument in the
// table is refused during argv parsing, in the first ~100ms, BEFORE the
// authenticated sweep exists — which is the same property (D115) that makes
// these refusals worth having at all. The last test prints and bounds the total
// wall time, so "it is too slow to run in CI" can never be asserted, only
// measured.
//
//   node --test scripts/studio-desk-entrypoint-guard.test.mjs

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');
const REPO = path.resolve(HERE, '..');

/** An argument the instrument must refuse during argv parsing — before ssh,
 *  before a browser, before a row exists. `--sha=main` is a NAMED refusal
 *  (a branch name is not a commit SHA), so a run that reaches the network has
 *  taken a different path than the one under test and the wall-time bound below
 *  will say so. */
const FAILING_ARGS = ['--sha=main'];

/** Every spawn's wall time, so the CI-cheapness claim is a measurement. */
const timings = [];

function run(argv0, args, { cwd = REPO } = {}) {
  const started = Date.now();
  const r = spawnSync(process.execPath, [argv0, ...args], {
    cwd,
    encoding: 'utf8',
    timeout: 30_000,
    // A parent `--sha`/`--out` in the environment must not steer the child.
    env: { ...process.env, BP_DESK_SHA: '', BP_DESK_RETRIES: '0' },
  });
  timings.push({ ms: Date.now() - started, argv0, args });
  assert.equal(r.error, undefined, `spawn itself failed: ${r.error?.message}`);
  return r;
}

// ── 1. D130: the symlink entrypoint guard ────────────────────────────────────

test('the instrument RUNS when invoked through a symlink — exit 1, non-empty stderr', (t) => {
  // The symlink lives in a scratch dir of its own, so the link's directory is
  // not the script's directory: that is the shape that broke, and it is also
  // the shape that proves `HERE`/`REPO` still resolve through realpath.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spd-b46-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const link = path.join(dir, 'studio-desk-measure.mjs');
  fs.symlinkSync(INSTRUMENT, link);
  assert.ok(fs.lstatSync(link).isSymbolicLink(), 'fixture check: the entrypoint really is a symlink');
  assert.notEqual(fs.realpathSync(link), link,
    'fixture check: the link path and its realpath must DIFFER, or this test proves nothing');

  const r = run(link, FAILING_ARGS);

  // This is the whole of D130. Before the fix these three assertions read
  // status 0, stderr '', stdout '' — a silent, successful-looking nothing.
  assert.equal(r.status, 1,
    `a refused argument must exit 1 through a symlink exactly as it does through the real path ` +
    `(got status ${r.status}; stdout ${r.stdout.length}B, stderr ${r.stderr.length}B). ` +
    `Exit 0 with no output means INVOKED_DIRECTLY went false and the instrument silently IMPORTED itself.`);
  assert.ok(r.stderr.trim().length > 0,
    'a failed run must say so on stderr — a rotted run must be VISIBLY rotted, never silently absent (D81/D97)');
  assert.match(r.stderr, /MEASURE FAILED/,
    'the failure must arrive through the instrument\'s ONE failure handler, by name');
});

test('the SAME invocation through the real path behaves identically — the positive control', () => {
  // Without this, a symlink run that exited 1 for an unrelated reason (a broken
  // import, a missing dep) would read as a passing guard.
  const r = run(INSTRUMENT, FAILING_ARGS);
  assert.equal(r.status, 1, 'the control must fail too, or the chosen argument does not actually fail');
  assert.ok(r.stderr.trim().length > 0);
  assert.match(r.stderr, /hex commit SHA/,
    'the control must fail for the REASON under test — argv parsing — not incidentally');
});

test('the symlink and the real path produce the SAME refusal text', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spd-b46-'));
  try {
    const link = path.join(dir, 'linked-instrument.mjs');
    fs.symlinkSync(INSTRUMENT, link);
    const viaLink = run(link, FAILING_ARGS);
    const viaReal = run(INSTRUMENT, FAILING_ARGS);
    assert.equal(viaLink.status, viaReal.status);
    assert.equal(viaLink.stderr, viaReal.stderr,
      'a symlinked entrypoint must be the same program, not a differently-behaving one');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the guard puts BOTH sides through realpath — the asymmetric form is what broke', () => {
  const SRC = fs.readFileSync(INSTRUMENT, 'utf8');
  assert.match(SRC, /realResolve\(process\.argv\[1\]\) === realResolve\(fileURLToPath\(import\.meta\.url\)\)/,
    'INVOKED_DIRECTLY must realpath BOTH sides; comparing a resolved argv[1] against a realpathed ' +
    'module URL is the D130 asymmetry and it is invisible until a symlink is on the path');
});

// ── 2. the three `--out` refusals, by name and without a stack ───────────────

const OUT_CASES = [
  {
    what: 'an empty value',
    args: ['--out='],
    expect: /--out was passed with an empty value/,
  },
  {
    what: 'followed by another flag',
    args: ['--out', '--json'],
    expect: /--out was followed by `--json`, which is another flag, not a path/,
  },
  {
    what: 'as the last argument',
    args: ['--out'],
    expect: /--out was the last argument, with no path after it/,
  },
];

for (const { what, args, expect } of OUT_CASES) {
  test(`--out ${what} exits 1 with its OWN named message, not a stack trace`, () => {
    const r = run(INSTRUMENT, args);
    assert.equal(r.status, 1, `\`${args.join(' ')}\` must be refused (stderr: ${r.stderr.slice(0, 300)})`);
    assert.match(r.stderr, expect,
      'each of the three paths composed its own sentence; a shared or generic one is a regression in ' +
      'the only thing the operator actually reads');
    // The temporal dead zone. `die` is a `const` ~200 lines below resolveOutPath,
    // so resolving OUT_PATH at module scope replaces every sentence above with
    // `ReferenceError: Cannot access 'die' before initialization` and a stack.
    assert.ok(!r.stderr.includes('ReferenceError'),
      `a malformed --out must produce the named refusal, never a ReferenceError — that is the ` +
      `temporal dead zone this resolution was moved to the entrypoint to escape. stderr:\n${r.stderr}`);
    assert.ok(!r.stderr.includes('\n    at '),
      `a refused ARGUMENT is not a crash: no stack frames belong on stderr. stderr:\n${r.stderr}`);
    assert.match(r.stderr, /MEASURE FAILED/,
      'the refusal must land in the instrument\'s one failure handler, like every other named abort');
  });
}

test('a malformed --out is refused through a SYMLINK too — the two defects compose', () => {
  // Each was fixed alone. This is the only assertion that says the fix for one
  // still holds while the other fires.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spd-b46-'));
  try {
    const link = path.join(dir, 'shim.mjs');
    fs.symlinkSync(INSTRUMENT, link);
    const r = run(link, ['--out']);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /--out was the last argument/);
    assert.ok(!r.stderr.includes('ReferenceError'));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('OUT_PATH is resolved at the ENTRYPOINT, never at module scope', () => {
  // The structural half of the case above: it names WHERE, so a reviewer who
  // moves the line meets a red that explains itself rather than three
  // ReferenceErrors that do not.
  const SRC = fs.readFileSync(INSTRUMENT, 'utf8');
  const declaration = SRC.indexOf('let OUT_PATH = null;');
  const guard = SRC.indexOf('if (INVOKED_DIRECTLY) {');
  const assign = SRC.indexOf('OUT_PATH = resolveOutPath()');
  assert.ok(declaration !== -1 && guard !== -1 && assign !== -1, 'anchors moved — re-read the entrypoint');
  assert.ok(assign > guard,
    'the resolution must sit INSIDE the INVOKED_DIRECTLY chain: at module scope it is in `die`\'s ' +
    'temporal dead zone, and it also couples IMPORT of this file to the importer\'s command line');
});

// ── 3. cheap enough that nobody is tempted to skip it ────────────────────────

test('every spawn refused during argv parsing — no ssh, no browser, no box', () => {
  assert.ok(timings.length >= 8, `expected the table above to have spawned; got ${timings.length}`);
  const total = timings.reduce((n, t) => n + t.ms, 0);
  const slowest = Math.max(...timings.map((t) => t.ms));
  console.log(`[spd-b46] ${timings.length} spawns, ${total}ms total, slowest ${slowest}ms`);
  // An authenticated sweep is 30-60s and an ssh provenance read is seconds. A
  // spawn that took even 5s did not fail in the parser, which is the claim.
  assert.ok(slowest < 5_000,
    `every argument here is refused before the network exists; ${slowest}ms means one run got further ` +
    `than argv parsing — pick a different argument rather than relaxing this bound`);
});
