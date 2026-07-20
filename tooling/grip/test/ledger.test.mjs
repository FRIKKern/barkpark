// ledger.test.mjs — the recipe ledger: no values, immutable files, read-time fold.
//
//   node --test tooling/grip/test/ledger.test.mjs
//
// Every write in this file goes to a fresh mkdtemp directory. NOTHING here
// writes into the committed tooling/grip/ledger/ — a test that seeds the real
// store would make the store's own contents untrustworthy, which is the whole
// disease.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  admitRecipe,
  writeLedgerRun,
  readLedgerRuns,
  foldLedger,
  recipeKey,
  digest,
  RECIPE_FIELDS,
  CONFLICT,
  DEFAULT_LEDGER_DIR,
} from "../ledger.mjs";

const LEDGER_SRC = fileURLToPath(new URL("../ledger.mjs", import.meta.url));
const REPO_ROOT = fileURLToPath(new URL("../../../", import.meta.url));

function tmpLedger() {
  return mkdtempSync(join(tmpdir(), "grip-ledger-"));
}

// A row that is honest in every respect — the baseline the rejection tests
// mutate ONE field of, so a rejection can only be attributed to that field.
function goodRow(over = {}) {
  return {
    subject: "api/lib/barkpark/plugin.ex",
    quantity: "callback count",
    rerun: "grep -c 'def ' api/lib/barkpark/plugin.ex",
    deps: ["api/lib/barkpark/plugin.ex"],
    observed_at: "2026-07-20T12:00:00Z",
    ...over,
  };
}

// ── export surface ───────────────────────────────────────────────────────────

test("the row schema is frozen and contains no value field", () => {
  assert.ok(Object.isFrozen(RECIPE_FIELDS));
  assert.deepEqual([...RECIPE_FIELDS], [
    "subject", "quantity", "rerun", "derived_level", "deps", "observed_at",
  ]);
  assert.ok(!RECIPE_FIELDS.includes("value"), "the schema must have no place to put an answer");
  assert.equal(typeof admitRecipe, "function");
  assert.equal(typeof writeLedgerRun, "function");
  assert.equal(typeof foldLedger, "function");
});

test("an honest row is admitted and comes back with exactly the schema's keys", () => {
  const verdict = admitRecipe(goodRow());
  assert.ok(verdict.ok, JSON.stringify(verdict.rejections));
  assert.deepEqual(Object.keys(verdict.recipe).sort(), [...RECIPE_FIELDS].sort());
  assert.equal(verdict.recipe.derived_level, "L3");
});

// ── criterion 1: NO VALUES, and a value is REJECTED, not dropped ─────────────

test("a row carrying `value` is REJECTED with VALUE-STORED", () => {
  const verdict = admitRecipe(goodRow({ value: 47 }));
  assert.equal(verdict.ok, false);
  const r = verdict.rejections.find((x) => x.reason === "VALUE-STORED");
  assert.ok(r, `expected VALUE-STORED, got ${verdict.rejections.map((x) => x.reason).join(", ")}`);
  assert.match(r.message, /never the fact/);
  assert.equal(r.field, "value");
});

