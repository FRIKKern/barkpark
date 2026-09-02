// adjudicate.mjs — THE ADAPTER. It maps and it composes; it re-decides nothing.
//
// PDS-D386: BUILD BY ADOPTING. tooling/grip already carries the fact record
// {subject, quantity, claim, evidence, rerun, level, observed_at, deps[]}, and
// the PDS ledger row is that record wearing other field names:
//
//     disposition_reason  IS grip's  evidence   (L6 BY CONSTRUCTION — grip built
//                                                a prose scanner first and
//                                                refuted it at precision 0.67)
//     disposition_rerun   IS grip's  rerun
//
// So the mapping is the adapter, and everything downstream is grip's shipped
// engine: admitFact, deriveLevel, screenCommand, runRerun's family dispatch,
// admitsAbsenceClaim, adjudicateAll, detectConflicts.
//
// HARD FENCE: every grip import below is READ-ONLY. Zero bytes under
// tooling/grip/** are changed by this slice. That tree belongs to the truth-grip
// epic, which is not sealed, whose seal predicate exits rc=2 INFRA-FAULT, and
// three of whose tests are red at HEAD for reasons PDS does not own. Nothing
// here is coupled to grip's suite or its seal.
//
// NO EXIT CODE IS EVER READ. grip's engine modules never terminate the process —
// only its command-line entry point does — so this module imports the ENGINE and
// reads the structured ruling. Shelling out to grip's CLI and scoring its rc would commit
// this epic's own violation ("no verb may report success on an exit code
// alone") one level up, inside the instrument built to enforce it.
//
// SUBJECT IS `pds/<doc_id>` VERBATIM. detectConflicts keys on (subject,
// quantity); any coarser subject manufactures spurious CONFLICT verdicts
// between unrelated rows. Measured with the doc_id: 0 conflicts across 172.
// ONE RECIPE PER ROW, for the same reason — two recipes sharing a subject and a
// null quantity are two rival claims on one key, and grip would correctly flag
// both as CONFLICT.

import { adjudicateAll, VERDICTS } from "../grip/adjudicate.mjs";
import { admitsPassClaim, admitsAbsenceClaim, SYNC_TIMEOUT_MS } from "../grip/rerun.mjs";
import { deriveLevel } from "../grip/level.mjs";
import { forbiddenSpelling } from "./spellings.mjs";
import { varianceSet, overClaim, isUnknownVariance, CLAIM_CLASS } from "./variance.mjs";
import { bindClaim } from "./binding.mjs";
import { hasReason } from "./corpus.mjs";

// ── THE PDS VERDICT VOCABULARY ───────────────────────────────────────────────
//
// SEVEN NAMES, AND NOT ONE OF THEM MEANS "TRUE". RE-DERIVED is the strongest
// thing this instrument can say and it means exactly: the claim is bound to the
// command, the command's exit code moves on the axis the claim asserts, and the
// command reproduced that claim at HEAD just now. Whether the author ever ran
// it, and whether the surrounding prose is honest, are outside jurisdiction.
export const PDS_VERDICT = Object.freeze({
  RE_DERIVED: "RE-DERIVED",
  REFUTED: "REFUTED",
  REFUSED: "REFUSED",
  INCONCLUSIVE: "INCONCLUSIVE",
  DEMOTED_UNKNOWN: "DEMOTED-UNKNOWN",
  PROSE_ONLY: "PROSE-ONLY",
  MALFORMED: "MALFORMED",
});

// ── THE EXECUTION BUDGET ─────────────────────────────────────────────────────
//
// A RUN THAT TIMES OUT MUST NOT BE INDISTINGUISHABLE FROM A RUN THAT PASSED.
// Measured on this host 2026-07-31: a remote-ref git read costs 25-60 ms, a
// `go vet` on a warm cache 105-300 ms, and grip's own sync ceiling for anything
// that runs a program is SYNC_TIMEOUT_MS (2000 ms) — one `mix test`-shaped
// rerun therefore burns a quarter of grip's 8000 ms census ceiling on its own.
// 213 rows all executing an L2 `git show` was measured at 4886 ms under wave
// load, so the headroom here is real but thin.
//
// The estimate is deliberately a CEILING per family, so the pre-flight refusal
// fires BEFORE anything runs rather than truncating a run halfway and reporting
// the part that finished.
export const COST_MS = Object.freeze({
  GIT_READ: 120,   // remote-ref git read, measured 25-60ms, doubled for load
  TOOLCHAIN: 2000, // anything that runs a program — grip's own sync ceiling
  REFUSED: 0,      // refused before execution: nothing runs, nothing is spent
});

