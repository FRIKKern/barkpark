#!/usr/bin/env node
// Proof for the re-execution backfill — tooling/grip/backfill.mjs.
//
//   node --test tooling/grip/test/backfill.test.mjs
//
// The backfill is the census used as a MINTING INSTRUMENT (charter D58): a
// corpus command becomes a durable ledger row ONLY by ANSWERING on re-execution
// today. The obligations this suite is shaped around:
//
//   1. SAFETY (charter D-crit 5). Execution is gated on screenCommand, NEVER on
//      classifySafety. Proven as a control pair: a spy executor handed a
//      screen-refused command records ZERO calls (and classifySafety is shown
//      green-lighting the SAME command, so the gate choice is load-bearing),
//      then a benign admitted command records exactly one — without the second
//      half the first proves only that the spawn path is dead.
//
//   2. NO ROW WITHOUT AN ANSWER. A decayed / spawn-errored / refused command
//      mints nothing. observed_at on every minted row is the injected `now`, so
//      it is true by construction rather than stamped on a stale string.
//
//   3. ALL-OR-NOTHING WITHOUT LOSING THE BATCH (charter D64). A mixed batch
//      still writes the rows that answered and reports the rest per row.
//
//   4. THE STORE IS A RECIPE STORE. A written run file folds clean, carries zero
//      `value` fields on disk, and the audit's before/after counts are real.
//
// MOSTLY HERMETIC. The pipeline tests inject `exec` so no historical command is
// spawned; the CLI smoke test runs `--dry-run --limit` against the real corpus
// (a backfill that never re-executed would be proving nothing about a backfill).

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import {
  DISPOSITION,
  loadProofCommands,
  prescreen,
  backfillOne,
  backfill,
  writeBackfill,
  auditLedger,
} from "../backfill.mjs";
import { screenCommand } from "../screen.mjs";
import { classifySafety } from "../rerun.mjs";
import { foldLedger } from "../ledger.mjs";

const BACKFILL_MJS = fileURLToPath(new URL("../backfill.mjs", import.meta.url));
const CORPUS_PATH = fileURLToPath(new URL("../fixtures/evidence-corpus.json", import.meta.url));
const SOURCE = readFileSync(BACKFILL_MJS, "utf8");

const NOW = "2026-07-21T15:00:00Z";

// A run record in the shape censusOne's injected `exec` returns.
const run = (exit, stdout = "", stderr = "") => ({ exit, stdout, stderr, ms: 3, timedOut: false, spawnError: null });

// A benign command that ANSWERS: wc over a file that exists.
const ANSWERS_WC = "wc -l tooling/grip/backfill.mjs";
// A command the screen REFUSES and classifySafety green-lights.
const DANGER = "systemctl stop bp-crux-parent";

function tmpLedger() {
  return mkdtempSync(join(tmpdir(), "grip-backfill-"));
}

// ── 1. proofs[] ONLY, evidence[] disqualified (charter D55) ───────────────────

test("loadProofCommands reads proofs[].command ONLY, deduped — the evidence[] half is never touched", () => {
  const cmds = loadProofCommands();
  const corpus = JSON.parse(readFileSync(CORPUS_PATH, "utf8"));

  // Every returned string is a proof command; none is invented.
  const proofCommands = new Set(corpus.proofs.map((p) => (typeof p.command === "string" ? p.command.trim() : "")).filter(Boolean));
  for (const c of cmds) assert.ok(proofCommands.has(c), `${JSON.stringify(c)} is not a proofs[].command`);

  // Deduped: the count is the DISTINCT proof-command count, not the raw 652.
  assert.equal(cmds.length, proofCommands.size);
  assert.ok(cmds.length < corpus.proofs.length, "the raw corpus has duplicate commands — the loader must dedupe");

  // The evidence[] half is prose with NO command field, and none of it leaks in.
  assert.ok(corpus.evidence.length > 1000, "precondition: the corpus carries the large prose evidence[] half");
  const evidenceHasNoCommand = corpus.evidence.every((e) => e == null || typeof e !== "object" || !("command" in e));
  assert.ok(evidenceHasNoCommand, "precondition (D55): evidence[] entries carry no command field");

  // The code says WHY, so the disqualification is not silently reversible.
  assert.match(SOURCE, /D55/);
  assert.match(SOURCE, /proofs\[\]\s*ONLY|proofs\[\]\.command\s*ONLY/i);
});

// ── 2. SAFETY: gated on screenCommand, NEVER classifySafety ───────────────────

