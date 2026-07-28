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

import { runAcceptance, checkProbes, parseLevelSkip, READ_LEVEL_PROBES, EXPECTED, SCREEN_EXPECTED, DECLARED_DIVERGENCES, FIXTURE } from "../acceptance.mjs";
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

test("specimen 5's R3 label diverges from what the adjudicator does, and it is DECLARED", () => {
  const outcome = runAcceptance();
  const finding = outcome.findings.find((f) => f.kind === "DECLARED-DIVERGENCE" && f.id === 5);

  assert.ok(finding, "specimen 5's divergence must be REPORTED on every run, not absorbed silently");
  assert.equal(finding.labelled, "R3");
  assert.equal(finding.actually, "R1");
  assert.ok(finding.filed_as, "a declared divergence must name the task that pays it off");

  // It is caught — the SAFETY half holds. Only the DIAGNOSIS half diverges.
  const row = rowFor(outcome, 5);
  assert.equal(row.caught, true, "specimen 5 IS caught; the divergence is about which rule catches it");
  assert.deepEqual(row.reasons, ["LEVEL-SKIP"]);
});

test("a divergence may only be declared for a specimen that actually diverges", () => {
  // The guard on the escape hatch. If DECLARED_DIVERGENCES could be padded with
  // specimens that behave correctly, it would become a place to park anything
  // inconvenient and the suite would rot from the inside.
  const outcome = runAcceptance();
  for (const id of Object.keys(DECLARED_DIVERGENCES)) {
    const row = rowFor(outcome, Number(id));
    assert.ok(row, `specimen ${id} is declared divergent but is not in the ratified set`);
    const byLabelledRule = row.caught_by === "R1" && row.reasons.includes("LEVEL-SKIP");
    assert.equal(byLabelledRule, false,
      `specimen ${id} is declared divergent but is caught by exactly the rule its label names — remove the declaration`);
  }
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

test("a declaration with no filed task is FATAL — the hatch cannot be padded with a shrug", async () => {
  const err = await mutatedModule((s) => s.replace(/filed_as: "tgw4-r3-has-no-adjudicator-check"/, 'filed_as: ""'));
  assert.ok(err, "an empty filed_as imported cleanly — the guard is not enforcing its own rule");
  assert.match(String(err.message), /DECLARED_DIVERGENCES\[5\] is malformed/);
  assert.match(String(err.message), /filed_as/);
});

test("a declaration whose label does not actually diverge is FATAL", async () => {
  const err = await mutatedModule((s) => s.replace(/actually: "R1"/, 'actually: "R3"'));
  assert.ok(err, "a non-divergent declaration imported cleanly");
  assert.match(String(err.message), /not a divergence/);
});

test("the shipped declaration passes its own guard — the check is not simply always-fatal", async () => {
  const err = await mutatedModule((s) => s);
  assert.equal(err, null, `the unmutated module failed its own declaration guard: ${err?.message}`);
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
