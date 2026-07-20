#!/usr/bin/env node
// ledger.mjs — the durable half of the grip layer: it stores RE-DERIVATION
// RECIPES, and never values.
//
//   import { admitRecipe, writeLedgerRun, readLedgerRuns, foldLedger } from "./ledger.mjs";
//
// THE ROW HAS NO VALUE FIELD (charter D26, amending D10):
//
//     { subject, quantity, rerun, derived_level, deps[], observed_at }
//
// and `observed_at` means "WHEN THIS RECIPE LAST RAN" — never "when this was
// true". The ratified anti-goal ("the ledger is an INDEX OF HOW TO VERIFY
// FAST, never a substitute for verification") stops being a discipline an
// author must remember and becomes a property of the schema: a store that
// contains no truth cannot be mistaken for settled truth.
//
// WHY VALUES CANNOT WORK — settled, do not re-litigate. This repo's own
// `MemAvailable` fact went false because BEAM uptime moved, and uptime is in
// the content hash of NOTHING the fact names. Content-hash invalidation
// structurally cannot catch it: the invalidation signal is not in the fact.
// That is precisely why R2 exists (a fact records its DEPENDENCIES), and why
// a stored value is a lie with a timestamp on it. A writer supplying a
// `value` key is REJECTED (`VALUE-STORED`), never silently dropped.
//
// UNKNOWN FIELDS ARE REJECTED, NOT STRIPPED. `tooling/research-coverage`'s
// `record()` silently strips unknown fields — proven by mutation, and it is
// half of D10's trap: the writer believes it stored something and the store
// disagrees, with no signal anywhere. Here the store's answer to "I do not
// understand this key" is a nonzero, named rejection.
//
// ONE IMMUTABLE FILE PER WRITE, FOLDED AT READ TIME. Every write creates
// exactly one new file under the ledger directory and NEVER opens an existing
// one for modification (`wx`, and the name is content-addressed). D10's
// lost-write class — two writers staggered inside an ~11s window, one
// contribution gone, proven — becomes IMPOSSIBLE rather than managed, and git
// merges the directory add/add clean across concurrent worktrees.
//
// CONFLICT DETECTION IS NOT A WRITE-TIME ALGORITHM. There is no write order to
// appeal to, so a conflict is simply what the FOLD OBSERVES: two rival recipes
// over one (subject, quantity) are BOTH kept and BOTH flagged, and are
// resolved by re-running both TODAY — never by whichever file arrived first.
// (R4.) The adjudicator slice has not merged, so this module emits the
// `{ reason: "CONFLICT", … }` shape rather than importing its vocabulary; when
// it lands, the constant below is the single place to re-point.
//
// NO CLOCK, NO RANDOMNESS. `observed_at` and `run_id` are REQUIRED
// writer-supplied arguments; nothing here calls the current time or a random
// source. D19: the workflow host hard-refuses the clock and randomness
// builtins outright with "breaks resume", and the writer of these rows is one
// phase away from a workflow file. A clock-free module can be called from
// anywhere, including from a phase that has none.
//
// The names of those builtins do not appear ANYWHERE in this file — not in a
// comment, not in a message — so the check is a plain grep over the raw source
// with no comment-stripping caveat to argue about. See ledger.test.mjs.
//
// node: builtins only, no dependencies, no side effect on import.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { deriveLevel, checkCeiling, LEVELS } from "./level.mjs";

// ── the row ──────────────────────────────────────────────────────────────────

// The COMPLETE set of keys a ledger row may carry. Anything else is rejected
// (UNKNOWN-FIELD), and `value` is rejected by its own name because it is the
// doctrinal one.
export const RECIPE_FIELDS = Object.freeze([
  "subject", "quantity", "rerun", "derived_level", "deps", "observed_at",
]);

// Names a writer reaches for when it is about to store an answer instead of a
// way to get one. Each gets the VALUE-STORED rejection rather than the generic
// UNKNOWN-FIELD, because the message has to say WHY, not just "not a key".
const VALUE_SHAPED_FIELDS = Object.freeze([
  "value", "values", "observed_value", "result", "measurement", "measured", "answer",
]);

