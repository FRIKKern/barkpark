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

import { runAcceptance, checkProbes, parseLevelSkip, READ_LEVEL_PROBES, EXPECTED, DECLARED_DIVERGENCES, FIXTURE } from "../acceptance.mjs";

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
