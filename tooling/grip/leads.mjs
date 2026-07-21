#!/usr/bin/env node
// leads.mjs — the READ half of the grip layer: a case-insensitive substring
// lookup that hands back RECIPES, never answers.
//
//   node tooling/grip/ledger.mjs leads <substring> [--json] [--census <report.json>] [--dir <ledger dir>]
//
// THE ANTI-GOAL IS STRUCTURAL, NOT A PROMISE (charter D66). This module cannot
// hand back a value even from a forged store, and the reason is not discipline:
// `RECIPE_FIELDS` carries no `value` key, and `foldLedger`'s projection rebuilds
// every recipe from SIX NAMED FIELDS (rerun, derived_level, deps, observed_at,
// run_id, file), so an unknown key is dropped before it ever reaches
// `entries[]`. `selectLeads` is a FILTER over `entries[]` — it adds no field and
// reads no file. A `value` hand-edited into a run file on disk therefore cannot
// reach this screen, and the test proves that by forging one.
//
// ── SHIPPED REDUCED, AND EACH CUT IS CARRIED BY A NUMBER (charter D43) ───────
//
//   NO staleness band. Every row at ship is minted this wave, so the band is a
//   CONSTANT COLUMN on day one; and 0 of the 652 corpus proofs carry a
//   timestamp, so it cannot be backfilled either. What is rendered instead is
//   the raw `observed_at`, plus the census verdict when one exists, plus
//   "never re-checked" when it does not — three states, and the third is a
//   diagnosis rather than a silence.
//
//   NO ranking. There is no rank signal at n≈100 with all-fresh rows, and a
//   ranked list with no ranking is the fake authority this epic exists to
//   abolish. The order is a DETERMINISTIC sort by (subject asc, observed_at
//   desc, rerun asc) — presentation, conferring no precedence.
//
//   NO RIVAL-METHOD flag. Measured at the (subject, quantity) grain D33
//   specifies: 282 of 297 pairs (94.9%) are singletons where it CANNOT fire,
//   and it fires on 15 of 15 where it can, with zero corroboration cases —
//   either impossible or certain, never informative, zero bits. Worse, wave-5
//   verification proved it is currently a FALSE-POSITIVE generator (D60), so
//   rendering it would surface a fabricated signal. The row count carries the
//   message instead: "3 methods on this key — run all three and compare."
//   The literal string RIVAL-METHOD never appears in leads output.
//
// ── THE FILTER IS CASE-INSENSITIVE (charter D44) ─────────────────────────────
//
// Measured defect, not a style preference: the substring "completion" returned
// 0 rows over a bucket that CONTAINS `go test -run
// TestCompletionNounsCoverAllDispatchedBuiltins ./internal/cli/`. A
// case-sensitive filter produces a FALSE honest-empty, and against this epic's
// own bar an empty that lies is worse than no filter at all.
//
// ── cmd:<head> SUBJECTS ARE NOT INDEXED (charter D45) ────────────────────────
//
// The `cmd:` fallback exists so the WRITE verb never reports 100% REJECTED
// (D32) — a write-path concern that does not obligate the read path. Measured,
// they are dumps rather than subjects: repo-wide `cmd:bp` is 55 rows, `cmd:git`
// 42, `cmd:curl` 27. The first query against a dumping ground discredits the
// feature. They are excluded, and the null state states HOW MANY were hidden,
// because an exclusion nobody can see is indistinguishable from an empty store.
//
// ── THE LEVEL IS RE-DERIVED AT RENDER TIME, NEVER READ FROM STORAGE ──────────
//
// `foldLedger` currently trusts the stored `derived_level` (open defect
// tgw2-fold-reread-derived-level). A leads row printing that stored value would
// inherit the bug into the instrument's headline column — this module's whole
// thesis failing in its own output. `deriveLevel(rerun)` runs here, on the
// command, every time; the stored value is carried alongside as
// `stored_level` and a disagreement is stated out loud.
//
// HONEST SCOPE (charter D46): leads help THIS EPIC stop re-deriving its own
// housekeeping facts. Repo-wide the mint degenerates (337 subjects, 268 of them
// singletons) and leads beat grep only in a bucket-size band of roughly 3–20.
//
// node: builtins only. Imports the fold and the level ladder; nothing else.

