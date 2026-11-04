#!/usr/bin/env node
// Reconciles the chain `npm test` runs (scripts/test-chain.mjs) against the test files
// actually on disk.
//
// The runner finds its tests itself, so a test file can no longer be left out by
// forgetting to append it. What can still go wrong is the runner: a predicate that
// narrows, a folder it stops walking, a FIRST entry that was renamed, a script that no
// longer calls it. This census walks src/ on its own and checks, in both directions:
//   1. every file under src/ named __*.test.mjs is in the chain;
//   2. every path in the chain exists, and none is there twice;
//   3. package.json's test script is the runner, and no npm hook runs a chain of its own;
//   4. every smoke case module that directly imports check from the shared harness is
//      imported exactly once by the aggregate smoke index.
// An empty disk set or an empty chain also exits 1: a census that found nothing is
// broken, not clean.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { chain } from '../scripts/test-chain.mjs';

const pkgRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const srcRoot = path.join(pkgRoot, 'src');
const smokeRoot = path.join(srcRoot, 'smoke');
const smokeIndex = path.join(srcRoot, '__smoke.mjs');
const RUNNER = 'node scripts/test-chain.mjs';

const isTestFile = (name) => name.startsWith('__') && name.endsWith('.test.mjs');

function walk(dir, prefix = 'src') {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const abs = path.join(dir, entry.name);
    const rel = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) out.push(...walk(abs, rel));
    else if (entry.isFile() && isTestFile(entry.name)) out.push(rel);
  }
  return out;
}

if (!existsSync(srcRoot) || !statSync(srcRoot).isDirectory()) {
  console.error(`test-chain census: FAIL — ${srcRoot} is not a directory`);
  process.exit(1);
}

const { scripts } = JSON.parse(readFileSync(path.join(pkgRoot, 'package.json'), 'utf8'));
const onDisk = walk(srcRoot).sort();
const named = chain(pkgRoot);
const inChain = new Set(named);

const problems = [];

const directCheckImport = /^import\s*\{[^}]*\bcheck\b[^}]*\}\s*from\s*["']\.\/harness\.mjs["'];\s*$/m;
const directSmokeImport = /^import\s+["']\.\/smoke\/([^"']+\.mjs)["'];\s*$/gm;
const hasSmokeRoot = existsSync(smokeRoot) && statSync(smokeRoot).isDirectory();
const hasSmokeIndex = existsSync(smokeIndex) && statSync(smokeIndex).isFile();
if (hasSmokeRoot && !hasSmokeIndex) {
  problems.push('src/smoke exists but src/__smoke.mjs does not');
}
if (hasSmokeRoot && hasSmokeIndex) {
  const smokeCases = readdirSync(smokeRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.mjs'))
    .filter((entry) => directCheckImport.test(readFileSync(path.join(smokeRoot, entry.name), 'utf8')))
    .map((entry) => entry.name)
    .sort();
  const smokeImports = [...readFileSync(smokeIndex, 'utf8').matchAll(directSmokeImport)]
    .map((match) => match[1]);
  const smokeImportCounts = new Map();
  for (const name of smokeImports) smokeImportCounts.set(name, (smokeImportCounts.get(name) ?? 0) + 1);

  if (smokeCases.length === 0) problems.push('no smoke case module directly imports check from ./harness.mjs');
  for (const name of smokeCases) {
    const count = smokeImportCounts.get(name) ?? 0;
    if (count === 0) problems.push(`src/smoke/${name} imports check but src/__smoke.mjs does not import it`);
    if (count > 1) problems.push(`src/__smoke.mjs imports smoke case src/smoke/${name} ${count} times`);
  }
}

if (onDisk.length === 0) problems.push('no files matching src/**/__*.test.mjs exist — the suite cannot be empty');
if (named.length === 0) problems.push('scripts/test-chain.mjs names no files');
if (scripts.test !== RUNNER) problems.push(`package.json's test script is ${JSON.stringify(scripts.test)}, not ${JSON.stringify(RUNNER)}`);
for (const hook of ['pretest', 'posttest']) {
  if (hook in scripts) problems.push(`package.json has a ${hook} script; the runner is the whole chain — move its files into src/ as __*.test.mjs`);
}

for (const rel of onDisk.filter((rel) => !inChain.has(rel))) {
  problems.push(`${rel} exists on disk but the runner does not run it — its discovery is broken`);
}
for (const rel of named.filter((rel) => !existsSync(path.join(pkgRoot, rel)))) {
  problems.push(`${rel} is in the chain but does not exist on disk — fix FIRST in scripts/test-chain.mjs`);
}
if (inChain.size !== named.length) {
  problems.push(`the chain names ${named.length - inChain.size} file(s) twice`);
}

const summary = `test-chain census: ${onDisk.length} test files on disk, ${named.length} files in the chain`;

if (problems.length > 0) {
  console.error(summary);
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`test-chain census: FAIL (${problems.length} problem${problems.length === 1 ? '' : 's'})`);
  process.exit(1);
}

console.log(`${summary} — reconciled, 0 drift`);
