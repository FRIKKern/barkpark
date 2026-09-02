// class-coverage.test.mjs — the class-coverage TRIPWIRE, plus controls for the
// classes it found uncontrolled.
//
//   node --test tooling/grip/test/class-coverage.test.mjs
//
// WHY THIS FILE EXISTS, AND WHY IT IS NOT THE COMMAND THAT WAS FILED.
//
// The filed version of this work was a shell one-liner over SEVEN hand-listed
// modules, matching the HYPHEN spelling only. It reproduces three real absences
// (NO-QUANTITY, NOT-A-REF, WRITE-FAILED) — the measurement was right — but the
// method is wrong three times over:
//
//   1. THE FILE SET WAS HAND-LISTED. backfill.mjs was not on it, so TEST-RUNNER
//      escaped both prior scans. A hand-listed set measures the author's memory,
//      not the tree. This scan GLOBS.
//   2. THE SPELLING WAS SINGLE. census.mjs stores `TOOL_ERROR: "TOOL-ERROR"` and
//      census.test.mjs asserts through the UPPER_SNAKE enum KEY. A hyphen-only
//      scan therefore cries wolf on five genuinely-controlled census classes
//      (SCREEN-REFUSED, ANOMALOUS-SILENCE, AMBIGUOUS-SILENCE, UNCLASSIFIED-128,
//      SKIPPED-TEST-RUNNER) — never-cry-wolf failing INSIDE the instrument built
//      to enforce it. This scan matches BOTH spellings.
//   3. THE UNIVERSE WAS SCRAPED, NEVER ASKED FOR. A scan for HYPHENATED string
//      literals cannot see a class whose name is one word, and widening the
//      regex to bare SHOUTY words would swamp it in prose, fixture keys and
//      assertion names. So the universe is now the UNION of two layers: the
//      hyphenated literal scan, and the VALUES of the enum objects the modules
//      EXPORT, obtained by importing them. The enum layer is scoped to enum
//      values and to nothing else, which is what keeps a bare `PASS` written in
//      a comment out of the universe while putting `OUTCOME.PASS` in it.
//
// It is written in Node (fs + RegExp + import), not shell, deliberately: `grep`
// on the authoring host is ugrep 7.5.0, which rejects invocations GNU grep
// accepts, and grip has NO CI — so a shell-shaped tripwire is tested only on one
// box and untested where it would have to hold. A shell scan also cannot ask a
// module what it exports.
//
// WHAT THIS TRIPWIRE DOES NOT MEASURE — declared, not implied:
//   * IT IS STILL A LOWER BOUND, for two NAMED reasons rather than the old
//     hyphen one. (a) A class name assembled at runtime — concatenation or a
//     template literal — is a literal to neither layer and a value to neither
//     enum, so both layers are blind to it. (b) The enum layer reads DEPTH 1 of
//     an exported plain object with UPPER_SNAKE keys, so a class reached only
//     through an array of records, or one kept in a module-private table, is out
//     of its reach. The blind-spot test below pins binding.mjs's two array
//     registries (BINDING_RULES, EXIT_MASK_RULES) inside the union, so that
//     depth costs nothing TODAY — but a bound that costs nothing today is still
//     a bound.
//   * A MODULE THE SWEEP CANNOT IMPORT CONTRIBUTES NO ENUMS. The sweep runs in a
//     CHILD process precisely because a grip module may execute, print, or exit
//     on import — harvest.mjs runs its fixture gate the moment it is imported.
//     A module that kills the sweep is skipped, NAMED in the printed line, and
//     its enums are then outside the universe. The unreadable count is printed
//     next to the universe size so this bound is visible rather than implied.
//   * IT MEASURES MENTION, NOT CONTROL. A class named anywhere under test/ reads
//     as covered here. Mention is not control — proven by mutation in the survey:
//     renaming FORGE-API-READ to another same-class rule left binding.test.mjs at
//     63/62/1 unchanged, and renaming the else branch collapsed DEFAULT-CWD-BOUND
//     29 → 2 while IMPROVING the epic's flagship else-share with nothing going
//     red (binding.test.mjs registers rules through
//     `assert.ok(registered.has(…))`, a subset check that cannot fail for an
//     unexercised rule). So absence here is a PROOF of no control; presence is
//     only an INVITATION to check. The controls in part (B) below are the real
//     thing: each one fires the class on an input that must trigger it and
//     withholds it on a neighbour that must not.
//
//     RE-MEASURED, AND THE FIGURE NOW CARRIES ITS SHA (D102). At binding.mjs
//     blob a87ab60eb78693c6ee7dc30bbd9983e027370c26 over
//     fixtures/evidence-corpus.json blob f0d6b6cbdb50490889e4489ef782eaca7737e86c
//     the else share is 31 of 652 = 4.8% against the naive 3-way rule's 580 of
//     652 = 89.0%; re-running that rename drops it to 2 of 652 = 0.3%. The
//     survey wrote 0.6% for the mutated figure, which is the shape of the finding
//     but not this corpus's number. The aggregate guard that let the mutation
//     through is now two-sided and counted off the ARM rather than the rule name
//     — see binding.test.mjs's ELSE_BRANCH_FLOOR/ELSE_BRANCH_CEILING.
//   * IT DOES NOT COUNT ITS OWN DECLARATIONS. This file names classes in prose —
//     the paragraph above is itself an example — and a tripwire that reads its
//     own commentary as coverage grades its own homework. So THIS file
//     contributes to the corpus from the part (B) banner ONWARD and no earlier:
//     the controls count, the declarations do not. UNMINTABLE is why that
//     matters — under the old file it was "covered" by nothing but a sentence in
//     this header listing it as invisible.

import { test } from "node:test";
import assert from "node:assert/strict";

import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, cpSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { checkCeiling, classifyRef } from "../level.mjs";
import { admitFact } from "../record.mjs";
import { writeLedgerRun } from "../ledger.mjs";
import { classifyOutcome, OUTCOME } from "../census.mjs";
import { backfillOne, DISPOSITION } from "../backfill.mjs";
import { classifyBinding, isDefaultRule, BINDING_RULES, EXIT_MASK_RULES } from "../binding.mjs";
import { mintRecipe } from "../mint.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = resolve(HERE, "..");
const SELF = "class-coverage.test.mjs";

// Everything in THIS file from this banner onward is a CONTROL and counts as
// corpus; everything before it is commentary and does not. `lastIndexOf` picks
// the banner, never this line.
const CONTROLS_BANNER = "(B) THE CONTROLS";

// ─────────────────────────────────────────────────────────────────────────────
// (A) THE TRIPWIRE
// ─────────────────────────────────────────────────────────────────────────────

