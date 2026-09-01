#!/usr/bin/env node
// The caller-boundary is STRUCTURAL, not conventional — tooling/grip/rerun.mjs.
//
//   node --test tooling/grip/test/rerun-import-boundary.test.mjs
//
// WHY THIS FILE EXISTS. charter D88 moved the safety gate to the CALLER:
// `screenedRerun` in adjudicate.mjs runs `screenCommand` first and calls
// `runRerun` only on admission, and it is the DEFAULT runner. That closed a
// real hole — a facts.json whose rerun was `cp /etc/hosts /tmp/x` materialised
// the file under no flags.
//
// But it closed it by CONVENTION. `runRerun` still reaches
// `spawnSync("/bin/sh", ["-c", cmd])` — see `shell` in rerun.mjs — gated only
// by `classifySafety`, and `classifySafety` is a denylist that admits anything
// with no write SHAPE. Measured on the frozen specimens in
// fixtures/level-skip-specimens.json it admits 6 of 6, including
// `ssh root@<ip> …` and a bare `node <file>.mjs`, where `screenCommand` admits
// 3 of 6. So the guarantee on main today is "every current caller happens to be
// screened", NOT "no caller can be unscreened". A new module importing
// `runRerun` directly would reopen the hole, and before this file NOTHING in
// the suite would have gone red: census.test.mjs asserts
// `doesNotMatch(CODE, /runRerun/)` for census.mjs ALONE, one file of seventeen.
//
// NO LINE NUMBERS ABOVE, deliberately. The three refs this file was written
// from had ALL drifted — by 20, 41 and 276 lines — while still reading
// perfectly plausibly. Grep the symbol; a symbol survives an insertion.
//
// This test makes the boundary an invariant of the tree rather than a habit.
//
// WHAT IT DOES NOT CLAIM. It does not say `classifySafety` is adequate — it is
// not, and that is the point of screening upstream. It does not say the wire
// itself is correct; adjudicate.test.mjs proves that with a real filesystem
// marker. It says exactly one thing: the set of production modules that can
// reach the executor directly is the set we chose.
//
// HERMETIC. Reads source text off disk. Spawns nothing, imports no subject.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const GRIP = join(dirname(fileURLToPath(import.meta.url)), "..");

// The ONE module permitted to import the executor. Adding a name here is a
// deliberate act: it means that module is now responsible for screening its own
// input BEFORE it calls runRerun, the way adjudicate.mjs does.
const ALLOWED_IMPORTERS = ["adjudicate.mjs"];

// The executor's own file defines runRerun; it does not import it.
const DEFINER = "rerun.mjs";

// A real import binding, static or dynamic — NOT a bare mention. Four of the
// seventeen production modules name `runRerun` only in prose (acceptance.mjs,
// census.mjs, screen.mjs, seal.mjs). A word-match guard would red on all four
// and teach everyone to ignore it.
const STATIC_IMPORT = /import\s*\{[^}]*\brunRerun\b[^}]*\}\s*from\s*["'][^"']+["']/;
const DYNAMIC_IMPORT = /\bawait\s+import\s*\([^)]*\)\s*\)?\s*[;,]?[\s\S]{0,80}?\brunRerun\b/;
const NAMESPACE_IMPORT = /import\s*\*\s*as\s+(\w+)\s*from\s*["']\.\/rerun\.mjs["']/;

function productionModules() {
  return readdirSync(GRIP)
    .filter((f) => f.endsWith(".mjs"))
    .sort();
}

function importsRunRerun(source) {
  return STATIC_IMPORT.test(source) || DYNAMIC_IMPORT.test(source);
}

test("the detector is not blind — it fires on a synthetic importer", () => {
  // Without this, a regex that matched nothing would make every assertion below
  // pass vacuously. Prove the instrument answers PRESENCE before trusting it to
  // report absence.
  assert.equal(
    importsRunRerun('import { runRerun, VERDICT } from "./rerun.mjs";'),
    true,
    "the static-import detector failed to see a plain named import"
  );
  assert.equal(
    importsRunRerun('import {\n  runRerun,\n} from "./rerun.mjs";'),
    true,
    "the static-import detector failed to see a multi-line named import"
  );
  // And it must NOT fire on prose, or it reds on four innocent modules.
  assert.equal(
    importsRunRerun("// runRerun executes only what screenCommand admitted"),
    false,
    "the detector fired on a COMMENT — a word-match guard trains people to ignore it"
  );
});

test("the scan actually reads the tree", () => {
  const files = productionModules();
  // A glob that matched nothing agrees with a tree in which every boundary was
  // deleted. Floor it.
  assert.ok(
    files.length >= 15,
    `expected at least 15 tooling/grip/*.mjs production modules, found ${files.length}: ${files.join(", ")}`
  );
  assert.ok(files.includes(DEFINER), `${DEFINER} is missing — the executor was renamed or moved`);
  for (const name of ALLOWED_IMPORTERS) {
    assert.ok(
      files.includes(name),
      `${name} is in ALLOWED_IMPORTERS but not on disk — the wire was renamed, and this guard is now watching a file that does not exist`
    );
  }
});

test("the allowlisted wire really does import runRerun", () => {
  // The load-bearing half. If adjudicate.mjs stops importing the executor, the
  // exact-set assertion below would still pass with an EMPTY set — green while
  // the wire it exists to protect is gone.
  for (const name of ALLOWED_IMPORTERS) {
    const source = readFileSync(join(GRIP, name), "utf8");
    assert.equal(
      importsRunRerun(source),
      true,
      `${name} no longer imports runRerun. Either the caller-boundary wire moved (update ALLOWED_IMPORTERS in the same commit) or it was deleted, which reopens the default-on execution path.`
    );
  }
});

test("only the allowlisted wire imports runRerun", () => {
  const offenders = productionModules()
    .filter((f) => f !== DEFINER && !ALLOWED_IMPORTERS.includes(f))
    .filter((f) => importsRunRerun(readFileSync(join(GRIP, f), "utf8")));

  assert.deepEqual(
    offenders,
    [],
    `these tooling/grip modules import runRerun directly, bypassing screenCommand: ${offenders.join(", ")}. ` +
      `runRerun gates only on classifySafety, a denylist that admits 6 of 6 frozen specimens including ssh and node. ` +
      `Route the call through screenedRerun (adjudicate.mjs), or — if this module screens its own input first — ` +
      `add it to ALLOWED_IMPORTERS with a comment saying where it screens.`
  );
});

test("no module aliases the executor module to smuggle it past the check", () => {
  // `import * as r from "./rerun.mjs"` then `r.runRerun(...)` would defeat the
  // named-import detector. Nothing does this today; assert it stays that way.
  const offenders = productionModules()
    .filter((f) => f !== DEFINER && !ALLOWED_IMPORTERS.includes(f))
    .filter((f) => NAMESPACE_IMPORT.test(readFileSync(join(GRIP, f), "utf8")));

  assert.deepEqual(
    offenders,
    [],
    `these modules namespace-import ./rerun.mjs: ${offenders.join(", ")}. ` +
      `That reaches runRerun without a named import and defeats the boundary check above.`
  );
});
