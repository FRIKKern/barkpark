#!/usr/bin/env node
// Proof for the level-skip acceptance suite — tooling/grip/acceptance.mjs
//
//   node --test tooling/grip/test/acceptance.test.mjs
//
// acceptance.mjs is itself a check, so this file's job is the awkward one:
// prove the CHECK CAN FAIL. A suite that reports "6/6, PASS" and would report
// it against a broken adjudicator is worse than no suite, because it converts
// an unknown into a false certainty — the exact laundering this epic exists to
// prevent, wearing the epic's own uniform.
//
// So every test below is a MUTATION: corrupt one input, assert the named red,
// and assert the failure is attributed to the right specimen. Nothing here
// asserts "it passes" without also having shown what makes it fail.
//
// HERMETIC. execute:false throughout — no specimen rerun is ever executed, and
// several of them ssh to production.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runAcceptance, checkProbes, parseLevelSkip, factFromSpecimen, READ_LEVEL_PROBES, EXPECTED, SCREEN_EXPECTED, DECLARED_DIVERGENCES, FIXTURE } from "../acceptance.mjs";
// The REAL fact-path engine. Specimen 103 is judged by the shipped adjudicator,
// never by a restatement of what it is believed to do.
import { adjudicate, VERDICTS } from "../adjudicate.mjs";
import { screenCommand } from "../screen.mjs";
// Imported to MEASURE the difference between the two gates, never to run one.
import { classifySafety } from "../rerun.mjs";

/** Write a mutated copy of the fixture and hand back its path. */
function withMutatedFixture(mutate, fn) {
  const dir = mkdtempSync(join(tmpdir(), "grip-acceptance-"));
  try {
    const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));
    mutate(fixture);
    const path = join(dir, "specimens.json");
    writeFileSync(path, JSON.stringify(fixture, null, 1), "utf8");
    return fn(path);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const specimen = (fixture, id) => fixture.specimens.find((s) => s.id === id);
const rowFor = (outcome, id) => outcome.results.find((r) => r.id === id);

// ─────────────────────────────────────────────────────────────────────────────
// The standing result
// ─────────────────────────────────────────────────────────────────────────────

test("the six ratified specimens adjudicate as expected against the REAL adjudicator", () => {
  const outcome = runAcceptance();
  assert.equal(outcome.probe_drift.length, 0,
    `PROBE-DRIFT: ${JSON.stringify(outcome.probe_drift)} — the read-level model is broken and no result below means anything`);
  assert.equal(outcome.specimen_count, 6, "the ratified table has six rows");
  assert.equal(outcome.results.length, 6);

  const failing = outcome.results.filter((r) => r.failures.length > 0);
  assert.deepEqual(failing, [],
    `specimens failed: ${failing.map((r) => `[${r.id}] ${r.failures.map((f) => `${f.kind}: ${f.detail}`).join("; ")}`).join(" | ")}`);
  assert.equal(outcome.ok, true);
});

test("every read-level probe still derives the level it is filed under", () => {
  // The whole modelling rests on this. deriveLevel is the real grammar; if a
  // probe drifts, every specimen below is being judged against a fact that does
  // not model it.
  assert.deepEqual(checkProbes(), [],
    "a probe no longer derives its level — acceptance.mjs's READ_LEVEL_PROBES table is stale");
});

test("L5 is deliberately absent from the probe table, and specimen 5 records the remap", () => {
  // Not an oversight — level.mjs:18 says L5 is never derived. Asserting the
  // ABSENCE keeps a future author from "fixing" it with a command that does not
  // actually derive L5.
  assert.equal(Object.hasOwn(READ_LEVEL_PROBES, "L5"), false,
    "L5 has no probe because no command derives it; adding one would model a level the grammar cannot express");

  const row = rowFor(runAcceptance(), 5);
  assert.ok(row.modelled.remap, "specimen 5 reads at L5/L3 and its L5→L3 collapse must be REPORTED, not silent");
  assert.equal(row.modelled.remap.from, "L5");
  assert.equal(row.modelled.remap.to, "L3");
});

// ─────────────────────────────────────────────────────────────────────────────
// PROVE IT CAN FAIL — one mutation per failure mode the suite claims to detect
// ─────────────────────────────────────────────────────────────────────────────