test("SAFETY: a screen-refused command NEVER reaches a spawn — and classifySafety would have run it", () => {
  // The gate's choice is the whole point: classifySafety green-lights the very
  // command screenCommand refuses. If the backfill gated on classifySafety this
  // command would execute.
  assert.equal(screenCommand(DANGER).ok, false, "precondition: the screen refuses this outage command");
  assert.equal(classifySafety(DANGER).safe, true, "precondition: classifySafety green-lights it — the denylist hole D29 names");

  let calls = 0;
  const spy = (cmd, opts) => { calls += 1; return run(0, "ran\n"); };

  const refused = backfillOne(DANGER, { now: NOW, exec: spy });
  assert.equal(calls, 0, "the spy executor must never be called for a refused command");
  assert.equal(refused.disposition, DISPOSITION.SCREEN_REFUSED);
  assert.ok(!("recipe" in refused), "a refused command produces no row");

  // The control's other half: a benign admitted command DOES reach the spy once,
  // or the zero above only proves the spawn path is dead.
  const admitted = backfillOne(ANSWERS_WC, { now: NOW, exec: spy });
  assert.equal(calls, 1, "the admitted command must reach the spy exactly once");
  assert.equal(admitted.disposition, DISPOSITION.MINTED);

  // And the module imports classifySafety NOWHERE and CALLS it nowhere — the
  // gate is the allowlist. classifySafety may be NAMED (the header and --help
  // explain why it is refused), but it is never imported and never invoked.
  assert.ok(!/from\s+["']\.\/rerun\.mjs["']/.test(SOURCE), "backfill.mjs must not import from rerun.mjs");
  assert.ok(!/classifySafety\s*\(/.test(SOURCE), "classifySafety is never CALLED — the gate is screenCommand");
});

// ── 3. NO ROW WITHOUT AN ANSWER ───────────────────────────────────────────────

test("a command that does NOT answer today produces NO row (decayed, spawn-error and refused all mint nothing)", () => {
  // Decayed: the path the recipe reads is gone → PATH-GONE, which IS decay.
  const decayed = backfillOne("cat tooling/grip/gone.mjs", { now: NOW, exec: () => run(1, "", "cat: tooling/grip/gone.mjs: No such file or directory") });
  assert.equal(decayed.disposition, DISPOSITION.DECAYED);
  assert.ok(!("recipe" in decayed));

  // A MISSING BINARY IS NOT DECAY, AND IS STILL NOT A ROW. rc 127 says the tool
  // is absent from THIS host, so census.mjs scores it TOOL-ABSENT — outside the
  // decayed set — and backfill files it as a null read. Both halves matter: it
  // must NOT be counted as decay, and it must STILL mint nothing, because a
  // command that did not run cannot carry an observed_at either.
  const toolGone = backfillOne("wc -l tooling/grip/backfill.mjs", { now: NOW, exec: () => run(127, "", "sh: wc: not found") });
  assert.equal(toolGone.outcome, "TOOL-ABSENT");
  assert.notEqual(toolGone.disposition, DISPOSITION.DECAYED, "a lean PATH must not be published as recipe rot");
  assert.equal(toolGone.disposition, DISPOSITION.NULL_READ);
  assert.ok(!("recipe" in toolGone));

  // Spawn error: the shell could not run it.
  const spawnErr = backfillOne("wc -l tooling/grip/backfill.mjs", {
    now: NOW,
    exec: () => ({ exit: null, stdout: "", stderr: "", ms: 0, timedOut: false, spawnError: "ENOENT" }),
  });
  assert.equal(spawnErr.disposition, DISPOSITION.SPAWN_ERROR);
  assert.ok(!("recipe" in spawnErr));

  // And an ANSWERING command DOES mint — otherwise "no row" is trivially true.
  const answered = backfillOne("wc -l tooling/grip/backfill.mjs", { now: NOW, exec: () => run(0, "  10 x\n") });
  assert.equal(answered.disposition, DISPOSITION.MINTED);
  assert.ok(answered.recipe, "an answering command must mint a row");
});

test("every minted row's observed_at is the injected `now` — true by construction, never a stale stamp", () => {
  const rep = backfill(
    ["wc -l tooling/grip/backfill.mjs", "grep -c test tooling/grip/backfill.mjs"],
    { now: NOW, exec: () => run(0, "3\n") },
  );
  assert.ok(rep.recipes.length >= 1);
  for (const r of rep.recipes) assert.equal(r.observed_at, NOW, "observed_at must be the run's own now");
});

// ── 4. ALL-OR-NOTHING WITHOUT LOSING THE BATCH ────────────────────────────────

test("a mixed batch keeps the answering rows and reports the rest — the raw corpus's 412 refusals do not zero the write", () => {
  const exec = (cmd) => {
    if (/^cat /.test(cmd)) return run(1, "", "cat: gone: No such file or directory"); // PATH-GONE → DECAYED
    return run(0, "  7 x\n"); // wc answers
  };
  const rep = backfill(
    [ANSWERS_WC, DANGER, "cat gone", "grep -c x tooling/grip/backfill.mjs"],
    { now: NOW, exec },
  );

  assert.equal(rep.counts[DISPOSITION.MINTED], 2, "the two answering commands mint");
  assert.equal(rep.counts[DISPOSITION.SCREEN_REFUSED], 1);
  assert.equal(rep.counts[DISPOSITION.DECAYED], 1);
  assert.equal(rep.recipes.length, 2, "the batch is not discarded because some rows were refused/decayed");

  // The write of exactly those pre-admitted rows succeeds — all-or-nothing sees
  // nothing to reject because the backfill already filtered.
  const dir = tmpLedger();
  const w = writeBackfill(rep.recipes, { now: NOW, dir });
  assert.equal(w.ok, true, JSON.stringify(w.rejections));
  assert.equal(w.written, true);
  assert.equal(foldLedger(dir).stats.rows, 2);
});

// ── 5. THE STORE IS A RECIPE STORE ────────────────────────────────────────────

test("writeBackfill writes ONE content-addressed file that folds clean with zero value fields and zero unreadable", () => {
  const dir = tmpLedger();
  const before = auditLedger(dir);
  assert.equal(before.rows, 0, "precondition: empty ledger");

  const exec = (cmd) => (/curl/.test(cmd) ? run(0, "{\"ok\":true}\n") : run(0, "  42 x\n"));
  const rep = backfill(
    ["wc -l tooling/grip/backfill.mjs", "grep -c screenCommand tooling/grip/census.mjs", "curl -s http://localhost:4000/health"],
    { now: NOW, exec },
  );
  const w = writeBackfill(rep.recipes, { now: NOW, dir });
  assert.equal(w.ok, true, JSON.stringify(w.rejections));

  // Exactly one run file.
  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  assert.equal(files.length, 1, `expected one run file, got ${files.join(", ")}`);
  assert.match(files[0], /^grip-\d{8}T\d{6}Z-[0-9a-f]+\.json$/, "content-addressed <run_id>-<key>.json");

  const after = auditLedger(dir);
  assert.equal(after.rows, rep.recipes.length);
  assert.equal(after.value_fields, 0, "a ledger row stores a recipe, never a value");
  assert.equal(after.unreadable, 0);
  assert.ok(after.subjects >= 1 && after.subjects <= after.rows);
  // D45: cmd:curl is a fallback subject, excluded from the leads index but
  // counted as a subject.
  assert.ok(after.leads_subjects <= after.subjects);
  assert.ok(after.subjects > after.leads_subjects, "the curl row minted a cmd: fallback subject the leads index drops");

  // On-disk value scan is real: plant a value field and the audit sees it.
  const rotten = { run_id: "grip-20260721T000000Z", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l x", derived_level: "L3", deps: [], observed_at: "2026-07-21T00:00:00Z", value: 42 }] };
  writeFileSync(join(dir, "grip-20260721T000000Z-plant.json"), JSON.stringify(rotten));
  assert.equal(auditLedger(dir).value_fields, 1, "the audit scans RAW bytes — a planted value field is caught");
});

// ── 6. THE LIVE-SERVICES BAND (charter D85) ───────────────────────────────────

test("network-reaching rows are counted as the ±live-services band, and the hermetic floor excludes them", () => {
  const exec = () => run(0, "answered\n");
  const rep = backfill(
    ["wc -l tooling/grip/backfill.mjs", "curl -s http://localhost:4000/health", "bp task ready"],
    { now: NOW, exec },
  );
  // wc is hermetic; curl and bp reach a live service.
  assert.equal(rep.counts[DISPOSITION.MINTED], 3);
  assert.equal(rep.counts.network_reaching, 2, "curl and bp reach a live service");
  assert.equal(rep.counts.hermetic_floor, 1, "only wc would answer with the network off");
  assert.deepEqual(rep.network_by_tool, { curl: 1, bp: 1 });
});

// ── 7. prescreen is a pure, execution-free report ─────────────────────────────

test("prescreen reports .ok per command and never executes — the refusal is a row in the report, not a silent drop", () => {
  assert.equal(prescreen(ANSWERS_WC).ok, true);
  const refused = prescreen(DANGER);
  assert.equal(refused.ok, false);
  assert.ok(refused.reason && refused.reason.length > 0, "a refusal carries the screen's own reason, not a shrug");
});

// ── 8. CLI smoke: bounded, real, writes nothing under --dry-run ───────────────

test("the CLI runs a bounded real backfill under --dry-run, names the corpus, and writes nothing", () => {
  const dir = tmpLedger();
  const r = spawnSync(process.execPath, [BACKFILL_MJS, "--dry-run", "--limit", "6", "--dir", dir], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /BACKFILL —/);
  assert.match(r.stdout, /proofs\[\]\.command/, "the render must NAME its corpus");
  assert.match(r.stdout, /dry-run: no run file written/);
  assert.equal(readdirSync(dir).filter((f) => f.endsWith(".json")).length, 0, "--dry-run must write nothing");
});

test("--limit rejects a non-positive value rather than silently running the whole corpus", () => {
  const r = spawnSync(process.execPath, [BACKFILL_MJS, "--limit", "0", "--dry-run"], { encoding: "utf8" });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--limit needs a positive integer/);
});