// The fold's flag for two rival recipes over one key. The adjudicator slice
// (tgw1-adjudicator) owns the verdict vocabulary; it has not merged, so this
// is the same shape emitted locally. One constant = one place to re-point.
export const CONFLICT = "CONFLICT";

// An instant, not a date and not prose. `observed_at` is load-bearing enough
// that "2026-07-20" or "yesterday" must not pass as one.
const ISO_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

// A run id names one production of rows. It goes in a filename, so it may not
// carry a separator or anything a shell or a path would reinterpret.
const RUN_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

function reject(reason, message, extra = {}) {
  return { reason, message: `${reason}: ${message}`, ...extra };
}

// admitRecipe(input) → { ok: true, recipe } | { ok: false, rejections: [...] }
//
// Rejections ACCUMULATE (record.mjs's convention): a writer fixing a row
// should see everything wrong with it in one pass, not one thing per attempt.
export function admitRecipe(input = {}) {
  const rejections = [];

  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    return { ok: false, rejections: [reject("NOT-A-ROW", "a ledger row must be a plain object")] };
  }

  // (a) NO VALUES. Checked FIRST so the doctrinal rejection is the first thing
  // a writer reads.
  for (const field of VALUE_SHAPED_FIELDS) {
    if (Object.hasOwn(input, field)) {
      rejections.push(reject(
        "VALUE-STORED",
        `the row carries ${JSON.stringify(field)} — a ledger row stores a RECIPE for re-deriving a fact, never the fact. A stored value goes stale for reasons that are not in the row (MemAvailable went false because BEAM uptime moved, and uptime is in no content hash of anything the row names), so no invalidation rule can catch it. Put the command in \`rerun\` and re-run it.`,
        { field },
      ));
    }
  }

  // (b) Unknown fields are REJECTED, never stripped — research-coverage's
  // record() strips them, and the writer never learns its data vanished.
  for (const field of Object.keys(input)) {
    if (RECIPE_FIELDS.includes(field) || VALUE_SHAPED_FIELDS.includes(field)) continue;
    rejections.push(reject(
      "UNKNOWN-FIELD",
      `${JSON.stringify(field)} is not a ledger row field (${RECIPE_FIELDS.join(", ")}). Unknown keys are rejected rather than dropped: a store that silently discards what it does not understand lets a writer believe it recorded something it did not.`,
      { field },
    ));
  }

  const { subject, quantity, rerun, derived_level, deps, observed_at } = input;

  if (typeof subject !== "string" || subject.trim() === "") {
    rejections.push(reject("MISSING-SUBJECT", "a row must name what it is about — the subject is half the conflict key"));
  }
  if (typeof quantity !== "string" || quantity.trim() === "") {
    rejections.push(reject("MISSING-QUANTITY", "a row must name WHICH property of the subject the recipe re-derives — the quantity is the other half of the conflict key"));
  }

  // (c) A recipe without a command is not a recipe.
  //
  // D3 (no rerun ⇒ DEMOTE to L6, never reject) governs FACTS, where the prose
  // still carries something and punishing honest work drives writers around
  // the gate. A LEDGER ROW is nothing but the recipe: with no command there is
  // no index entry, only an assertion with a timestamp — the thing this store
  // exists to be incapable of holding. So here it rejects. D20 sanctions
  // exactly this check at the write seam ("rerun is present and non-empty").
  if (typeof rerun !== "string" || rerun.trim() === "") {
    rejections.push(reject(
      "MISSING-RERUN",
      "a ledger row IS the re-derivation recipe — with no `rerun` command there is nothing to index, and what remains is an assertion with a timestamp, which is exactly what this store must be unable to hold",
    ));
  }

  // (d) derived_level is DERIVED — from the rerun command alone. A supplied
  // value is a claim, and the derivation is its ceiling (D2).
  let level = null;
  if (typeof rerun === "string" && rerun.trim() !== "") {
    const derived = deriveLevel(rerun);
    level = derived;
    if (derived_level !== undefined) {
      const ceiling = checkCeiling(derived_level, derived);
      if (!ceiling.ok) {
        rejections.push(ceiling);
      } else if (LEVELS[derived_level] > LEVELS[derived]) {
        level = derived_level; // an honest under-claim is kept
      }
    }
  } else if (derived_level !== undefined && LEVELS[derived_level] === undefined) {
    rejections.push(reject("UNKNOWN-LEVEL", `${JSON.stringify(derived_level)} is not on the ladder ${Object.keys(LEVELS).join(" ")}`));
  }

  // (e) deps[] — R2. May be empty (a recipe genuinely reading nothing else is
  // honest); may not be absent-by-accident-of-type or hold non-strings.
  let depList = [];
  if (deps === undefined) {
    depList = [];
  } else if (!Array.isArray(deps) || deps.some((d) => typeof d !== "string" || d.trim() === "")) {
    rejections.push(reject("BAD-DEPS", "deps must be an array of non-empty subject strings this recipe reads through (R2) — an empty array is fine, a malformed one is not"));
  } else {
    depList = deps.map((d) => d.trim());
  }

  // (f) observed_at — REQUIRED, writer-supplied. This module owns no clock.
  if (typeof observed_at !== "string" || observed_at.trim() === "") {
    rejections.push(reject(
      "MISSING-OBSERVED-AT",
      "observed_at is required and must be supplied by the writer — this module reads no clock at all (D19: the workflow host refuses the clock builtins outright, because they break resume). It records WHEN THIS RECIPE LAST RAN, never when the fact was true.",
    ));
  } else if (!ISO_INSTANT.test(observed_at.trim())) {
    rejections.push(reject(
      "BAD-OBSERVED-AT",
      `${JSON.stringify(observed_at)} is not an ISO-8601 instant (YYYY-MM-DDTHH:MM:SS[.sss](Z|±HH:MM)) — a date or a phrase cannot order two runs of the same recipe`,
    ));
  }

  if (rejections.length > 0) return { ok: false, rejections };

  // Key order is fixed so that the serialized bytes of an identical row are
  // identical — the file name is a digest of them.
  return {
    ok: true,
    recipe: {
      subject: subject.trim(),
      quantity: quantity.trim(),
      rerun: rerun.trim(),
      derived_level: level,
      deps: depList,
      observed_at: observed_at.trim(),
    },
  };
}