// LAYER ONE — a SHOUTY class identifier is a fully-uppercase, hyphen-joined
// STRING LITERAL. Restricting to literals (rather than any word in the file)
// keeps prose in comments — "DEFAULT-*", "the D73 rule" — out of the universe,
// so the tripwire counts things the code can actually return.
const SHOUTY_LITERAL = /(["'`])((?:[A-Z0-9]+-)+[A-Z0-9]+)\1/g;

// LAYER TWO — an enum VALUE. The shape is deliberately narrow at BOTH ends: the
// KEY must be UPPER_SNAKE (so binding.mjs's PORTABLE_SCOPES, keyed by prose
// class names, contributes nothing) and the VALUE must be a fully-uppercase
// word or hyphen/underscore-joined phrase (so ANCESTRY's lowercase rungs and
// LEVELS' integers contribute nothing). One word is now enough: this is the
// half that sees ADMITTED, DEMOTED, REJECTED, FAILED, UNAVAILABLE, CONFLICT and
// UNMINTABLE, and it never looks at a free literal.
const ENUM_KEY = /^[A-Z][A-Z0-9_]*$/;
const ENUM_VALUE = /^[A-Z][A-Z0-9]*(?:[-_][A-Z0-9]+)*$/;

// The sweep runs OUT OF PROCESS. harvest.mjs runs its fixture gate at import and
// can `process.exit` on a bad argv — importing the tree in-process would let one
// module kill the whole test file. The child writes its state after EVERY module
// so a death is attributable: whatever is `pending` in the file is what killed
// it, and the parent re-runs with that module skipped.
const ENUM_SWEEP = `
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const src = process.env.GRIP_ENUM_SRC;
const out = process.env.GRIP_ENUM_OUT;
const skip = new Set(JSON.parse(process.env.GRIP_ENUM_SKIP || "[]"));
const KEY = ${ENUM_KEY.toString()};
const VALUE = ${ENUM_VALUE.toString()};
const state = { pending: null, unreadable: [...skip], values: {} };
const flush = () => writeFileSync(out, JSON.stringify(state), "utf8");
const isEnumObject = (v) =>
  v !== null && typeof v === "object" && !Array.isArray(v) &&
  (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);
flush();
for (const name of readdirSync(src).filter((n) => n.endsWith(".mjs")).sort()) {
  if (skip.has(name)) continue;
  state.pending = name;
  flush();
  let mod = null;
  try { mod = await import(pathToFileURL(join(src, name)).href); }
  catch { state.unreadable.push(name); }
  for (const [enumName, value] of Object.entries(mod || {})) {
    if (!isEnumObject(value)) continue;
    for (const [key, member] of Object.entries(value)) {
      if (!KEY.test(key)) continue;
      if (typeof member !== "string" || !VALUE.test(member)) continue;
      (state.values[member] ||= []).push({ module: name, enumName, key });
    }
  }
  state.pending = null;
  flush();
}
flush();
`;

const ENUM_CACHE = new Map();

/**
 * sweepEnumUniverse(srcDir) → { values: Map<class, origin[]>, unreadable: [] }
 *
 * `origin` is { module, enumName, key } — the enum member that HOLDS the class,
 * which is what lets the coverage check accept `OUTCOME.TOOL_ERROR` as a mention
 * of TOOL-ERROR without accepting the bare word TOOL_ERROR anywhere else.
 * Cached per directory: the sweep costs one child process, not one per test.
 */
export function sweepEnumUniverse(srcDir = GRIP) {
  const cached = ENUM_CACHE.get(srcDir);
  if (cached) return cached;

  const workdir = mkdtempSync(join(tmpdir(), "grip-enumsweep-"));
  const out = join(workdir, "sweep.json");
  const unreadable = [];
  let state = { pending: null, unreadable: [], values: {} };
  try {
    writeFileSync(out, JSON.stringify(state), "utf8");
    // Bounded by the module count: each retry retires exactly one killer.
    const budget = readdirSync(srcDir).filter((n) => n.endsWith(".mjs")).length + 1;
    for (let attempt = 0; attempt < budget; attempt++) {
      spawnSync(process.execPath, ["--input-type=module", "-e", ENUM_SWEEP], {
        stdio: "ignore",
        timeout: 60_000, // a hung module must not hang the suite; it becomes an unreadable module instead
        env: { ...process.env, GRIP_ENUM_SRC: srcDir, GRIP_ENUM_OUT: out, GRIP_ENUM_SKIP: JSON.stringify(unreadable) },
      });
      state = JSON.parse(readFileSync(out, "utf8"));
      if (!state.pending) break;
      unreadable.push(state.pending); // it died on this one — retire it and retry
    }
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }

  const result = {
    values: new Map(Object.entries(state.values)),
    unreadable: [...new Set([...(state.unreadable || []), ...unreadable])].sort(),
  };
  ENUM_CACHE.set(srcDir, result);
  return result;
}

/**
 * The corpus contribution of one test file. THIS file contributes only its
 * controls — see the "does not count its own declarations" bullet in the header.
 */
function corpusTextOf(name, raw) {
  if (name !== SELF) return raw;
  const at = raw.lastIndexOf(CONTROLS_BANNER);
  return at === -1 ? "" : raw.slice(at);
}

/**
 * Is `id` named by the corpus? Three spellings, and for a one-word class only
 * the last two — `corpus.includes("FAILED")` would be satisfied by the substring
 * inside WRITE-FAILED, which is how a loose scan grades an absent class covered.
 */
function isMentioned(corpus, id, origins) {
  if (id.includes("-")) {
    if (corpus.includes(id)) return true; // the hyphen spelling, as written in the module
    if (new RegExp(`\\b${id.replace(/-/g, "_")}\\b`).test(corpus)) return true; // the UPPER_SNAKE enum key
  }
  if (new RegExp(`(["'\`])${id}\\1`).test(corpus)) return true; // the value as a quoted literal
  return origins.some(({ enumName, key }) => new RegExp(`\\b${enumName}\\.${key}\\b`).test(corpus)); // ENUM.KEY
}

/**
 * scanClassCoverage({ srcDir, testDir, excludeTests }) → {
 *   modules, testFiles, literalUniverse, enumUniverse, unreadable,
 *   universe, hyphenOnly, dual, uncontrolled
 * }
 *
 * GLOBS `srcDir` — never a hand-listed set. `universe` is the UNION of the two
 * layers. `dual` is the uncontrolled set of the LITERAL layer under both
 * spellings, and `hyphenOnly` what the filed method would have said; both are
 * kept so the three methods can be printed side by side. `uncontrolled` is the
 * committed expectation — the union layer's flagged set. Exported so a scratch
 * copy of the tree can be scanned without editing this one.
 */
export function scanClassCoverage({ srcDir = GRIP, testDir = join(GRIP, "test"), excludeTests = [] } = {}) {
  const modules = readdirSync(srcDir).filter((name) => name.endsWith(".mjs")).sort();
  const literalUniverse = new Map();
  for (const name of modules) {
    const lines = readFileSync(join(srcDir, name), "utf8").split("\n");
    lines.forEach((line, i) => {
      SHOUTY_LITERAL.lastIndex = 0;
      let m;
      while ((m = SHOUTY_LITERAL.exec(line)) !== null) {
        if (!literalUniverse.has(m[2])) literalUniverse.set(m[2], `${name}:${i + 1}`);
      }
    });
  }

  const { values: enumUniverse, unreadable } = sweepEnumUniverse(srcDir);
  const universe = new Map(literalUniverse);
  for (const [id, origins] of enumUniverse) {
    if (!universe.has(id)) universe.set(id, `${origins[0].module} ${origins[0].enumName}.${origins[0].key}`);
  }

  const testFiles = readdirSync(testDir)
    .filter((name) => name.endsWith(".mjs") && !excludeTests.includes(name))
    .sort();
  const corpus = testFiles.map((name) => corpusTextOf(name, readFileSync(join(testDir, name), "utf8"))).join("\n");

  const hyphenOnly = [];
  const dual = [];
  const uncontrolled = [];
  for (const [id, where] of universe) {
    const origins = enumUniverse.get(id) ?? [];
    if (literalUniverse.has(id)) {
      const mentionedHyphen = corpus.includes(id);
      const mentionedSnake = new RegExp(`\\b${id.replace(/-/g, "_")}\\b`).test(corpus);
      if (!mentionedHyphen) hyphenOnly.push({ id, where });
      if (!mentionedHyphen && !mentionedSnake) dual.push({ id, where });
    }
    if (!isMentioned(corpus, id, origins)) uncontrolled.push({ id, where });
  }
  return { modules, testFiles, literalUniverse, enumUniverse, unreadable, universe, hyphenOnly, dual, uncontrolled };
}

// The committed expectation. EMPTY is the whole point: every class in the union
// universe — hyphenated literal OR exported enum value — is named by some test
// under tooling/grip/test/. A new class landing with no test anywhere turns this
// red and names it, one word or seven.
const EXPECTED_UNCONTROLLED = [];

// What this file itself brought under control, measured by scanning with THIS
// file excluded from the test corpus — so the row below is the honest "before".
// Split by which LAYER sees them, because that split is the whole point of the
// change: the hyphenated seven were always visible to the scan, and UNMINTABLE
// was not visible to anything until the enum layer arrived.
const CONTROLLED_HERE = [
  "TEST-RUNNER",
  "FORGE-API-READ",
  "DEFAULT-CWD-BOUND",
  "TOOL-ERROR",
  "WRITE-FAILED",
  "NOT-A-REF",
  "NO-QUANTITY",
];
const CONTROLLED_HERE_UNHYPHENATED = ["UNMINTABLE"];

test("TRIPWIRE: every class in tooling/grip/*.mjs — hyphenated literal OR exported enum value — is named by some test", () => {
  const scan = scanClassCoverage();
  const names = scan.uncontrolled.map((row) => `${row.id} (${row.where})`);

  // NON-VACUITY OF THE SELF-SLICE. If the slice ever swallowed part (A), this
  // file's own declarations would start counting as coverage and the tripwire
  // would go quietly green on classes nothing exercises; if it swallowed part
  // (B) instead, seven controlled classes would flag. Both directions are pinned.
  const selfControls = corpusTextOf(SELF, readFileSync(join(GRIP, "test", SELF), "utf8"));
  assert.ok(selfControls.includes("never cries wolf: a pathless ref"), "the self-slice lost this file's controls");
  assert.ok(!selfControls.includes("EXPECTED_UNCONTROLLED"), "the self-slice swallowed part (A) — declarations would credit themselves");

  console.log(
    `\n  [class-coverage] ${scan.modules.length} modules globbed, ${scan.testFiles.length} test files read` +
      `, ${scan.unreadable.length} modules unreadable by the enum sweep${scan.unreadable.length ? ` (${scan.unreadable.join(", ")})` : ""}` +
      `\n  [class-coverage] universe ${scan.universe.size} = ${scan.literalUniverse.size} hyphenated literals ∪ ${scan.enumUniverse.size} exported enum values (LOWER BOUND — see the blind-spot test)` +
      `\n  [class-coverage] uncontrolled: ${names.length === 0 ? "none" : names.join(", ")}\n`,
  );

  assert.deepEqual(
    names,
    EXPECTED_UNCONTROLLED,
    "a class exists in tooling/grip/*.mjs that no test names under any spelling — write a fail-before control for it, or add it to EXPECTED_UNCONTROLLED with a written reason",
  );
});

test("TRIPWIRE never cries wolf: the hyphen-only method flags five census classes this scan clears", () => {
  // These five ARE controlled — census.test.mjs asserts them as fired outcomes
  // through the UPPER_SNAKE enum key (OUTCOME.TOOL_ERROR …), which is how the
  // module spells them at the call site. The filed hyphen-only scan cannot see
  // that spelling and reports them absent.
  const CRIED_WOLF_ON = ["SCREEN-REFUSED", "ANOMALOUS-SILENCE", "AMBIGUOUS-SILENCE", "UNCLASSIFIED-128", "SKIPPED-TEST-RUNNER"];

  // Scanned with THIS file excluded, so the comparison is the historical one:
  // what the methods said about the tree BEFORE this file existed.
  const before = scanClassCoverage({ excludeTests: [SELF] });
  const hyphen = before.hyphenOnly.map((r) => r.id);
  const dual = before.dual.map((r) => r.id);
  const union = before.uncontrolled.map((r) => r.id);

  for (const id of CRIED_WOLF_ON) {
    assert.ok(hyphen.includes(id), `${id} should be flagged by the hyphen-only method (that is the defect being demonstrated)`);
    assert.ok(!dual.includes(id), `${id} is controlled via its UPPER_SNAKE spelling and must NOT be flagged`);
    assert.ok(!union.includes(id), `${id} is controlled — the union layer must not re-introduce the false alarm`);
  }
  for (const id of CONTROLLED_HERE) {
    assert.ok(dual.includes(id), `${id} was uncontrolled before this file — if another test now controls it, drop it from CONTROLLED_HERE`);
  }
  for (const id of CONTROLLED_HERE_UNHYPHENATED) {
    assert.ok(!dual.includes(id), `${id} carries no hyphen — the literal layer cannot see it and must not report it`);
    assert.ok(union.includes(id), `${id} was uncontrolled before this file — if another test now controls it, drop it from CONTROLLED_HERE_UNHYPHENATED`);
  }

  console.log(
    `\n  [side by side] hyphen-only (the filed method): ${hyphen.length} flagged — ${hyphen.join(", ")}` +
      `\n  [side by side] dual-spelling, literals only:  ${dual.length} flagged — ${dual.join(", ")}` +
      `\n  [side by side] union with the enum layer:     ${union.length} flagged — ${union.join(", ")}` +
      `\n  [side by side] the ${CRIED_WOLF_ON.length} cleared are controlled through the UPPER_SNAKE enum key, not the hyphen string` +
      `\n  [side by side] the enum layer adds ${union.length - dual.length}: ${CONTROLLED_HERE_UNHYPHENATED.join(", ")} — invisible to every literal scan\n`,
  );
});

test("TRIPWIRE declares its residual blind spot: the hyphen hole is CLOSED, what is left is depth and construction", () => {
  // The seven the previous draft of this file declared invisible by construction.
  // Both halves are load-bearing: they are still absent from the LITERAL layer
  // (nothing was renamed to sneak them in), and they are now IN the universe via
  // the enum layer. If a rename gives one a hyphen the first goes red; if one
  // leaves its enum the second goes red, and either way the declaration below is
  // stale and must be rewritten.
  const CLOSED_BY_THE_ENUM_LAYER = ["ADMITTED", "DEMOTED", "REJECTED", "FAILED", "UNAVAILABLE", "CONFLICT", "UNMINTABLE"];
  const scan = scanClassCoverage();
  for (const id of CLOSED_BY_THE_ENUM_LAYER) {
    assert.ok(!scan.literalUniverse.has(id), `${id} carries a hyphen now — it is no longer an example of the closed hole`);
    assert.ok(scan.universe.has(id), `${id} is no longer an exported enum value — the blind-spot declaration below must be rewritten`);
  }

  // THE RESIDUAL DEPTH BOUND, priced rather than asserted away. The enum layer
  // reads depth 1 of an exported object, so binding.mjs's two ARRAY registries
  // are outside it. They cost nothing today only because every rule name they
  // carry is also a hyphenated literal the other layer sees — which is a fact
  // about today's spelling, not a property of the scan, so it is pinned here.
  for (const entry of [...BINDING_RULES, ...EXIT_MASK_RULES]) {
    assert.ok(
      scan.universe.has(entry.rule),
      `${entry.rule} lives in an array registry the enum layer does not walk, and it is no longer a hyphenated literal either — it has fallen out of the universe entirely`,
    );
  }

  console.log(
    `\n  [BLIND SPOT] The hyphen hole is CLOSED: the universe is now hyphenated literals ∪ exported enum values,` +
      ` so ${CLOSED_BY_THE_ENUM_LAYER.length} one-word classes the previous draft declared invisible are inside it.` +
      ` WHAT REMAINS, and why the number is still a LOWER BOUND: (a) a class name built at RUNTIME by concatenation` +
      ` is a literal to neither layer; (b) the enum layer reads DEPTH 1 of an exported object, so a class held only in` +
      ` an array of records or in a module-private table is out of reach — the ${BINDING_RULES.length + EXIT_MASK_RULES.length}` +
      ` array-registry rules pinned above are covered by the literal layer, not by the enum one;` +
      ` (c) ${scan.unreadable.length} module(s) the sweep could not import contribute no enums at all.` +
      ` And mention under test/ is still not control.\n`,
  );
});

test("TRIPWIRE is able to fail: planted classes in a scratch copy of the tree are named — hyphenated AND one word", () => {
  // Both plants' NAMES are assembled at runtime and never appear spelled out in
  // any file under test/ — otherwise this very file would "control" them by
  // mention and the plants would come back clean, which is how a tripwire proves
  // itself green without being able to go red. (The self-slice would drop this
  // block from the corpus anyway; assembling the names too means the plant does
  // not depend on the slice being right.)
  const plantedHyphen = ["PLANTED", "UNCONTROLLED", "CLASS"].join("-");
  const plantedWord = ["PLANTED", "SINGLEWORD", "CLASS"].join("");
  const scratch = mkdtempSync(join(tmpdir(), "grip-classcov-plant-"));
  try {
    cpSync(GRIP, join(scratch, "grip"), { recursive: true });
    const src = join(scratch, "grip");
    writeFileSync(
      join(src, "planted.mjs"),
      `export const PLANTED = Object.freeze({ NEVER_TESTED: "${plantedHyphen}", ALSO_NEVER_TESTED: "${plantedWord}" });\n`,
      "utf8",
    );
    const scan = scanClassCoverage({ srcDir: src, testDir: join(src, "test") });
    const flagged = scan.uncontrolled.map((r) => r.id);
    assert.ok(flagged.includes(plantedHyphen), `the hyphenated plant was not flagged; scan said ${JSON.stringify(flagged)}`);
    assert.ok(flagged.includes(plantedWord), `the ONE-WORD plant was not flagged — this is the hole the enum layer exists to close; scan said ${JSON.stringify(flagged)}`);
    assert.ok(!scan.literalUniverse.has(plantedWord), "the one-word plant must be invisible to the literal layer — otherwise this proves nothing about the enum layer");
    assert.ok(scan.enumUniverse.has(plantedWord), "the enum layer did not see the planted enum value");
    assert.ok(scan.modules.includes("planted.mjs"), "the glob missed a new module — a hand-listed set is exactly how backfill.mjs escaped");
    assert.deepEqual(scan.unreadable, [], "the enum sweep could not import part of the scratch tree — the plant result is not trustworthy");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// (B) THE CONTROLS — each class FIRES on an input that must trigger it, and
// stays SILENT on a neighbour that must not. Fail-before plant + never-cry-wolf,
// one pair per class.
// ─────────────────────────────────────────────────────────────────────────────

test("NOT-A-REF fires on a non-reference, and never on a real one", () => {
  for (const bad of ["", "   ", "see the notifications module", "api/lib/x.ex:", "api/lib/x.ex:12:14"]) {
    const v = classifyRef(bad);
    assert.equal(v.ok, false);
    assert.equal(v.reason, "NOT-A-REF", `${JSON.stringify(bad)} should be NOT-A-REF`);
    assert.match(v.message, /^NOT-A-REF: /);
  }
  assert.equal(classifyRef(null).reason, "NOT-A-REF");
});

test("NOT-A-REF never cries wolf: a pathless ref is PATHLESS-REF and a good ref is ok", () => {
  // The near-miss that matters: `notifications.ex:389-397` IS ref-shaped. Calling
  // it NOT-A-REF would erase the distinction the class exists to draw.
  const pathless = classifyRef("notifications.ex:389-397");
  assert.equal(pathless.ok, false);
  assert.equal(pathless.reason, "PATHLESS-REF");
  const good = classifyRef("cloud/lib/barkpark_cloud/notifications.ex:389-397");
  assert.equal(good.ok, true);
  assert.deepEqual(good.lines, { start: 389, end: 397 });
});

test("WRITE-FAILED fires when the ledger directory refuses the write", (t) => {
  if (typeof process.getuid === "function" && process.getuid() === 0) {
    t.skip("running as root — a read-only directory cannot produce EACCES, so this control cannot be exercised here");
    return;
  }
  const now = "2026-07-27T00:00:00Z";
  const recipe = mintRecipe({ rerun: "wc -l tooling/grip/mint.mjs" }, { observed_at: now }).recipe;
  const base = mkdtempSync(join(tmpdir(), "grip-classcov-write-"));
  const readOnly = join(base, "ro");
  try {
    mkdirSync(readOnly);
    chmodSync(readOnly, 0o555);
    const verdict = writeLedgerRun({ run_id: "grip-classcoverage-plant", recipes: [recipe], dir: readOnly, now });
    assert.equal(verdict.ok, false);
    assert.deepEqual(verdict.rejections.map((r) => r.reason), ["WRITE-FAILED"]);
    assert.match(verdict.rejections[0].message, /^WRITE-FAILED: /);
    assert.match(verdict.rejections[0].message, /EACCES/);
    assert.equal(readdirSync(readOnly).length, 0, "nothing may be written when the write failed");
  } finally {
    chmodSync(readOnly, 0o755);
    rmSync(base, { recursive: true, force: true });
  }
});

test("WRITE-FAILED never cries wolf: a writable directory writes, and a re-write is ALREADY-RECORDED", () => {
  const now = "2026-07-27T00:00:00Z";
  const recipe = mintRecipe({ rerun: "wc -l tooling/grip/mint.mjs" }, { observed_at: now }).recipe;
  const dir = mkdtempSync(join(tmpdir(), "grip-classcov-ok-"));
  try {
    const first = writeLedgerRun({ run_id: "grip-classcoverage-plant", recipes: [recipe], dir, now });
    assert.equal(first.ok, true);
    assert.equal(first.written, true);
    // Same bytes again: idempotent, and emphatically NOT a write failure.
    const second = writeLedgerRun({ run_id: "grip-classcoverage-plant", recipes: [recipe], dir, now });
    assert.equal(second.ok, true);
    assert.equal(second.written, false);
    assert.equal(second.reason, "ALREADY-RECORDED");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("TOOL-ERROR fires when a matcher or a differ ERRORS, and is counted as decay", () => {
  const matcher = classifyOutcome("grep -n isolation tooling/grip/mint.mjs", { exit: 2, stdout: "", stderr: "grep: unrecognized option" });
  assert.equal(matcher.outcome, OUTCOME.TOOL_ERROR);
  assert.equal(matcher.outcome, "TOOL-ERROR");
  assert.equal(matcher.answering, false);
  assert.equal(matcher.decayed, true);
  assert.equal(matcher.admissible, true, "decay is admissible — it is an answer about the world having moved");

  const differ = classifyOutcome("diff a.txt b.txt", { exit: 3, stdout: "", stderr: "diff: something broke" });
  assert.equal(differ.outcome, OUTCOME.TOOL_ERROR);
});

test("TOOL-ERROR never cries wolf: grep rc 1 is an ABSENCE and a gone path is PATH-GONE", () => {
  // THE SPECIMEN. rc 1 with no bytes is grep answering "nothing here". Reading it
  // as a tool error is the exact fabricated-decay defect this census exists to end.
  const absent = classifyOutcome("grep -n isolation tooling/grip/mint.mjs", { exit: 1, stdout: "", stderr: "" });
  assert.equal(absent.outcome, OUTCOME.ABSENT);
  assert.equal(absent.answering, true);

  const gone = classifyOutcome("grep -n isolation gone.mjs", { exit: 2, stdout: "", stderr: "grep: gone.mjs: No such file or directory" });
  assert.equal(gone.outcome, OUTCOME.PATH_GONE);
  assert.notEqual(gone.outcome, OUTCOME.TOOL_ERROR);
});

const NEVER_SPAWNS = () => {
  throw new Error("a test runner must never be executed by the backfill");
};
const ANSWERED_RUN = () => ({ exit: 0, stdout: "42\n", stderr: "", ms: 1, timedOut: false, spawnError: null });

test("TEST-RUNNER fires on the runners the screen admits — and the command is never spawned", () => {
  // `exec` throws: reaching the executor at all fails this test, which is the
  // property that matters — a test runner executes repo code the screen never read.
  for (const cmd of ["go test ./...", "mix test test/foo_test.exs"]) {
    const row = backfillOne(cmd, { now: "2026-07-27T00:00:00Z", exec: NEVER_SPAWNS });
    assert.equal(row.disposition, DISPOSITION.TEST_RUNNER, `${cmd} should be dispositioned TEST-RUNNER`);
    assert.equal(row.disposition, "TEST-RUNNER");
    assert.equal(row.outcome, "SKIPPED-TEST-RUNNER");
  }
});

test("TEST-RUNNER never cries wolf: the screen decides first, and a real read is MINTED", () => {
  const now = "2026-07-27T00:00:00Z";
  // PRECEDENCE, recorded rather than assumed: `npm test` and `pytest` never reach
  // the test-runner check at all — the screen refuses them first (npm's `test`
  // sub-verb is off the read-only allowlist; `pytest` is an unknown head and the
  // screen fails closed). Their disposition is SCREEN-REFUSED, and calling that a
  // TEST-RUNNER row would misreport WHY the command did not run.
  for (const cmd of ["npm test --workspace js/sdk", "pytest -q"]) {
    const row = backfillOne(cmd, { now, exec: NEVER_SPAWNS });
    assert.equal(row.disposition, DISPOSITION.SCREEN_REFUSED, `${cmd} is refused by the screen before the runner check`);
  }
  for (const cmd of ["go vet ./internal/cli", "wc -l tooling/grip/mint.mjs"]) {
    const row = backfillOne(cmd, { now, exec: ANSWERED_RUN });
    assert.notEqual(row.disposition, DISPOSITION.TEST_RUNNER, `${cmd} is not a test runner`);
    assert.equal(row.disposition, DISPOSITION.MINTED);
  }
});

test("UNMINTABLE fires when a command ANSWERS but no recipe can be minted, and names WHY", () => {
  // The four shapes part (C) proves reach NO-QUANTITY: `cd` swallows the head
  // AND its argument, so the path still mints a subject while the quantity has
  // no head left to come from. The command ANSWERED — this is neither a decay
  // nor a refusal, and that is the distinction UNMINTABLE exists to record.
  //
  // THIS CONTROL IS WHY THE ENUM LAYER WAS BUILT. UNMINTABLE carries no hyphen,
  // so no literal scan could ever see it; before this pair it was named by
  // nothing under test/ except a sentence in this file's own header declaring it
  // invisible — a class "covered" by the confession that it was not.
  const now = "2026-07-27T00:00:00Z";
  for (const cmd of ["cd tooling/grip/mint.mjs", "cd api/lib/foo.ex", "cd tooling/grip", "cd x.txt"]) {
    const row = backfillOne(cmd, { now, exec: ANSWERED_RUN });
    assert.equal(row.disposition, DISPOSITION.UNMINTABLE, `${cmd} should be dispositioned UNMINTABLE`);
    assert.equal(row.disposition, "UNMINTABLE");
    assert.equal(row.outcome, "ANSWERED", "an UNMINTABLE row RAN and answered — what was lost is the recipe, never the read");
    assert.equal(row.why, "NO-QUANTITY", "the row must carry the mint reason, or UNMINTABLE degenerates into a shrug");
  }
});

test("UNMINTABLE never cries wolf: a real read MINTS, a refusal is SCREEN-REFUSED, a failed run is DECAYED", () => {
  const now = "2026-07-27T00:00:00Z";
  const FAILED_RUN = () => ({ exit: 1, stdout: "", stderr: "boom", ms: 1, timedOut: false, spawnError: null });
  for (const cmd of ["wc -l tooling/grip/mint.mjs", "go vet ./internal/cli"]) {
    assert.equal(backfillOne(cmd, { now, exec: ANSWERED_RUN }).disposition, DISPOSITION.MINTED, `${cmd} mints — it is not unmintable`);
  }
  // The two neighbours that also end with NO durable row. Calling either of them
  // UNMINTABLE would misreport WHY the row is missing: the first never ran at
  // all, the second ran and lost its answer, and only a minted-stage failure is
  // UNMINTABLE.
  assert.equal(backfillOne("FOO=1", { now, exec: NEVER_SPAWNS }).disposition, DISPOSITION.SCREEN_REFUSED);
  const decayed = backfillOne("wc -l gone.txt", { now, exec: FAILED_RUN });
  assert.equal(decayed.disposition, DISPOSITION.DECAYED);
  assert.equal(decayed.outcome, "RAN-AND-FAILED");
});

test("FORGE-API-READ fires on gh reads, and names the forge as the anchor", () => {
  for (const cmd of ["gh api repos/FRIKKern/barkpark/pulls/6284", "gh pr view 6284 --json state", "gh run list --limit 5"]) {
    const v = classifyBinding(cmd);
    assert.equal(v.rule, "FORGE-API-READ", `${cmd} should fire FORGE-API-READ`);
    assert.equal(v.binding_class, "shared-ref");
    assert.equal(v.portable_scope, "any worktree of this clone");
    assert.equal(isDefaultRule(v.rule), false, "FORGE-API-READ is a fired rule, never an else branch");
  }
});

test("FORGE-API-READ never cries wolf: other shared-ref reads keep their OWN rule names", () => {
  // The mutation that this pair exists to catch: routing `gh` to a neighbouring
  // rule of the SAME class leaves every class-level assertion green. Asserting
  // the RULE, per command, is what makes the rename visible.
  assert.equal(classifyBinding("git ls-remote origin main").rule, "GIT-REMOTE-SERVER-OP");
  assert.equal(classifyBinding("git show origin/main:tooling/grip/mint.mjs").rule, "REMOTE-TRACKING-REF");
  for (const cmd of ["git ls-remote origin main", "git show origin/main:tooling/grip/mint.mjs"]) {
    assert.notEqual(classifyBinding(cmd).rule, "FORGE-API-READ");
    assert.equal(classifyBinding(cmd).binding_class, "shared-ref", "same class, different rule — the class alone cannot tell them apart");
  }
});

test("DEFAULT-CWD-BOUND fires when no rule matched, and says so as a FLOOR", () => {
  for (const cmd of ["echo hello", "true", "date -u +%s"]) {
    const v = classifyBinding(cmd);
    assert.equal(v.rule, "DEFAULT-CWD-BOUND", `${cmd} should land on the else branch`);
    assert.equal(v.binding_class, "cwd-bound");
    assert.equal(isDefaultRule(v.rule), true, "the else branch MUST be registered as a default — the else-share number is derived from this");
    assert.match(v.reason, /ELSE branch/);
    assert.equal(v.anchor ?? null, null, "an else branch names no anchor — it has not found one");
  }
});

test("DEFAULT-CWD-BOUND never cries wolf: a fired cwd-bound rule is NOT the else branch", () => {
  // The survey's mutation: renaming the else branch collapsed DEFAULT-CWD-BOUND
  // 29 → 2 and IMPROVED the flagship else-share (4.8% → 0.3% at binding.mjs blob
  // a87ab60eb78693c6ee7dc30bbd9983e027370c26) with nothing red.
  // Both halves are pinned here — the name AND its default-ness — and
  // binding.test.mjs now bounds the arrival count from both sides as well, so
  // the aggregate figure the rename moved is no longer undefended.
  for (const [cmd, rule] of [
    ["curl -s http://localhost:4000/api/schemas", "NETWORK-READ-NO-TREE"],
    ["wc -l tooling/grip/mint.mjs", "RELATIVE-PATH-READ"],
    ["node tooling/grip/ledger.mjs --selftest", "TOOLCHAIN-CWD-ROOTED"],
  ]) {
    const v = classifyBinding(cmd);
    assert.equal(v.binding_class, "cwd-bound");
    assert.equal(v.rule, rule, `${cmd} must keep its own rule name, not the else branch's`);
    assert.equal(isDefaultRule(v.rule), false, `${rule} is a finding, not a floor`);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// (C) NO-QUANTITY — the reachability question, answered
// ─────────────────────────────────────────────────────────────────────────────
//
// THE HYPOTHESIS UNDER TEST was that NO-QUANTITY is structurally unreachable:
// `quantityPhrase` returns "" only when the measuring stage has no head, and
// mintRecipe returns NO-SUBJECT first whenever the head is empty — so the branch
// looked dead, and five probe shapes reached NO-SUBJECT instead.
//
// THE HYPOTHESIS IS FALSE, and this is the disposition: NO-QUANTITY IS REACHABLE.
// The subject does NOT depend on the head — `subject = paths[0] ?? cmd:<head>` —
// so a command whose only token is a PATH swallowed by `cd` mints a subject and
// no quantity. `cd tooling/grip/mint.mjs` is such a command: headAt skips `cd`
// AND its argument, leaving head "", while pathToken still sees the argument.
//
// PROBE TABLE (rerun → reason), the shapes tried and what each returned:
//   "cd tooling/grip/mint.mjs"     → NO-QUANTITY   ← REACHES IT (path swallowed by cd)
//   "cd api/lib/foo.ex"            → NO-QUANTITY   ← reaches it
//   "cd tooling/grip"              → NO-QUANTITY   ← reaches it
//   "cd x.txt"                     → NO-QUANTITY   ← reaches it
//   "FOO=1"                        → NO-SUBJECT    (assignment skipped, no path)
//   "cd /tmp && "                  → NO-SUBJECT    (absolute path is not a path token)
//   ""                             → NO-RERUN      (guarded earlier)
//   "wc -l tooling/grip/mint.mjs"  → ok            (control)
//
// The branch is LIVE, it is now controlled below, and nothing was deleted.

test("NO-QUANTITY is REACHABLE: a path swallowed by `cd` mints a subject and no quantity", () => {
  const now = "2026-07-27T00:00:00Z";
  for (const rerun of ["cd tooling/grip/mint.mjs", "cd api/lib/foo.ex", "cd tooling/grip", "cd x.txt"]) {
    const v = mintRecipe({ rerun }, { observed_at: now });
    assert.equal(v.ok, false);
    assert.equal(v.reason, "NO-QUANTITY", `${JSON.stringify(rerun)} should reach NO-QUANTITY, not ${v.reason}`);
  }
});

test("NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints", () => {
  const now = "2026-07-27T00:00:00Z";
  assert.equal(mintRecipe({ rerun: "" }, { observed_at: now }).reason, "NO-RERUN");
  assert.equal(mintRecipe({}, { observed_at: now }).reason, "NO-RERUN");
  assert.equal(mintRecipe({ rerun: "FOO=1" }, { observed_at: now }).reason, "NO-SUBJECT");
  assert.equal(mintRecipe({ rerun: "cd /tmp && " }, { observed_at: now }).reason, "NO-SUBJECT");

  const minted = mintRecipe({ rerun: "cd tooling/grip && wc -l mint.mjs" }, { observed_at: now });
  assert.equal(minted.ok, true, `a real read must mint, got ${minted.reason}`);
  assert.equal(minted.recipe.quantity, "wc:-l");
});

// ─────────────────────────────────────────────────────────────────────────────
// (D) UNKNOWN-LEVEL — the off-ladder claim, fired
// ─────────────────────────────────────────────────────────────────────────────
//
// UNKNOWN-LEVEL had exactly one hit under tooling/grip/test/ and it was a
// NEGATIVE assertion: adjudicate.mjs must not RESTATE the name (it composes
// record.mjs instead of re-implementing it). That assertion is green whether
// the ceiling check works, is inverted, or was deleted — it never asks the
// grammar anything. Below, it is asked.

test("UNKNOWN-LEVEL fires on a claim that is not on the ladder, and names the ladder it is off", () => {
  // The whole ceiling rests on LEVELS being a total order over known rungs. A
  // claim outside it cannot be COMPARED, so admitting it would silently let an
  // arbitrary string past the level gate — the failure mode is not "wrong
  // level", it is "no level at all, waved through".
  for (const claimed of ["L9", "L0", "l3", "L3 ", "high", ""]) {
    const v = checkCeiling(claimed, "L3");
    assert.equal(v.ok, false, `${JSON.stringify(claimed)} is off the ladder and must not be comparable`);
    assert.equal(v.reason, "UNKNOWN-LEVEL", `${JSON.stringify(claimed)} should be UNKNOWN-LEVEL, got ${v.reason}`);
    assert.match(v.message, /^UNKNOWN-LEVEL: claimed level /);
    assert.match(v.message, /is not on the ladder L1 L2 L3 L4 L5 L6/);
  }

  // The DERIVED side of the same guard — the half a caller cannot reach by
  // typing a bad claim, and the half that would go unnoticed if deriveLevel
  // ever started answering something the ladder does not carry.
  const derived = checkCeiling("L3", "L7");
  assert.equal(derived.reason, "UNKNOWN-LEVEL");
  assert.match(derived.message, /^UNKNOWN-LEVEL: derived level /);

  // And it reaches the real admission path, not just the helper: this is the
  // reproduction the filing named.
  const rejected = admitFact({ subject: "s", claim: "c", rerun: "git rev-parse HEAD", level: "L9" });
  assert.equal(rejected.ok, false);
  assert.deepEqual(rejected.rejections.map((r) => r.reason), ["UNKNOWN-LEVEL"]);
  assert.equal(rejected.rejections[0].claimed, "L9");
  assert.equal(rejected.rejections[0].derived, "L3");
});

test("UNKNOWN-LEVEL never cries wolf: an on-ladder over-claim is LEVEL-SKIP, and an under-claim is admitted", () => {
  // The distinction the class exists to draw. "Off the ladder" and "too high on
  // the ladder" are different findings with different fixes — collapsing them
  // would tell an author to re-derive when the real defect is a typo, and vice
  // versa. Both neighbours are pinned here.
  const skip = checkCeiling("L1", "L3");
  assert.equal(skip.ok, false);
  assert.equal(skip.reason, "LEVEL-SKIP");
  assert.notEqual(skip.reason, "UNKNOWN-LEVEL");

  for (const [claimed, derived] of [["L3", "L3"], ["L4", "L3"], ["L6", "L1"]]) {
    assert.equal(checkCeiling(claimed, derived).ok, true, `${claimed} on ${derived} is an honest claim`);
  }

  // An omitted level is not an unknown one — a fact with no claim is levelled
  // by its command (D3), never rejected.
  const admitted = admitFact({ subject: "s", claim: "c", rerun: "git rev-parse HEAD" });
  assert.equal(admitted.ok, true, `an unclaimed level must be derived, not rejected: ${JSON.stringify(admitted.rejections)}`);
  assert.equal(admitted.fact.level, "L3");
});

// ─────────────────────────────────────────────────────────────────────────────
// (E) THE FIRING REGISTRY — MENTIONED is not FIRED, and the gap is now named
// ─────────────────────────────────────────────────────────────────────────────
//
// Part (A) says it in its own header: "IT MEASURES MENTION, NOT CONTROL. A class
// named anywhere under test/ reads as covered here." That declaration was
// honest and it was also the whole hole. Three classes sat inside it for the
// life of this suite — UNKNOWN-LEVEL (named only by an assertion that it must
// NOT appear in adjudicate.mjs), PROBE-DRIFT (asserted only as an empty array)
// and REASONS (named nowhere at all, and invisible to part (A) anyway because
// it carries no hyphen). Each was a rule that could not go red.
//
// WHAT THIS PART ADDS, AND WHAT IT DELIBERATELY DOES NOT.
//
// It is NOT a framework that infers firing from the shape of an assertion. Every
// textual proxy tried was wrong in one direction or the other: `assert` appears
// in absence assertions too, and a rule id in a test TITLE matched
// "VERDICTS is frozen" for VERDICT. So the claim "test T fires rule R" stays a
// HUMAN claim, written down once per rule, and what is mechanical is the part a
// human gets wrong: that the claim is COMPLETE (every rule the modules can
// return has one) and that it still POINTS AT SOMETHING (the named test exists,
// under that exact title, naming that rule in its body).
//
// The universe is the rules a module can actually RETURN — string literals in
// `reason:` / `kind:` position — which is a smaller and more meaningful set than
// part (A)'s "every SHOUTY literal", and unlike part (A) it does not require a
// hyphen, so REASONS and VERDICT are inside it.
//
// THE LIST THAT MUST STAY EMPTY is `unregistered`. A new rule lands with no
// firing entry and this goes red naming it. There is no exemption list to add
// it to on the way past — the only way through is to write the control, which
// is the point.

/** Rules a grip module can RETURN — a `reason:` or `kind:` string literal. */
const RETURNED_RULE = /\b(?:reason|kind):\s*"([A-Z][A-Z0-9-]{3,})"/g;

/** A top-level `test("…")` declaration, with its title. */
const TEST_TITLE = /^[ \t]*(?:await\s+)?test\s*\(\s*"((?:[^"\\]|\\.)*)"/;

/**
 * scanFiringCoverage({ srcDir, testDir, registry }) →
 *   { universe: Map<rule, "file:line">, unregistered: [], phantoms: [] }
 *
 * `unregistered` — a returnable rule with no firing entry. THE LIST THAT MUST
 * STAY EMPTY.
 * `phantoms` — an entry pointing at a test that does not exist under that title,
 * or one whose body never names the rule. Rot in the other direction.
 *
 * Parameterised over the tree exactly like scanClassCoverage, so a scratch copy
 * can be scanned without editing this file — which is how the plant below proves
 * the tripwire can go red.
 */
export function scanFiringCoverage({ srcDir = GRIP, testDir = join(GRIP, "test"), registry = {} } = {}) {
  const universe = new Map();
  for (const name of readdirSync(srcDir).filter((n) => n.endsWith(".mjs")).sort()) {
    const lines = readFileSync(join(srcDir, name), "utf8").split("\n");
    lines.forEach((line, i) => {
      RETURNED_RULE.lastIndex = 0;
      let m;
      while ((m = RETURNED_RULE.exec(line)) !== null) {
        if (!universe.has(m[1])) universe.set(m[1], `${name}:${i + 1}`);
      }
    });
  }

  // Every test in the suite, sliced from its own declaration to the next one, so
  // "the rule is named in THAT test" is a question about a body and not about
  // the file it happens to share with twenty others.
  const bodies = new Map();
  const duplicates = [];
  for (const name of readdirSync(testDir).filter((n) => n.endsWith(".mjs")).sort()) {
    const lines = readFileSync(join(testDir, name), "utf8").split("\n");
    let title = null;
    let buffer = [];
    const flush = () => {
      if (title === null) return;
      const key = `${name} :: ${title}`;
      if (bodies.has(key)) duplicates.push(key);
      else bodies.set(key, buffer.join("\n"));
    };
    for (const line of lines) {
      const m = TEST_TITLE.exec(line);
      if (m) {
        flush();
        title = m[1];
        buffer = [line];
      } else if (title !== null) buffer.push(line);
    }
    flush();
  }

  const unregistered = [];
  for (const [rule, where] of universe) {
    if (!Object.hasOwn(registry, rule)) unregistered.push({ rule, where });
  }

  const phantoms = [];
  for (const [rule, entry] of Object.entries(registry)) {
    const key = `${entry.file} :: ${entry.test}`;
    const body = bodies.get(key);
    if (body === undefined) phantoms.push({ rule, key, why: "no test under that exact title" });
    else if (!body.includes(rule)) phantoms.push({ rule, key, why: "the named test never names the rule" });
  }

  return { universe, bodies, duplicates, unregistered, phantoms };
}

// THE REGISTRY. One row per rule a grip module can return: the test that makes
// it FIRE on a positive input. Mention does not qualify and neither does an
// absence assertion — the three rows added by this slice (UNKNOWN-LEVEL,
// PROBE-DRIFT, REASONS) exist precisely because those were all that stood.
//
// PROBE-DRIFT is registered although it is NOT in the derived universe: it is
// returned as a populated `probe_drift` array rather than a `kind:` literal, so
// no scan of the returnable set can see it. That invisibility is exactly how it
// went uncontrolled, and the row is here so it cannot go back.
const FIRING_CONTROLS = Object.freeze({
  // acceptance.mjs — the specimen judgements
  "SPECIMEN-COUNT": { file: "acceptance.test.mjs", test: "MUTATION: losing a ratified specimen turns it RED" },
  "NO-EXPECTATION": { file: "acceptance.test.mjs", test: "MUTATION: an unexpected new ratified specimen turns it RED" },
  "NO-SCREEN-EXPECTATION": { file: "acceptance.test.mjs", test: "a ratified specimen with no frozen screen row is a NO-SCREEN-EXPECTATION failure" },
  "SCREEN-DRIFT": { file: "acceptance.test.mjs", test: "MUTATION: a specimen whose rerun is rewritten drifts against the frozen screen" },
  "VERDICT": { file: "acceptance.test.mjs", test: "MUTATION: corrupting a specimen's claimed level turns that specimen RED" },
  "REASONS": { file: "acceptance.test.mjs", test: "REASONS FIRES: a specimen still REJECTED, but for a reason the doctrine did not name" },
  "CAUGHT-BY": { file: "acceptance.test.mjs", test: "MUTATION: relabelling a caught specimen UNCAUGHT turns it RED" },
  "DECLARED-DIVERGENCE": { file: "acceptance.test.mjs", test: "MUTATION: a DECLARED divergence is reported as a finding and keeps the suite green" },
  "UNDECLARED-DIVERGENCE": { file: "acceptance.test.mjs", test: "MUTATION: an UNDECLARED rule divergence turns it RED" },
  "PROBE-DRIFT": { file: "acceptance.test.mjs", test: "PROBE-DRIFT FIRES: a probe moved off its level voids the whole run before any specimen is judged" },

  // level.mjs — the authority grammar
  "UNKNOWN-LEVEL": { file: SELF, test: "UNKNOWN-LEVEL fires on a claim that is not on the ladder, and names the ladder it is off" },
  "LEVEL-SKIP": { file: "level.test.mjs", test: "a claim above the derived level is REJECTED with LEVEL-SKIP naming both levels" },
  "PATHLESS-REF": { file: "level.test.mjs", test: "a path-less line reference is REJECTED with PATHLESS-REF" },
  "NOT-A-REF": { file: SELF, test: "NOT-A-REF fires on a non-reference, and never on a real one" },

  // record.mjs — write-time admission
  "MISSING-SUBJECT": { file: "level.test.mjs", test: "admitFact rejects a subject-less or claim-less record with named reasons" },
  "MISSING-CLAIM": { file: "level.test.mjs", test: "admitFact rejects a subject-less or claim-less record with named reasons" },
  "BAD-DEPS": { file: "ledger.test.mjs", test: "deps must be an array of non-empty subjects (R2), and empty is honest" },
  "INADMISSIBLE-CONTINUOUS": { file: "level.test.mjs", test: "admitFact flags a predicate-less continuous quantity INADMISSIBLE-CONTINUOUS" },

  // mint.mjs — recipe minting
  "NO-RERUN": { file: SELF, test: "NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints" },
  "NO-SUBJECT": { file: SELF, test: "NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints" },
  "NO-QUANTITY": { file: SELF, test: "NO-QUANTITY is REACHABLE: a path swallowed by `cd` mints a subject and no quantity" },

  // ledger.mjs — the store
  "ALREADY-RECORDED": { file: "ledger.test.mjs", test: "the same run written twice is ALREADY-RECORDED — idempotent, and still one file" },
  "UNPARSEABLE": { file: "ledger.test.mjs", test: "an unparseable ledger file is REPORTED, never silently skipped (D6)" },
  "MALFORMED-RUN": { file: "ledger.test.mjs", test: "an unparseable ledger file is REPORTED, never silently skipped (D6)" },
  "NOT-A-RUN": { file: "ledger.test.mjs", test: "a document that never claimed to be a run is NOT-A-RUN, DISTINCT from MALFORMED-RUN, and both stay counted" },
  "MALFORMED-ROW": { file: "ledger.test.mjs", test: "null rows, bare strings and subject-less rows are REPORTED, never merged into one bogus entry" },
});

test("FIRING TRIPWIRE: every rule a grip module can RETURN has a test that makes it fire", () => {
  const scan = scanFiringCoverage({ registry: FIRING_CONTROLS });
  const names = scan.unregistered.map((row) => `${row.rule} (${row.where})`);

  console.log(
    `\n  [firing] ${scan.universe.size} returnable rules found (reason:/kind: literals, hyphen NOT required)` +
      `, ${Object.keys(FIRING_CONTROLS).length} registered firing controls` +
      `\n  [firing] returnable with no FIRING control: ${names.length === 0 ? "none" : names.join(", ")}\n`,
  );

  assert.deepEqual(
    names, [],
    "a grip module can return this rule and no test makes it fire. Mention is not control and an absence " +
      "assertion is not control — write a positive control and register it in FIRING_CONTROLS. There is no " +
      "exemption list: a rule that cannot go red is a gate that cannot go red",
  );
});

test("FIRING TRIPWIRE points at real tests: no registry row is a phantom, and no title is ambiguous", () => {
  const scan = scanFiringCoverage({ registry: FIRING_CONTROLS });

  // The other rot direction. A renamed or deleted control leaves a row that
  // still READS like coverage, which is the same laundering one level up.
  assert.deepEqual(
    scan.phantoms, [],
    "a FIRING_CONTROLS row no longer points at a test that names its rule — the control was renamed or deleted",
  );

  // Bodies are sliced by title, so a duplicated title inside one file would make
  // the body lookup ambiguous and the phantom check quietly weaker.
  assert.deepEqual(scan.duplicates, [], "two tests share a title inside one file — the firing scan slices bodies by title");

  // NOT VACUOUS: the registry is non-empty and covers more than one module.
  assert.ok(Object.keys(FIRING_CONTROLS).length >= 20, "the registry lost rows without the tripwire noticing");
  assert.ok(new Set(Object.values(FIRING_CONTROLS).map((e) => e.file)).size >= 4);
});

test("FIRING TRIPWIRE is able to fail: a planted rule with a MENTION-ONLY test is flagged, while part (A) clears it", () => {
  // THE DISCRIMINATION, demonstrated rather than asserted in prose. The plant is
  // a module that RETURNS a new rule, plus a test file that names the rule in an
  // absence assertion — exactly the shape UNKNOWN-LEVEL had. Part (A) sees a
  // mention and reports the class controlled. Part (E) sees no firing control
  // and reports it uncontrolled. Both scans, one tree, opposite answers.
  const planted = ["PLANTED", "MENTION", "ONLY"].join("-");
  const scratch = mkdtempSync(join(tmpdir(), "grip-firing-plant-"));
  try {
    cpSync(GRIP, join(scratch, "grip"), { recursive: true });
    const src = join(scratch, "grip");
    writeFileSync(join(src, "planted.mjs"), `export const plantedRule = () => ({ ok: false, reason: "${planted}" });\n`, "utf8");
    // The mention-only test: it names the rule and asserts it is ABSENT, which is
    // green whether the rule works or was deleted.
    writeFileSync(
      join(src, "test", "planted.test.mjs"),
      `import { test } from "node:test";\nimport assert from "node:assert/strict";\n` +
        `test("the planted rule is not restated elsewhere", () => {\n` +
        `  assert.equal("nothing".includes("${planted}"), false);\n});\n`,
      "utf8",
    );

    const mention = scanClassCoverage({ srcDir: src, testDir: join(src, "test") });
    assert.ok(mention.universe.has(planted), "the mention scan must see the planted rule at all");
    assert.equal(mention.dual.some((r) => r.id === planted), false,
      "part (A) is expected to CLEAR the plant — it is mentioned, and mention is all that scan measures");

    const firing = scanFiringCoverage({ srcDir: src, testDir: join(src, "test"), registry: FIRING_CONTROLS });
    assert.ok(firing.universe.has(planted), "the firing scan must see the planted rule");
    assert.deepEqual(
      firing.unregistered.map((r) => r.rule), [planted],
      "the plant must be the one and only rule with no firing control — and the ONLY one, or the shipped tree is already leaking",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