test("MUTATION: corrupting a specimen's claimed level turns that specimen RED", () => {
  // Specimen 1 reads at L2 and claims L1 — a level skip. Rewrite the claim DOWN
  // to L3 and it becomes an honest under-claim, so the adjudicator admits it
  // and the expectation (REJECTED / LEVEL-SKIP) must fail by name.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 1).level_skip = "read at L2 (git HEAD matched origin/main), claimed at L3 (\"it is in my checkout\")";
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false, "the acceptance suite reported PASS against a corrupted specimen");

  const row = rowFor(outcome, 1);
  assert.ok(row.failures.length > 0, "specimen 1 must be the one that fails");
  const kinds = row.failures.map((f) => f.kind);
  assert.ok(kinds.includes("VERDICT"), `expected a VERDICT failure, got ${kinds.join("+")}`);
  assert.ok(kinds.includes("CAUGHT-BY"),
    "labelled caught_by R1 but ADMITTED — the caught_by hypothesis must be reported as falsified");

  // ATTRIBUTION: only the corrupted specimen fails. A suite that reddens
  // everything on one bad row cannot tell you WHICH row is wrong.
  const others = outcome.results.filter((r) => r.id !== 1 && r.failures.length > 0);
  assert.deepEqual(others, [], "the mutation leaked into other specimens");
});

test("MUTATION: relabelling a caught specimen UNCAUGHT turns it RED", () => {
  // The hypothesis runs in BOTH directions. A specimen labelled UNCAUGHT that
  // the adjudicator actually rejects is just as much a false label as the
  // reverse, and a suite that only checked one direction would let the fixture
  // quietly under-claim the grammar's reach.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 2).caught_by = "UNCAUGHT";
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false);
  const row = rowFor(outcome, 2);
  const caughtBy = row.failures.find((f) => f.kind === "CAUGHT-BY");
  assert.ok(caughtBy, `expected a CAUGHT-BY failure, got ${row.failures.map((f) => f.kind).join("+")}`);
  assert.match(caughtBy.detail, /labelled UNCAUGHT but the adjudicator REJECTED it/);
});

test("MUTATION: an UNDECLARED rule divergence turns it RED", () => {
  // Specimen 3 is caught by R1 under LEVEL-SKIP. Relabel it R3 — still "caught",
  // so the safety half passes — and the DIAGNOSIS half must catch that it is
  // caught by a different rule than the label names. This is the check that
  // found the real specimen-5 finding.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 3).caught_by = "R3";
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false);
  const row = rowFor(outcome, 3);
  const divergence = row.failures.find((f) => f.kind === "UNDECLARED-DIVERGENCE");
  assert.ok(divergence, `expected UNDECLARED-DIVERGENCE, got ${row.failures.map((f) => f.kind).join("+")}`);
  assert.match(divergence.detail, /caught by a DIFFERENT rule than its label/);
});

test("MUTATION: losing a ratified specimen turns it RED", () => {
  // The fixture's own _meta re-derives "six rows" from the durable paper. A
  // fixture that silently shrank would otherwise report a clean 5/5.
  const outcome = withMutatedFixture((fixture) => {
    fixture.specimens = fixture.specimens.filter((s) => s.id !== 6);
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false);
  const finding = outcome.findings.find((f) => f.kind === "SPECIMEN-COUNT");
  assert.ok(finding, "a missing ratified specimen must be reported");
  assert.match(finding.detail, /found 5/);
});

test("MUTATION: an unexpected new ratified specimen turns it RED", () => {
  // Promoting an unratified specimen without revisiting this file leaves it
  // with no entry in EXPECTED — which must fail loudly rather than be skipped.
  // A suite that silently ignores rows it does not recognise measures only the
  // rows its author already thought about.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 101).ratified = true;
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false);
  const row = rowFor(outcome, 101);
  assert.ok(row, "the newly ratified specimen must appear in the results");
  assert.ok(row.failures.some((f) => f.kind === "NO-EXPECTATION"),
    `expected NO-EXPECTATION, got ${row.failures.map((f) => f.kind).join("+")}`);
});

// ─────────────────────────────────────────────────────────────────────────────
// The declared divergence is a FINDING under a filed task, not a waiver
// ─────────────────────────────────────────────────────────────────────────────

