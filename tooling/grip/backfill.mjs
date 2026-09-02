// backfill.mjs — FILL THE LEDGER BY RE-EXECUTION (charter D58).
//
// The census is the MINTING INSTRUMENT. A corpus command becomes a durable
// ledger row ONLY by ANSWERING on re-execution today, so `observed_at` is true
// BY CONSTRUCTION — the command was just run, not stamped `now` on a weeks-old
// string. That distinction is the whole reason a plain backfill is forbidden:
// the corpus's proofs[] carry `run` as a workflow id (wf_009b2433-388), never a
// timestamp, so there is no honest `observed_at` to copy off a proof. Running
// the command mints one.
//
// ── WHY proofs[] ONLY, AND NOT evidence[] (charter D55) ──────────────────────
// The frozen fixture has two halves. The `evidence[]` half is 1,902 PROSE
// entries with NO `rerun`/`command` field — "100% of these strings are prose"
// (D55) — so it cannot be re-executed and is disqualified as a fact source ON
// THE MERITS, not by oversight. This slice does NOT reverse that: it reads
// `proofs[].command` ONLY. The proofs half is 652 entries each carrying a
// `.command`, which IS a rerun (D58 settles D55 precisely rather than
// overturning it — the disqualification was of the evidence half, and it
// stands).
//
// ── SAFETY, NON-NEGOTIABLE (charter D-crit 5 / D29 / D47) ────────────────────
// Execution is gated on `screenCommand` (via `censusOne`, whose gate is not
// injectable) and NEVER on `classifySafety`. `classifySafety` returns
// {safe:true} for `systemctl stop`, `mix ecto.drop` and `reboot` — it green-lit
// 26 of 31 outage probes — because a denylist of mutating APIs cannot be
// complete. `screenCommand` is an ALLOWLIST that fails closed on an unknown
// head, and it refuses all three. This module imports `classifySafety` nowhere;
// the gate is the allowlist and only the allowlist. See the SCREEN-REFUSED
// bucket below and test/backfill.test.mjs's "never reaches a spawn" proof.
//
// ── ALL-OR-NOTHING WITHOUT LOSING THE BATCH (charter D64) ────────────────────
// `writeLedgerRun` is all-or-nothing on purpose — a run file holding only the
// rows that happened to pass IS the silent-strip defect at file granularity.
// The raw corpus fed straight in produces 412/652 REFUSED-COMMAND and writes
// NOTHING. So this module PRE-SCREENS and RE-EXECUTES first, reports a per-row
// verdict for every command, and hands `writeLedgerRun` only the rows that
// already answered AND already passed `admitRecipe` individually — so the
// all-or-nothing write can never discard a batch it was going to keep.

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

import { censusOne, isAnswering, networkTool, CORPUS_PATH } from "./census.mjs";
import { mintRecipe } from "./mint.mjs";
import { screenCommand } from "./screen.mjs";
import {
  admitRecipe,
  writeLedgerRun,
  mintRunId,
  foldLedger,
  readLedgerRuns,
  DEFAULT_LEDGER_DIR,
} from "./ledger.mjs";

// Value-shaped keys a ledger row must never carry — admitRecipe rejects these
// at write time (VALUE-STORED), and the audit re-checks the raw bytes on disk
// because its claim is about the FILES, not about the writer's good intentions.
const VALUE_KEYS = ["value", "result", "output", "answer", "output_excerpt"];

// The per-command disposition. Every command lands in exactly one bucket, and
// every bucket is reported — a command that vanished silently would be the
// vacuous-green defect this epic exists to abolish.
export const DISPOSITION = Object.freeze({
  SCREEN_REFUSED: "SCREEN-REFUSED", // the safety screen refused it; never executed
  NOT_A_COMMAND: "NOT-A-COMMAND", // prose or a placeholder — a finding about the corpus
  TEST_RUNNER: "TEST-RUNNER", // go/mix/npm test — executes repo code the screen never examined
  DECAYED: "DECAYED", // ran, but the answer is gone (path-gone, failed, tool-error)
  NULL_READ: "NULL-READ", // ran but the census could not classify (silence/timeout/env fault)
  SPAWN_ERROR: "SPAWN-ERROR", // the shell could not run it / the network failed
  UNMINTABLE: "UNMINTABLE", // answered, but no subject/quantity could be minted
  REJECTED: "REJECTED", // answered and minted, but admitRecipe refused the row
  MINTED: "MINTED", // answered, minted, admitted — a durable row
});

