// class-coverage-firing.test.mjs — part (E) of the class-coverage suite: the
// firing registry, where a rule counts only if a named test makes it fire.
//
//   node --test tooling/grip/test/class-coverage-firing.test.mjs
//
// One of the class-coverage-*.test.mjs files the single class-coverage suite was
// split into by subject (task-ff9bcdb1cbe00405); the tests moved unchanged. The
// registry rows that named the old file now name class-coverage-controls.test.mjs,
// where those controls went. The tripwire reads all of this file as corpus, as
// it read part (E) when it sat after the part (B) banner.

import { test } from "node:test";
import assert from "node:assert/strict";

import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { GRIP, scanClassCoverage } from "./lib/class-coverage-scan.mjs";

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
  "UNKNOWN-LEVEL": { file: "class-coverage-controls.test.mjs", test: "UNKNOWN-LEVEL fires on a claim that is not on the ladder, and names the ladder it is off" },
  "LEVEL-SKIP": { file: "level-admit.test.mjs", test: "a claim above the derived level is REJECTED with LEVEL-SKIP naming both levels" },
  "PATHLESS-REF": { file: "level-admit.test.mjs", test: "a path-less line reference is REJECTED with PATHLESS-REF" },
  "NOT-A-REF": { file: "class-coverage-controls.test.mjs", test: "NOT-A-REF fires on a non-reference, and never on a real one" },

  // record.mjs — write-time admission
  "MISSING-SUBJECT": { file: "level-admit.test.mjs", test: "admitFact rejects a subject-less or claim-less record with named reasons" },
  "MISSING-CLAIM": { file: "level-admit.test.mjs", test: "admitFact rejects a subject-less or claim-less record with named reasons" },
  "BAD-DEPS": { file: "ledger.test.mjs", test: "deps must be an array of non-empty subjects (R2), and empty is honest" },
  "INADMISSIBLE-CONTINUOUS": { file: "level-admit.test.mjs", test: "admitFact flags a predicate-less continuous quantity INADMISSIBLE-CONTINUOUS" },

  // mint.mjs — recipe minting
  "NO-RERUN": { file: "class-coverage-controls.test.mjs", test: "NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints" },
  "NO-SUBJECT": { file: "class-coverage-controls.test.mjs", test: "NO-QUANTITY never cries wolf: NO-SUBJECT and NO-RERUN keep their own reasons, and a real read mints" },
  "NO-QUANTITY": { file: "class-coverage-controls.test.mjs", test: "NO-QUANTITY is REACHABLE: a path swallowed by `cd` mints a subject and no quantity" },

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