test("specimen 5 is caught by R1 and NOTHING is declared — the divergence is paid off, not waived", () => {
  // It was `labelled R3 / actually R1` for the life of this file. The fixture's
  // label now names the rule that actually fires, so there is nothing left to
  // silence. `caught_by` is a HYPOTHESIS the fixture asks this suite to test
  // (_meta.caught_by_is_a_hypothesis) — correcting it against measurement is the
  // fixture working, not the fixture being edited to match a green.
  const outcome = runAcceptance();

  assert.deepEqual(Object.keys(DECLARED_DIVERGENCES), [],
    "a declaration is back: it silences a real finding and must be paid off by a filed task, not carried");
  assert.deepEqual(outcome.findings, [],
    `the run reported findings it should no longer have: ${JSON.stringify(outcome.findings)}`);

  const row = rowFor(outcome, 5);
  assert.equal(row.caught_by, "R1", "specimen 5's label must name the rule that actually rejects it");
  assert.equal(row.caught, true, "the SAFETY half was never in doubt — specimen 5 is caught");
  assert.deepEqual(row.reasons, ["LEVEL-SKIP"]);
  assert.equal(row.divergence, undefined, "a row carrying a divergence means the label and the adjudicator still disagree");
  assert.equal(outcome.ok, true);
});

test("MUTATION: specimen 5 relabelled back to R3 is UNDECLARED — removing the entry RE-ARMED the guard on the row it silenced", () => {
  // The one failure mode of paying off a declaration by relabelling: doing it
  // while the guard that would have caught the wrong label stays asleep. It does
  // not. Put the R3 label back and the run fails by name — which is exactly what
  // the declaration suppressed for as long as it existed.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 5).caught_by = "R3";
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false, "the R3 label went green again — the declaration was removed without the guard picking the finding back up");
  const row = rowFor(outcome, 5);
  const divergence = row.failures.find((f) => f.kind === "UNDECLARED-DIVERGENCE");
  assert.ok(divergence, `expected UNDECLARED-DIVERGENCE, got ${row.failures.map((f) => f.kind).join("+")}`);
  assert.match(divergence.detail, /labelled caught_by R3/);
});

test("a divergence may only be declared for a specimen that actually diverges", () => {
  // The guard on the escape hatch. If DECLARED_DIVERGENCES could be padded with
  // specimens that behave correctly, it would become a place to park anything
  // inconvenient and the suite would rot from the inside.
  const outcome = runAcceptance();
  const wouldBeJustified = (row) => !(row.caught_by === "R1" && row.reasons.includes("LEVEL-SKIP"));

  for (const id of Object.keys(DECLARED_DIVERGENCES)) {
    const row = rowFor(outcome, Number(id));
    assert.ok(row, `specimen ${id} is declared divergent but is not in the ratified set`);
    assert.equal(wouldBeJustified(row), true,
      `specimen ${id} is declared divergent but is caught by exactly the rule its label names — remove the declaration`);
  }

  // NON-VACUITY. The table is empty, so the loop above asserts nothing on its
  // own — an empty `for` is the shape a guard dies in. The predicate is
  // therefore exercised directly, in both directions, against real rows.
  assert.equal(wouldBeJustified(rowFor(outcome, 5)), false,
    "specimen 5 is caught by exactly the rule its label names — a declaration for it would now be unjustified and this check must say so");
  assert.equal(wouldBeJustified({ caught_by: "R3", reasons: ["LEVEL-SKIP"] }), true,
    "a row whose label names a rule other than the one that fired IS a real divergence — the predicate must not refuse every declaration");
});

test("every ratified specimen has an expectation, and EXPECTED carries no phantoms", () => {
  const outcome = runAcceptance();
  const ids = new Set(outcome.results.map((r) => r.id));
  for (const id of Object.keys(EXPECTED)) {
    assert.ok(ids.has(Number(id)), `EXPECTED carries specimen ${id}, which is not a ratified specimen`);
  }
  assert.equal(Object.keys(EXPECTED).length, ids.size);
});

// ─────────────────────────────────────────────────────────────────────────────
// The prose parser
// ─────────────────────────────────────────────────────────────────────────────

test("parseLevelSkip reads both the plain and the straddling forms", () => {
  assert.deepEqual(parseLevelSkip("read at L2 (git HEAD matched origin/main), claimed at L1 (\"it is live\")"),
    { read: ["L2"], claimed: ["L1"] });
  assert.deepEqual(parseLevelSkip("read at L5/L3 (the env var is present), claimed at L1 (\"the recipient is …\")"),
    { read: ["L5", "L3"], claimed: ["L1"] });
  assert.deepEqual(parseLevelSkip("read at L4 (regenerated cleanly), claimed at L2/L3 (\"the file is correct\")"),
    { read: ["L4"], claimed: ["L2", "L3"] });
  // Specimen 4's prose opens with "NONE — this is a unit/identity confusion…",
  // so neither clause is present and no level is invented from thin air.
  assert.deepEqual(parseLevelSkip("NONE — this is a unit/identity confusion WITHIN one level"),
    { read: [], claimed: [] });
  assert.deepEqual(parseLevelSkip(undefined), { read: [], claimed: [] });
});

