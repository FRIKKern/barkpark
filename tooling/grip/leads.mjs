#!/usr/bin/env node
// leads.mjs — the READ half of the grip layer: a SUBSYSTEM lookup that hands
// back RECIPES, never answers.
//
//   node tooling/grip/ledger.mjs leads <subsystem> [--cmd] [--full] [--json] [--census <report.json>] [--dir <ledger dir>]
//
// THE ANTI-GOAL IS STRUCTURAL, NOT A PROMISE (charter D66). This module cannot
// hand back a value even from a forged store, and the reason is not discipline:
// `RECIPE_FIELDS` carries no `value` key, and `foldLedger`'s projection rebuilds
// every recipe from a NAMED ALLOWLIST — so an unknown key is dropped before it
// ever reaches `entries[]`. The guarantee is the allowlist, NOT its length.
// `selectLeads` is a FILTER over `entries[]` — it adds no answer field and reads
// no file. A `value` hand-edited into a run file on disk therefore cannot reach
// this screen, and the test proves that by forging one.
//
// ── SUBJECT MATCHING IS SEGMENT-BOUNDARY, NEVER RAW SUBSTRING (charter D91) ───
//
// A needle matches a subject iff it EQUALS the subject or is a LEADING
// PATH-SEGMENT prefix of it. `js` matches `js/packages/x`; it does NOT match
// `package.json` through the substring "json", nor `.workflow.js` through the
// file extension. This closes the live 25-of-30 `leads js` defect measured in
// tgw6-leads-subject-first: subject-default fixed the command-text dump but did
// nothing for extension/interior-word noise, because that noise is a property of
// SUBSTRING matching over paths, not of the haystack width. The fix stays
// restatable in ONE sentence (D44) — see `MATCH_RULE`, printed on every render —
// and it stays honestly dumb: the needle is compared to path SEGMENTS, no
// tokenising of the needle itself, no fuzz, no scoring.
//
// The cost is paid knowingly: `leads grip` no longer finds
// `tooling/grip/leads.mjs`, because `grip` is a MIDDLE segment there. Type the
// leading prefix (`leads tooling/grip`) or the whole subject. A middle-segment
// convenience match is exactly the imprecision D91 abolishes.
//
// ── DENSE BY DEFAULT; `--full` RESTORES THE BLOCK ───────────────────────────
//
// The default render is ONE line per recipe (subject, quantity, binding class,
// and the re-runnable command), because a five-line block per row turned
// `leads internal/cli` into ~76 lines for 11 recipes — a wall a reader skims
// past. `--full` restores the per-row block (level provenance, deps,
// observed_at, census, binding scope) for when the metadata is the point.
//
// ── SUBSYSTEM ROLLUP IS ALL-ANCESTOR-PREFIX MATCH-COUNT (charter D87) ─────────
//
// A subsystem's size is the count of recipes whose subject EQUALS it or sits
// UNDER it (`subject === P || subject.startsWith(P + "/")`) — every ancestor
// prefix counts a nested recipe, never a greedy disjoint partition. When a
// queried key's count EXCEEDS the [3,20] band (D46's band, the only one where
// leads beats grep), the render answers with the CHILD BREAKDOWN — "api → 34
// recipes; narrow: api/lib (21), api/test (9)" — instead of dumping 34 lines.
// The band metric is computed over LEADS-INDEXED subjects only: `cmd:<head>`
// dumping grounds are hidden (D45), so the reader's number matches the tool's.
//
// ── THE SUBJECT IS THE DEFAULT HAYSTACK; THE COMMAND TEXT IS `--cmd` ─────────
//
// Measured (D80) at 331d418418 (2026-07-21): with the command text in the
// haystack unconditionally, `leads origin/main` returned 51 of the store's 62
// recipes (82%) with ZERO subject matches — a reading against that snapshot,
// never a live share. A question is asked ABOUT a subject; the command text is
// the answer's machinery, not its topic. `--cmd` restores the wider haystack
// (a raw case-insensitive substring over subject+command), and the count of
// what it would add (`cmd_only_recipes`) is stated on the empty AND on the hit
// list — so this is a precision fix with its recall moved behind a named,
// counted flag.
//
// ── THE FILTER IS CASE-INSENSITIVE (charter D44) ─────────────────────────────
//
// Measured defect: the substring "completion" returned 0 rows over a bucket that
// CONTAINS `go test -run TestCompletionNounsCoverAllDispatchedBuiltins
// ./internal/cli/`. A case-sensitive filter produces a FALSE honest-empty.
//
// ── cmd:<head> SUBJECTS ARE NOT INDEXED (charter D45) ────────────────────────
//
// The `cmd:` fallback exists so the WRITE verb never reports 100% REJECTED
// (D32) — a write-path concern that does not obligate the read path. Repo-wide
// `cmd:bp` is 55 rows, `cmd:git` 42: dumping grounds, not subjects. They are
// excluded from the index AND from the rollup band, and the null state states
// HOW MANY were hidden.
//
// ── PER-ROW BINDING IS IMPORTED, NEVER RE-DERIVED (charter D73/D74) ───────────
//
// Every row declares its binding class (content-addressed / shared-ref /
// per-worktree / cwd-bound / foreign-tree-pinned) and its portable scope,
// computed by `classifyBinding` from binding.mjs — the ONE grammar for ref
// identity. leads does not carry a second regex; a divergent answer here would
// be exactly the copy-paste-the-grammar defect this epic exists to abolish.
//
// ── THE LEVEL IS RE-DERIVED AT RENDER TIME, NEVER READ FROM STORAGE ──────────
//
// `deriveLevel(rerun)` runs HERE, on the command, every time. The stored value
// is carried alongside as `stored_level` and a disagreement is stated out loud.
//
// HONEST SCOPE (charter D46): leads help THIS EPIC stop re-deriving its own
// housekeeping facts. Repo-wide the mint degenerates and leads beat grep only in
// a bucket-size band of roughly 3–20.
//
// node: builtins only. Imports the fold, the level ladder and the binding
// grammar; nothing else. It executes NOTHING — surfacing an ANSWER would break
// the cheap-lookup contract this whole layer rests on.

