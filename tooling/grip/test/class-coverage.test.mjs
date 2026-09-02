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
//     29 → 2 while IMPROVING the epic's flagship else-share 4.8% → 0.6% with
//     nothing going red (binding.test.mjs registers rules through
//     `assert.ok(registered.has(…))`, a subset check that cannot fail for an
//     unexercised rule). So absence here is a PROOF of no control; presence is
//     only an INVITATION to check. The controls in part (B) below are the real
//     thing: each one fires the class on an input that must trigger it and
//     withholds it on a neighbour that must not.
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

import { classifyRef } from "../level.mjs";
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
  // 29 → 2 and IMPROVED the flagship else-share 4.8% → 0.6% with nothing red.
  // Both halves are pinned here — the name AND its default-ness.
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