// ─────────────────────────────────────────────────────────────────────────────
// The escape hatch has to cost something (added in review)
// ─────────────────────────────────────────────────────────────────────────────
//
// DECLARED_DIVERGENCES silences a real finding. Its "each entry must be paid
// off by a filed task" rule lived only in a comment, so an entry with an empty
// `filed_as` — or a label that does not diverge from what actually fires —
// silenced the finding exactly as well as an honest declaration did. The shape
// check is now fatal on import; these tests prove it FIRES, in both directions,
// by importing a mutated copy of the module rather than by trusting the source.

// THE COPY GOES IN A TEMP DIR, NEVER BESIDE THE ORIGINAL. Writing it into
// tooling/grip made this suite flaky one run in three: another test in the same
// `node --test` process enumerates every file in tooling/grip (the D4 authorship
// wording scan), and it raced the copy's creation and deletion. So the copy
// lives outside the tree and its relative sibling imports are rewritten to
// absolute file:// URLs of the REAL modules — the module under test is still
// the shipped source plus one mutation, not a stub.
let declGuardSeq = 0;

/**
 * Import a mutated COPY of a tooling/grip module, from a temp dir.
 *
 * Generalised from the acceptance-only form so the same house pattern can
 * mutate cli.mjs (the exit-3 control below). Returns the namespace, or throws
 * whatever the mutated module threw on import.
 */
