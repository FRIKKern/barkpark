#!/usr/bin/env node
// Proof for the IN-LOOP provenance gate that lives inside the epic-cycle
// workflow — `gateFactProvenance` in .claude/workflows/bp-epic-cycle.workflow.js
//
//   node --test tooling/grip/test/inloop-gate.test.mjs
//
// WHY A VM HARNESS. A workflow file cannot be imported: the host parses it with
// acorn in module mode (so a line-1 `export const meta` and a column-0 top-level
// `return` can coexist) and then compiles the body with vm.Script — a CLASSIC
// SCRIPT, never a module. `import` dies at compile, dynamic import() is
// hand-refused, `require` is undefined, and the context is created with
// codeGeneration:{strings:false,wasm:false} so eval and new Function raise
// EvalError (charter D19). So this test does what the host does: read the
// source, extract the named helper, and run it under a faithful reproduction of
// that context. Same mutation-proof pattern wave 1 used for the fan-out throws.
//
// WHAT IS UNDER TEST, honestly scoped: the gate over THE WAVE'S FACT FLOW — the
// facts[] the survey and verify fleets hand back — NOT every write in the repo.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const WORKFLOW = join(REPO, ".claude", "workflows", "bp-epic-cycle.workflow.js");
const SOURCE = readFileSync(WORKFLOW, "utf8");
const HELPER = "gateFactProvenance";