// ── the conflict key ─────────────────────────────────────────────────────────

// (subject, quantity). NUL-joined because neither field may contain it, so no
// pair of distinct rows can collide by concatenation.
//
// Defensive about types on purpose: admitRecipe guarantees strings on the WRITE
// path, but the fold reads bytes off disk that nothing re-admits, so a
// hand-edited or truncated file can present a number here. See usableRow.
export function recipeKey(recipe) {
  const part = (v) => (typeof v === "string" ? v.trim() : "");
  return `${part(recipe?.subject)}\u0000${part(recipe?.quantity)}`;
}

// Is this on-disk row usable by the fold?
//
// THE WRITE PATH IS NOT THE READ PATH. admitRecipe gates everything this module
// WRITES, but the fold reads whatever is in the directory — a hand edit, a
// truncated write, a row from a future schema. Two failure modes were live and
// both are defects this module exists to make impossible, committed inside it:
//
//   - a non-string subject/quantity threw out of recipeKey, so ONE bad row took
//     down the WHOLE fold. D6 calls a fold that reports a smaller, cleaner,
//     wrong world a defect; a fold that reports NO world because a single byte
//     rotted is worse, and it fails fatally in the one module that promises to
//     fail informatively (`unreadable[]`).
//   - a null row, a bare string, or a row with no subject silently keyed to the
//     empty pair and merged every malformed row into one bogus entry — garbage
//     accepted as a subject, the mirror defect.
//
// Both now land in `unreadable[]`, named, with file and index. Reported, never
// skipped, never fatal.
function usableRow(row) {
  if (row === null || typeof row !== "object" || Array.isArray(row)) return "a row must be a plain object";
  if (typeof row.subject !== "string" || row.subject.trim() === "") return "subject must be a non-empty string";
  if (typeof row.quantity !== "string" || row.quantity.trim() === "") return "quantity must be a non-empty string";
  if (typeof row.rerun !== "string" || row.rerun.trim() === "") return "rerun must be a non-empty string — the row IS the recipe";
  return null;
}