const importMutated = async (relPath, mutate) => {
  const srcUrl = new URL(`../${relPath}`, import.meta.url);
  const gripDir = new URL("../", import.meta.url).href.replace(/\/$/, "");
  const src = mutate(readFileSync(srcUrl, "utf8")).replace(/(from\s*")\.\//g, `$1${gripDir}/`);
  const dir = mkdtempSync(join(tmpdir(), "grip-mutated-"));
  const path = join(dir, `${relPath.replace(/\.mjs$/, "")}-${declGuardSeq++}.mjs`);
  writeFileSync(path, src, "utf8");
  try {
    return await import(`file://${path}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

const mutatedModule = async (mutate) => {
  try {
    await importMutated("acceptance.mjs", mutate);
    return null; // imported clean — the guard did NOT fire
  } catch (err) {
    return err;
  }
};

// THE TABLE IS EMPTY, SO THE GUARD IS PROVEN AGAINST A SYNTHETIC ENTRY.
//
// These tests used to mutate the shipped specimen-5 declaration. That
// declaration is paid off and gone, and a guard whose proof depended on a live
// divergence existing would go vacuous the moment the honest state (nothing
// declared) was reached — the escape hatch would be unguarded exactly when
// nobody was looking at it. So the entry is INSERTED into the empty table
// instead, and the insertion is asserted to have applied: a mutation that did
// not land is not a catch, it is a green.
const DECL_ANCHOR = "const DECLARED_DIVERGENCES = Object.freeze({});";

const withDeclaration = ({ filed_as = "tgw4-r3-has-no-adjudicator-check", actually = "R1" } = {}) => (src) => {
  assert.equal(src.split(DECL_ANCHOR).length - 1, 1,
    "the declaration anchor no longer occurs exactly once in acceptance.mjs — these mutations are not landing where they claim to");
  const entry = `const DECLARED_DIVERGENCES = Object.freeze({
  5: {
    labelled: "R3",
    actually: ${JSON.stringify(actually)},
    finding: "A SYNTHETIC declaration written by the test suite, long enough to clear the eighty-character floor the shape guard puts on a finding.",
    filed_as: ${JSON.stringify(filed_as)},
  },
});`;
  const out = src.replace(DECL_ANCHOR, entry);
  assert.notEqual(out, src, "the synthetic declaration did not apply");
  return out;
};

test("a declaration with no filed task is FATAL — the hatch cannot be padded with a shrug", async () => {
  const err = await mutatedModule(withDeclaration({ filed_as: "" }));
  assert.ok(err, "an empty filed_as imported cleanly — the guard is not enforcing its own rule");
  assert.match(String(err.message), /DECLARED_DIVERGENCES\[5\] is malformed/);
  assert.match(String(err.message), /filed_as/);
});

test("a declaration whose label does not actually diverge is FATAL", async () => {
  const err = await mutatedModule(withDeclaration({ actually: "R3" }));
  assert.ok(err, "a non-divergent declaration imported cleanly");
  assert.match(String(err.message), /not a divergence/);
});

test("an HONEST declaration imports cleanly — the guard is not simply always-fatal", async () => {
  const err = await mutatedModule(withDeclaration());
  assert.equal(err, null, `a well-formed declaration was rejected by the shape guard: ${err?.message}`);
});

test("the shipped (empty) table passes its own guard", async () => {
  const err = await mutatedModule((s) => s);
  assert.equal(err, null, `the unmutated module failed its own declaration guard: ${err?.message}`);
});

test("MUTATION: a DECLARED divergence is reported as a finding and keeps the suite green", async () => {
  // Emptying DECLARED_DIVERGENCES leaves the emission path with no live entry to
  // exercise it — an unreachable branch is exactly what this file refuses to
  // ship — so it is driven here against a module carrying the synthetic entry
  // and a fixture that actually diverges from its label.
  const mod = await importMutated("acceptance.mjs", withDeclaration());
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 5).caught_by = "R3";
  }, (path) => mod.runAcceptance(path));

  const finding = outcome.findings.find((f) => f.kind === "DECLARED-DIVERGENCE" && f.id === 5);
  assert.ok(finding, `a declared divergence must be REPORTED on every run, got ${JSON.stringify(outcome.findings)}`);
  assert.equal(finding.labelled, "R3");
  assert.equal(finding.actually, "R1");
  assert.equal(finding.filed_as, "tgw4-r3-has-no-adjudicator-check");

  const row = outcome.results.find((r) => r.id === 5);
  assert.deepEqual(row.failures, [], "a declared divergence is a FINDING, never a row failure — that is the whole difference from UNDECLARED");
  assert.ok(row.divergence, "the row must carry the declaration that silenced it");
  assert.equal(outcome.ok, true, "a declared divergence keeps the suite green — that is what declaring buys, and why the shape guard has to be fatal");
});

// ─────────────────────────────────────────────────────────────────────────────
// C5 — THE SPECIMEN'S OWN `rerun` IS SCREENED, AND THE ANSWER IS FROZEN (D116)
// ─────────────────────────────────────────────────────────────────────────────
//
// The one-word hazard this section exists to hold off: a reword saying "every
// specimen rerun goes through runRerun" would ssh to production from the test
// suite. `runRerun`'s step 1 is `classifySafety` (rerun.mjs:676), NOT
// `screenCommand`. The tests below MEASURE that difference rather than
// asserting it in prose.

const RATIFIED = JSON.parse(readFileSync(FIXTURE, "utf8")).specimens.filter((s) => s.ratified === true);

test("the six-row screen table is FROZEN VERBATIM — {ok, reason} per specimen, refusals included", () => {
  assert.equal(RATIFIED.length, 6, "the ratified table has six rows; the frozen screen table must cover all of them");

  // Measured, not restated: screenCommand is called here on the fixture's own
  // `rerun` strings and the answer is compared to the frozen table.
  const measured = Object.fromEntries(RATIFIED.map((s) => {
    const r = screenCommand(s.rerun ?? "");
    return [s.id, { ok: r.ok === true, reason: String(r.reason ?? "") }];
  }));

  assert.deepEqual(measured, {
    1: { ok: false, reason: "host bound: names ssh (remote execution)" },
    2: { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" },
    3: { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" },
    4: { ok: false, reason: "host bound: names barkpark.cloud" },
    5: { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" },
    6: { ok: false, reason: "not allowlisted: node executes arbitrary JavaScript (including fs writes)" },
  });

  // …and the module's own frozen table is the SAME table, so acceptance.mjs
  // cannot drift away from this file while both stay green.
  assert.deepEqual(Object.fromEntries(Object.entries(SCREEN_EXPECTED).map(([k, v]) => [k, { ...v }])), measured);

  // The suite reports it too — a freeze nobody reads is a freeze nobody keeps.
  const outcome = runAcceptance();
  for (const row of outcome.results) {
    assert.deepEqual(row.screen, measured[row.id], `specimen ${row.id}'s reported screen must match the measurement`);
  }
  assert.equal(outcome.results.filter((r) => !r.screen.ok).length, 3, "exactly three specimen reruns are refused");
});

test("the three refusals are NOT one class — specimen 6 is HEAD-ALLOWLIST, specimens 1 and 4 are HOST-BOUND", () => {
  // Collapsing them under a single "refused" label would let the head allowlist
  // be deleted entirely while the table stayed green, because the host bound
  // alone still refuses 1 and 4. They are different rules with different failure
  // modes, and the freeze keeps them apart by REASON, not by count.
  const reasonOf = (id) => SCREEN_EXPECTED[id].reason;

  for (const id of [1, 4]) {
    assert.match(reasonOf(id), /^host bound: /, `specimen ${id} is refused for leaving this box`);
  }
  assert.match(reasonOf(6), /^not allowlisted: /, "specimen 6 is refused for WHAT it runs, not WHERE");
  assert.notEqual(reasonOf(1), reasonOf(4), "the two host-bound refusals name different bounds (ssh vs a hostname)");

  // Specimen 6's rerun never leaves the loopback and is refused anyway — that is
  // the whole categorical difference, and it is also this slice's own L3
  // ceiling: every command in this file's gate starts with `node`.
  const localNode = screenCommand("node tooling/grip/cli.mjs --selftest");
  assert.equal(localNode.ok, false);
  assert.equal(localNode.reason, reasonOf(6),
    "grip refuses to screen its own execution under exactly the rule that refuses specimen 6 (screen.mjs:1096)");
});

test("TIGHTENING, MEASURED: classifySafety admits all six specimens; screenCommand refuses three", () => {
  // This is the measurement behind the claim that screening TIGHTENS the fixture
  // rather than softening it. `runRerun` gates on classifySafety, which says
  // safe:true for the ssh-to-production specimen and for the arbitrary-JS one.
  // adjudicate.mjs:90-96 calls that path, left to itself, "a default-on RCE".
  // Nothing below executes: both functions are pure string judgements.
  const admittedBySafety = [];
  for (const s of RATIFIED) {
    const v = classifySafety(s.rerun);
    assert.equal(v.safe, true,
      `classifySafety is expected to admit specimen ${s.id} — that permissiveness IS the finding`);
    assert.equal(v.reason, "no write shape detected");
    admittedBySafety.push(s.id);
  }
  assert.deepEqual(admittedBySafety, [1, 2, 3, 4, 5, 6], "classifySafety admits 6 of 6, ssh-to-production included");

  const refusedByScreen = RATIFIED.filter((s) => screenCommand(s.rerun).ok !== true).map((s) => s.id);
  assert.deepEqual(refusedByScreen, [1, 4, 6], "screenCommand refuses 3 of 6 — strictly more refusals, never fewer");

  // The strict-superset statement, asserted rather than narrated.
  const safeSet = new Set(admittedBySafety);
  for (const id of refusedByScreen) {
    assert.ok(safeSet.has(id), `specimen ${id} is refused by the screen and admitted by classifySafety`);
  }
  assert.ok(refusedByScreen.length > 0, "a screen that refused nothing would not be a tightening");
});

test("MUTATION: a permissive screen (admitAll) turns the acceptance suite RED under SCREEN-DRIFT", async () => {
  // The freeze has to be ABLE TO FAIL. Swap screenCommand for one that admits
  // everything — the shape a well-meaning "make the fixture runnable" edit would
  // take — and the three refusals must be reported by name, not absorbed.
  const mod = await importMutated("acceptance.mjs", (src) => {
    const patched = src.replace(
      /import \{ screenCommand \} from "\.\/screen\.mjs";/,
      'const screenCommand = () => ({ ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" });',
    );
    assert.notEqual(patched, src, "the screenCommand import moved — this mutation no longer mutates anything");
    return patched;
  });

  // The copy lives in a temp dir, so it is handed the REAL fixture path
  // explicitly — the module under test is the shipped source plus one mutation,
  // read against the shipped fixture.
  const outcome = mod.runAcceptance(FIXTURE);
  assert.equal(outcome.ok, false, "an admit-everything screen reported PASS — the freeze is not enforcing itself");

  const drifted = outcome.results.filter((r) => r.failures.some((f) => f.kind === "SCREEN-DRIFT")).map((r) => r.id);
  assert.deepEqual(drifted, [1, 4, 6], "exactly the three refused specimens must go red, and only them");

  const detail = outcome.results.find((r) => r.id === 6).failures.find((f) => f.kind === "SCREEN-DRIFT").detail;
  assert.match(detail, /node executes arbitrary JavaScript/, "the failure must quote the reason string it lost");
});

test("MUTATION: a specimen whose rerun is rewritten drifts against the frozen screen", () => {
  // The other direction. The freeze pins the SPECIMEN's command as much as the
  // screen's rules: editing specimen 1's ssh into a local grep would quietly
  // make the fixture tamer, and the frozen refusal is what notices.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 1).rerun = "grep -c reason tooling/grip/record.mjs";
  }, (path) => runAcceptance(path));

  assert.equal(outcome.ok, false);
  const drift = rowFor(outcome, 1).failures.find((f) => f.kind === "SCREEN-DRIFT");
  assert.ok(drift, `expected SCREEN-DRIFT, got ${rowFor(outcome, 1).failures.map((f) => f.kind).join("+") || "none"}`);
  assert.match(drift.detail, /host bound: names ssh/);

  // ATTRIBUTION — only the rewritten specimen drifts.
  const others = outcome.results.filter((r) => r.id !== 1 && r.failures.length > 0);
  assert.deepEqual(others, [], "the rerun rewrite leaked into other specimens");
});