// ── Extract the helper by pattern (never by line number — every cited line
// number in this file's history has gone stale within a wave). ───────────────
function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} not found in ${WORKFLOW} — the in-loop gate was removed or renamed`);
  const open = source.indexOf("{", start);
  assert.notEqual(open, -1, `${name} has no body`);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    const ch = source[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`${name} body never closes — brace imbalance in the workflow`);
}

const HELPER_SOURCE = extractFunction(SOURCE, HELPER);

// A context shaped like the host's: no globals worth having, and code
// generation from strings shut off exactly as the host shuts it off.
function hostContext() {
  return vm.createContext(Object.create(null), {
    codeGeneration: { strings: false, wasm: false },
  });
}

function loadGate() {
  const ctx = hostContext();
  return new vm.Script(`${HELPER_SOURCE}\n${HELPER}`).runInContext(ctx);
}

// The helper's return value is born in the vm realm, so its prototype is not
// this realm's Object.prototype — read the two counts across the boundary
// rather than comparing object identity.
function counts(result) {
  return { total: result.total, demoted: result.demoted };
}

// ── 0. THE HARNESS IS ACTUALLY HOST-SHAPED ───────────────────────────────────
// If this ever passes silently, the rest of the file proves nothing about the
// environment the helper really runs in.

test("the harness context refuses eval and new Function, like the host does", () => {
  const ctx = hostContext();
  assert.throws(
    () => new vm.Script("eval('1 + 1')").runInContext(ctx),
    (err) => err instanceof EvalError || /Code generation from strings/.test(String(err)),
  );
  assert.throws(
    () => new vm.Script("new Function('return 1')()").runInContext(ctx),
    (err) => err instanceof EvalError || /Code generation from strings/.test(String(err)),
  );
});

test("the helper loads and runs inside that context", () => {
  const gate = loadGate();
  assert.equal(typeof gate, "function");
  assert.deepEqual(counts(gate([])), { total: 0, demoted: 0 });
});

// ── 1. THE ONE QUESTION IT ASKS: is rerun present and non-empty? ─────────────

test("a fact WITH a rerun command is left completely untouched", () => {
  const gate = loadGate();
  const fact = { claim: "main has the gate", evidence: "read it", rerun: "git show origin/main:tooling/grip/record.mjs" };
  const report = { key: "s1", facts: [fact] };
  const result = gate([report]);

  assert.deepEqual(counts(result), { total: 1, demoted: 0 });
  assert.equal(Object.prototype.hasOwnProperty.call(fact, "provenance"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(fact, "provenance_note"), false);
  assert.deepEqual(Object.keys(fact), ["claim", "evidence", "rerun"]);
});

test("a fact with an EMPTY rerun is demoted and annotated in place", () => {
  const gate = loadGate();
  const fact = { claim: "I believe X", evidence: "recall", rerun: "" };
  const result = gate([{ key: "s1", facts: [fact] }]);

  assert.deepEqual(counts(result), { total: 1, demoted: 1 });
  assert.equal(fact.provenance, "DEMOTED-NO-RERUN");
  assert.match(fact.provenance_note, /rerun/);
  assert.equal(fact.claim, "I believe X"); // the fact's own content is not rewritten
  assert.equal(fact.evidence, "recall");
});

test("a WHITESPACE-only rerun counts as empty, not as a command", () => {
  const gate = loadGate();
  const fact = { claim: "X", evidence: "y", rerun: "   \n\t " };
  assert.deepEqual(counts(gate([{ key: "s1", facts: [fact] }])), { total: 1, demoted: 1 });
  assert.equal(fact.provenance, "DEMOTED-NO-RERUN");
});

test("a fact with NO rerun key at all is demoted and annotated", () => {
  const gate = loadGate();
  const fact = { claim: "X", evidence: "y" };
  assert.deepEqual(counts(gate([{ key: "s1", facts: [fact] }])), { total: 1, demoted: 1 });
  assert.equal(fact.provenance, "DEMOTED-NO-RERUN");
});

test("a non-string rerun (a model returning a number/object) does NOT pass the gate", () => {
  const gate = loadGate();
  const facts = [{ claim: "a", evidence: "b", rerun: 42 }, { claim: "c", evidence: "d", rerun: { cmd: "ls" } }];
  assert.deepEqual(counts(gate([{ key: "s1", facts }])), { total: 2, demoted: 2 });
  for (const f of facts) assert.equal(f.provenance, "DEMOTED-NO-RERUN");
});

// ── 2. DEMOTE, NEVER DROP — length in === length out ─────────────────────────

test("array length before === after, across every report and every fact", () => {
  const gate = loadGate();
  const reports = [
    { key: "s1", facts: [{ claim: "1", evidence: "e", rerun: "git show origin/main:README.md" }, { claim: "2", evidence: "e" }] },
    { key: "s2", facts: [{ claim: "3", evidence: "e", rerun: "" }, { claim: "4", evidence: "e", rerun: "curl -s localhost:4000/api/schemas" }, { claim: "5", evidence: "e" }] },
    { key: "s3", facts: [] },
  ];
  const before = reports.map((r) => r.facts.length);
  const beforeClaims = reports.flatMap((r) => r.facts.map((f) => f.claim));

  const result = gate(reports);

  assert.deepEqual(reports.map((r) => r.facts.length), before, "a fact was DROPPED — a silent loss, the same defect class as a silent promotion");
  assert.deepEqual(reports.flatMap((r) => r.facts.map((f) => f.claim)), beforeClaims, "fact order or content changed");
  assert.equal(reports.length, 3);
  assert.deepEqual(counts(result), { total: 5, demoted: 3 });
});

test("the demotion SURVIVES JSON.stringify — the next Fable actually sees it", () => {
  // Both downstream serialisation sites are JSON.stringify of the gated array.
  const gate = loadGate();
  const reports = [{ key: "s1", facts: [{ claim: "X", evidence: "y" }] }];
  gate(reports);
  const round = JSON.parse(JSON.stringify(reports));
  assert.equal(round[0].facts.length, 1);
  assert.equal(round[0].facts[0].provenance, "DEMOTED-NO-RERUN");
  assert.match(round[0].facts[0].provenance_note, /demote, never reject/);
});

// ── 3. RAGGED INPUT — the fleet is allowed to hand back holes ────────────────

test("missing facts[], null reports and null facts do not throw", () => {
  const gate = loadGate();
  assert.deepEqual(counts(gate(undefined)), { total: 0, demoted: 0 });
  assert.deepEqual(counts(gate(null)), { total: 0, demoted: 0 });
  assert.deepEqual(counts(gate([null, undefined, {}, { key: "s", facts: null }])), { total: 0, demoted: 0 });
  assert.deepEqual(counts(gate([{ key: "s", facts: [null, "not-an-object", { claim: "a", evidence: "b" }] }])), { total: 1, demoted: 1 });
});

// ── 4. THE IN-LOOP HALF STAYS GRAMMAR-FREE AND IMPORT-FREE (D19 + D20) ───────

test("no level grammar leaked into the workflow file", () => {
  for (const needle of ["deriveLevel", "LEVEL-SKIP", "PATHLESS-REF", "INADMISSIBLE-CONTINUOUS"]) {
    assert.equal(SOURCE.includes(needle), false, `${needle} appears in the workflow — the level ladder belongs in tooling/grip/, not here (D20)`);
  }
});

test("the helper adds no import, require, eval, new Function, Date.now or new Date", () => {
  for (const re of [/\bimport\b/, /\brequire\s*\(/, /\beval\s*\(/, /new\s+Function/, /Date\.now/, /new\s+Date/, /Math\.random/]) {
    assert.equal(re.test(HELPER_SOURCE), false, `the in-loop helper uses ${re} — the host refuses it (D19)`);
  }
});

// ── 5. ONE INTERCEPTION, AT THE RESOLVE, UPSTREAM OF BOTH SERIALISATIONS ─────

test("the gate is called exactly twice — once per parallel() resolve, never per serialisation site", () => {
  const calls = [...SOURCE.matchAll(new RegExp(`(?<!function )\\b${HELPER}\\s*\\(`, "g"))];
  assert.equal(calls.length, 2, "expected exactly two call sites (surveys, verifications); patching each serialisation site separately is the copies-that-must-agree defect in miniature");
});

test("both survey serialisation sites are DOWNSTREAM of the single survey interception", () => {
  const gateAt = SOURCE.indexOf(`gateFactProvenance(surveys)`);
  assert.notEqual(gateAt, -1, "the survey interception is gone");

  const resolveAt = SOURCE.indexOf("const surveys");
  assert.ok(resolveAt !== -1 && resolveAt < gateAt, "the gate must sit after the resolve of `surveys`");

  // Site 1: the full serialisation into the Digest prompt.
  const digestSite = SOURCE.indexOf("JSON.stringify(surveys, null, 2)");
  assert.notEqual(digestSite, -1, "the Digest serialisation of surveys moved — relocate by pattern");
  assert.ok(digestSite > gateAt, "Digest serialises surveys BEFORE the gate runs");

  // Site 2: the projection into the Decide prompt.
  const decideSite = SOURCE.indexOf("JSON.stringify(surveys.map(");
  assert.notEqual(decideSite, -1, "the Decide projection of surveys moved — relocate by pattern");
  assert.ok(decideSite > gateAt, "Decide projects surveys BEFORE the gate runs");
});

// Being downstream of the gate is necessary but NOT sufficient: a projection
// that drops facts[] is downstream of the gate and still blind to every
// demotion it made. The Decide phase is where the next wave's slices get filed,
// so a Decide that cannot see which facts are unre-derivable files slices on
// sand — the wiring would be half-connected while reading as done.
test("the Decide projection actually CARRIES facts, so the demotion reaches the phase that files tasks", () => {
  const site = SOURCE.indexOf("JSON.stringify(surveys.map(");
  assert.notEqual(site, -1, "the Decide projection of surveys moved — relocate by pattern");
  const projection = SOURCE.slice(site, SOURCE.indexOf("\n", site));
  assert.match(
    projection,
    /facts:\s*s\.facts/,
    "the Decide projection must carry facts[] — without it every DEMOTED-NO-RERUN annotation the gate writes is invisible to Decide",
  );
  assert.doesNotMatch(
    projection,
    /relevant_files/,
    "relevant_files is not a SURVEY_SCHEMA property — it always projects undefined and reads as a carried field that is not carried",
  );
  // and the prompt must TELL Decide what the annotation means, or it is data
  // the model has no instruction to act on.
  assert.match(SOURCE, /DEMOTED-NO-RERUN has no command that re-derives it/);
});

test("the verify serialisation site is DOWNSTREAM of the single verify interception", () => {
  const gateAt = SOURCE.indexOf(`gateFactProvenance(verifications)`);
  assert.notEqual(gateAt, -1, "the verify interception is gone");
  const site = SOURCE.indexOf("JSON.stringify(verifications, null, 2)");
  assert.notEqual(site, -1, "the Decide serialisation of verifications moved — relocate by pattern");
  assert.ok(site > gateAt, "Decide serialises verifications BEFORE the gate runs");
});

// ── 6. THE SCOPE STATEMENT IS PART OF THE CONTRACT ───────────────────────────

test("the code says out loud that this gates the wave's fact flow, not every repo write", () => {
  assert.match(SOURCE, /NOT every write in\s*\n?\/\/ the repo|and NOT every write in the repo/);
  assert.match(SOURCE, /wave'?s? fact flow|WAVE'?S FACT FLOW/i);
});