export function digest(text) {
  return createHash("sha256").update(text).digest("hex").slice(0, 16);
}

// ── writing: one new immutable file, never an existing one ───────────────────

// The default store. NOT gitignored — verified, and deliberately unlike
// tooling/research-coverage/research-ledger.json, which is (D10's trap).
export const DEFAULT_LEDGER_DIR = fileURLToPath(new URL("./ledger/", import.meta.url));

function serialize(runFile) {
  return `${JSON.stringify(runFile, null, 2)}\n`;
}

// writeLedgerRun({ run_id, recipes, dir }) → one new file, or a named rejection.
//
// The file NAME is `<run_id>-<key>.json` where key is a digest of the admitted
// rows (D26's `<run>-<key>` shape). Content-addressing does two jobs: two
// writers sharing a run_id but writing different rows cannot collide, and a
// path collision therefore means the bytes are already identical, so the
// idempotent answer is "already recorded" rather than a write.
export function writeLedgerRun({ run_id, recipes, dir = DEFAULT_LEDGER_DIR } = {}) {
  if (typeof run_id !== "string" || !RUN_ID.test(run_id)) {
    return { ok: false, rejections: [reject("BAD-RUN-ID", `run_id must match ${RUN_ID} — it is part of a filename, and it is supplied by the caller because this module has no clock and no random source to invent one`)] };
  }
  if (!Array.isArray(recipes) || recipes.length === 0) {
    return { ok: false, rejections: [reject("EMPTY-RUN", "a run file must carry at least one recipe — an empty file is a NULL-READ waiting to be folded as an absence")] };
  }

  const admitted = [];
  const rejections = [];
  recipes.forEach((row, index) => {
    const verdict = admitRecipe(row);
    if (verdict.ok) admitted.push(verdict.recipe);
    else rejections.push(...verdict.rejections.map((r) => ({ ...r, index })));
  });

  // All-or-nothing: a run file that quietly held the rows that happened to
  // pass would be the silent-strip defect at file granularity.
  if (rejections.length > 0) return { ok: false, rejections };

  const body = { run_id, recipes: admitted };
  const bytes = serialize(body);
  const key = digest(bytes);
  const path = join(dir, `${run_id}-${key}.json`);

  mkdirSync(dir, { recursive: true });

  if (existsSync(path)) {
    // Content-addressed, so this is the same bytes by construction. Verify
    // rather than assume, and NEVER open it for writing either way.
    const existing = readFileSync(path, "utf8");
    if (existing === bytes) return { ok: true, path, written: false, reason: "ALREADY-RECORDED", recipes: admitted };
    return { ok: false, rejections: [reject("IMMUTABLE-COLLISION", `${basename(path)} exists with different bytes — ledger files are never modified; nothing was written`)], path };
  }

  try {
    // "wx" — the immutability is enforced by the syscall, not by the check
    // above, which is racy on its own.
    writeFileSync(path, bytes, { encoding: "utf8", flag: "wx" });
  } catch (err) {
    if (err?.code === "EEXIST") {
      const existing = readFileSync(path, "utf8");
      if (existing === bytes) return { ok: true, path, written: false, reason: "ALREADY-RECORDED", recipes: admitted };
      return { ok: false, rejections: [reject("IMMUTABLE-COLLISION", `${basename(path)} appeared with different bytes during the write; nothing was modified`)], path };
    }
    return { ok: false, rejections: [reject("WRITE-FAILED", `${err?.message ?? String(err)}`)], path };
  }

  return { ok: true, path, written: true, recipes: admitted };
}

// ── reading ──────────────────────────────────────────────────────────────────

