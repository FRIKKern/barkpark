#!/usr/bin/env node
// Reconciles the hand-written `node src/…` chains in package.json against the
// test files actually on disk.
//
// The paper-editor gate is a chain of explicit `node <path>` invocations spread
// across the `pretest`, `test` and `posttest` scripts. Explicit paths are worth
// keeping — a path that no longer exists makes node exit 1, so this gate is not
// satisfiable by emptiness the way a zero-match glob is. What an explicit list
// cannot do is notice a test file that was never appended to it: the gate stays
// green at 100% of the tests it was told about while the denominator it should
// have used silently grew.
//
// This census closes exactly that hole, in both directions:
//   1. every file matching the chain's own naming convention (src/**/__*.test.mjs)
//      must be named by one of the three scripts;
//   2. every path the scripts name must exist on disk.
// Either mismatch exits 1. An empty disk set also exits 1, so the emptiness
// property the explicit list already had is preserved rather than traded away.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const pkgRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const srcRoot = path.join(pkgRoot, 'src');

// The predicate, stated once and derived from the chain's own convention:
// a test file is any file under src/ (at any depth) named __*.test.mjs.
// Runner entrypoints such as __smoke.mjs / __narrow_render.mjs do not match and
// are therefore not required to appear — but if a script names them they still
// have to exist (direction 2 below).
const isTestFile = (name) => name.startsWith('__') && name.endsWith('.test.mjs');

function walk(dir, prefix = 'src') {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const abs = path.join(dir, entry.name);
    const rel = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) out.push(...walk(abs, rel));
    else if (entry.isFile() && isTestFile(entry.name)) out.push(rel);
  }
  return out;
}

const SCRIPT_KEYS = ['pretest', 'test', 'posttest'];

const pkg = JSON.parse(readFileSync(path.join(pkgRoot, 'package.json'), 'utf8'));
const scripts = pkg.scripts || {};

const invoked = new Map(); // rel path -> [script keys naming it]
for (const key of SCRIPT_KEYS) {
  const body = scripts[key];
  if (typeof body !== 'string') continue;
  for (const m of body.matchAll(/\bnode\s+(src\/[^\s&|;"']+)/g)) {
    const rel = m[1];
    if (!invoked.has(rel)) invoked.set(rel, []);
    invoked.get(rel).push(key);
  }
}

if (!existsSync(srcRoot) || !statSync(srcRoot).isDirectory()) {
  console.error(`test-chain census: FAIL — ${srcRoot} is not a directory`);
  process.exit(1);
}

const onDisk = walk(srcRoot);

const problems = [];

// Emptiness reds. A census that found no test files is a broken census, not a
// clean bill of health.
if (onDisk.length === 0) {
  problems.push(`no files matching src/**/__*.test.mjs exist — the suite cannot be empty`);
}
if (invoked.size === 0) {
  problems.push(`none of ${SCRIPT_KEYS.join('/')} name any \`node src/…\` invocation`);
}

// Direction 1: on disk, never invoked.
const missingFromChain = onDisk.filter((rel) => !invoked.has(rel));
for (const rel of missingFromChain) {
  problems.push(`${rel} exists on disk but no ${SCRIPT_KEYS.join('/')} script runs it — append it to the chain`);
}

// Direction 2: invoked, does not exist.
const missingFromDisk = [...invoked.keys()]
  .filter((rel) => !existsSync(path.join(pkgRoot, rel)))
  .sort();
for (const rel of missingFromDisk) {
  problems.push(`${rel} is named by ${invoked.get(rel).join('+')} but does not exist on disk — remove or fix the entry`);
}

const summary = `test-chain census: ${onDisk.length} test files on disk, ${invoked.size} paths named across ${SCRIPT_KEYS.join('+')}`;

if (problems.length > 0) {
  console.error(summary);
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`test-chain census: FAIL (${problems.length} problem${problems.length === 1 ? '' : 's'})`);
  process.exit(1);
}

console.log(`${summary} — reconciled, 0 drift`);