/**
 * The corpus's proof commands, deduped and order-preserving.
 *
 * Reads `proofs[].command` ONLY. The `evidence[]` half is DELIBERATELY not
 * touched — see the D55 note at the top of this file. Returning the raw strings
 * (never mutated) keeps the re-execution faithful to what was actually stored.
 */
export function loadProofCommands(path = CORPUS_PATH) {
  const corpus = JSON.parse(readFileSync(path, "utf8"));
  const proofs = Array.isArray(corpus?.proofs) ? corpus.proofs : [];
  const seen = new Set();
  const out = [];
  for (const p of proofs) {
    const cmd = typeof p?.command === "string" ? p.command.trim() : "";
    if (cmd === "" || seen.has(cmd)) continue;
    seen.add(cmd);
    out.push(cmd);
  }
  return out;
}

/**
 * PRE-SCREEN one command with the safety screen — no execution.
 *
 * This is the cheap first pass that lets the run report refusals per row
 * instead of discovering them one all-or-nothing write later. The verdict key
 * is `.ok`, NEVER `.safe` (screenCommand has no `.safe`; reading it yields
 * undefined and scores the opposite of the truth — charter D64's pinned trap).
 */
export function prescreen(command) {
  const cmd = String(command ?? "").trim();
  const v = screenCommand(cmd);
  return { command: cmd, ok: v.ok === true, reason: v.reason };
}

/**
 * Re-execute one command through the census classifier and, if it ANSWERS,
 * mint and pre-admit a durable row.
 *
 * `exec` is injected only so a test can drive the outcome without spawning; it
 * is forwarded to `censusOne`, whose SCREEN GATE is not injectable — so no
 * caller, test or otherwise, can execute a screen-refused command. `now` and
 * `screen` are the admitRecipe bounds; a row is pre-admitted here (never batched
 * into the all-or-nothing write blind) so the write can only ever refuse a row
 * this function already refused.
 */
export function backfillOne(command, { now, exec, screen = screenCommand } = {}) {
  const cmd = String(command ?? "").trim();

  // (a) THE SCREEN, as a reported pre-pass. censusOne screens again as its own
  // non-injectable GATE — this pass exists so the refusal is a row in the
  // report, not a silent drop inside the executor.
  const screened = prescreen(cmd);
  if (!screened.ok) {
    return { command: cmd, disposition: DISPOSITION.SCREEN_REFUSED, why: screened.reason };
  }

  // (b) RE-EXECUTE through the census. Its gate re-screens (so a bug that let a
  // refused command past pre-screen still cannot spawn), it classifies prose and
  // test runners without running them, and it returns whether the outcome
  // ANSWERS. Nothing here inspects classifySafety.
  const row = censusOne(cmd, exec ? { exec } : {});

  if (!row.executed) {
    // Not executed for a reason the census already named: refused (belt-and-
    // braces with the pre-screen), prose, or a test runner.
    const disposition =
      row.outcome === "REFUSED" ? DISPOSITION.SCREEN_REFUSED
        : row.outcome === "NOT-A-COMMAND" ? DISPOSITION.NOT_A_COMMAND
          : DISPOSITION.TEST_RUNNER;
    return { command: cmd, disposition, why: row.why, outcome: row.outcome };
  }

  if (!isAnswering(row.outcome)) {
    // Ran, but the answer is not there today. A command that no longer answers
    // is NOT stored (D58) — its `observed_at` could only be a claim, never an
    // observation. Split so the report distinguishes true decay from a host
    // fault or an unclassifiable silence.
    const disposition = row.decayed ? DISPOSITION.DECAYED
      : row.outcome === "SPAWN-ERROR" ? DISPOSITION.SPAWN_ERROR
        : DISPOSITION.NULL_READ;
    return { command: cmd, disposition, why: row.why, outcome: row.outcome };
  }

  // (c) IT ANSWERED. Mint a recipe from the command (D32 path-token subject +
  // quantity phrase), then PRE-ADMIT it individually. observed_at is `now` — the
  // instant this command was just run — so the row records when the recipe last
  // ran, which is true by construction.
  const minted = mintRecipe({ rerun: cmd }, { observed_at: now });
  if (!minted.ok) {
    return { command: cmd, disposition: DISPOSITION.UNMINTABLE, why: minted.reason, outcome: row.outcome };
  }

  const verdict = admitRecipe(minted.recipe, { now, screen });
  if (!verdict.ok) {
    return {
      command: cmd,
      disposition: DISPOSITION.REJECTED,
      why: verdict.rejections.map((r) => r.reason).join(", "),
      outcome: row.outcome,
    };
  }

  return {
    command: cmd,
    disposition: DISPOSITION.MINTED,
    outcome: row.outcome,
    subject_source: minted.subject_source,
    network_tool: networkTool(cmd), // null unless the row reached a live service
    recipe: verdict.recipe,
  };
}