// readLedgerRuns(dir) → { runs, unreadable }
//
// A file that will not parse is REPORTED, never skipped. D6: an empty or
// failed read may not become an admissible negative claim, and a fold that
// silently drops a corrupt file is a fold that reports a smaller, cleaner,
// wrong world.
export function readLedgerRuns(dir = DEFAULT_LEDGER_DIR) {
  const runs = [];
  const unreadable = [];
  if (!existsSync(dir)) return { runs, unreadable };

  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort(); // deterministic: never readdir order

  for (const file of files) {
    const path = join(dir, file);
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(path, "utf8"));
    } catch (err) {
      unreadable.push({ file, reason: "UNPARSEABLE", message: `UNPARSEABLE: ${file} — ${err?.message ?? String(err)}` });
      continue;
    }
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.recipes)) {
      unreadable.push({ file, reason: "MALFORMED-RUN", message: `MALFORMED-RUN: ${file} has no recipes[] array` });
      continue;
    }
    runs.push({ file, run_id: typeof parsed.run_id === "string" ? parsed.run_id : null, recipes: parsed.recipes });
  }
  return { runs, unreadable };
}

// ── the fold ─────────────────────────────────────────────────────────────────

// foldLedger(dirOrRuns) → { entries, conflicts, unreadable, stats }
//
// Every entry is one (subject, quantity) with EVERY recipe ever written for
// it. Nothing is superseded, nothing is deduplicated away, and write order is
// never consulted — there is no write order to consult.
//
// A CONFLICT is two or more DISTINCT `rerun` commands over one key: two ways
// to re-derive the same property that may not agree, both kept and both
// flagged, resolved by running both today. The same command recorded twice is
// CORROBORATION, not conflict — collapsing those two would make the flag fire
// forever on ordinary repetition and be ignored within a wave.
export function foldLedger(source = DEFAULT_LEDGER_DIR) {
  const { runs, unreadable } = Array.isArray(source)
    ? { runs: source, unreadable: [] }
    : readLedgerRuns(source);

  const byKey = new Map();
  let rowCount = 0;

  for (const run of runs) {
    run.recipes.forEach((row, index) => {
      const bad = usableRow(row);
      if (bad !== null) {
        // Reported at row granularity, with enough to find it by hand. The
        // fold continues: one rotten row must never cost the other files.
        unreadable.push({
          file: run.file,
          index,
          reason: "MALFORMED-ROW",
          message: `MALFORMED-ROW: ${run.file} row ${index} — ${bad}. The row is NOT folded; every other row is.`,
        });
        return;
      }
      rowCount += 1;
      const key = recipeKey(row);
      if (!byKey.has(key)) {
        byKey.set(key, {
          key,
          subject: (row?.subject ?? "").trim(),
          quantity: (row?.quantity ?? "").trim(),
          recipes: [],
        });
      }
      byKey.get(key).recipes.push({
        rerun: row?.rerun ?? null,
        derived_level: row?.derived_level ?? null,
        deps: Array.isArray(row?.deps) ? row.deps : [],
        observed_at: row?.observed_at ?? null,
        run_id: run.run_id,
        file: run.file,
      });
    });
  }

  const entries = [...byKey.values()].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const conflicts = [];

  for (const entry of entries) {
    // Deterministic ordering INSIDE an entry too — by (observed_at, file), so
    // the fold reads the same on any machine. This is presentation only: it
    // confers no precedence, and the conflict verdict does not consult it.
    entry.recipes.sort((a, b) => {
      const t = String(a.observed_at).localeCompare(String(b.observed_at));
      return t !== 0 ? t : String(a.file).localeCompare(String(b.file));
    });

    const rivals = [...new Set(entry.recipes.map((r) => String(r.rerun).trim()))];
    entry.distinct_reruns = rivals.length;
    entry.conflict = rivals.length > 1;

    if (entry.conflict) {
      const flag = {
        reason: CONFLICT,
        key: entry.key,
        subject: entry.subject,
        quantity: entry.quantity,
        rivals,
        recipes: entry.recipes,
        message: `${CONFLICT}: ${rivals.length} rival recipes re-derive ${JSON.stringify(entry.quantity)} of ${JSON.stringify(entry.subject)}. Both are kept and neither wins by arrival order — there is no write order here. Resolve by running all ${rivals.length} today and comparing what they answer NOW.`,
      };
      entry.flag = flag;
      conflicts.push(flag);
    }
  }

  return {
    entries,
    conflicts,
    unreadable,
    stats: {
      runs: runs.length,
      rows: rowCount,
      subjects: entries.length,
      conflicts: conflicts.length,
      unreadable: unreadable.length,
    },
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

// `--selftest` is the D18 obligation: a control must be shown able to FIRE,
// and a control that did NOT fire gets its own outcome class (exit 3) rather
// than being absorbed into a normal pass.
function selftest() {
  const controls = [
    ["a row carrying `value` is rejected VALUE-STORED", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "git show origin/main:README.md", observed_at: "2026-07-20T00:00:00Z", value: 42 });
      return !v.ok && v.rejections.some((r) => r.reason === "VALUE-STORED");
    }],
    ["an unknown field is rejected, not stripped", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z", notes: "hi" });
      return !v.ok && v.rejections.some((r) => r.reason === "UNKNOWN-FIELD");
    }],
    ["a missing observed_at is rejected (the module has no clock to fill it)", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md" });
      return !v.ok && v.rejections.some((r) => r.reason === "MISSING-OBSERVED-AT");
    }],
    ["an over-claimed derived_level is rejected LEVEL-SKIP", () => {
      const v = admitRecipe({ subject: "s", quantity: "q", rerun: "cat README.md", derived_level: "L1", observed_at: "2026-07-20T00:00:00Z" });
      return !v.ok && v.rejections.some((r) => r.reason === "LEVEL-SKIP");
    }],
    ["the fold flags two rival recipes over one key", () => {
      const runs = [
        { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "cat a", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
        { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "cat b", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
      ];
      return foldLedger(runs).conflicts.length === 1;
    }],
    ["a rotten on-disk row is reported, and does not take the fold down with it", () => {
      const folded = foldLedger([
        { file: "good.json", run_id: "g", recipes: [{ subject: "s", quantity: "q", rerun: "cat a", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
        { file: "rot.json", run_id: "r", recipes: [{ subject: 42, quantity: "q", rerun: "cat a" }, null] },
      ]);
      return folded.entries.length === 1 && folded.unreadable.length === 2
        && folded.unreadable.every((u) => u.reason === "MALFORMED-ROW");
    }],
    ["an honest row is ADMITTED (the control does not just say no to everything)", () => {
      const v = admitRecipe({ subject: "api/lib/x.ex", quantity: "line count", rerun: "wc -l api/lib/x.ex", deps: [], observed_at: "2026-07-20T00:00:00Z" });
      return v.ok && !Object.hasOwn(v.recipe, "value");
    }],
  ];

  let fired = 0;
  for (const [name, fn] of controls) {
    let ok = false;
    try { ok = fn() === true; } catch { ok = false; }
    process.stdout.write(`${ok ? "fired " : "SILENT"}  ${name}\n`);
    if (ok) fired += 1;
  }
  if (fired === controls.length) {
    process.stdout.write(`\nselftest: ${fired}/${controls.length} controls fired\n`);
    return 0;
  }
  process.stdout.write(`\nCONTROL DID NOT BEHAVE AS A CONTROL — ${controls.length - fired} of ${controls.length} stayed silent\n`);
  return 3;
}

function main(argv) {
  const [cmd = "fold", ...rest] = argv;
  if (cmd === "--selftest" || cmd === "selftest") return selftest();
  if (cmd === "fold") {
    const dir = rest[0] ? resolve(rest[0]) : DEFAULT_LEDGER_DIR;
    const folded = foldLedger(dir);
    process.stdout.write(`${JSON.stringify(folded, null, 2)}\n`);
    // A conflict is a finding, not a failure: both rows are legitimately
    // stored. Exit 0 and let the caller read `conflicts`.
    return folded.unreadable.length > 0 ? 1 : 0;
  }
  process.stderr.write("usage: node ledger.mjs [fold [dir] | --selftest]\n");
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  process.exit(main(process.argv.slice(2)));
}