test("REJECTED, not silently dropped: the falsy and null cases are rejections too", () => {
  // The silent-strip defect hides exactly here — `if (row.value)` would let
  // 0, "" and null through as "no value supplied".
  for (const value of [0, "", null, false, undefined]) {
    const verdict = admitRecipe(goodRow({ value }));
    assert.equal(verdict.ok, false, `value=${JSON.stringify(value)} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "VALUE-STORED"));
  }
});

test("the value-shaped family is rejected by name, each naming its own field", () => {
  for (const field of ["values", "observed_value", "result", "measurement", "measured", "answer"]) {
    const verdict = admitRecipe(goodRow({ [field]: "42" }));
    assert.equal(verdict.ok, false);
    assert.ok(verdict.rejections.some((x) => x.reason === "VALUE-STORED" && x.field === field));
  }
});

test("an unknown field is REJECTED, never stripped (research-coverage's record() strips — that is half of D10's trap)", () => {
  const verdict = admitRecipe(goodRow({ notes: "ran it twice" }));
  assert.equal(verdict.ok, false);
  const r = verdict.rejections.find((x) => x.reason === "UNKNOWN-FIELD");
  assert.ok(r);
  assert.equal(r.field, "notes");
  assert.match(r.message, /believe it recorded something it did not/);
});

test("rejections accumulate — one pass shows everything wrong with the row", () => {
  const verdict = admitRecipe({ value: 1, notes: "x", subject: "s" });
  assert.equal(verdict.ok, false);
  const reasons = new Set(verdict.rejections.map((x) => x.reason));
  for (const expected of ["VALUE-STORED", "UNKNOWN-FIELD", "MISSING-QUANTITY", "MISSING-RERUN", "MISSING-OBSERVED-AT"]) {
    assert.ok(reasons.has(expected), `missing ${expected} in ${[...reasons].join(", ")}`);
  }
});

// ── the rest of the admission grammar ────────────────────────────────────────

test("a row with no rerun command is REJECTED — a ledger row IS the recipe", () => {
  const verdict = admitRecipe(goodRow({ rerun: "   " }));
  assert.equal(verdict.ok, false);
  assert.ok(verdict.rejections.some((x) => x.reason === "MISSING-RERUN"));
});

test("derived_level is DERIVED from the rerun command, and an over-claim is a LEVEL-SKIP", () => {
  const local = admitRecipe(goodRow({ rerun: "cat api/mix.exs" }));
  assert.equal(local.recipe.derived_level, "L3");

  const skip = admitRecipe(goodRow({ rerun: "cat api/mix.exs", derived_level: "L1" }));
  assert.equal(skip.ok, false);
  assert.ok(skip.rejections.some((x) => x.reason === "LEVEL-SKIP"));

  const live = admitRecipe(goodRow({ rerun: "curl -s https://barkpark.cloud/v1/health" }));
  assert.equal(live.recipe.derived_level, "L1");

  const under = admitRecipe(goodRow({ rerun: "curl -s https://barkpark.cloud/v1/health", derived_level: "L3" }));
  assert.ok(under.ok);
  assert.equal(under.recipe.derived_level, "L3", "an honest under-claim is kept");
});

test("deps must be an array of non-empty subjects (R2), and empty is honest", () => {
  assert.ok(admitRecipe(goodRow({ deps: [] })).ok);
  for (const deps of ["a", [""], [null], [3]]) {
    const verdict = admitRecipe(goodRow({ deps }));
    assert.equal(verdict.ok, false, `deps=${JSON.stringify(deps)} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "BAD-DEPS"));
  }
});

test("a non-object row is rejected NOT-A-ROW", () => {
  for (const bad of [null, "row", 7, ["subject"]]) {
    const verdict = admitRecipe(bad);
    assert.equal(verdict.ok, false);
    assert.equal(verdict.rejections[0].reason, "NOT-A-ROW");
  }
});

// ── criterion 4: observed_at is required and the module is clock-free ────────

test("observed_at is a REQUIRED writer-supplied argument", () => {
  const missing = admitRecipe({ ...goodRow(), observed_at: undefined });
  assert.equal(missing.ok, false);
  assert.ok(missing.rejections.some((x) => x.reason === "MISSING-OBSERVED-AT"));
});