import { readFileSync } from "node:fs";

import { deriveLevel } from "./level.mjs";

// A subject minted from the `cmd:<head>` fallback rather than from a path
// token. One constant, one place to re-point.
export const CMD_SUBJECT_PREFIX = "cmd:";

export function isCommandShapeSubject(subject) {
  return String(subject ?? "").startsWith(CMD_SUBJECT_PREFIX);
}

// The three misses that are STRUCTURAL — properties of what a path-keyed index
// of commands can be, not gaps a bigger corpus would close. Named out loud in
// the null state so two of the three stop being silent failures and become
// diagnoses (D44). Exported because the test asserts on this exact text.
export const STRUCTURAL_MISSES = Object.freeze([
  "the ledger indexes repo PATHS — it cannot index bp task ids",
  "it cannot answer judgment questions — it stores commands, never conclusions",
  "it is keyed to the path a command names, so a subsystem question may need a narrower substring",
]);

// Stated on every render, empty or not. The guarantee is a property of the
// schema, and a reader who does not know that has to take the output on trust.
export const NO_VALUE_FOOTER =
  "leads hand over METHOD, never a value: RECIPE_FIELDS has no `value` field and the fold rebuilds\n"
  + "  every recipe from six NAMED fields, so even a forged run file cannot put an answer on this screen.";

// ── the census join ──────────────────────────────────────────────────────────

// census.mjs writes NOTHING (it says so in its own caveats), so there is no
// verdict store to read — a verdict reaches leads only when the caller hands
// over a `census --json` report. Absence is therefore the normal case, and it
// is rendered as "never re-checked" rather than as a blank column.
export function censusIndex(report) {
  const rows = Array.isArray(report?.rows) ? report.rows : Array.isArray(report) ? report : [];
  const byCommand = new Map();
  for (const row of rows) {
    const command = typeof row?.command === "string" ? row.command.trim() : "";
    if (command === "") continue;
    byCommand.set(command, {
      outcome: typeof row.outcome === "string" ? row.outcome : "(unnamed outcome)",
      answering: row.answering === true,
      decayed: row.decayed === true,
      admissible: row.admissible === true,
    });
  }
  return byCommand;
}

export function loadCensusIndex(path) {
  return censusIndex(JSON.parse(readFileSync(path, "utf8")));
}

// ── the filter ───────────────────────────────────────────────────────────────

// Case-insensitive substring over the rerun AND the subject. That is the whole
// matching rule — no tokenising, no fuzz, no scoring. A rule a reader cannot
// restate in one sentence cannot be trusted to have produced an honest empty.
// The subject and the rerun are joined by NUL — the one byte a typed query
// cannot contain — so a needle can never match ACROSS the boundary and invent a
// hit out of a subject's tail plus a command's head. It is written as the
// ESCAPE, never as a raw byte: a literal NUL makes git treat the file as binary
// and stop diffing it, and a read path nobody can review is its own defect.
export function matchesQuery(entry, recipe, needle) {
  if (needle === "") return false;
  const hay = `${String(entry?.subject ?? "")}\u0000${String(recipe?.rerun ?? "")}`.toLowerCase();
  return hay.includes(needle);
}

/**
 * selectLeads(folded, query, { census }) → the reduced result set.
 *
 * A pure filter+projection over `folded.entries[]`. It reads no file, spawns
 * nothing, and executes no recipe: executing one would surface an ANSWER and
 * break the cheap-lookup contract this whole layer rests on.
 */