test("a ratified specimen with no frozen screen row is a NO-SCREEN-EXPECTATION failure", () => {
  // The same never-skip-what-you-do-not-recognise rule EXPECTED already has.
  const outcome = withMutatedFixture((fixture) => {
    specimen(fixture, 101).ratified = true;
  }, (path) => runAcceptance(path));

  const row = rowFor(outcome, 101);
  assert.ok(row.failures.some((f) => f.kind === "NO-SCREEN-EXPECTATION"),
    `expected NO-SCREEN-EXPECTATION, got ${row.failures.map((f) => f.kind).join("+")}`);
});

test("SCREEN_EXPECTED carries no phantoms — one row per ratified specimen, no more", () => {
  const ids = new Set(RATIFIED.map((s) => s.id));
  for (const id of Object.keys(SCREEN_EXPECTED)) {
    assert.ok(ids.has(Number(id)), `SCREEN_EXPECTED pins specimen ${id}, which is not ratified`);
  }
  assert.equal(Object.keys(SCREEN_EXPECTED).length, ids.size);
});

// ─────────────────────────────────────────────────────────────────────────────
// C2 — THE EXIT-3 OUTCOME CLASS IS RE-DERIVABLE, NOT A ONE-TIME HAND RUN
// ─────────────────────────────────────────────────────────────────────────────
//
// "CONTROL DID NOT BEHAVE AS A CONTROL" was proven once, by hand, by breaking a
// fixture in the working tree. A third outcome class whose only evidence is a
// paragraph in a wave log is exactly the shape this epic refuses, so the
// mutation is automated here on the same house pattern the declaration-guard
// tests use: import a mutated COPY of cli.mjs and call its real `selftest()`.