import { readFileSync } from "node:fs";

import { deriveLevel } from "./level.mjs";
import { classifyBinding } from "./binding.mjs";

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
  + "  every recipe from a NAMED ALLOWLIST of fields, so even a forged run file cannot put an answer here.";

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

// ── the subsystem band (charter D87) ──────────────────────────────────────────

// The [3,20] bucket-size band D46 identified as the only range where leads beats
// grep. A key BELOW it is a grep away; a key ABOVE it is a dump the rollup breaks
// into children.
export const SUBSYSTEM_BAND = Object.freeze({ min: 3, max: 20 });

// ancestorPrefixCount(entries, P) → how many recipes sit AT or UNDER the path P.
// The ALL-ANCESTOR rule (D87): a recipe under `api/lib` is counted for `api`,
// for `api/lib`, and for its own exact subject — never assigned to just one
// bucket as a greedy partition would. `P` is matched at a SEGMENT boundary, so
// `api` never absorbs `apiary/…`.
export function ancestorPrefixCount(entries, prefix) {
  const list = Array.isArray(entries) ? entries : [];
  const p = String(prefix ?? "");
  if (p === "") return 0;
  let n = 0;
  for (const entry of list) {
    const subject = String(entry?.subject ?? "");
    if (subject === p || subject.startsWith(`${p}/`)) {
      n += Array.isArray(entry?.recipes) ? entry.recipes.length : 0;
    }
  }
  return n;
}

// Every path-segment prefix of every INDEXED subject — the candidate keys the
// band is computed over. `cmd:<head>` subjects are excluded here, before the
// count, so the band never counts a dumping ground (D45/D87).
export function candidatePrefixes(entries) {
  const set = new Set();
  for (const entry of Array.isArray(entries) ? entries : []) {
    if (isCommandShapeSubject(entry?.subject)) continue;
    const subject = String(entry?.subject ?? "");
    if (subject === "") continue;
    const segs = subject.split("/");
    for (let i = 1; i <= segs.length; i += 1) set.add(segs.slice(0, i).join("/"));
  }
  return [...set];
}

// subsystemBand(entries) → the sorted list of prefix keys whose ALL-ANCESTOR
// recipe count sits inside the [3,20] band, computed over LEADS-INDEXED subjects
// only. This is the number a reader sees quoted; because `cmd:<head>` subjects
// are hidden from BOTH this band and the leads index, the reader's number
// matches the tool's (D45/D87).
export function subsystemBand(entries) {
  const indexed = (Array.isArray(entries) ? entries : []).filter((e) => !isCommandShapeSubject(e?.subject));
  return candidatePrefixes(indexed)
    .filter((prefix) => {
      const n = ancestorPrefixCount(indexed, prefix);
      return n >= SUBSYSTEM_BAND.min && n <= SUBSYSTEM_BAND.max;
    })
    .sort((a, b) => a.localeCompare(b));
}