export function selectLeads(folded, query, { census = null } = {}) {
  const entries = Array.isArray(folded?.entries) ? folded.entries : [];
  const needle = String(query ?? "").trim().toLowerCase();

  const indexed = [];
  let hiddenSubjects = 0;
  let hiddenRecipes = 0;
  for (const entry of entries) {
    if (isCommandShapeSubject(entry?.subject)) {
      hiddenSubjects += 1;
      hiddenRecipes += Array.isArray(entry?.recipes) ? entry.recipes.length : 0;
      continue;
    }
    indexed.push(entry);
  }

  const rows = [];
  const matchedKeys = new Set();
  for (const entry of indexed) {
    const recipes = Array.isArray(entry.recipes) ? entry.recipes : [];
    // "N methods on this key" is the row count for the WHOLE key, not for the
    // filtered slice — the message is "this key has N cheap checks", and a
    // count that shrank with the query would be describing the query instead.
    const methodsOnKey = new Set(recipes.map((r) => String(r?.rerun ?? "").trim())).size;
    for (const recipe of recipes) {
      if (!matchesQuery(entry, recipe, needle)) continue;
      matchedKeys.add(entry.key ?? `${entry.subject}\u0000${entry.quantity}`);
      const rerun = String(recipe?.rerun ?? "");
      // THE ON-DISK LEVEL, and it moved one key over. `foldLedger` now
      // re-derives `derived_level` itself (tgw6-fold-rederives-key, closing
      // tgw2-fold-reread-derived-level) and carries the stored value as
      // `stored_level` — the same shape this row has always rendered. Reading
      // `recipe.derived_level` alone would now compare the re-derived value to
      // itself and report `level_restated: false` forever, silently retiring
      // the drift signal this whole section exists for. The `??` keeps a fold
      // that predates that change working unchanged.
      const stored = recipe?.stored_level ?? recipe?.derived_level ?? null;
      // RE-DERIVED HERE, EVERY TIME. Never trusted from storage.
      const derived = deriveLevel(rerun);
      rows.push({
        subject: String(entry.subject ?? ""),
        quantity: String(entry.quantity ?? ""),
        rerun,
        derived_level: derived,
        stored_level: stored,
        level_restated: stored !== null && stored !== derived,
        deps: Array.isArray(recipe?.deps) ? recipe.deps : [],
        observed_at: recipe?.observed_at ?? null,
        run_id: recipe?.run_id ?? null,
        methods_on_key: methodsOnKey,
        census: census instanceof Map ? (census.get(rerun.trim()) ?? null) : null,
      });
    }
  }

  // DETERMINISTIC, and this is the sort — not a ranking. (subject asc,
  // observed_at desc, rerun asc); the last key is a tiebreak so two rows minted
  // in the same second cannot swap between runs.
  rows.sort((a, b) => (
    a.subject.localeCompare(b.subject)
    || String(b.observed_at ?? "").localeCompare(String(a.observed_at ?? ""))
    || a.rerun.localeCompare(b.rerun)
  ));

  // A PARTIALLY-ROTTEN STORE MUST NOT RENDER AS A CLEAN SMALLER ONE. `foldLedger`
  // already reports the run files and rows it could not use in `unreadable[]`,
  // and the fold CLI exits 1 on it — but a filter that reads only `entries[]`
  // inherits the exact defect the fold's own header warns about, one layer up:
  // a store with half its rows dropped produces a confident "HONEST EMPTY, N
  // subjects indexed" that is neither honest nor an empty. It is carried here
  // and stated in BOTH render paths, because the empty state is precisely where
  // a hidden read failure is indistinguishable from a real absence (D6).
  const unreadable = Array.isArray(folded?.unreadable) ? folded.unreadable : [];

  return {
    query: String(query ?? "").trim(),
    rows,
    unreadable: unreadable.length,
    unreadable_detail: unreadable.map((u) => String(u?.message ?? u?.reason ?? "(unnamed)")),
    matched_subjects: matchedKeys.size,
    indexed_subjects: indexed.length,
    indexed_recipes: indexed.reduce((n, e) => n + (Array.isArray(e.recipes) ? e.recipes.length : 0), 0),
    hidden_cmd_subjects: hiddenSubjects,
    hidden_cmd_recipes: hiddenRecipes,
    total_subjects: entries.length,
  };
}