export function estimateMs(recipes = []) {
  let total = 0;
  for (const r of recipes) {
    if (forbiddenSpelling(r.command)) continue; // refused before execution
    const v = varianceSet(r.command);
    total += v.axes.includes("BEHAVIOUR") ? COST_MS.TOOLCHAIN : COST_MS.GIT_READ;
  }
  return total;
}

/** The grip fact this ledger row IS. `rerun` comes from the recipe, if any. */
export function toFact(row, recipe = null) {
  return {
    subject: `pds/${row.doc_id}`,
    quantity: null,
    claim: row.title,
    // Prose. Never parsed, never levelled, never able to raise anything.
    evidence: row.disposition_reason || (row.disposition_reason_sha256
      ? `sha256:${row.disposition_reason_sha256} (${row.disposition_reason_bytes} bytes of prose, not stored — grip never parses evidence)`
      : ""),
    rerun: recipe?.command ?? "",
    observed_at: row._createdAt || undefined,
    deps: [],
  };
}

// Screen a recipe BEFORE grip executes anything. Returns a refusal or null.
function preScreen(recipe) {
  const forbidden = forbiddenSpelling(recipe.command);
  if (forbidden) return { reason: forbidden.name, message: forbidden.message };

  const bound = bindClaim(recipe);
  if (!bound.ok) return { reason: bound.rejections[0].reason, message: bound.rejections.map((r) => r.message).join(" | ") };

  const variance = varianceSet(recipe.command);
  const over = overClaim(recipe.claim_class, variance);
  if (over) return { reason: over.reason, message: over.message };

  return null;
}

/**
 * Rule on one EXECUTED recipe from grip's structured ruling. Never from an rc.
 *
 * ABSENCE IS FIRST-CLASS (PDS-D389). Four of the five FAILED verdicts in the
 * real sample were TRUE reasons whose claim IS an absence — a `git grep` that
 * exits 1 because the token really is gone. Keying on `verdict === ADMITTED`
 * calls all four of them false. So the discriminator is grip's own shipped
 * `admitsAbsenceClaim` (rerun.mjs:842), which already knows that a DIFFER's rc1
 * means "these differ" and not "it is absent", and that an UNAVAILABLE probe
 * says nothing in either direction.
 */
function ruleExecuted(recipe, ruling) {
  const result = ruling.rerun;
  const absent = recipe.claim_class === CLAIM_CLASS.ABSENCE;

  if (ruling.verdict === VERDICTS.REJECTED) {
    return { verdict: PDS_VERDICT.REFUSED, reason: ruling.label, note: ruling.note };
  }

  const pass = admitsPassClaim(result);
  const absence = admitsAbsenceClaim(result);

  if (absent) {
    if (absence) {
      return { verdict: PDS_VERDICT.RE_DERIVED, reason: "ABSENCE-ADMITTED", note: `the absence re-derives at HEAD via grip's admitsAbsenceClaim (${result.family ?? "no family"}, exit ${result.exit}): ${result.reason}` };
    }
    if (pass) {
      return { verdict: PDS_VERDICT.REFUTED, reason: "ABSENCE-CONTRADICTED", note: `the reason claims an absence and the command FOUND the thing (exit ${result.exit}): ${result.reason}` };
    }
    return { verdict: PDS_VERDICT.INCONCLUSIVE, reason: ruling.verdict, note: `${ruling.verdict} — says nothing either way: ${result?.reason ?? ruling.note}` };
  }

  if (pass) {
    return { verdict: PDS_VERDICT.RE_DERIVED, reason: "PASS-ADMITTED", note: `re-derived just now at HEAD (${result.ms}ms, ${result.family ?? "no family"}): ${result.reason}` };
  }
  if (absence || ruling.verdict === VERDICTS.FAILED) {
    return { verdict: PDS_VERDICT.REFUTED, reason: "PASS-CONTRADICTED", note: `the command ran and REFUTES the claim (exit ${result.exit}): ${result.reason}` };
  }
  return { verdict: PDS_VERDICT.INCONCLUSIVE, reason: ruling.verdict, note: `${ruling.verdict} — says nothing either way: ${result?.reason ?? ruling.note}` };
}