/**
 * Run the backfill over a list of commands and return the full disposition
 * report plus the admitted recipe set. Writes NOTHING — writing is `writeBackfill`.
 */
export function backfill(commands, { now, exec, screen = screenCommand } = {}) {
  const list = Array.isArray(commands) ? commands : [];
  const results = list.map((c) => backfillOne(c, { now, exec, screen }));

  const byDisposition = {};
  for (const d of Object.values(DISPOSITION)) byDisposition[d] = 0;
  for (const r of results) byDisposition[r.disposition] += 1;

  const minted = results.filter((r) => r.disposition === DISPOSITION.MINTED);
  const recipes = minted.map((r) => r.recipe);

  // The ±live-services band (charter D85): rows that reached a live service
  // (bp/gh/curl/…) answer about the network on THIS host at THIS time, not about
  // the checkout. A hermetic re-run floors below the full set by exactly this
  // many rows, so the band is reported, never hidden.
  const networkReaching = minted.filter((r) => r.network_tool !== null);
  const networkByTool = {};
  for (const r of networkReaching) networkByTool[r.network_tool] = (networkByTool[r.network_tool] || 0) + 1;

  return {
    results,
    recipes,
    counts: {
      total: list.length,
      ...byDisposition,
      network_reaching: networkReaching.length,
      hermetic_floor: recipes.length - networkReaching.length,
    },
    network_by_tool: networkByTool,
  };
}

/**
 * Write the minted recipes as ONE content-addressed, immutable run file.
 *
 * `run_id` is minted from the SAME `now` the rows were observed at, sanitised so
 * it is a legal filename (RUN_ID rejects the colons in a raw `date -u` stamp).
 * `screen` is forwarded so `writeLedgerRun` re-admits every row against the
 * safety screen at the write seam too — the last gate a forged row must cross.
 */
export function writeBackfill(recipes, { now, dir = DEFAULT_LEDGER_DIR, screen = screenCommand } = {}) {
  return writeLedgerRun({ run_id: mintRunId(now), recipes, dir, now, screen });
}

// ── the audit ────────────────────────────────────────────────────────────────

/**
 * Fold a ledger dir and report the numbers the acceptance audit needs: rows,
 * subjects, leads-indexed subjects (D45 excludes `cmd:<head>` dumping-ground
 * fallbacks from the read index), any stored `value` field (there must be
 * none), and unreadable rows (there must be none).
 */