test("observed_at must be an instant — a bare date or a phrase cannot order two runs", () => {
  for (const bad of ["2026-07-20", "yesterday", "just now", "1721476800"]) {
    const verdict = admitRecipe(goodRow({ observed_at: bad }));
    assert.equal(verdict.ok, false, `${bad} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "BAD-OBSERVED-AT"));
  }
  for (const good of ["2026-07-20T12:00:00Z", "2026-07-20T12:00:00.123Z", "2026-07-20T12:00:00+02:00"]) {
    assert.ok(admitRecipe(goodRow({ observed_at: good })).ok, `${good} must be admitted`);
  }
});

test("ledger.mjs is CLOCK-FREE and RANDOM-FREE — the source contains no Date.now, new Date, or Math.random (D19)", () => {
  // The RAW source, deliberately unstripped. A comment-stripping version of
  // this check invites the argument "but it was only in a comment" — and the
  // criterion is a plain grep, so the file names those builtins NOWHERE.
  const src = readFileSync(LEDGER_SRC, "utf8");
  for (const forbidden of [/Date\.now/, /new\s+Date/, /Math\.random/, /performance\.now/, /process\.hrtime/, /\bDate\s*\(/]) {
    assert.equal(forbidden.test(src), false, `ledger.mjs mentions ${forbidden} — it must own no clock, and must not read as if it might`);
  }

  // The control must be able to FAIL: the same predicate over a source that
  // DOES read the clock has to trip. record.mjs fills a missing observed_at
  // with new Date().toISOString() — the exact thing this module refuses.
  const clocked = readFileSync(fileURLToPath(new URL("../record.mjs", import.meta.url)), "utf8");
  assert.equal(/new\s+Date/.test(clocked), true, "the negative control is stale — record.mjs no longer reads a clock, so this test proves nothing");
});

test("two identical rows produce identical bytes — the module is deterministic, so the same input twice cannot drift", () => {
  const a = admitRecipe(goodRow());
  const b = admitRecipe(goodRow());
  assert.equal(JSON.stringify(a.recipe), JSON.stringify(b.recipe));
  assert.equal(digest(JSON.stringify(a.recipe)), digest(JSON.stringify(b.recipe)));
});

// ── criterion 2: one new file per write, existing files never touched ────────

test("each write creates exactly ONE new file and leaves earlier files byte-identical", () => {
  const dir = tmpLedger();

  const first = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  assert.ok(first.ok, JSON.stringify(first.rejections));
  assert.equal(first.written, true);
  assert.equal(readdirSync(dir).length, 1);

  const beforeBytes = readFileSync(first.path);
  const beforeStat = statSync(first.path);

  const second = writeLedgerRun({
    run_id: "run-b",
    recipes: [goodRow({ subject: "api/lib/barkpark/schema.ex", rerun: "wc -l api/lib/barkpark/schema.ex" })],
    dir,
  });
  assert.ok(second.ok, JSON.stringify(second.rejections));
  assert.notEqual(second.path, first.path);
  assert.equal(readdirSync(dir).length, 2, "the second write must ADD a file, never fold into the first");

  const afterBytes = readFileSync(first.path);
  const afterStat = statSync(first.path);
  assert.deepEqual(afterBytes, beforeBytes, "the first file's bytes must be unchanged");
  assert.equal(afterStat.size, beforeStat.size);
  assert.equal(afterStat.mtimeMs, beforeStat.mtimeMs, "the first file must not even have been opened for writing");
});

test("the same run written twice is ALREADY-RECORDED — idempotent, and still one file", () => {
  const dir = tmpLedger();
  const a = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  const before = readFileSync(a.path);

  const b = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  assert.ok(b.ok);
  assert.equal(b.written, false);
  assert.equal(b.reason, "ALREADY-RECORDED");
  assert.equal(readdirSync(dir).length, 1);
  assert.deepEqual(readFileSync(a.path), before);
});

test("two writers sharing a run_id but writing different rows do NOT collide — D10's lost-write class", () => {
  const dir = tmpLedger();
  const a = writeLedgerRun({ run_id: "same-run", recipes: [goodRow({ subject: "a.ex", rerun: "wc -l a.ex" })], dir });
  const b = writeLedgerRun({ run_id: "same-run", recipes: [goodRow({ subject: "b.ex", rerun: "wc -l b.ex" })], dir });
  assert.ok(a.ok && b.ok);
  assert.notEqual(a.path, b.path);
  assert.equal(readdirSync(dir).length, 2);

  const folded = foldLedger(dir);
  assert.equal(folded.stats.rows, 2, "neither writer's contribution may be lost");
});

test("a write with any bad row writes NOTHING — all-or-nothing, never a partial file", () => {
  const dir = tmpLedger();
  const verdict = writeLedgerRun({ run_id: "run-a", recipes: [goodRow(), goodRow({ value: 1 })], dir });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.rejections.some((x) => x.reason === "VALUE-STORED" && x.index === 1));
  assert.equal(readdirSync(dir).length, 0, "no file may exist after a rejected write");
});

test("run_id is caller-supplied and validated — the module invents no id because it has no clock", () => {
  const dir = tmpLedger();
  for (const run_id of [undefined, "", "has space", "a/b", "../escape", "x".repeat(65)]) {
    const verdict = writeLedgerRun({ run_id, recipes: [goodRow()], dir });
    assert.equal(verdict.ok, false, `run_id=${JSON.stringify(run_id)} must be rejected`);
    assert.equal(verdict.rejections[0].reason, "BAD-RUN-ID");
  }
  assert.equal(readdirSync(dir).length, 0);
});

test("an empty run is rejected — an empty file would fold as an absence (D6)", () => {
  const dir = tmpLedger();
  const verdict = writeLedgerRun({ run_id: "run-a", recipes: [], dir });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.rejections[0].reason, "EMPTY-RUN");
});

test("a pre-existing file at the content-addressed path with DIFFERENT bytes is never overwritten", () => {
  const dir = tmpLedger();
  const probe = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  const path = probe.path;
  writeFileSync(path, "{\"tampered\":true}\n");

  const verdict = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.rejections[0].reason, "IMMUTABLE-COLLISION");
  assert.equal(readFileSync(path, "utf8"), "{\"tampered\":true}\n", "the tampered file must survive untouched");
});

// ── criterion 3: the fold observes conflicts ─────────────────────────────────

test("foldLedger surfaces two RIVAL recipes over one (subject, quantity) as both-kept-and-flagged", () => {
  const dir = tmpLedger();
  writeLedgerRun({
    run_id: "run-a",
    recipes: [goodRow({ quantity: "callback count", rerun: "grep -c 'def ' api/lib/barkpark/plugin.ex" })],
    dir,
  });
  // The planted rival: same subject, same quantity, a DIFFERENT way to get it.
  writeLedgerRun({
    run_id: "run-b",
    recipes: [goodRow({ quantity: "callback count", rerun: "rg --count '^  def ' api/lib/barkpark/plugin.ex", observed_at: "2026-07-20T13:00:00Z" })],
    dir,
  });

  const folded = foldLedger(dir);
  assert.equal(folded.stats.subjects, 1);
  assert.equal(folded.conflicts.length, 1);

  const flag = folded.conflicts[0];
  assert.equal(flag.reason, CONFLICT);
  assert.equal(flag.rivals.length, 2);
  assert.equal(flag.recipes.length, 2, "BOTH recipes are kept — neither is superseded");
  assert.match(flag.message, /neither wins by arrival order/);

  const entry = folded.entries[0];
  assert.equal(entry.conflict, true);
  assert.equal(entry.key, recipeKey({ subject: goodRow().subject, quantity: "callback count" }));
});

test("the same recipe recorded twice is CORROBORATION, not a conflict", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  writeLedgerRun({ run_id: "run-b", recipes: [goodRow({ observed_at: "2026-07-21T09:00:00Z" })], dir });

  const folded = foldLedger(dir);
  assert.equal(folded.entries.length, 1);
  assert.equal(folded.entries[0].recipes.length, 2, "both runs are kept");
  assert.equal(folded.entries[0].conflict, false, "a flag that fires on ordinary repetition is ignored within a wave");
  assert.equal(folded.conflicts.length, 0);
});

test("write ORDER does not decide anything — the fold is identical whichever file lands first", () => {
  const rowA = goodRow({ rerun: "grep -c 'def ' api/lib/barkpark/plugin.ex", observed_at: "2026-07-20T12:00:00Z" });
  const rowB = goodRow({ rerun: "rg --count 'def ' api/lib/barkpark/plugin.ex", observed_at: "2026-07-20T13:00:00Z" });

  const forward = tmpLedger();
  writeLedgerRun({ run_id: "r1", recipes: [rowA], dir: forward });
  writeLedgerRun({ run_id: "r2", recipes: [rowB], dir: forward });

  const reverse = tmpLedger();
  writeLedgerRun({ run_id: "r2", recipes: [rowB], dir: reverse });
  writeLedgerRun({ run_id: "r1", recipes: [rowA], dir: reverse });

  const strip = (f) => JSON.stringify(f.entries.map((e) => ({ ...e, recipes: e.recipes.map(({ file, ...r }) => r), flag: undefined })));
  assert.equal(strip(foldLedger(forward)), strip(foldLedger(reverse)));
});

test("a subject with two DIFFERENT quantities is two entries, not a conflict", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "r1", recipes: [goodRow({ quantity: "callback count" })], dir });
  writeLedgerRun({ run_id: "r2", recipes: [goodRow({ quantity: "line count", rerun: "wc -l api/lib/barkpark/plugin.ex" })], dir });

  const folded = foldLedger(dir);
  assert.equal(folded.entries.length, 2);
  assert.equal(folded.conflicts.length, 0);
});

test("recipeKey cannot be forged by concatenation", () => {
  const a = recipeKey({ subject: "a b", quantity: "c" });
  const b = recipeKey({ subject: "a", quantity: "b c" });
  assert.notEqual(a, b);
});

// ── reading honestly ─────────────────────────────────────────────────────────

test("an unparseable ledger file is REPORTED, never silently skipped (D6)", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "good", recipes: [goodRow()], dir });
  writeFileSync(join(dir, "broken-0000.json"), "{ not json");
  writeFileSync(join(dir, "shapeless-0000.json"), "{\"run_id\":\"x\"}");

  const { runs, unreadable } = readLedgerRuns(dir);
  assert.equal(runs.length, 1);
  assert.equal(unreadable.length, 2);
  assert.deepEqual(unreadable.map((u) => u.reason).sort(), ["MALFORMED-RUN", "UNPARSEABLE"]);

  const folded = foldLedger(dir);
  assert.equal(folded.stats.unreadable, 2, "a fold that hides a corrupt file reports a smaller, cleaner, wrong world");
});

test("folding an absent directory is an empty fold, not a throw", () => {
  const folded = foldLedger(join(tmpLedger(), "does-not-exist"));
  assert.deepEqual(folded.entries, []);
  assert.equal(folded.stats.rows, 0);
});

test("the fold is deterministic — entries sorted by key, recipes by (observed_at, file)", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "z", recipes: [goodRow({ subject: "z.ex", rerun: "wc -l z.ex" })], dir });
  writeLedgerRun({ run_id: "a", recipes: [goodRow({ subject: "a.ex", rerun: "wc -l a.ex" })], dir });

  const keys = foldLedger(dir).entries.map((e) => e.subject);
  assert.deepEqual(keys, [...keys].sort());
});

// ── the store on disk ────────────────────────────────────────────────────────

test("the committed ledger directory is NOT gitignored — D10's exact trap, checked not assumed", () => {
  const git = spawnSync("git", ["check-ignore", "-v", "tooling/grip/ledger/"], { cwd: REPO_ROOT, encoding: "utf8" });
  if (git.error) return; // no git here — the shell gate still checks it
  assert.equal(git.status, 1, `tooling/grip/ledger/ IS gitignored: ${git.stdout.trim()}`);
});

test("DEFAULT_LEDGER_DIR points inside tooling/grip and this test never wrote to it", () => {
  assert.match(DEFAULT_LEDGER_DIR, /tooling\/grip\/ledger\/$/);
  mkdirSync(DEFAULT_LEDGER_DIR, { recursive: true });
  const stray = readdirSync(DEFAULT_LEDGER_DIR).filter((f) => f.endsWith(".json"));
  assert.deepEqual(stray, [], `the committed store must hold no test rows, found: ${stray.join(", ")}`);
});

// ── the D18 control ──────────────────────────────────────────────────────────

test("--selftest runs every control and reports each one FIRING", () => {
  const run = spawnSync(process.execPath, [LEDGER_SRC, "--selftest"], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal(/SILENT/.test(run.stdout), false, run.stdout);
  assert.match(run.stdout, /controls fired/);
});

test("the CLI folds a directory and exits nonzero only on an unreadable file", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "r1", recipes: [goodRow()], dir });
  const clean = spawnSync(process.execPath, [LEDGER_SRC, "fold", dir], { encoding: "utf8" });
  assert.equal(clean.status, 0);
  assert.equal(JSON.parse(clean.stdout).stats.rows, 1);

  writeFileSync(join(dir, "broken-0000.json"), "{");
  const dirty = spawnSync(process.execPath, [LEDGER_SRC, "fold", dir], { encoding: "utf8" });
  assert.equal(dirty.status, 1);
});