/**
 * adjudicateCorpus(rows, recipes, opts) → report
 *
 * opts:
 *   budgetMs  refuse to START when the estimate exceeds it (default 8000, grip's
 *             CENSUS_TIMEOUT_MS). Never truncates.
 *   run       injectable runner, handed straight to grip. Omitted in a live run
 *             so grip's DEFAULT screened wire decides what may execute.
 *   root, timeoutMs  passed through to grip.
 */
export function adjudicateCorpus(rows, recipes = [], opts = {}) {
  const { budgetMs = 8000, run, root, timeoutMs = SYNC_TIMEOUT_MS } = opts;

  // ONE RECIPE PER ROW. A duplicate is a REFUSAL, not a last-write-wins merge:
  // two recipes on one (subject, quantity) are two rival claims on one conflict
  // key, and silently keeping the last one is how a wrong value replaces a
  // right one.
  const byRow = new Map();
  const duplicates = [];
  for (const r of recipes) {
    if (byRow.has(r.doc_id)) duplicates.push(r.doc_id);
    else byRow.set(r.doc_id, r);
  }

  const known = new Set(rows.map((r) => r.doc_id));
  const orphanRecipes = [...byRow.keys()].filter((id) => !known.has(id));

  // ── PRE-FLIGHT ────────────────────────────────────────────────────────────
  const refusals = new Map();
  const executable = [];
  for (const [docId, recipe] of byRow) {
    if (!known.has(docId)) continue;
    const refusal = preScreen(recipe);
    if (refusal) refusals.set(docId, refusal);
    else executable.push(recipe);
  }

  const estimate = estimateMs(executable);
  if (estimate > budgetMs) {
    return {
      status: "REFUSED-TO-START",
      budgetMs,
      estimateMs: estimate,
      elapsedMs: 0,
      message:
        `EXECUTION BUDGET: ${executable.length} executable recipe(s) estimate ${estimate}ms against a budget of ${budgetMs}ms. ` +
        "Refusing to START rather than truncating — a run that times out halfway must never be reportable as a run that passed. " +
        "Raise --budget-ms deliberately, or cut the recipe set.",
      rows: [],
      counts: {},
      conflicts: [],
      duplicates,
      orphanRecipes,
    };
  }

  // ── ADMISSION OVER THE WHOLE BOARD (no execution) ─────────────────────────
  // Every live adjudicated row goes through grip's admitFact, including the
  // 167 that carry no rerun at all: a prose-only reason is DEMOTED to L6, never
  // rejected (truth-grip D3), and it must appear in the output BY NAME.
  const facts = rows.map((row) => toFact(row, byRow.get(row.doc_id) ?? null));
  const admission = adjudicateAll(facts, { execute: false });

  // ── EXECUTION, ONE RECIPE AT A TIME, INSIDE THE BUDGET ────────────────────
  // PDS-BLIND-SPOT-METER: `Date.now()`, WALL CLOCK inside this Node process,
  // around the recipe-execution loop. Placement is (a) of PDS-D633's law — an
  // OS-level clock OUTSIDE every BEAM — and it is the only placement available,
  // since the reruns are child processes this module shells out to. THE UNIT IS
  // NOT A PRICE AND MUST NEVER BE QUOTED AS ONE: this is a BUDGET ODOMETER whose
  // whole job is to decide when to stop spending, so it charges each child's
  // WAITING as well as its work, and PDS-D605 forbids a wall-clock second
  // standing in for CPU (wall swung 2.5x on an unchanged census where user CPU
  // moved 9%). A CPU price for a rerun comes from an OS meter around a SHELL
  // (`pds-door-census.sh --measure`); a regression ratchet would take
  // `Process.info(pid, :reductions)`, which has no Node equivalent at all.
  //
  // PDS-BLIND-SPOT-EMITTER: tooling/pds/verdict.mjs
  // This module computes the figure; verdict.mjs is the only thing that PRINTS
  // it, and that is where the sentence rides. Declared here so the check can
  // follow the figure to its own output path rather than demanding the sentence
  // in a module that prints nothing.
  const started = Date.now();
  const executed = new Map();
  let overspent = null;
  for (const recipe of executable) {
    const elapsed = Date.now() - started;
    if (elapsed > budgetMs) {
      overspent = { at: recipe.doc_id, elapsed };
      break;
    }
    const [ruling] = adjudicateAll([toFact(rows.find((r) => r.doc_id === recipe.doc_id), recipe)], {
      execute: true,
      ...(run ? { run } : {}),
      root,
      timeoutMs,
    }).rulings;
    executed.set(recipe.doc_id, ruling);
  }
  const elapsedMs = Date.now() - started;

  // ── COMPOSE ───────────────────────────────────────────────────────────────
  const out = [];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const admissionRuling = admission.rulings[i];
    const recipe = byRow.get(row.doc_id) ?? null;
    const level = recipe ? deriveLevel(recipe.command) : "L6";

    if (admissionRuling.verdict === VERDICTS.REJECTED) {
      out.push({
        doc_id: row.doc_id, level: null, claim_class: recipe?.claim_class ?? null,
        verdict: PDS_VERDICT.MALFORMED, reason: admissionRuling.label,
        note: admissionRuling.note, command: recipe?.command ?? "",
      });
      continue;
    }
    if (admissionRuling.verdict === VERDICTS.CONFLICT) {
      out.push({
        doc_id: row.doc_id, level, claim_class: recipe?.claim_class ?? null,
        verdict: PDS_VERDICT.MALFORMED, reason: "CONFLICT",
        note: admissionRuling.note, command: recipe?.command ?? "",
      });
      continue;
    }
    if (!recipe) {
      out.push({
        doc_id: row.doc_id, level: "L6", claim_class: null,
        verdict: PDS_VERDICT.PROSE_ONLY,
        reason: hasReason(row) ? "NO-RERUN" : "NO-REASON",
        note: hasReason(row)
          ? "the reason is prose with no rerun command, so nothing about it can be re-derived — L6, asserted by nobody"
          : "the row carries a disposition and NO reason at all",
        command: "",
      });
      continue;
    }
    const refusal = refusals.get(row.doc_id);
    if (refusal) {
      out.push({ doc_id: row.doc_id, level, claim_class: recipe.claim_class, verdict: PDS_VERDICT.REFUSED, reason: refusal.reason, note: refusal.message, command: recipe.command });
      continue;
    }
    const ruling = executed.get(row.doc_id);
    if (!ruling) {
      out.push({ doc_id: row.doc_id, level, claim_class: recipe.claim_class, verdict: PDS_VERDICT.INCONCLUSIVE, reason: "BUDGET-EXHAUSTED", note: `the execution budget of ${budgetMs}ms ran out before this recipe ran — it is NOT a pass and NOT a failure`, command: recipe.command });
      continue;
    }
    const variance = varianceSet(recipe.command);
    if (isUnknownVariance(variance)) {
      const ruled = ruleExecuted(recipe, ruling);
      out.push({
        doc_id: row.doc_id, level: "L6", claim_class: recipe.claim_class,
        verdict: PDS_VERDICT.DEMOTED_UNKNOWN, reason: "UNKNOWN-VARIANCE",
        note: `${variance.why} — DEMOTED to L6, never rejected (truth-grip D3). The command still ran and returned ${ruled.verdict}, which is recorded and NOT counted as re-derived.`,
        command: recipe.command,
      });
      continue;
    }
    const ruled = ruleExecuted(recipe, ruling);
    out.push({ doc_id: row.doc_id, level, claim_class: recipe.claim_class, ...ruled, command: recipe.command });
  }

  const counts = {};
  for (const r of out) counts[r.verdict] = (counts[r.verdict] ?? 0) + 1;

  return {
    status: overspent ? "INCOMPLETE" : "COMPLETE",
    budgetMs,
    estimateMs: estimate,
    elapsedMs,
    overspent,
    message: overspent
      ? `EXECUTION BUDGET EXHAUSTED after ${overspent.elapsed}ms at ${overspent.at} — this run is INCOMPLETE and must not be read as a pass.`
      : "",
    rows: out,
    counts,
    conflicts: admission.conflicts.map((c) => c.fact?.subject ?? "(unnamed)"),
    duplicates,
    orphanRecipes,
  };
}
