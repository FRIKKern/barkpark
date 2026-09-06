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
import { readFileSync, readdirSync } from "node:fs";
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

// ── 7. THE VERIFY-WRITES / DECIDE-COMMITS SEAM (D27 / D35) ───────────────────
//
// These four changes are PROMPT TEXT, not executable code, so `node --check`
// can say nothing about them — it parses a template literal whether the clause
// inside it is present, absent, or reversed. Wave 2 already paid for that
// lesson: a fan-out floor whose only gate was `node --check` shipped a floor
// the check could not distinguish from a floor of zero. So the seam is pinned
// by reading the shipped source, the same way the wiring above is.

// The verifier prompt branches on q.needs_worktree, and the two branches must
// say DIFFERENT things — that asymmetry is the whole ruling, so parse them
// apart rather than grepping the file as one blob.
function verifyPromptBranches() {
  // 2026-09-06: anchor on the TERNARY, not on a fused prefix. This used to look
  // for the literal "never touch main${q.needs_worktree ?" — the two were
  // adjacent when this was written, and 2dfb6239b (2026-09-02, #15508, charter
  // D17 "the wave walks its own lifecycle graph") inserted the sanctioned
  // `bp task stage … researching` carve-out sentence between them. The ternary
  // and both of its branches are unchanged in substance; only the text in front
  // of it moved, so every assertion below stands as written.
  const at = SOURCE.indexOf("${q.needs_worktree ? '");
  assert.notEqual(at, -1, "the verifier prompt's needs_worktree ternary moved or was rewritten — relocate by pattern");
  const end = SOURCE.indexOf("}", at);
  assert.notEqual(end, -1, "the ternary never closes");
  const quoted = [...SOURCE.slice(at, end).matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((m) => m[1]);
  assert.equal(quoted.length, 2, "expected exactly two branch strings (worktree, shared checkout)");
  return { worktree: quoted[0], shared: quoted[1] };
}

test("the SHARED-CHECKOUT verifier branch carries the narrow ledger carve-out and never authorises a commit", () => {
  const { shared } = verifyPromptBranches();
  assert.match(shared, /tooling\/grip\/ledger\//, "the shared-checkout branch must name the ONE directory the carve-out opens");
  assert.match(shared, /carve-out/i);
  assert.match(shared, /never commit|commit nothing|You never commit/i, "a write permission with no commit prohibition is the stranding bug, not the fix");
  assert.match(shared, /Decide commits/i, "the branch must say WHO commits, or the verifier has no reason to believe the row survives");
});

test("the unqualified 'no repo edits' wording is gone — a blanket ban and a carve-out cannot both be live", () => {
  assert.equal(
    SOURCE.includes(" , no repo edits"),
    false,
    "the old unqualified ban is still in the verifier prompt: it contradicts the carve-out, and a model handed both instructions will obey the shorter one",
  );
});

test("the WORKTREE verifier branch explicitly DENIES the carve-out, with the reason", () => {
  const { worktree } = verifyPromptBranches();
  assert.match(worktree, /DENIED/, "the second stranding path stays silently lossy unless the denial is explicit");
  assert.match(worktree, /stranded/i);
  assert.match(worktree, /distinct filesystem path|Decide .*never sees|never sees/i, "the denial must state WHY, or it reads as arbitrary and gets reasoned around");
  assert.equal(worktree.includes("you may WRITE"), false, "the worktree branch must not also grant the write");
});

test("BOTH Digest sites tell the fleet that a ledger-writing assignment must not set needs_worktree", () => {
  const schemaAt = SOURCE.indexOf("needs_worktree: { type: 'boolean'");
  assert.notEqual(schemaAt, -1, "the needs_worktree schema property moved — relocate by pattern");
  const schemaLine = SOURCE.slice(schemaAt, SOURCE.indexOf("\n", schemaAt));

  const proseAt = SOURCE.indexOf("- needs_worktree: true only for probe edits");
  assert.notEqual(proseAt, -1, "the Digest prose guidance for needs_worktree moved — relocate by pattern");
  const proseLine = SOURCE.slice(proseAt, SOURCE.indexOf("\n", proseAt));

  // The schema description is what a structured-output model reads; the prose
  // is what it reasons over. One without the other is half-wired.
  for (const [where, text] of [["schema description", schemaLine], ["Digest prose", proseLine]]) {
    assert.match(text, /must NOT set it/, `${where} does not forbid needs_worktree for a ledger-writing assignment`);
    assert.match(text, /tooling\/grip\/ledger\//, `${where} does not name the ledger directory it is ruling about`);
  }
});

test("Decide is told to commit ledger rows BY EXPLICIT PATH, and to skip cleanly when there are none", () => {
  const at = SOURCE.indexOf("THE SAME PR CARRIES THIS RUN'S LEDGER ROWS");
  assert.notEqual(at, -1, "Decide's ledger-commit instruction is missing — Verify's rows would be written and never committed");
  const step = SOURCE.slice(at, SOURCE.indexOf("\n", at));
  assert.match(step, /git status --porcelain tooling\/grip\/ledger\//, "Decide must DISCOVER the rows, not guess at filenames it never saw");
  assert.match(step, /BY EXPLICIT PATH/, "staging by anything but explicit path sweeps other sessions' work in this shared checkout");
  assert.match(step, /never \\?`?git add -A/);
  assert.match(step, /skip the step silently/, "a run whose verifiers wrote nothing must not read as a failure");
});

test("'never git add -A' is restated at the ledger commit, not left to carry over from the charter commit", () => {
  const bans = [...SOURCE.matchAll(/never \\?`?git add -A/g)];
  assert.equal(
    bans.length,
    2,
    "expected the ban once at the charter commit and once at the ledger commit — a second staging instruction inheriting a ban stated two sentences earlier is how `git add -A` gets typed",
  );
});

// ── 8. THE STRANDED-FILE CASE IS RULED IN WRITING ────────────────────────────
//
// Verify writes and Decide commits ONE PHASE LATER, so there is a window where
// the rows are uncommitted. Silence about that window is the defect this
// asserts against: an accepted loss and an unnoticed loss look identical in the
// code, and only the comment tells them apart.

function strandedRuling() {
  const start = SOURCE.indexOf("// ── Phase 4: Verify");
  assert.notEqual(start, -1, "the Verify phase banner moved — relocate by pattern");
  const end = SOURCE.indexOf("phase('Verify')", start);
  assert.notEqual(end, -1, "the Verify phase call moved");
  const raw = SOURCE.slice(start, end).split("\n").filter((l) => l.trim().length > 0);
  for (const line of raw) {
    assert.match(line.trim(), /^\/\//, "the ruling must be a COMMENT — anything else here is code the host will run");
  }
  return raw.map((l) => l.trim().replace(/^\/\/\s?/, "")).join(" ").replace(/\s+/g, " ");
}

test("the ruling states the loss, accepts it, and refuses a sweep — with the reason", () => {
  const ruling = strandedRuling();
  assert.match(ruling, /STRANDED-FILE CASE IS RULED/, "the case is not named");
  assert.match(ruling, /LOST/, "the ruling must say plainly that rows can be lost");
  assert.match(ruling, /LOSS IS ACCEPTED/, "an unstated acceptance is indistinguishable from an oversight");
  assert.match(ruling, /No sweep is built/, "the ruling must record that no sweep exists, so nobody looks for one");
});

test("the ruling gives BOTH reasons: a sweep is more dangerous, and a recipe is cheap to re-derive", () => {
  const ruling = strandedRuling();
  assert.match(ruling, /OTHER LIVE SESSIONS SHARE/, "reason 1 — the danger is that this checkout is shared");
  assert.match(ruling, /RE-DERIVATION RECIPE, never a value/, "reason 2 — what is lost is a recipe, not a measurement");
  assert.match(ruling, /cheap|re-run/i, "reason 2 must say the loss is cheap to undo, which is why it is tolerable");
});

test("the ruling also names the SECOND stranding path and how it is closed", () => {
  const ruling = strandedRuling();
  assert.match(ruling, /second stranding path/i, "a ruling that covers one path while a second stays open reads complete and is not");
  assert.match(ruling, /DENYING the carve-out/, "the worktree path is closed by denial, not by recovery — the ruling must say so");
});

// ── 9. THE COPIES-THAT-MUST-AGREE CHECK (added in review) ────────────────────

test("the verifier prompt exists in exactly ONE workflow file — no second copy to drift", () => {
  // This epic exists because of copies that must agree and silently stop
  // agreeing. Section 7-8 pins the WORDS in this file; that proves nothing if
  // another workflow carries its own verifier prompt still granting the blanket
  // ", no repo edits" ban, or still granting the ledger carve-out to a
  // worktree verifier. Two prompts, one contract, no mechanism keeping them
  // level — the exact shape the charter's D20 refuses to create by import.
  //
  // Measured: bp-epic-cycle.workflow.js is the only file with the string, so
  // the seam is genuinely single-sourced today. This test is what makes that a
  // property rather than an observation someone made once.
  const dir = join(REPO, ".claude", "workflows");
  const files = readdirSync(dir).filter((f) => f.endsWith(".js"));
  const carriers = files.filter((f) => readFileSync(join(dir, f), "utf8").includes("You are a VERIFIER on a Barkpark epic wave"));
  assert.deepEqual(carriers, ["bp-epic-cycle.workflow.js"],
    `the verifier prompt must live in exactly one file; found it in: ${carriers.join(", ")}. If a second workflow legitimately needs one, the two must be reconciled by hand HERE — there is no import to share (D19).`);

  // And the retired blanket ban must be gone from every one of them, not just
  // reworded in this one.
  for (const f of files) {
    const src = readFileSync(join(dir, f), "utf8");
    assert.ok(!src.includes("' , no repo edits'"),
      `${f} still carries the pre-carve-out ", no repo edits" ban, which now contradicts the ledger seam`);
  }
});

test("the two verifier branches disagree on the carve-out, and BOTH say why", () => {
  // The asymmetry IS the ruling, so it is asserted as an asymmetry rather than
  // as two independent string matches: the worktree branch must DENY what the
  // shared-checkout branch GRANTS, and neither may be silent about the reason.
  const src = readFileSync(WORKFLOW, "utf8");
  const at = src.indexOf("${q.needs_worktree");
  assert.ok(at > 0, "the verifier prompt's branch point moved");
  const ternary = src.slice(at, src.indexOf("}`", at));
  // 2026-09-06: the positional word "below" is gone from the prompt (2dfb6239b,
  // #15508 reworded it to "…carve-out described in other runs is DENIED to
  // you"), so the anchor no longer pins WHERE the carve-out is described — it
  // still pins that the worktree branch names the carve-out AND denies it.
  assert.match(ternary, /carve-out[^']*is DENIED to you/, "the worktree branch must deny the carve-out explicitly");
  assert.match(ternary, /distinct filesystem path that Decide[^`]*never sees/, "the denial must carry its reason, or it reads as an arbitrary rule to route around");
  assert.match(ternary, /you may WRITE re-derivation recipe rows under tooling\/grip\/ledger\//, "the shared-checkout branch must grant the carve-out");
  assert.match(ternary, /You never commit them/, "the grant must state that Decide, not the verifier, commits");
  // No stray space before the clause — the prompt is read by an agent, and a
  // ragged "never touch main , and" reads as a truncation artifact.
  assert.ok(!/\s+,\s/.test(ternary.slice(0, 400)), "stray whitespace before a comma in the granted branch");
});
