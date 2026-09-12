#!/usr/bin/env node
// EVERY GRIP CLI SPELLS ITS ENTRY GUARD THE SAME WAY.
//
//   node --test tooling/grip/test/entry-guard-uniformity.test.mjs
//
// WHY THIS FILE EXISTS. An entry guard that reads false is the quietest failure
// a CLI has: main() never runs, nothing is printed, and the process exits 0 —
// indistinguishable from a clean pass to any caller that reads the status.
// seal.mjs shipped `import.meta.url === `file://${process.argv[1]}`` and was
// fixed under task-9e6de5502ce017c0; trial-leads-vs-grep.mjs was the last file
// still comparing `fileURLToPath(import.meta.url)` against a RAW
// `process.argv[1]`, with resolve() on neither side (task-f765add393247dfd).
//
// This sweep is a PREDICATE OVER THE DIRECTORY, not a list of the two files
// somebody happened to notice. The next module added to tooling/grip/ is
// covered the day it lands.
//
// WHAT IT DOES NOT CLAIM. It does not claim the canonical form is invulnerable.
// Measured 2026-09-10: invoked through a SYMLINK, both the resolve()'d and the
// un-resolve()'d forms read false, because import.meta.url is realpath'd and
// process.argv[1] is not — resolve() normalises, it does not follow links. The
// claim here is uniformity: one spelling, so a reader checks one thing.
//
// HERMETIC. Reads source text off disk. Spawns nothing, imports no subject.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const GRIP = join(dirname(fileURLToPath(import.meta.url)), "..");

// The canonical form, as it stands in cli/census/screen/ledger/backfill/
// acceptance/seal — resolve() on BOTH sides, and the argv[1] presence check.
const CANONICAL = /process\.argv\[1\]\s*&&\s*resolve\(process\.argv\[1\]\)\s*===\s*resolve\(fileURLToPath\(import\.meta\.url\)\)/;

// Any line that decides main-ness off argv[1]. Prose mentions are excluded by
// requiring the comparison, not the token.
const GUARD_LINE = /^(?!\s*(\/\/|\*)).*process\.argv\[1\].*===/;

function guardLines(source) {
  return source.split("\n").filter((l) => GUARD_LINE.test(l));
}

function modules() {
  return readdirSync(GRIP).filter((f) => f.endsWith(".mjs")).sort();
}

test("the detector is not blind — it sees a guard and rejects the half-fixed form", () => {
  const bad = "if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {";
  const good = "const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));";
  assert.equal(guardLines(bad).length, 1, "the guard-line detector must SEE a guard");
  assert.equal(CANONICAL.test(bad), false, "the half-fixed form must not pass as canonical");
  assert.equal(CANONICAL.test(good), true, "the canonical form must pass");
  assert.equal(guardLines("// process.argv[1] === something, in prose").length, 0,
    "a prose mention must not be read as a guard");
});

test("every tooling/grip CLI guard is the canonical resolve()-on-both-sides form", () => {
  const offenders = [];
  let checked = 0;
  for (const file of modules()) {
    for (const line of guardLines(readFileSync(join(GRIP, file), "utf8"))) {
      checked++;
      if (!CANONICAL.test(line)) offenders.push(`${file}: ${line.trim()}`);
    }
  }
  // CONTROL: an empty sweep would report "all clean" having read nothing.
  assert.ok(checked >= 8, `the sweep found only ${checked} entry guards — it is not reaching the modules`);
  assert.deepEqual(offenders, [],
    "a guard that is not resolve()'d on both sides exits 0 having run nothing — the quietest failure a CLI has");
});