export function auditLedger(dir = DEFAULT_LEDGER_DIR) {
  // Inject the SAME two read-path bounds the write path admits against
  // (`date -u` clock + screenCommand). Without them the audit's fold cannot fire
  // FUTURE-OBSERVED-AT or REFUSED-COMMAND, so a composed-future or outage-capable
  // row would fold clean here while writeLedgerRun refuses both (D66 read-path
  // residual). shellNow() is defined below; screenCommand is imported above.
  const folded = foldLedger(dir, { now: shellNow(), screen: screenCommand });
  const subjects = new Set();
  const leadsSubjects = new Set();
  for (const entry of folded.entries) {
    subjects.add(entry.subject);
    // D45: a `cmd:<head>` fallback subject is a dumping ground, excluded from
    // the read index. The audit counts it as a row/subject but reports the
    // leads-indexed subject count separately.
    if (!String(entry.subject).startsWith("cmd:")) leadsSubjects.add(entry.subject);
  }

  // Zero `value` fields ANYWHERE on disk — scanned over the RAW run files, not
  // the folded synthesis (the fold builds fresh recipe objects and would drop a
  // stray value key silently, hiding exactly what this audit exists to find).
  let valueFields = 0;
  for (const run of readLedgerRuns(dir).runs) {
    for (const recipe of run.recipes) {
      if (!recipe || typeof recipe !== "object") continue;
      for (const k of VALUE_KEYS) if (Object.hasOwn(recipe, k)) valueFields += 1;
    }
  }

  return {
    dir,
    rows: folded.stats.rows,
    subjects: subjects.size,
    leads_subjects: leadsSubjects.size,
    value_fields: valueFields,
    unreadable: folded.unreadable.length,
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

const CORPUS_NAME = "the frozen evidence corpus (tooling/grip/fixtures/evidence-corpus.json, proofs[].command)";

// UTC-only, Z-form, read from the SHELL and never from any input — the module
// owns no clock the same way ledger.mjs does not (D19/D31). This is the ONE
// `now` used for every row and for the run_id, so the file name and the rows
// agree by construction.
function shellNow() {
  return execFileSync("date", ["-u", "+%Y-%m-%dT%H:%M:%SZ"], { encoding: "utf8" }).trim();
}

const HELP = `backfill.mjs — fill the ledger by RE-EXECUTION (charter D58).

  node tooling/grip/backfill.mjs [--dir <ledger dir>] [--limit N] [--dry-run] [--json]

Reads tooling/grip/fixtures/evidence-corpus.json proofs[].command ONLY (the
evidence[] half is prose with no rerun — charter D55), pre-screens every
command, re-executes the admitted set through the census classifier, and mints
a durable row ONLY for a command that ANSWERS today. observed_at is true by
construction. Writes ONE immutable, content-addressed run file into the ledger.

  --dir      write into this ledger dir instead of tooling/grip/ledger/
  --limit N  re-execute only the first N distinct commands (for a bounded probe)
  --dry-run  do everything EXCEPT write the run file
  --json     machine render of the disposition report

Safety: every command is screened by screen.mjs before any spawn — never by
classifySafety, which green-lights systemctl stop / mix ecto.drop / reboot.`;

function renderReport(report, { corpusName, wrote, audit }) {
  const c = report.counts;
  const L = [];
  L.push(`BACKFILL — ${corpusName}`);
  L.push("");
  L.push(`  distinct commands   ${c.total}`);
  L.push(`  screen refused      ${c[DISPOSITION.SCREEN_REFUSED]}   never executed`);
  L.push(`  not a command       ${c[DISPOSITION.NOT_A_COMMAND]}   prose/placeholder — a finding about the corpus`);
  L.push(`  test runners        ${c[DISPOSITION.TEST_RUNNER]}   execute repo code the screen never examined — skipped`);
  L.push(`  decayed             ${c[DISPOSITION.DECAYED]}   ran, but the answer is gone — NOT stored (D58)`);
  L.push(`  null-read           ${c[DISPOSITION.NULL_READ]}   ran, unclassifiable silence — NOT stored`);
  L.push(`  spawn error         ${c[DISPOSITION.SPAWN_ERROR]}   shell/network fault — measures this host, NOT the ledger`);
  L.push(`  unmintable          ${c[DISPOSITION.UNMINTABLE]}   answered, but no subject/quantity minted`);
  L.push(`  rejected            ${c[DISPOSITION.REJECTED]}   answered and minted, but admitRecipe refused the row`);
  L.push(`  MINTED              ${c[DISPOSITION.MINTED]}   answered → durable rows (observed_at true by construction)`);
  L.push("");
  L.push(`  live-services band  ${c.network_reaching} of ${c[DISPOSITION.MINTED]} minted rows reach a live service ${JSON.stringify(report.network_by_tool)}`);
  L.push(`  hermetic floor      ${c.hermetic_floor}   rows a network-free re-run would still mint`);
  if (audit) {
    L.push("");
    L.push(`  LEDGER AFTER ${wrote ? "(written)" : "(dry-run — unchanged)"}`);
    L.push(`    rows              ${audit.rows}`);
    L.push(`    subjects          ${audit.subjects}`);
    L.push(`    leads-indexed     ${audit.leads_subjects}   (D45: cmd:<head> fallbacks excluded from the read index)`);
    L.push(`    value fields      ${audit.value_fields}   MUST be 0 — a ledger row stores a recipe, never a value`);
    L.push(`    unreadable        ${audit.unreadable}   MUST be 0`);
  }
  return L.join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(`${HELP}\n`);
    return 0;
  }
  const take = (name) => {
    const i = argv.indexOf(name);
    if (i < 0) return null;
    return argv[i + 1] ?? null;
  };
  const dirArg = take("--dir");
  const limitArg = take("--limit");
  const dryRun = argv.includes("--dry-run");
  const asJson = argv.includes("--json");

  let limit = Infinity;
  if (limitArg !== null) {
    limit = Number.parseInt(limitArg, 10);
    if (!Number.isInteger(limit) || limit < 1) {
      process.stderr.write(`backfill: --limit needs a positive integer, got ${JSON.stringify(limitArg)}\n`);
      return 2;
    }
  }

  const dir = dirArg ? resolve(dirArg) : DEFAULT_LEDGER_DIR;
  const now = shellNow();
  const all = loadProofCommands();
  const commands = Number.isFinite(limit) ? all.slice(0, limit) : all;

  process.stderr.write(`backfill: re-executing ${commands.length} distinct commands (now=${now}, read from \`date -u\`) …\n`);
  const report = backfill(commands, { now });

  let wrote = false;
  let writeResult = null;
  if (!dryRun && report.recipes.length > 0) {
    writeResult = writeBackfill(report.recipes, { now, dir });
    if (!writeResult.ok) {
      const byClass = new Map();
      for (const r of writeResult.rejections) byClass.set(r.reason, (byClass.get(r.reason) ?? 0) + 1);
      process.stderr.write("backfill: writeLedgerRun REFUSED — nothing written (all-or-nothing)\n");
      for (const [reason, count] of byClass) process.stderr.write(`  ${reason} x${count}\n`);
      return 1;
    }
    wrote = writeResult.written === true;
  }

  const audit = auditLedger(dir);

  if (asJson) {
    process.stdout.write(`${JSON.stringify({ now, dir, wrote, write: writeResult && { path: writeResult.path, written: writeResult.written, reason: writeResult.reason }, counts: report.counts, network_by_tool: report.network_by_tool, audit }, null, 2)}\n`);
  } else {
    process.stdout.write(`${renderReport(report, { corpusName: CORPUS_NAME, wrote, audit })}\n`);
    if (writeResult) process.stdout.write(`\n  ${wrote ? "wrote" : "already recorded"}  ${writeResult.path}\n`);
    else if (dryRun) process.stdout.write("\n  --dry-run: no run file written\n");
    else process.stdout.write("\n  nothing answered — no run file written\n");
  }
  return 0;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  // NO process.exit HERE (charter D92, the same ruling ledger.mjs's entry guard
  // already applies). process.exit() tears whatever stdout has not yet reached
  // the OS: Node writes a pipe ASYNCHRONOUSLY, so once a report outgrows the
  // kernel pipe buffer the bytes past it are simply dropped the instant a
  // caller adds `| jq`, while the same run redirected to a file is whole. A
  // truncated `--json` is not a loud failure — it is a JSON.parse error the
  // caller blames on this tool's format. Measured on darwin: an emitter whose
  // tail is `process.exit(code)` delivers exactly 65536 bytes of a 1 MiB
  // payload to a slow reader; the `process.exitCode` tail delivers all of it.
  // Setting exitCode leaves the exit STATUS identical and lets the event loop
  // drain first — main() opens no lingering handles, so the natural exit is
  // immediate. exit-race.test.mjs is the pin.
  main(process.argv.slice(2))
    .then((code) => { process.exitCode = code; })
    .catch((err) => {
      process.stderr.write(`backfill: crashed before any write — ${err?.stack ?? err?.message ?? String(err)}\n`);
      process.exitCode = 2;
    });
}