// childBreakdown(rows, query) → the immediate-child rollup for an over-band key.
// Groups the matched rows by the NEXT path segment under `query`, counting with
// the same all-ancestor rule, so `api` breaks into `api/lib`, `api/test`, and
// any recipes sitting EXACTLY at `api`. Case-insensitive on the prefix, but the
// child paths are displayed with their real casing.
export function childBreakdown(rows, query) {
  const q = String(query ?? "").trim();
  const qLower = q.toLowerCase();
  const children = new Map();
  let exact = 0;
  for (const row of Array.isArray(rows) ? rows : []) {
    const subject = String(row?.subject ?? "");
    const subLower = subject.toLowerCase();
    if (subLower === qLower) { exact += 1; continue; }
    if (!subLower.startsWith(`${qLower}/`)) continue;
    // The real-cased child path: query length + 1 for the slash, then to the
    // next slash.
    const rest = subject.slice(q.length + 1);
    const nextSeg = rest.split("/")[0];
    const childPath = `${subject.slice(0, q.length)}/${nextSeg}`;
    children.set(childPath, (children.get(childPath) ?? 0) + 1);
  }
  const sorted = [...children.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([path, count]) => ({ path, count }));
  return { exact, children: sorted };
}

// ── the filter ───────────────────────────────────────────────────────────────

// THE WHOLE MATCHING RULE, IN ONE SENTENCE (charter D44/D91). Printed on every
// render, so a reader never has to infer it from the results — a rule you cannot
// restate cannot be trusted to have produced an honest empty.
export const MATCH_RULE =
  "a recipe matches when its SUBJECT equals the query or has it as a leading path-segment prefix (js matches js/x, never package.json), case-insensitive — and, with --cmd, when its RERUN COMMAND contains it as a substring";

// subjectSegmentMatch(subject, needle) → the D91 rule. The needle EQUALS the
// whole subject, or is a run of whole path segments at its head. `js` matches
// `js/packages/x`; it does not match `package.json` (substring "json") nor
// `.workflow.js` (extension). Case-insensitive; no tokenising of the needle.
export function subjectSegmentMatch(subject, needle) {
  const s = String(subject ?? "").toLowerCase();
  const q = String(needle ?? "").toLowerCase();
  if (q === "") return false;
  return s === q || s.startsWith(`${q}/`);
}

// Case-insensitive, no fuzz, no scoring — the SUBJECT is matched at a SEGMENT
// boundary (D91), and by DEFAULT the command text is not searched at all.
//
// `--cmd` opts the command text back in as a raw substring, restoring the wider
// pre-D80 haystack. In that opt-in mode the subject and the rerun are joined by
// NUL — the one byte a typed query cannot contain — so a needle can never match
// ACROSS the boundary and invent a hit out of a subject's tail plus a command's
// head. It is written as the ESCAPE, never as a raw byte: a literal NUL makes
// git treat the file as binary and stop diffing it (charter D67).
export function matchesQuery(entry, recipe, needle, { cmd = false } = {}) {
  const q = String(needle ?? "").toLowerCase();
  if (q === "") return false;
  if (subjectSegmentMatch(entry?.subject, q)) return true;
  if (!cmd) return false;
  const hay = `${String(entry?.subject ?? "")}\u0000${String(recipe?.rerun ?? "")}`.toLowerCase();
  return hay.includes(q);
}

/**
 * selectLeads(folded, query, { census, cmd }) → the reduced result set.
 *
 * A pure filter+projection over `folded.entries[]`. It reads no file, spawns
 * nothing, and executes no recipe. `cmd:true` widens the haystack to the rerun
 * command (the `--cmd` flag). In EITHER mode the command-text match is evaluated
 * for every recipe, because the count of what the wider mode would add is what
 * keeps the narrow mode's empty honest — see `cmd_only_recipes`.
 */