// ── the render ───────────────────────────────────────────────────────────────

function censusLine(row) {
  if (!row.census) return "never re-checked";
  const verdict = row.census.outcome;
  if (!row.census.admissible) return `census ${verdict} (inadmissible — measures this host, not the ledger)`;
  return `census ${verdict}`;
}

function methodsNote(row) {
  if (row.methods_on_key <= 1) return "";
  return `  (${row.methods_on_key} methods on this key — run all ${row.methods_on_key} and compare)`;
}

export function renderLeads(result) {
  const out = [];
  const o = (line = "") => out.push(line);
  const rule = "─".repeat(76);

  o(`grip leads — recipes matching ${JSON.stringify(result.query)} (case-insensitive, over subject and rerun)`);
  o();

  // Stated FIRST, above both the hit list and the empty, because it changes what
  // every number below it means: these rows were never filtered out, they were
  // never read.
  if (result.unreadable > 0) {
    o(`  ⚠ THE STORE IS PARTIALLY UNREADABLE — ${result.unreadable} run file(s)/row(s) could not be read, so the`);
    o("    counts below describe the readable remainder ONLY. An empty here may be a read failure,");
    o("    not an absence. Re-derive with: node tooling/grip/ledger.mjs fold (it exits 1 on this).");
    for (const detail of result.unreadable_detail ?? []) o(`      · ${detail}`);
    o();
  }

  if (result.rows.length === 0) {
    o(`  HONEST EMPTY — no recipe matches. ${result.indexed_subjects} subjects (${result.indexed_recipes} recipes) are indexed,`);
    o(
      result.unreadable > 0
        ? "  and none of their paths or commands contains that substring — but see the warning above:"
          + "\n  this empty is NOT clean, because part of the store was never read."
        : "  and none of their paths or commands contains that substring. This is an answer, not a blank.",
    );
    o();
    o("  Three misses here are STRUCTURAL — a bigger corpus does not close them:");
    for (const miss of STRUCTURAL_MISSES) o(`    · ${miss}`);
    o();
    o(`  Hidden by the charter-D45 exclusion: ${result.hidden_cmd_subjects} cmd:<head> subjects (${result.hidden_cmd_recipes} recipes) are not`);
    o("  indexed at all — they are command-shape dumping grounds, not subjects.");
  } else {
    o(`  ${result.matched_subjects} of ${result.indexed_subjects} indexed subjects match · ${result.rows.length} recipes`);
    o(`  ${result.hidden_cmd_subjects} cmd:<head> subjects (${result.hidden_cmd_recipes} recipes) are excluded from the index (charter D45).`);
    o(rule);
    for (const row of result.rows) {
      o(`  ${row.subject}   ${row.quantity}${methodsNote(row)}`);
      o(`     $ ${row.rerun}`);
      const restated = row.level_restated
        ? `  ← stored ${row.stored_level}, NOT trusted: re-derived from the command`
        : "  (re-derived from the command at render time, never read from storage)";
      o(`       level        ${row.derived_level}${restated}`);
      o(`       deps         ${row.deps.length ? row.deps.join(", ") : "(none recorded)"}`);
      o(`       observed_at  ${row.observed_at ?? "(none)"} · ${censusLine(row)}`);
      o();
    }
  }

  o(rule);
  o(`  ${NO_VALUE_FOOTER}`);
  o("  Re-run the command yourself — that is the whole product. (machine-readable: add --json)");
  return `${out.join("\n")}\n`;
}