/** Run a (possibly mutated) cli.mjs selftest, capturing stdout instead of printing it. */
const runSelftest = async (mutate) => {
  const mod = await importMutated("cli.mjs", mutate);
  const chunks = [];
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = (chunk) => { chunks.push(String(chunk)); return true; };
  try {
    return { code: mod.selftest(), out: chunks.join("") };
  } finally {
    process.stdout.write = write;
  }
};

test("MUTATION: breaking a control's PRECONDITION yields exit 3, not a pass and not a guard failure", async () => {
  // The LEVEL-SKIP control only tests a level SKIP if its clean twin's command
  // really derives L2. Point the clean twin at a local command and the
  // precondition breaks: the poisoned twin's rejection would then prove nothing,
  // so the run must VOID it rather than count it.
  const { code, out } = await runSelftest((src) => {
    const patched = src.replace(
      'clean: withField({ rerun: "git show origin/main:tooling/grip/record.mjs", level: "L2" }),',
      'clean: withField({ rerun: "git rev-parse --short HEAD", level: "L2" }),',
    );
    assert.notEqual(patched, src, "the LEVEL-SKIP clean twin moved — this mutation no longer mutates anything");
    return patched;
  });

  assert.equal(code, 3, `expected EXIT.CONTROL_INVALID (3), got ${code}\n${out}`);
  assert.match(out, /CONTROL DID NOT BEHAVE AS A CONTROL \(1\)/);
  assert.match(out, /VOID {2}LEVEL-SKIP/, "the voided control must be named, not merely counted");
  assert.match(out, /the clean twin's command must derive L2/);

  // 1-vs-3 is the whole point: an invalid experiment is NOT a guard failure.
  assert.doesNotMatch(out, /^GUARD FAILURE/m);
  // …and the other controls still ran. A harness that reddens everything on one
  // broken fixture cannot tell you which fixture broke.
  assert.ok(out.split("\n").filter((l) => l.startsWith("  ok")).length >= 10,
    "the surviving controls must still fire — only the voided one is withheld");
});

test("MUTATION: a control that stops REJECTING its planted defect yields exit 1, never exit 3", async () => {
  // The discriminator, in the other direction. Exit 3 says "we do not know";
  // exit 1 says "we know, and the guard is broken". A harness that answered 3 to
  // both would launder a real guard failure into an inconclusive.
  const { code, out } = await runSelftest((src) => {
    const patched = src.replace(
      'poisoned: withField({ subject: "   " }),',
      'poisoned: withField({}),',
    );
    assert.notEqual(patched, src, "the MISSING-SUBJECT poisoned twin moved — this mutation no longer mutates anything");
    return patched;
  });

  assert.equal(code, 1, `expected EXIT.GUARD_FAILURE (1), got ${code}\n${out}`);
  assert.match(out, /GUARD FAILURE \(1\)/);
  assert.doesNotMatch(out, /CONTROL DID NOT BEHAVE AS A CONTROL/);
});

test("the UNMUTATED selftest is clean at exit 0 — the exit-3 path is not simply always-on", async () => {
  const { code, out } = await runSelftest((s) => s);
  assert.equal(code, 0, `the shipped selftest must be clean; got ${code}\n${out}`);
  assert.match(out, /grip --selftest — clean/);
  assert.match(out, /all \d+ controls fired as designed\./,
    "the verdict line must be present — capture the selftest to a FILE, never a pipe (tgw11-bl-cli-selftest-pipe-truncation)");
});

// ─────────────────────────────────────────────────────────────────────────────
// R3 HAS NO CHECK ON THE FACT PATH — specimen 103 is the standing proof
// ─────────────────────────────────────────────────────────────────────────────
//
// Specimen 5 carried the R3 label for the life of this fixture and could never
// have tested R3: its levels are dishonest, so LEVEL-SKIP fires first and no R3
// reasoning is ever reached. Until specimen 103 there was no specimen anywhere
// that violates R3 WITHOUT also being a level skip, which means no R3 check was
// testable against this fixture at all — a rule with nothing able to make it
// fire, which is the vacuity this module exists to refuse.
//
// 103 supplies the missing shape and the two tests below say what the fact path
// does with it: it ADMITS it. That is a gap, stated as a measurement. The day an
// R3 rejection lands on the fact path, the second test goes RED — the correct
// signal, not a regression: re-derive 103's label, promote it from a negative
// control to a catch, and delete the assertion.

test("specimen 103 violates R3 with HONEST levels — R1 structurally cannot reach it", () => {
  const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));
  const s = specimen(fixture, 103);
  assert.ok(s, "specimen 103 is missing — the fixture holds no R3 case R1 cannot reach, so no R3 check is testable against it");

  assert.equal(s.ratified, false, "the ratified table has SIX rows; 103 is a negative control, never a seventh row");
  assert.equal(s.caught_by, "UNCAUGHT", "labelling this a catch would bank a rejection the fact path does not make");
  assert.ok(typeof s.uncaught_reason === "string" && s.uncaught_reason.length > 20,
    "an UNCAUGHT specimen with no reason is padding — the fixture's own anti-vacuity rule");

  // THE POINT: the levels are EQUAL. LEVEL-SKIP compares the read level against
  // the claimed one, so it has nothing to compare. What is wrong here is the
  // CONTROL — the read could not have come back any other way — and nothing else.
  const parsed = parseLevelSkip(s.level_skip);
  assert.deepEqual(parsed.read, ["L3"]);
  assert.deepEqual(parsed.claimed, ["L3"]);
});

test("the fact path ADMITS specimen 103 — R3 is enforced NOWHERE on it", () => {
  const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));
  const { fact, readLevel, claimedLevel } = factFromSpecimen(specimen(fixture, 103));

  // Modelled EXACTLY as a ratified specimen is — same probe table, same fields.
  // A bespoke fact built for this test would prove something about the test.
  assert.equal(readLevel, "L3");
  assert.equal(claimedLevel, "L3");
  assert.equal(fact.rerun, READ_LEVEL_PROBES.L3);

  const ruling = adjudicate(fact, { execute: false });
  assert.equal(ruling.verdict, VERDICTS.ADMITTED,
    `the fact path now rejects specimen 103 (${ruling.label}) — if that is an R3 check landing, this is the moment to re-derive 103's caught_by label and promote it from a negative control to a catch`);
  assert.deepEqual(ruling.reasons, [],
    "a vacuously-controlled but honestly-levelled fact is admitted with no reason recorded — that IS the gap this specimen freezes");
  assert.equal(ruling.level, "L3");
});