export function selectLeads(folded, query, { census = null, cmd = false } = {}) {
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
  // Recipes the `--cmd` haystack matches that the SUBJECT-segment rule does not.
  // The command-text match is a strict superset of the subject match, so this is
  // exactly "what --cmd adds" — computed in both modes so the number is
  // available whether the flag is on or off.
  let cmdOnlyRecipes = 0;
  for (const entry of indexed) {
    const recipes = Array.isArray(entry.recipes) ? entry.recipes : [];
    // "N methods on this key" is the row count for the WHOLE key, not for the
    // filtered slice — the message is "this key has N cheap checks".
    const methodsOnKey = new Set(recipes.map((r) => String(r?.rerun ?? "").trim())).size;
    for (const recipe of recipes) {
      const onSubject = matchesQuery(entry, recipe, needle);
      const onCommand = matchesQuery(entry, recipe, needle, { cmd: true });
      if (onCommand && !onSubject) cmdOnlyRecipes += 1;
      if (!(cmd ? onCommand : onSubject)) continue;
      matchedKeys.add(entry.key ?? `${entry.subject}\u0000${entry.quantity}`);
      const rerun = String(recipe?.rerun ?? "");
      // THE ON-DISK LEVEL. `foldLedger` re-derives `derived_level` itself
      // (tgw6-fold-rederives-key) and carries the stored value as `stored_level`;
      // the `??` keeps a fold that predates that change working unchanged.
      const stored = recipe?.stored_level ?? recipe?.derived_level ?? null;
      // RE-DERIVED HERE, EVERY TIME. Never trusted from storage.
      const derived = deriveLevel(rerun);
      // BINDING: imported from binding.mjs, never a second regex here (D73/D74).
      const binding = classifyBinding(rerun);
      rows.push({
        subject: String(entry.subject ?? ""),
        quantity: String(entry.quantity ?? ""),
        rerun,
        derived_level: derived,
        stored_level: stored,
        level_restated: stored !== null && stored !== derived,
        binding_class: binding.binding_class ?? null,
        portable_scope: binding.portable_scope ?? null,
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

  // A PARTIALLY-ROTTEN STORE MUST NOT RENDER AS A CLEAN SMALLER ONE (D6).
  const unreadable = Array.isArray(folded?.unreadable) ? folded.unreadable : [];

  return {
    query: String(query ?? "").trim(),
    match_mode: cmd ? "subject+command" : "subject",
    match_rule: MATCH_RULE,
    rows,
    cmd_only_recipes: cmdOnlyRecipes,
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

// ONE physical line per recipe (the default): subject, quantity, binding class,
// and the re-runnable command. Everything a reader needs to re-derive the fact,
// nothing they have to scroll past.
function denseLine(row) {
  const binding = row.binding_class ?? "unknown";
  return `  ${row.subject}  ${row.quantity}  ${binding}  $ ${row.rerun}${methodsNote(row)}`;
}

// The per-row BLOCK, restored by --full: level provenance, binding scope, deps,
// observed_at and census verdict.
function fullBlock(row, out) {
  out(`  ${row.subject}   ${row.quantity}${methodsNote(row)}`);
  out(`     $ ${row.rerun}`);
  const restated = row.level_restated
    ? `  ← stored ${row.stored_level}, NOT trusted: re-derived from the command`
    : "  (re-derived from the command at render time, never read from storage)";
  out(`       level        ${row.derived_level}${restated}`);
  out(`       binding      ${row.binding_class ?? "unknown"} · portable to ${row.portable_scope ?? "unknown"}`);
  out(`       deps         ${row.deps.length ? row.deps.join(", ") : "(none recorded)"}`);
  out(`       observed_at  ${row.observed_at ?? "(none)"} · ${censusLine(row)}`);
  out("");
}

// The rollup: a key whose all-ancestor count exceeds the band is answered with
// its child directories and their counts, not a per-recipe dump (D87).
function renderRollup(result, out) {
  const { children, exact } = childBreakdown(result.rows, result.query);
  out(`  ${result.query} → ${result.rows.length} recipes — over the [${SUBSYSTEM_BAND.min},${SUBSYSTEM_BAND.max}] band, so this is a subsystem, not a lead.`);
  out("  Narrow to a child (each count is recipes AT or UNDER that path — the all-ancestor rule):");
  for (const child of children) out(`    ${child.path}   ${child.count}   ·  leads ${child.path}`);
  if (exact > 0) out(`    ${result.query} (exactly)   ${exact}`);
  out("");
  out(`  ${result.rows.length} recipes were matched but NOT listed — re-run with a child prefix above, or \`--full\` to see them all.`);
  out("");
}

export function renderLeads(result, opts = {}) {
  // `--full` reaches this module through the CLI's argv rather than through
  // ledger.mjs's leadsCommand (that file is owned by a concurrent slice); a
  // programmatic caller passes { full } explicitly and never touches argv.
  const full = opts.full ?? (typeof process !== "undefined" && Array.isArray(process.argv) && process.argv.includes("--full"));
  const out = [];
  const o = (line = "") => out.push(line);
  const rule = "─".repeat(76);

  const wide = result.match_mode === "subject+command";
  const cmdOnly = Number(result.cmd_only_recipes ?? 0);
  const scope = wide ? "over the SUBJECT and the RERUN COMMAND (--cmd)" : "over the SUBJECT";
  o(`grip leads — recipes matching ${JSON.stringify(result.query)} (case-insensitive, ${scope})`);
  o(`  rule: ${result.match_rule ?? MATCH_RULE}`);
  o();

  if (result.unreadable > 0) {
    o(`  ⚠ THE STORE IS PARTIALLY UNREADABLE — ${result.unreadable} run file(s)/row(s) could not be read, so the`);
    o("    counts below describe the readable remainder ONLY. An empty here may be a read failure,");
    o("    not an absence. Re-derive with: node tooling/grip/ledger.mjs fold (it exits 1 on this).");
    for (const detail of result.unreadable_detail ?? []) o(`      · ${detail}`);
    o();
  }

  if (result.rows.length === 0) {
    o(`  HONEST EMPTY — no recipe matches. ${result.indexed_subjects} subjects (${result.indexed_recipes} recipes) are indexed,`);
    const searched = wide ? "and none of their paths or commands contains that substring" : "and none of their SUBJECTS equals it or has it as a leading path segment";
    o(
      result.unreadable > 0
        ? `  ${searched} — but see the warning above:`
          + "\n  this empty is NOT clean, because part of the store was never read."
        : `  ${searched}. This is an answer, not a blank.`,
    );
    o();

    if (!wide) {
      if (cmdOnly > 0) {
        o(`  ${cmdOnly} indexed recipe(s) carry that substring in their RERUN COMMAND rather than in a subject.`);
        o(`  \`--cmd\` widens the search to include them; they are matches on command text, not on this subject.`);
      } else {
        o("  No indexed recipe carries it in its RERUN COMMAND either, so `--cmd` returns 0 as well —");
        o("  this empty is the whole store's answer, not one mode's.");
      }
      o();
    }

    o("  Three misses here are STRUCTURAL — a bigger corpus does not close them:");
    for (const miss of STRUCTURAL_MISSES) o(`    · ${miss}`);
    o();
    o(`  Hidden by the charter-D45 exclusion: ${result.hidden_cmd_subjects} cmd:<head> subjects (${result.hidden_cmd_recipes} recipes) are not`);
    o("  indexed at all — they are command-shape dumping grounds, not subjects.");
  } else {
    o(`  ${result.matched_subjects} of ${result.indexed_subjects} indexed subjects match · ${result.rows.length} recipes`);
    if (cmdOnly > 0) {
      o(wide
        ? `  ${cmdOnly} of these ${result.rows.length} recipes matched on RERUN COMMAND TEXT, not on the subject (--cmd is on).`
        : `  ${cmdOnly} further recipe(s) carry it in RERUN COMMAND TEXT only — \`--cmd\` includes them, on command not subject.`);
    }
    o(`  ${result.hidden_cmd_subjects} cmd:<head> subjects (${result.hidden_cmd_recipes} recipes) are excluded from the index (charter D45).`);
    o(rule);

    // ROLLUP when a subsystem key exceeds the band and has children to break
    // into. --cmd rows can sit outside the query prefix, so the rollup is
    // subject-mode only; a lone busy key (no children) falls through to a list.
    const breakdown = !wide && result.rows.length > SUBSYSTEM_BAND.max
      ? childBreakdown(result.rows, result.query)
      : { children: [] };
    if (breakdown.children.length > 0) {
      renderRollup(result, o);
    } else if (full) {
      for (const row of result.rows) fullBlock(row, o);
    } else {
      for (const row of result.rows) o(denseLine(row));
      o("");
      o("  (one line per recipe; add --full for level, deps, observed_at and binding scope)");
    }
  }

  o(rule);
  o(`  ${NO_VALUE_FOOTER}`);
  o("  Re-run the command yourself — that is the whole product. (machine-readable: add --json)");
  return `${out.join("\n")}\n`;
}
